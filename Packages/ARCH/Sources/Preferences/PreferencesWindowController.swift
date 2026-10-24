// Settings window with a toolbar of sections in the system's settings layout: General, Site Search, Sidebar, Appearance, Shortcuts, Websites, and AI. Site Search saves its shortcuts in their own file, Websites in `permissions.json`, and AI in its own files and the Keychain; the others save in `UserDefaults`.
import AppKit
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

/// Owns the single Settings window, which stays in memory when closed. Its toolbar switches between sections, and the window takes each section's title and size.
public final class PreferencesWindowController: NSWindowController {
    public static let shared = PreferencesWindowController()
    public static let archiveAfterHoursKey = "ARCHArchiveAfterHours"
    public static let defaultArchiveAfterHours = 12

    private init() {
        UserDefaults.standard.register(defaults: [Self.archiveAfterHoursKey: Self.defaultArchiveAfterHours])
        let sections = NSTabViewController()
        sections.tabStyle = .toolbar
        sections.addTabViewItem(Self.section("General", symbol: "gearshape", GeneralSection()))
        sections.addTabViewItem(Self.section("Site Search", symbol: "magnifyingglass", SiteSearchSection()))
        sections.addTabViewItem(Self.section("Sidebar", symbol: "sidebar.left", SidebarSection()))
        sections.addTabViewItem(Self.section("Appearance", symbol: "paintpalette", AppearanceSection()))
        sections.addTabViewItem(Self.section("Shortcuts", symbol: "keyboard", ShortcutsSection()))
        sections.addTabViewItem(Self.section("Websites", symbol: "globe", WebsitesSection()))
        sections.addTabViewItem(Self.section("AI", symbol: "sparkles", AISettingsView()))
        let window = NSWindow(contentViewController: sections)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    /// A toolbar section whose hosting controller reports the form's size, so the window fits each section.
    private static func section(_ title: String, symbol: String, _ form: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: form)
        controller.sizingOptions = .preferredContentSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
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
