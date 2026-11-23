// Arch's own panel for a page's file chooser, the same on both engines: an open panel for files or a folder, or a save panel.
import AppKit
import ARCHEngine

/// Makes the open or save panel for a page's file chooser and reads the user's choice back, as the file header describes.
enum FileChooserPanel {
    /// A panel set up for the request, with a message that names who asks (`asker(of:)`). The open panel offers only the page's accepted types when each has a file type (`allowedContentTypes`), and otherwise every file.
    static func make(for request: EngineFileChooserRequest) -> NSSavePanel {
        let asker = asker(of: request)
        guard request.mode != .save else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = request.suggestedName ?? ""
            panel.message = localized("Choose where \(asker) saves a file.")
            return panel
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = request.mode != .openFolder
        panel.canChooseDirectories = request.mode == .openFolder
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        if let types = request.allowedContentTypes { panel.allowedContentTypes = types }
        panel.prompt = localized("Choose")
        panel.message = switch request.mode {
        case .openFiles: localized("Choose files for \(asker).")
        case .openFolder: localized("Choose a folder for \(asker). The page receives every file in it.")
        default: localized("Choose a file for \(asker).")
        }
        return panel
    }

    /// Who asks, from the engine's report and never from the tab's address, which can be one that the page started loading: the asking frame's site, with the page's when they differ, as for a frame of another site inside the page; the page's site as "a page on" it when the engine names no frame, as Chromium does; or "this page" when the engine names neither.
    static func asker(of request: EngineFileChooserRequest) -> String {
        switch (request.origin?.host, request.pageOrigin?.host) {
        case let (frame?, page?) where frame != page: localized("\u{201C}\(frame)\u{201D} in \u{201C}\(page)\u{201D}")
        case let (frame?, _): "\u{201C}\(frame)\u{201D}"
        case let (nil, page?): localized("a page on \u{201C}\(page)\u{201D}")
        case (nil, nil): localized("this page")
        }
    }

    /// What the user chose: an open panel's selection, or a save panel's file.
    static func chosenURLs(of panel: NSSavePanel) -> [URL] {
        if let panel = panel as? NSOpenPanel { return panel.urls }
        return panel.url.map { [$0] } ?? []
    }
}
