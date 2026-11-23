import Foundation
import XCTest

final class PluginsLocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: PluginsLocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testPluginsHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Plugins")
        XCTAssertEqual(strings["Copy Page Address"], "페이지 주소 복사")
        XCTAssertEqual(strings["The plugin has stopped."], "플러그인이 중단되었습니다.")
        XCTAssertEqual(strings["%@ and %lld more"], "%1$@ 외 %2$lld개")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, as the module's own lookups pick it; `arguments` fill a format key.
func catalogText(_ key: String, _ arguments: CVarArg..., module: String = "Plugins") -> String {
    let products = Bundle(for: PluginsLocalizationTests.self).bundleURL.deletingLastPathComponent()
    let bundle = Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")) ?? .main
    let text = bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
