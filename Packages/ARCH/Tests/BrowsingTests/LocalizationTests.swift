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

    func testBrowsingHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Browsing")
        XCTAssertEqual(strings["New Tab"], "새 탭")
        XCTAssertEqual(strings["Hide Sidebar"], "사이드바 가리기")
        XCTAssertEqual(strings["Open Link in New Tab"], "새 탭에서 링크 열기")
        XCTAssertEqual(strings["%lld of %lld"], "%1$lld/%2$lld")
    }
}
