// Looks up the strings this module shows in its own string catalog, `Resources/Localizable.xcstrings` (`docs/localization.md`).
import Foundation

/// The text for `key` in the language Arch runs in, from this module's catalog; the key itself, which is the English text, when the catalog has no translation.
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
