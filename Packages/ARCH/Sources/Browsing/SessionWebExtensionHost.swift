// The session hosts web extensions for its Personas. It starts engine profiles and opens, selects, and closes their tabs and windows.
// It shows popups in windows, questions as cards over tabs, and store-install review for a store button. It reports Arch windows to extensions.
// Each space is one extension window: favorites shown in a main window come first, followed by its tabs in sidebar order. Its active tab is the one shown there or last selected.
// Each small window reports its single tab as its own window. The last window to become main is focused.
import AppKit
import ARCHEngine
import Combine
import Extensions
import Plugins

/// The session's side of the web extension runtime: it opens and reports tabs and windows for the extensions of its Personas.
@MainActor
final class SessionWebExtensionHost: WebExtensionHost {
    private weak var session: BrowserSession?
    /// The runtimes of the Personas whose extensions see the windows, until the Persona goes.
    private var runtimes: [Persona.ID: WebExtensionRuntime] = [:]
    private var changes: AnyCancellable?
    /// Whether a report waits for the next turn of the run loop, which gathers the changes of one turn into one report.
    private var isReportPending = false

    /// Made with the session, which passes itself with each runtime it follows.
    nonisolated init() {}

    /// Reports the Persona's windows to the runtime now and each time they change. The session follows a runtime before its plugin manager reads the engines that run extensions.
    func follow(_ runtime: WebExtensionRuntime, of personaID: Persona.ID, in session: BrowserSession) {
        self.session = session
        runtimes[personaID] = runtime
        if changes == nil { changes = Self.windowChanges(of: session).sink { [weak self] in self?.scheduleReport() } }
        report(to: runtime, of: personaID)
    }

    /// Stops reporting to a Persona the user deleted.
    func stopFollowing(_ personaID: Persona.ID) {
        runtimes[personaID] = nil
    }

    /// Changes to what the windows hold: the spaces, the tabs and the favorites' tabs, a tab's engine, space, and the pinned state and folder that place it in its space's order, and each window's space and selection, and their order, which follows the window that last became main. The publishers send before the change, so a report reads the session on the next turn of the run loop.
    private static func windowChanges(of session: BrowserSession) -> AnyPublisher<Void, Never> {
        let tabs = session.$tabs.combineLatest(session.$favoriteTabs).map { tabs, favoriteTabs in
            Publishers.MergeMany((tabs + favoriteTabs.values).map { tab in
                tab.$webContents.map { _ in () }.merge(with: tab.$spaceID.map { _ in () }, tab.$isPinned.map { _ in () }, tab.$folderID.map { _ in () })
            })
        }.switchToLatest()
        let windows = session.$windows.map { windows in
            Publishers.MergeMany(windows.map { $0.$currentSpaceID.map { _ in () }.merge(with: $0.$selectedTabID.map { _ in () }) })
        }.switchToLatest()
        return session.$spaces.map { _ in () }.merge(with: session.$windows.map { _ in () }, tabs, windows).eraseToAnyPublisher()
    }

