// The command palette floats over the window and uses its mode to edit the current tab's address or open a new tab. As the user types, it lists matching plugin commands, Ask About This Page when the words begin its name, open tabs to switch to, and pages from history. Text that starts with a site search keyword and a space searches that site.
import History
import Plugins
import SwiftUI

struct CommandPaletteView: View {
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

    /// Matching commands of the enabled plugins of the window's Persona.
    private var pluginCommands: [Attributed<PluginCommand>] {
        Array(session.plugins(in: windowModel.personaID).contributions.paletteCommands(matching: text).prefix(5))
    }

    /// The listed tabs of the window's Persona to switch to. A small window shows only its own tab, so its palette offers none.
    private var matchingTabs: [Tab] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, windowModel.kind == .main else { return [] }
        return Array(session.allTabs.filter { tab in
            tab.id != windowModel.selectedTabID && tab.isListedInSidebar && tab.personaID == windowModel.personaID &&
                (tab.displayTitle.lowercased().contains(query) || tab.url?.absoluteString.lowercased().contains(query) == true)
        }.prefix(5))
    }

    /// Pages that share a title and host, such as the steps of a sign-in flow, appear once.
    private var historySuggestions: [HistoryEntry] {
        var seen = Set<String>()
        return Array(HistoryStore.shared.suggestions(for: text, limit: 15).filter { seen.insert("\($0.title)\u{1F}\($0.url.host ?? "")").inserted }.prefix(5))
    }

    private var actionLabel: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return mode == .newTab ? "Open a new tab" : "Enter an address or search" }
        if let page = InternalPage(address: trimmed) { return "Open \(page.address)" }
        // The session reads the untrimmed text the same way, so a keyword and a space are enough.
        if let search = SiteSearchStore.shared.match(text) {
            return search.query.isEmpty ? "Search \(search.shortcut.name)" : "Search \(search.shortcut.name) for \"\(search.query)\""
        }
        if let url = BrowserSession.url(forInput: trimmed) { return "Go to \(url.host ?? trimmed)" }
        return "Search for \"\(trimmed)\""
    }

    /// Ask About This Page appears once the typed words begin its name, while the selected tab's page can be asked about.
    private var offersAskAboutPage: Bool {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !words.isEmpty && "ask about this page".hasPrefix(words) && windowModel.canAskAboutPage
    }

    /// The palette's distance from the window's top.
    static let top: CGFloat = 120
    /// The height of the search field.
    static let fieldHeight: CGFloat = 62
    /// The space between the search field and the results panel.
    static let surfaceSpacing: CGFloat = 12

    /// The results appear once there is something to act on, as in Spotlight.
    private var showsResults: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: Self.surfaceSpacing) {
            HStack(spacing: 14) {
                Image(systemName: mode == .newTab ? "plus" : "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                TextField(mode == .newTab ? "Search or enter address for a new tab" : "Search or enter address", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($isFocused)
                    .onSubmit { windowModel.submitCommandPalette(text) }
                    .onExitCommand { windowModel.dismissCommandPalette() }
            }
            .padding(.horizontal, 26)
            .frame(height: Self.fieldHeight)
            .modifier(PaletteSurface(shape: Capsule()))
            if showsResults {
                VStack(spacing: 2) {
                    PaletteRow(symbol: "arrow.turn.down.left", title: actionLabel, isPrimary: true)
                        .paletteAction { windowModel.submitCommandPalette(text) }
                    ForEach(pluginCommands, id: \.ref) { command in
                        PaletteRow(symbol: command.item.symbol ?? "puzzlepiece.extension", title: command.item.title, detail: command.pluginName)
                            .paletteAction { windowModel.runPluginCommand(command.ref) }
                    }
                    if offersAskAboutPage {
                        PaletteRow(symbol: "sparkles", title: "Ask About This Page")
                            .paletteAction {
                                windowModel.dismissCommandPalette()
                                windowModel.askAboutPage()
                            }
                    }
                    ForEach(matchingTabs) { tab in
                        PaletteTabRow(tab: tab)
                            .paletteAction {
                                windowModel.selectedTabID = tab.id
                                windowModel.dismissCommandPalette()
                            }
                    }
                    ForEach(historySuggestions) { entry in
                        PaletteRow(symbol: "clock", title: entry.title.isEmpty ? entry.url.absoluteString : "\(entry.title) · \(entry.url.host ?? entry.url.absoluteString)")
                            .paletteAction { windowModel.submitCommandPalette(entry.url.absoluteString) }
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
    /// How far the address pill's contents have moved toward the palette.
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
                paletteMotion = PaletteMotion(origin: windowModel.commandPaletteOrigin, pill: addressPillFrame, windowWidth: windowWidth)
                if paletteMotion.pull == .zero { withAnimation(.paletteIn(from: .addressPill)) { addressPillPull = .zero } }
                return withAnimation(.paletteIn(from: windowModel.commandPaletteOrigin)) { shownPaletteMode = mode }
            }
            withAnimation(.paletteOut) { isPaletteLeaving = true }
            // The pill's contents return as the palette leaves.
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
    /// Dim text at the trailing end, such as the plugin that adds a command.
    var detail: String?
    var isPrimary = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 15, weight: isPrimary ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(Rectangle())
        .modifier(PaletteRowHighlight(isPrimary: isPrimary))
    }
}

struct PaletteTabRow: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 14) {
            TabIconView(tab: tab)
                .frame(width: 20, height: 18)
            Text(tab.displayTitle)
                .font(.system(size: 15))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("Switch to Tab")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(Rectangle())
        .modifier(PaletteRowHighlight())
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

/// Highlights a row under the pointer. The primary row, which Return opens, keeps an accent highlight. The highlight's corners follow the results panel's corners, offset inward by the panel's inset.
struct PaletteRowHighlight: ViewModifier {
    static let panelRadius: CGFloat = 26
    static let panelInset: CGFloat = 8

    var isPrimary = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Self.panelRadius - Self.panelInset, style: .continuous)
                .fill(isPrimary ? Color.accentColor.opacity(isHovering ? 0.24 : 0.16) : Color.primary.opacity(isHovering ? 0.07 : 0)))
            .onHover { isHovering = $0 }
    }
}
