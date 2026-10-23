// The command palette floats over the window and uses its mode to edit the current tab's address or open a new tab. As the user types, it lists matching open tabs to switch to and matching pages from history.
import History
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var session: BrowserSession
    let mode: CommandPaletteMode
    @State private var text = ""
    @FocusState private var isFocused: Bool

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
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { session.dismissCommandPalette() }
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
                    .onTapGesture { session.submitCommandPalette(text) }
                ForEach(matchingTabs) { tab in
                    PaletteTabRow(tab: tab)
                        .onTapGesture {
                            session.selectedTabID = tab.id
                            session.dismissCommandPalette()
                        }
                }
                ForEach(historySuggestions) { entry in
                    PaletteRow(symbol: "clock", title: entry.title.isEmpty ? entry.url.absoluteString : "\(entry.title) · \(entry.url.host ?? entry.url.absoluteString)")
                        .onTapGesture { session.submitCommandPalette(entry.url.absoluteString) }
                }
            }
            .padding(.bottom, 6)
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 120)
            .onAppear {
                if mode == .editCurrent { text = session.selectedTab?.url?.absoluteString ?? "" }
                DispatchQueue.main.async { isFocused = true }
            }
        }
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
