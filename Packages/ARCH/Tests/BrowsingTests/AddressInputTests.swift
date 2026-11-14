// How the palette and dropped text read an address: a URL with a host as typed, a file URL as typed, an address on this Mac as http, a dotted host as https, and other text as no address, which the palette searches the web for.
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

    /// `localhost:3000` parses as a URL whose scheme is `localhost`, and `localhost` has no dot, yet both name a server on this Mac, which they reach over http.
    @Test func anAddressOnThisMacLoadsOverHTTP() {
        let addresses = ["localhost:3000": "http://localhost:3000", "localhost": "http://localhost", "localhost:8080/api": "http://localhost:8080/api",
                         "[::1]:8080": "http://[::1]:8080", "127.0.0.1:5000": "http://127.0.0.1:5000", "myapp.localhost:3000": "http://myapp.localhost:3000"]
        for (input, address) in addresses {
            #expect(BrowserSession.url(forInput: input)?.absoluteString == address, "\(input)")
        }
        #expect(BrowserSession.url(forInput: "[fe80::1]:8080")?.absoluteString == "https://[fe80::1]:8080")
    }

    @Test func otherTextIsNoAddress() {
        #expect(BrowserSession.url(forInput: "hello") == nil)
        #expect(BrowserSession.url(forInput: "example search") == nil)
        // A single name with a number after a colon reads as a search, not as a host and port.
        #expect(BrowserSession.url(forInput: "python:3") == nil)
    }

    @Test func thePaletteLoadsADroppedFilesAddressInsteadOfSearchingForIt() throws {
        let file = URL(fileURLWithPath: "/Users/someone/Tax Docs/2025.pdf")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAddressInputTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(BrowserSession.destination(forInput: file.absoluteString, siteSearch: SiteSearchStore(directory: folder)) == file)
    }
}

/// A tab opened without an address, as at a launch without tabs or for an extension's `tabs.create({})`, loads the chosen search engine's home page rather than another engine's.
@Suite struct NewTabPageTests {
    @Test func eachSearchEngineOpensItsOwnHomePage() {
        for engine in SearchEngine.allCases {
            #expect(engine.homeURL.host == engine.resultsURL.host, "\(engine)")
        }
        #expect(BrowserSession.newTabURL == SearchEngine.current.homeURL)
    }
}
