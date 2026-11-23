// The ARCHEngine module's string catalog: its built bundle has Korean for the text items Arch adds to page context menus, and the other tests compare those items' titles with the catalog's text in the language the tests run in.
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    static func moduleBundle() -> Bundle? {
        let products = Bundle(for: LocalizationTests.self).bundleURL.deletingLastPathComponent()
        return Bundle(url: products.appendingPathComponent("ArchBrowser_ARCHEngine.bundle"))
    }

    private func koreanStrings() throws -> [String: String] {
        let bundle = try XCTUnwrap(Self.moduleBundle())
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testARCHEngineHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings()
        XCTAssertEqual(strings["Look Up %@"], "%@ 찾아보기")
        XCTAssertEqual(strings["Spelling and Grammar"], "철자 및 문법")
        XCTAssertEqual(strings["Speech"], "말하기")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, which the module's code picks too, filled with `arguments` as the code fills the key's format specifiers.
func catalogText(_ key: String, _ arguments: CVarArg...) -> String {
    let format = LocalizationTests.moduleBundle()?.localizedString(forKey: key, value: nil, table: nil) ?? key
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
