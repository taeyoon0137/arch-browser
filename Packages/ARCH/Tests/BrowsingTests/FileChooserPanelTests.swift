// Arch's panel for a page's file chooser: an open panel for files or a folder with the page's accepted types, or a save panel with the suggested name, each with a message that names the page's site. Showing the panel as a sheet and the page receiving the files are checked from the bundle (`docs/plan.md`, regression check 70).
import AppKit
import ARCHEngine
import Testing
import UniformTypeIdentifiers
@testable import Browsing

@MainActor @Suite struct FileChooserPanelTests {
    @Test func aFileInputGetsAnOpenPanelForOneFileOfItsTypes() throws {
        let panel = try #require(FileChooserPanel.make(for: EngineFileChooserRequest(mode: .openFile, acceptedTypes: ["image/*", ".pdf"]), site: "example.com") as? NSOpenPanel)
        #expect(panel.canChooseFiles && !panel.canChooseDirectories && !panel.allowsMultipleSelection)
        #expect(panel.allowedContentTypes == [.image, .pdf])
        #expect(panel.message == "Choose a file for \u{201C}example.com\u{201D}.")
    }

    @Test func anInputForSeveralFilesOrAFolderGetsItsPanel() throws {
        let files = try #require(FileChooserPanel.make(for: EngineFileChooserRequest(mode: .openFiles), site: nil) as? NSOpenPanel)
        #expect(files.canChooseFiles && files.allowsMultipleSelection && files.allowedContentTypes.isEmpty)
        #expect(files.message == "Choose files for this page.")
        let folder = try #require(FileChooserPanel.make(for: EngineFileChooserRequest(mode: .openFolder), site: "example.com") as? NSOpenPanel)
        #expect(!folder.canChooseFiles && folder.canChooseDirectories && !folder.allowsMultipleSelection)
        #expect(folder.message?.hasSuffix("The page receives every file in it.") == true)
    }

    @Test func aSaveChooserGetsASavePanelWithTheSuggestedName() {
        let panel = FileChooserPanel.make(for: EngineFileChooserRequest(mode: .save, suggestedName: "report.pdf"), site: "example.com")
        #expect(!(panel is NSOpenPanel))
        #expect(panel.nameFieldStringValue == "report.pdf")
        #expect(panel.message == "Choose where \u{201C}example.com\u{201D} saves a file.")
    }
}
