// The command palette floats over the window and uses its mode to edit the current tab's address or open a new tab. As the user types, it lists Install from the Web Store for an extension that the text names, Ask Agent for text of two or more words and agent sessions to show, matching plugin commands, Ask About This Page when the words begin its name, Install Extension from This Page on a Web Store page, open tabs to switch to, and pages from history. Text that starts with a site search keyword and a space searches that site.
import Agent
import AI
import AppKit
import Extensions
import History
import Plugins
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject private var aiSettings = AIService.shared.settings
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let mode: CommandPaletteMode
    /// Set for the copy the window builds once at launch so the first palette the user opens is cheap to build. The copy stays hidden and takes no focus.
    var isWarmUp = false
    /// Set while the palette closes, before the window removes it.
    var isLeaving = false
    /// Where the palette starts its arrival and ends its departure, relative to its resting position.
    var arrivalOffset = CGSize(width: 0, height: 16)
    /// Runs inside the arrival animation so the window can move other views with the palette.
    var onArrival: () -> Void = {}
    @State private var text = ""
    @FocusState private var isFocused: Bool
    /// Set as the palette appears to animate its arrival as a state change.
    @State private var hasArrived = false
    /// The pages from history for `text`, which `loadHistorySuggestions()` reads as the text changes. The palette redraws for many other changes, such as a loading page's title, and none of them queries the history store again.
    @State private var historySuggestions: [HistoryEntry] = []
    /// The row that Up and Down selected. Its identity selects a matching row on redraw. Nil, or a row that has left the list, selects the first row; typing selects it again.
    @State private var selectedRow: PaletteItem?

    /// Matching commands of the enabled plugins of the window's Persona.
    private var pluginCommands: [Attributed<PluginCommand>] {
        Array(windowModel.plugins.contributions.paletteCommands(matching: text).prefix(5))
    }

    /// The listed tabs of the window's Persona to switch to. A small window shows only its own tab, so its palette offers none.
    private var matchingTabs: [Tab] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, windowModel.kind == .main else { return [] }
        return Array(session.allTabs.filter { tab in
            tab.id != windowModel.selectedTabID && tab.isListedInSidebar && tab.personaID == windowModel.personaID &&
                (tab.shownTitle.lowercased().contains(query) || tab.url?.absoluteString.lowercased().contains(query) == true)
        }.prefix(5))
    }

    /// Pages that share a title and site, such as the steps of a sign-in flow, appear once. The site is the one the row shows, so a page with `www.` and one without it count as one. Typing more cancels the read, and the result of a cancelled read is dropped, so the list always belongs to the latest text.
    private func loadHistorySuggestions() async {
        let entries = await session.history.suggestions(for: text, limit: 15)
        guard !Task.isCancelled else { return }
        var seen = Set<String>()
        historySuggestions = Array(entries.filter { seen.insert("\($0.title)\u{1F}\(AddressPillView.siteName(of: $0.url))").inserted }.prefix(5))
    }

    private var actionLabel: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return mode == .newTab ? "Open a new tab" : "Enter an address or search" }
        if let page = InternalPage(address: trimmed) { return "Open \(page.address)" }
        // The session reads the untrimmed text the same way, so a keyword and a space are enough, and searches the web for a keyword whose template makes no web address.
        if let search = session.siteSearch.match(text), search.shortcut.resultsURL(for: search.query) != nil {
            return search.query.isEmpty ? "Search \(search.shortcut.name)" : "Search \(search.shortcut.name) for \u{201C}\(search.query)\u{201D}"
        }
        // The site as the address pill names it, an extension's page by the extension's name in the window's Persona, so the current address that ⌘L starts with reads as the pill does.
        if let url = BrowserSession.url(forInput: trimmed) { return "Go to \(extensionName(ofPageAt: url) ?? AddressPillView.siteName(of: url))" }
        return "Search for \u{201C}\(trimmed)\u{201D}"
    }

    /// The primary row's symbol while another row has the selection, so that the Return symbol marks only the row Return runs: the address pill's symbol for an internal page or an address, else the search's.
    private var actionSymbol: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let page = InternalPage(address: trimmed) { return AddressPillView.symbol(for: nil, internalPage: page) }
        if let search = session.siteSearch.match(text), search.shortcut.resultsURL(for: search.query) != nil { return "magnifyingglass" }
        if let url = BrowserSession.url(forInput: trimmed) { return AddressPillView.symbol(for: url, internalPage: nil, isExtensionPage: extensionName(ofPageAt: url) != nil) }
        return "magnifyingglass"
    }

    /// The name of the web extension in the window's Persona whose page is at `url`, which the primary row names as the address pill does (`AddressPillView.extensionName(ofPageAt:in:session:)`).
    private func extensionName(ofPageAt url: URL) -> String? {
        session.extensionName(ofPageAt: url, in: windowModel.personaID)
    }

    /// Ask About This Page appears once the typed words begin its name, while the selected tab's page can be asked about.
    private var offersAskAboutPage: Bool {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !words.isEmpty && "ask about this page".hasPrefix(words) && windowModel.canAskAboutPage
    }

    /// The Web Store rows for the text and the selected tab's page, which no internal page or preview panel covers, while the app shell can start a store install.
    private var webStoreRows: PaletteWebStoreRows {
        guard session.installFromWebStore != nil else { return PaletteWebStoreRows() }
        let isPageCovered = windowModel.internalPage != nil || windowModel.preview != nil
        return PaletteWebStoreRows(text: text, pageURL: isPageCovered ? nil : windowModel.selectedTab?.url)
    }

    /// Closes the palette and opens the store sheet in Settings ▸ Plugins for the extension, in the selected tab's Persona and space for its page, else in the window's.
    private func installFromWebStore(_ id: String, fromPage: Bool) {
        windowModel.dismissCommandPalette()
        if fromPage, let tab = windowModel.selectedTab {
            let space = BrowserWindowModel.sheetSpace(ofTabIn: tab.spaceID, personaID: tab.personaID, spaces: session.spaces, currentSpace: windowModel.currentSpace)
            session.installFromWebStore?(tab.personaID, space?.id, id)
        } else {
            session.installFromWebStore?(windowModel.personaID, windowModel.currentSpace.id, id)
        }
    }

    private var askAgentOffer: AskAgentOffer? {
        windowModel.askAgentOffer(for: text, settings: aiSettings)
    }

    /// The live agent sessions whose titles contain the text, ignoring case, to show in the panel.
    private var matchingAgentSessions: [AgentSession] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, let agents = session.agents else { return [] }
        return Array(agents.sessions.filter { !$0.hasEnded && $0.title.lowercased().contains(query) }.prefix(5))
    }

    /// The palette's distance from the window's top.
    static let top: CGFloat = 120
    /// The height of the search field.
    static let fieldHeight: CGFloat = 62
    /// The space between the search field and the results panel.
    static let surfaceSpacing: CGFloat = 12
    /// The search field is a rounded rectangle, not a capsule.
    static let fieldRadius: CGFloat = 18

    /// The results appear once there is something to act on, as in Spotlight.
    private var showsResults: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The results panel's rows in the order it lists them, the order Up and Down move through.
    private var rows: [PaletteItem] {
        let storeRows = webStoreRows
        var items: [PaletteItem] = [.primary]
        if let id = storeRows.typedExtension { items.append(.typedStore(id)) }
        if let offer = askAgentOffer { items.append(.askAgent(offer)) }
        items += matchingAgentSessions.map(PaletteItem.agentSession)
        items += pluginCommands.map(PaletteItem.command)
        if offersAskAboutPage { items.append(.askAboutPage) }
        if let id = storeRows.pageExtension { items.append(.pageStore(id)) }
        items += matchingTabs.map(PaletteItem.tab)
        items += historySuggestions.map(PaletteItem.history)
        return items
    }

    private func selectedIndex(in items: [PaletteItem]) -> Int {
        selectedRow.flatMap { selected in items.firstIndex { $0.id == selected.id } } ?? 0
    }

    /// Up and Down stop at the first and the last row.
    private func moveSelection(by step: Int, in items: [PaletteItem]) {
        selectedRow = items[max(0, min(selectedIndex(in: items) + step, items.count - 1))]
    }

    /// Return runs the selected row while the results show, and otherwise acts on the text as before.
    private func submit(in items: [PaletteItem]) {
        guard showsResults else { return windowModel.submitCommandPalette(text) }
        // Keep the reviewed document when Return runs a highlighted Ask Agent row after a redraw.
        if case .askAgent(let offer) = selectedRow, offer.task == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            perform(.askAgent(offer))
            return
        }
        perform(items[selectedIndex(in: items)])
    }

    /// Runs a row, on a click or on Return while it is selected.
    private func perform(_ row: PaletteItem) {
        switch row {
        case .primary:
            windowModel.submitCommandPalette(text)
        case .typedStore(let id):
            installFromWebStore(id, fromPage: false)
        case .askAgent(let offer):
            windowModel.dismissCommandPalette()
            windowModel.askAgent(offer, settings: aiSettings)
        case .agentSession(let agentSession):
            windowModel.dismissCommandPalette()
            windowModel.showAgentSession(agentSession.id)
        case .command(let command):
            windowModel.dismissCommandPalette()
            windowModel.runPluginCommand(command.ref)
        case .askAboutPage:
            windowModel.dismissCommandPalette()
            windowModel.askAboutPage()
        case .pageStore(let id):
            installFromWebStore(id, fromPage: true)
        case .tab(let tab):
            windowModel.selectTab(tab.id)
            windowModel.dismissCommandPalette()
        case .history(let entry):
            windowModel.submitCommandPalette(entry.url.absoluteString)
        }
    }

    @ViewBuilder private func rowView(for row: PaletteItem, isSelected: Bool) -> some View {
        switch row {
        case .primary:
            PaletteRow(symbol: isSelected ? "arrow.turn.down.left" : actionSymbol, title: actionLabel, isPrimary: true, isSelected: isSelected)
        case .typedStore:
            PaletteRow(symbol: "puzzlepiece.extension", title: PaletteWebStoreRows.typedTitle, isSelected: isSelected)
        case .askAgent(let offer):
            PaletteRow(symbol: "sparkles", title: offer.title, subtitle: offer.sharingDetail, isSelected: isSelected)
        case .agentSession(let agentSession):
            PaletteRow(symbol: "text.bubble", title: agentSession.title, detail: session.agents?.place(of: agentSession), isSelected: isSelected)
        case .command(let command):
            PaletteRow(symbol: command.item.symbol ?? "puzzlepiece.extension", title: command.item.title, detail: command.pluginName, isSelected: isSelected)
        case .askAboutPage:
            PaletteRow(symbol: "sparkles", title: "Ask About This Page\u{2026}", isSelected: isSelected)
        case .pageStore:
            PaletteRow(symbol: "puzzlepiece.extension", title: PaletteWebStoreRows.pageTitle, isSelected: isSelected)
        case .tab(let tab):
            PaletteTabRow(tab: tab, isSelected: isSelected)
        case .history(let entry):
            // The site follows the title in the rows' trailing column, as a command's plugin does.
            PaletteRow(symbol: "clock", title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                       detail: entry.title.isEmpty ? nil : AddressPillView.siteName(of: entry.url), isSelected: isSelected)
        }
    }

    var body: some View {
        let items: [PaletteItem] = showsResults ? rows : [.primary]
        VStack(spacing: Self.surfaceSpacing) {
            // The symbol's column and the text start line up with the rows' below.
            HStack(spacing: 14) {
                Image(systemName: mode == .newTab ? "plus" : "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField(mode == .newTab ? "Search or enter address for a new tab" : "Search or enter address", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($isFocused)
                    .onSubmit { submit(in: items) }
                    .onExitCommand { windowModel.dismissCommandPalette() }
            }
            .padding(.horizontal, 22)
            .frame(height: Self.fieldHeight)
            .modifier(PaletteSurface(shape: RoundedRectangle(cornerRadius: Self.fieldRadius, style: .continuous)))
            .background(PaletteArrowKeys(isActive: isFocused && showsResults && !isLeaving && !isWarmUp, move: { moveSelection(by: $0, in: items) }))
            if showsResults {
                let selected = selectedIndex(in: items)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                        rowView(for: row, isSelected: index == selected)
                            .paletteAction { perform(row) }
                            .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                }
                .padding(PaletteRowHighlight.panelInset)
                .modifier(PaletteSurface(shape: RoundedRectangle(cornerRadius: PaletteRowHighlight.panelRadius, style: .continuous)))
            }
        }
        // A window narrower than the palette, such as a small window, keeps the page margin on both sides of it.
        .frame(maxWidth: 600)
        .modifier(CommandPaletteAppearance(offset: arrivalOffset, isHidden: !hasArrived || isLeaving))
        .allowsHitTesting(!isLeaving)
        .padding(.top, Self.top)
        .padding(.horizontal, BrowserWindowView.pageMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !isWarmUp else { return }
            if mode == .editCurrent { text = windowModel.internalPage?.address ?? windowModel.selectedTab?.url?.absoluteString ?? "" }
            // The arrival animation waits until the hidden first frame is on screen, so a slow first build cannot use up the animation time.
            DispatchQueue.main.async {
                withAnimation(.paletteIn(from: windowModel.commandPaletteOrigin)) {
                    hasArrived = true
                    onArrival()
                }
            }
            DispatchQueue.main.async { isFocused = true }
        }
        // At once, unlike the history read, so Return right after typing runs the first row for the new text.
        .onChange(of: text) { selectedRow = nil }
        .task(id: text) { await loadHistorySuggestions() }
    }
}

