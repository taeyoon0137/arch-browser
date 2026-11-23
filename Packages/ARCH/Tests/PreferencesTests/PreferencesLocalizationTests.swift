import Foundation
import XCTest

final class PreferencesLocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: PreferencesLocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testPreferencesHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Preferences")
        XCTAssertEqual(strings["General"], "일반")
        XCTAssertEqual(strings["Shortcuts"], "단축키")
        XCTAssertEqual(strings["Site Search"], "사이트 검색")
        XCTAssertEqual(strings["Providers"], "제공자")
        XCTAssertEqual(strings["After %lld Hours"], "%lld시간 후")
    }
}
