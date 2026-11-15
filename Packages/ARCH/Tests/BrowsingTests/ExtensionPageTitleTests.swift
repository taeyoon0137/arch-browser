// The title that the sidebar's rows, the window's title, and the tab switcher show for a web extension's own page (`Tab.shownTitle`): the extension's name in place of a page title that only repeats the address, as WebKit and Chromium report a page without a title, while a page's own title, the user's name, a hook's name, and a live folder item's title stay, with a rename to that name and a favorite of the page, and how the name follows an install, a rename, and a removal of the extension at once. Tabs run on stand-ins, in a session on a test engine for the rename, the favorite, and the changes, with the extension's name from a callback as the session gives it, or for the changes from the Persona's runtime, to which the test lists the extension as the manager does.
import ARCHEngine
import Combine
import Extensions
import Foundation
@testable import Plugins
import Testing
@testable import Browsing

/// The identifier of the extension named Reader, and the address of its options page on WebKit.
private let identifier = "abcdefghijklmnopabcdefghijklmnop"
private let options = URL(string: "webkit-extension://\(identifier)/options.html")!

@MainActor
@Suite struct ExtensionPageTitleTests {
    /// A tab at `url` whose page reports `title`, in which the extension with the identifier is named Reader.
    private func tab(at url: URL = options, title: String) -> Tab {
        let tab = Tab(id: UUID(), webContents: UnloadedWebContents(url: url, title: title, engine: .webKit, state: nil), spaceID: UUID(), isPinned: false, personaID: UUID())
        tab.extensionName = { $0.host == identifier ? "Reader" : nil }
        return tab
    }

    @Test func anExtensionsPageWithoutATitleIsNamedByTheExtension() {
        // WebKit reports an empty title, for which the page's title is its host, the identifier.
        let untitled = tab(title: "")
        #expect(untitled.displayTitle == identifier && untitled.shownTitle == "Reader" && untitled.shownPageTitle == "Reader")
        // Chromium reports the address as the title of a page without one, without the `/` of a bare host and with spaces unescaped.
        let chromium = URL(string: "chrome-extension://\(identifier)/options.html")!
        #expect(tab(at: chromium, title: chromium.absoluteString).shownTitle == "Reader")
        #expect(tab(at: URL(string: "chrome-extension://\(identifier)/")!, title: "chrome-extension://\(identifier)").shownTitle == "Reader")
        #expect(tab(at: URL(string: "chrome-extension://\(identifier)/my%20options.html")!, title: "chrome-extension://\(identifier)/my options.html").shownTitle == "Reader")
        #expect(tab(title: identifier).shownTitle == "Reader")
    }

    @Test func aTitleOrANameOfTheTabsOwnStays() {
        let titled = tab(title: "Reader Options")
        #expect(titled.shownTitle == "Reader Options" && titled.shownPageTitle == "Reader Options")
        let named = tab(title: "")
        named.customTitle = "Mine"
        #expect(named.shownTitle == "Mine" && named.shownPageTitle == "Reader")
        let suggested = tab(title: "")
        suggested.suggestedTitle = SuggestedTitle(title: "From a hook", url: options)
        #expect(suggested.shownTitle == "From a hook")
        // A name the user turned down leaves the page's title, which the extension's name stands in for.
        suggested.suggestedTitle = SuggestedTitle(title: nil, url: options)
        #expect(suggested.shownTitle == "Reader")
        // A live folder item's tab on its saved page shows the item's title, which the saved page keeps, and the extension's name only for an item without one.
        let item = tab(title: "")
        item.liveItemID = "item"
        item.savedPage = SavedPage(url: options, title: "An item")
        #expect(item.shownTitle == "An item")
        item.savedPage = SavedPage(url: options, title: "")
        #expect(item.shownTitle == "Reader")
    }

    @Test func otherPagesKeepTheirTitles() {
        // A page without an extension's name and a tab without the session's callback keep `displayTitle`. The session names no web page, whatever its host (`EngineVersionsTests`).
        #expect(tab(at: URL(string: "webkit-extension://ponmlkjihgfedcbaponmlkjihgfedcba/options.html")!, title: "").shownTitle == "ponmlkjihgfedcbaponmlkjihgfedcba")
        let unwired = Tab(id: UUID(), webContents: UnloadedWebContents(url: options, title: "", engine: .chromium, state: nil), spaceID: nil, isPinned: false, personaID: UUID())
        #expect(unwired.shownTitle == unwired.displayTitle)
        #expect(!Tab.titleRepeatsAddress("Options", of: options) && !Tab.titleRepeatsAddress("webkit-extension://\(identifier)/other.html", of: options))
    }

    /// Runs `body` with a session whose first space has a tab on the options page without a title, and a main window on that space.
    private func withSession(_ body: (BrowserSession, BrowserWindowModel, Tab) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let page = session.adopt(UnloadedWebContents(url: options, title: "", engine: .webKit, state: nil), spaceID: space.id, personaID: space.resolvedPersonaID, pinned: false, select: false)
        page.extensionName = { $0.host == identifier ? "Reader" : nil }
        try body(session, window, page)
    }

