// The favorites grid below the address pill: one tile per favorite of the window's Persona, which opens or selects the favorite's tab, previews it, or moves among the others.
import AppKit
import ARCHEngine
import SwiftUI

/// The favorites grid's row capacities, which Settings ▸ Sidebar sets for each listed row and for the rows after them, and its tile metrics. A row that is not full shares its width among its favorites.
public enum FavoriteTileLayout {
    public static let columnsKey = "ARCHFavoriteColumns"
    public static let rowSizesKey = "ARCHFavoriteRowSizes"
    public static let defaultColumns = 4
    public static let choices = 1...4
    static let spacing: CGFloat = 6
    static let height: CGFloat = 44
    static let iconSize: CGFloat = 16
    static let gridHeaderSpacing: CGFloat = 10

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

/// The favorites grid's slots, laid out by row capacity: tile positions, the slot under a dragged item's pointer, and the tiles shown during a drag. A drag over the grid holds one slot open as a gap in place of a tile; the other tiles reflow around it, keeping equal widths in each row.
struct FavoriteGridSlots: Equatable {
    let rowSizes: [Int]
    let defaultColumns: Int

    enum NewRow: Equatable { case first, last }

    struct Placement: Equatable {
        let index: Int
        let frame: CGRect
        var newRow: NewRow? = nil
        var rowSizes: [Int]? = nil
    }

    /// A saved drop layout includes only rows in use; later rows start with the default capacity.
    private func usedRowSizes(for count: Int) -> [Int] {
        Array(rowSizes.prefix(rows(for: count).count))
    }

    /// A boundary drop gives the item its own row. Setting the last row's capacity to its occupied size keeps a partial row from absorbing it. The new last row leaves room for later additions.
    func insertingRow(_ edge: NewRow, remaining: Int) -> FavoriteGridSlots {
        let occupied = rows(for: remaining)
        let sizes = edge == .first ? [1] + usedRowSizes(for: remaining) : occupied + [FavoriteTileLayout.columnCount(defaultColumns)]
        return FavoriteGridSlots(rowSizes: sizes, defaultColumns: defaultColumns)
    }

    /// Drop geometry based on the saved favorites, so closing a gap cannot shrink its return target.
    struct Target: Equatable {
        let slots: FavoriteGridSlots
        let frame: CGRect
        let viewport: CGRect
        let count: Int

        func bounds(adding: Bool, holding: NewRow? = nil) -> CGRect {
            let edge = FavoriteTileLayout.gridHeaderSpacing
            let total = count + (adding ? 1 : 0)
            let projected = holding.map { slots.insertingRow($0, remaining: max(0, total - 1)) } ?? slots
            let grid = CGRect(origin: frame.origin, size: CGSize(width: frame.width, height: projected.height(for: total)))
            // A held boundary remains reachable if opening its row adds scroll padding. The viewport still limits the accepted margin.
            let margin = holding == nil ? edge : 2 * edge
            return grid.insetBy(dx: 0, dy: -margin).intersection(viewport.insetBy(dx: 0, dy: -edge))
        }

