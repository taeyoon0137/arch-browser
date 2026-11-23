import Foundation
import XCTest

final class HooksLocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: HooksLocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testHooksHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Hooks")
        XCTAssertEqual(strings["Allow…"], "허용…")
        XCTAssertEqual(strings["When a new tab opens"], "새 탭이 열릴 때")
        XCTAssertEqual(strings["Limits: %lld seconds, %@, %@, %lld runs a day"], "제한: %1$lld초, %2$@, %3$@, 하루 %4$lld회 실행")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, as the module's own lookups pick it; `arguments` fill a format key.
func catalogText(_ key: String, _ arguments: CVarArg..., module: String = "Hooks") -> String {
    let products = Bundle(for: HooksLocalizationTests.self).bundleURL.deletingLastPathComponent()
    let bundle = Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")) ?? .main
    let text = bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
