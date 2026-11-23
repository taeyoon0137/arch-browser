import Foundation
import XCTest

final class ExtensionsLocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: ExtensionsLocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testExtensionsHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Extensions")
        XCTAssertEqual(strings["Looking for native apps…"], "네이티브 앱 찾는 중…")
        XCTAssertEqual(strings["No engine on this Mac runs web extensions."], "이 Mac에는 웹 확장 프로그램을 실행하는 엔진이 없습니다.")
        XCTAssertEqual(strings["Only the %@ version gets this access."], "%@ 버전에만 이 권한이 주어집니다.")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, as the module's own lookups pick it; `arguments` fill a format key.
func catalogText(_ key: String, _ arguments: CVarArg..., module: String = "Extensions") -> String {
    let products = Bundle(for: ExtensionsLocalizationTests.self).bundleURL.deletingLastPathComponent()
    let bundle = Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")) ?? .main
    let text = bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