/// One row of the palette's results panel.
@MainActor private enum PaletteItem {
    /// Acts on the text as typed: an address, a site search, or a web search.
    case primary
    case typedStore(String)
    case askAgent(AskAgentOffer)
    case agentSession(AgentSession)
    case command(Attributed<PluginCommand>)
    case askAboutPage
    case pageStore(String)
    case tab(Tab)
    case history(HistoryEntry)

    /// Unique among the rows: each kind of row shows once at most, except commands, tabs, and history pages, which each have their own identity.
    var id: AnyHashable {
        switch self {
        case .primary: return "primary"
        case .typedStore: return "typedStore"
        case .askAgent: return "askAgent"
        case .agentSession(let session): return "agent-" + session.id.uuidString
        case .command(let command): return command.ref
        case .askAboutPage: return "askAboutPage"
        case .pageStore: return "pageStore"
        case .tab(let tab): return tab.id
        case .history(let entry): return entry.id
        }
    }
}

/// Moves the palette's selection with Up and Down while its field has the keyboard focus and no input method is composing text in it. The monitor sees the keys before the field's editor, which would move the caret to the text's start or end; other keys, and arrows with a modifier, go on to the field.
private struct PaletteArrowKeys: NSViewRepresentable {
    let isActive: Bool
    let move: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isActive = isActive
        view.move = move
    }

    /// Lies behind the field and takes no clicks.
    final class MonitorView: NSView {
        var isActive = false
        var move: ((Int) -> Void)?
        private var monitor: Any?

        // A window that closes releases its views without moving them out of it first.
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let step = self.step(for: event) else { return event }
                self.move?(step)
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func step(for event: NSEvent) -> Int? {
            guard isActive, let window, event.window === window,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return nil }
            switch event.keyCode {
            case 125: return 1
            case 126: return -1
            default: return nil
            }
        }
    }
}

