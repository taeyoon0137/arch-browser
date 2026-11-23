// A download the user asks for in a tab, with Download Image, Download Linked File, or File ▸ Save Page As…, goes on outside the page's download gate (`Tab.download(_:savingPage:)`): also after the user refused the page's downloads, matched by the address the user asked for, before or after a redirect, so that the page's own download cannot use the user's up first. A request ends when the engine asks for its file's name or the tab commits another document. The tests answer the engine's question as the session does and open no panel: without a row for the download, the session answers at once.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct UserDownloadRequestTests {
    private let page = URL(string: "https://example.org/")!
    private let image = URL(string: "https://example.org/photo.jpg")!

    private func withTab(_ check: (BrowserSession, Tab) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchUserDownloads-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        defer { for window in session.windows { session.windowWillClose(window) } }
        let space = try #require(session.spaces.first)
        let tab = session.openTab(url: page, in: space.id, select: false, engine: .webKit)
        tab.webContents(tab.webContents, didCommitDocumentAt: page)
        try check(session, tab)
    }

    /// Asks the session for the file's name as the engine does once the download has started.
    private func download(_ item: RequestedDownload, from tab: Tab, in session: BrowserSession) -> RequestedDownload {
        let downloads = session.runtime(for: tab.engineKind, in: tab.personaID)!.context.downloads
        session.downloads(downloads, determineFilenameFor: item, defaultFilename: "file") { _ in item.isDecided = true }
        return item
    }

    /// The page uses its first download, then the user answers Don't Allow on the card for its second.
    private func refusePageDownloads(of tab: Tab, in session: BrowserSession) {
        #expect(download(RequestedDownload(tab.webContents, at: page), from: tab, in: session).decision == .allowed)
        #expect(download(RequestedDownload(tab.webContents, at: page), from: tab, in: session).decision == .waiting)
        tab.pageDownloads.answer(false).forEach { $0(false) }
    }

    @Test func theUsersDownloadGoesOnAfterThePagesDownloadsWereRefused() throws {
        try withTab { session, tab in
            refusePageDownloads(of: tab, in: session)
            #expect(download(RequestedDownload(tab.webContents, at: page), from: tab, in: session).decision == .refused)
            tab.download(image, savingPage: false)
            #expect(download(RequestedDownload(tab.webContents, at: image), from: tab, in: session).decision == .allowed)
            // One request admits one download.
            #expect(download(RequestedDownload(tab.webContents, at: image), from: tab, in: session).decision == .refused)
        }
    }

    @Test func thePageCannotUseTheUsersRequestFirst() throws {
        try withTab { session, tab in
            #expect(download(RequestedDownload(tab.webContents, at: page), from: tab, in: session).decision == .allowed)
            tab.download(image, savingPage: false)
            // The page's own download, started before the user's reached the engine, asks with a card.
            #expect(download(RequestedDownload(tab.webContents, at: page), from: tab, in: session).decision == .waiting)
            #expect(download(RequestedDownload(tab.webContents, at: image), from: tab, in: session).decision == .allowed)
        }
    }

    @Test func aRedirectedDownloadMatchesTheAddressTheUserAskedFor() throws {
        try withTab { session, tab in
            refusePageDownloads(of: tab, in: session)
            tab.download(page, savingPage: true)
            let signIn = URL(string: "https://login.example.org/")!
            #expect(download(RequestedDownload(tab.webContents, at: signIn, requestedAt: page), from: tab, in: session).decision == .allowed)
        }
    }

    @Test func anotherDocumentEndsTheRequest() throws {
        try withTab { session, tab in
            refusePageDownloads(of: tab, in: session)
            tab.download(image, savingPage: false)
            tab.webContents(tab.webContents, didCommitDocumentAt: page)
            // The same site keeps the refusal.
            #expect(download(RequestedDownload(tab.webContents, at: image), from: tab, in: session).decision == .refused)
        }
    }
}

/// A download that the session admits, with the address the engine reports and the one it was requested at.
private final class RequestedDownload: EngineDownloadItem {
    enum Decision: Equatable {
        case allowed
        case refused
        case waiting
    }

    let sourceURL: URL
    let requestURL: URL
    let pageURL: URL? = nil
    let webContents: (any EngineWebContents)?
    var targetPath: URL?
    var state: EngineDownloadState = .inProgress
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var isDecided = false
    private var isRemoved = false

    var decision: Decision {
        guard isDecided else { return .waiting }
        return isRemoved ? .refused : .allowed
    }

    init(_ webContents: any EngineWebContents, at url: URL, requestedAt requestURL: URL? = nil) {
        self.webContents = webContents
        sourceURL = url
        self.requestURL = requestURL ?? url
    }

    func pause() { state = .paused }
    func resume() { state = .inProgress }
    func cancel() { state = .cancelled }
    func remove() { isRemoved = true }
}
