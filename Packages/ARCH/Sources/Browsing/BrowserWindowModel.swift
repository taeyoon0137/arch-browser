// A browser window's state and commands live here. A main window shows a space, selected tab and split view, internal or fullscreen page, preview, reader, question popover, and prompt cards.
// It also holds the palette, find, renaming, region capture, tab switcher, docked developer tools, and sharing. A small window shows only its one tab.
// The session owns Personas, spaces, favorites, tabs, folders, split views, closed tabs, downloads, pending prompts, reader conversations, engines, and persistence.
import Agent
import AI
import AppKit
import ARCHEngine
import Combine
import Foundation
import PDFKit
import Plugins
import SwiftUI
import UniformTypeIdentifiers

/// Whether a browser window has a sidebar or shows a single tab on its own.
public enum BrowserWindowKind {
    /// A window with the sidebar. `session.json` keeps the main windows.
    case main
    /// A window without a sidebar for one tab, which `session.json` does not keep. It opens for a link from another app while Arch is in the background, for a page that a small window's page or preview opens, and for an extension's `windows.create`. Its tab stays out of its space's list until it moves to a main window, and the window closes with the tab.
    case small
}

/// The state of one browser window: what it shows and what the user is doing in it. Its commands read and change the user's data through the session.
@MainActor public final class BrowserWindowModel: ObservableObject {
    unowned let session: BrowserSession
    /// The window's identity in `session.json`, which it keeps across launches.
    let id: UUID
    public let kind: BrowserWindowKind
    public let privateSessionID: UUID?
    /// An agent-owned private window never shares storage with tabs opened by the user or another agent.
    let privateOwnerID: UUID?
    public var isPrivate: Bool { privateSessionID != nil }
    public var privateTabs: [Tab] {
        guard let privateSessionID else { return [] }
        return session.tabs.filter { $0.privateSessionID == privateSessionID }
    }
    /// The AppKit window, set when it is created. Window sheets, printing, export, and sharing use it.
    public weak var nsWindow: NSWindow?
    private var recentPreviewSourceClick: (point: CGPoint, timestamp: TimeInterval, windowNumber: Int)?
    /// The window's frame outside full screen, in screen coordinates: the saved one, where the window opens, then the one the window controller records as the window moves and resizes. `nil` until the window opens, when the window has no saved frame.
    var restorableFrame: CGRect?

    // MARK: State: what the window shows

    /// The space the sidebar shows. A small window has no sidebar; its current space is the space its tab moves to, whose tint it shows.
    @Published public var currentSpaceID: UUID {
        didSet { if oldValue != currentSpaceID { closeSidebarPanel() } }
    }
    /// The selected tab, or nil for the empty page. Only `selectTab(_:)` changes it, because a selection does more than show the tab.
    @Published public private(set) var selectedTabID: UUID?
    /// Each window remembers its selected item separately for every space of each Persona.
    private enum SpaceSelection {
        case favorite(UUID), tab(UUID), empty
    }
    private var spaceSelections: [Persona.ID: [Space.ID: SpaceSelection]] = [:]
    /// Republishes the selected tab's changes, so that views that read the tab through the window refresh.
    private var selectedTabObserver: AnyCancellable?
    /// The tabs whose pages the window shows, left to right: its selected tab and each other pane of its split view that no other window shows. At most one window shows a tab (window rule 1), because a page's view has one superview. The list under Panes and split view tells it from the window's other lists of panes.
    @Published private(set) var shownTabIDs: [UUID] = [] {
        // Every window's sidebar dims the rows of the tabs that another window shows, so the session announces the change too.
        willSet { session.objectWillChange.send() }
    }
    /// The internal page covering the page area, opened by its address from the command palette.
    @Published public private(set) var internalPage: InternalPage?
    /// The tab whose page fills the window in fullscreen. Only engines that leave the transition to the app report it; WebKit shows fullscreen in its own window. The other panes of a split view leave the screen meanwhile, and their prompts wait until the panes return.
    @Published public private(set) var fullscreenTabID: UUID? {
        // A page in fullscreen takes the docked sidebar off the screen, and a sidebar panel's page ends with it.
        didSet { if fullscreenTabID != nil { closeSidebarPanel() } }
    }
    /// The page in the preview panel over the page area, or nil while no panel shows. Its web contents belongs to no tab.
    @Published private(set) var preview: PagePreview?
    /// User dismissal fades the panel before its live page closes. Programmatic teardown stays immediate.
    @Published private(set) var isPreviewDismissing = false
    private var previewDismissal: DispatchWorkItem?
    private var previewDismissalReleasedFocus = false
    /// Hiding the sidebar closes a sidebar panel: its page ends with the docked column, and the floating card does not take it over.
    @Published public var isSidebarVisible = true {
        didSet { if !isSidebarVisible { closeSidebarPanel() } }
    }
    /// The selected library tab. Each window keeps its choice; new windows and launches use the last saved choice.
    @Published var libraryTab = LibraryTab(rawValue: UserDefaults.standard.string(forKey: LibraryTab.defaultsKey) ?? "") ?? .downloads {
        didSet {
            UserDefaults.standard.set(libraryTab.rawValue, forKey: LibraryTab.defaultsKey)
            if isLibraryVisible && libraryTab == .downloads { session.markDownloadsSeen() }
        }
    }
    /// Requests focus in the library's history search without changing its query.
    @Published private(set) var libraryHistorySearchRequest = 0
    /// The current Persona's history state survives replacement of the sidebar's view host.
    private var retainedLibraryHistory: LibraryHistoryModel?
    /// Opening the library marks downloads as seen only when Downloads is selected.
    @Published public var isLibraryVisible = false {
        didSet {
            if isLibraryVisible {
                if libraryTab == .downloads { session.markDownloadsSeen() }
                closeSidebarPanel()
            }
        }
    }
    /// A plugin panel shown in place of the current space's tab list.
    @Published private(set) var sidebarPanel: SidebarPluginPanel?
    private var sidebarPanelObserver: AnyCancellable?
    /// Whether the page reader shows beside the page.
    @Published public private(set) var isPageReaderVisible = false
    /// What the agent panel shows in the trailing column in place of the page reader, or nil while it is hidden; only one of the two shows.
    @Published public private(set) var agentPanel: AgentPanelContent?
    /// Unsubmitted tasks belong to this window and their original spaces.
    private var agentDrafts: [Space.ID: AgentComposerContext] = [:]
    private var draftSpaceObserver: AnyCancellable?
    /// The question popover over the selected tab's page while it is open. It closes when another tab is selected or the tab loads another page.
    @Published private(set) var pageQuestion: PageQuestion?
    /// Where the selected tab's developer tools show.
    public let devToolsDock = DevToolsDock()

    // MARK: State: what the user does in the window

    /// `nil` when the command palette is hidden.
    @Published var siteRuleToast: SiteRuleToast?
    @Published public var commandPaletteMode: CommandPaletteMode?
    /// Counts palette openings and mode changes so each gets a fresh view.
    @Published public private(set) var commandPaletteGeneration = 0
    /// Where the open palette came from, which sets the direction it appears from.
    @Published public private(set) var commandPaletteOrigin = CommandPaletteOrigin.keyboard
    @Published public private(set) var isFindBarVisible = false
    /// Counts the requests to focus the find bar's field, such as ⌘F while the bar is already open.
    @Published public private(set) var findBarFocusRequests = 0
    /// The text in the find bar. Each change searches the selected tab while the bar is visible.
    @Published public var findText = "" {
        didSet { if findText != oldValue { runFind(forward: true) } }
    }
    /// The last result for `findText`. `nil` while no search has finished.
    @Published public private(set) var findResult: EngineFindResult?
    /// Advances with each search, so that only the latest search's result shows: an earlier one, as from the tab selected before, can arrive after it.
    private var findGeneration = 0
    /// The space whose name is being edited in the sidebar.
    @Published public var renamingSpaceID: UUID?
    /// The tab whose name is being edited in the sidebar.
    @Published public var renamingTabID: UUID?
    /// The folder whose name is being edited in the sidebar.
    @Published public var renamingFolderID: UUID?

    /// The tab whose page shows the region capture overlay, from Capture Region until the user drags out a region or cancels.
    @Published public private(set) var regionCaptureTabID: UUID?
    /// The tab whose prompt card has the keyboard focus, which the card's layer sets (`PanePromptLayer`).
    @Published var focusedPromptTabID: UUID?
    /// Counts the requests for the selected tab's card to take the focus, as `focusPage()` makes while the card shows.
    @Published private(set) var promptFocusRequests = 0
    /// The fields over the selected tab's page that have the keyboard focus, as they report it (`PageField`), which a card over that page counts as the page's.
    @Published private(set) var focusedPageFields: Set<PageField> = []

    /// Tab identifiers in the order the tabs were last selected, most recent first. Tabs not selected since launch are missing.
    private var activationOrder: [UUID] = []
    /// The tab the switcher highlights, which releasing Control selects. `nil` while the switcher is hidden.
    @Published public private(set) var tabSwitcherHighlightID: UUID?

    /// Set while the selected page renders as PDF for Print or Export as PDF, so a second request cannot start another.
    private var isRenderingPDF = false

    /// The share button in the address pill, set when it joins the window.
    weak var shareButtonView: NSView?
    /// The site settings button in the address pill, which web extensions' popups point at, set when it joins the window.
    weak var siteSettingsButtonView: NSView?
    /// The picker holds its delegate weakly, so the last one stays here until the next share.
    private var sharePicker: PageSharePicker?

    /// A window of `kind` as `record` describes it: its ID, space, sidebar, and frame. The session selects its tab once the window exists.
    init(session: BrowserSession, record: SessionSnapshot.WindowRecord, kind: BrowserWindowKind, privateSessionID: UUID? = nil, privateOwnerID: UUID? = nil) {
        self.session = session
        id = record.id
        self.kind = kind
        self.privateSessionID = privateSessionID
        self.privateOwnerID = privateOwnerID
        currentSpaceID = record.currentSpaceID
        isSidebarVisible = record.isSidebarVisible
        restorableFrame = record.frame
        draftSpaceObserver = session.$spaces.dropFirst().sink { [weak self] spaces in
            guard let self, !agentDrafts.isEmpty else { return }
            agentDrafts = agentDrafts.filter { spaceID, draft in
                spaces.contains { $0.id == spaceID && $0.resolvedPersonaID == draft.personaID }
            }
            if case .composer(let draft) = agentPanel, agentDrafts[draft.spaceID] == nil { hideAgentPanel() }
        }
    }

    // MARK: Selection

    public var selectedTab: Tab? {
        session.tabs.first { $0.id == selectedTabID } ?? session.favoriteTabs.values.first { $0.id == selectedTabID }
    }

    /// Selects the tab `id`, or the empty page for nil, and does what a selection does, in this order (`docs/windows-personas.md`, `BrowserWindowModel`). Selecting the tab already selected runs every step except the end of step 2.
    ///
    /// 1. Every other window that shows the tab gives it up (window rule 2): a main window keeps it selected behind a placeholder (open decision 5), and a small window closes. Then the window shows the tab. Selecting the tab already selected behind a placeholder takes it back so.
    /// 2. The window leaves its internal page and another tab's page fullscreen, stamps the tab's activation, clears its unread dot, follows its space, and, while the agent panel shows an outside client, switches it to the client that owns the newly selected agent tab. Only for another tab, the command palette, the search, and the question popover, which belong to the old tab's page, close.
    /// 3. The session updates the focused tab.
    /// 4. The docked developer tools follow the tab.
    /// 5. The window republishes the tab's changes, and keyboard focus leaves another pane of the split view.
    ///
    /// The prompts of the tabs that left the screen wait, and the panes that show a tab with a prompt show its card (`PanePromptLayer`). Step 1 can close another window, so every step reads the selection as it is when the step runs, not `id`.
    public func selectTab(_ id: UUID?) {
        if let id, let tab = session.allTabs.first(where: { $0.id == id }), tab.privateSessionID != privateSessionID { return }
        if let tab = session.allTabs.first(where: { $0.id == id }),
           tab.personaID != personaID || (tab.spaceID != nil && tab.spaceID != currentSpaceID) {
            rememberSpaceSelection()
        }
        let previousID = selectedTabID
        selectedTabID = id
        // 1. Another window that shows the tab lets go of its page fullscreen and docked tools, then the window shows its selected tab (`release` updates every window's panes, this one's too).
        session.release(selectedTab, except: self)
        // 2. Selecting a tab, even the one under the page, leaves an internal page.
        internalPage = nil
        // Another tab ends the fullscreen of the page that filled the window.
        if fullscreenTabID != nil, fullscreenTabID != selectedTabID { exitPageFullscreen() }
        selectedTab?.lastActivatedAt = Date()
        recordActivation()
        if previousID != selectedTabID, case .client = agentPanel, let owner = selectedTab?.agentOwnerID, session.agents?.panel.owners[owner] != nil {
            showClientPanel(owner)
        }
        if let tab = selectedTab, tab.isUnread { tab.isUnread = false }
        // A favorite can be shown in any space of its Persona, including when a session in another Persona links to it.
        if let tab = selectedTab, !isPrivate {
            if let spaceID = tab.spaceID, spaceID != currentSpaceID { currentSpaceID = spaceID }
            else if tab.spaceID == nil && personaID != tab.personaID { currentSpaceID = session.preferredSpace(in: tab.personaID).id }
        }
        // Only another tab.
        if previousID != selectedTabID {
            // Another tab takes the focus, so a palette left open over the old page closes, as when a link from another app or Move to Main Window selects a tab.
            if commandPaletteMode != nil { commandPaletteMode = nil }
            // Switching tabs ends the search because it belongs to one page.
            if isFindBarVisible {
                session.allTabs.first { $0.id == previousID }?.webContents.stopFind()
                isFindBarVisible = false
                findResult = nil
            }
            // The question popover belongs to the page it opened over.
            closePageQuestion()
        }
        // 3.
        session.windowDidSelect(self)
        // 4.
        devToolsDock.track(selectedTab)
        // 5.
        followSelectedTab()
        focusSelectedPane()
    }

