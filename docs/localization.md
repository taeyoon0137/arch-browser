# Localization

Arch shows its interface in the system's language by default. English is the source language, and Korean is the first translation. Settings ▸ General ▸ Language picks another language for Arch alone (row 73 in `docs/features.md`).

## How it works

- Each module that shows text has a string catalog at `Resources/Localizable.xcstrings` and declares it in `Package.swift` with `resources: [.process("Resources")]`. The package sets `defaultLocalization: "en"`. These modules are `Arch`, `Browsing`, `Preferences`, `Agent`, `Hooks`, `Import`, `History`, `Terminal`, `Plugins`, `Extensions`, `Sync`, `AI`, `ARCHEngine`, `ARCHEngineWebKit`, and `ARCHEngineChromium`.
- `swift build` compiles each catalog into `ko.lproj/Localizable.strings` inside the module's resource bundle, `ArchBrowser_<Module>.bundle`. English needs no table, because each key is its English text.
- Each module's `Localization.swift` holds `localized(_:)`, which looks a key up in the module's own bundle (`Bundle.module`). SwiftUI literals use `Text("…", bundle: .module)`. Labels, buttons, toggles, sections, pickers, help tags, alerts, menu items, and messages take `localized("…")`. Interpolation makes format keys: `localized("Closed \(count) tabs")` looks up `Closed %lld tabs`, and a `String` value is `%@`.
- `scripts/bundle_app.sh` copies every module's bundle into `Contents/Resources`, where `Bundle.module` finds it. It lists `en` and `ko` in `CFBundleLocalizations`, and the system picks the app's language from them. It also writes `ko.lproj/InfoPlist.strings` with the usage descriptions in Korean.
- Text that does not reach the user stays in English and out of the catalogs. This covers log messages, identifiers, stored keys, protocol values, and what goes to AI models and to programs over the agent channel, including `arch-cli` output. Text that plugins, extensions, and pages provide is not translated either. Where one value serves both the interface and such a channel, the interface has a translated copy, such as `AgentAccessLevel.localizedTitle` beside `title`.

## Settings ▸ General ▸ Language

- The picker offers System (default) and each language Arch is translated into, each by its own name: English, 한국어 (`LanguageSetting`).
- A language writes `AppleLanguages` with that language in Arch's own defaults domain. This is the key macOS reads for an app's language, and System Settings ▸ General ▸ Language & Region ▸ Applications writes it too. System removes the key, so Arch again follows the system's languages. If the domain names a language Arch is not translated into, the picker shows System.
- The choice applies at the next launch. After a change, the section says so and offers Relaunch in an app bundle. Relaunch quits Arch, and once the process has ended, a shell waiting on its process ID opens the bundle again. The reopening waits for the process to end because a second copy cannot open the profile. A quit that is cancelled, for example at the downloads warning, leaves no reopening behind.

## Pages' languages

- WebKit sends the app's preferred languages (`Locale.preferredLanguages`) in `Accept-Language` and `navigator.languages` on its own. Arch sets no language for WebKit.
- Chromium takes the same list at startup. `ChromiumLanguages.acceptLanguageList(from:)` gives each preferred language with its region and then alone, without repeats, as in `ko-KR,ko,en-US,en`. The CEF bridge sets this as `CefSettings.accept_language_list`. Profiles' request contexts set no list of their own, so every Persona's pages use it. `CefSettings.locale` gets the first preferred language, so Chromium's own text, such as its built-in pages and dialogs, matches the interface. CEF's framework ships Korean (`ko.lproj/locale.pak`), so this needs no engine change.
- Both engines read the languages once per launch, which is when a choice in Settings takes effect.

## Adding a string

1. Route the text through the module's catalog, with `Text("…", bundle: .module)` in SwiftUI or `localized("…")` elsewhere. Write a whole sentence in one key, with values interpolated, and do not join pieces. Korean word order differs from English, and positional specifiers (`%1$@`, `%2$lld`) can reorder values only within one key.
2. Run `swift build`. The compiler writes the keys it extracts to `.stringsdata` files under `.build/out/Intermediates.noindex/ArchBrowser.build/Debug/<Module>-*.build/Objects-normal/arm64/`. Add each new key to the module's `Localizable.xcstrings` with its Korean value, either in Xcode's catalog editor or as JSON in the same shape as the existing entries.
3. In Korean, keep `…`, keyboard symbols, product names, and every format specifier. Do not put a particle that depends on the word before it, such as 을/를 or 이/가, right after a `%@` that can be any word.
4. Each module's test target has a test that loads the built bundle's Korean table and checks a few keys, such as `Packages/ARCH/Tests/BrowsingTests/LocalizationTests.swift`. Which language a test sees depends on its runner. Swift Testing tests run under SwiftPM's test helper, whose bundle has only English, so lookups give English. XCTest tests run under `xctest` in the Mac's language, which gave Korean on a Korean Mac. An XCTest test that compares text the interface shows looks up the expected value in the module's bundle, so that it passes in either language.

## Adding a language

1. Add the language's values to every module's catalog. A key without a value shows in English.
2. Add the language code to `CFBundleLocalizations` in `scripts/bundle_app.sh` and to `LanguageSetting.languages`. Give the usage descriptions an `InfoPlist.strings` for it in the same script.
3. Check that CEF's framework ships the language under `Chromium Embedded Framework.framework/Resources/<language>.lproj`. Otherwise Chromium's own text falls back to English.
