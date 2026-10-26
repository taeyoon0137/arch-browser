// How the palette and dropped text read an address: a URL with a host as typed, a file URL as typed, a dotted host as https, and other text as no address, which the palette searches the web for.
import Foundation
import Testing
@testable import Browsing

@Suite struct AddressInputTests {
    @Test func aURLWithAHostLoadsAsTyped() {
        #expect(BrowserSession.url(forInput: "https://example.org/a?b=c")?.absoluteString == "https://example.org/a?b=c")
        #expect(BrowserSession.url(forInput: "  http://localhost:8080  ")?.absoluteString == "http://localhost:8080")
    }

    @Test func aFileURLLoadsAsTyped() {
        let file = URL(fileURLWithPath: "/Users/someone/Tax Docs/2025.pdf")
        #expect(BrowserSession.url(forInput: file.absoluteString) == file)
        #expect(BrowserSession.url(forInput: "FILE:///etc/hosts")?.isFileURL == true)
    }

    @Test func aDottedHostLoadsOverHTTPS() {
        #expect(BrowserSession.url(forInput: "example.org/path")?.absoluteString == "https://example.org/path")
    }

    @Test func otherTextIsNoAddress() {
        #expect(BrowserSession.url(forInput: "hello") == nil)
        #expect(BrowserSession.url(forInput: "example search") == nil)
    }

    @Test func thePaletteLoadsADroppedFilesAddressInsteadOfSearchingForIt() throws {
        let file = URL(fileURLWithPath: "/Users/someone/Tax Docs/2025.pdf")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAddressInputTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(BrowserSession.destination(forInput: file.absoluteString, siteSearch: SiteSearchStore(directory: folder)) == file)
    }
}