/// The palette's Web Store rows (`docs/web-store.md`, Entry points), each with the identifier of the extension it installs, which name no Persona.
struct PaletteWebStoreRows: Equatable {
    /// With an ellipsis, as both rows open the store sheet and its review before anything installs.
    static let pageTitle = "Install Extension from This Page\u{2026}"
    static let typedTitle = "Install from the Web Store\u{2026}"
    /// Install Extension from This Page: the extension of the store page that the selected tab shows, once the typed words begin the row's name or the text names that extension, as the page's address does, which the palette starts with when it edits the current address.
    var pageExtension: String?
    /// Install from the Web Store, below the primary row: another extension that the text names, as a store page's address or a bare identifier.
    var typedExtension: String?

    init(pageExtension: String? = nil, typedExtension: String? = nil) {
        self.pageExtension = pageExtension
        self.typedExtension = typedExtension
    }

    /// The rows for the typed text and the address of the selected tab's page, nil while no tab shows a page.
    init(text: String, pageURL: URL?, reader: WebStoreReader = .store) {
        let typed = reader.text(text)
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let page = pageURL.flatMap(reader.page), typed == page || (!words.isEmpty && Self.pageTitle.lowercased().hasPrefix(words)) {
            pageExtension = page
        }
        typedExtension = typed == pageExtension ? nil : typed
    }
}

