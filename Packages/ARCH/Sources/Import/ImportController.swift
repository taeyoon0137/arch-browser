// File ▸ Import Bookmarks and History…: the user picks exported files in an open panel, their bookmarks become favorites and their pages go into the history store, and a sheet sums up what came in. Passwords are left to the system's Passwords app.
import AppKit
import Browsing
import History

/// Runs one import at a time on the browser window: an open panel sheet, reading the files off the main thread, then a summary sheet.
public final class ImportController {
    private let session: BrowserSession
    private let history: HistoryStore
    /// Set from the open panel until the summary sheet closes.
    private var isImporting = false

    public init(session: BrowserSession, history: HistoryStore = .shared) {
        self.session = session
        self.history = history
    }

    /// Whether an import can start on `window`: none is running and the window shows no sheet.
    public func canImport(in window: NSWindow) -> Bool {
        !isImporting && window.attachedSheet == nil
    }

    /// Asks for files in an open panel on `window`, which comes to the front first, since the menu item also works while another window is key. A History database has no extension, so the panel takes any file and its contents decide the format.
    public func chooseFiles(in window: NSWindow) {
        guard canImport(in: window) else { return }
        isImporting = true
        window.makeKeyAndOrderFront(nil)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose exported bookmarks (an HTML, JSON, or property list file) or a History database. Passwords are imported in the Passwords app."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let urls = panel.urls
            guard response == .OK, !urls.isEmpty else {
                self.isImporting = false
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                HistoryDatabase.removeLeftoverCopies()
                let results = urls.map { url in Result { try ImportedFile.read(url) } }
                DispatchQueue.main.async { self.add(results, in: window) }
            }
        }
    }

    /// Adds the favorites and history pages the files held, then sums them up in a sheet on `window`.
    private func add(_ results: [Result<ImportedFile, Error>], in window: NSWindow) {
        var bookmarkCount = 0
        var addedFavoriteCount = 0
        var pageCount = 0
        var failures: [String] = []
        for result in results {
            switch result {
            case .success(let file):
                bookmarkCount += file.favorites.count
                addedFavoriteCount += session.addFavorites(file.favorites)
                history.importEntries(file.history)
                pageCount += file.history.count
            case .failure(let error):
                failures.append(error.localizedDescription)
            }
        }
        var lines: [String] = []
        if bookmarkCount > 0 {
            let skippedCount = bookmarkCount - addedFavoriteCount
            lines.append("Added \(Self.count(addedFavoriteCount, "favorite", "favorites"))." + (skippedCount > 0 ? " \(Self.count(skippedCount, "bookmark was", "bookmarks were")) already in favorites." : ""))
        }
        if pageCount > 0 {
            lines.append("Imported \(Self.count(pageCount, "page", "pages")) into history.")
        }
        if lines.isEmpty, failures.count < results.count {
            lines.append("No bookmarks or history pages with web addresses were found.")
        }
        let alert = NSAlert()
        alert.messageText = bookmarkCount + pageCount > 0 ? "Import Finished" : "Nothing Was Imported"
        alert.informativeText = (lines + failures).joined(separator: "\n")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.isImporting = false
        }
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }
}
