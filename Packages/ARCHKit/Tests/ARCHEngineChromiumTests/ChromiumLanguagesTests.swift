// The languages Chromium's pages see and its own text uses, from the app's preferred languages (`docs/localization.md`, Pages' languages).
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumLanguagesTests {
    @Test func eachLanguageComesWithItsRegionThenAlone() {
        #expect(ChromiumLanguages.acceptLanguageList(from: ["ko-KR", "en-US"]) == "ko-KR,ko,en-US,en")
        #expect(ChromiumLanguages.acceptLanguageList(from: ["ko-KR", "en-KR", "en-US"]) == "ko-KR,ko,en-KR,en,en-US")
        #expect(ChromiumLanguages.acceptLanguageList(from: ["ko"]) == "ko")
        #expect(ChromiumLanguages.acceptLanguageList(from: ["zh-Hans-CN"]) == "zh-Hans-CN,zh")
        #expect(ChromiumLanguages.acceptLanguageList(from: ["en_GB"]) == "en-GB,en")
    }

    @Test func noLanguagesLeaveChromiumsDefault() {
        #expect(ChromiumLanguages.acceptLanguageList(from: []) == "en-US,en")
        #expect(ChromiumLanguages.locale(from: []) == "")
    }

    @Test func chromiumsTextFollowsTheFirstLanguage() {
        #expect(ChromiumLanguages.locale(from: ["ko-KR", "en-US"]) == "ko-KR")
        #expect(ChromiumLanguages.locale(from: ["en_US"]) == "en-US")
    }
}
