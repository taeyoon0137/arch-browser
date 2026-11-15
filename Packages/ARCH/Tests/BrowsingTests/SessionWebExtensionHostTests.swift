// The session's side of the tabs and windows that web extensions open (`SessionWebExtensionHost`, `docs/plugins.md`, Web extensions as plugins), as for a plugin's tabs: a tab that `tabs.create` opens, a small window's tab that `windows.create` opens, and a tab that a page of either opens before the user acts in it download no file that their address points at, and their pages' downloads ask with a card over the tab until the user acts in them.
import AppKit
import ARCHEngine
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
        try check(session, session.webExtensionHost, persona)
    }

    /// Opens a tab for an extension as `tabs.create` does and returns it.
    private func openTab(_ url: URL?, in engine: EngineKind, with host: SessionWebExtensionHost, persona: Persona.ID, session: BrowserSession) throws -> Tab {
        var opened: (any EngineWebContents)?
        host.openTab(url, in: engine, persona: persona, window: nil, active: false, index: nil) { opened = $0 }
        let contents = try #require(opened)
        return try #require(session.tabs.first { $0.webContents === contents })
    }

    /// Starts a download from the tab's page through the session and says whether it went on at once.
    private func download(from tab: Tab, in session: BrowserSession) -> Bool {
        let downloads = session.runtime(for: tab.engineKind, in: tab.personaID).context.downloads
        var decided = false
        session.downloads(downloads, determineFilenameFor: DownloadDouble(webContents: tab.webContents), defaultFilename: "a.bin") { _ in decided = true }
        return decided
    }

    /// An extension's tab whose address turns out to be a file downloads nothing, as a restored tab does not fetch its file again, while the user's own tab downloads it; the extension's tab's page asks with a card before its first download, and a click in the page lets the next one through.
    @Test func aTabThatAnExtensionOpensDownloadsNothingWithoutTheUser() throws {
        try withSession { session, host, persona in
            let onFile = try openTab(file, in: .chromium, with: host, persona: persona, session: session)
            #expect(onFile.pageDownloads.isOpenedByPlugin)
            #expect(!onFile.webContents(onFile.webContents, shouldDownload: file, hasPage: false))
            let space = try #require(session.spaces.first)
            let own = session.openTab(url: file, in: space.id, select: false, engine: .chromium)
            #expect(own.webContents(own.webContents, shouldDownload: file, hasPage: false))

            let page = URL(string: "https://example.org/files")!
            let onPage = try openTab(page, in: .webKit, with: host, persona: persona, session: session)
            onPage.webContents(onPage.webContents, didCommitDocumentAt: page)
            #expect(!download(from: onPage, in: session))
            #expect(session.prompts.current(for: onPage.id)?.content.kind == .pageDownloads)
            onPage.userDidClickInPage()
            #expect(!onPage.pageDownloads.isOpenedByPlugin)
            #expect(download(from: onPage, in: session))
        }
    }

    /// The one tab of a small window that `windows.create` opens downloads no file at its address either, and its page asks before its first download.
    @Test func aSmallWindowThatAnExtensionOpensDownloadsNothingWithoutTheUser() throws {
        // The host reads the key window, which needs the application object; no window shows.
        _ = NSApplication.shared
        try withSession { session, host, persona in
            var windowID: UUID?
            host.openWindow(with: [file], in: .webKit, persona: persona, focused: true) { windowID = $0 }
            let window = try #require(session.windows.first { $0.id == windowID })
            defer { session.windowWillClose(window) }
            let tab = try #require(window.selectedTab)
            #expect(window.kind == .small && tab.pageDownloads.isOpenedByPlugin)
            #expect(!tab.webContents(tab.webContents, shouldDownload: file, hasPage: false))

            var pageWindowID: UUID?
            host.openWindow(with: [], in: .chromium, persona: persona, focused: true) { pageWindowID = $0 }
            let pageWindow = try #require(session.windows.first { $0.id == pageWindowID })
            defer { session.windowWillClose(pageWindow) }
            let pageTab = try #require(pageWindow.selectedTab)
            pageTab.webContents(pageTab.webContents, didCommitDocumentAt: BrowserSession.newTabURL)
            #expect(!download(from: pageTab, in: session))
            #expect(session.prompts.current(for: pageTab.id)?.content.kind == .pageDownloads)
        }
    }

    /// A tab that a page of an extension's tab opens before the user clicks in that page downloads no file at its address, while one that the page opens after a click downloads it, as a page of the user's own tab does.
    @Test func aTabThatAnExtensionsPageOpensDownloadsNothingWithoutTheUser() throws {
        try withSession { session, host, persona in
            let page = URL(string: "https://example.org/opener")!
            let opener = try openTab(page, in: .webKit, with: host, persona: persona, session: session)
            opener.webContents(opener.webContents, didCommitDocumentAt: page)
            @MainActor func popup(from tab: Tab) throws -> Tab {
                let contents = PageDouble(url: file)
                tab.webContents(tab.webContents, didCreateNewWebContents: contents, targetURL: file, disposition: .newBackgroundTab)
                return try #require(session.tabs.first { $0.webContents === contents })
            }
            let before = try popup(from: opener)
            #expect(before.pageDownloads.isOpenedByPlugin)
            #expect(!before.webContents(before.webContents, shouldDownload: file, hasPage: false))
            opener.userDidClickInPage()
            let after = try popup(from: opener)
            #expect(!after.pageDownloads.isOpenedByPlugin)
            #expect(after.webContents(after.webContents, shouldDownload: file, hasPage: false))
        }
    }
}

/// A download that the page of `webContents` started, which the session admits.
private final class DownloadDouble: EngineDownloadItem {
    let sourceURL = URL(string: "https://example.org/a.bin")!
    let pageURL: URL? = nil
    let webContents: (any EngineWebContents)?
    var targetPath: URL?
    var state: EngineDownloadState = .inProgress
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    init(webContents: any EngineWebContents) {
        self.webContents = webContents
    }

    func pause() { state = .paused }
    func resume() { state = .inProgress }
    func cancel() { state = .cancelled }
    func remove() {}
}