/// The task, destination and visible document reviewed in the palette.
@MainActor struct AskAgentOffer {
    let task: String
    private let personaID: UUID
    private let spaceID: UUID
    private let tabID: UUID?
    private let documentID: UUID?
    private let url: URL?
    private let sharedTitle: String?

    init?(text: String, canRunSession: Bool, context: @autoclosure () -> AgentComposerContext, allowsAI: (URL) -> Bool) {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRunSession, task.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }
        self.task = task
        let context = context()
        personaID = context.personaID
        spaceID = context.spaceID
        tabID = context.tab?.id
        documentID = context.tab?.documentID
        url = context.tab?.url
        sharedTitle = context.attachableTab(allowsAI: allowsAI)?.title
    }

    var title: String { "Ask Agent: \u{201C}\(task)\u{201D}" }
    var sharingDetail: String { sharedTitle.map { "Shares \($0)" } ?? "No page shared" }

    func matches(_ context: AgentComposerContext, allowsAI: (URL) -> Bool) -> Bool {
        context.personaID == personaID && context.spaceID == spaceID && context.tab?.id == tabID &&
            context.tab?.documentID == documentID && context.tab?.url == url &&
            (context.attachableTab(allowsAI: allowsAI) != nil) == (sharedTitle != nil)
    }
}

