// The request the Chromium adapter makes of a file chooser that the bridge reports, which needs no engine: CEF's mode, the page's accepted types, only the file name of a save chooser's default path, and the page's origin from the main frame's committed address with no frame's. That a page's file input opens Arch's panel and receives the chosen files needs the engine and the app (`docs/plan.md`, regression check 70).
import ARCHEngine
import CEFBridge
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumFileChooserTests {
    @Test func eachOfCEFsModesBecomesTheRequestsMode() {
        let modes: [(ARCHCEFFileChooserMode, EngineFileChooserRequest.Mode)] = [(.open, .openFile), (.openMultiple, .openFiles), (.openFolder, .openFolder), (.save, .save)]
        for (cefMode, mode) in modes {
            #expect(ChromiumWebContents.fileChooserRequest(mode: cefMode, defaultPath: "", acceptedTypes: [], pageURL: "").mode == mode)
        }
    }

    @Test func theRequestKeepsThePagesAcceptedTypes() {
        let request = ChromiumWebContents.fileChooserRequest(mode: .open, defaultPath: "", acceptedTypes: ["image/*", ".pdf", "application/json"], pageURL: "")
        #expect(request.acceptedTypes == ["image/*", ".pdf", "application/json"])
    }

    /// CEF's default path can name a folder on the Mac, as a download's does; the panel gets only the name.
    @Test func aSaveChooserSuggestsOnlyTheDefaultPathsFileName() {
        #expect(ChromiumWebContents.fileChooserRequest(mode: .save, defaultPath: "/private/tmp/Downloads/report.pdf", acceptedTypes: [], pageURL: "").suggestedName == "report.pdf")
        #expect(ChromiumWebContents.fileChooserRequest(mode: .save, defaultPath: "notes.txt", acceptedTypes: [], pageURL: "").suggestedName == "notes.txt")
        #expect(ChromiumWebContents.fileChooserRequest(mode: .save, defaultPath: "", acceptedTypes: [], pageURL: "").suggestedName == nil)
        #expect(ChromiumWebContents.fileChooserRequest(mode: .open, defaultPath: "/tmp/a.txt", acceptedTypes: [], pageURL: "").suggestedName == nil)
    }

    /// CEF names no frame, so the request names only the page, from the address the bridge reads of the main frame's last commit.
    @Test func theRequestNamesThePageFromItsCommittedAddressAndNoFrame() {
        let request = ChromiumWebContents.fileChooserRequest(mode: .open, defaultPath: "", acceptedTypes: [], pageURL: "https://news.example/story?id=1#top")
        #expect(request.pageOrigin == URL(string: "https://news.example/"))
        #expect(request.origin == nil)
        #expect(ChromiumWebContents.fileChooserRequest(mode: .open, defaultPath: "", acceptedTypes: [], pageURL: "").pageOrigin == nil)
        #expect(ChromiumWebContents.fileChooserRequest(mode: .open, defaultPath: "", acceptedTypes: [], pageURL: "about:blank").pageOrigin == nil)
    }
}
