// The History module's string catalog: its built bundle has Korean for the History window's text.
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

    func testHistoryHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "History")
        XCTAssertEqual(strings["History"], "방문 기록")
        XCTAssertEqual(strings["Clear History…"], "방문 기록 지우기…")
        XCTAssertEqual(strings["Open in %lld New Tabs"], "새 탭 %lld개에서 열기")
    }
}
