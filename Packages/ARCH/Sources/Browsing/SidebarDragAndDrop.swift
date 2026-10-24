// Drag and drop in the sidebar. Favorites and space symbols lift into the window's drag layer as tab rows do, and dragging one over another moves it to that place. A tab released over another space's symbol moves to that space, and one released over a folder's row joins that folder. Links, addresses, and files that other apps drop onto the tab list open in new tabs.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a drag in the sidebar lifts.
enum SidebarDragItem: Equatable {
    case tab(UUID)
    case favorite(UUID)
    case space(UUID)

    var id: UUID {
        switch self {
        case .tab(let id), .favorite(let id), .space(let id): return id
        }
    }
}

extension TabDragState {
    /// How long the lifted item's shadow and the slot's dimming take to appear and disappear, as for tab rows.
    static let liftDuration = 0.4

    /// The space whose symbol is at `point` in the window. Only symbols in the strip's visible part count.
    func space(at point: CGPoint) -> UUID? {
        // Some slack above and below makes the small symbols easier to hit.
        guard spaceStripFrame.insetBy(dx: 0, dy: -6).contains(point) else { return nil }
        return spaceSymbolFrames.first { $0.value.insetBy(dx: -1, dy: -6).contains(point) }?.key
    }

    /// On release, the lifted item returns to its slot, and its shadow fades out before the item reappears there.
    func settle(into slot: CGRect, ownedBy owner: UUID) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isSettling = true
            frame = slot
        }
        withAnimation(.easeInOut(duration: Self.liftDuration)) { isLifted = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftDuration) { self.end(ownedBy: owner) }
    }

    /// A tab released over a space's symbol shrinks into it while the symbol's highlight fades.
    func settle(intoSpace spaceID: UUID, ownedBy owner: UUID) {
        settle(shrinkingInto: spaceSymbolFrames[spaceID] ?? frame, ownedBy: owner)
    }

    /// A tab released over a drop target, such as a folder's row, shrinks into the target's frame while its highlight fades.
    func settle(shrinkingInto target: CGRect, ownedBy owner: UUID) {
        withAnimation(.easeIn(duration: 0.25)) {
            isSettling = true
            isEntering = true
            targetSpaceID = nil
            targetFolderID = nil
            frame.origin = CGPoint(x: target.midX - frame.width / 2, y: target.midY - frame.height / 2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.end(ownedBy: owner) }
    }
}

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
    @EnvironmentObject private var tabDrag: TabDragState
    /// Set during the drag gesture. Resets automatically if the gesture is cancelled, such as when the item disappears.
    @GestureState private var isGestureActive = false
    /// The item's frame in the window.
    @State private var frame: CGRect?
    /// Identifies this item as the owner of a drag it started.
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        let isDragged = tabDrag.item == item
        content
            .opacity(isDragged ? 0 : 1)
            .background {
                if isDragged {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(tabDrag.isLifted ? 0.06 : 0))
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
                    if !isGestureActive, !tabDrag.isSettling { tabDrag.end(ownedBy: owner) }
                }
            }
            .onDisappear { tabDrag.end(ownedBy: owner) }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        guard !tabDrag.isSettling, tabDrag.item == nil || (tabDrag.item == item && tabDrag.owner == owner), let frame else { return }
        if tabDrag.item == nil {
            tabDrag.begin(item, frame: frame, grabbedAt: value.startLocation, owner: owner)
            // The item appears without a shadow, which then fades in.
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: TabDragState.liftDuration)) { tabDrag.isLifted = true } }
        }
        tabDrag.move(to: value.location)
        reorder(value.location)
    }

    private func dragEnded() {
        guard tabDrag.owner == owner, let frame else { return tabDrag.end(ownedBy: owner) }
        tabDrag.settle(into: frame, ownedBy: owner)
    }
}

/// Draws a lifted favorite or space symbol at the pointer, above the sidebar and the page. `TabDragLayer` draws lifted tabs.
struct SidebarItemDragLayer: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tabDrag: TabDragState
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        if tabDrag.item != nil, tabDrag.tabID == nil {
            liftedItem
                .shadow(color: .black.opacity(tabDrag.isLifted ? 0.18 : 0), radius: 5, y: 2)
                .frame(width: tabDrag.frame.width, height: tabDrag.frame.height)
                .offset(x: tabDrag.frame.minX, y: tabDrag.frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // Over the page the item needs a backing of its own.
    @ViewBuilder private var liftedItem: some View {
        switch tabDrag.item {
        case .favorite(let id):
            if let favorite = session.favorites.first(where: { $0.id == id }) {
                FavoriteTileView(favorite: favorite, isActive: favorite.id == session.selectedFavoriteID, isOpen: session.hasTab(favorite))
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.regularMaterial).opacity(tabDrag.isLifted ? 1 : 0))
            }
        case .space(let id):
            if let space = session.spaces.first(where: { $0.id == id }) {
                Image(systemName: space.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.symbolColor(for: space.tint))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.regularMaterial).opacity(tabDrag.isLifted ? 1 : 0))
            }
        case .tab, nil:
            EmptyView()
        }
    }
}

/// Opens links, addresses, and files that other apps drop here in new tabs of the current space, in the default engine. A ring aligned with the tab rows shows while a drop can land.
struct SidebarDropTarget: ViewModifier {
    /// Links and files, and text that may be an address.
    static let types: [UTType] = [.url, .plainText]
    /// The schemes a dropped address may have; others, such as `mailto:`, belong to other apps.
    private static let schemes: Set<String> = ["http", "https", "file"]

    let session: BrowserSession
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2))
                        .padding(.horizontal, SidebarView.inset)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: Self.types, isTargeted: $isTargeted) { providers in
                Self.loadURLs(from: providers) { urls in urls.forEach { session.openTab(url: $0) } }
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
