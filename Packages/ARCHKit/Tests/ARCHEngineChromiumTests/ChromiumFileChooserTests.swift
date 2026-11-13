// The request the Chromium adapter makes of a file chooser that the bridge reports, which needs no engine: CEF's mode, the page's accepted types, and only the file name of a save chooser's default path. That a page's file input opens Arch's panel and receives the chosen files needs the engine and the app (`docs/plan.md`, regression check 70).
import ARCHEngine
import CEFBridge
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumFileChooserTests {
    @Test func eachOfCEFsModesBecomesTheRequestsMode() {
        let modes: [(ARCHCEFFileChooserMode, EngineFileChooserRequest.Mode)] = [(.open, .openFile), (.openMultiple, .openFiles), (.openFolder, .openFolder), (.save, .save)]
        for (cefMode, mode) in modes {
            #expect(ChromiumWebContents.fileChooserRequest(mode: cefMode, defaultPath: "", acceptedTypes: []).mode == mode)
        }
    }

    @Test func theRequestKeepsThePagesAcceptedTypes() {
        let request = ChromiumWebContents.fileChooserRequest(mode: .open, defaultPath: "", acceptedTypes: ["image/*", ".pdf", "application/json"])
        #expect(request.acceptedTypes == ["image/*", ".pdf", "application/json"])
    }

    /// CEF's default path can name a folder on the Mac, as a download's does; the panel gets only the name.
    @Test func aSaveChooserSuggestsOnlyTheDefaultPathsFileName() {
        #expect(ChromiumWebContents.fileChooserRequest(mode: .save, defaultPath: "/private/tmp/Downloads/report.pdf", acceptedTypes: []).suggestedName == "report.pdf")
        #expect(ChromiumWebContents.fileChooserRequest(mode: .save, defaultPath: "notes.txt", acceptedTypes: []).suggestedName == "notes.txt")
        #expect(ChromiumWebContents.fileChooserRequest(mode: .save, defaultPath: "", acceptedTypes: []).suggestedName == nil)
        #expect(ChromiumWebContents.fileChooserRequest(mode: .open, defaultPath: "/tmp/a.txt", acceptedTypes: []).suggestedName == nil)
    }
}
