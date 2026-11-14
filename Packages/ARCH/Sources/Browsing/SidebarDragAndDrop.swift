// Drag and drop in the sidebar. Favorites and space symbols lift into the window's drag layer as tab rows do, and dragging one over another moves it to that place. A tab released over the symbol of another space of its Persona moves to that space, and one released over a folder's row joins that folder. Links, addresses, and files that other apps drop onto the tab list open in new tabs. The drag state that these drags share with tab rows is in `SidebarDragState.swift`.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Each draggable favorite's or space symbol's frame in the window.
struct SidebarItemFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Drags a favorite or space symbol as a tab row drags: the item lifts into the window's drag layer and follows the pointer, leaves a dimmed slot, and returns to the slot on release. `reorder` receives the pointer's position in the window while the item moves. The item reports its frame through `SidebarItemFramesKey`.
struct SidebarItemDrag: ViewModifier {
    let item: SidebarDragItem
    /// The corner radius of the slot's dimming.
    let cornerRadius: CGFloat
    let reorder: (CGPoint) -> Void
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    /// Set during the drag gesture. Resets automatically if the gesture is cancelled, such as when the item disappears.
    @GestureState private var isGestureActive = false
    /// The item's frame in the window.
    @State private var frame: CGRect?
    /// Identifies this item as the owner of a drag it started.
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        let isDragged = sidebarDrag.item == item
        content
            .opacity(isDragged ? 0 : 1)
            .background {
                if isDragged {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(sidebarDrag.isLifted ? 0.06 : 0))
                }
            }
            .background(GeometryReader { proxy in
                let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
                Color.clear
                    .preference(key: SidebarItemFramesKey.self, value: [item.id: frame])
                    .onAppear { self.frame = frame }
                    .onChange(of: frame) { self.frame = $1 }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BrowserWindowView.coordinateSpace))
                .updating($isGestureActive) { _, isActive, _ in isActive = true }
                .onChanged(dragChanged)
                .onEnded { _ in dragEnded() })
            // A cancelled gesture never reports its end. Drop the drag once the gesture is gone and nothing is settling.
            .onChange(of: isGestureActive) { _, isActive in
                guard !isActive else { return }
                DispatchQueue.main.async {
                    if !isGestureActive, !sidebarDrag.isSettling { sidebarDrag.end(ownedBy: owner) }
                }
            }
            .onDisappear { sidebarDrag.end(ownedBy: owner) }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        guard !sidebarDrag.isSettling, sidebarDrag.item == nil || (sidebarDrag.item == item && sidebarDrag.owner == owner), let frame else { return }
        if sidebarDrag.item == nil {
            sidebarDrag.begin(item, frame: frame, grabbedAt: value.startLocation, owner: owner)
            // The item appears without a shadow, which then fades in.
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: SidebarDragState.liftDuration)) { sidebarDrag.isLifted = true } }
        }
        sidebarDrag.move(to: value.location)
        reorder(value.location)
    }

    private func dragEnded() {
        guard sidebarDrag.owner == owner, let frame else { return sidebarDrag.end(ownedBy: owner) }
        sidebarDrag.settle(into: frame, ownedBy: owner)
    }
}

/// Draws a lifted favorite or space symbol at the pointer, above the sidebar and the page. `TabDragLayer` draws lifted tabs.
struct SidebarItemDragLayer: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject var sidebarDrag: SidebarDragState
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        if sidebarDrag.item != nil, sidebarDrag.tabID == nil {
            liftedItem
                .shadow(color: .black.opacity(sidebarDrag.isLifted ? 0.18 : 0), radius: 5, y: 2)
                .frame(width: sidebarDrag.frame.width, height: sidebarDrag.frame.height)
                .offset(x: sidebarDrag.frame.minX, y: sidebarDrag.frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // Over the page the item needs a backing of its own.
    @ViewBuilder private var liftedItem: some View {
        switch sidebarDrag.item {
        case .favorite(let id):
            if let favorite = session.favorites.first(where: { $0.id == id }) {
                FavoriteTileView(favorite: favorite, isActive: favorite.id == windowModel.selectedFavoriteID, isOpen: session.hasOpenPage(favorite))
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.regularMaterial).opacity(sidebarDrag.isLifted ? 1 : 0))
            }
        case .space(let id):
            // The symbol keeps the size and color it has in the strip, as a lifted favorite keeps its tile, so it does not jump on lift or when it settles back.
            if let space = session.spaces.first(where: { $0.id == id }) {
                let isCurrent = space.id == windowModel.currentSpaceID
                Image(systemName: space.symbol)
                    .font(.system(size: isCurrent ? 12 : 9))
                    .foregroundStyle(isCurrent ? theme.symbolColor(for: space.tint) : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.regularMaterial).opacity(sidebarDrag.isLifted ? 1 : 0))
            }
        case .tab, nil:
            EmptyView()
        }
    }
}

/// Opens links, addresses, and files that other apps drop here in new tabs of the window's current space, in the default engine. A ring aligned with the tab rows shows while a drop can land, in the color a folder row lights up in for a dragged tab.
struct SidebarDropTarget: ViewModifier {
    /// Links and files, and text that may be an address.
    static let types: [UTType] = [.url, .plainText]
    /// The schemes a dropped address may have; others, such as `mailto:`, belong to other apps.
    private static let schemes: Set<String> = ["http", "https", "file"]

    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.spaceTheme) private var theme
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    let color = theme.symbolColor(for: windowModel.currentSpace.tint)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.6), lineWidth: 2))
                        .padding(.horizontal, SidebarView.inset)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: Self.types, isTargeted: $isTargeted) { providers in
                Self.loadURLs(from: providers) { urls in urls.forEach { windowModel.openTab(url: $0) } }
                return true
            }
    }

    /// Reads each item as a link or file, or as text that is an address, and keeps the items' order. Text that is not an address is left out.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let results = DroppedURLs(count: providers.count)
        for (index, provider) in providers.enumerated() {
            let store = { (url: URL?) in
                DispatchQueue.main.async {
                    results.urls[index] = url
                    group.leave()
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in store(url) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: String.self) { text, _ in store(text.flatMap(BrowserSession.url(forInput:))) }
            }
        }
        group.notify(queue: .main) {
            completion(results.urls.compactMap { $0 }.filter { url in url.scheme.map { schemes.contains($0.lowercased()) } == true })
        }
    }
}

/// The dropped items' addresses, one slot per item, filled on the main thread.
private final class DroppedURLs {
    var urls: [URL?]

    init(count: Int) {
        urls = Array(repeating: nil, count: count)
    }
}
