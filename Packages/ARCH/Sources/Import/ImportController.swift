// The two imports on the browser window. File ▸ Import Bookmarks and History…: the user picks exported files in an open panel, their bookmarks become favorites and their pages go into the history store. File ▸ Import from Browser…: a sheet lists the browsers on this Mac with their profiles, and the checked items go to the session, the history store, and site search. Either way a sheet then sums up what came in. Passwords are left to the system's Passwords app.
import AppKit
import Browsing
import History
import SwiftUI

/// Runs one import at a time on the browser window: an open panel sheet or the browser import sheet, reading the files off the main thread, then a summary sheet.
public final class ImportController {
    private let session: BrowserSession
    private let history: HistoryStore
    private let siteSearch: SiteSearchStore
    /// Set from the open panel or the browser import sheet until the summary sheet closes.
    private var isImporting = false
    /// The browser import sheet while it is open.
    private weak var browserSheet: NSWindow?
    /// Reads the browsers that the user went to grant access to again when Arch becomes active, while the browser import sheet is open.
    private var activationObserver: NSObjectProtocol?

    public init(session: BrowserSession, history: HistoryStore = .shared, siteSearch: SiteSearchStore = .shared) {
        self.session = session
        self.history = history
        self.siteSearch = siteSearch
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
                DatabaseCopy.removeLeftovers()
                let results = urls.map { url in Result { try ImportedFile.read(url) } }
                DispatchQueue.main.async { self.add(results, in: window) }
            }
        }
    }

    /// Adds the favorites and history pages the files held, the favorites to the Persona of the sidebar target's current space, then sums them up in a sheet on `window`.
    private func add(_ results: [Result<ImportedFile, Error>], in window: NSWindow) {
        let personaID = session.sidebarTarget().personaID
        var summary = ImportSummary()
        for result in results {
            switch result {
            case .success(let file):
                let addedCount = session.addFavorites(file.favorites, in: personaID)
                summary.favorites += addedCount
                summary.presentFavorites += file.favorites.count - addedCount
                history.importEntries(file.history)
                summary.historyPages += file.history.count
            case .failure(let error):
                summary.failures.append(error.localizedDescription)
            }
        }
        show(summary, emptyLine: summary.failures.count < results.count ? "No bookmarks or history pages with web addresses were found." : nil, in: window)
    }

    // MARK: Import from Browser

    /// Shows the browser import sheet on `window`, which comes to the front first, and reads the browsers on this Mac off the main thread while the sheet says it is looking for them.
    public func importFromBrowser(in window: NSWindow) {
        guard canImport(in: window) else { return }
        isImporting = true
        window.makeKeyAndOrderFront(nil)
        let model = BrowserImportModel(personas: session.$personas, currentPersonaID: session.sidebarTarget().personaID, record: SidebarImport.Record())
        let controller = NSHostingController(rootView: BrowserImportSheet(model: model, actions: BrowserImportSheet.Actions(
            importSelection: { [weak self] in
                self?.closeBrowserSheet(on: window)
                self?.add(model.selection, record: model.record, in: window)
            },
            cancel: { [weak self] in self?.cancelBrowserImport(on: window) },
            openPrivacySetting: { browser in
                model.markAsked(browser)
                NSWorkspace.shared.open(browser.source.privacySetting.paneURL)
            },
            chooseExportedFile: { [weak self] in
                self?.cancelBrowserImport(on: window)
                self?.chooseFiles(in: window)
            }
        )))
        // The sheet grows from "Looking for browsers…" to the browsers' sections.
        controller.sizingOptions = .preferredContentSize
        let sheet = NSWindow(contentViewController: controller)
        browserSheet = sheet
        window.beginSheet(sheet)
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            model.browsersToReread.forEach { self?.read($0.source, into: model) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            DatabaseCopy.removeLeftovers()
            let browsers = BrowserSource.detected().map { ImportedBrowser.read($0.source) }
            DispatchQueue.main.async { model.show(browsers) }
        }
    }

    /// Reads `source` again off the main thread, as after the user granted access to its files.
    private func read(_ source: BrowserSource, into model: BrowserImportModel) {
        DispatchQueue.global(qos: .userInitiated).async {
            let browser = ImportedBrowser.read(source)
            DispatchQueue.main.async { model.replace(browser) }
        }
    }

    /// Closes the browser import sheet, which Import follows with the summary.
    private func closeBrowserSheet(on window: NSWindow) {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let browserSheet { window.endSheet(browserSheet) }
    }

    /// Closes the browser import sheet without importing, which ends the import.
    private func cancelBrowserImport(on window: NSWindow) {
        closeBrowserSheet(on: window)
        isImporting = false
    }

    /// Applies the selection in one turn of the run loop, as `docs/import-browsers.md` describes: each profile's sidebar items to its destination, then the shortcuts, the history pages, the search engine, and the record of what the profiles brought. The session saves through its usual debounce.
    private func add(_ selection: BrowserImportModel.Selection, record: SidebarImport.Record, in window: NSWindow) {
        var record = record
        var summary = ImportSummary()
        for (row, destination) in selection.rows {
            summary.add(session.addImport(row, to: destination, record: &record))
        }
        let addedShortcutCount = siteSearch.add(selection.shortcuts)
        summary.shortcuts = addedShortcutCount
        summary.skippedShortcuts = selection.shortcuts.count - addedShortcutCount + selection.skippedShortcutCount
        history.importEntries(selection.history)
        summary.historyPages = selection.history.count
        if let engine = selection.searchEngine {
            UserDefaults.standard.set(engine.rawValue, forKey: SearchEngine.defaultsKey)
            summary.searchEngine = engine
        }
        if !selection.rows.isEmpty { record.write() }
        summary.failures = selection.failures
        show(summary, emptyLine: "Everything checked was in Arch already.", in: window)
    }

    // MARK: Summary

    /// Sums up an import in a sheet on `window`, with `emptyLine` when nothing came in, and ends the import once the sheet closes.
    private func show(_ summary: ImportSummary, emptyLine: String?, in window: NSWindow) {
        let lines = summary.lines
        let alert = NSAlert()
        alert.messageText = lines.isEmpty ? "Nothing Was Imported" : "Import Finished"
        alert.informativeText = ((lines.isEmpty ? [emptyLine].compactMap { $0 } : lines) + summary.failures).joined(separator: "\n")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.isImporting = false
        }
    }
}

