// Connects the session's tabs to the plugins of their Personas: each tab's pages run the page scripts of its Persona's enabled plugins, the values those scripts send reach their plugins, and the page's context menu shows the plugins' items for what the user clicked on.
import AppKit
import ARCHEngine
import Combine
import Plugins

@MainActor
final class PluginPages {
    private weak var session: BrowserSession?
    /// The tabs whose callbacks are set, so that each joins once.
    private var followedTabIDs: Set<UUID> = []
    private var tabsSubscription: AnyCancellable?
    /// Each Persona's subscription to its plugins' page scripts, which ends when the Persona goes.
    private var pageScriptSubscriptions: [Persona.ID: AnyCancellable] = [:]

    /// Made with the session, which calls `attach(to:)` once it exists.
    nonisolated init() {}

    /// Follows the session's tabs, the favorites' tabs among them.
    func attach(to session: BrowserSession) {
        self.session = session
        tabsSubscription = session.$tabs.combineLatest(session.$favoriteTabs)
            .sink { [weak self] tabs, favoriteTabs in
                MainActor.assumeIsolated { self?.follow(tabs + favoriteTabs.values) }
            }
    }

    /// Gives the Persona's tabs the plugins' page scripts whenever they change, from each page's next document on. A web contents the session creates starts with the scripts of that moment.
    func follow(_ plugins: PluginManager, of personaID: Persona.ID) {
        pageScriptSubscriptions[personaID] = plugins.$contributions.map(\.pageScripts).removeDuplicates().dropFirst()
            .sink { [weak self] scripts in
                MainActor.assumeIsolated {
                    for tab in self?.session?.allTabs ?? [] where tab.personaID == personaID { tab.webContents.setPageScripts(scripts) }
                }
            }
    }

    /// Stops following the plugins of a Persona the user deleted.
    func stopFollowing(_ personaID: Persona.ID) {
        pageScriptSubscriptions[personaID] = nil
    }

    /// Sets the callbacks of each tab that joins and gives it its Persona's page scripts: a page that another page opens starts with that page's scripts, and the preview panel's pages run none.
    private func follow(_ tabs: [Tab]) {
        guard let session else { return }
        followedTabIDs.formIntersection(tabs.map(\.id))
        for tab in tabs where followedTabIDs.insert(tab.id).inserted {
            let plugins = session.plugins(in: tab.personaID)
            tab.webContents.setPageScripts(plugins.contributions.pageScripts)
            tab.receivePageScriptMessage = { [weak session, weak tab] message, reply in
                MainActor.assumeIsolated {
                    guard let tab, let pluginTab = session?.pluginTab(tab) else { return reply(nil) }
                    Task { reply(await plugins.receive(message, from: pluginTab)) }
                }
            }
            tab.addPluginMenuItems = { [weak self, weak tab] element, menu in
                MainActor.assumeIsolated {
                    if let tab { self?.addMenuItems(for: element, in: tab, to: menu) }
                }
            }
        }
    }

    /// Adds the items for the contexts of the click, one section per plugin under the plugin's name. Each runs its command on the tab with what the user clicked on.
    private func addMenuItems(for element: EngineContextMenuElement, in tab: Tab, to menu: NSMenu) {
        guard let session else { return }
        let plugins = session.plugins(in: tab.personaID)
        let invocation = PluginInvocation(tab: session.pluginTab(tab), linkURL: element.linkURL, imageURL: element.imageURL, selection: element.selectedText)
        for section in plugins.contributions.menuSections(at: .pageContextMenu(Set(element))) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: section.pluginName))
            for entry in section.items {
                menu.addItem(EngineActionMenuItem(entry.title) { Task { await plugins.run(entry.command, invocation) } })
            }
        }
    }
}

extension BrowserSession {
    /// The tab as its Persona's plugins see it before the manager applies a plugin's grant. It is selected while any window selects it.
    func pluginTab(_ tab: Tab) -> PluginTab {
        PluginTab(id: tab.id, spaceID: tab.spaceID, title: tab.displayTitle, url: tab.url, engine: tab.engineKind, isPinned: tab.isPinned,
                  isSelected: windows.contains { $0.selectedTabID == tab.id })
    }
}
