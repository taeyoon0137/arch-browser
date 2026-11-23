// The session's side of the tabs and windows that web extensions open (`SessionWebExtensionHost`, `docs/plugins.md`, Web extensions as plugins), as a tab that the user opens, unlike a script plugin's tabs, as other browsers do: a tab that `tabs.create` opens, a small window's tab that `windows.create` opens, and a tab that a page of either opens download the file that their address points at as a normal download, and their pages' downloads go through the tab's gate. A tab that a page opens straight onto a file downloads as that page's download, so a page opens no file after file without asking. The small windows' AppKit windows are never ordered in.
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

    /// An extension's tab whose address turns out to be a file downloads it as a normal download, as a tab that the user opens does and as other browsers download what an extension's tabs open, and the tab's page downloads through its own gate, whose first goes on without asking and whose next asks with a card.
    @Test func aTabThatAnExtensionOpensDownloadsAsTheUsersTabDoes() throws {
        try withSession { session, host, persona in
            let onFile = try openTab(file, in: .chromium, with: host, persona: persona, session: session)
            #expect(!onFile.pageDownloads.isHeldUntilUserActs)
            #expect(onFile.webContents(onFile.webContents, shouldDownload: file, hasPage: false))
            #expect(download(from: onFile, in: session).decision == .allowed)

            let page = URL(string: "https://example.org/files")!
            let onPage = try openTab(page, in: .webKit, with: host, persona: persona, session: session)
            onPage.webContents(onPage.webContents, didCommitDocumentAt: page)
            #expect(download(from: onPage, in: session).decision == .allowed)
            #expect(download(from: onPage, in: session).decision == .waiting)
            #expect(session.prompts.current(for: onPage.id)?.content.kind == .pageDownloads)
        }
    }

    /// The one tab of a small window that `windows.create` opens downloads the file at its address too.
    @Test func aSmallWindowThatAnExtensionOpensDownloadsAsTheUsersTabDoes() throws {
        try withSession { session, host, persona in
            let offscreen = OffscreenSmallWindows(session)
            var windowID: UUID?
            host.openWindow(with: [file], in: .webKit, persona: persona, focused: true) { windowID = $0 }
            let window = try #require(session.windows.first { $0.id == windowID })
            let tab = try #require(window.selectedTab)
            #expect(window.kind == .small && !tab.pageDownloads.isHeldUntilUserActs)
            #expect(tab.webContents(tab.webContents, shouldDownload: file, hasPage: false))
            #expect(offscreen.windows.count == 1 && offscreen.windows.allSatisfy { $0.raises == 1 })
        }
    }

    /// A tab that a page of an extension's tab opens onto a file, as a link of the extension's popup or options page does, downloads it as that page's download: the first goes through, and the next asks with a card over the page's tab.
    @Test func aFileThatAnExtensionsPageOpensDownloadsAsThatPagesDownload() throws {
        try withSession { session, host, persona in
            let page = URL(string: "https://example.org/opener")!
            let opener = try openTab(page, in: .webKit, with: host, persona: persona, session: session)
            opener.webContents(opener.webContents, didCommitDocumentAt: page)
            let first = try popup(from: opener, at: file, in: session)
            #expect(!first.pageDownloads.isHeldUntilUserActs)
            #expect(first.webContents(first.webContents, shouldDownload: file, hasPage: false))
            #expect(download(from: first, in: session).decision == .allowed)
            let next = try popup(from: opener, at: file, in: session)
            #expect(next.webContents(next.webContents, shouldDownload: file, hasPage: false))
            #expect(download(from: next, in: session).decision == .waiting)
            #expect(session.prompts.current(for: opener.id)?.content.kind == .pageDownloads)
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