    private func scheduleReport() {
        guard !isReportPending else { return }
        isReportPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reportToEveryPersona() }
        }
    }

    private func reportToEveryPersona() {
        isReportPending = false
        for (personaID, runtime) in runtimes { report(to: runtime, of: personaID) }
    }

    private func report(to runtime: WebExtensionRuntime, of personaID: Persona.ID) {
        guard let session else { return }
        let windows = extensionWindows(of: personaID, in: session).map { window in
            EngineExtensionWindow(id: window.id, tabs: window.tabs.map(\.webContents), activeTab: window.active?.webContents, window: window.showing?.nsWindow)
        }
        runtime.setWindows(windows, focusedWindowID: focusedWindowID(of: personaID, in: session))
    }

    /// One of the Persona's windows as its extensions see it: its identity, the space its tabs belong to, its tabs in order, its active tab, and the window that shows it.
    private typealias ExtensionWindow = (id: UUID, space: Space, tabs: [Tab], active: Tab?, showing: BrowserWindowModel?)

    /// Each space of the Persona, with the first main window that shows it, and then each small window of the Persona, with its one tab, as its extensions' windows. A space's identity is its window's. A restored tab that no window has shown has no page for the engines to list, so it joins its window once its page loads, and an index among a window's tabs counts only the tabs that have pages.
    private func extensionWindows(of personaID: Persona.ID, in session: BrowserSession) -> [ExtensionWindow] {
        let spaces = session.spaces.filter { $0.resolvedPersonaID == personaID }
        // A favorite's tab belongs to no space: it is in the Persona's space where a window shows it, or else in the Persona's first space.
        let favoriteTabs = Dictionary(grouping: session.openFavoriteTabs.filter { !$0.isPrivate && $0.personaID == personaID }) { tab in
            let shownIn = session.windows.first { !$0.isPrivate && $0.selectedTabID == tab.id }?.currentSpaceID
            return spaces.contains { $0.id == shownIn } ? shownIn : spaces.first?.id
        }
        let spaceWindows = spaces.map { space -> ExtensionWindow in
            let showing = session.windows.filter { !$0.isPrivate && $0.kind == .main && $0.currentSpaceID == space.id }
            let tabs = ((favoriteTabs[space.id] ?? []) + session.tabs(in: space.id, pinned: true) + session.tabs(in: space.id, pinned: false)).filter { !$0.isPrivate && $0.isLoaded }
            let active = showing.lazy.compactMap(\.selectedTab).first { tab in tabs.contains { $0 === tab } } ?? tabs.max { $0.lastActivatedAt < $1.lastActivatedAt }
            return (space.id, space, tabs, active, showing.first)
        }
        let smallWindows = session.windows.compactMap { window -> ExtensionWindow? in
            guard !window.isPrivate, window.kind == .small, window.personaID == personaID, let tab = window.selectedTab, !tab.isPrivate else { return nil }
            return (window.id, window.currentSpace, [tab], tab, window)
        }
        return spaceWindows + smallWindows
    }

    /// The space of the window that last became main, when it is the Persona's.
    private func focusedSpace(of personaID: Persona.ID, in session: BrowserSession) -> Space? {
        guard let window = session.windows.first, !window.isPrivate else { return nil }
        return window.currentSpace.resolvedPersonaID == personaID ? window.currentSpace : nil
    }

    /// The window that last became main as the Persona's extensions see it, when it is the Persona's: a small window itself, or else the space of a main window.
    private func focusedWindowID(of personaID: Persona.ID, in session: BrowserSession) -> UUID? {
        guard let window = session.windows.first, !window.isPrivate, window.personaID == personaID else { return nil }
        return window.kind == .small ? window.id : window.currentSpaceID
    }

    // MARK: WebExtensionHost

    var extensionRuntimeVersions: [EngineKind: String] {
        session?.extensionRuntimeVersions ?? [:]
    }

    func extensionEngines(in persona: PersonaID) -> [EngineKind: any EngineExtensions] {
        session?.extensionEngines(in: persona) ?? [:]
    }

    func webContents(ofTab id: UUID) -> (any EngineWebContents)? {
        session?.allTabs.first { $0.id == id && !$0.isPrivate }?.webContents
    }

    /// The window that shows the tab selects it again, or else the front main window that shows the tab's space, which the extensions see as the tab's window, so that another window keeps its space; otherwise a window selects it as for a tab no window shows, which takes a favorite's tab to a window of its Persona.
    func activate(_ tab: any EngineWebContents) {
        guard let session, let tab = self.tab(tab) else { return }
        if let window = session.window(showing: tab) ?? session.windows.first(where: { !$0.isPrivate && $0.kind == .main && $0.currentSpaceID == tab.spaceID }) {
            window.selectTab(tab.id)
        } else {
            session.selectUnshownTab(tab)
        }
    }

    /// ⌘Z reopens only the tabs the user just closed, newest first, so a close that puts its record ahead of theirs ends that, as a page's own close does.
    func close(_ tab: any EngineWebContents) {
        guard let session, let tab = self.tab(tab) else { return }
        let remembers = TabCloseAction.of(tab, reason: .webExtension) == .close(remember: true)
        if session.closeTab(tab, reason: .webExtension), remembers { session.forgetUndoableCloses() }
    }

    func present(_ popup: EngineExtensionPopup, for tab: (any EngineWebContents)?) -> Bool {
        guard let session else { return false }
        let window = if let tab { self.tab(tab).flatMap(session.window(showing:)) } else { session.windows.first }
        guard let window, !window.isPrivate, let anchor = window.siteControlAnchor(window.siteSettingsButtonView) else { return false }
        ExtensionPopupPresenter.present(popup, relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
        return true
    }

    /// The tab opens among the space's open tabs, a small window's space for a small window, which holds one tab: before the tab at `index` among the space's tabs of the engine when that one is an open tab outside folders and the window is a space, else after the space's active tab when that one is, else at their end. The extensions hear of it at once, before the completion. It downloads as a tab that the user opens does, as other browsers download what an extension's tabs open: a file at its address downloads as a normal download, and its pages' downloads go through the tab's gate, whose first goes on (`PageDownloadGate`). Arch cannot tell a `tabs.create` that the user's click in the extension's popup or options page starts from the extension's own call, so neither is held as a script plugin's tab is.
    func openTab(_ url: URL?, in engine: EngineKind, persona: PersonaID, window windowID: UUID?, active: Bool, index: Int?, completion: @escaping ((any EngineWebContents)?) -> Void) {
        guard let session, session.personas.contains(where: { $0.id == persona }) else { return completion(nil) }
        let windows = extensionWindows(of: persona, in: session)
        let named = windows.first { $0.id == windowID }
        let window = (named?.space ?? focusedSpace(of: persona, in: session)).flatMap { space in windows.first { $0.id == space.id } }
        // An index among a small window's tabs says nothing about its space's.
        let namesSmallWindow = named.map { $0.id != $0.space.id } ?? false
        let index = namesSmallWindow ? nil : index
        let space = window?.space ?? session.preferredSpace(in: persona)
        let tab = session.openTab(url: url, in: space.id, select: false, engine: engine)
        let listed = window?.tabs.filter { $0.engineKind == engine } ?? []
        let isPlacedAtIndex = index.map { listed.indices.contains($0) && session.placeTab(tab, nextTo: listed[$0], after: false) } ?? false
        if !isPlacedAtIndex, let activeTab = window?.active {
            session.placeTab(tab, nextTo: activeTab, after: true)
        }
        if active { activate(tab.webContents) }
        reportToEveryPersona()
        completion(tab.webContents)
    }

    /// A small window with the page, or the new tab page for none, as its one tab, which belongs to the Persona's focused space or its preferred one; extensions see it as a new window that lists only that tab. A request for several pages opens nothing, since a small window holds one tab. Without `focused`, the window that was key stays key. Its tab downloads as one that `openTab` opens does.
    func openWindow(with urls: [URL], in engine: EngineKind, persona: PersonaID, focused: Bool, completion: @escaping (UUID?) -> Void) {
        guard let session, session.personas.contains(where: { $0.id == persona }), urls.count <= 1 else { return completion(nil) }
        let space = focusedSpace(of: persona, in: session) ?? session.preferredSpace(in: persona)
        let keyWindow = NSApp.keyWindow
        let window = session.openSmallWindow(url: urls.first, engine: engine, spaceID: space.id, personaID: persona)
        if !focused { keyWindow?.makeKeyAndOrderFront(nil) }
        reportToEveryPersona()
        completion(window.id)
    }

    /// Shows the question as a card over the tab, or without a tab over the tab of the window that last became main. A question for a tab that has closed, or without any tab, gets the safe answer. The card shows the extension's action icon for the tab as the site settings popover does, or the extension symbol without one.
    func ask(_ question: WebExtensionQuestion, for tab: (any EngineWebContents)?, completion: @escaping (Bool) -> Void) {
        guard let session, let tab = if let tab { self.tab(tab) } else { session.focusedTab }, !tab.isPrivate else { return completion(false) }
        let icon = question.pluginID.flatMap { id in session.webExtensions(in: tab.personaID)?.actions(for: tab.webContents).first { $0.id == id }?.action?.icon }
        let content = TabPromptContent.extensionQuestion(question, icon: icon, identity: PromptSiteIdentity.make(for: tab.url, in: tab))
        session.enqueuePrompt(content, for: tab) { completion(TabPromptContent.extensionAnswer($0)) }
    }

    /// Opens the store sheet in Settings ▸ Plugins through the session's `installFromWebStore`, as the site settings popover's Web Store row does: in the Persona, with the tab's space, or for a favorite's tab the space of the window that shows it, which the review names with the Persona (Persona rule 7). A tab that has closed starts nothing.
    func installFromWebStore(_ id: String, persona: PersonaID, tab webContents: any EngineWebContents) {
        guard let session, session.personas.contains(where: { $0.id == persona }), let tab = self.tab(webContents) else { return }
        let space = session.window(showing: tab).flatMap { window in
            BrowserWindowModel.sheetSpace(ofTabIn: tab.spaceID, personaID: persona, spaces: session.spaces, currentSpace: window.currentSpace)
        } ?? session.spaces.first { $0.id == tab.spaceID }
        session.installFromWebStore?(persona, space?.id, id)
    }

    /// The open tab whose web contents `webContents` is.
    private func tab(_ webContents: any EngineWebContents) -> Tab? {
        session?.allTabs.first { $0.webContents === webContents && !$0.isPrivate }
    }
}
