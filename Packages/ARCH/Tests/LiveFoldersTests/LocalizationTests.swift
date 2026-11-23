import Foundation
import XCTest

final class LiveFoldersLocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: LiveFoldersLocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testLiveFoldersHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "LiveFolders")
        XCTAssertEqual(strings["Pull Requests"], "풀 리퀘스트")
        XCTAssertEqual(strings["The Mac is offline."], "Mac이 오프라인 상태입니다.")
        XCTAssertEqual(strings["The server answered %lld (%@)."], "서버 응답: %lld(%@).")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, as the module's own lookups pick it; `arguments` fill a format key.
func catalogText(_ key: String, _ arguments: CVarArg..., module: String = "LiveFolders") -> String {
    let products = Bundle(for: LiveFoldersLocalizationTests.self).bundleURL.deletingLastPathComponent()
    let bundle = Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")) ?? .main
    let text = bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
