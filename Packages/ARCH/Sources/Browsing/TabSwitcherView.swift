// The tab switcher floats over the window while Control stays down after ⌃Tab. It lists the current space's listed tabs and the open tabs of the window's Persona's favorites (`BrowserWindowModel.recentTabs`), most recently selected first, and highlights the tab that releasing Control selects.
import SwiftUI

struct TabSwitcherView: View {
    /// Observed because the tabs the switcher lists are the session's.
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Set a moment after the switcher opens, so that a quick ⌃Tab, which switches at once, does not flash it.
    @State private var isShown = false

    static let width: CGFloat = 440
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    /// Beyond this many tabs, the list scrolls to keep the highlighted tab in view.
    static let visibleRows = 10

    var body: some View {
        let tabs = windowModel.recentTabs
        let rows = CGFloat(min(tabs.count, Self.visibleRows))
        let panel = RoundedRectangle(cornerRadius: PaletteRowHighlight.panelRadius, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(tabs) { tab in
                        TabSwitcherRow(session: session, tab: tab, isHighlighted: tab.id == windowModel.tabSwitcherHighlightID)
                            .id(tab.id)
                    }
                }
                .padding(PaletteRowHighlight.panelInset)
            }
            .scrollDisabled(tabs.count <= Self.visibleRows)
            .frame(width: Self.width, height: rows * Self.rowHeight + max(0, rows - 1) * Self.rowSpacing + 2 * PaletteRowHighlight.panelInset)
            // Rows that scroll past the inset stay inside the panel's corners.
            .clipShape(panel)
            .onAppear { if let id = windowModel.tabSwitcherHighlightID { proxy.scrollTo(id) } }
            .onChange(of: windowModel.tabSwitcherHighlightID) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .modifier(PaletteSurface(shape: panel))
        .scaleEffect(isShown ? 1 : 0.97)
        .opacity(isShown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The switcher follows the keyboard only; Control-clicks go on to the page as context clicks.
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab Switcher")
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeOut(duration: 0.12)) { isShown = true }
            }
        }
    }
}

private struct TabSwitcherRow: View {
    let session: BrowserSession
    @ObservedObject var tab: Tab
    let isHighlighted: Bool

    /// The name of the web extension whose page the tab shows (`AddressPillView.extensionName(ofPageAt:in:session:)`).
    private var extensionName: String? {
        tab.url.flatMap { AddressPillView.extensionName(ofPageAt: $0, in: tab, session: session) }
    }

    /// The site after `title`, the tab's title as its sidebar row shows it (`Tab.shownTitle`): the site as the address pill names it, or nil without a host or when the title already is the site, as for a page without a title.
    private func site(title: String, extensionName: String?) -> String? {
        guard let url = tab.url, let host = url.host, !host.isEmpty, tab.displayTitle != host else { return nil }
        let site = extensionName ?? AddressPillView.siteName(of: url)
        return site == title ? nil : site
    }

    var body: some View {
        let title = tab.shownTitle
        let site = self.site(title: title, extensionName: extensionName)
        HStack(spacing: 10) {
            TabIconView(tab: tab)
                .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let site {
                // Keeps its width, so a long title truncates first, as in the palette's rows.
                Text(site)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TabSwitcherView.rowHeight)
        .background(RoundedRectangle(cornerRadius: PaletteRowHighlight.panelRadius - PaletteRowHighlight.panelInset, style: .continuous)
            .fill(isHighlighted ? Color.accentColor.opacity(PaletteRowHighlight.selectedOpacity) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
