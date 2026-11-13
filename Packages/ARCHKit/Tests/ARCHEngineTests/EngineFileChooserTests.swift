// The rules both adapters apply to a page's file chooser: the accepted types they keep, the file types an open panel offers for them, the origins that name who asks, and what the page receives of the user's choice.
import ARCHEngine
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite struct EngineFileChooserTests {
    @Test func acceptedTypesKeepOnlyMIMETypesAndExtensionsInLowercase() {
        let request = EngineFileChooserRequest(mode: .openFile, acceptedTypes: [" Image/* ", ".PDF", "bogus", ".", "/", "text/", ".tar.gz", ""])
        #expect(request.acceptedTypes == ["image/*", ".pdf", ".tar.gz"])
    }

    @Test func eachAcceptedTypeMapsToItsFileType() {
        let request = EngineFileChooserRequest(mode: .openFiles, acceptedTypes: ["image/*", "video/*", "audio/*", "text/*", "application/pdf", ".png", ".PNG"])
        #expect(request.allowedContentTypes == [.image, .movie, .audio, .text, .pdf, .png])
    }

    /// A type the system does not declare would get a dynamic type that matches no file, so the panel offers every file and the page checks the choice.
    @Test func aTypeWithoutADeclaredFileTypeOffersEveryFile() {
        #expect(EngineFileChooserRequest(mode: .openFile).allowedContentTypes == nil)
        #expect(EngineFileChooserRequest(mode: .openFile, acceptedTypes: ["image/*", "application/x-arch-unknown"]).allowedContentTypes == nil)
        #expect(EngineFileChooserRequest(mode: .openFile, acceptedTypes: [".png", ".archunknown"]).allowedContentTypes == nil)
        #expect(EngineFileChooserRequest(mode: .openFile, acceptedTypes: ["font/*"]).allowedContentTypes == nil)
    }

    @Test func aChooserForOneItemReceivesOnlyTheFirstFile() {
        let files = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        #expect(EngineFileChooserRequest(mode: .openFiles).answer(from: files) == files)
        for mode in [EngineFileChooserRequest.Mode.openFile, .openFolder, .save] {
            #expect(EngineFileChooserRequest(mode: mode).answer(from: files) == [files[0]])
        }
    }

    @Test func onlyFileAddressesReachThePageAndNoneIsACancel() {
        let request = EngineFileChooserRequest(mode: .openFiles)
        #expect(request.answer(from: [URL(string: "https://example.com/a.txt")!, URL(fileURLWithPath: "/tmp/a.txt")]) == [URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(request.answer(from: [URL(string: "https://example.com/a.txt")!]) == nil)
        #expect(request.answer(from: []) == nil)
        #expect(request.answer(from: nil) == nil)
    }

    @Test func anEmptySuggestedNameIsNone() {
        #expect(EngineFileChooserRequest(mode: .save, suggestedName: "notes.txt").suggestedName == "notes.txt")
        #expect(EngineFileChooserRequest(mode: .save, suggestedName: "").suggestedName == nil)
    }

    @Test func onlyAChooserForFilesTakesSeveral() {
        #expect(EngineFileChooserRequest(mode: .openFiles).allowsMultipleSelection)
        for mode in [EngineFileChooserRequest.Mode.openFile, .openFolder, .save] {
            #expect(!EngineFileChooserRequest(mode: mode).allowsMultipleSelection)
        }
    }

    @Test func eachAddressKeepsOnlyItsOriginAndOneWithoutAHostNone() {
        let request = EngineFileChooserRequest(mode: .openFile, origin: URL(string: "https://user:secret@widget.example:8443/frame?q=1#x"), pageOrigin: URL(string: "https://news.example/story"))
        #expect(request.origin == URL(string: "https://widget.example:8443/"))
        #expect(request.pageOrigin == URL(string: "https://news.example/"))
        for address in ["about:blank", "data:text/html,a", "blob:https://news.example/1", "file:///tmp/a.html"] {
            #expect(EngineFileChooserRequest(mode: .openFile, origin: URL(string: address), pageOrigin: URL(string: address)) == EngineFileChooserRequest(mode: .openFile))
        }
    }
}