/// What an import brought, which the summary sheet reports with one line per kind. The file import fills the favorites, history pages, and failures; the browser import fills every kind.
struct ImportSummary {
    var personas = 0
    var spaces = 0
    var pinnedTabs = 0
    var favorites = 0
    /// The favorites, or bookmarks that would have become favorites, whose addresses the Persona's favorites had already.
    var presentFavorites = 0
    var historyPages = 0
    var shortcuts = 0
    /// The shortcuts left out because another shortcut uses their keyword or Arch cannot use them.
    var skippedShortcuts = 0
    var searchEngine: SearchEngine?
    /// Why files, browsers, or items could not be read.
    var failures: [String] = []

    /// Adds what one profile brought to the sidebar.
    mutating func add(_ counts: SidebarImport.Counts) {
        personas += counts.personas
        spaces += counts.spaces
        pinnedTabs += counts.pinnedTabs
        favorites += counts.favorites
        presentFavorites += counts.presentFavorites
    }

    /// One line for each kind that came in, without the failures.
    var lines: [String] {
        var lines: [String] = []
        if personas > 0 {
            lines.append("Created \(Self.count(personas, "Persona", "Personas")).")
        }
        let pinned = [spaces > 0 ? Self.count(spaces, "space", "spaces") : nil, pinnedTabs > 0 ? Self.count(pinnedTabs, "pinned tab", "pinned tabs") : nil].compactMap { $0 }
        if !pinned.isEmpty {
            lines.append("Added \(pinned.joined(separator: " and ")).")
        }
        if favorites + presentFavorites > 0 {
            lines.append("Added \(Self.count(favorites, "favorite", "favorites"))." + (presentFavorites > 0 ? " \(Self.count(presentFavorites, "was", "were")) already in favorites." : ""))
        }
        if historyPages > 0 {
            lines.append("Imported \(Self.count(historyPages, "page", "pages")) into history.")
        }
        if shortcuts + skippedShortcuts > 0 {
            lines.append("Added \(Self.count(shortcuts, "search shortcut", "search shortcuts"))." + (skippedShortcuts > 0 ? " Skipped \(skippedShortcuts.formatted()) with a keyword in use or an address Arch cannot use." : ""))
        }
        if let searchEngine {
            lines.append("The search engine is now \(searchEngine.title).")
        }
        return lines
    }

    /// The number with the noun that agrees with it, such as "1 page" or "5,210 pages".
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }
}
