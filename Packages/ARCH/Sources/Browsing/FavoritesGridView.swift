// The favorites grid below the address pill: one tile per favorite of the window's Persona, which opens or selects the favorite's tab, previews it, or moves among the others.
import AppKit
import ARCHEngine
import SwiftUI

/// The number of shortcuts in a full row. The last row shares its available width among the remaining shortcuts.
public enum FavoriteTileLayout {
    public static let columnsKey = "ARCHFavoriteColumns"
    public static let rowSizesKey = "ARCHFavoriteRowSizes"
    public static let defaultColumns = 4
    public static let choices = 1...4
    static let spacing: CGFloat = 6
    static let height: CGFloat = 44

    public static func columnCount(_ stored: Int) -> Int {
        min(max(stored, choices.lowerBound), choices.upperBound)
    }

    public static func rowSizes(from data: Data) -> [Int] {
        let stored = (try? JSONDecoder().decode([Int].self, from: data)) ?? []
        return stored.map(columnCount)
    }

    public static func encode(rowSizes: [Int]) -> Data {
        (try? JSONEncoder().encode(rowSizes.map(columnCount))) ?? Data()
    }

    static func counts(for favorites: Int, rowSizes: [Int], defaultColumns: Int) -> [Int] {
        var remaining = favorites
        var counts: [Int] = []
        while remaining > 0 {
            let row = counts.count
            let capacity = row < rowSizes.count ? rowSizes[row] : defaultColumns
            let count = min(remaining, columnCount(capacity))
            counts.append(count)
            remaining -= count
        }
        return counts
    }
}

/// Keeps each favorite in the same view while it crosses rows during a drag.
struct FavoriteRows: Layout {
    let rowSizes: [Int]
    let defaultColumns: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = FavoriteTileLayout.counts(for: subviews.count, rowSizes: rowSizes, defaultColumns: defaultColumns).count
        return CGSize(width: proposal.width ?? SidebarView.defaultWidth,
                      height: CGFloat(rows) * FavoriteTileLayout.height + CGFloat(max(0, rows - 1)) * FavoriteTileLayout.spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spacing = FavoriteTileLayout.spacing
        var index = 0
        for (row, count) in FavoriteTileLayout.counts(for: subviews.count, rowSizes: rowSizes, defaultColumns: defaultColumns).enumerated() {
            let width = max(0, bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count)
            for column in 0..<count {
                let origin = CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing),
                                     y: bounds.minY + CGFloat(row) * (FavoriteTileLayout.height + spacing))
                subviews[index].place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: FavoriteTileLayout.height))
                index += 1
            }
        }
    }
}

/// Shows the favorites that every space of the window's Persona shares as a grid of site icons. A favorite that has a tab of its own is marked as open, and clicking it selects that tab. Dragging a tile moves it among the others, and holding Shift over one previews it.
struct FavoritesGridView: View {
    @ObservedObject var session: BrowserSession
    let personaID: Persona.ID
    @AppStorage(FavoriteTileLayout.columnsKey) private var columns = FavoriteTileLayout.defaultColumns
    @AppStorage(FavoriteTileLayout.rowSizesKey) private var rowSizes = Data()
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    /// Each tile's frame in the window, used to find the tile under a dragged favorite.
    @State private var tileFrames: [UUID: CGRect] = [:]
    @State private var reorderHover = SidebarReorderHover()

    var body: some View {
        let favorites = session.favorites(in: personaID)
        FavoriteRows(rowSizes: FavoriteTileLayout.rowSizes(from: rowSizes), defaultColumns: columns) {
            ForEach(favorites) { favorite in
                tile(favorite, selected: windowModel.selectedFavoriteID)
            }
        }
        .onPreferenceChange(SidebarItemFramesKey.self) { tileFrames = $0 }
        .onChange(of: sidebarDrag.item) { _, item in
            if item == nil { reorderHover = SidebarReorderHover() }
        }
    }

    private func tile(_ favorite: Favorite, selected: Favorite.ID?) -> some View {
        FavoriteTileView(favorite: favorite, isActive: favorite.id == selected, isOpen: session.hasOpenPage(favorite),
                         prompts: session.prompts, tabID: session.favoriteTabs[favorite.id]?.id)
            // The release that ends a drag does not also open the favorite.
            .onTapGesture { if sidebarDrag.item == nil { windowModel.openFavorite(favorite) } }
            .accessibilityAction { windowModel.openFavorite(favorite) }
            .contextMenu {
                // The favorite's address and title are its saved page (bookmark rule 2); the commands act on its open tab.
                if let tab = session.favoriteTabs[favorite.id] {
                    FavoriteTabSavedPageItems(tab: tab, session: session)
                    SidebarAgentMenuItem(windowModel: windowModel, tab: tab)
                } else {
                    Button("Use Current Page as Saved Page") {}.disabled(true)
                }
                Button("Edit Favorite\u{2026}") { windowModel.promptToEditFavorite(favorite) }
                Button("Copy Address") { Tab.copyToPasteboard(favorite.url) }
                Divider()
                Button("Close Tab") { session.closeFavorite(favorite) }
                    .disabled(!session.hasTab(favorite))
                Divider()
                Button("Remove from Favorites") { session.removeFavorite(favorite) }
            }
            .modifier(SidebarItemDrag(item: .favorite(favorite.id), cornerRadius: 10) { reorder(favorite, at: $0) })
            .modifier(ShiftHoverPreview { if sidebarDrag.item == nil { windowModel.previewFavorite(favorite) } })
    }