        func placement(at point: CGPoint, adding: Bool, holding: NewRow? = nil) -> Placement? {
            let total = count + (adding ? 1 : 0)
            guard total > 0, bounds(adding: adding, holding: holding).contains(point) else { return nil }
            if total > 1 {
                func boundary(_ edge: NewRow) -> Placement {
                    let expanded = slots.insertingRow(edge, remaining: total - 1)
                    let index = edge == .first ? 0 : total - 1
                    let tile = expanded.frames(for: total, width: frame.width, origin: frame.origin)[index]
                    return Placement(index: index, frame: tile, newRow: edge, rowSizes: expanded.rowSizes)
                }
                // Keep the boundary through the spacing and scroll padding added when the gap makes the grid scroll.
                if let holding {
                    let held = boundary(holding)
                    if held.frame.insetBy(dx: 0, dy: -(FavoriteTileLayout.spacing + FavoriteTileLayout.gridHeaderSpacing)).contains(point) { return held }
                }
                if point.y < frame.minY { return boundary(.first) }
                if point.y >= frame.minY + slots.height(for: count) { return boundary(.last) }
            }
            var sizes = slots.usedRowSizes(for: count)
            if adding, count > 0 {
                // Find the row before inserting the gap, then grow its saved capacity for the incoming tile.
                let occupied = slots.rows(for: count)
                let row = slots.row(at: point, count: count, origin: frame.origin)
                if occupied[row] < FavoriteTileLayout.choices.upperBound {
                    while sizes.count <= row { sizes.append(FavoriteTileLayout.columnCount(slots.defaultColumns)) }
                    sizes[row] = max(sizes[row], occupied[row] + 1)
                }
            }
            let expanded = FavoriteGridSlots(rowSizes: sizes, defaultColumns: slots.defaultColumns)
            let index = expanded.slot(at: point, count: total, width: frame.width, origin: frame.origin)
            return Placement(index: index, frame: expanded.frames(for: total, width: frame.width, origin: frame.origin)[index],
                             rowSizes: sizes == slots.rowSizes ? nil : sizes)
        }
    }

    /// A grid position while a drag may hold a gap open: a favorite's tile or the gap a dragged tab lands in.
    enum Entry: Hashable {
        case favorite(UUID)
        case gap
    }

    /// An entry and its collapsed state: a favorite dragged outside the grid keeps the view carrying its drag, without a slot.
    struct Item: Identifiable, Hashable {
        let entry: Entry
        var isCollapsed = false
        var id: Entry { entry }
    }

    /// The number of tiles in each row for `count` slots.
    func rows(for count: Int) -> [Int] {
        FavoriteTileLayout.counts(for: count, rowSizes: rowSizes, defaultColumns: defaultColumns)
    }

    /// The grid's height with `count` slots.
    func height(for count: Int) -> CGFloat {
        let rows = rows(for: count).count
        return CGFloat(rows) * FavoriteTileLayout.height + CGFloat(max(0, rows - 1)) * FavoriteTileLayout.spacing
    }

    /// The frames of `count` slots, row by row, in a grid of `width` whose top leading corner is at `origin`.
    func frames(for count: Int, width: CGFloat, origin: CGPoint) -> [CGRect] {
        let spacing = FavoriteTileLayout.spacing
        return rows(for: count).enumerated().flatMap { row, tiles in
            let tileWidth = Self.tileWidth(tiles, in: width)
            return (0..<tiles).map { column in
                CGRect(x: origin.x + CGFloat(column) * (tileWidth + spacing), y: origin.y + CGFloat(row) * (FavoriteTileLayout.height + spacing),
                       width: tileWidth, height: FavoriteTileLayout.height)
            }
        }
    }

    /// The slot inside the grid, in reading order. Spacing splits at its middle; `Target` handles new rows outside the grid.
    func slot(at point: CGPoint, count: Int, width: CGFloat, origin: CGPoint) -> Int {
        let rows = rows(for: count)
        guard !rows.isEmpty else { return 0 }
        if point.y < origin.y { return 0 }
        if point.y >= origin.y + height(for: count) { return count - 1 }
        let spacing = FavoriteTileLayout.spacing
        let row = row(at: point, count: count, origin: origin)
        let tileWidth = Self.tileWidth(rows[row], in: width)
        let column = Self.clamped(Int(((point.x - origin.x + spacing / 2) / (tileWidth + spacing)).rounded(.down)), below: rows[row])
        return rows.prefix(row).reduce(0, +) + column
    }

    private func row(at point: CGPoint, count: Int, origin: CGPoint) -> Int {
        Self.clamped(Int(((point.y - origin.y + FavoriteTileLayout.spacing / 2) / (FavoriteTileLayout.height + FavoriteTileLayout.spacing)).rounded(.down)), below: rows(for: count).count)
    }

