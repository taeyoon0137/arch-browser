// Main window content. The current space's tint fills the window. The sidebar sits over the tint and contains navigation, the address field, favorites, the current space's tabs, and the space switcher. The page fills the remaining space with nothing above it.
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
                    .padding(EdgeInsets(top: session.isSidebarVisible ? 8 : 38, leading: session.isSidebarVisible ? 0 : 8, bottom: 8, trailing: 8))
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

/// Uses a soft gradient of the space's tint over the window background to keep the interface legible in light and dark appearances.
struct SpaceBackgroundView: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .animation(.easeInOut(duration: 0.25), value: tint)
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
                SidebarIconButton(symbol: "sidebar.left", action: session.toggleSidebar)
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
            SidebarIconButton(symbol: "sidebar.left", action: session.toggleSidebar)
            Spacer()
            SidebarIconButton(symbol: "chevron.left", action: session.goBack).disabled(!tab.canGoBack)
            SidebarIconButton(symbol: "chevron.right", action: session.goForward).disabled(!tab.canGoForward)
            SidebarIconButton(symbol: "arrow.clockwise", action: session.reload)
        }
        AddressPillView(session: session, tab: tab)
    }
}

struct SidebarIconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Shows the site's host. Clicking it opens the command palette with the full address.
struct AddressPillView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab

    private var host: String {
        tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "Search or enter address"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.isLoading ? "arrow.triangle.2.circlepath" : (tab.url?.scheme == "https" ? "lock.fill" : "globe"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(host)
                .lineLimit(1)
                .foregroundStyle(tab.url == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.45)))
        .contentShape(Rectangle())
        .onTapGesture { session.showCommandPalette(.editCurrent) }
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
    @State private var icon: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(isActive ? 0.85 : 0.45))
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
            .help(favorite.title)
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
    }
}

struct TabRowView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @State private var isHovering = false

    private var isSelected: Bool { tab.id == session.selectedTabID }

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(tab: tab)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovering {
                Button(action: { session.closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color(nsColor: .controlBackgroundColor).opacity(0.85) : (isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.3) : Color.clear)))
        .shadow(color: .black.opacity(isSelected ? 0.06 : 0), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTabID = tab.id }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePinned(tab) }
            Button("Add to Favorites") { session.addFavorite(tab) }.disabled(tab.url == nil)
            Divider()
            Button("Close Tab") { session.closeTab(tab) }
        }
    }
}

struct TabIconView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isLoading {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Shows one symbol per space at the bottom of the sidebar, with a button to add a space.
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
            }
            Spacer(minLength: 0)
            SidebarIconButton(symbol: "plus", action: session.addSpace)
                .help("New Space")
        }
    }
}
