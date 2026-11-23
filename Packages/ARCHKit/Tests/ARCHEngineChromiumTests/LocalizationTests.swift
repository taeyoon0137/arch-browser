// The ARCHEngineChromium module's string catalog: its built bundle has Korean for the Chromium adapter's context menu items and package messages, and the other tests compare those with the catalog's text in the language the tests run in.
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    static func moduleBundle() -> Bundle? {
        let products = Bundle(for: LocalizationTests.self).bundleURL.deletingLastPathComponent()
        return Bundle(url: products.appendingPathComponent("ArchBrowser_ARCHEngineChromium.bundle"))
    }

    private func koreanStrings() throws -> [String: String] {
        let bundle = try XCTUnwrap(Self.moduleBundle())
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testARCHEngineChromiumHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings()
        XCTAssertEqual(strings["Cut"], "오려두기")
        XCTAssertEqual(strings["Ignore Spelling"], "철자 무시")
        XCTAssertEqual(strings["It names %@ as %@, which is not in the package."], "%2$@: %1$@ 파일이 패키지에 없습니다.")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, which the module's code picks too, filled with `arguments` as the code fills the key's format specifiers.
func catalogText(_ key: String, _ arguments: CVarArg...) -> String {
    let format = LocalizationTests.moduleBundle()?.localizedString(forKey: key, value: nil, table: nil) ?? key
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
