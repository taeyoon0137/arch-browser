// Main window content. The system's translucent window material fills the window with a faint wash of the current space's tint. The sidebar sits over it and contains navigation, the address field, favorites, the current space's tabs, and the space switcher. The page fills the remaining space with nothing above it.
import AppKit
import ARCHEngine
import SwiftUI

public struct BrowserWindowView: View {
    @ObservedObject var session: BrowserSession

    public init(session: BrowserSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if session.isSidebarVisible {
                    SidebarView(session: session)
                        .frame(width: 250)
                }
                // When the sidebar is hidden, the page starts below the window buttons.
                WebContentsHostView(contentView: session.selectedTab?.webContents.view)
                    .background(PageFrameShape().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.12), radius: 2, y: 1))
                    .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
                    .padding(EdgeInsets(top: session.isSidebarVisible ? 8 : 38, leading: session.isSidebarVisible ? 0 : 8, bottom: 8, trailing: 8))
            }
            if session.isFindBarVisible {
                FindBarView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 20)
                    .padding(.trailing, 24)
            }
            if let mode = session.commandPaletteMode {
                // Give each mode its own view identity to reset the typed text and initial address.
                CommandPaletteView(session: session, mode: mode)
                    .id(mode)
            }
        }
        .background(SpaceBackgroundView(tint: session.currentSpace.tint.color))
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 500)
    }
}

/// The rounded frame of the page. `WebContentsHostView` clips the engine's view with the same radius.
struct PageFrameShape: InsettableShape {
    static let cornerRadius: CGFloat = 8
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: Self.cornerRadius - insetAmount, style: .continuous).path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> PageFrameShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Shows the system's translucent window material, the one Apple's own sidebars use, under a faint wash of the space's tint.
struct SpaceBackgroundView: View {
    let tint: Color

    var body: some View {
        ZStack {
            WindowMaterialView()
            LinearGradient(colors: [tint.opacity(0.08), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .animation(.easeInOut(duration: 0.25), value: tint)
    }
}

/// Blends with what lies behind the window and turns opaque while the window is inactive, as the system's sidebars do.
struct WindowMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Translucent fills for sidebar controls. They lighten the window material in both appearances instead of covering it with an opaque color.
enum SidebarFill {
    case field, hover, selected

    func color(in scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.field, .dark): return .white.opacity(0.07)
        case (.field, _): return .black.opacity(0.05)
        case (.hover, .dark): return .white.opacity(0.05)
        case (.hover, _): return .black.opacity(0.04)
        case (.selected, .dark): return .white.opacity(0.13)
        case (.selected, _): return .white.opacity(0.8)
        }
    }
}

extension SpaceTint {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .green: return .green
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}

struct SidebarView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Leave space for the window buttons because the sidebar extends under the title bar.
            Color.clear.frame(height: 30)
            if let tab = session.selectedTab {
                SelectedTabHeaderView(session: session, tab: tab)
            } else {
                SidebarIconButton(symbol: "sidebar.left", label: "Hide Sidebar", action: session.toggleSidebar)
            }
            if !session.favorites.isEmpty {
                FavoritesGridView(session: session)
                    .padding(.top, 6)
            }
            SpaceTabsView(session: session)
                .padding(.top, 6)
            Spacer(minLength: 0)
            SpaceSwitcherView(session: session)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

// Observes the selected tab directly so the controls reflect navigation within the page.
struct SelectedTabHeaderView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 4) {
            SidebarIconButton(symbol: "sidebar.left", label: "Hide Sidebar", action: session.toggleSidebar)
            Spacer()
            SidebarIconButton(symbol: "chevron.left", label: "Back", action: session.goBack).disabled(!tab.canGoBack)
            SidebarIconButton(symbol: "chevron.right", label: "Forward", action: session.goForward).disabled(!tab.canGoForward)
            if tab.isLoading {
                SidebarIconButton(symbol: "xmark", label: "Stop Loading", action: session.stopLoading)
            } else {
                SidebarIconButton(symbol: "arrow.clockwise", label: "Reload", action: session.reload)
            }
        }
        AddressPillView(session: session, tab: tab)
    }
}