    /// Republishes changes from the selected tab through the window model.
    private func followSelectedTab() {
        selectedTabObserver = selectedTab?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Spaces

    public var currentSpace: Space {
        session.spaces.first { $0.id == currentSpaceID } ?? session.spaces[0]
    }

    /// The Persona whose favorites, tabs, and plugins the window offers: the current space's, which for a small window is its tab's.
    public var personaID: Persona.ID { privateSessionID ?? currentSpace.resolvedPersonaID }

    /// Adds a space to the window's Persona and shows it.
    public func addSpace() {
        guard !isPrivate else { return }
        switchToSpace(session.makeSpace(in: personaID).id)
    }

    /// Shows a space with this window's last selected item there, or its first free tab without a valid memory.
    public func switchToSpace(_ id: UUID) {
        guard !isPrivate else { return }
        guard let space = session.spaces.first(where: { $0.id == id }) else { return }
        isLibraryVisible = false
        guard currentSpaceID != id else { return }
        rememberSpaceSelection()
        currentSpaceID = id
        // Merging or deleting a space moves its tabs first; keep the selected tab as the window follows it.
        if selectedTab?.spaceID == id { return }
        if !restoreSelection(in: space) { selectTab(firstFreeTab(inSpace: id)?.id) }
    }

    private func rememberSpaceSelection() {
        guard kind == .main, let space = session.spaces.first(where: { $0.id == currentSpaceID }) else { return }
        let selection: SpaceSelection
        if let tab = selectedTab {
            guard tab.personaID == space.resolvedPersonaID else { return }
            if let favoriteID = selectedFavoriteID {
                selection = .favorite(favoriteID)
            } else {
                guard tab.spaceID == space.id, tab.isListedInSidebar else { return }
                selection = .tab(tab.id)
            }
        } else {
            selection = .empty
        }
        spaceSelections[space.resolvedPersonaID, default: [:]][space.id] = selection
    }

    private func restoreSelection(in space: Space) -> Bool {
        guard let selection = spaceSelections[space.resolvedPersonaID]?[space.id] else { return false }
        switch selection {
        case .favorite(let id):
            guard let favorite = session.favorites(in: space.resolvedPersonaID).first(where: { $0.id == id }) else { return false }
            openFavorite(favorite)
        case .tab(let id):
            guard let tab = session.tabs.first(where: {
                $0.id == id && $0.spaceID == space.id && $0.personaID == space.resolvedPersonaID && $0.isListedInSidebar
            }) else { return false }
            selectTab(tab.id)
        case .empty:
            selectTab(nil)
        }
        return true
    }

    /// The first tab row of the space that the sidebar shows and no other window shows, open tabs before pinned ones (window rule 3). Only a space whose free tabs all sit in collapsed folders gives a hidden tab.
    func firstFreeTab(inSpace id: UUID) -> Tab? {
        let tree = session.folderTree
        let spaceTabs = (tree.tabs(in: id, pinned: false) + tree.tabs(in: id, pinned: true)).filter { !isShownInAnotherWindow($0) }
        return spaceTabs.first { !tree.isInCollapsedFolder($0) } ?? spaceTabs.first
    }

    /// Moves to the next or previous space, wrapping at either end.
    public func switchToAdjacentSpace(forward: Bool) {
        let spaces = session.spaces
        guard let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let next = (index + (forward ? 1 : spaces.count - 1)) % spaces.count
        switchToSpace(spaces[next].id)
    }

    /// Keeps the old name when the new one is empty.
    public func renameSpace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { session.updateSpace(id) { $0.name = trimmed } }
        renamingSpaceID = nil
    }

    /// The name the tab's row shows already (`Tab.shownTitle`), which its rename field starts with, changes nothing. An empty name or the page's own title as the row names the page (`Tab.shownPageTitle`), the extension's name for an extension's page without a title, restores the page's title, which hooks then leave until the tab moves to another address. The session saves the name, as it saves every change to a tab.
    public func renameTab(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tab = session.tabs.first(where: { $0.id == id }), trimmed != tab.shownTitle {
            if trimmed.isEmpty || trimmed == tab.shownPageTitle {
                tab.customTitle = nil
                tab.suggestedTitle = tab.url.map { SuggestedTitle(title: nil, url: $0) }
            } else {
                tab.customTitle = trimmed
            }
        }
        endRenaming(id)
    }

    /// Does not interrupt renaming another tab that may have started meanwhile.
    public func endRenaming(_ id: UUID) {
        if renamingTabID == id { renamingTabID = nil }
    }

    // MARK: Personas

    /// Whether New Persona…, Rename Persona…, and Delete Persona… can ask with their sheet: the window shows no other sheet, which theirs would wait behind.
    public var canShowPersonaSheet: Bool { !isPrivate && nsWindow?.attachedSheet == nil }

    /// Asks for a name in a sheet on the window, then adds a Persona with that name and shows its space. Create stays disabled until the field holds a name.
    public func promptForNewPersona() {
        askForPersonaName(title: localized("New Persona"), message: localized("A Persona has its own spaces and plugins, and its tabs keep their own cookies and website data."), name: "", button: localized("Create")) { [weak self] name in
            guard let self else { return }
            let persona = self.session.addPersona(named: name)
            if let space = self.session.spaces(in: persona.id).first { self.switchToSpace(space.id) }
        }
    }

    /// Asks for the Persona's new name in a sheet on the window. Rename stays disabled while the field holds no name.
    public func promptToRenamePersona(_ id: Persona.ID) {
        guard let persona = session.persona(withID: id) else { return }
        askForPersonaName(title: localized("Rename Persona"), message: nil, name: persona.name, button: localized("Rename")) { [weak self] name in
            self?.session.renamePersona(id, to: name)
        }
    }

    /// Asks with a sheet on the window before deleting the Persona of `space`, the space menu's space or the window's current space, unless it is the default Persona, saying what goes with it.
    public func confirmDeletePersona(ofSpace space: Space) {
        let id = space.resolvedPersonaID
        guard canShowPersonaSheet, session.canDeletePersona(id), let persona = Self.sheetName(ofPersona: id, space: space, among: session.personas), let nsWindow else { return }
        let texts = Self.deletePersonaTexts(persona: persona, spaceCount: session.spaces(in: id).count, favoriteCount: session.favorites(in: id).count,
                                            tabCount: session.tabs.filter { $0.personaID == id }.count,
                                            downloadCount: session.downloads.count { $0.personaID == id && !$0.isFinished }, siteRuleCount: session.siteRules.rules.count { $0.personaID == id }, isSyncing: session.isSidebarSyncEnabled)
        let alert = NSAlert()
        alert.messageText = texts.message
        alert.informativeText = texts.information
        alert.addButton(withTitle: localized("Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: localized("Cancel"))
        alert.beginSheetModal(for: nsWindow) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.session.deletePersona(id) }
        }
    }

    /// The Delete Persona sheet's question and explanation, for `persona` as `sheetName(ofPersona:space:among:)` names it and the counts of what goes. The explanation leaves out what the Persona has none of, and names one space, tab, or download without a number, as the Quit sheet names one download; every Persona has a space.
    nonisolated static func deletePersonaTexts(persona: String, spaceCount: Int, favoriteCount: Int, tabCount: Int, downloadCount: Int, siteRuleCount: Int = 0, isSyncing: Bool = false) -> (message: String, information: String) {
        // Each sentence is whole in the string catalog, so that a translation can order its parts.
        let removed: String
        if tabCount == 0 {
            removed = switch (spaceCount == 1, favoriteCount) {
            case (true, 0): localized("Its space is removed.")
            case (true, 1): localized("Its space and 1 favorite are removed.")
            case (true, _): localized("Its space and \(favoriteCount) favorites are removed.")
            case (false, 0): localized("Its \(spaceCount) spaces are removed.")
            case (false, 1): localized("Its \(spaceCount) spaces and 1 favorite are removed.")
            case (false, _): localized("Its \(spaceCount) spaces and \(favoriteCount) favorites are removed.")
            }
        } else {
            let spaces = switch (spaceCount == 1, favoriteCount) {
            case (true, 0): localized("Its space is removed")
            case (true, 1): localized("Its space and 1 favorite are removed")
            case (true, _): localized("Its space and \(favoriteCount) favorites are removed")
            case (false, 0): localized("Its \(spaceCount) spaces are removed")
            case (false, 1): localized("Its \(spaceCount) spaces and 1 favorite are removed")
            case (false, _): localized("Its \(spaceCount) spaces and \(favoriteCount) favorites are removed")
            }
            removed = tabCount == 1 ? localized("\(spaces), and its tab closes into the closed list.") : localized("\(spaces), and its \(tabCount) tabs close into the closed list.")
        }
        let downloads = downloadCount == 0 ? "" : downloadCount == 1 ? " " + localized("Its download in progress stops.") : " " + localized("Its \(downloadCount) downloads in progress stop.")
        var information = removed + downloads + " " + localized("Arch removes its plugins, cookies, and website data from this Mac the next time it opens.")
        if siteRuleCount > 0 { information += " " + localized("Its \(siteRuleCount) site rules are deleted too.") }
        if isSyncing { information += " " + localized("It is also deleted on your other Macs that sync with iCloud, which remove its cookies and website data too.") }
        return (localized("Delete \(persona)?"), information)
    }

    /// Merge Space Into…: a sheet on the window lists the spaces the space can merge into (`BrowserSession.spaceMergeTargets(for:)`), each as "Persona / Space" (Persona rule 7), says what moves and what is removed, and merges into the chosen space on Merge.
    public func confirmMergeSpace(_ space: Space) {
        let targets = session.spaceMergeTargets(for: space.id)
        guard canShowPersonaSheet, !targets.isEmpty else { return }
        let name = { (space: Space) in BrowserSession.displayedPlace(ofPersona: space.resolvedPersonaID, space: space, among: self.session.personas) ?? space.name }
        let texts = Self.mergeSpaceTexts(space: name(space), isSyncing: session.isSidebarSyncEnabled)
        askForMergeTarget(message: texts.message, information: texts.information, targets: targets.map { ($0.id, name($0)) }) { [weak self] target in
            self?.session.mergeSpace(space.id, into: target)
        }
    }

