import Foundation
import XCTest
@testable import Agent

final class AgentLocalizationTests: XCTestCase {
    /// The module's resource bundle, which SwiftPM builds beside the test bundle.
    private func koreanStrings(of module: String) throws -> [String: String] {
        let products = Bundle(for: AgentLocalizationTests.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "ko"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testAgentHasKoreanForKeyStrings() throws {
        let strings = try koreanStrings(of: "Agent")
        XCTAssertEqual(strings["Hand Back"], "돌려주기")
        XCTAssertEqual(strings["Waiting for your decision"], "결정을 기다리는 중")
        XCTAssertEqual(strings["Tab %lld · %@"], "탭 %1$lld · %2$@")
        XCTAssertEqual(strings["Agent Runs from Programs"], "프로그램의 에이전트 실행")
        XCTAssertEqual(strings["Agent Task"], "에이전트 작업")
    }

    /// The English text that task events carry to outside clients stays English whatever language Arch runs in.
    func testSourceTextStaysEnglish() {
        let count = 3
        XCTAssertEqual(sourceText("Hand Back"), "Hand Back")
        XCTAssertEqual(sourceText("\(count) more requests wait after this one."), "3 more requests wait after this one.")
    }
}

/// The text the module's catalog gives `key` in the language the tests run in, as the module's own lookups pick it; `arguments` fill a format key.
func catalogText(_ key: String, _ arguments: CVarArg..., module: String = "Agent") -> String {
    let products = Bundle(for: AgentLocalizationTests.self).bundleURL.deletingLastPathComponent()
    let bundle = Bundle(url: products.appendingPathComponent("ArchBrowser_\(module).bundle")) ?? .main
    let text = bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