    /// The tile under the pointer makes room for the dragged favorite, with a light haptic at each new position.
    private func reorder(_ favorite: Favorite, at location: CGPoint) {
        guard sidebarDrag.item == .favorite(favorite.id), personaID == windowModel.personaID,
              sidebarDrag.favoriteBarFrames[windowModel.currentSpaceID]?.contains(location) == true, reorderHover.canMove(at: location),
              let target = session.favorites(in: personaID).first(where: { $0.id != favorite.id && tileFrames[$0.id]?.contains(location) == true }),
              let frame = tileFrames[target.id] else { return }
        reorderHover.moved(into: frame)
        withAnimation(.easeInOut(duration: 0.15)) { session.moveFavorite(favorite.id, to: target) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// A favorite tile's Go Back to Saved Page and Use Current Page as Saved Page, which follow the favorite's open tab: the grid redraws with the window's selected tab and the session's lists, so a page change in the tab while another tab is selected would otherwise leave them as they were.
private struct FavoriteTabSavedPageItems: View {
    @ObservedObject var tab: Tab
    @ObservedObject var session: BrowserSession

    var body: some View {
        if session.isOffSavedPage(tab) {
            Button("Go Back to Saved Page") { session.goBackToSavedPage(tab) }
        }
        Button("Use Current Page as Saved Page") { session.useCurrentPageAsSavedPage(tab) }
            .disabled(!session.canUseCurrentPageAsSavedPage(tab))
    }
}

struct FavoriteTileView: View {
    let favorite: Favorite
    /// Set while the favorite's tab is selected.
    let isActive: Bool
    /// Set while the favorite's page is open, which a dot below the tile shows, as the Dock does for an open app. Otherwise, as before the favorite's first click or after its tab unloaded, the icon is dimmed, as the row of a tab without its page is.
    let isOpen: Bool
    /// Observed for the waiting mark, since the session does not republish the queue's changes.
    @ObservedObject var prompts: TabPromptQueue
    /// The favorite's tab, whose prompts the mark shows.
    let tabID: UUID?
    @Environment(\.colorScheme) private var colorScheme
    @State private var icon: NSImage?
    /// The icon address last requested, so that an icon arriving after the favorite moved to another site is dropped.
    @State private var iconURL: URL?
    @State private var isHovering = false

    var body: some View {
        // The selection lies over the tile's own fill and adds the step a tab row's selection adds, so in the dark appearance a selected tile stays apart from a hovered one. As with the selected row, only the light appearance lifts it.
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(SidebarFill.field.color(in: colorScheme))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SidebarFill.selected.color(in: colorScheme)).opacity(isActive ? 1 : 0))
            .shadow(color: .black.opacity(isActive && colorScheme == .light ? 0.08 : 0), radius: 1.5, y: 0.5)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SidebarFill.hover.color(in: colorScheme).opacity(isHovering && !isActive ? 1 : 0)))
            .frame(maxWidth: .infinity)
            .frame(height: FavoriteTileLayout.height)
            .overlay {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .opacity(isOpen ? 1 : SidebarDimming.unopened)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(isOpen ? 1 : SidebarDimming.unopened)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isOpen)
            // The dot sits in the gap below the tile, nearer the tile than the row below it; a short tile has no room for it under the icon.
            .overlay(alignment: .bottom) {
                if isOpen {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 4, height: 4)
                        .offset(y: 5)
                }
            }
            // The favorite's tab waits for the user's answer to a prompt. The mark sits on the tile's corner, as the Library button's count does, clear of the icon even in the narrowest sidebar.
            .overlay(alignment: .topTrailing) {
                TabPromptIndicator(prompts: prompts, tabID: tabID)
                    .offset(x: 3, y: -2)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(favorite.title)
            // One element for VoiceOver, whose value says what the dot and the mark show.
            .accessibilityElement()
            .accessibilityLabel(favorite.title)
            .accessibilityValue([isOpen ? "Open" : nil, prompts.hasPrompt(for: tabID) ? "Waiting for your answer" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .onAppear(perform: loadIcon)
            // Use Current Page as Saved Page and Edit Favorite… can move the favorite to another site.
            .onChange(of: favorite.url) {
                icon = nil
                loadIcon()
            }
    }

    private func loadIcon() {
        guard icon == nil else { return }
        let url = FaviconLoader.defaultIconURL(for: favorite.url)
        iconURL = url
        guard let url else { return }
        FaviconLoader.load(url) { image in
            if iconURL == url { icon = image }
        }
    }
}
