// The downloads list fills the top of the sidebar's library. Each row reflects one engine download item and offers open, reveal, pause, resume, cancel, and remove actions, and gives a file that a hook renamed its original name back.
import AppKit
import ARCHEngine
import SwiftUI
import UniformTypeIdentifiers

/// Publishes an engine download item's state for the downloads list. The session refreshes it with each engine update.
public final class DownloadEntry: ObservableObject, Identifiable {
    /// Unique among the downloads of every Persona. An engine numbers downloads within one profile, so its item IDs can repeat across Personas, and the session finds an entry by its item.
    public let id = UUID()
    let item: any EngineDownloadItem
    /// The Persona whose profile in the engine keeps the download.
    let personaID: Persona.ID
    @Published public private(set) var state: EngineDownloadState
    @Published public private(set) var completedBytes: Int64
    @Published public private(set) var totalBytes: Int64
    @Published public private(set) var targetPath: URL?
    /// Where a rename moved the finished file; nil while the file keeps the name the engine gave it.
    @Published public private(set) var renamedPath: URL?

    init(item: any EngineDownloadItem, personaID: Persona.ID) {
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

    // MARK: Renaming

    /// The longest file name a rename gives, extension included.
    static let maximumFilenameLength = 80

    /// Renames the finished file in its folder to `name` with the file's own extension, made safe by `safeFilename(_:keepingExtensionOf:)` and unused in the folder. Fails when the file is no longer where the entry put it, the name leaves nothing, or the file has that name already.
    @discardableResult
    func rename(to name: String) -> Bool {
        guard state == .completed, let current = fileURL, let filename = Self.safeFilename(name, keepingExtensionOf: current.lastPathComponent),
              filename != current.lastPathComponent else { return false }
        return move(current, to: BrowserSession.uniqueDestination(for: filename, in: current.deletingLastPathComponent()))
    }

    /// Gives the renamed file back the name the engine saved it under, or the nearest unused one.
    func restoreOriginalName() {
        guard let current = renamedPath, let original = targetPath else { return }
        let destination = FileManager.default.fileExists(atPath: original.path) ? BrowserSession.uniqueDestination(for: original.lastPathComponent, in: current.deletingLastPathComponent()) : original
        move(current, to: destination)
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

struct DownloadsSectionView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: session.clearFinishedDownloads)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .disabled(!session.downloads.contains(where: \.isFinished))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            if session.downloads.isEmpty {
                Text("No downloads")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        // Newest first.
                        ForEach(session.downloads.reversed()) { entry in
                            DownloadRowView(session: session, entry: entry)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

struct DownloadRowView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var entry: DownloadEntry

    private var icon: NSImage {
        if let path = entry.fileURL?.path, entry.state == .completed { return NSWorkspace.shared.icon(forFile: path) }
        return NSWorkspace.shared.icon(for: .data)
    }

    private var status: String {
        let formatter = ByteCountFormatter()
        switch entry.state {
        case .inProgress:
            let total = entry.totalBytes > 0 ? " of \(formatter.string(fromByteCount: entry.totalBytes))" : ""
            return formatter.string(fromByteCount: entry.completedBytes) + total
        case .paused: return "Paused"
        case .completed: return formatter.string(fromByteCount: entry.totalBytes > 0 ? entry.totalBytes : entry.completedBytes)
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.filename)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if entry.state == .inProgress, entry.totalBytes > 0 {
                    ProgressView(value: Double(entry.completedBytes), total: Double(entry.totalBytes))
                        .progressViewStyle(.linear)
                }
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.state == .inProgress {
                SidebarIconButton(symbol: "pause.circle", label: "Pause", action: entry.item.pause)
                SidebarIconButton(symbol: "xmark.circle", label: "Cancel", action: entry.item.cancel)
            } else if entry.state == .paused || entry.state == .failed {
                SidebarIconButton(symbol: "play.circle", label: "Resume", action: entry.item.resume)
                SidebarIconButton(symbol: "xmark.circle", label: "Cancel", action: entry.item.cancel)
            } else if entry.state == .completed, let path = entry.fileURL {
                SidebarIconButton(symbol: "magnifyingglass.circle", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.state == .completed, let path = entry.fileURL { NSWorkspace.shared.open(path) }
        }
        .contextMenu {
            if let path = entry.fileURL, entry.state == .completed {
                Button("Open") { NSWorkspace.shared.open(path) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                if entry.renamedPath != nil {
                    Button("Restore Original Name", action: entry.restoreOriginalName)
                }
                Divider()
            }
            Button("Remove from List") { session.removeDownload(entry) }
        }
    }
}