    /// The grid's entries for `ids`, in order. `gap` indexes the favorites other than `dragged` and holds the dragged favorite's tile or a gap for a dragged tab. Without it, a dragged favorite collapses at the end, closing its place.
    static func items(_ ids: [UUID], dragged: UUID?, gap: Int?) -> [Item] {
        let isDragged = dragged.map(ids.contains) == true
        var items = ids.filter { !isDragged || $0 != dragged }.map { Item(entry: .favorite($0)) }
        let moving = isDragged ? dragged.map(Entry.favorite) : nil
        if let gap {
            items.insert(Item(entry: moving ?? .gap), at: min(max(0, gap), items.count))
        } else if let moving {
            items.append(Item(entry: moving, isCollapsed: true))
        }
        return items
    }

    private static func tileWidth(_ tiles: Int, in width: CGFloat) -> CGFloat {
        max(0, width - CGFloat(tiles - 1) * FavoriteTileLayout.spacing) / CGFloat(tiles)
    }

    private static func clamped(_ value: Int, below count: Int) -> Int {
        min(max(0, value), count - 1)
    }
}

/// Marks a collapsed tile of `FavoriteRows`, which takes no slot.
private struct FavoriteTileCollapsed: LayoutValueKey {
    static let defaultValue = false
}

/// Places tiles and the gap in their slots (`FavoriteGridSlots`), keeping each favorite in the same view as it crosses rows during a drag. A collapsed tile takes no slot and has zero size at the grid's corner.
struct FavoriteRows: Layout {
    let slots: FavoriteGridSlots

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? SidebarView.defaultWidth, height: slots.height(for: subviews.filter { !$0[FavoriteTileCollapsed.self] }.count))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = subviews.filter { !$0[FavoriteTileCollapsed.self] }
        for (subview, frame) in zip(placed, slots.frames(for: placed.count, width: bounds.width, origin: bounds.origin)) {
            subview.place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
        for subview in subviews where subview[FavoriteTileCollapsed.self] {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
    }
}

/// Shows the favorites that every space of the window's Persona shares as a grid of site icons. A favorite that has a tab of its own is marked as open, and clicking it selects that tab. Dragging a favorite or a tab that can become one over the grid opens a dimmed gap under the pointer. The other tiles reflow around it, as tab rows move aside; release puts the item there. A favorite dragged out of the grid closes its place until it returns. Holding Shift over a tile previews it.
struct FavoritesGridView: View {
    @ObservedObject var session: BrowserSession
    let personaID: Persona.ID
    /// The current space, whose tab rows can drop into this shared grid.
    let spaceID: UUID
    let viewport: CGRect
    let availableHeight: CGFloat
    @State private var gridViewport = CGRect.zero
    @AppStorage(FavoriteTileLayout.columnsKey) private var columns = FavoriteTileLayout.defaultColumns
    @AppStorage(FavoriteTileLayout.rowSizesKey) private var rowSizes = Data()
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    private var slots: FavoriteGridSlots {
        FavoriteGridSlots(rowSizes: FavoriteTileLayout.rowSizes(from: rowSizes), defaultColumns: columns)
    }

    /// The gap this grid holds open until release.
    private var gap: SidebarDragState.FavoriteGap? {
        guard let gap = sidebarDrag.favoriteGap, gap.spaceID == spaceID, !sidebarDrag.isSettling else { return nil }
        return gap
    }

    /// The dragged favorite until release.
    private var draggedFavoriteID: UUID? {
        guard case .favorite(let id) = sidebarDrag.item, !sidebarDrag.isSettling else { return nil }
        return id
    }

