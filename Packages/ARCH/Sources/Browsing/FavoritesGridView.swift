// The favorites grid below the address pill: one tile per favorite of the window's Persona, which opens or selects the favorite's tab, previews it, or moves among the others.
import AppKit
import ARCHEngine
import SwiftUI

/// The favorites grid's saved tile counts and metrics. Each row shares its width among its favorites; automatic additions use the column count from Settings ▸ Sidebar.
public enum FavoriteTileLayout {
    public static let columnsKey = "ARCHFavoriteColumns"
    /// Read only when migrating snapshots that predate per-Persona layouts.
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
        return stored.filter { $0 > 0 }.map(columnCount)
    }

    public static func encode(rowSizes: [Int]) -> Data {
        (try? JSONEncoder().encode(rowSizes.filter { $0 > 0 }.map(columnCount))) ?? Data()
    }

    /// Repairs a layout against its favorites, keeping occupied rows and filling the last row before adding more.
    public static func normalizedRows(for favorites: Int, rowSizes: [Int], defaultColumns: Int) -> [Int] {
        var remaining = max(0, favorites)
        var rows: [Int] = []
        for size in rowSizes where size > 0 && remaining > 0 {
            let count = min(remaining, columnCount(size))
            rows.append(count)
            remaining -= count
        }
        if remaining > 0, let last = rows.indices.last {
            let added = min(remaining, choices.upperBound - rows[last])
            rows[last] += added
            remaining -= added
        }
        while remaining > 0 {
            let count = min(remaining, columnCount(defaultColumns))
            rows.append(count)
            remaining -= count
        }
        return rows
    }

    /// Expands the row capacities edited in Settings into actual tile counts.
    public static func counts(for favorites: Int, rowSizes: [Int], defaultColumns: Int) -> [Int] {
        var remaining = favorites
        var counts: [Int] = []
        let rowSizes = rowSizes.filter { $0 > 0 }.map(columnCount)
        while remaining > 0 {
            let row = counts.count
            let size = row < rowSizes.count ? rowSizes[row] : defaultColumns
            let count = min(remaining, columnCount(size))
            counts.append(count)
            remaining -= count
        }
        return counts
    }
}

