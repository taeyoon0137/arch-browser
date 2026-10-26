// Which address a link from another app or an `open location` script opens: http and https addresses as they came, text without a scheme as the address field reads it, with AppKit's escapes decoded or with the script's own, and nothing for other schemes or text that is no address. The URLs are built with `URL(string:)`, which escapes text as AppKit's delivery is assumed to.
import Foundation
import Testing
@testable import Browsing

@Suite struct OpenedAddressTests {
    private func opened(_ text: String) throws -> URL? {
        BrowserSession.webAddress(forOpened: try #require(URL(string: text)))
    }

    @Test func aWebAddressOpensAsItCame() throws {
        #expect(try opened("https://example.org/a?b=c")?.absoluteString == "https://example.org/a?b=c")
        #expect(try opened("http://example.org")?.absoluteString == "http://example.org")
        #expect(try opened("HTTPS://example.org")?.absoluteString == "HTTPS://example.org")
    }

    @Test func anAddressOfAnotherSchemeOpensNothing() throws {
        #expect(try opened("file:///etc/hosts") == nil)
        #expect(try opened("mailto:someone@example.org") == nil)
        #expect(try opened("data:text/html,hello") == nil)
    }

    @Test func textWithoutASchemeReadsAsTheAddressFieldReadsIt() throws {
        #expect(try opened("example.org")?.absoluteString == "https://example.org")
        #expect(try opened("example.org/한글")?.absoluteString == "https://example.org/%ED%95%9C%EA%B8%80")
        #expect(try opened("hello") == nil)
    }

    @Test func escapesTheScriptWroteStay() throws {
        #expect(try opened("example.org/search?q=a%20b")?.absoluteString == "https://example.org/search?q=a%20b")
    }

    @Test func textWithASpaceInItsHostOpensNothing() throws {
        // `URL(string:)` escapes the space, as AppKit does.
        #expect(try opened("example.org search") == nil)
    }
}
