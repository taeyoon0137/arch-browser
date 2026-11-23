// The ARCHEngineWebKit module's string catalog: its built bundle has Korean for the item the WebKit adapter adds to a field's context menu.
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: LocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testARCHEngineWebKitHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "ARCHEngineWebKit")
        XCTAssertEqual(strings["Select All"], "모두 선택")
    }
}