/// The favorites grid's slots, laid out by row count. A drag changes only its source and destination rows, keeping equal widths within each row.
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

    /// Removing a tile changes only its own row; an empty row disappears.
    func removing(at index: Int, count: Int) -> FavoriteGridSlots {
        var sizes = rows(for: count)
        if let row = row(containing: index, sizes: sizes) { sizes[row] -= 1 }
        return FavoriteGridSlots(rowSizes: sizes.filter { $0 > 0 }, defaultColumns: defaultColumns)
    }

    /// Commands append to the last row until it reaches the configured column count.
    func appending(_ additions: Int, count: Int) -> FavoriteGridSlots {
        var sizes = rows(for: count)
        for _ in 0..<max(0, additions) {
            if let last = sizes.indices.last, sizes[last] < FavoriteTileLayout.columnCount(defaultColumns) {
                sizes[last] += 1
            } else {
                sizes.append(1)
            }
        }
        return FavoriteGridSlots(rowSizes: sizes, defaultColumns: defaultColumns)
    }

    /// A boundary drop gives the item its own row without changing any occupied row.
    func insertingRow(_ edge: NewRow, remaining: Int) -> FavoriteGridSlots {
        let occupied = rows(for: remaining)
        let sizes = edge == .first ? [1] + occupied : occupied + [1]
        return FavoriteGridSlots(rowSizes: sizes, defaultColumns: defaultColumns)
    }

    private func row(containing index: Int, sizes: [Int]) -> Int? {
        guard index >= 0 else { return nil }
        var end = 0
        return sizes.indices.first { end += sizes[$0]; return index < end }
    }

    /// Drop geometry based on the saved favorites, so closing a gap cannot shrink its return target.
    struct Target: Equatable {
        let slots: FavoriteGridSlots
        let frame: CGRect
        let viewport: CGRect
        let count: Int
        var favoriteIDs: [UUID] = []
        /// Original row indexes in displayed order; nil marks a row containing only the gap.
        var displayedRows: [Int?]? = nil
        var displayedGap: Placement? = nil

        func bounds(adding: Bool, holding: NewRow? = nil, sourceIndex: Int? = nil) -> CGRect {
            let edge = FavoriteTileLayout.gridHeaderSpacing
            let total = count + (adding ? 1 : 0)
            let remaining = adding ? slots : slots.removing(at: sourceIndex ?? count - 1, count: count)
            let projected = holding.map { remaining.insertingRow($0, remaining: max(0, total - 1)) } ?? slots
            let rows = max(projected.rows(for: total).count, displayedRows?.count ?? 0)
            let height = CGFloat(rows) * FavoriteTileLayout.height + CGFloat(max(0, rows - 1)) * FavoriteTileLayout.spacing
            let grid = CGRect(origin: frame.origin, size: CGSize(width: frame.width, height: height))
            // A held boundary remains reachable if opening its row adds scroll padding. The viewport still limits the accepted margin.
            let margin = holding == nil ? edge : 2 * edge
            return grid.insetBy(dx: 0, dy: -margin).intersection(viewport.insetBy(dx: 0, dy: -edge))
        }

        func placement(at point: CGPoint, adding: Bool, holding: NewRow? = nil, sourceIndex: Int? = nil) -> Placement? {
            let total = count + (adding ? 1 : 0)
            guard total > 0, bounds(adding: adding, holding: holding, sourceIndex: sourceIndex).contains(point) else { return nil }
            if total > 1 {
                func boundary(_ edge: NewRow) -> Placement {
                    let remaining = adding ? slots : slots.removing(at: sourceIndex ?? count - 1, count: count)
                    let expanded = remaining.insertingRow(edge, remaining: total - 1)
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
                let rowCount = displayedRows?.count ?? slots.rows(for: count).count
                let displayedHeight = CGFloat(rowCount) * FavoriteTileLayout.height + CGFloat(max(0, rowCount - 1)) * FavoriteTileLayout.spacing
                if point.y >= frame.minY + displayedHeight { return boundary(.last) }
            }
            var sizes = slots.rows(for: count)
            var index: Int?
            if count == 0 {
                sizes = [1]
            } else if adding || sourceIndex != nil {
                // Resolve both rows before removing the source, so an emptied row cannot change the target.
                var row = slots.row(at: point, count: count, origin: frame.origin)
                if let displayedRows, !displayedRows.isEmpty {
                    let visibleRow = FavoriteGridSlots.clamped(Int(((point.y - frame.minY + FavoriteTileLayout.spacing / 2) / (FavoriteTileLayout.height + FavoriteTileLayout.spacing)).rounded(.down)), below: displayedRows.count)
                    if let original = displayedRows[visibleRow] {
                        row = original
                    } else if let gap = displayedGap {
                        let projected = FavoriteGridSlots(rowSizes: gap.rowSizes ?? sizes, defaultColumns: slots.defaultColumns)
                        // Match the rendered items when another window or sync removes a favorite during the drag.
                        let index = FavoriteGridSlots.clamped(gap.index, below: total)
                        return Placement(index: index, frame: projected.frames(for: total, width: frame.width, origin: frame.origin)[index], newRow: gap.newRow, rowSizes: gap.rowSizes)
                    }
                }
                if !adding, let sourceIndex, let source = slots.row(containing: sourceIndex, sizes: sizes) {
                    sizes[source] -= 1
                }
                if sizes[row] < FavoriteTileLayout.choices.upperBound {
                    sizes[row] += 1
                } else {
                    row += 1
                    sizes.insert(1, at: row)
                }
                let tileWidth = FavoriteGridSlots.tileWidth(sizes[row], in: frame.width)
                let column = FavoriteGridSlots.clamped(Int(((point.x - frame.minX + FavoriteTileLayout.spacing / 2) / (tileWidth + FavoriteTileLayout.spacing)).rounded(.down)), below: sizes[row])
                index = sizes.prefix(row).reduce(0, +) + column
                sizes.removeAll { $0 == 0 }
            }
            let expanded = FavoriteGridSlots(rowSizes: sizes, defaultColumns: slots.defaultColumns)
            let destination = index ?? expanded.slot(at: point, count: total, width: frame.width, origin: frame.origin)
            return Placement(index: destination, frame: expanded.frames(for: total, width: frame.width, origin: frame.origin)[destination],
                             rowSizes: adding || sourceIndex != nil || sizes != slots.rowSizes ? sizes : nil)
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
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    private var slots: FavoriteGridSlots {
        FavoriteGridSlots(rowSizes: session.favoriteRows(in: personaID), defaultColumns: columns)
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
        let sourceIndex = draggedFavoriteID.flatMap { id in favorites.firstIndex { $0.id == id } }
        let withoutSource = sourceIndex.map { slots.removing(at: $0, count: favorites.count) } ?? slots
        let layout = gap.map { FavoriteGridSlots(rowSizes: $0.rowSizes ?? slots.rows(for: favorites.count), defaultColumns: columns) } ?? withoutSource
        let originalRows = slots.rows(for: favorites.count).enumerated().flatMap { row, count in Array(repeating: row, count: count) }
        let rowByID = Dictionary(zip(favorites.map(\.id), originalRows)) { first, _ in first }
        let visibleItems = items.filter { !$0.isCollapsed }
        let displayedRows = rowOrigins(of: visibleItems, layout: layout, rowByID: rowByID)
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
                let target = FavoriteGridSlots.Target(slots: slots, frame: frame, viewport: visible, count: favorites.count, favoriteIDs: favorites.map(\.id),
                                                      displayedRows: displayedRows, displayedGap: gap.map {
                    FavoriteGridSlots.Placement(index: $0.index, frame: $0.frame, newRow: $0.newRow, rowSizes: layout.rows(for: visibleItems.count))
                })
                let acceptsDrops = !visible.isEmpty && !favorites.isEmpty
                Color.clear
                    .preference(key: FavoriteBarFramesKey.self, value: acceptsDrops ? [spaceID: target.bounds(adding: sidebarDrag.tabID != nil, holding: gap?.newRow, sourceIndex: sourceIndex)] : [:])
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

    /// A row follows its remaining favorites when removing a source row or inserting a gap shifts it.
    private func rowOrigins(of items: [FavoriteGridSlots.Item], layout: FavoriteGridSlots, rowByID: [UUID: Int]) -> [Int?] {
        var start = 0
        return layout.rows(for: items.count).map { count in
            defer { start += count }
            return items[start..<(start + count)].compactMap { item -> Int? in
                guard case .favorite(let id) = item.entry, id != draggedFavoriteID else { return nil }
                return rowByID[id]
            }.first
        }
    }

    private func tile(_ favorite: Favorite, selected: Favorite.ID?, collapsed: Bool) -> some View {
        FavoriteTileView(favorite: favorite, isActive: favorite.id == selected, isOpen: session.hasOpenPage(favorite),
                         prompts: session.prompts, tab: session.favoriteTabs[favorite.id],
                         storedIcon: session.siteIcons.icon(for: favorite.url, in: personaID))
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
            .modifier(SidebarItemDrag(item: .favorite(favorite.id), cornerRadius: 10, showsSlot: !collapsed, release: {
                sidebarDrag.dropFavoriteTile(favorite, in: spaceID, session: session)
            }) { updateGap(at: $0) })
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
    /// The waveform observes the open tab independently of the grid's session updates.
    let tab: Tab?
    /// The icon a page of the favorite's site showed before (`SiteIconStore`), used before any download.
    var storedIcon: NSImage?
    private var tabID: UUID? { tab?.id }
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
                if let tab {
                    TabPlaybackWaveform(tab: tab)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            // Without a measured spectrum, notes rise from behind the icon instead, kept inside the tile.
            .overlay {
                if let tab {
                    TabPlaybackNotes(tab: tab, cornerRadius: 10)
                }
            }
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
        let url = favorite.url
        iconURL = url
        if let storedIcon {
            icon = storedIcon
            return
        }
        FaviconLoader.loadPageIcon(for: url) { image in
            if iconURL == url { icon = image }
        }
    }
}
