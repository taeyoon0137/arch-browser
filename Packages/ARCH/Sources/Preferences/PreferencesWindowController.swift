// Settings window with a toolbar of sections in the system's settings layout: General, Site Search, Sidebar, Appearance, Shortcuts, Websites, Plugins, and AI. Site Search saves its shortcuts in their own file, Websites in `permissions.json`, Plugins in each Persona's plugin files and the Keychain, and AI in its own files and the Keychain; the others save in `UserDefaults`.
import Agent
import AI
import AppKit
import ARCHEngine
import Browsing
import Hooks
import Plugins
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
    /// Opens the built-in terminal, where the user installs and signs in to command-line tools for Settings ▸ AI. The app shell sets it, so this module does not depend on the terminal's.
    public static var openTerminal: (() -> Void)?
    /// Opens the built-in terminal with a command typed at the prompt but not run, such as a tool's sign-in for Sign In in Settings ▸ AI. The app shell sets it beside `openTerminal`.
    public static var openTerminalTyping: ((String) -> Void)?
    /// The session whose shortcuts Settings ▸ Site Search edits, whose remembered permissions Settings ▸ Websites shows, and whose Personas' plugins Settings ▸ Plugins shows. The app shell sets it at launch, before Settings first opens; without it those sections are left out.
    public static var session: BrowserSession?
    /// The agents' service whose outside access, grants, and activity Settings ▸ AI ▸ Agents shows. The app shell sets it at launch, before Settings first opens; without it the page is left out.
    public static var agents: AgentService?
    /// The hook registry whose hooks Settings ▸ AI ▸ Agent Hooks lists. The app shell sets it at launch, before Settings first opens; without it the page is left out.
    public static var hooks: HookRegistry?

    /// Sign In for a Claude Code or Codex provider outside Settings, as from the agent panel: the built-in terminal with the tool's sign-in typed, as the provider's editor types it.
    @MainActor public static func signInToAgentTool(_ providerID: AIProviderID) {
        guard let provider = AIService.shared.settings.providers.first(where: { $0.id == providerID }), case .commandLine(let tool) = provider.kind,
              let agent = tool.agent, let type = openTerminalTyping else { return shared.showAISection() }
        Task {
            let found = await AICommandLineConfiguration.locateExecutable(named: agent.executableName)
            let program = found?.resolvingSymlinksInPath() == tool.executable.resolvingSymlinksInPath() ? agent.executableName : AICommandLineEditor.shellQuoted(tool.executable.path)
            type(AICommandLineEditor.signInCommand(program: program, arguments: agent.signInArguments, environment: tool.environment))
        }
    }

    /// Settings ▸ AI, where the errors of AI features about models, keys, and limits send the user.
    private let aiSection = PreferencesWindowController.section("AI", symbol: "sparkles", AISettingsView(agents: PreferencesWindowController.agents, hooks: PreferencesWindowController.hooks))
    /// Settings ▸ Plugins, while the app shell has set `session`.
    private var pluginsSection: NSTabViewItem?

    private init() {
        let sections = NSTabViewController()
        sections.tabStyle = .toolbar
        let session = Self.session
        sections.addTabViewItem(Self.section("General", symbol: "gearshape", GeneralSection()))
        if let session {
            sections.addTabViewItem(Self.section("Site Search", symbol: "magnifyingglass", SiteSearchSection(store: session.siteSearch)))
        }
        sections.addTabViewItem(Self.section("Sidebar", symbol: "sidebar.left", SidebarSection()))
        sections.addTabViewItem(Self.section("Appearance", symbol: "paintpalette", AppearanceSection()))
        sections.addTabViewItem(Self.section("Shortcuts", symbol: "keyboard", ShortcutsSection()))
        if let session {
            sections.addTabViewItem(Self.section("Websites", symbol: "globe", WebsitesSection(store: session.sitePermissions, notifications: session.notificationAuthorization, session: session)))
            // AI writes plugins only from Settings ▸ Plugins, so its feature joins Settings ▸ AI with the section.
            AIService.shared.register(.pluginComposer)
            let plugins = Self.section("Plugins", symbol: "puzzlepiece.extension", PluginsSection(session: session))
            pluginsSection = plugins
            sections.addTabViewItem(plugins)
        }
        sections.addTabViewItem(aiSection)
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

    /// Brings the Settings window to the front on the AI section. The tab view controller follows its tab view's selection.
    public func showAISection() {
        aiSection.tabView?.selectTabViewItem(aiSection)
        show()
    }

    /// Brings the Settings window to the front on Plugins at the plugin in the Persona, with the open panel for the plugin's version for the engine, for Install <Engine> Version… in the site settings popover. The review names the Persona with `space`, the tab's.
    public func showPlugin(_ plugin: PluginID, in persona: Persona.ID, space: Space.ID?, installingVersionFor engine: EngineKind) {
        showPlugins(PluginsRequest(persona: persona, space: space, action: .installVersion(plugin, engine)))
    }

    /// Brings the Settings window to the front on Plugins in the Persona, with the store sheet started for the extension `id`, for the Web Store's entry points in tabs and the palette. The review names the Persona with `space`, the tab's or the window's.
    public func showWebStoreInstall(of id: String, in persona: Persona.ID, space: Space.ID?) {
        showPlugins(PluginsRequest(persona: persona, space: space, action: .installFromWebStore(id)))
    }

    private func showPlugins(_ request: PluginsRequest) {
        PluginsRequests.shared.pending = request
        if let pluginsSection { pluginsSection.tabView?.selectTabViewItem(pluginsSection) }
        show()
    }
}
