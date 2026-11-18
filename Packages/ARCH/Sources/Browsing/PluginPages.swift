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

    /// Gives the Persona's tabs the plugins' page scripts whenever they change, from each page's next document on, after the app's own (`TabUnloading.pageScripts(withPluginScripts:inAgentTab:)`): every tab the Persona's, when those change, and a tab whose plugins' access changes those of the plugins whose access in it holds (`PluginManager.accessPageScripts(forTab:)`). A web contents the session creates starts with the Persona's scripts of that moment.
    func follow(_ plugins: PluginManager, of personaID: Persona.ID) {
        var applied = (shared: plugins.contributions.pageScripts, byTab: plugins.tabPageScripts)
        pageScriptSubscriptions[personaID] = plugins.$contributions.map(\.pageScripts).combineLatest(plugins.$tabPageScripts)
            .sink { [weak self, weak plugins] shared, byTab in
                MainActor.assumeIsolated {
                    let changed = Set(applied.byTab.keys).union(byTab.keys).filter { applied.byTab[$0] != byTab[$0] }
                    let sharedChanged = shared != applied.shared
                    applied = (shared, byTab)
                    guard sharedChanged || !changed.isEmpty, let plugins else { return }
                    self?.setPageScripts(ofTabsIn: personaID, where: { sharedChanged || changed.contains($0.id) }, shared: shared, plugins: plugins)
                }
            }
    }

    /// Gives the Persona's tabs that `needs` picks their page scripts (`pageScripts(of:among:shared:plugins:)`), with `shared` as the Persona's plugins' scripts.
    private func setPageScripts(ofTabsIn personaID: Persona.ID, where needs: (Tab) -> Bool, shared: [EnginePageScript], plugins: PluginManager) {
        let tabs = session?.allTabs ?? []
        for tab in tabs where tab.personaID == personaID && needs(tab) {
            tab.webContents.setPageScripts(pageScripts(of: tab, among: tabs, shared: shared, plugins: plugins))
        }
    }

    /// The page scripts that `tab` takes, after the app's own (`TabUnloading.pageScripts(withPluginScripts:inAgentTab:)`): `shared`, its Persona's plugins' scripts, then those of the plugins whose access in the tab holds (`PluginManager.accessPageScripts(forTab:)`), unless its web contents shares its list with that of another of `tabs`, as on WebKit a tab and the pages it opens do. Such a tab takes `shared` only, since the scripts of its access would run in the other tab's documents on the host too, where a plugin's script could read the page and hand what it read to the tab with the access, as through the site's storage; there they run only at the plugin's commands.
    private func pageScripts(of tab: Tab, among tabs: [Tab], shared: [EnginePageScript], plugins: PluginManager) -> [EnginePageScript] {
        let list = tab.webContents.pageScriptListID
        let sharesList = tabs.contains { $0 !== tab && $0.webContents.pageScriptListID == list }
        return TabUnloading.pageScripts(withPluginScripts: sharesList ? shared : shared + plugins.accessPageScripts(forTab: tab.id), inAgentTab: tab.agentOwnerID != nil)
    }

    /// Stops following the plugins of a Persona the user deleted.
    func stopFollowing(_ personaID: Persona.ID) {
        pageScriptSubscriptions[personaID] = nil
    }

    /// Sets the callbacks of each tab that joins and gives it its Persona's page scripts: a page that another page opens starts with that page's scripts, and the preview panel's pages run none. A tab that joins or leaves can start or end another's sharing of a script list, as a page that a WebKit tab opens does, so the tabs with access then take their scripts again (`pageScripts(of:among:shared:plugins:)`). `tabs` holds the tabs that join, which the session does not list yet.
    private func follow(_ tabs: [Tab]) {
        guard let session else { return }
        let ids = Set(tabs.map(\.id))
        let tabsLeft = !followedTabIDs.isSubset(of: ids)
        followedTabIDs.formIntersection(ids)
        var tabsJoined = false
        for tab in tabs where followedTabIDs.insert(tab.id).inserted {
            let plugins = session.plugins(in: tab.personaID)
            tabsJoined = true
            tab.webContents.setPageScripts(pageScripts(of: tab, among: tabs, shared: plugins.contributions.pageScripts, plugins: plugins))
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
        guard tabsJoined || tabsLeft else { return }
        for tab in tabs {
            let plugins = session.plugins(in: tab.personaID)
            guard plugins.tabPageScripts[tab.id] != nil else { continue }
            tab.webContents.setPageScripts(pageScripts(of: tab, among: tabs, shared: plugins.contributions.pageScripts, plugins: plugins))
        }
    }

    /// Adds the items for the contexts of the click, one section per plugin under the plugin's name. Each runs its command on the tab with what the user clicked on.
    private func addMenuItems(for element: EngineContextMenuElement, in tab: Tab, to menu: NSMenu) {
        guard let session else { return }
        let plugins = session.plugins(in: tab.personaID)
        let invocation = PluginInvocation(tab: session.pluginTab(tab), linkURL: element.linkURL, imageURL: element.imageURL, selection: element.selectedText, source: .contextMenu)
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
                  isSelected: windows.contains { $0.selectedTabID == tab.id }, kind: BrowserEventSource.kind(of: tab), documentID: tab.documentID,
                  documentURL: tab.committedURL)
    }
}
