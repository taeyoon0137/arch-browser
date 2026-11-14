import AppKit
import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@MainActor @Suite struct PagePreviewTests {
    private func withSession(_ body: (BrowserSession, SessionTestEngine, BrowserWindowModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = EngineRegistry(defaults: defaults)
        let chromium = SessionTestEngine(kind: .chromium)
        registry.register(chromium)
        registry.register(SessionTestEngine(kind: .webKit))
        registry.defaultKind = .chromium
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        try body(session, chromium, window)
        #expect(session.windows.isEmpty)
    }

    @Test func aPreviewIsReusedOnlyForTheSameAddressPersonaAndRequestedEngine() throws {
        try withSession { session, chromium, window in
            let url = URL(string: "about:blank#shared")!
            let favorite = Favorite(url: url, title: "Shared", personaID: window.personaID)
            window.previewFavorite(favorite)
            let first = try #require(window.preview)
            window.previewFavorite(favorite)
            #expect(window.preview === first)

            let other = session.addPersona(named: "Work")
            let space = try #require(session.spaces.first { $0.resolvedPersonaID == other.id })
            let selected = session.openTab(url: URL(string: "about:blank#selected"), in: space.id, select: false, engine: .webKit)
            window.switchToSpace(space.id)
            #expect(window.selectedTab === selected)
            chromium.unavailableStorageID = other.id
            let otherFavorite = Favorite(url: url, title: "Shared", personaID: other.id)
            window.previewFavorite(otherFavorite)
            let second = try #require(window.preview)
            #expect(second !== first && second.personaID == other.id)
            #expect(second.webContents.engineKind == .webKit)
            window.previewFavorite(otherFavorite)
            #expect(window.preview === second)
            window.showPreview(of: url, engine: .webKit, in: other.id)
            #expect(window.preview !== second)
            #expect(window.selectedTab === selected && session.tabs.count == 1)
        }
    }

    @Test(arguments: [false, true]) func aFavoritePreviewOpenedAsATabKeepsItsRequestedEngine(recovered: Bool) throws {
        try withSession { session, chromium, window in
            let persona = session.addPersona(named: "Work")
            let space = try #require(session.spaces.first { $0.resolvedPersonaID == persona.id })
            window.switchToSpace(space.id)
            chromium.unavailableStorageID = persona.id
            let url = URL(string: "about:blank#favorite")!
            window.previewFavorite(Favorite(url: url, title: "Saved", personaID: persona.id))
            let preview = try #require(window.preview)
            #expect(preview.webContents.engineKind == .webKit)
            if recovered { chromium.unavailableStorageID = nil }
            window.openPreviewInTab()
            let tab = try #require(window.selectedTab)
            #expect(window.preview == nil && tab.url == url && tab.personaID == persona.id)
            #expect(tab.engineKind == (recovered ? .chromium : .webKit))
            #expect(tab.preferredEngine == .chromium)
            try session.saveNow().get()
            #expect(SessionStore(directory: session.userDataDirectory, seal: .fixture).load()?.tabs.first?.engine == .chromium)
        }
    }

    @Test func escapeWaitsForThePageToFinishComposingText() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let monitor = PreviewDismissal.MonitorView()
        let page = ComposingPageView()
        window.contentView?.addSubview(monitor)
        window.contentView?.addSubview(page)
        #expect(window.makeFirstResponder(page) && !window.isVisible)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(monitor.closesOnEscape(escape))
        page.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!monitor.closesOnEscape(escape))
        page.unmarkText()
        #expect(monitor.closesOnEscape(escape))
        monitor.ignoresEscape = { true }
        #expect(!monitor.closesOnEscape(escape))
    }

    @Test func promotingAPreviewForItsPopupKeepsTheNativeOpenerAndPopupEngines() throws {
        try withSession { session, chromium, window in
            let persona = session.addPersona(named: "Work")
            let space = try #require(session.spaces.first { $0.resolvedPersonaID == persona.id })
            window.switchToSpace(space.id)
            chromium.unavailableStorageID = persona.id
            window.previewFavorite(Favorite(url: URL(string: "about:blank#opener")!, title: "Opener", personaID: persona.id))
            let preview = try #require(window.preview)
            let popup = PageStub(engine: .webKit, url: URL(string: "about:blank#popup"))
            chromium.unavailableStorageID = nil
            preview.webContents(preview.webContents, didCreateNewWebContents: popup, targetURL: popup.url, disposition: .newWindow)
            let opener = try #require(session.tabs.first { $0.webContents === preview.webContents })
            let opened = try #require(window.selectedTab)
            #expect(opener.engineKind == .webKit && opener.preferredEngine == .chromium)
            #expect(opened.webContents === popup && opened.opener === preview.webContents)
            #expect(opened.engineKind == .webKit && opened.preferredEngine == .webKit)
            #expect(opened.personaID == persona.id && opener.personaID == persona.id)
        }
    }
}

/// The field editor in an engine view adopts the input client protocol without being an NSTextView.
private final class ComposingPageView: NSView, NSTextInputClient {
    override var acceptsFirstResponder: Bool { true }
    private var markedText = ""
    func setMarkedText(_ text: Any, selectedRange: NSRange, replacementRange: NSRange) { markedText = text as? String ?? "" }
    func unmarkText() { markedText = "" }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange { NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: markedText.utf16.count) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func insertText(_ text: Any, replacementRange: NSRange) { unmarkText() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