    var body: some View {
        let favorites = session.favorites(in: personaID)
        let byID = Dictionary(favorites.map { ($0.id, $0) }) { first, _ in first }
        let items = FavoriteGridSlots.items(favorites.map(\.id), dragged: draggedFavoriteID, gap: gap?.index)
        let layout = gap?.rowSizes.map { FavoriteGridSlots(rowSizes: $0, defaultColumns: columns) } ?? slots
        let height = layout.height(for: items.filter { !$0.isCollapsed }.count)
        let limit = max(FavoriteTileLayout.height, availableHeight / 2)
        let scrolls = height > limit
        let edge = scrolls ? FavoriteTileLayout.gridHeaderSpacing : 0
        // Keep the scroll view in place as rows grow or collapse, so the dragged tile keeps its gesture.
        ScrollView(.vertical) {
            FavoriteRows(slots: layout) {
                ForEach(items) { item in
                    switch item.entry {
                    case .favorite(let id):
                        if let favorite = byID[id] {
                            tile(favorite, selected: windowModel.selectedFavoriteID, collapsed: item.isCollapsed)
                                .layoutValue(key: FavoriteTileCollapsed.self, value: item.isCollapsed)
                                .transition(sidebarDrag.item == nil ? .scale(scale: 0) : .identity)
                        }
                    case .gap:
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
            }
            .background(GeometryReader { proxy in
                let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
                let visible = scrolls ? gridViewport.intersection(viewport) : viewport
                let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: visible, count: favorites.count)
                let acceptsDrops = !visible.isEmpty && !favorites.isEmpty
                Color.clear
                    .preference(key: FavoriteBarFramesKey.self, value: acceptsDrops ? [spaceID: target.bounds(adding: sidebarDrag.tabID != nil, holding: gap?.newRow)] : [:])
                    .onAppear { sidebarDrag.favoriteGridTargets[spaceID] = acceptsDrops ? target : nil }
                    .onChange(of: target) { sidebarDrag.favoriteGridTargets[spaceID] = $1.viewport.isEmpty || $1.count == 0 ? nil : $1 }
                    .onChange(of: spaceID) { old, new in
                        sidebarDrag.favoriteGridTargets[old] = nil
                        sidebarDrag.favoriteGridTargets[new] = acceptsDrops ? target : nil
                    }
            })
            // The visible ends leave room to target a new first or last row after scrolling there.
            .padding(.vertical, edge)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(!scrolls)
        .scrollClipDisabled(!scrolls)
        .frame(height: min(height + 2 * edge, limit))
        .animation(SidebarDragState.motion, value: favorites.map(\.id))
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
            Color.clear
                .onAppear { gridViewport = frame }
                .onChange(of: frame) { gridViewport = $1 }
        })
        .onDisappear { sidebarDrag.favoriteGridTargets[spaceID] = nil }
    }

