// Arch's own panel for a page's file chooser, the same on both engines: an open panel for files or a folder, or a save panel.
import AppKit
import ARCHEngine

enum FileChooserPanel {
    /// A panel set up for the request, with a message that names the page's site, which the page cannot choose. The open panel offers only the page's accepted types when each has a file type (`allowedContentTypes`), and otherwise every file.
    static func make(for request: EngineFileChooserRequest, site: String?) -> NSSavePanel {
        let asker = site.map { "\u{201C}\($0)\u{201D}" } ?? "this page"
        guard request.mode != .save else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = request.suggestedName ?? ""
            panel.message = "Choose where \(asker) saves a file."
            return panel
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = request.mode != .openFolder
        panel.canChooseDirectories = request.mode == .openFolder
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        if let types = request.allowedContentTypes { panel.allowedContentTypes = types }
        panel.prompt = "Choose"
        panel.message = switch request.mode {
        case .openFiles: "Choose files for \(asker)."
        case .openFolder: "Choose a folder for \(asker). The page receives every file in it."
        default: "Choose a file for \(asker)."
        }
        return panel
    }

    /// What the user chose: an open panel's selection, or a save panel's file.
    static func chosenURLs(of panel: NSSavePanel) -> [URL] {
        if let panel = panel as? NSOpenPanel { return panel.urls }
        return panel.url.map { [$0] } ?? []
    }
}
