// Each download's state as the downloads list and the library button show it, and the renaming of a finished file that a hook asks for and the downloads list undoes. The session makes an entry for each engine download item and refreshes it and the summary with each engine update.
import ARCHEngine
import Combine
import Foundation

/// Publishes an engine download item's state for the downloads list. The session refreshes it with each engine update.
public final class DownloadEntry: ObservableObject, Identifiable {
    /// Unique among the downloads of every Persona. An engine numbers downloads within one profile, so its item IDs can repeat across Personas, and the session finds an entry by its item.
    public let id = UUID()
    let item: any EngineDownloadItem
    private weak var session: BrowserSession?
    /// The destination accepted before the engine reports a path or creates its file.
    private(set) var chosenDestination: URL?
    /// The Persona whose profile in the engine keeps the download.
    let personaID: Persona.ID
    @Published public private(set) var state: EngineDownloadState
    @Published public private(set) var completedBytes: Int64
    @Published public private(set) var totalBytes: Int64
    @Published public private(set) var targetPath: URL?
    /// Where a rename moved the finished file; nil while the file keeps the name the engine gave it.
    @Published public private(set) var renamedPath: URL?

    init(item: any EngineDownloadItem, personaID: Persona.ID, session: BrowserSession? = nil) {
        self.session = session
        self.item = item
        self.personaID = personaID
        state = item.state
        completedBytes = item.completedBytes
        totalBytes = item.totalBytes
        targetPath = item.targetPath
    }

    func refresh() {
        state = item.state
        completedBytes = item.completedBytes
        totalBytes = item.totalBytes
        targetPath = item.targetPath
    }

    /// The file's location: where a rename moved it, or where the engine saved it.
    public var fileURL: URL? {
        renamedPath ?? targetPath
    }

    public var filename: String {
        fileURL?.lastPathComponent ?? item.sourceURL.lastPathComponent
    }

    public var isFinished: Bool {
        state == .completed || state == .cancelled || state == .failed
    }

    enum FileIssue: String {
        case missing = "File not found"
        case open = "Couldn’t open file"
        case reveal = "Couldn’t show file in Finder"
        case restore = "Couldn’t restore original name"
        case folder = "Couldn’t open folder"

        /// The words the downloads list shows and VoiceOver reads.
        var message: String {
            switch self {
            case .missing: localized("File not found")
            case .open: localized("Couldn’t open file")
            case .reveal: localized("Couldn’t show file in Finder")
            case .restore: localized("Couldn’t restore original name")
            case .folder: localized("Couldn’t open folder")
            }
        }
    }

    /// Resolve the file again on every attempt. Finder may have moved it, or a hook may have renamed it since the menu opened.
    func accessFile(onFailure issue: FileIssue, _ action: (URL) -> Bool) -> FileIssue? {
        guard state == .completed else { return nil }
        guard let file = fileURL, file.isFileURL, FileManager.default.fileExists(atPath: file.path) else { return .missing }
        if action(file) { return nil }
        return FileManager.default.fileExists(atPath: file.path) ? issue : .missing
    }

    /// The last folder Arch saved or renamed the file in, while that folder is still available.
    var containingFolder: URL? {
        guard let file = fileURL, file.isFileURL else { return nil }
        let folder = file.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue ? folder : nil
    }

    func showContainingFolder(_ open: (URL) -> Bool) -> FileIssue? {
        guard let folder = containingFolder, open(folder) else { return .folder }
        return nil
    }

    var canRetry: Bool { item.canRetry }

    /// Retiring the profile cancels any transfer that can still make a request.
    var canCancel: Bool {
        switch item.state {
        case .inProgress, .paused: return true
        case .failed: return canRetry
        case .completed, .cancelled: return false
        }
    }

    private var reservedDestination: URL? {
        canCancel ? chosenDestination ?? item.targetPath : nil
    }

    /// Two spellings in the same folder can name the same future file on a case-insensitive volume.
    @MainActor
    private func isReserved(_ url: URL) -> Bool {
        let others = session?.downloads.compactMap { $0 === self ? nil : $0.reservedDestination } ?? []
        guard !others.isEmpty else { return false }
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let caseSensitive = (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? true
        let path = directory.appendingPathComponent(url.lastPathComponent).path
        return others.contains {
            let otherPath = $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent).path
            return caseSensitive ? path == otherPath : path.caseInsensitiveCompare(otherPath) == .orderedSame
        }
    }

