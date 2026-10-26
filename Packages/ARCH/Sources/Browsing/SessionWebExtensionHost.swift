// The session as the host of its Personas' web extensions: it starts their profiles in the engines, opens, selects, and closes tabs for them, opens windows for them, shows their popups and sheets in its windows, and reports its windows to them. Arch's tabs live in spaces, which windows show, so each space of a Persona is a window to its extensions: its tabs in sidebar order, the favorites' tabs that a window shows on it first, and its active tab, the one a window shows there or else the one selected last. The window that last became main has the focused one.
import AppKit
import ARCHEngine
import Combine
import Extensions
import Plugins

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
        let windows = spaceWindows(of: personaID, in: session).map { window in
            EngineExtensionWindow(id: window.space.id, tabs: window.tabs.map(\.webContents), activeTab: window.active?.webContents, window: window.showing?.nsWindow)
        }
        runtime.setWindows(windows, focusedWindowID: focusedSpace(of: personaID, in: session)?.id)
    }

    /// Each space of the Persona as its extensions' window: its tabs in order, its active tab, and the first window that shows it.
    private func spaceWindows(of personaID: Persona.ID, in session: BrowserSession) -> [(space: Space, tabs: [Tab], active: Tab?, showing: BrowserWindowModel?)] {
        let spaces = session.spaces.filter { $0.resolvedPersonaID == personaID }
        // A favorite's tab belongs to no space: it is in the Persona's space where a window shows it, or else in the Persona's first space.
        let favoriteTabs = Dictionary(grouping: session.openFavoriteTabs.filter { $0.personaID == personaID }) { tab in
            let shownIn = session.windows.first { $0.selectedTabID == tab.id }?.currentSpaceID
            return spaces.contains { $0.id == shownIn } ? shownIn : spaces.first?.id
        }
        return spaces.map { space in
            let showing = session.windows.filter { $0.currentSpaceID == space.id }
            let tabs = (favoriteTabs[space.id] ?? []) + session.tabs(in: space.id, pinned: true) + session.tabs(in: space.id, pinned: false)
                + session.tabs.filter { $0.spaceID == space.id && $0.isInSmallWindow }
            let active = showing.lazy.compactMap(\.selectedTab).first { tab in tabs.contains { $0 === tab } } ?? tabs.max { $0.lastActivatedAt < $1.lastActivatedAt }
            return (space, tabs, active, showing.first)
        }
    }

    /// The space of the window that last became main, when it is the Persona's.
    private func focusedSpace(of personaID: Persona.ID, in session: BrowserSession) -> Space? {
        session.windows.first.map(\.currentSpace).flatMap { $0.resolvedPersonaID == personaID ? $0 : nil }
    }

    // MARK: WebExtensionHost

    var extensionRuntimeVersions: [EngineKind: String] {
        session?.extensionRuntimeVersions ?? [:]
    }

    func extensionEngines(in persona: PersonaID) -> [EngineKind: any EngineExtensions] {
        session?.extensionEngines(in: persona) ?? [:]
    }

    func webContents(ofTab id: UUID) -> (any EngineWebContents)? {
        session?.allTabs.first { $0.id == id }?.webContents
    }

    /// The window that shows the tab selects it again; otherwise a window selects it as for a tab no window shows, which takes a favorite's tab to a window of its Persona.
    func activate(_ tab: any EngineWebContents) {
        guard let session, let tab = self.tab(tab) else { return }
        if let window = session.window(showing: tab) {
            window.selectTab(tab.id)
        } else {
            session.selectUnshownTab(tab)
        }
    }

    func close(_ tab: any EngineWebContents) {
        guard let tab = self.tab(tab) else { return }
        session?.closeTab(tab, reason: .webExtension)
    }

    func present(_ popup: EngineExtensionPopup, for tab: (any EngineWebContents)?) -> Bool {
        guard let session else { return false }
        let window = if let tab { self.tab(tab).flatMap(session.window(showing:)) } else { session.windows.first }
        guard let window, let anchor = window.siteControlAnchor(window.siteSettingsButtonView) else { return false }
        ExtensionPopupPresenter.present(popup, relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
        return true
    }

    /// The tab opens among the space's open tabs: before the tab at `index` among the window's tabs of the engine when that one is an open tab outside folders, else after the window's active tab when that one is, else at their end. The extensions hear of it at once, before the completion.
    func openTab(_ url: URL?, in engine: EngineKind, persona: PersonaID, window windowID: UUID?, active: Bool, index: Int?, completion: @escaping ((any EngineWebContents)?) -> Void) {
        guard let session, session.personas.contains(where: { $0.id == persona }) else { return completion(nil) }
        let windows = spaceWindows(of: persona, in: session)
        let window = windows.first { $0.space.id == windowID } ?? focusedSpace(of: persona, in: session).flatMap { space in windows.first { $0.space.id == space.id } }
        let space = window?.space ?? session.preferredSpace(in: persona)
        let tab = session.openTab(url: url, in: space.id, select: false, engine: engine)
        let listed = window?.tabs.filter { $0.engineKind == engine } ?? []
        if let index, listed.indices.contains(index) {
            session.placeTab(tab, nextTo: listed[index], after: false)
        } else if let activeTab = window?.active {
            session.placeTab(tab, nextTo: activeTab, after: true)
        }
        if active { activate(tab.webContents) }
        reportToEveryPersona()
        completion(tab.webContents)
    }

    /// A main window on the Persona's focused space, or its preferred one, with the pages as new tabs of that space, the first one selected; extensions see the space as the window. Without `focused`, the window that was key stays key.
    func openWindow(with urls: [URL], in engine: EngineKind, persona: PersonaID, focused: Bool, completion: @escaping (UUID?) -> Void) {
        guard let session, session.personas.contains(where: { $0.id == persona }) else { return completion(nil) }
        let space = focusedSpace(of: persona, in: session) ?? session.preferredSpace(in: persona)
        let keyWindow = NSApp.keyWindow
        let window = session.openWindow(onSpace: space.id)
        let tabs = (urls.isEmpty ? [nil] : urls.map { Optional($0) }).map { session.openTab(url: $0, in: space.id, select: false, engine: engine) }
        window.selectTab(tabs.first?.id)
        if !focused { keyWindow?.makeKeyAndOrderFront(nil) }
        reportToEveryPersona()
        completion(space.id)
    }

    /// Without a tab, the sheet is for the tab of the window that last became main. A sheet for a tab that has closed, or without any tab, gets the safe answer.
    func presentSheet(_ alert: NSAlert, for tab: (any EngineWebContents)?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let session, let tab = if let tab { self.tab(tab) } else { session.focusedTab } else { return completion(.cancel) }
        session.enqueueSheet(alert, for: tab, completion: completion)
    }

    /// The open tab whose web contents `webContents` is.
    private func tab(_ webContents: any EngineWebContents) -> Tab? {
        session?.allTabs.first { $0.webContents === webContents }
    }
}
