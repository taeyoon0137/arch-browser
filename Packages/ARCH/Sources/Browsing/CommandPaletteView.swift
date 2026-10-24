// The command palette floats over the window and uses its mode to edit the current tab's address or open a new tab. As the user types, it lists matching open tabs to switch to and matching pages from history.
import History
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var session: BrowserSession
    let mode: CommandPaletteMode
    @State private var text = ""
    @FocusState private var isFocused: Bool
    /// Set as the palette appears to animate its arrival as a state change.
    @State private var hasArrived = false

    private var matchingTabs: [Tab] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return Array(session.tabs.filter { tab in
            tab.id != session.selectedTabID &&
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
        if let url = BrowserSession.url(forInput: trimmed) { return "Go to \(url.host ?? trimmed)" }
        return "Search for \"\(trimmed)\""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: mode == .newTab ? "plus" : "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(mode == .newTab ? "Search or enter address for a new tab" : "Search or enter address", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($isFocused)
                    .onSubmit { session.submitCommandPalette(text) }
                    .onExitCommand { session.dismissCommandPalette() }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()
            PaletteRow(symbol: "arrow.turn.down.left", title: actionLabel, isPrimary: true)
                .paletteAction { session.submitCommandPalette(text) }
            ForEach(matchingTabs) { tab in
                PaletteTabRow(tab: tab)
                    .paletteAction {
                        session.selectedTabID = tab.id
                        session.dismissCommandPalette()
                    }
            }
            ForEach(historySuggestions) { entry in
                PaletteRow(symbol: "clock", title: entry.title.isEmpty ? entry.url.absoluteString : "\(entry.title) · \(entry.url.host ?? entry.url.absoluteString)")
                    .paletteAction { session.submitCommandPalette(entry.url.absoluteString) }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .modifier(CommandPaletteAppearance(offset: CommandPaletteAppearance.offset(from: session.commandPaletteOrigin), isHidden: !hasArrived))
        .padding(.top, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if mode == .editCurrent { text = session.selectedTab?.url?.absoluteString ?? "" }
            withAnimation(.paletteIn(from: session.commandPaletteOrigin)) { hasArrived = true }
            DispatchQueue.main.async { isFocused = true }
        }
    }
}

/// The palette rises a little from below with a blur when a shortcut opens it, and slides in from the sidebar's side when a sidebar control opens it. It leaves the same way.
struct CommandPaletteAppearance: ViewModifier {
    let offset: CGSize
    let isHidden: Bool

    /// The sidebar sits on the leading side.
    static func offset(from origin: CommandPaletteOrigin) -> CGSize {
        origin == .sidebar ? CGSize(width: -32, height: 0) : CGSize(width: 0, height: 16)
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
        .timingCurve(0.16, 1, 0.3, 1, duration: origin == .sidebar ? 0.32 : 0.16)
    }
    /// Something that leaves starts slowly and speeds away.
    static let paletteOut = Animation.timingCurve(0.7, 0, 0.84, 0, duration: 0.2)
}

extension AnyTransition {
    /// The palette animates its own arrival because a transition fades and sharpens its contents without moving them. Leaving needs no movement.
    static func commandPalette(from origin: CommandPaletteOrigin) -> AnyTransition {
        let offset = CommandPaletteAppearance.offset(from: origin)
        let appearance = AnyTransition.modifier(active: CommandPaletteAppearance(offset: offset, isHidden: true), identity: CommandPaletteAppearance(offset: offset, isHidden: false))
        return .asymmetric(insertion: .identity, removal: appearance.animation(.paletteOut))
    }

    /// The dimming behind the palette follows the palette's timing.
    static func commandPaletteDimming(from origin: CommandPaletteOrigin) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.paletteIn(from: origin)), removal: .opacity.animation(.paletteOut))
    }
}

struct PaletteRow: View {
    let symbol: String
    let title: String
    var isPrimary = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 14, weight: isPrimary ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .contentShape(Rectangle())
        .modifier(PaletteRowHighlight(isPrimary: isPrimary))
    }
}

struct PaletteTabRow: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            TabIconView(tab: tab)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("Switch to Tab")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
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

/// Highlights a row under the pointer. The primary row, which Return opens, keeps an accent highlight.
struct PaletteRowHighlight: ViewModifier {
    var isPrimary = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isPrimary ? Color.accentColor.opacity(isHovering ? 0.24 : 0.16) : Color.primary.opacity(isHovering ? 0.07 : 0))
                .padding(.horizontal, 6))
            .onHover { isHovering = $0 }
    }
}