/// The command palette over a window of either kind, with the dimming behind it that a click dismisses. Each opening gets a fresh palette, which arrives with its origin's motion; closing fades out the palette and the dimming, then removes both.
struct CommandPaletteLayer: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// The frame of the address pill that a palette opened from the pill comes out of.
    let addressPillFrame: CGRect?
    /// The window's width, which with the pill's frame sets the line that such a palette travels along.
    let windowWidth: CGFloat
    /// How far the address pill has moved toward the palette.
    @Binding var addressPillPull: CGSize
    /// The displayed palette mode. It stays set while the palette closes because removal transitions do not run in this window.
    @State private var shownPaletteMode: CommandPaletteMode?
    @State private var isPaletteLeaving = false
    /// Set after the hidden warm-up palette is drawn.
    @State private var isPaletteWarm = false
    /// The palette's entry motion, fixed when it opens.
    @State private var paletteMotion = PaletteMotion()

    /// A window without an address pill leaves out the pill's frame and pull and the width that places the palette relative to the pill.
    init(session: BrowserSession, addressPillFrame: CGRect? = nil, windowWidth: CGFloat = 0, addressPillPull: Binding<CGSize> = .constant(.zero)) {
        self.session = session
        self.addressPillFrame = addressPillFrame
        self.windowWidth = windowWidth
        _addressPillPull = addressPillPull
    }

    var body: some View {
        ZStack {
            if shownPaletteMode != nil {
                Color.black.opacity(isPaletteLeaving ? 0 : 0.15)
                    .onTapGesture { windowModel.dismissCommandPalette() }
                    .transition(.opacity)
            }
            // Drawing a hidden palette once as the window opens builds the text field, material, and fonts before the first visible palette opens. Otherwise, that palette would appear only after its arrival animation ends.
            if !isPaletteWarm {
                CommandPaletteView(session: session, mode: .newTab, isWarmUp: true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isPaletteWarm = true } }
            }
            if let mode = shownPaletteMode {
                // Each opening gets a fresh view, with reset text and a focused field, even if the previous palette is still leaving.
                CommandPaletteView(session: session, mode: mode, isLeaving: isPaletteLeaving, arrivalOffset: paletteMotion.arrival,
                                   onArrival: { addressPillPull = paletteMotion.pull })
                    .id(windowModel.commandPaletteGeneration)
            }
        }
        .onAppear { shownPaletteMode = windowModel.commandPaletteMode }
        .onChange(of: windowModel.commandPaletteMode) { _, mode in
            guard mode == nil else {
                isPaletteLeaving = false
                // Open Location asks for the pill, which a hidden sidebar or a small window does not show; the palette then opens as other shortcuts open it.
                let origin = windowModel.commandPaletteOrigin == .addressPill && addressPillFrame == nil ? .keyboard : windowModel.commandPaletteOrigin
                paletteMotion = PaletteMotion(origin: origin, pill: addressPillFrame, windowWidth: windowWidth)
                if paletteMotion.pull == .zero { withAnimation(.paletteIn(from: .addressPill)) { addressPillPull = .zero } }
                return withAnimation(.paletteIn(from: origin)) { shownPaletteMode = mode }
            }
            withAnimation(.paletteOut) { isPaletteLeaving = true }
            // The pill returns as the palette leaves.
            withAnimation(.paletteIn(from: .addressPill)) { addressPillPull = .zero }
            let generation = windowModel.commandPaletteGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Animation.paletteOutDuration) {
                // A palette reopened during this delay has a new generation and stays until it finishes closing.
                guard windowModel.commandPaletteGeneration == generation else { return }
                shownPaletteMode = nil
                isPaletteLeaving = false
            }
        }
    }
}

/// Uses the system's glass on macOS 26 and later; earlier versions use the system material with a shadow. The glass is a separate layer behind the content, outside any glass container: glass applied to the content draws its text vibrant, as gray as the placeholder, and a container draws its glass over the content.
struct PaletteSurface<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(Color.clear.glassEffect(.regular, in: shape))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
        }
    }
}

