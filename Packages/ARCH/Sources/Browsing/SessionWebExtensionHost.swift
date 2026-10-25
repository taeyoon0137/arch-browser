// The session as the host of its Personas' web extensions: it starts their profiles in the engines, selects and closes tabs for them, shows their popups and access sheets in its windows, and reports its windows to them. Arch's tabs live in spaces, which windows show, so each space of a Persona is a window to its extensions: its tabs in sidebar order, the favorites' tabs that a window shows on it first, and its active tab, the one a window shows there or else the one selected last. The window that last became main has the focused one.
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

    /// Reports the Persona's windows to the runtime now and each time they change.
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
        let spaces = session.spaces.filter { $0.resolvedPersonaID == personaID }
        // A favorite's tab belongs to no space: it is in the Persona's space where a window shows it, or else in the Persona's first space.
        let favoriteTabs = Dictionary(grouping: session.openFavoriteTabs.filter { $0.personaID == personaID }) { tab in
            let shownIn = session.windows.first { $0.selectedTabID == tab.id }?.currentSpaceID
            return spaces.contains { $0.id == shownIn } ? shownIn : spaces.first?.id
        }
        let windows = spaces.map { space in
            let showing = session.windows.filter { $0.currentSpaceID == space.id }
            let tabs = (favoriteTabs[space.id] ?? []) + session.tabs(in: space.id, pinned: true) + session.tabs(in: space.id, pinned: false)
                + session.tabs.filter { $0.spaceID == space.id && $0.isInSmallWindow }
            let active = showing.lazy.compactMap(\.selectedTab).first { tab in tabs.contains { $0 === tab } } ?? tabs.max { $0.lastActivatedAt < $1.lastActivatedAt }
            return EngineExtensionWindow(id: space.id, tabs: tabs.map(\.webContents), activeTab: active?.webContents, window: showing.first?.nsWindow)
        }
        let focusedSpaceID = session.windows.first?.currentSpaceID
        runtime.setWindows(windows, focusedWindowID: spaces.contains { $0.id == focusedSpaceID } ? focusedSpaceID : nil)
    }

    // MARK: WebExtensionHost

    func extensionEngines(in persona: PersonaID) -> [any EngineExtensions] {
        session?.extensionEngines(in: persona) ?? []
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

    func present(_ popup: NSPopover, for tab: (any EngineWebContents)?) -> Bool {
        guard let session else { return false }
        let window = if let tab { self.tab(tab).flatMap(session.window(showing:)) } else { session.windows.first }
        guard let window, let anchor = window.siteControlAnchor(window.siteSettingsButtonView) else { return false }
        popup.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
        return true
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
