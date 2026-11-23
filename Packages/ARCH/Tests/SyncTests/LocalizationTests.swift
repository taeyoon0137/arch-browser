import Foundation
import XCTest

final class SyncLocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: SyncLocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testSyncHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Sync")
        XCTAssertEqual(strings["Sign in to iCloud in System Settings to sync."], "동기화하려면 시스템 설정에서 iCloud에 로그인하세요.")
        XCTAssertEqual(strings["iCloud is restricted on this Mac."], "이 Mac에서 iCloud가 제한되어 있습니다.")
        XCTAssertEqual(strings["A sync save failed (%lld)."], "동기화 저장에 실패했습니다(%lld).")
        XCTAssertEqual(strings["Personal"], "개인")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, as the module's own lookups pick it; `arguments` fill a format key.
func catalogText(_ key: String, _ arguments: CVarArg..., module: String = "Sync") -> String {
    let products = Bundle(for: SyncLocalizationTests.self).bundleURL.deletingLastPathComponent()
    let bundle = Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")) ?? .main
    let text = bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
