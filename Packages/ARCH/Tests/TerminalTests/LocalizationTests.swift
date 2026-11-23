// The Terminal module's string catalog: its built bundle has Korean for the terminal window's title, menu, and alert.
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

    func testTerminalHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Terminal")
        XCTAssertEqual(strings["Terminal"], "터미널")
        XCTAssertEqual(strings["Close the terminal?"], "터미널을 닫겠습니까?")
        XCTAssertEqual(strings["Select All"], "모두 선택")
        XCTAssertEqual(strings["The shell could not start: %@"], "셸을 시작할 수 없습니다: %@")
    }
}
