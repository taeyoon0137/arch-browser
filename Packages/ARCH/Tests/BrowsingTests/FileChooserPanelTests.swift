// Arch's panel for a page's file chooser: an open panel for files or a folder with the page's accepted types, or a save panel with the suggested name, each with a message that names who asks from the engine's report: the asking frame's site, with the page's when it differs, or the page's alone when the engine names no frame. Showing the panel as a sheet and the page receiving the files are checked from the bundle (`docs/plan.md`, regression check 85).
import AppKit
import ARCHEngine
import Testing
import UniformTypeIdentifiers
@testable import Browsing

@MainActor @Suite struct FileChooserPanelTests {
    private let site = URL(string: "https://example.com/")

    @Test func newDocumentsDismissOnlyTheirTabsFileChooserAndIgnoreItsLateAnswer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let source = session.openTab(url: site, in: space.id, select: false)
        let neighbor = session.openTab(url: site, in: space.id, select: false)
        let request = EngineFileChooserRequest(mode: .openFile, pageOrigin: site)
        var replies: [[URL]?] = [], otherReplies: [[URL]?] = []
        neighbor.webContents(neighbor.webContents, runFileChooser: request) { otherReplies.append($0) }
        let other = try #require(session.prompts.current(for: neighbor.id))
        // Both a different address and a reload at the same address commit a new document.
        let target = try #require(URL(string: "https://example.org/next"))
        for _ in 0..<2 {
            source.webContents(source.webContents, runFileChooser: request) { replies.append($0) }
            let chooser = try #require(session.prompts.current(for: source.id))
            let count = replies.count
            #expect(chooser.panel is NSOpenPanel && chooser.panel?.isVisible == false)
            source.webContents(source.webContents, didCommitDocumentAt: target)
            #expect(!session.prompts.contains(chooser.id))
            #expect(replies.count == count + 1 && replies.last == .some(nil))
            source.webContents(source.webContents, runFileChooser: request) { replies.append($0) }
            let fresh = try #require(session.prompts.current(for: source.id))
            session.prompts.answer(chooser.id, with: PromptAnswer(buttonID: "choose"))
            #expect(fresh.id != chooser.id && session.prompts.contains(fresh.id))
            #expect(otherReplies.isEmpty && session.prompts.contains(other.id))
            session.prompts.answer(fresh.id, with: PromptAnswer(buttonID: "cancel"))
        }
        session.prompts.answer(other.id, with: PromptAnswer(buttonID: "cancel"))
        #expect(otherReplies == [nil])
    }

    @Test func aFileInputGetsAnOpenPanelForOneFileOfItsTypes() throws {
        let panel = try #require(FileChooserPanel.make(for: EngineFileChooserRequest(mode: .openFile, acceptedTypes: ["image/*", ".pdf"], origin: site, pageOrigin: site)) as? NSOpenPanel)
        #expect(panel.canChooseFiles && !panel.canChooseDirectories && !panel.allowsMultipleSelection)
        #expect(panel.allowedContentTypes == [.image, .pdf])
        #expect(panel.message == "Choose a file for \u{201C}example.com\u{201D}.")
    }

    @Test func anInputForSeveralFilesOrAFolderGetsItsPanel() throws {
        let files = try #require(FileChooserPanel.make(for: EngineFileChooserRequest(mode: .openFiles)) as? NSOpenPanel)
        #expect(files.canChooseFiles && files.allowsMultipleSelection && files.allowedContentTypes.isEmpty)
        #expect(files.message == "Choose files for this page.")
        let folder = try #require(FileChooserPanel.make(for: EngineFileChooserRequest(mode: .openFolder, origin: site, pageOrigin: site)) as? NSOpenPanel)
        #expect(!folder.canChooseFiles && folder.canChooseDirectories && !folder.allowsMultipleSelection)
        #expect(folder.message?.hasSuffix("The page receives every file in it.") == true)
    }

    @Test func aSaveChooserGetsASavePanelWithTheSuggestedName() {
        let panel = FileChooserPanel.make(for: EngineFileChooserRequest(mode: .save, suggestedName: "report.pdf", pageOrigin: site))
        #expect(!(panel is NSOpenPanel))
        #expect(panel.nameFieldStringValue == "report.pdf")
        #expect(panel.message == "Choose where a page on \u{201C}example.com\u{201D} saves a file.")
    }

    /// A frame of another site inside the page is named with the page; a chooser without its frame, as Chromium reports one, names only the page as "a page on" it.
    @Test func theMessageNamesTheFrameThatAsksAndThePage() {
        let widget = URL(string: "https://widget.example/")
        #expect(FileChooserPanel.asker(of: EngineFileChooserRequest(mode: .openFile, origin: widget, pageOrigin: site)) == "\u{201C}widget.example\u{201D} in \u{201C}example.com\u{201D}")
        #expect(FileChooserPanel.asker(of: EngineFileChooserRequest(mode: .openFile, origin: widget)) == "\u{201C}widget.example\u{201D}")
        #expect(FileChooserPanel.asker(of: EngineFileChooserRequest(mode: .openFile, origin: URL(string: "http://example.com:8080/"), pageOrigin: site)) == "\u{201C}example.com\u{201D}")
        #expect(FileChooserPanel.asker(of: EngineFileChooserRequest(mode: .openFile, pageOrigin: site)) == "a page on \u{201C}example.com\u{201D}")
        #expect(FileChooserPanel.asker(of: EngineFileChooserRequest(mode: .openFile)) == "this page")
    }
}
