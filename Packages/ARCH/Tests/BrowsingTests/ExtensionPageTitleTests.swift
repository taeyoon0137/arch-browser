// The title that the sidebar's rows, the window's title, and the tab switcher show for a web extension's own page (`Tab.shownTitle`): the extension's name in place of a page title that only repeats the address, as WebKit and Chromium report a page without a title, while a page's own title, the user's name, and a hook's name stay. Tabs run on stand-ins without a session, with the extension's name from a callback as the session gives it.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

/// The identifier of the extension named Reader, and the address of its options page on WebKit.
private let identifier = "abcdefghijklmnopabcdefghijklmnop"
private let options = URL(string: "webkit-extension://\(identifier)/options.html")!

@MainActor
@Suite struct ExtensionPageTitleTests {
    /// A tab at `url` whose page reports `title`, in which the extension with the identifier is named Reader.
    private func tab(at url: URL = options, title: String) -> Tab {
        let tab = Tab(id: UUID(), webContents: UnloadedWebContents(url: url, title: title, engine: .webKit, state: nil), spaceID: UUID(), isPinned: false, personaID: UUID())
        tab.extensionName = { $0.scheme != "https" && $0.host == identifier ? "Reader" : nil }
        return tab
    }

    @Test func anExtensionsPageWithoutATitleIsNamedByTheExtension() {
        // WebKit reports an empty title, for which the page's title is its host, the identifier.
        let untitled = tab(title: "")
        #expect(untitled.displayTitle == identifier && untitled.shownTitle == "Reader")
        // Chromium reports the address as the title of a page without one, without the `/` of a bare host and with spaces unescaped.
        let chromium = URL(string: "chrome-extension://\(identifier)/options.html")!
        #expect(tab(at: chromium, title: chromium.absoluteString).shownTitle == "Reader")
        #expect(tab(at: URL(string: "chrome-extension://\(identifier)/")!, title: "chrome-extension://\(identifier)").shownTitle == "Reader")
        #expect(tab(at: URL(string: "chrome-extension://\(identifier)/my%20options.html")!, title: "chrome-extension://\(identifier)/my options.html").shownTitle == "Reader")
        #expect(tab(title: identifier).shownTitle == "Reader")
    }

    @Test func aTitleOrANameOfTheTabsOwnStays() {
        #expect(tab(title: "Reader Options").shownTitle == "Reader Options")
        let named = tab(title: "")
        named.customTitle = "Mine"
        #expect(named.shownTitle == "Mine")
        let suggested = tab(title: "")
        suggested.suggestedTitle = SuggestedTitle(title: "From a hook", url: options)
        #expect(suggested.shownTitle == "From a hook")
        // A name the user turned down leaves the page's title, which the extension's name stands in for.
        suggested.suggestedTitle = SuggestedTitle(title: nil, url: options)
        #expect(suggested.shownTitle == "Reader")
    }

    @Test func otherPagesKeepTheirTitles() {
        // A web page on a host of that name, a page without an extension's name, and a tab without the session's callback keep `displayTitle`.
        #expect(tab(at: URL(string: "https://\(identifier)/options.html")!, title: "").shownTitle == identifier)
        #expect(tab(at: URL(string: "webkit-extension://ponmlkjihgfedcbaponmlkjihgfedcba/options.html")!, title: "").shownTitle == "ponmlkjihgfedcbaponmlkjihgfedcba")
        let unwired = Tab(id: UUID(), webContents: UnloadedWebContents(url: options, title: "", engine: .chromium, state: nil), spaceID: nil, isPinned: false, personaID: UUID())
        #expect(unwired.shownTitle == unwired.displayTitle)
        #expect(!Tab.titleRepeatsAddress("Options", of: options) && !Tab.titleRepeatsAddress("webkit-extension://\(identifier)/other.html", of: options))
    }
}