    /// Merge Persona Into…: a sheet on the window lists the Personas that the Persona of `space` can merge into (`BrowserSession.personaMergeTargets(for:)`), says what moves and that its cookies and sign-ins are deleted, and merges on Merge. A failed plugin install stops the merge and shows its error.
    public func confirmMergePersona(ofSpace space: Space) {
        let id = space.resolvedPersonaID
        let targets = session.personaMergeTargets(for: id)
        guard canShowPersonaSheet, !targets.isEmpty, let persona = Self.sheetName(ofPersona: id, space: space, among: session.personas) else { return }
        let texts = Self.mergePersonaTexts(persona: persona, isSyncing: session.isSidebarSyncEnabled)
        askForMergeTarget(message: texts.message, information: texts.information, targets: targets.map { ($0.id, $0.name) }) { [weak self] target in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.session.mergePersona(id, into: target) } catch {
                    guard let nsWindow = self.nsWindow else { return }
                    let alert = NSAlert()
                    alert.messageText = localized("The Persona could not be merged.")
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: nsWindow, completionHandler: nil)
                }
            }
        }
    }

    /// The Merge Space Into… sheet's question and explanation, for the space as "Persona / Space" names it.
    nonisolated static func mergeSpaceTexts(space: String, isSyncing: Bool = false) -> (message: String, information: String) {
        var information = localized("Its pinned tabs, folders, and open tabs move to the space you choose, after that space’s own, and \u{201C}\(space)\u{201D} is removed.")
            + " " + localized("In a space of another Persona, they reload in that Persona’s profile, without their pages’ sign-ins and back and forward history.")
        if isSyncing { information += " " + localized("Your other Macs that sync with iCloud make the same change.") }
        return (localized("Merge \u{201C}\(space)\u{201D} into another space?"), information)
    }

    /// The Merge Persona Into… sheet's question and explanation, for `persona` as `sheetName(ofPersona:space:among:)` names it.
    nonisolated static func mergePersonaTexts(persona: String, isSyncing: Bool = false) -> (message: String, information: String) {
        var information = localized("Its spaces move to the Persona you choose with their names, and its favorites follow that Persona’s. Its tabs reload in that Persona’s profile, and plugins and extensions it lacks are installed there with the permissions you gave them.")
            + " " + localized("Then the Persona is removed. Its cookies and sign-ins are not carried over: Arch deletes them and its website data from this Mac the next time it opens.")
        if isSyncing { information += " " + localized("Your other Macs that sync with iCloud make the same change.") }
        return (localized("Merge \(persona) into another Persona?"), information)
    }

    /// Asks in a sheet on the window which of `targets` to merge into, with a pop-up button that starts at the first, and passes the chosen ID to `merge` on Merge.
    private func askForMergeTarget(message: String, information: String, targets: [(id: UUID, name: String)], then merge: @escaping (UUID) -> Void) {
        guard let nsWindow else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.addButton(withTitle: localized("Merge"))
        alert.addButton(withTitle: localized("Cancel"))
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        // Items added one by one keep two targets of the same name, which `addItems(withTitles:)` would join.
        for target in targets { picker.menu?.addItem(NSMenuItem(title: target.name, action: nil, keyEquivalent: "")) }
        alert.accessoryView = picker
        alert.beginSheetModal(for: nsWindow) { response in
            let index = picker.indexOfSelectedItem
            guard response == .alertFirstButtonReturn, targets.indices.contains(index) else { return }
            merge(targets[index].id)
        }
    }

    /// How a sheet or a card about a whole Persona names it from where it starts (Persona rule 7): "the Persona of “Work / Research”" from a place with a space, "the Persona “Work”" without one, or nil while the default Persona is the only one. A favorite's tab takes the window's current space (`sheetSpace(ofTabIn:personaID:spaces:currentSpace:)`), so the Persona alone remains only as a guard for a tab shown outside every space of its Persona.
    nonisolated static func sheetName(ofPersona id: Persona.ID, space: Space?, among personas: [Persona]) -> String? {
        guard let place = BrowserSession.displayedPlace(ofPersona: id, space: space, among: personas) else { return nil }
        return space == nil ? localized("the Persona \u{201C}\(place)\u{201D}") : localized("the Persona of \u{201C}\(place)\u{201D}")
    }

    /// Asks for a Persona's name in a sheet with a text field on the window, which starts with `name`, and passes the name without surrounding spaces to `use` unless the user cancels. The sheet's `button` stays disabled while the field is empty or holds only spaces, so that Return cannot close the sheet without a name.
    private func askForPersonaName(title: String, message: String?, name: String, button: String, then use: @escaping (String) -> Void) {
        guard canShowPersonaSheet, let nsWindow else { return }
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let confirm = alert.addButton(withTitle: button)
        alert.addButton(withTitle: localized("Cancel"))
        let field = NSTextField(string: name)
        field.placeholderString = localized("Persona Name")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let hasName = { !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        confirm.isEnabled = hasName()
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
            MainActor.assumeIsolated { confirm.isEnabled = hasName() }
        }
        alert.beginSheetModal(for: nsWindow) { response in
            NotificationCenter.default.removeObserver(observer)
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !name.isEmpty { use(name) }
        }
    }

    // MARK: Home pages

    /// Whether the selected tab shows a web page that can become a space's home page. An internal page over it has no address to use.
    public var canSetCurrentPageAsHome: Bool {
        guard !isPrivate else { return false }
        guard internalPage == nil, let scheme = selectedTab?.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Makes the selected tab's page the home page of the space `id`, which need not be the current space.
    public func setCurrentPageAsHome(ofSpace id: UUID) {
        guard canSetCurrentPageAsHome, let url = selectedTab?.url else { return }
        session.updateSpace(id) { $0.homeURL = url }
    }

    /// Home needs a home page for the current space and no internal page or preview over the tab.
    public var canGoHome: Bool { !isPrivate && !isSelectedPageCovered && currentSpace.homeURL != nil }

    /// Loads the current space's home page in the selected tab, or in a new tab when no tab is selected.
    public func goHome() {
        guard canGoHome, let url = currentSpace.homeURL else { return }
        guard let tab = selectedTab else {
            openTab(url: url)
            return
        }
        tab.forgetExternalAppDecline()
        tab.userDidNavigate()
        tab.pendingCause = nil
        tab.webContents.navigationController.load(URLRequest(url: url))
    }

    // MARK: Favorites

    /// Selects the favorite's own tab, which the session opens if needed.
    public func openFavorite(_ favorite: Favorite) {
        guard !isPrivate else { return }
        selectTab(session.openTab(for: favorite).id)
    }

    /// The favorite whose tab is selected.
    public var selectedFavoriteID: UUID? {
        session.favoriteTabs.first { $0.value.id == selectedTabID }?.key
    }

    // MARK: Saved pages

    /// Tab ▸ Go Back to Saved Page: the selected tab, a pinned tab or a favorite's tab, is off its saved page (bookmark rule 3), and no internal page or preview covers it, as for Home.
    public var canGoBackToSavedPage: Bool {
        !isSelectedPageCovered && selectedTab.map(session.isOffSavedPage) == true
    }

    /// Returns the selected saved tab to its pinned or favorite address when it has moved away.
    public func goBackToSavedPage() {
        guard canGoBackToSavedPage, let tab = selectedTab else { return }
        session.goBackToSavedPage(tab)
    }

    /// Tab ▸ Use Current Page as Saved Page: the selected tab is pinned, or a favorite's tab whose page no other favorite of the Persona has, and has an address.
    public var canUseCurrentPageAsSavedPage: Bool {
        selectedTab.map(session.canUseCurrentPageAsSavedPage) == true
    }

    /// Replaces the selected saved tab's saved page with its current page when allowed.
    public func useCurrentPageAsSavedPage() {
        selectedTab.map(session.useCurrentPageAsSavedPage)
    }

    /// Tab ▸ Edit Saved Address…: the selected tab is pinned and the window shows no other sheet, which this one would wait behind. A favorite's tile has Edit Favorite… instead.
    public var canEditSavedAddress: Bool {
        selectedTab?.isPinned == true && nsWindow?.attachedSheet == nil
    }

    /// Opens the saved address sheet for the selected pinned tab when available.
    public func promptToEditSavedAddress() {
        guard canEditSavedAddress, let tab = selectedTab else { return }
        promptToEditSavedAddress(of: tab)
    }

    /// Edit Saved Address…: asks for a pinned tab's saved address in a sheet on the window, prefilled with it. Text that is no address beeps and changes nothing.
    func promptToEditSavedAddress(of tab: Tab) {
        guard tab.isPinned else { return }
        let address = (tab.savedPage?.url ?? tab.url)?.absoluteString ?? ""
        askForText(title: localized("Edit Saved Address"), message: localized("Go Back to Saved Page returns \u{201C}\(tab.shownTitle)\u{201D} to this address."), fields: [(localized("Address"), address)], button: localized("Save")) { [weak tab] texts in
            if tab?.setSavedAddress(fromInput: texts[0]) != true { NSSound.beep() }
        }
    }

    /// Edit Favorite…: asks for a favorite's name and address in a sheet on the window, prefilled with them. An empty name keeps the old one; an address that is no address, or another favorite's, beeps and changes nothing.
    func promptToEditFavorite(_ favorite: Favorite) {
        askForText(title: localized("Edit Favorite"), message: nil, fields: [(localized("Name"), favorite.title), (localized("Address"), favorite.url.absoluteString)], button: localized("Save")) { [weak self] texts in
            if self?.session.editFavorite(favorite.id, name: texts[0], address: texts[1]) != true { NSSound.beep() }
        }
    }

    /// Duplicate: opens a copy of the tab after it and selects it here.
    func duplicate(_ tab: Tab) {
        if isPrivate {
            guard tab.privateSessionID == privateSessionID else { return }
            _ = session.openPrivateTab(url: tab.url, in: self, engine: tab.preferredEngine)
            return
        }
        guard let copy = session.duplicateTab(tab) else { return }
        selectTab(copy.id)
    }

    /// Asks in a sheet on the window with one labeled text field for each of `fields`, which starts with its value, and passes the fields' text to `use` when the user chooses `button`. Nothing shows while the window shows another sheet.
    private func askForText(title: String, message: String?, fields: [(label: String, value: String)], button: String, then use: @escaping ([String]) -> Void) {
        guard let nsWindow, nsWindow.attachedSheet == nil, !fields.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: localized("Cancel"))
        let textFields = fields.map { field in
            let textField = NSTextField(string: field.value)
            textField.setAccessibilityLabel(field.label)
            textField.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return textField
        }
        let grid = NSGridView(views: zip(fields, textFields).map { field, textField in
            [NSTextField(labelWithString: "\(field.label):"), textField]
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize
        zip(textFields, textFields.dropFirst()).forEach { $0.nextKeyView = $1 }
        alert.accessoryView = grid
        alert.window.initialFirstResponder = textFields[0]
        alert.beginSheetModal(for: nsWindow) { response in
            if response == .alertFirstButtonReturn { use(textFields.map(\.stringValue)) }
        }
    }

    // MARK: Previews

    /// Preserve the input location while a renderer delivers the resulting navigation asynchronously.
    func recordPreviewSourceEvent(_ event: NSEvent) {
        guard let window = nsWindow, event.window === window,
              [.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type) else {
            recentPreviewSourceClick = nil
            return
        }
        recentPreviewSourceClick = (event.locationInWindow, event.timestamp, window.windowNumber)
    }

    private func previewPresentationPoint() -> CGPoint? {
        guard let window = nsWindow else { return nil }
        if let event = NSApp.currentEvent, event.window === window,
           [.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type) {
            let elapsed = ProcessInfo.processInfo.systemUptime - event.timestamp
            if elapsed >= 0 && elapsed <= 0.5 { return event.locationInWindow }
        }
        if let click = recentPreviewSourceClick, click.windowNumber == window.windowNumber {
            let elapsed = ProcessInfo.processInfo.systemUptime - click.timestamp
            if elapsed >= 0 && elapsed <= 0.5 { return click.point }
        }
        return window.mouseLocationOutsideOfEventStream
    }

    /// Whether an internal page or the preview panel covers the selected tab's page, so that the commands for the page in front, and the site settings popover, leave the tab alone.
    var isSelectedPageCovered: Bool { internalPage != nil || preview != nil }

    /// Previews a favorite in the default engine and the favorite's Persona, which opening the favorite would use.
    func previewFavorite(_ favorite: Favorite) {
        showPreview(of: favorite.url, engine: session.defaultEngine, in: favorite.resolvedPersonaID)
    }

    /// Shows `url` in the panel, in place of any other preview, in a web contents of the Persona's runtime for `engine` that no tab owns. A preview opened with the same address, Persona and requested engine stays as it is. The preview refuses downloads. User dismissal closes its page after the fade; programmatic teardown is immediate.
    func showPreview(of url: URL, engine: EngineKind, in personaID: Persona.ID) {
        guard !isPrivate, session.personas.contains(where: { $0.id == personaID }) else { return }
        if let preview, preview.openedURL == url, preview.personaID == personaID, preview.requestedEngine == engine {
            cancelPreviewDismissal(restoringFocus: true)
            return
        }
        let sourcePoint = previewPresentationPoint()
        let source = previewPresentationSource(in: personaID, opener: nil, point: sourcePoint)
        guard let runtime = session.runtime(for: engine, in: personaID) else { return NSSound.beep() }
        let webContents = runtime.browser.createWebContents(EngineWebContentsConfiguration(initialURL: url))
        showPreview(webContents, openedURL: url, in: personaID, requestedEngine: engine,
                    presentationSourcePoint: sourcePoint, presentationSource: source)
    }

    /// Takes an engine's new page into Peek without reloading, preserving the native request and opener.
    func showPreview(_ webContents: any EngineWebContents, openedURL: URL, in personaID: Persona.ID,
                     requestedEngine: EngineKind, opener: (any EngineWebContents)? = nil, presentationSourcePoint: CGPoint? = nil,
                     presentationSource: PagePreview.PresentationSource? = nil) {
        guard !isPrivate, session.personas.contains(where: { $0.id == personaID }) else { return }
        let sourcePoint = presentationSourcePoint ?? previewPresentationPoint()
        let source = presentationSource ?? (presentationSourcePoint == nil ? previewPresentationSource(in: personaID, opener: opener, point: sourcePoint) : nil)
        closePreview()
        // The panel covers the page that a search, a region capture, or the question popover belongs to, so all three end.
        hideFindBar()
        cancelRegionCapture()
        closePageQuestion()
        guard let runtime = session.runtime(for: webContents.engineKind, in: personaID) else { return NSSound.beep() }
        let preview = PagePreview(webContents: webContents, personaID: personaID, requestedEngine: requestedEngine, openedURL: openedURL)
        if let point = sourcePoint {
            preview.presentationSourceRectInWindow = CGRect(x: point.x - 40, y: point.y - 20, width: 80, height: 40)
        }
        preview.opener = opener
        // A page opened by the preview keeps the preview as its native opener. Both become tabs; the panel leaves on the next run loop turn, after the engine's callback.
        preview.openNewTab = { [weak self, weak preview] popup in
            guard let self, let preview else { return }
            runtime.browser.takeOwnership(of: popup)
            self.showOpenedPage(preview.webContents, personaID: personaID, opener: preview.opener, preferredEngine: preview.requestedEngine)
            self.showOpenedPage(popup, personaID: personaID, opener: preview.webContents, preferredEngine: preview.requestedEngine)
            DispatchQueue.main.async { [weak self] in
                if let self, self.preview === preview { self.removePreview(closingPage: false) }
            }
        }
        // A preview asks the user nothing, so its page's permission requests are denied without changing the profile's kept answers.
        preview.requestPermission = { [weak self] request, completion in
            guard let self else { return completion(false) }
            if self.isPrivate { return completion(false) }
            self.session.permissionAnswers.denyWithoutAsking(request, personaID: personaID, in: runtime.context, completion: completion)
        }
        preview.didClose = { [weak self] in self?.closePreview() }
        preview.presentationDidBecomeReady = { [weak self, weak preview] in
            guard let self, let preview, self.preview === preview else { return }
            self.objectWillChange.send()
            if let window = self.nsWindow, window.firstResponder === window { self.focusPage() }
        }
        if let source {
            preview.preparePresentation(from: source) { [weak self, weak preview] in
                guard let self, let preview, self.preview === preview, !self.isPreviewDismissing,
                      let tab = source.tab else { return false }
                return self.shows(tab) && tab.personaID == personaID && self.nsWindow === source.window
            }
        }
        self.preview = preview
        nsWindow?.makeFirstResponder(nil)
        focusPage()
    }

    private func previewPresentationSource(in personaID: Persona.ID, opener: (any EngineWebContents)?, point: CGPoint?) -> PagePreview.PresentationSource? {
        guard preview == nil, internalPage == nil, let window = nsWindow, let point else { return nil }
        let tab = opener.flatMap { page in session.allTabs.first { $0.webContents === page } } ?? selectedTab
        guard let tab, tab.personaID == personaID, shows(tab) else { return nil }
        return PagePreview.PresentationSource(tab: tab, window: window, point: point)
    }

    /// Transfers the live page into a tab in the current space, retaining its form state, history, engine, and opener.
    func openPreviewInTab() {
        guard let tab = takePreviewAsTab() else { return }
        let destination = kind == .main ? self : session.regularWindow(in: tab.spaceID ?? currentSpaceID)
        destination.selectTab(tab.id)
        if destination !== self { destination.nsWindow?.makeKeyAndOrderFront(nil) }
        destination.focusPage()
    }

    /// Moves the same live page into a new regular window in its space.
    func openPreviewInNewWindow() {
        guard let tab = takePreviewAsTab(), let spaceID = tab.spaceID else { return }
        let destination = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: spaceID,
                                                         selectedTabID: tab.id, isSidebarVisible: true), kind: .main)
        destination.selectTab(tab.id)
        destination.nsWindow?.makeKeyAndOrderFront(nil)
        destination.focusPage()
    }

    /// Detaches the panel before the page gets another host. No navigation or engine recreation occurs.
    private func takePreviewAsTab() -> Tab? {
        guard !isPrivate, let preview, session.personas.contains(where: { $0.id == preview.personaID }) else { return nil }
        removePreview(closingPage: false)
        return session.adopt(preview.webContents, spaceID: currentSpaceID, personaID: preview.personaID,
                             pinned: false, select: false, opener: preview.opener, preferredEngine: preview.requestedEngine)
    }

    /// Dismisses a panel without retiring its page halfway through its presentation animation.
    func dismissPreview() {
        guard let preview, !isPreviewDismissing else { return }
        guard preview.isPresentationReady else { return closePreview() }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return closePreview() }
        isPreviewDismissing = true
        let pageView = preview.webContents.view
        if let window = nsWindow, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: pageView) {
            // The fading page takes neither pointer events nor typing. App fields keep their own focus.
            previewDismissalReleasedFocus = window.makeFirstResponder(nil)
        }
        let dismissal = DispatchWorkItem { [weak self, weak preview] in
            guard let self, let preview, self.preview === preview, self.isPreviewDismissing else { return }
            self.closePreview()
        }
        previewDismissal = dismissal
        let duration = preview.presentationSourceRectInWindow == nil ? PagePreviewOverlay.fadeDuration : PagePreviewPanel.dismissalDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
    }

    private func cancelPreviewDismissal(restoringFocus: Bool = false) {
        let shouldRestoreFocus = restoringFocus && previewDismissalReleasedFocus && previewDismissalStillOwnsFocus
        previewDismissal?.cancel()
        previewDismissal = nil
        isPreviewDismissing = false
        previewDismissalReleasedFocus = false
        if shouldRestoreFocus { focusPage() }
    }

    private var previewDismissalStillOwnsFocus: Bool {
        guard let window = nsWindow else { return false }
        return window.firstResponder === window
    }

    /// Closes the panel and its page immediately for engine and window teardown.
    func closePreview() {
        removePreview(closingPage: true)
    }

    /// Removes the panel and, with `closingPage`, closes its page; without, a tab has taken the page. Keyboard focus returns to the selected tab's page when it was in the panel, unless the click that closed the panel gave it to a field.
    private func removePreview(closingPage: Bool) {
        let releasedFocus = previewDismissalReleasedFocus && previewDismissalStillOwnsFocus
        cancelPreviewDismissal()
        guard let preview else { return }
        let pendingPresentationOwnedFocus = !preview.isPresentationReady && previewDismissalStillOwnsFocus
        preview.cancelPresentationPreparation()
        preview.presentationDidBecomeReady = nil
        self.preview = nil
        let view = preview.webContents.view
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        // A page that a tab took, as the preview's page does when it opens another, stays open with that tab, also when the panel closes before the next turn of the run loop removes it.
        if closingPage, !session.allTabs.contains(where: { $0.webContents === preview.webContents }) {
            // The page stops reporting to the panel before it closes.
            preview.webContents.uiDelegate = nil
            session.retire(preview.webContents, of: preview.personaID)
        }
        if hadFocus || releasedFocus || pendingPresentationOwnedFocus { focusPage(leaving: view) }
    }

    // MARK: Tabs

    /// Opens a tab at `url` in the current space and the default engine, and selects it.
    func openTab(url: URL) {
        if isPrivate { _ = session.openPrivateTab(url: url, in: self); return }
        selectTab(session.openTab(url: url, in: currentSpaceID, select: false).id)
    }

    /// Shows a page that one of the window's pages or its preview opened, which a runtime of the Persona created, in a new tab: selected in the current space of a main window, or in a small window of its own beside a small window, which shows only its tab (open decision 11). A page of another Persona, as from a preview that stayed open while the window moved to another Persona's space, goes to its Persona's preferred space instead. `opener` is the page that opened it, which the window returns to when the new page closes itself.
    func showOpenedPage(_ webContents: any EngineWebContents, personaID: Persona.ID, opener: (any EngineWebContents)? = nil, preferredEngine: EngineKind? = nil) {
        if let id = privateSessionID {
            guard personaID == id else { return }
            if privateOwnerID != nil {
                _ = session.openPrivateTab(url: webContents.url, in: self, engine: preferredEngine ?? webContents.engineKind)
                session.retire(webContents, of: id)
                return
            }
            let tab = session.adoptPrivate(webContents, sessionID: id, ownerID: nil, opener: opener)
            if let preferredEngine { tab.preferredEngine = preferredEngine }
            selectTab(tab.id)
            return
        }
        switch kind {
        case .main:
            selectTab(session.adopt(webContents, spaceID: currentSpaceID, personaID: personaID, pinned: false, select: false, opener: opener, preferredEngine: preferredEngine).id)
        case .small: session.openSmallWindow(webContents, spaceID: currentSpaceID, personaID: personaID, opener: opener, preferredEngine: preferredEngine)
        }
    }

    /// Whether the selected tab's page fills the window in fullscreen, without margins or the controls around the page.
    var isPageFullscreen: Bool { fullscreenTabID != nil && fullscreenTabID == selectedTabID }

    /// Records whether the tab's page fills the window.
    func setPageFullscreen(_ isFullscreen: Bool, of tab: Tab) {
        if isFullscreen {
            fullscreenTabID = tab.id
        } else if fullscreenTabID == tab.id {
            fullscreenTabID = nil
        }
    }

    /// The preview panel or an internal page is what the user sees, so it closes instead of the tab under it. A window with no tab selected closes itself while another browser window stays open.
    public func closeSelectedTab() {
        if preview != nil { return dismissPreview() }
        if internalPage != nil { return closeInternalPage() }
        if let tab = selectedTab { return session.requestCloseTab(tab) }
        if session.windows.count > 1 { nsWindow?.performClose(nil) }
    }

    /// Closes other tabs in the selected tab's space, keeping pinned tabs, the tabs of small windows, and agents' tabs. A small window has no other tabs.
    public func closeOtherTabs() {
        if isPrivate {
            privateTabs.filter { $0.id != selectedTabID }.forEach(session.requestCloseTab)
            return
        }
        guard kind == .main, let selected = selectedTab else { return }
        for tab in session.tabs where tab.spaceID == selected.spaceID && tab.isListedInSidebar && !tab.isPinned && tab.agentOwnerID == nil && tab.id != selected.id {
            session.requestCloseTab(tab)
        }
    }

    /// The current space's tab rows in sidebar order: pinned first, then open. A collapsed folder, at any level, shows only the selected tab.
    private var orderedTabs: [Tab] {
        if isPrivate { return privateTabs }
        let tree = session.folderTree
        return (tree.tabs(in: currentSpaceID, pinned: true) + tree.tabs(in: currentSpaceID, pinned: false)).filter { $0.id == selectedTabID || !tree.isInCollapsedFolder($0) }
    }

    /// Selects a tab by its visible sidebar position when the index exists.
    public func selectTab(at index: Int) {
        let ordered = orderedTabs
        guard ordered.indices.contains(index) else { return }
        selectTab(ordered[index].id)
    }

    /// Selects the last visible tab in the current space.
    public func selectLastTab() {
        if let last = orderedTabs.last { selectTab(last.id) }
    }

    /// The ⌘-number shortcut for `tab`: 1 to 8 for the current space's first eight tabs, or 9 for its last tab beyond those.
    public func shortcutNumber(for tab: Tab) -> Int? {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == tab.id }) else { return nil }
        if index < 8 { return index + 1 }
        return index == ordered.count - 1 ? 9 : nil
    }

    /// Selects the next or previous visible tab in sidebar order, wrapping at either end.
    public func selectAdjacentTab(forward: Bool) {
        let ordered = orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectTab(ordered[(index + (forward ? 1 : ordered.count - 1)) % ordered.count].id)
    }

    /// Swaps the selected tab with its neighbor in its folder, or among its space's pinned or open tabs outside folders.
    public func moveSelectedTab(up: Bool) {
        selectedTab.map { session.moveTab($0, up: up) }
    }

    /// Loads a URL when the text parses as one, otherwise runs a web search.
    public func navigate(to input: String) {
        guard let url = BrowserSession.destination(forInput: input, siteSearch: session.siteSearch) else { return }
        if let tab = selectedTab {
            tab.forgetExternalAppDecline()
            tab.userDidNavigate()
            tab.pendingCause = nil
            tab.webContents.navigationController.load(URLRequest(url: url))
        } else {
            openTab(url: url)
        }
    }

    // MARK: Command palette

    /// Opens the palette in a mode and records where it appeared from.
    public func showCommandPalette(_ mode: CommandPaletteMode, from origin: CommandPaletteOrigin = .keyboard) {
        commandPaletteOrigin = origin
        if commandPaletteMode != mode { commandPaletteGeneration += 1 }
        commandPaletteMode = mode
    }
    /// Closes the palette and returns keyboard focus to the page.
    public func dismissCommandPalette() {
        commandPaletteMode = nil
        focusPage()
    }

    /// Opens an internal page, navigates the selected tab, or opens a new tab for the submitted text.
    public func submitCommandPalette(_ input: String, bypassSiteRules: Bool = false) {
        defer {
            commandPaletteMode = nil
            focusPage()
        }
        if let page = InternalPage(address: input) { return internalPage = page }
        guard let mode = commandPaletteMode, let url = BrowserSession.destination(forInput: input, siteSearch: session.siteSearch) else { return }
        internalPage = nil
        if !isPrivate, !bypassSiteRules, let destination = session.destination(forOpening: currentSpace, url: url) {
            session.openRoutedTab(url: url, destination: destination, source: self, background: false)
            return
        }
        switch mode {
        case .editCurrent where selectedTab != nil: navigate(to: input)
        case .editCurrent, .newTab: openTab(url: url)
        }
    }

    public func focusCommandBar(from origin: CommandPaletteOrigin = .keyboard) { showCommandPalette(selectedTab == nil ? .newTab : .editCurrent, from: origin) }

    /// Reveals the selected tab and returns keyboard focus to its page.
    public func closeInternalPage() {
        internalPage = nil
        focusPage()
    }

    /// Ends the fullscreen of the page that fills the window, as Escape does.
    public func exitPageFullscreen() {
        guard let id = fullscreenTabID else { return }
        fullscreenTabID = nil
        session.allTabs.first { $0.id == id }?.webContents.exitFullscreen()
    }

    /// Whether the selected tab has a prompt, which its card shows over the page unless an internal page covers it. The page's own commands, such as find, printing, and Clear Site Data, wait for the answer.
    var hasPromptOnSelectedTab: Bool { session.prompts.hasPrompt(for: selectedTabID) }

    /// Returns keyboard focus to the page after the palette or the question popover closes. Runs after the next layout pass so a new tab's view is in the window, and leaves a page that another window has taken in the meantime alone. Given the view that focus is `leaving`, focus moves only while it is still there or nowhere, so a field the user clicked in the meantime keeps it.
    func focusPage(leaving previous: NSView? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPreviewDismissing, self.preview?.isPresentationReady != false,
                  let view = self.preview?.webContents.view ?? self.selectedTab?.webContents.view,
                  let window = view.window, window === self.nsWindow else { return }
            if let previous, let responder = window.firstResponder, responder !== window,
               (responder as? NSView)?.isDescendant(of: previous) != true { return }
            // Keys must not reach a page an internal page covers.
            guard self.preview != nil || self.internalPage == nil else {
                window.makeFirstResponder(nil)
                return
            }
            // A card over the page takes the keys in its place.
            if self.preview == nil, self.hasPromptOnSelectedTab {
                self.promptFocusRequests += 1
                return
            }
            window.makeFirstResponder(Self.viewTakingFocus(in: view))
        }
    }

    /// The view that takes the keys of a page whose engine view is `view`: the engine view when it takes focus, as WebKit's page view does, which passes it to its web view, or else the topmost visible view inside it that does. On Chromium that is the current page's view within CEF's view, the one CEF focuses, because CEF's view takes no focus: keys sent to it reach no view, and while it has the window's focus AppKit can hold it, though CEF closes the browser only once that view is released (`DetachBrowserView` in the bridge). Topmost first, because the page lies above views the adapter keeps below it, such as a Chromium video's picture-in-picture source view. Visible first, because Chromium adds each page's view below the others and only hides the view of a page it leaves for another site, which stays above while that page is in the back-forward cache. While every such view is hidden, as while Chromium has not shown a new page's view yet, the topmost one; `nil`, which leaves the focus to the window, while no view takes it, as before the engine has made the page's view.
    static func viewTakingFocus(in view: NSView) -> NSView? {
        viewTakingFocus(in: view, skippingHidden: true) ?? viewTakingFocus(in: view, skippingHidden: false)
    }

    /// Finds the frontmost descendant that accepts focus, optionally ignoring hidden views.
    private static func viewTakingFocus(in view: NSView, skippingHidden: Bool) -> NSView? {
        if view.acceptsFirstResponder { return view }
        return view.subviews.reversed().lazy
            .filter { !(skippingHidden && $0.isHidden) }
            .compactMap { viewTakingFocus(in: $0, skippingHidden: skippingHidden) }
            .first
    }

    /// Moves keyboard focus to the selected tab's page, or its card, from another pane of the split view on screen, whose page or card stays in the window and would keep the keys. Checks after the event that changed the selection, so a pane that a click selected has taken focus itself by then and keeps the element focused in it.
    private func focusSelectedPane() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isFocusInOtherPane = self.tabsOnScreen.contains { pane in
                let view = pane.webContents.view
                return pane.id != self.selectedTabID && (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
            }
            let isFocusOnOtherCard = self.focusedPromptTabID.map { $0 != self.selectedTabID } ?? false
            if isFocusInOtherPane || isFocusOnOtherCard { self.focusPage() }
        }
    }

    /// Records whether a field over the selected tab's page has the keyboard focus (`PageField`).
    func pageField(_ field: PageField, isFocused: Bool) {
        guard focusedPageFields.contains(field) != isFocused else { return }
        if isFocused { focusedPageFields.insert(field) } else { focusedPageFields.remove(field) }
    }

    // MARK: Plugins

    /// A plugin panel shown in the sidebar for one space.
    struct SidebarPluginPanel {
        let spaceID: Space.ID
        let title: String
        let controller: NSViewController
    }

    /// Shows a plugin's sidebar panel while its space and plugin remain active.
    func showSidebarPanel(_ controller: NSViewController, for item: Attributed<PluginSidebarItem>, in space: Space.ID, plugins: PluginManager) {
        guard !isPrivate else { return }
        guard currentSpaceID == space else { return }
        closeSidebarPanel()
        sidebarPanel = SidebarPluginPanel(spaceID: space, title: item.item.title, controller: controller)
        (controller as? any PluginEndingPanel)?.onEnd = { [weak self] in self?.closeSidebarPanel() }
        sidebarPanelObserver = plugins.$plugins.sink { [weak self] installed in
            guard let self, self.sidebarPanel?.controller === controller else { return }
            if !installed.contains(where: { $0.id == item.plugin && $0.isEnabled }) { self.closeSidebarPanel() }
        }
    }

    /// Detaches and dismisses the plugin panel shown in the sidebar. The panel's page ends when its view leaves the window, so the panel closes whenever the column that shows it goes: on Back, a change of space, the library, hiding the sidebar, a page entering fullscreen, or the floating card closing.
    func closeSidebarPanel() {
        (sidebarPanel?.controller as? any PluginEndingPanel)?.onEnd = nil
        sidebarPanelObserver = nil
        sidebarPanel = nil
    }

    /// The plugins of the window's Persona, whose contributions the window shows.
    var plugins: PluginManager {
        session.plugins(in: personaID)
    }

    /// Runs a plugin command on the selected tab through the plugins of the window's Persona, as the palette, the Plugins menu, and sidebar items do.
    public func runPluginCommand(_ command: PluginCommandRef, source: PluginInvocation.Source = .menu, argument: String? = nil) {
        guard !isPrivate else { return }
        let invocation = PluginInvocation(tab: selectedPluginTab(of: personaID), source: source, argument: argument)
        let plugins = self.plugins
        Task { await plugins.run(command, invocation) }
    }

    /// Runs a plugin command from a tab row's context menu on that tab, with the plugins of the tab's Persona.
    func runPluginCommand(_ command: PluginCommandRef, onTab tab: Tab) {
        guard !isPrivate else { return }
        let invocation = PluginInvocation(tab: session.pluginTab(tab), source: .contextMenu)
        Task { await session.plugins(in: tab.personaID).run(command, invocation) }
    }

    /// Runs a plugin command from a space's menu on the selected tab, with the space and the plugins of its Persona.
    func runPluginCommand(_ command: PluginCommandRef, inSpace space: Space) {
        guard !isPrivate else { return }
        let invocation = PluginInvocation(tab: selectedPluginTab(of: space.resolvedPersonaID), spaceID: space.id)
        Task { await session.plugins(in: space.resolvedPersonaID).run(command, invocation) }
    }

    /// The selected tab, for the plugins of `personaID`, before the manager applies a plugin's grant: for their commands, and for their `selectedTab()` from the window that last became main. A plugin sees only its Persona's tabs, so it gets no tab of another Persona, such as a favorite's, and none while an internal page or the preview panel covers the tab's page.
    func selectedPluginTab(of personaID: Persona.ID) -> PluginTab? {
        guard !isPrivate else { return nil }
        guard !isSelectedPageCovered, let tab = selectedTab, tab.personaID == personaID else { return nil }
        return session.pluginTab(tab)
    }

    // MARK: Page reader and questions

    /// The reader opens beside a selected tab that no internal page covers, and closes at any time.
    public var canTogglePageReader: Bool {
        guard !isPrivate else { return false }
        return isPageReaderVisible || (selectedTab != nil && internalPage == nil)
    }

    /// Shows or hides the page reader. Showing it summarizes the selected tab's page unless its conversation has begun or AI is off for its site; hiding it has the session stop the reader's replies (`BrowserSession.pageReaderDidHide`). The agent panel, which takes the same place, closes.
    public func togglePageReader() {
        guard !isPrivate else { return }
        withAnimation(SidebarView.pageSpring) {
            isPageReaderVisible.toggle()
            if isPageReaderVisible { agentPanel = nil }
        }
        if isPageReaderVisible {
            selectedTab.map(session.pageAssistant.readerDidShow)
        } else {
            session.pageReaderDidHide(in: self)
        }
    }

    // MARK: Agent panel

    /// Whether a connected model can run a session, for the palette's Ask Agent row and Continue as Agent Task.
    var canStartAgentTask: Bool {
        guard !isPrivate else { return false }
        return !(session.agents?.agentModels().isEmpty ?? true)
    }

    /// Where a session started in this window goes and what it starts with: the window's current space, which for a small window is the space Move to Main Window would use, its Persona, and the selected tab unless an internal page or the preview covers it.
    func agentComposerContext(text: String = "") -> AgentComposerContext {
        Self.agentComposerContext(in: currentSpace, personas: session.personas, selectedTab: selectedTab.map(BrowserAgentHost.info(of:)),
                                  isPageCovered: isSelectedPageCovered, text: text)
    }

    /// The context for `space` and its Persona among `personas`, named "Persona / Space", with `selectedTab` unless an internal page or the preview covers its page.
    static func agentComposerContext(in space: Space, personas: [Persona], selectedTab: AgentTabInfo?, isPageCovered: Bool, text: String) -> AgentComposerContext {
        let persona = personas.first { $0.id == space.resolvedPersonaID }?.name ?? localized("Default")
        return AgentComposerContext(personaID: space.resolvedPersonaID, spaceID: space.id, place: "\(persona) / \(space.name)", tab: isPageCovered ? nil : selectedTab, text: text)
    }

    /// The sidebar command is about its row, including a background tab, while the window keeps its selected page.
    func sidebarAgentDraft(for tab: Tab, settings: AISettingsStore? = nil) -> AgentComposerContext? {
        guard !isPrivate, !tab.isPrivate else { return nil }
        let settings = settings ?? AIService.shared.settings
        guard kind == .main, session.agents != nil, settings.route(for: .agent).isEnabled, tab.personaID == personaID, tab.isLoaded,
              session.allTabs.contains(where: { $0 === tab }) else { return nil }
        return Self.sidebarAgentDraft(for: BrowserAgentHost.info(of: tab), in: currentSpace, personas: session.personas, allowsAI: settings.allowsAI(on:))
    }

    /// Builds a draft for a sidebar tab only when it belongs to the space and can be attached.
    static func sidebarAgentDraft(for tab: AgentTabInfo, in space: Space, personas: [Persona], allowsAI: (URL) -> Bool) -> AgentComposerContext? {
        // An open favorite belongs to its Persona across spaces. Its window supplies the task's destination.
        guard tab.spaceID == nil || tab.spaceID == space.id else { return nil }
        let context = agentComposerContext(in: space, personas: personas, selectedTab: tab, isPageCovered: false, text: "")
        return context.attachableTab(allowsAI: allowsAI) == nil ? nil : context
    }

    /// Opens a reviewed sidebar tab in the agent composer, dropping its attachment if the page changed.
    func askAgentAboutSidebarTab(_ tab: Tab, reviewed: AgentComposerContext, settings: AISettingsStore? = nil) {
        guard let context = sidebarAgentDraft(for: tab, settings: settings), context.spaceID == reviewed.spaceID, context.personaID == reviewed.personaID,
              let document = context.tab, let original = reviewed.tab, document.id == original.id else { return }
        // A page the user did not see while the menu showed is never attached, as with askAgent.
        if document.documentID != original.documentID || document.url != original.url {
            context.tab = nil
            context.problem = localized("The page changed. Review the task before starting.")
        }
        showAgentPanel(.composer(context))
    }

    /// File ▸ New Agent Task: the composer for the window's current space and its Persona, with the selected tab to attach and `text` as the task.
    public func showAgentComposer(text: String = "") {
        guard !isPrivate else { return }
        showAgentPanel(.composer(agentComposerContext(text: text)))
    }

    func askAgentOffer(for text: String, settings: AISettingsStore) -> AskAgentOffer? {
        guard !isPrivate else { return nil }
        return AskAgentOffer(text: text, canRunSession: canStartAgentTask, context: agentComposerContext(), allowsAI: settings.allowsAI(on:))
    }

    /// Start only with the place and disclosure offered in the palette. A changed context leaves the task for review.
    func askAgent(_ offer: AskAgentOffer, settings: AISettingsStore) {
        guard let agents = session.agents else { return }
        let context = agentComposerContext(text: offer.task)
        guard offer.matches(context, allowsAI: settings.allowsAI(on:)) else {
            context.tab = nil
            context.problem = localized("The page, sharing setting, or destination changed. Review the task before starting.")
            showAgentPanel(.composer(context))
            return
        }
        guard canStartAgentTask else {
            showAgentPanel(.composer(context))
            return
        }
        do {
            let started = try agents.startSession(context.sessionStart(task: offer.task, mode: agents.newSessionMode, allowsAI: settings.allowsAI(on:)))
            showAgentSession(started.id)
        } catch {
            context.problem = error.localizedDescription
            showAgentPanel(.composer(context))
        }
    }

    /// Continue as Agent Task in the page reader and the question popover, whose questions are about the selected tab's page: the composer with the question and that tab.
    func continueAsAgentTask(_ question: String, from source: AgentHandoffSource, excerpt: AgentReaderExcerpt?, settings: AISettingsStore? = nil) {
        guard !isPrivate else { return }
        let settings = settings ?? AIService.shared.settings
        guard !isSelectedPageCovered, let tab = selectedTab, tab.id == source.tabID, tab.documentID == source.documentID,
              let url = tab.url, url == source.url, settings.allowsAI(on: url) else { return }
        if let id = source.questionID {
            guard pageQuestion?.id == id else { return }
        } else if !isPageReaderVisible {
            return
        }
        let context = agentComposerContext(text: question)
        if let excerpt, let attached = context.attachableTab(allowsAI: settings.allowsAI(on:)), excerpt.matches(attached) {
            context.readerExcerpt = excerpt
        }
        closePageQuestion()
        showAgentPanel(.composer(context))
    }

    /// Resolve the live owner again when a menu action or its confirmation returns.
    func agentSession(of folder: TabFolder) -> AgentSession? {
        guard let id = folder.agentSessionID, let owner = session.agents?.session(withID: id),
              !owner.hasEnded, owner.spaceID == currentSpaceID, owner.personaID == personaID,
              session.folders.contains(where: { $0.id == folder.id && $0.agentSessionID == id && $0.spaceID == currentSpaceID }) else { return nil }
        return owner
    }

    /// Actions available for a folder owned by an agent session.
    enum AgentFolderAction { case show, stop, keepTabs, deleteSession }

    /// Performs an agent folder action only while the reviewed session still owns it.
    func perform(_ action: AgentFolderAction, on folder: TabFolder, reviewed owner: AgentSession) async {
        guard agentSession(of: folder) === owner else { return }
        switch action {
        case .show: showAgentSession(owner.id)
        case .stop: if owner.isTurnRunning { owner.stop() }
        case .keepTabs: session.keepTabs(ofFolder: folder.id)
        case .deleteSession: await session.agents?.deleteSession(owner.id)
        }
    }

    /// The panel's menu keeps only the folder it displayed in this window's conversation.
    var panelKeepTabsAction: (() -> Void)? {
        guard case .session(let id) = agentPanel, let folder = session.folders.first(where: { $0.agentSessionID == id }),
              let owner = agentSession(of: folder) else { return nil }
        return { [weak self] in
            guard let self, self.agentPanel == .session(owner.id), self.agentSession(of: folder) === owner else { return }
            self.session.keepTabs(ofFolder: folder.id)
        }
    }

    /// Shows a session in the panel, as a row or the indicator's menu does.
    public func showAgentSession(_ id: UUID) {
        showAgentPanel(.session(id))
    }

    /// A step's tab button: a small window's tab brings its small window forward, since another window that selected it would close that window and keep the tab out of every list; any other tab is selected here, or, since a small window shows only its own tab, in the main window, which comes forward. A tab that has closed shows nothing.
    func showAgentTab(_ id: UUID) {
        guard let tab = session.allTabs.first(where: { $0.id == id }) else { return }
        guard !tab.isInSmallWindow else {
            session.window(showing: tab)?.nsWindow?.makeKeyAndOrderFront(nil)
            return
        }
        guard kind == .small else { return selectTab(id) }
        let target = session.sidebarTarget()
        target.selectTab(id)
        target.nsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A page read this turn can already be on screen in another window, including a split pane.
    func showReadTab(_ id: UUID) {
        guard let tab = session.allTabs.first(where: { $0.id == id }), tab.isLoaded else { return }
        let destination: BrowserWindowModel
        if let owner = session.window(showing: tab) {
            destination = owner
        } else {
            guard !tab.isInSmallWindow else { return }
            destination = kind == .main ? self : session.sidebarTarget()
        }
        destination.closePreview()
        destination.commandPaletteMode = nil
        if destination.selectedTabID != id || destination.internalPage != nil { destination.selectTab(id) }
        if destination !== self { destination.nsWindow?.makeKeyAndOrderFront(nil) }
    }

    /// A reply link opens in the invoking Persona, in the current space or a small window of its own.
    func openReplyLink(_ url: URL, in personaID: Persona.ID) {
        switch kind {
        case .main:
            let space = self.personaID == personaID ? currentSpaceID : session.preferredSpace(in: personaID).id
            selectTab(session.openTab(url: url, in: space, select: false).id)
        case .small: _ = session.openSmallWindow(url: url, engine: session.defaultEngine, spaceID: currentSpaceID, personaID: personaID)
        }
    }

    var resumableAgentDraft: AgentComposerContext? {
        guard let draft = agentDrafts[currentSpaceID], draft.personaID == personaID,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return draft
    }

    /// Each window has one local draft per space. A blank one gives way.
    func canReceiveAgentDraft(_ draft: AgentComposerContext) -> Bool {
        agentDrafts[draft.spaceID].map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
    }

    /// A blank composer that shows for the same space gives way to the moved draft, so the panel shows the draft this window keeps.
    func receiveAgentDraft(_ draft: AgentComposerContext, showing: Bool) {
        if case .composer(let shown) = agentPanel, shown.spaceID == draft.spaceID {
            showAgentPanel(.composer(draft))
        } else if showing && agentPanel == nil && !isPageReaderVisible {
            showAgentPanel(.composer(draft))
        } else {
            agentDrafts[draft.spaceID] = draft
        }
    }

    /// An open panel and this space’s unfinished setup draft stay reachable before a model can run.
    public var canToggleAgentPanel: Bool { !isPrivate && (agentPanel != nil || resumableAgentDraft != nil || canStartAgentTask) }

    /// Hides the panel, or resumes its draft in this space before showing the most recent session or a new composer.
    public func toggleAgentPanel() {
        guard agentPanel == nil else { return hideAgentPanel() }
        if let draft = resumableAgentDraft {
            showAgentPanel(.composer(draft))
        } else if let latest = session.agents?.sessions.last(where: { $0.spaceID == currentSpaceID }) {
            showAgentSession(latest.id)
        } else {
            showAgentComposer()
        }
    }

    /// Hides the agent column with the sidebar's spring animation.
    public func hideAgentPanel() {
        withAnimation(SidebarView.pageSpring) { agentPanel = nil }
    }

    /// Clears the submitted draft and shows its new agent session.
    func agentTaskDidStart(_ sessionID: UUID, from draft: AgentComposerContext) {
        if agentDrafts[draft.spaceID] === draft { agentDrafts[draft.spaceID] = nil }
        showAgentSession(sessionID)
    }

    /// Shows agent content in the trailing column and preserves a composer's draft.
    private func showAgentPanel(_ content: AgentPanelContent) {
        guard !isPrivate else { return }
        if case .composer(let context) = content { agentDrafts[context.spaceID] = context }
        if isPageReaderVisible { session.pageReaderDidHide(in: self) }
        withAnimation(SidebarView.pageSpring) {
            isPageReaderVisible = false
            agentPanel = content
        }
    }

    /// Whether the palette offers Ask About This Page: a provider can answer, and the selected tab shows a page that neither an internal page nor the preview panel covers.
    var canAskAboutPage: Bool {
        guard !isPrivate else { return false }
        guard !isSelectedPageCovered, !hasPromptOnSelectedTab, let url = selectedTab?.url else { return false }
        return PageAssistant.isQuestionAvailable && PageAssistant.canRead(url)
    }

    /// Opens a question popover for the selected page when page questions are available.
    func askAboutPage() {
        guard canAskAboutPage, let tab = selectedTab else { return }
        openPageQuestion(in: tab, selection: nil)
    }

    /// From the page's context menu, so the tab is this window's selected tab: a click in another pane selects that pane's tab first.
    func askAboutSelection(_ selection: AISelection, in tab: Tab) {
        guard !isPrivate, !tab.isPrivate else { return }
        guard selectedTabID == tab.id, PageAssistant.isQuestionAvailable, !session.prompts.hasPrompt(for: tab.id),
              selection.pageURL == tab.url, PageAssistant.canRead(selection.pageURL) else { return }
        openPageQuestion(in: tab, selection: selection)
    }

    /// Closes the popover the user dismissed and gives the page keyboard focus again.
    func dismissPageQuestion(_ id: UUID) {
        guard pageQuestion?.id == id else { return }
        closePageQuestion()
        focusPage()
    }

    /// Closes the popover when it is about the tab's page.
    func closePageQuestion(ofTab id: UUID) {
        if pageQuestion?.tabID == id { closePageQuestion() }
    }

    /// Replaces the question popover with a conversation for the tab's current document.
    func openPageQuestion(in tab: Tab, selection: AISelection?) {
        guard !isPrivate else { return }
        pageQuestion?.conversation.cancel()
        pageQuestion = PageQuestion(tabID: tab.id, documentID: tab.documentID, selection: selection, conversation: session.pageAssistant.makeQuestionConversation(for: tab))
    }

    /// Cancels and removes the active page question conversation.
    private func closePageQuestion() {
        guard let pageQuestion else { return }
        pageQuestion.conversation.cancel()
        self.pageQuestion = nil
    }

    // MARK: Closing

    /// Shows an outside client's agent panel when its card opens, with its steps and the cards that wait for the user, in place of the page reader, which hides. A composer or a session the column shows stays (`agentPanel(showingClient:over:)`).
    public func showAgentPanel(for ownerID: UUID) {
        guard let content = Self.agentPanel(showingClient: ownerID, over: agentPanel), content != agentPanel else { return }
        showAgentPanel(content)
    }

    /// The agents indicator's row for a connected client: its panel, in place of whatever the column shows.
    func showClientPanel(_ ownerID: UUID) {
        showAgentPanel(.client(ownerID))
    }

    /// What the column shows once an outside client's card opens: the client's panel, unless the composer or a session shows, whose draft and conversation would go with it. The client's cards then wait in the agents indicator's menu, whose row for the client shows its panel.
    static func agentPanel(showingClient ownerID: UUID, over current: AgentPanelContent?) -> AgentPanelContent? {
        switch current {
        case .composer, .session: return current
        case .client, nil: return .client(ownerID)
        }
    }

    /// The window as `session.json` keeps it. The session also keeps it once the window closes.
    var record: SessionSnapshot.WindowRecord {
        SessionSnapshot.WindowRecord(id: id, frame: restorableFrame, currentSpaceID: currentSpaceID, selectedTabID: selectedTabID, isSidebarVisible: isSidebarVisible)
    }

    /// Lets go of what the window shows as it closes, so that other windows can show its tabs, which stay open (window rule 5): the page reader's replies about them, the palette, find, region capture, page fullscreen, the preview panel, the question popover, and the docked developer tools. The tabs' prompts stay with them and show in the next window that shows them.
    func prepareToClose() {
        if isPageReaderVisible { session.pageReaderDidHide(in: self) }
        commandPaletteMode = nil
        hideFindBar()
        cancelRegionCapture()
        exitPageFullscreen()
        closePreview()
        closePageQuestion()
        shownTabIDs = []
        devToolsDock.track(nil)
    }

    /// Closes the window from code, as a small window does once its tab leaves or closes. AppKit would take an attached sheet away unanswered, so a sheet on the window, such as the print panel, Export as PDF's save panel, or a page's file chooser panel, ends first with Cancel. The tab's other prompts wait for its next window.
    func close() {
        if let nsWindow, let sheet = nsWindow.attachedSheet {
            nsWindow.endSheet(sheet, returnCode: .cancel)
        }
        nsWindow?.close()
    }

    // MARK: Find in page

    /// Opens the bar and searches the current text. While the bar is open, this only returns focus to its field without moving the match. The bar does not open under the preview panel, whose page it would not search, or while the page waits for the answer to its tab's prompt.
    public func showFindBar() {
        guard selectedTab != nil, preview == nil, !hasPromptOnSelectedTab else { return }
        findBarFocusRequests += 1
        guard !isFindBarVisible else { return }
        isFindBarVisible = true
        runFind(forward: true)
    }

    /// Stops the current search and returns keyboard focus to the selected page.
    public func hideFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        findResult = nil
        selectedTab?.webContents.stopFind()
        focusPage()
    }

    /// Moves to the next match and shows the find bar if hidden so the user can see the search.
    public func findNext() {
        if !isFindBarVisible { showFindBar() } else { runFind(forward: true) }
    }

    /// Moves to the previous match, opening the find bar first if needed.
    public func findPrevious() {
        if !isFindBarVisible { showFindBar() } else { runFind(forward: false) }
    }

    /// Searches the selected page and accepts only the latest search result.
    private func runFind(forward: Bool) {
        guard isFindBarVisible, let tab = selectedTab else { return }
        findGeneration += 1
        let generation = findGeneration
        let text = findText
        guard !text.isEmpty else {
            tab.webContents.stopFind()
            findResult = nil
            return
        }
        tab.webContents.find(text, forward: forward, matchCase: false) { [weak self] result in
            guard let self, self.isFindBarVisible, self.findGeneration == generation else { return }
            self.findResult = result
        }
    }

    // MARK: Sidebar and library

    var libraryHistoryModel: LibraryHistoryModel {
        if let model = retainedLibraryHistory, model.persona == personaID { return model }
        let model = LibraryHistoryModel(store: session.history, persona: personaID)
        retainedLibraryHistory = model
        return model
    }

    public func toggleSidebar() { isSidebarVisible.toggle() }

    /// A small window shows the library in its main window. A main window with its sidebar hidden reveals both together.
    public func toggleLibrary() {
        guard !isPrivate else { return }
        if kind == .small {
            let main = session.sidebarTarget()
            main.isSidebarVisible = true
            main.isLibraryVisible = true
            main.nsWindow?.makeKeyAndOrderFront(nil)
            return
        }
        guard isSidebarVisible else {
            isSidebarVisible = true
            isLibraryVisible = true
            return
        }
        isLibraryVisible.toggle()
    }

    /// History menu commands use the same list as the library's History tab.
    public func showHistoryInLibrary() {
        guard !isPrivate, kind == .main else { return }
        guard nsWindow?.attachedSheet == nil else { return }
        commandPaletteMode = nil
        exitPageFullscreen()
        libraryTab = .history
        isSidebarVisible = true
        isLibraryVisible = true
    }

    /// Find searches history while that list is shown, otherwise the caller may search the page.
    public func focusLibraryHistorySearch() -> Bool {
        guard isShowingLibraryHistory else { return false }
        guard nsWindow?.attachedSheet == nil else { return true }
        libraryHistorySearchRequest &+= 1
        return true
    }

    public var isShowingLibraryHistory: Bool {
        !isPrivate && kind == .main && !isPageFullscreen && isSidebarVisible && isLibraryVisible && libraryTab == .history
    }

    // MARK: Navigation

    // Going to another page leaves an internal page, and reloading does not reach the page under it. While the preview panel shows, Back, Forward, and Reload act on its page instead of the tab under it. Each tells the tab that the user asked for the load (`Tab.userDidNavigate()`), Back and Forward only when there is a page to go to. The user's navigation drops the cause of one that code started (`Tab.pendingCause`).
    /// Goes back in the preview or selected tab and leaves any internal page.
    public func goBack() {
        if let preview { return preview.webContents.navigationController.goBack() }
        internalPage = nil
        guard let tab = selectedTab else { return }
        if tab.webContents.canGoBack { tab.userDidNavigate() }
        tab.pendingCause = nil
        tab.webContents.navigationController.goBack()
    }
    /// Goes forward in the preview or selected tab and leaves any internal page.
    public func goForward() {
        if let preview { return preview.webContents.navigationController.goForward() }
        internalPage = nil
        guard let tab = selectedTab else { return }
        if tab.webContents.canGoForward { tab.userDidNavigate() }
        tab.pendingCause = nil
        tab.webContents.navigationController.goForward()
    }
    /// The selected tab's earlier pages, most recent first, for the History menu.
    public func recentBackItems(limit: Int) -> [any EngineBackForwardListItem] {
        guard let list = selectedTab?.webContents.navigationController.backForwardList else { return [] }
        return Array(list.backList.reversed().prefix(limit))
    }
    /// Pages keep running while the menu is open. Use an item only in its original tab, while that tab is selected. The item is one of the tab's pages, so the preview panel closes to show it.
    public func go(to item: any EngineBackForwardListItem, inTab tabID: UUID) {
        guard let tab = selectedTab, tab.id == tabID else { return }
        closePreview()
        internalPage = nil
        tab.userDidNavigate()
        tab.pendingCause = nil
        tab.webContents.navigationController.go(to: item)
    }
    /// Reloads the preview or uncovered selected tab.
    public func reload() {
        if let preview { return preview.webContents.navigationController.reload() }
        guard internalPage == nil, let tab = selectedTab else { return }
        tab.userDidNavigate()
        tab.pendingCause = nil
        tab.webContents.navigationController.reload()
    }
    /// Stops loading the preview or selected tab.
    public func stopLoading() {
        if let preview { return preview.webContents.navigationController.stop() }
        selectedTab?.webContents.navigationController.stop()
    }
    /// Whether the commands above have a page to act on, the preview's while the panel shows, for the menu bar and, for Reload, the sidebar's and the small window's buttons.
    public var canGoBack: Bool { preview?.webContents.canGoBack ?? (selectedTab?.canGoBack == true) }
    public var canGoForward: Bool { preview?.webContents.canGoForward ?? (selectedTab?.canGoForward == true) }
    public var canReload: Bool { preview != nil || (internalPage == nil && selectedTab != nil) }
    public var isLoadingPage: Bool { preview?.isLoading ?? (selectedTab?.isLoading == true) }

    // MARK: Developer tools

    /// Whether the selected tab's engine offers developer tools.
    public var canShowDeveloperTools: Bool { selectedTab?.webContents.devTools != nil }
    public var isShowingDeveloperTools: Bool { selectedTab?.webContents.devTools?.isOpen == true }
    /// Whether the docking side applies to the selected tab's tools. Tools that dock inside the page have their own controls.
    public var canChooseDevToolsSide: Bool { selectedTab?.webContents.devTools?.isPlacedByApp == true }
    /// Opens or closes the selected tab's developer tools when its engine provides them.
    public func toggleDeveloperTools() {
        guard let devTools = selectedTab?.webContents.devTools else { return }
        devToolsDock.track(selectedTab)
        devTools.isOpen ? devTools.close() : devTools.open()
    }

    // MARK: Zoom

    /// The factors that zooming in and out steps through, alike on both engines.
    private static let zoomFactors: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// Zooming needs a selected tab that no internal page or preview covers.
    public var canZoom: Bool { selectedTab != nil && !isSelectedPageCovered }

    public func zoomIn() { changeZoom { current in Self.zoomFactors.first { $0 > current + 0.01 } } }
    public func zoomOut() { changeZoom { current in Self.zoomFactors.last { $0 < current - 0.01 } } }
    public func resetZoom() { changeZoom { _ in 1 } }

    /// Sets the selected tab's zoom from its current factor. The session remembers it for the page's host.
    private func changeZoom(_ next: (Double) -> Double?) {
        guard canZoom, let tab = selectedTab, let factor = next(tab.webContents.zoomFactor) else { return }
        session.setZoom(factor, of: tab)
    }

    // MARK: Printing

    /// Whether Print and Export as PDF can act: a page is selected with no internal page or preview over it and no prompt waiting, no PDF is rendering, and the window shows no sheet.
    public var canPrint: Bool {
        guard selectedTab != nil, !isSelectedPageCovered, !hasPromptOnSelectedTab, !isRenderingPDF else { return false }
        return nsWindow?.attachedSheet == nil
    }

    public var canSavePageAs: Bool {
        guard !isSelectedPageCovered, selectedTab?.isLoaded == true, let url = selectedTab?.committedURL, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// View ▸ Picture in Picture and a tab row's menu: a loaded tab whose committed page is a web page or a file, and that no internal page covers when it is the selected tab.
    public func canTogglePictureInPicture(_ tab: Tab) -> Bool {
        guard tab.isLoaded, ["http", "https", "file"].contains(tab.committedURL?.scheme?.lowercased() ?? "") else { return false }
        return tab !== selectedTab || !isSelectedPageCovered
    }

    /// Selects the tab first, so that only a page the user sees gets the user activation the request needs, then asks its video to enter picture in picture, or to leave it when one already shows. A beep reports a page without a video or one that refused.
    public func togglePictureInPicture(_ tab: Tab) {
        guard canTogglePictureInPicture(tab) else { return NSSound.beep() }
        if tab !== selectedTab || !shows(tab) { selectTab(tab.id) }
        guard selectedTab === tab, shows(tab), !isSelectedPageCovered else { return NSSound.beep() }
        tab.webContents.togglePictureInPicture { done in if !done { NSSound.beep() } }
    }

    /// Starts saving the selected web page through the session when available.
    public func savePageAs() {
        guard canSavePageAs, let tab = selectedTab, let url = tab.committedURL else { return }
        session.savePageAs(tab, url: url)
    }

    /// Prints the selected page through the system print panel, a sheet on the window. Both engines render the page as PDF first, so the panel and its preview work the same on either.
    public func printPage() {
        renderSelectedPageAsPDF(failureMessage: localized("The page could not be printed.")) { tab, document, window in
            guard let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
            operation.jobTitle = tab.shownTitle
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    /// Saves the selected page as a PDF file where the user chooses in a save panel on the window.
    public func exportPageAsPDF() {
        renderSelectedPageAsPDF(failureMessage: localized("The page could not be exported as PDF.")) { [weak self] tab, document, window in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            // A slash would name a folder, and a colon shows as a slash in the Finder.
            panel.nameFieldStringValue = tab.shownTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".pdf"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                if !document.write(to: url) {
                    self?.showNotice(localized("The PDF could not be saved."), detail: url.path, detailIsPath: true, for: tab)
                }
            }
        }
    }

    /// Renders the selected page as PDF and passes it on with the window while that tab is still selected; a tab the user left in the meantime drops the request. A failure shows a notice card on the tab.
    private func renderSelectedPageAsPDF(failureMessage: String, then use: @escaping (Tab, PDFDocument, NSWindow) -> Void) {
        guard canPrint, let tab = selectedTab else { return }
        isRenderingPDF = true
        tab.webContents.createPDF { [weak self] result in
            guard let self else { return }
            self.isRenderingPDF = false
            guard self.selectedTab === tab, let window = self.nsWindow else { return }
            if case .success(let data) = result, let document = PDFDocument(data: data) {
                use(tab, document, window)
            } else {
                self.showNotice(failureMessage, for: tab)
            }
        }
    }

    // MARK: Capture

    /// Whether the capture commands can act: a page is selected and no internal page or preview covers it.
    public var canCapture: Bool { selectedTab != nil && !isSelectedPageCovered }

    /// Saves the visible part of the selected page as a PNG file in the captures folder and shows it in the Finder.
    public func captureViewport() {
        guard canCapture, let tab = selectedTab else { return }
        tab.webContents.captureViewport { [weak self] in self?.saveCapture($0, of: tab) }
    }

    /// Saves the whole selected page, including the parts scrolled out of view, as a PNG file in the captures folder and shows it in the Finder.
    public func captureFullPage() {
        guard canCapture, let tab = selectedTab else { return }
        tab.webContents.captureFullPage { [weak self] in self?.saveCapture($0, of: tab) }
    }

    /// Covers the selected page with an overlay where the user drags out the region to capture.
    public func beginRegionCapture() {
        guard canCapture, let tab = selectedTab else { return }
        regionCaptureTabID = tab.id
    }

    /// Captures the visible part of the page and keeps the region the user dragged out, given in the page view's coordinates.
    func finishRegionCapture(_ rect: CGRect) {
        guard let tab = selectedTab, tab.id == regionCaptureTabID else { return cancelRegionCapture() }
        regionCaptureTabID = nil
        focusPage()
        let view = tab.webContents.view
        let bounds = view.bounds
        let isFlipped = view.isFlipped
        tab.webContents.captureViewport { [weak self] image in
            self?.saveCapture(image.flatMap { PageCapture.crop($0, to: rect, of: bounds, isFlipped: isFlipped) }, of: tab)
        }
    }

    /// Removes the region capture overlay without capturing.
    func cancelRegionCapture() {
        guard regionCaptureTabID != nil else { return }
        regionCaptureTabID = nil
        focusPage()
    }

    /// Writes a capture to the captures folder and shows the file in the Finder. Encoding a long page takes a moment, so it runs off the main thread. A capture that failed or could not be written shows a notice card on its tab, if the tab is still open.
    private func saveCapture(_ image: NSImage?, of tab: Tab) {
        guard let image else { return showCaptureFailure(localized("The page could not be captured."), for: tab) }
        let title = tab.shownTitle
        let date = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PageCapture.save(image, title: title, date: date) }
            DispatchQueue.main.async {
                switch result {
                case .success(let file): NSWorkspace.shared.activateFileViewerSelecting([file])
                case .failure(let error): self?.showCaptureFailure(localized("The capture could not be saved."), detail: error.localizedDescription, for: tab)
                }
            }
        }
    }

    /// Shows a capture failure on its tab only while that tab still exists.
    private func showCaptureFailure(_ message: String, detail: String? = nil, for tab: Tab) {
        guard session.allTabs.contains(where: { $0 === tab }) else { return }
        showNotice(message, detail: detail, for: tab)
    }

    /// Arch's notice about the tab's page, as a card over the tab's pane.
    private func showNotice(_ title: String, detail: String? = nil, detailIsPath: Bool = false, for tab: Tab) {
        let content = TabPromptContent.notice(title: title, detail: detail, detailIsPath: detailIsPath, identity: PromptSiteIdentity.make(for: tab.url, in: tab))
        session.enqueuePrompt(content, for: tab) { _ in }
    }

    // MARK: Sharing and site controls

    /// Whether the selected tab shows a page to share. An internal page has nothing to share, and the preview panel hides the tab's page.
    public var canShareSelectedPage: Bool { !isSelectedPageCovered && selectedTab?.url != nil }

    /// Shows the system share picker for the selected tab's address and title, below the share button, or from the top of the window while the sidebar or the library hides the button.
    public func shareSelectedPage() {
        guard !isSelectedPageCovered, let tab = selectedTab, let url = tab.url, let anchor = siteControlAnchor(shareButtonView) else { return }
        let picker = PageSharePicker(url: url, title: tab.shownPageTitle, icon: tab.favicon)
        sharePicker = picker
        picker.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
    }

    /// Where a picker or popover for one of the address pill's buttons points: below `button`, or below the top of the window's content while the sidebar or the library hides it. Nil before the window has content.
    func siteControlAnchor(_ button: NSView?) -> (view: NSView, rect: NSRect, edge: NSRectEdge)? {
        if let button, button.window != nil, !isLibraryVisible {
            return (button, button.bounds, button.isFlipped ? .maxY : .minY)
        }
        guard let content = nsWindow?.contentView else { return nil }
        let bounds = content.bounds
        return (content, NSRect(x: bounds.midX, y: content.isFlipped ? bounds.minY : bounds.maxY - 1, width: 1, height: 1), content.isFlipped ? .maxY : .minY)
    }

    // MARK: Tab switcher

    public var isTabSwitcherVisible: Bool { tabSwitcherHighlightID != nil }

    /// The current space's listed tabs and the open tabs of the favorites that every space of the window's Persona shows, most recently selected first. Tabs not selected since launch follow by their last activation: restored tabs keep the one from the saved session, and tabs opened in the background count from their opening.
    public var recentTabs: [Tab] {
        if isPrivate { return privateTabs.sorted { $0.lastActivatedAt > $1.lastActivatedAt } }
        let candidates = session.tabs.filter { $0.spaceID == currentSpaceID && $0.isListedInSidebar } + session.openFavoriteTabs.filter { $0.personaID == personaID }
        let selected = activationOrder.compactMap { id in candidates.first { $0.id == id } }
        let selectedIDs = Set(activationOrder)
        return selected + candidates.filter { !selectedIDs.contains($0.id) }.sorted { $0.lastActivatedAt > $1.lastActivatedAt }
    }

    /// Moves the selected tab to the front of this window's recent selection order.
    private func recordActivation() {
        guard let id = selectedTabID else { return }
        activationOrder.removeAll { $0 == id }
        activationOrder.insert(id, at: 0)
    }

    /// Drops a closing tab from the switcher's order.
    func forgetActivation(of tabID: UUID) {
        activationOrder.removeAll { $0 == tabID }
    }

    /// Opens the switcher on the tab selected before the current one, or on the least recent tab when going backward. The current space needs a second tab.
    public func showTabSwitcher(backward: Bool) {
        let recent = recentTabs
        guard recent.count > 1 else { return }
        let others = recent.filter { $0.id != selectedTabID }
        tabSwitcherHighlightID = (backward ? others.last : others.first)?.id
    }

    /// Moves the highlight to the next less recent tab, or toward the current one when going backward, wrapping at either end.
    public func moveTabSwitcherHighlight(backward: Bool) {
        guard let id = tabSwitcherHighlightID else { return }
        let recent = recentTabs
        guard !recent.isEmpty else { return cancelTabSwitcher() }
        // A highlighted tab that closed meanwhile counts as the first.
        let index = recent.firstIndex { $0.id == id } ?? 0
        tabSwitcherHighlightID = recent[(index + (backward ? recent.count - 1 : 1)) % recent.count].id
    }

    /// Selects the highlighted tab and gives its page keyboard focus. An open command palette closes, as when the palette's own tab row is chosen.
    public func commitTabSwitcher() {
        guard let id = tabSwitcherHighlightID else { return }
        tabSwitcherHighlightID = nil
        guard session.allTabs.contains(where: { $0.id == id }) else { return }
        selectTab(id)
        if commandPaletteMode != nil { dismissCommandPalette() } else { focusPage() }
    }

    /// Closes the switcher and keeps the selected tab.
    public func cancelTabSwitcher() {
        if tabSwitcherHighlightID != nil { tabSwitcherHighlightID = nil }
    }

    // MARK: Site data

    /// Whether Clear Site Data can act: the selected tab shows a web page that no internal page or preview covers and whose tab has no prompt waiting, and the window shows no sheet.
    public var canClearSiteData: Bool {
        guard !isPrivate else { return false }
        guard !isSelectedPageCovered, !hasPromptOnSelectedTab, SiteDataScope(url: selectedTab?.url) != nil else { return false }
        return nsWindow?.attachedSheet == nil
    }

    /// Asks with a card over the selected tab before clearing the data of its page's host. With several Personas, the card's message names the Persona whose data goes from the tab's place, as "the Persona of “Work / Research”" (Persona rule 7): with the tab's space or, for a favorite's tab, the window's current one while it belongs to the tab's Persona (`sheetSpace(ofTabIn:personaID:spaces:currentSpace:)`). Only Clear clears.
    public func confirmClearSiteData() {
        guard canClearSiteData, let tab = selectedTab, let site = SiteDataScope(url: tab.url) else { return }
        let space = Self.sheetSpace(ofTabIn: tab.spaceID, personaID: tab.personaID, spaces: session.spaces, currentSpace: currentSpace)
        let persona = Self.sheetName(ofPersona: tab.personaID, space: space, among: session.personas)
        let content = TabPromptContent.clearSiteData(persona: persona, identity: PromptSiteIdentity.make(for: tab.url, in: tab))
        let personaID = tab.personaID
        session.enqueuePrompt(content, for: tab) { [weak self] response in
            if response.buttonID == "clear" { self?.session.clearSiteData(of: site, in: personaID) }
        }
    }

    /// The space a sheet or card about a tab's Persona names with it (Persona rule 7): the tab's space, or for a favorite's tab, which belongs to no space and shows in the window's current space, that space while it belongs to the tab's Persona, as the window title names it.
    nonisolated static func sheetSpace(ofTabIn spaceID: UUID?, personaID: Persona.ID, spaces: [Space], currentSpace: Space) -> Space? {
        if let space = spaces.first(where: { $0.id == spaceID }) { return space }
        return currentSpace.resolvedPersonaID == personaID ? currentSpace : nil
    }

    // MARK: Folders

    /// Adds an empty folder after the space's folders among its pinned tabs, shows the space, and starts renaming the folder.
    public func addFolder(toSpace spaceID: UUID) {
        guard session.spaces.contains(where: { $0.id == spaceID }) else { return }
        switchToSpace(spaceID)
        renamingFolderID = session.makeFolder(in: spaceID, pinned: true).id
    }

    /// New Folder Inside: adds an empty folder last among a folder's folders, below the fourth level only, expands the folders that hold it, and starts renaming it.
    public func addFolder(inside parentID: UUID) {
        guard session.folderTree.canAddFolder(inside: parentID), let parent = session.folders.first(where: { $0.id == parentID }) else { return }
        let folder = session.makeFolder(in: parent.spaceID, pinned: parent.isPinned, inside: parentID)
        session.expandFolders(holding: folder.id)
        renamingFolderID = folder.id
    }

    /// Add to New Folder: puts a tab in a new folder where the tab is, inside its folder or at the top of its space's pinned or open list, expands the folders that hold the new one, and starts renaming it. A tab in a folder at the fourth level has no room for one. A favorite's tab belongs to no space and stays out of folders.
    public func addToNewFolder(_ tab: Tab) {
        guard let spaceID = tab.spaceID, session.folderTree.canAddFolder(inside: tab.folderID) else { return }
        let folder = session.makeFolder(in: spaceID, pinned: tab.isPinned, inside: tab.folderID)
        session.moveTab(tab.id, toFolder: folder.id)
        session.expandFolders(holding: folder.id)
        renamingFolderID = folder.id
    }

    /// Keeps the old name when the new one is empty.
    public func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { session.updateFolder(id) { $0.name = trimmed } }
        endRenamingFolder(id)
    }

    /// Does not interrupt renaming another folder that may have started meanwhile.
    public func endRenamingFolder(_ id: UUID) {
        if renamingFolderID == id { renamingFolderID = nil }
    }

    // MARK: Panes and split view

    // The page area shows one pane or a split view of up to four. The session keeps each space's split view (`BrowserSession.splitTabIDs`), and these names tell the window's lists of panes apart:
    // - `splitOnScreen`: the selected tab's split view, or nil when the selected tab is in none. `isInSplitViewOnScreen(_:)` asks whether a tab is in it.
    // - `paneTabs`: the page area's panes, left to right: the tabs of `splitOnScreen`, or the selected tab alone.
    // - `shownTabIDs`: the panes whose pages this window shows. A pane that another window shows stays out, and the page area shows a placeholder in its place (window rule 1).
    // - `tabsOnScreen`: the shown panes, the selected tab first, or the selected tab alone while its page fills the window. Their prompts show over their panes.

    /// The split view the page area shows: the selected tab's, if it is in one.
    private var splitOnScreen: [UUID]? {
        guard let selected = selectedTab, let spaceID = selected.spaceID, let ids = session.splitTabIDs[spaceID], ids.contains(selected.id) else { return nil }
        return ids
    }

    /// The page area's panes, left to right: the selected tab's split view, or the selected tab alone. The window shows the pages of `shownTabIDs` among them.
    var paneTabs: [Tab] {
        guard let selected = selectedTab else { return [] }
        guard let ids = splitOnScreen else { return [selected] }
        return ids.compactMap { id in session.tabs.first { $0.id == id } }
    }

    /// Whether `tab` is a pane of the split view the page area shows.
    func isInSplitViewOnScreen(_ tab: Tab) -> Bool {
        splitOnScreen?.contains(tab.id) == true
    }

    /// Whether the window shows `tab`, as its selected tab or a pane of its split view.
    func shows(_ tab: Tab) -> Bool {
        shownTabIDs.contains(tab.id)
    }

    /// Whether another window shows `tab`. Selection this window makes on its own passes such a tab by (window rule 3).
    func isShownInAnotherWindow(_ tab: Tab) -> Bool {
        session.windows.contains { $0 !== self && $0.shows(tab) }
    }

    /// Follows a change of the selection or of the split views: the window keeps its selected tab and the panes it shows already, and takes each other pane that no other window shows. A tab without its page gets it before the window shows it (`BrowserSession.loadPage(of:)`). A tab that leaves the window was in view until now, as archiving and automatic unloading count it.
    func updateShownTabs() {
        let shown = Self.panesToShow(paneTabs, shownTabIDs: shownTabIDs, isShownInAnotherWindow: isShownInAnotherWindow)
        shown.forEach(session.loadPage(of:))
        let ids = shown.map(\.id)
        guard ids != shownTabIDs else { return }
        let now = Date()
        for tab in session.allTabs where shownTabIDs.contains(tab.id) && !ids.contains(tab.id) { tab.lastActivatedAt = now }
        let showedSelected = selectedTabID.map(shownTabIDs.contains) == true
        shownTabIDs = ids
        // A selected tab that comes back, as when the window that took it closes, brings its docked tools back.
        if let selected = selectedTab, !showedSelected, ids.contains(selected.id) { devToolsDock.track(selected) }
        session.applyPendingSyncEngines()
    }

    /// The panes of `panes` that a window shows, and so loads, after a change: the panes it shows already (`shownTabIDs`) and each other pane that no other window shows, its selected tab among them. A selected tab that another window took stays out until the user takes it back or the other window lets it go (open decision 5).
    static func panesToShow(_ panes: [Tab], shownTabIDs: [UUID], isShownInAnotherWindow: (Tab) -> Bool) -> [Tab] {
        panes.filter { shownTabIDs.contains($0.id) || !isShownInAnotherWindow($0) }
    }

    /// Lets another window take `tab` (window rule 2). A small window, which shows only its tab, closes, letting go of the page's fullscreen and docked tools as it does. A main window keeps its selection, as for another pane of its split view (open decision 5): it ends the page's fullscreen here first, and for its selected tab lets go of the docked tools and closes the find bar and the question popover, which belong to the page. Its page area then shows a placeholder in the pane, and its sidebar dims the tab's row, until the user takes the tab back. The tab's prompt goes with it.
    func giveUp(_ tab: Tab) {
        shownTabIDs.removeAll { $0 == tab.id }
        if tab.id == selectedTabID, kind == .small { return close() }
        if fullscreenTabID == tab.id { exitPageFullscreen() }
        guard tab.id == selectedTabID else { return }
        devToolsDock.track(nil)
        if isFindBarVisible {
            tab.webContents.stopFind()
            isFindBarVisible = false
            findResult = nil
        }
        closePageQuestion(ofTab: tab.id)
    }

    /// Brings forward the window that shows `tab` in place of this one, as the placeholder's Show Other Window does.
    func showWindowShowing(_ tab: Tab) {
        guard let other = session.window(showing: tab), other !== self else { return }
        other.nsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The tabs whose pages the window shows now, the selected tab first: the panes of its split view that it shows, or the selected tab alone while its page fills the window. Their prompts show as cards over their panes. None once the window has let go of its tabs as it closes.
    var tabsOnScreen: [Tab] {
        guard let selected = selectedTab, shows(selected) else { return [] }
        if fullscreenTabID == selected.id { return [selected] }
        return [selected] + paneTabs.filter { $0.id != selected.id && shows($0) }
    }

    /// The tab of `tabsOnScreen` whose page the click at the event's place in the window reaches, as one in a pane of the split view that the click is about to select. A click on a prompt card, its dimming, or another view over the page reaches none (`NSView.takesClick(at:)`).
    public func tabOnScreen(at event: NSEvent) -> Tab? {
        tabsOnScreen.first { tab in
            let view = tab.webContents.view
            return view.window === event.window && view.takesClick(at: event.locationInWindow)
        }
    }

    /// The tab of `tabsOnScreen` whose page has the window's keys when `event` is a key press that activates the page's focused link or button, as a click does (`NSView.takesActivation(by:)`).
    public func tabOnScreen(activatedBy event: NSEvent) -> Tab? {
        tabsOnScreen.first { tab in
            let view = tab.webContents.view
            return view.window === event.window && view.takesActivation(by: event)
        }
    }

    /// Whether `tab` can open as a pane: it belongs to the selected tab's space, the page area does not show it yet, and the panes it joins have room.
    public func canOpenInSplitView(_ tab: Tab) -> Bool {
        let panes = panesJoined(by: tab)
        return !panes.isEmpty && !panes.contains(tab.id) && panes.count < BrowserSession.maximumPanes
    }

    /// Opens `tab` as a pane at `index` among the panes it joins, or after the last, and selects it. The result becomes the space's split view, in place of an earlier one. A tab that is already a pane on screen moves to `index`.
    public func openInSplitView(_ tab: Tab, at index: Int? = nil) {
        guard let spaceID = tab.spaceID else { return }
        var ids = panesJoined(by: tab)
        var position = min(index ?? ids.count, ids.count)
        if let current = ids.firstIndex(of: tab.id) {
            ids.remove(at: current)
            if current < position { position -= 1 }
        }
        ids.insert(tab.id, at: position)
        guard (2...BrowserSession.maximumPanes).contains(ids.count) else { return }
        session.setSplitView(ids, ofSpace: spaceID)
        // Selecting the tab again would close an internal page over it.
        if selectedTabID != tab.id { selectTab(tab.id) }
    }

    /// Whether the menu bar's Open in Split View can act: the selected tab can open as a pane, and no internal page covers it.
    public var canOpenSelectedTabInSplitView: Bool {
        internalPage == nil && selectedTab.map(canOpenInSplitView) == true
    }

    /// Adds the selected tab to a split view when it can join another pane.
    public func openSelectedTabInSplitView() {
        guard canOpenSelectedTabInSplitView, let tab = selectedTab else { return }
        openInSplitView(tab)
    }

    /// Takes `tab` out of its split view and leaves the tab open. When it was the focused pane, the pane that takes its place is selected, or else another of the split view's panes, so the rest of the split view stays on screen. A pane that another window shows stays there (window rule 3); with no other pane free, `tab` stays selected on its own.
    func closePane(_ tab: Tab) {
        let panes = tab.spaceID.flatMap { session.splitTabIDs[$0] } ?? []
        let neighborID = session.leaveSplitView(tab)
        guard selectedTabID == tab.id else { return }
        let candidates = ([neighborID].compactMap { $0 } + panes).filter { $0 != tab.id }.compactMap { id in session.tabs.first { $0.id == id } }
        if let next = candidates.first(where: { !isShownInAnotherWindow($0) }) { selectTab(next.id) }
    }

    /// The panes `tab` joins, left to right: those on screen, which are a split view or the selected tab alone. The selected tab shown alone joins its space's split view instead or, without one, the tab selected before it. Empty when `tab` is in another space or has no tab to join.
    private func panesJoined(by tab: Tab) -> [UUID] {
        guard let selected = selectedTab, let spaceID = tab.spaceID, selected.spaceID == spaceID else { return [] }
        let onScreen = paneTabs.map(\.id)
        guard onScreen == [tab.id] else { return onScreen }
        if let split = session.splitTabIDs[spaceID] { return split }
        return recentTabs.first { $0.id != tab.id && $0.spaceID == tab.spaceID }.map { [$0.id] } ?? []
    }
}
