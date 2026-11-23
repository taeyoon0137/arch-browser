// The session's side of the tabs and windows that web extensions open (`SessionWebExtensionHost`, `docs/plugins.md`, Web extensions as plugins), as for a plugin's tabs: a tab that `tabs.create` opens, a small window's tab that `windows.create` opens, and a tab that a page of either opens before the user acts in it, in the background, in a main window, or in a small window, download no file that their address points at, and their pages' downloads ask with a card over the tab until the user acts in them. A tab that a page opens straight onto a file downloads as that page's download, so a page opens no file after file without asking. The small windows' AppKit windows are never ordered in.
import AppKit
import ARCHEngine
import Combine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct SessionWebExtensionHostTests {
    private let file = URL(string: "https://example.org/a.bin")!

    private func withSession(_ check: (BrowserSession, SessionWebExtensionHost, Persona.ID) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchWebExtensionHost-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        registry.register(SessionTestEngine(kind: .chromium))
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let persona = try #require(session.spaces.first).resolvedPersonaID
        // The host follows the Persona's runtime from its plugin manager on.
        _ = session.plugins(in: persona)
        defer { for window in session.windows { session.windowWillClose(window) } }
        try check(session, session.webExtensionHost, persona)
    }

    /// Gives each small window that the session opens a window that is never ordered in before the session raises it, and keeps those windows.
    @MainActor private final class OffscreenSmallWindows {
        private(set) var windows: [WindowSpy] = []
        private var observation: AnyCancellable?

        init(_ session: BrowserSession) {
            // The host reads the key window, which needs the application object.
            _ = NSApplication.shared
            observation = session.$focusedTabID.sink { [unowned self] id in
                guard let id, let window = session.activeWindow, window.kind == .small, window.selectedTabID == id, !(window.nsWindow is WindowSpy) else { return }
                let spy = WindowSpy()
                windows.append(spy)
                window.nsWindow = spy
            }
        }
    }

    final class WindowSpy: NSWindow {
        private(set) var raises = 0
        override func makeKeyAndOrderFront(_ sender: Any?) { raises += 1 }
    }

    /// Opens a tab for an extension as `tabs.create` does and returns it.
    private func openTab(_ url: URL?, in engine: EngineKind, with host: SessionWebExtensionHost, persona: Persona.ID, session: BrowserSession) throws -> Tab {
        var opened: (any EngineWebContents)?
        host.openTab(url, in: engine, persona: persona, window: nil, active: false, index: nil) { opened = $0 }
        let contents = try #require(opened)
        return try #require(session.tabs.first { $0.webContents === contents })
    }

    /// Opens a tab from the page of `tab`, as `window.open` does, and returns it.
    private func popup(from tab: Tab, at url: URL, disposition: EngineNavigationDisposition = .newBackgroundTab, in session: BrowserSession) throws -> Tab {
        let contents = PageDouble(url: url, engine: tab.engineKind)
        tab.webContents(tab.webContents, didCreateNewWebContents: contents, targetURL: url, disposition: disposition)
        return try #require(session.tabs.first { $0.webContents === contents })
    }

    /// Starts a download from the tab's page through the session, as the engine asks for its file's name.
    private func download(from tab: Tab, in session: BrowserSession) -> DownloadDouble {
        let downloads = session.runtime(for: tab.engineKind, in: tab.personaID)!.context.downloads
        let item = DownloadDouble(webContents: tab.webContents)
        session.downloads(downloads, determineFilenameFor: item, defaultFilename: "a.bin") { _ in item.isDecided = true }
        return item
    }

    /// An extension's tab whose address turns out to be a file downloads nothing, as a restored tab does not fetch its file again, while the user's own tab downloads it; the extension's tab's page asks with a card before its first download, and an act in the page lets the next one through.
    @Test func aTabThatAnExtensionOpensDownloadsNothingWithoutTheUser() throws {
        try withSession { session, host, persona in
            let onFile = try openTab(file, in: .chromium, with: host, persona: persona, session: session)
            #expect(onFile.pageDownloads.isHeldUntilUserActs)
            #expect(!onFile.webContents(onFile.webContents, shouldDownload: file, hasPage: false))
            let space = try #require(session.spaces.first)
            let own = session.openTab(url: file, in: space.id, select: false, engine: .chromium)
            #expect(own.webContents(own.webContents, shouldDownload: file, hasPage: false))

            let page = URL(string: "https://example.org/files")!
            let onPage = try openTab(page, in: .webKit, with: host, persona: persona, session: session)
            onPage.webContents(onPage.webContents, didCommitDocumentAt: page)
            #expect(download(from: onPage, in: session).decision == .waiting)
            #expect(session.prompts.current(for: onPage.id)?.content.kind == .pageDownloads)
            onPage.userDidActInPage()
            #expect(!onPage.pageDownloads.isHeldUntilUserActs)
            #expect(download(from: onPage, in: session).decision == .allowed)
        }
    }

    /// The one tab of a small window that `windows.create` opens downloads no file at its address either, and its page asks before its first download.
    @Test func aSmallWindowThatAnExtensionOpensDownloadsNothingWithoutTheUser() throws {
        try withSession { session, host, persona in
            let offscreen = OffscreenSmallWindows(session)
            var windowID: UUID?
            host.openWindow(with: [file], in: .webKit, persona: persona, focused: true) { windowID = $0 }
            let window = try #require(session.windows.first { $0.id == windowID })
            let tab = try #require(window.selectedTab)
            #expect(window.kind == .small && tab.pageDownloads.isHeldUntilUserActs)
            #expect(!tab.webContents(tab.webContents, shouldDownload: file, hasPage: false))

            var pageWindowID: UUID?
            host.openWindow(with: [], in: .chromium, persona: persona, focused: true) { pageWindowID = $0 }
            let pageWindow = try #require(session.windows.first { $0.id == pageWindowID })
            let pageTab = try #require(pageWindow.selectedTab)
            pageTab.webContents(pageTab.webContents, didCommitDocumentAt: BrowserSession.newTabURL)
            #expect(download(from: pageTab, in: session).decision == .waiting)
            #expect(session.prompts.current(for: pageTab.id)?.content.kind == .pageDownloads)
            #expect(offscreen.windows.count == 2 && offscreen.windows.allSatisfy { $0.raises == 1 })
        }
    }

    /// A tab that a page of an extension's tab opens in the background before the user acts in that page downloads no file at its address, while one that the page opens after an act in it downloads its file as the page's download: the act lets one through, and the next file asks with a card over the page's tab.
    @Test func aTabThatAnExtensionsPageOpensDownloadsNothingWithoutTheUser() throws {
        try withSession { session, host, persona in
            let page = URL(string: "https://example.org/opener")!
            let opener = try openTab(page, in: .webKit, with: host, persona: persona, session: session)
            opener.webContents(opener.webContents, didCommitDocumentAt: page)
            let before = try popup(from: opener, at: file, in: session)
            #expect(before.pageDownloads.isHeldUntilUserActs)
            #expect(!before.webContents(before.webContents, shouldDownload: file, hasPage: false))
            opener.userDidActInPage()
            let after = try popup(from: opener, at: file, in: session)
            #expect(!after.pageDownloads.isHeldUntilUserActs)
            #expect(after.webContents(after.webContents, shouldDownload: file, hasPage: false))
            #expect(download(from: after, in: session).decision == .allowed)

            let next = try popup(from: opener, at: file, in: session)
            #expect(next.webContents(next.webContents, shouldDownload: file, hasPage: false))
            #expect(download(from: next, in: session).decision == .waiting)
            #expect(session.prompts.current(for: opener.id)?.content.kind == .pageDownloads)
            #expect(session.prompts.current(for: next.id) == nil)
        }
    }

    /// A tab that a page of an extension's tab opens in the window that shows the page, as the selected tab of a main window or in a small window of its own beside a small window, is held as the extension's too: its page asks before its first download.
    @Test func aTabThatAnExtensionsPageOpensInAWindowIsHeldToo() throws {
        try withSession { session, host, persona in
            let offscreen = OffscreenSmallWindows(session)
            let space = try #require(session.spaces.first)
            let main = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            let mainWindow = WindowSpy()
            main.nsWindow = mainWindow
            let page = URL(string: "https://example.org/opener")!
            let opener = try openTab(page, in: .webKit, with: host, persona: persona, session: session)
            main.selectTab(opener.id)
            let inMain = try popup(from: opener, at: page, disposition: .newForegroundTab, in: session)
            #expect(main.selectedTab === inMain && inMain.pageDownloads.isHeldUntilUserActs)
            inMain.webContents(inMain.webContents, didCommitDocumentAt: page)
            #expect(download(from: inMain, in: session).decision == .waiting)
            #expect(session.prompts.current(for: inMain.id)?.content.kind == .pageDownloads)

            var windowID: UUID?
            host.openWindow(with: [page], in: .webKit, persona: persona, focused: true) { windowID = $0 }
            let small = try #require(session.windows.first { $0.id == windowID })
            let smallOpener = try #require(small.selectedTab)
            let inSmall = try popup(from: smallOpener, at: page, disposition: .newForegroundTab, in: session)
            #expect(inSmall.isInSmallWindow && inSmall !== smallOpener && inSmall.pageDownloads.isHeldUntilUserActs)
            inSmall.webContents(inSmall.webContents, didCommitDocumentAt: page)
            #expect(download(from: inSmall, in: session).decision == .waiting)
            #expect(offscreen.windows.count == 2 && offscreen.windows.allSatisfy { $0.raises == 1 })
            #expect(mainWindow.raises == 0)
        }
    }

    /// A page of the user's own tab, as one where an extension's content script runs, downloads the files that it opens in new tabs through its own gate: its first goes through, the next waits for a card over the page's tab, and Don't Allow there refuses it and the ones after it.
    @Test func filesThatAPageOpensInNewTabsAreThatPagesDownloads() throws {
        try withSession { session, _, _ in
            let space = try #require(session.spaces.first)
            let page = URL(string: "https://example.org/files")!
            let opener = session.openTab(url: page, in: space.id, select: false, engine: .webKit)
            opener.webContents(opener.webContents, didCommitDocumentAt: page)
            let downloads = try (0..<3).map { _ in
                let tab = try popup(from: opener, at: file, in: session)
                #expect(tab.webContents(tab.webContents, shouldDownload: file, hasPage: false))
                return download(from: tab, in: session)
            }
            #expect(downloads.map(\.decision) == [.allowed, .waiting, .waiting])
            let card = try #require(session.prompts.current(for: opener.id))
            #expect(card.content.kind == .pageDownloads)
            session.prompts.answer(card.id, with: PromptAnswer(buttonID: "deny"))
            #expect(downloads.map(\.decision) == [.allowed, .refused, .refused])
            let later = try popup(from: opener, at: file, in: session)
            #expect(later.webContents(later.webContents, shouldDownload: file, hasPage: false))
            #expect(download(from: later, in: session).decision == .refused)
        }
    }
}

/// A download that the page of `webContents` started, which the session admits, and what became of it.
private final class DownloadDouble: EngineDownloadItem {
    enum Decision: Equatable {
        /// The session went on to choose the file's destination.
        case allowed
        /// The session ended the download and removed it.
        case refused
        /// The download waits for the user's answer.
        case waiting
    }

    let sourceURL = URL(string: "https://example.org/a.bin")!
    let pageURL: URL? = nil
    let webContents: (any EngineWebContents)?
    var targetPath: URL?
    var state: EngineDownloadState = .inProgress
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Set once the session answers the engine's question for the file's name.
    var isDecided = false
    private var isRemoved = false

    var decision: Decision {
        guard isDecided else { return .waiting }
        return isRemoved ? .refused : .allowed
    }

    init(webContents: any EngineWebContents) {
        self.webContents = webContents
    }

    func pause() { state = .paused }
    func resume() { state = .inProgress }
    func cancel() { state = .cancelled }
    func remove() { isRemoved = true }
}
