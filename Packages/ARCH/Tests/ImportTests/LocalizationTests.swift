// The Import module's string catalog: its built bundle has Korean for the sheet's and the summary's text, and the other tests compare the text the module shows with the catalog's text in the language the tests run in.
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    static func moduleBundle() -> Bundle? {
        let products = Bundle(for: LocalizationTests.self).bundleURL.deletingLastPathComponent()
        return Bundle(url: products.appendingPathComponent("ArchBrowser_Import.bundle"))
    }

    private func koreanStrings() throws -> [String: String] {
        let bundle = try XCTUnwrap(Self.moduleBundle())
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testImportHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings()
        XCTAssertEqual(strings["Import from Browser"], "브라우저에서 가져오기")
        XCTAssertEqual(strings["Other Bookmarks"], "기타 북마크")
        XCTAssertEqual(strings["%@ pinned tabs"], "고정된 탭 %@개")
        XCTAssertEqual(strings["Added %@ and %@."], "%1$@ 및 %2$@를 추가했습니다.")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, which the module's code picks too, filled with `arguments` as the code fills the key's format specifiers.
func catalogText(_ key: String, _ arguments: CVarArg...) -> String {
    let format = LocalizationTests.moduleBundle()?.localizedString(forKey: key, value: nil, table: nil) ?? key
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