/// A borderless symbol button that shows a soft highlight under the pointer. `label` names it in its tooltip and for VoiceOver.
struct SidebarIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Shows the site's host. Clicking it opens the command palette with the full address.
struct AddressPillView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @Environment(\.colorScheme) private var colorScheme

    private var host: String {
        guard let host = tab.url?.host else { return "Search or enter address" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(host)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tab.url == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SidebarFill.field.color(in: colorScheme)))
        .contentShape(Rectangle())
        .onTapGesture { session.showCommandPalette(.editCurrent) }
        .help(tab.url?.absoluteString ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Shows favorites as a grid of site icons. All spaces share the same favorites.
struct FavoritesGridView: View {
    @ObservedObject var session: BrowserSession
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(session.favorites) { favorite in
                FavoriteTileView(favorite: favorite, isActive: session.selectedTab?.url?.host == favorite.url.host)
                    .onTapGesture { session.openFavorite(favorite) }
                    .contextMenu {
                        Button("Remove from Favorites") { session.removeFavorite(favorite) }
                    }
            }
        }
    }
}

struct FavoriteTileView: View {
    let favorite: Favorite
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var icon: NSImage?
    @State private var isHovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill((isActive ? SidebarFill.selected : SidebarFill.field).color(in: colorScheme))
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SidebarFill.hover.color(in: colorScheme).opacity(isHovering && !isActive ? 1 : 0)))
            .aspectRatio(1.5, contentMode: .fit)
            .overlay {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(favorite.title)
            .accessibilityElement()
            .accessibilityLabel(favorite.title)
            .accessibilityAddTraits(.isButton)
            .onAppear {
                guard icon == nil, let url = FaviconLoader.defaultIconURL(for: favorite.url) else { return }
                FaviconLoader.load(url) { icon = $0 }
            }
    }
}

/// Shows the current space's pinned tabs first, followed by the new tab row and the remaining tabs.
struct SpaceTabsView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        let space = session.currentSpace
        let pinned = session.tabs(in: space.id, pinned: true)
        let open = session.tabs(in: space.id, pinned: false)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: space.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(space.tint.color)
                    Text(space.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                ForEach(pinned) { tab in
                    TabRowView(session: session, tab: tab)
                }
                if !pinned.isEmpty {
                    Divider().padding(.vertical, 4).padding(.horizontal, 10)
                }
                NewTabButton(action: { session.showCommandPalette(.newTab) })
                ForEach(open) { tab in
                    TabRowView(session: session, tab: tab)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

struct TabRowView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var isSelected: Bool { tab.id == session.selectedTabID }

    private var fill: Color {
        if isSelected { return SidebarFill.selected.color(in: colorScheme) }
        return isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(tab: tab)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovering {
                TabCloseButton { session.closeTab(tab) }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill))
        // Only the light appearance lifts the selected row; in the dark one its lighter fill is enough.
        .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.08 : 0), radius: 1.5, y: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTabID = tab.id }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePinned(tab) }
            Button("Add to Favorites") { session.addFavorite(tab) }.disabled(tab.url == nil)
            Divider()
            Button("Close Tab") { session.closeTab(tab) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct TabCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
    }
}

struct TabIconView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct NewTabButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
    }
}

/// Shows one symbol per space at the bottom of the sidebar, plus buttons to open the downloads list and add a space.
struct SpaceSwitcherView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        HStack(spacing: 4) {
            ForEach(session.spaces) { space in
                let isCurrent = space.id == session.currentSpaceID
                Button(action: { session.switchToSpace(space.id) }) {
                    Image(systemName: space.symbol)
                        .font(.system(size: isCurrent ? 11 : 8))
                        .foregroundStyle(isCurrent ? space.tint.color : Color.secondary.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .accessibilityLabel(space.name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
            Spacer(minLength: 0)
            SidebarIconButton(symbol: session.downloads.contains(where: { $0.state == .inProgress }) ? "arrow.down.circle.fill" : "arrow.down.circle",
                              label: "Downloads", action: session.toggleDownloadsPopover)
                .popover(isPresented: $session.isDownloadsPopoverVisible, arrowEdge: .top) {
                    DownloadsListView(session: session)
                }
            SidebarIconButton(symbol: "plus", label: "New Space", action: session.addSpace)
        }
    }
}
