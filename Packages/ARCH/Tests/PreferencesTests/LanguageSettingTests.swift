// Settings ▸ General ▸ Language (`docs/localization.md`): a language writes `AppleLanguages` in the app's own domain and System removes it; the system's languages, which every domain reads, count as no choice; a language Arch has no catalogs for counts as the system's; and each language goes by its own name.
import Foundation
import Testing
@testable import Preferences

@Suite struct LanguageSettingTests {
    /// A domain of its own, which stands in for Arch's.
    private func withDomain(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "LanguageSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    @Test func choosingALanguageWritesAppleLanguagesAndSystemRemovesIt() {
        withDomain { defaults, name in
            let setting = LanguageSetting(defaults: defaults, domain: name)
            #expect(setting.chosen == nil)
            setting.choose("ko")
            #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == ["ko"])
            #expect(setting.chosen == "ko")
            setting.choose("en")
            #expect(setting.chosen == "en")
            setting.choose(nil)
            #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
            // The system's languages, which the domain still reads from the global one, are no choice.
            #expect(setting.chosen == nil)
        }
    }

    @Test func aRegionalOrUntranslatedChoiceReadsAsItsLanguageOrTheSystem() {
        withDomain { defaults, name in
            let setting = LanguageSetting(defaults: defaults, domain: name)
            defaults.set(["ko-KR"], forKey: "AppleLanguages")
            #expect(setting.chosen == "ko")
            defaults.set(["ja"], forKey: "AppleLanguages")
            #expect(setting.chosen == nil)
        }
    }

    @Test func languagesGoByTheirOwnNames() {
        #expect(LanguageSetting.languages == ["en", "ko"])
        #expect(LanguageSetting.name(of: "en") == "English")
        #expect(LanguageSetting.name(of: "ko") == "한국어")
    }
}
