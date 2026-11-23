import Foundation
import XCTest

final class AILocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: AILocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testAIHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "AI")
        XCTAssertEqual(strings["Fast"], "빠름")
        XCTAssertEqual(strings["The request was cancelled."], "요청이 취소되었습니다.")
        XCTAssertEqual(strings["%@ is limiting requests. Try again after %@."], "%1$@에서 요청을 제한하고 있습니다. %2$@ 이후에 다시 시도하세요.")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, as the module's own lookups pick it; `arguments` fill a format key.
func catalogText(_ key: String, _ arguments: CVarArg..., module: String = "AI") -> String {
    let products = Bundle(for: AILocalizationTests.self).bundleURL.deletingLastPathComponent()
    let bundle = Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")) ?? .main
    let text = bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
