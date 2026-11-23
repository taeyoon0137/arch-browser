// Settings ▸ General ▸ Language: the system's language, the default, or one Arch is translated into, from the next launch (`docs/localization.md`).
// The choice is `AppleLanguages` in Arch's own defaults domain, the key macOS reads for an app's language, as System Settings ▸ General ▸ Language & Region ▸ Applications writes it. System removes it.
import AppKit
import Foundation

public struct LanguageSetting {
    /// The languages Arch's string catalogs translate into, as `CFBundleLocalizations` lists them (`scripts/bundle_app.sh`).
    public static let languages = ["en", "ko"]
    public static let defaultsKey = "AppleLanguages"

    private let defaults: UserDefaults
    /// The domain `defaults` writes to, whose own value tells a choice from the system's languages, which `defaults` also reads.
    private let domain: String

    /// Arch's own domain by default.
    public init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domain = domain ?? ""
    }

    /// The chosen language, or nil for the system's. A language that the domain names but Arch is not translated into, as System Settings can set, counts as the system's.
    public var chosen: String? {
        guard let stored = defaults.persistentDomain(forName: domain)?[Self.defaultsKey] as? [String], let first = stored.first else { return nil }
        let code = Locale.Language(identifier: first).languageCode?.identifier ?? first
        return Self.languages.contains(code) ? code : nil
    }

    /// Writes `language` for the next launch, or removes the choice for nil.
    public func choose(_ language: String?) {
        if let language {
            defaults.set([language], forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// The language's name in that language, as language menus name them: English, 한국어.
    public static func name(of language: String) -> String {
        Locale(identifier: language).localizedString(forLanguageCode: language).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? language
    }

    /// Quits Arch and opens it again once this process has ended, since a second copy cannot open the profile while this one runs. The quit can still be cancelled, as by the downloads warning; the reopening waits for the quit to happen.
    @MainActor public static func relaunch() {
        let app = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        // The block does not remove its observer: AppKit posts the notification once, right before the process exits.
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            let reopen = Process()
            reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
            reopen.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"", String(pid), app]
            try? reopen.run()
        }
        NSApp.terminate(nil)
        // AppKit returns only when the app does not quit, also after a quit it answered later; that quit leaves no reopening behind for a later one.
        NotificationCenter.default.removeObserver(observer)
    }
}
