// A page's request for files, a folder, or a place to save one, with who asks, which both adapters report to the UI delegate (`webContents(_:runFileChooser:completion:)`), and the rules both apply to the answer.
import Foundation
import UniformTypeIdentifiers

/// What a page asks the user to choose for a file input, as its click or `showPicker()` opens it, or what another chooser of the engine asks, such as Chromium's Save As.
public struct EngineFileChooserRequest: Equatable, Sendable {
    /// What kind of choice the chooser asks for.
    public enum Mode: String, Sendable {
        /// One existing file.
        case openFile
        /// One or more existing files, for an input with `multiple`.
        case openFiles
        /// One folder, whose files the page receives, for an input with `webkitdirectory`.
        case openFolder
        /// A new or existing file to write. Only Chromium asks for one, from a chooser that saves, such as a download's Save As, which Arch's downloads never ask for since they always name a destination.
        case save
    }

    public var mode: Mode
    /// The types the page accepts, as its `accept` attribute lists them: lowercase MIME types, such as `image/*` or `application/pdf`, and file name extensions with their leading dot, such as `.png`, in the engine's order. Empty when the page accepts any file, or when the engine cannot tell, as WebKit cannot with its private API flag off.
    public var acceptedTypes: [String]
    /// The file name the page suggests for `save`, without a folder; nil for the other modes.
    public var suggestedName: String?
    /// The origin of the frame that asks, which receives the files, as an address with an empty path. Nil when the engine cannot tell, as Chromium cannot, whose chooser names no frame, and for an origin without a host, such as a sandboxed or `data:` frame's.
    public var origin: URL?
    /// The origin of the page the tab shows, from the address its main frame committed, never from one it is still loading, which the page can start; nil when unknown or without a host. A panel names who asks from `origin` and this, not from the tab's address.
    public var pageOrigin: URL?

    /// Keeps of `acceptedTypes` only MIME types and extensions, trimmed and in lowercase, and of each address only its origin.
    public init(mode: Mode, acceptedTypes: [String] = [], suggestedName: String? = nil, origin: URL? = nil, pageOrigin: URL? = nil) {
        self.mode = mode
        self.acceptedTypes = acceptedTypes.compactMap { type in
            let type = type.trimmingCharacters(in: .whitespaces).lowercased()
            let isExtension = type.count > 1 && type.hasPrefix(".") && !type.contains("/")
            let parts = type.split(separator: "/", omittingEmptySubsequences: false)
            let isMIMEType = parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            return isExtension || isMIMEType ? type : nil
        }
        self.suggestedName = suggestedName.flatMap { $0.isEmpty ? nil : $0 }
        self.origin = origin.flatMap(Self.origin(of:))
        self.pageOrigin = pageOrigin.flatMap(Self.origin(of:))
    }

    /// An address's scheme, host, and port with an empty path, or nil for an address without a host, as `about:`, `data:`, `blob:`, and `file:` addresses are.
    private static func origin(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true), components.scheme != nil,
              let host = components.host, !host.isEmpty else { return nil }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Whether the user may choose more than one item.
    public var allowsMultipleSelection: Bool { mode == .openFiles }

    /// The content types an open panel offers for `acceptedTypes`: a whole category for `image/*`, `audio/*`, `video/*`, or `text/*`, and the declared type of each full MIME type and extension. Nil, so that the panel offers every file, when the page accepts any file or names a type that the system does not declare, whose dynamic type would match no file; the page then checks the file itself.
    public var allowedContentTypes: [UTType]? {
        guard !acceptedTypes.isEmpty else { return nil }
        var types: [UTType] = []
        for accepted in acceptedTypes {
            let type: UTType?
            if accepted.hasPrefix(".") {
                type = UTType(filenameExtension: String(accepted.dropFirst()))
            } else if accepted.hasSuffix("/*") {
                type = switch accepted {
                case "image/*": .image
                case "audio/*": .audio
                case "video/*": .movie
                case "text/*": .text
                default: nil
                }
            } else {
                type = UTType(mimeType: accepted)
            }
            guard let type, !type.isDynamic else { return nil }
            if !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// What the page receives of the files the user chose: file addresses only, and only the first for a mode that takes one item. Nil when nothing is left, which the engines take as a cancel.
    public func answer(from urls: [URL]?) -> [URL]? {
        let files = (urls ?? []).filter(\.isFileURL)
        let kept = allowsMultipleSelection ? files : Array(files.prefix(1))
        return kept.isEmpty ? nil : kept
    }
}
