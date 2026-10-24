// Settings window for the default engine, appearance, and tab archive delay, saved in `UserDefaults`.
import AppKit
import ARCHEngine
import SwiftUI

/// An appearance choice stored as a raw string under `ARCHAppearance`.
public enum AppearanceSetting: String, CaseIterable {
    case system
    case light
    case dark

    public static let defaultsKey = "ARCHAppearance"

    /// The saved appearance choice, or `system` if none is saved.
    public static var current: AppearanceSetting {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
    }

    /// The value for `NSApp.appearance`; `nil` follows the system appearance.
    public var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Owns the single, fixed-size Settings window, which stays in memory when closed.
public final class PreferencesWindowController: NSWindowController {
    public static let shared = PreferencesWindowController()
    public static let archiveAfterHoursKey = "ARCHArchiveAfterHours"
    public static let defaultArchiveAfterHours = 12

    private init() {
        UserDefaults.standard.register(defaults: [Self.archiveAfterHoursKey: Self.defaultArchiveAfterHours])
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesForm()))
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesWindowController is created through shared")
    }

    /// Brings the Settings window to the front, centering it if it was hidden.
    public func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PreferencesForm: View {
    @State private var defaultEngine = EngineRegistry.shared.defaultKind
    @AppStorage(AppearanceSetting.defaultsKey) private var appearance = AppearanceSetting.system
    @AppStorage(PreferencesWindowController.archiveAfterHoursKey) private var archiveAfterHours = PreferencesWindowController.defaultArchiveAfterHours

    var body: some View {
        Form {
            Picker("Default engine:", selection: $defaultEngine) {
                ForEach(EngineRegistry.shared.registeredKinds, id: \.self) { kind in
                    Text(kind.displayName)
                }
            }
            .onChange(of: defaultEngine) { EngineRegistry.shared.defaultKind = $0 }

            Picker("Appearance:", selection: $appearance) {
                ForEach(AppearanceSetting.allCases, id: \.self) { choice in
                    Text(choice.title)
                }
            }
            .onChange(of: appearance) { NSApp.appearance = $0.appearance }

            Stepper(value: $archiveAfterHours, in: 0...168) {
                Text(archiveAfterHours == 0 ? "Archive tabs: Never" : "Archive tabs after \(archiveAfterHours) hours")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