    @Test func renamingToTheExtensionsNameKeepsNoName() throws {
        try withSession { _, window, page in
            // The rename field starts with the extension's name, so ending it with only a space added changes nothing.
            window.renameTab(page.id, to: "Reader ")
            #expect(page.customTitle == nil && page.suggestedTitle == nil)
            // The name the row shows for the page takes the user's name away, as a page's own title does, so the row follows the extension's name again.
            window.renameTab(page.id, to: "Mine")
            #expect(page.customTitle == "Mine")
            window.renameTab(page.id, to: "Reader")
            #expect(page.customTitle == nil && page.shownTitle == "Reader")
        }
    }

    @Test func aFavoriteOfTheExtensionsPageTakesItsName() throws {
        try withSession { session, _, page in
            session.addFavorite(page)
            let favorite = try #require(session.favorites.last)
            #expect(favorite.url == options && favorite.title == "Reader")
            var renamed = favorite
            renamed.title = "Mine"
            // Use Current Page as Saved Page takes the page's title as the row names the page.
            #expect(renamed.usingCurrentPage(of: page, among: session.favorites)?.title == "Reader")
        }
    }

    /// The extension named Reader as the manager lists it to the runtime, under `name`.
    private func reader(named name: String, isEnabled: Bool = true) -> InstalledPlugin {
        let manifest = PluginManifest(id: PluginID(rawValue: "extension.\(identifier)")!, name: name, version: "1", summary: "", contributions: PluginContributions())
        return InstalledPlugin(kind: .webExtension, manifest: manifest, grant: PluginGrant(requestedBy: manifest), isEnabled: isEnabled)
    }

    /// Lets the main queue run what was sent to it before.
    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func theNamesFollowAnInstallARenameAndARemovalAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let personaID = space.resolvedPersonaID
        let otherSpace = try #require(session.spaces(in: session.addPersona(named: "Work").id).first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let quietWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let otherWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: otherSpace.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { [window, quietWindow, otherWindow].forEach(session.windowWillClose) }
        window.commandPaletteMode = .newTab
        otherWindow.commandPaletteMode = .newTab
        let page = session.adopt(UnloadedWebContents(url: options, title: "", engine: .webKit, state: nil), spaceID: space.id, personaID: personaID, pinned: false, select: false)
        let otherPage = session.adopt(UnloadedWebContents(url: URL(string: "webkit-extension://ponmlkjihgfedcbaponmlkjihgfedcba/options.html")!, title: "", engine: .webKit, state: nil),
                                      spaceID: space.id, personaID: personaID, pinned: false, select: false)
        let site = session.adopt(UnloadedWebContents(url: URL(string: "https://example.org/")!, title: "", engine: .webKit, state: nil), spaceID: space.id, personaID: personaID, pinned: false, select: false)
        var changes: [String: Int] = [:]
        let observers = [("page", page.objectWillChange), ("otherPage", otherPage.objectWillChange), ("site", site.objectWillChange),
                         ("window", window.objectWillChange), ("quietWindow", quietWindow.objectWillChange), ("otherWindow", otherWindow.objectWillChange)]
            .map { name, publisher in publisher.sink { changes[name, default: 0] += 1 } }
        defer { observers.forEach { $0.cancel() } }

        // A runtime whose first list names nothing announces nothing.
        let runtime = try #require(session.webExtensions(in: personaID))
        await nextTurn()
        #expect(session.extensionName(ofPageAt: options, in: personaID) == nil && page.shownTitle == identifier && changes.isEmpty)

        // An install names the page at once, and on the next turn the page's tab and the Persona's window whose palette is open announce it, so the views that follow them draw the name; another extension's page, a web page's tab, the Persona's window without the palette, and another Persona's window do not.
        runtime.run([reader(named: "Reader")])
        #expect(session.extensionName(ofPageAt: options, in: personaID) == "Reader" && page.shownTitle == "Reader")
        await nextTurn()
        #expect(changes == ["page": 1, "window": 1])

        // A rename, as an update brings, announces the new name; a switch off keeps the name and announces nothing.
        runtime.run([reader(named: "Reader Two")])
        await nextTurn()
        #expect(session.extensionName(ofPageAt: options, in: personaID) == "Reader Two" && page.shownTitle == "Reader Two" && changes == ["page": 2, "window": 2])
        runtime.run([reader(named: "Reader Two", isEnabled: false)])
        await nextTurn()
        #expect(session.extensionName(ofPageAt: options, in: personaID) == "Reader Two" && page.shownTitle == "Reader Two" && changes == ["page": 2, "window": 2])

        // A removal takes the name away, so the page's tab shows the identifier again.
        runtime.remove(reader(named: "Reader Two", isEnabled: false))
        await nextTurn()
        #expect(session.extensionName(ofPageAt: options, in: personaID) == nil && page.shownTitle == identifier && changes == ["page": 3, "window": 3])
    }
}
