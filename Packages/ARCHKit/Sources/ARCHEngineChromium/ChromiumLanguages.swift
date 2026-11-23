// The languages Chromium's pages see and Chromium's own text uses, from the app's preferred languages (`docs/localization.md`, Pages' languages).
import Foundation

/// Builds the language settings that `ChromiumEngine` hands CEF at start.
enum ChromiumLanguages {
    /// The list for `Accept-Language` and `navigator.languages` in every profile: each preferred language as macOS names it, with its region, then the language alone, in order and without repeats, as in `ko-KR,ko,en-US,en`. CEF takes commas without spaces and adds the weights itself. No languages give CEF's own `en-US,en`.
    static func acceptLanguageList(from preferred: [String]) -> String {
        var tags: [String] = []
        for identifier in preferred {
            let tag = identifier.replacingOccurrences(of: "_", with: "-")
            let language = Locale.Language(identifier: tag).languageCode?.identifier ?? tag
            for candidate in [tag, language] where !candidate.isEmpty && !tags.contains(candidate) {
                tags.append(candidate)
            }
        }
        return tags.isEmpty ? "en-US,en" : tags.joined(separator: ",")
    }

    /// The locale of Chromium's own text, such as its built-in pages and dialogs: the first preferred language, which Chromium resolves to a locale it ships (`ko-KR` to `ko`). Empty for none, which CEF reads as `en-US`.
    static func locale(from preferred: [String]) -> String {
        preferred.first?.replacingOccurrences(of: "_", with: "-") ?? ""
    }
}
