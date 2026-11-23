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
        XCTAssertEqual(strings["System (default)"], "시스템 (기본값)")
    }

    /// The app shell has no test target of its own; `swift build` builds its bundle beside the others.
    func testAppShellHasKoreanForKeyStrings() throws {
        let products = Bundle(for: PreferencesLocalizationTests.self).bundleURL.deletingLastPathComponent()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: products.appendingPathComponent("ArchBrowser_Arch.bundle").path), "swift build has not built the app shell")
        let strings = try koreanStrings(of: "Arch")
        XCTAssertEqual(strings["New Tab"], "새 탭")
        XCTAssertEqual(strings["Settings\u{2026}"], "설정\u{2026}")
        XCTAssertEqual(strings["Show Sidebar"], "사이드바 보기")
        XCTAssertEqual(strings["About Arch"], "Arch에 관하여")
    }
}