    private func tile(_ favorite: Favorite, selected: Favorite.ID?, collapsed: Bool) -> some View {
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
                    Button(localized("Use Current Page as Saved Page")) {}.disabled(true)
                }
                Button(localized("Edit Favorite\u{2026}")) { windowModel.promptToEditFavorite(favorite) }
                Button(localized("Copy Address")) { Tab.copyToPasteboard(favorite.url) }
                Divider()
                Button(localized("Close Tab")) { session.closeFavorite(favorite) }
                    .disabled(!session.hasTab(favorite))
                Divider()
                Button(localized("Remove from Favorites")) { session.removeFavorite(favorite) }
            }
            .modifier(SidebarItemDrag(item: .favorite(favorite.id), cornerRadius: 10, showsSlot: !collapsed, release: { release(favorite) }) { updateGap(at: $0) })
            .modifier(ShiftHoverPreview { if sidebarDrag.item == nil { windowModel.previewFavorite(favorite) } })
            .frame(width: collapsed ? 0 : nil, height: collapsed ? 0 : nil)
            .accessibilityHidden(collapsed)
    }

    /// The dragged tile keeps its view while its slot opens, moves, or closes.
    private func updateGap(at point: CGPoint) {
        guard windowModel.currentSpaceID == spaceID, personaID == windowModel.personaID,
              case .favorite(let id) = sidebarDrag.item, let favorite = session.favorites(in: personaID).first(where: { $0.id == id }) else { return }
        sidebarDrag.liftedFavorite = favorite
        sidebarDrag.liftedTab = session.favoriteTabs[id]
        sidebarDrag.favoriteRowWidth = sidebarDrag.favoriteGridTargets[spaceID]?.frame.width ?? sidebarDrag.favoriteRowWidth
        let overTabs = sidebarDrag.favoriteTabTargets[spaceID]?.list.contains(point) == true
        sidebarDrag.updateFavoriteGap(in: overTabs ? nil : spaceID, at: point, adding: false)
        sidebarDrag.targetFavoriteSpaceID = sidebarDrag.favoriteGap?.spaceID
        sidebarDrag.updateFavoriteTabDrop(in: spaceID, at: point, session: session)
    }

    /// On release, a favorite takes the tab list's slot or the grid's gap. Elsewhere it returns to its original place.
    private func release(_ favorite: Favorite) -> CGRect? {
        let favorites = session.favorites(in: personaID)
        guard sidebarDrag.item == .favorite(favorite.id), let original = favorites.firstIndex(where: { $0.id == favorite.id }) else { return nil }
        if let frame = sidebarDrag.dropFavoriteIntoTabs(favorite, session: session) { return frame }
        let destination = gap
        let index = destination?.index ?? original
        withAnimation(SidebarDragState.motion) {
            if index != original { session.moveFavorite(favorite.id, toIndex: index) }
            if let sizes = destination?.rowSizes { rowSizes = FavoriteTileLayout.encode(rowSizes: sizes) }
        }
        guard let target = sidebarDrag.favoriteGridTargets[spaceID] else { return nil }
        let committedSlots = destination?.rowSizes.map { FavoriteGridSlots(rowSizes: $0, defaultColumns: columns) } ?? slots
        let frames = committedSlots.frames(for: favorites.count, width: target.frame.width, origin: target.frame.origin)
        return frames.indices.contains(index) ? frames[index] : nil
    }
}

/// A favorite tile's Go Back to Saved Page and Use Current Page as Saved Page, which follow the favorite's open tab: the grid redraws with the window's selected tab and the session's lists, so a page change in the tab while another tab is selected would otherwise leave them as they were.
private struct FavoriteTabSavedPageItems: View {
    @ObservedObject var tab: Tab
    @ObservedObject var session: BrowserSession

    var body: some View {
        if session.isOffSavedPage(tab) {
            Button(localized("Go Back to Saved Page")) { session.goBackToSavedPage(tab) }
        }
        Button(localized("Use Current Page as Saved Page")) { session.useCurrentPageAsSavedPage(tab) }
            .disabled(!session.canUseCurrentPageAsSavedPage(tab))
    }
}

/// One favorite's tile in `FavoritesGridView`, also drawn as the drag preview: its icon, dimmed while unopened, its selected fill, and the prompt mark.
struct FavoriteTileView: View {
    let favorite: Favorite
    /// Set while the favorite's tab is selected.
    let isActive: Bool
    /// Set while the favorite's page is open. An unopened favorite's icon is dimmed.
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
                        .frame(width: FavoriteTileLayout.iconSize, height: FavoriteTileLayout.iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .opacity(isOpen ? 1 : SidebarDimming.unopened)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(isOpen ? 1 : SidebarDimming.unopened)
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isOpen)
            // The favorite's tab waits for the user's answer to a prompt. The mark sits on the tile's corner, as the Library button's count does, clear of the icon even in the narrowest sidebar.
            .overlay(alignment: .topTrailing) {
                TabPromptIndicator(prompts: prompts, tabID: tabID)
                    .offset(x: 3, y: -2)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(favorite.title)
            // One element for VoiceOver, whose value says whether its page is open and whether a prompt waits.
            .accessibilityElement()
            .accessibilityLabel(favorite.title)
            .accessibilityValue([isOpen ? localized("Open") : nil, prompts.hasPrompt(for: tabID) ? localized("Waiting for your answer") : nil].compactMap { $0 }.joined(separator: ", "))
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