/// The palette enters from `offset` with a blur and exits the same way. A shortcut raises it a little from below; a sidebar control brings it from the sidebar's side; the address pill sends it out along the line from the pill.
struct CommandPaletteAppearance: ViewModifier {
    let offset: CGSize
    let isHidden: Bool

    /// The sidebar sits on the leading side.
    static func offset(from origin: CommandPaletteOrigin) -> CGSize {
        origin == .keyboard ? CGSize(width: 0, height: 16) : CGSize(width: -32, height: 0)
    }

    func body(content: Content) -> some View {
        content
            .offset(isHidden ? offset : .zero)
            .blur(radius: isHidden ? 10 : 0)
            .opacity(isHidden ? 0 : 1)
    }
}

/// The palette's entry motion: where it starts and how far the address pill moves toward it.
struct PaletteMotion {
    var arrival = CommandPaletteAppearance.offset(from: .keyboard)
    var pull = CGSize.zero
    /// How far the palette travels into place from the pill, and the pill toward it.
    static let distance: CGFloat = 40

    init() {}

    /// From the address pill, the palette moves along the line from the pill's center to the search field's center. The pill moves the same distance in the same direction as it fades out.
    init(origin: CommandPaletteOrigin, pill: CGRect?, windowWidth: CGFloat) {
        guard origin == .addressPill, let pill, windowWidth > 0 else {
            arrival = CommandPaletteAppearance.offset(from: origin)
            return
        }
        let dx = windowWidth / 2 - pill.midX
        let dy = CommandPaletteView.top + CommandPaletteView.fieldHeight / 2 - pill.midY
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let (ux, uy) = (dx / length, dy / length)
        arrival = CGSize(width: -ux * Self.distance, height: -uy * Self.distance)
        pull = CGSize(width: ux * Self.distance, height: uy * Self.distance)
    }
}

extension Animation {
    /// Something that appears arrives fast and slows to a stop. A shortcut opens the palette twice as fast as a sidebar control.
    static func paletteIn(from origin: CommandPaletteOrigin) -> Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: origin == .keyboard ? 0.16 : 0.32)
    }
    /// Something that leaves starts slowly and speeds away.
    static let paletteOut = Animation.timingCurve(0.7, 0, 0.84, 0, duration: paletteOutDuration)
    static let paletteOutDuration = 0.2
}

struct PaletteRow: View {
    let symbol: String
    let title: String
    /// A second line when the action needs a sharing disclosure.
    var subtitle: String?
    /// Dim text at the trailing end, such as the plugin that adds a command or a history page's site. It keeps its width, so a long title truncates first.
    var detail: String?
    /// The first row, which acts on the text as typed, has a heavier title.
    var isPrimary = false
    var isSelected = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: isPrimary ? .medium : .regular))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(Rectangle())
        .modifier(PaletteRowHighlight(isSelected: isSelected))
    }
}

struct PaletteTabRow: View {
    @ObservedObject var tab: Tab
    var isSelected = false

    var body: some View {
        HStack(spacing: 14) {
            // Square, as every other list draws a tab's icon, and centered in the rows' symbol column.
            TabIconView(tab: tab, symbolSize: 15)
                .frame(width: 18, height: 18)
                .frame(width: 20)
            Text(tab.shownTitle)
                .font(.system(size: 15))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("Switch to Tab")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(Rectangle())
        .modifier(PaletteRowHighlight(isSelected: isSelected))
    }
}

extension View {
    /// Runs `action` on a click and on the accessibility press, which a tap gesture alone does not answer.
    func paletteAction(_ action: @escaping () -> Void) -> some View {
        onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// Highlights a row under the pointer. The selected row, which Return runs and Up and Down move, the first row until then, keeps an accent highlight. The highlight's corners follow the results panel's corners, offset inward by the panel's inset.
struct PaletteRowHighlight: ViewModifier {
    static let panelRadius: CGFloat = 26
    static let panelInset: CGFloat = 8
    /// The accent's opacity behind the row that the keyboard selects, here and in the tab switcher, which shares the panel.
    static let selectedOpacity = 0.16

    var isSelected = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Self.panelRadius - Self.panelInset, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(isHovering ? 0.24 : Self.selectedOpacity) : Color.primary.opacity(isHovering ? 0.07 : 0)))
            .onHover { isHovering = $0 }
    }
}
