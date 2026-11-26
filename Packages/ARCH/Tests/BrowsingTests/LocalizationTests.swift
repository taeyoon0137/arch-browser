import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: LocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testBrowsingHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Browsing")
        XCTAssertEqual(strings["New Tab"], "새 탭")
        XCTAssertEqual(strings["Empty Folder"], "빈 폴더")
        XCTAssertEqual(strings["Sync Plugins"], "플러그인 동기화")
        XCTAssertEqual(strings["Sidebar"], "사이드바")
        XCTAssertEqual(strings["Settings"], "설정")
        XCTAssertEqual(strings["Site Rules"], "사이트 규칙")
        XCTAssertEqual(strings["Open Tabs from Other Macs"], "다른 Mac의 열린 탭")
        XCTAssertEqual(strings["Plugins"], "플러그인")
        XCTAssertEqual(strings["Install on this Mac"], "이 Mac에 설치")
        XCTAssertEqual(strings["Hide Sidebar"], "사이드바 가리기")
        XCTAssertEqual(strings["Open Link in New Tab"], "새 탭에서 링크 열기")
        XCTAssertEqual(strings["Chromium picture in picture scaling"], "Chromium 화면 속 화면 크기 조정")
        XCTAssertEqual(strings["%lld of %lld"], "%1$lld/%2$lld")
        XCTAssertEqual(strings["Show Tabs from Other Macs"], "다른 Mac의 탭 보기")
        XCTAssertEqual(strings["Hide Tabs from Other Macs"], "다른 Mac의 탭 가리기")
        XCTAssertEqual(strings["%@'s Tabs"], "%@의 탭")
    }

    func testLibraryHistoryHasKoreanForTabsSearchAndDeletion() throws {
        let strings = try koreanStrings(of: "Browsing")
        XCTAssertEqual(strings["Downloads"], "다운로드")
        XCTAssertEqual(strings["History"], "방문 기록")
        XCTAssertEqual(strings["Search History"], "방문 기록 검색")
        XCTAssertEqual(strings["Clear History…"], "방문 기록 지우기…")
        XCTAssertEqual(strings["Delete from History"], "방문 기록에서 삭제")
        XCTAssertEqual(strings["The Last Hour"], "지난 1시간")
        XCTAssertEqual(strings["Today"], "오늘")
        XCTAssertEqual(strings["Yesterday"], "어제")
        XCTAssertEqual(strings["All History"], "모든 방문 기록")
    }
}
