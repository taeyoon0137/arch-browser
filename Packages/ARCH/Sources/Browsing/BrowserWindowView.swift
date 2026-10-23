// Main window content. The sidebar contains navigation, the address field, and tabs. The page fills the remaining space with nothing above it.
import ARCHEngine
import SwiftUI

public struct BrowserWindowView: View {
    @ObservedObject var session: BrowserSession

    public init(session: BrowserSession) {
        self.session = session
    }

    public var body: some View {
        HStack(spacing: 0) {
            if session.isSidebarVisible {
                SidebarView(session: session)
                    .frame(width: 250)
                    .background(SidebarBackgroundView())
            }
            WebContentsHostView(contentView: session.selectedTab?.webContents.view)
                .padding(EdgeInsets(top: 8, leading: session.isSidebarVisible ? 0 : 8, bottom: 8, trailing: 8))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 500)
    }
}

/// Uses window-background vibrancy for the standard macOS sidebar appearance.
struct SidebarBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
            TabListView(session: session)
                .padding(.top, 10)
            Spacer(minLength: 0)
            NewTabButton(action: { session.openTab() })
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

/// Shows the site's host when not editing and the full address while editing.
struct AddressPillView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    private var host: String {
        tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "Search or enter address"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.isLoading ? "arrow.triangle.2.circlepath" : (tab.url?.scheme == "https" ? "lock.fill" : "globe"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if isEditing {
                TextField("Search or enter address", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        session.navigate(to: text)
                        isEditing = false
                    }
                    .onExitCommand { isEditing = false }
                    .onChange(of: isFocused) { focused in if !focused { isEditing = false } }
                    .onAppear { DispatchQueue.main.async { isFocused = true } }
            } else {
                Text(host)
                    .lineLimit(1)
                    .foregroundStyle(tab.url == nil ? .secondary : .primary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
        .onChange(of: session.commandBarFocusRequest) { _ in beginEditing() }
    }

    private func beginEditing() {
        text = tab.url?.absoluteString ?? ""
        isEditing = true
    }
}

struct TabListView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(session.tabs) { tab in
                    TabRowView(tab: tab, isSelected: tab.id == session.selectedTabID,
                               select: { session.selectedTabID = tab.id },
                               close: { session.closeTab(tab) })
                }
            }
        }
    }
}

struct TabRowView: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.isLoading ? "arrow.triangle.2.circlepath" : "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovering {
                Button(action: close) {
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
            .fill(isSelected ? Color(nsColor: .controlBackgroundColor).opacity(0.75) : (isHovering ? Color.primary.opacity(0.05) : Color.clear)))
        .shadow(color: .black.opacity(isSelected ? 0.06 : 0), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
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