    /// A save panel may replace an existing file with the user's consent. Every accepted name belongs to one transfer.
    @MainActor
    func reserveDestination(_ url: URL) -> Bool {
        guard canCancel, !isReserved(url) else { return false }
        chosenDestination = url
        return true
    }

    @MainActor
    func unusedDestination(for filename: String, in directory: URL, keeping current: URL? = nil) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 1
        while isReserved(candidate) || (candidate != current && FileManager.default.fileExists(atPath: candidate.path)) {
            counter += 1
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
        }
        return candidate
    }

    // MARK: Renaming

    /// The longest file name a rename gives, extension included.
    static let maximumFilenameLength = 80

    /// Renames the finished file in its folder to `name` with the file's own extension, made safe by `safeFilename(_:keepingExtensionOf:)` and unused in the folder. Fails when the file is no longer where the entry put it, the name leaves nothing, or the file has that name already.
    @MainActor
    @discardableResult
    func rename(to name: String) -> Bool {
        guard state == .completed, let current = fileURL, let filename = Self.safeFilename(name, keepingExtensionOf: current.lastPathComponent),
              filename != current.lastPathComponent else { return false }
        return move(current, to: unusedDestination(for: filename, in: current.deletingLastPathComponent()))
    }

    /// Gives the renamed file back the name the engine saved it under, or the nearest unused one.
    @MainActor
    @discardableResult
    func restoreOriginalName() -> Bool {
        guard let current = renamedPath, let original = targetPath else { return false }
        let destination = unusedDestination(for: original.lastPathComponent, in: original.deletingLastPathComponent(), keeping: current)
        return destination == current || move(current, to: destination)
    }

    @discardableResult
    private func move(_ current: URL, to destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: current.path), (try? FileManager.default.moveItem(at: current, to: destination)) != nil else { return false }
        renamedPath = destination == targetPath ? nil : destination
        return true
    }

    /// The extensions of compressed archives, which name two layers that a rename keeps together.
    private static let archiveExtensions: Set<String> = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    /// A file name from a suggested name: without `/` and `:`, with spaces for control characters such as line breaks, without dots or spaces at either end, with the original file's extension, which the suggestion may repeat, and at most `maximumFilenameLength` characters. A compressed archive's extension, such as `.tar.gz`, counts as one. Nil when nothing is left.
    static func safeFilename(_ suggestion: String, keepingExtensionOf original: String) -> String? {
        let name = original as NSString
        let lastExtension = name.pathExtension
        let archiveExtension = "\((name.deletingPathExtension as NSString).pathExtension).\(lastExtension)"
        let pathExtension = archiveExtensions.contains(archiveExtension.lowercased()) ? archiveExtension : lastExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        var base = String(String.UnicodeScalarView(suggestion.unicodeScalars.filter { $0 != "/" && $0 != ":" }.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        if !suffix.isEmpty, base.lowercased().hasSuffix(suffix.lowercased()) { base.removeLast(suffix.count) }
        let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))
        base = String(base.trimmingCharacters(in: edges).prefix(max(maximumFilenameLength - suffix.count, 1))).trimmingCharacters(in: edges)
        return base.isEmpty ? nil : base + suffix
    }
}

/// What the library button and the downloads list's Clear button show of every download. The session refreshes it with each change to its downloads, and each value publishes only when it changes.
final class DownloadSummary: ObservableObject {
    /// Whether a download is in progress.
    @Published private(set) var isDownloading = false
    /// The share of the in-progress downloads' bytes received, or `nil` when none of them knows its size.
    @Published private(set) var progress: Double?
    /// Whether a download has finished, so that Clear has a row to remove.
    @Published private(set) var hasFinished = false

    /// VoiceOver's progress for an active download, including one whose size is unknown.
    var progressDescription: String {
        guard let progress else { return localized("Downloading") }
        if progress > 0, progress < 0.01 { return localized("Downloading, less than \((0.01).formatted(.percent))") }
        return localized("Downloading, \(progress.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down)))")
    }

    func refresh(from entries: [DownloadEntry]) {
        let active = entries.filter { $0.state == .inProgress }
        let sized = active.filter { $0.totalBytes > 0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = sized.reduce(Int64(0)) { $0 + $1.completedBytes }
        let progress = sized.isEmpty ? nil : min(1, Double(received) / Double(total))
        let hasFinished = entries.contains(where: \.isFinished)
        if isDownloading == active.isEmpty { isDownloading = !active.isEmpty }
        if self.progress != progress { self.progress = progress }
        if self.hasFinished != hasFinished { self.hasFinished = hasFinished }
    }
}
