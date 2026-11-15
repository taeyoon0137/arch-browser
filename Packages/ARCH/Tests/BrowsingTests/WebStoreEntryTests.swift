// The Web Store's entry points in tabs and the palette (`docs/web-store.md`, Entry points): the palette's rows for a store address, a bare identifier, and other text, with and without a store page in the selected tab, and the site settings popover's row for a store page with the extension installed or not, with the section's note for the row alone. Store pages are built from hosts that stand in for the store's, so this file names no store host.
@testable import Browsing
@testable import Extensions
import Foundation
import Testing

@Suite struct WebStoreEntryTests {
    private let id = String(repeating: "abcdefghijklmnop", count: 2)
    private let otherID = String(repeating: "ponmlkjihgfedcba", count: 2)
    /// Reads store pages on a host that stands in for the store's.
    private let reader = WebStoreReader(page: { WebStore.extensionID(in: $0, pageHosts: ["store.example"]) },
                                        text: { WebStore.extensionID(from: $0, pageHosts: ["store.example"]) })

    private func page(_ id: String) -> URL { URL(string: "https://store.example/detail/sample-name/\(id)")! }

    @Test func thePaletteOffersTheExtensionThatTheTextNames() {
        let other = URL(string: "https://example.org/")!
        // A store address, with or without `https://`, and a bare identifier in any case add Install from the Web Store.
        for text in [page(id).absoluteString, "store.example/detail/\(id)", id, " \(id.uppercased()) "] {
            #expect(PaletteWebStoreRows(text: text, pageURL: other, reader: reader) == PaletteWebStoreRows(typedExtension: id), "\(text)")
        }
        // Other text, an address of another host, and an identifier with a letter past `p` add nothing.
        for text in ["example.org", "install", "https://example.org/detail/\(id)", String(id.dropLast()) + "q", ""] {
            #expect(PaletteWebStoreRows(text: text, pageURL: other, reader: reader) == PaletteWebStoreRows(), "\(text)")
        }
        #expect(PaletteWebStoreRows.typedTitle == "Install from the Web Store\u{2026}")
    }

    @Test func aStorePageInTheSelectedTabOffersItsExtension() {
        // The page's own address, which the palette starts with when it edits the current address, and words that begin the row's name.
        for text in [page(id).absoluteString, id, "install", "Install Extension from", "install  extension from this page"] {
            #expect(PaletteWebStoreRows(text: text, pageURL: page(id), reader: reader) == PaletteWebStoreRows(pageExtension: id), "\(text)")
        }
        // Another extension's identifier gets its own row beside the page's, once the words do not begin the page row's name.
        #expect(PaletteWebStoreRows(text: otherID, pageURL: page(id), reader: reader) == PaletteWebStoreRows(typedExtension: otherID))
        // Other text, or a tab off a store page or without one, offers no page row.
        for (text, pageURL) in [("example.org", page(id)), ("install", URL(string: "https://example.org/")!), ("install", nil)] {
            #expect(PaletteWebStoreRows(text: text, pageURL: pageURL, reader: reader) == PaletteWebStoreRows(), "\(text)")
        }
        #expect(PaletteWebStoreRows.pageTitle == "Install Extension from This Page\u{2026}")
    }

    @Test func thePopoverRowInstallsOrNamesThePagesExtension() {
        let installed = { (asked: String) in asked == self.id ? "1Password" : nil }
        let row = WebStorePageRow(pageURL: page(id), installedName: installed, reader: reader)
        // The installed extension's row names it alone, as a label; the view adds Installed at the row's end.
        #expect(row == .installed("1Password") && row?.title == "1Password")
        let install = WebStorePageRow(pageURL: page(otherID), installedName: installed, reader: reader)
        #expect(install == .install(otherID) && install?.title == "Install This Extension\u{2026}")
        // The section's note for the row alone says what the row does, and for an installed extension where to manage it.
        #expect(install?.note == "Opens the extension\u{2019}s review in Settings before it installs.")
        #expect(row?.note == "Manage it for this Persona in Settings \u{25B8} Plugins.")
        // Pages that are not a store page's get no row.
        for url in [URL(string: "https://example.org/detail/sample-name/\(id)"), URL(string: "https://store.example/category/extensions"), nil] {
            #expect(WebStorePageRow(pageURL: url, installedName: installed, reader: reader) == nil, "\(String(describing: url))")
        }
    }
}
