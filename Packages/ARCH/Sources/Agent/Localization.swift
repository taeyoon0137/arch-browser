// Looks up the strings this module shows in its own string catalog, `Resources/Localizable.xcstrings` (`docs/localization.md`).
import Foundation

/// The text for `key` in the language Arch runs in, from this module's catalog; the key itself, which is the English text, when the catalog has no translation.
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// The English text of `key`, for text that also goes to outside clients over the agent channel: a table the module does not have, whose lookup falls back to the key.
func sourceText(_ key: String.LocalizationValue) -> String {
    String(localized: key, table: "SourceText", bundle: .module)
}
