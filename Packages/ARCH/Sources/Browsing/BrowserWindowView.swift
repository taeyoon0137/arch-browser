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
            }
            WebContentsHostView(contentView: session.selectedTab?.webContents.view)
                .padding(EdgeInsets(top: 8, leading: session.isSidebarVisible ? 0 : 8, bottom: 8, trailing: 8))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 500)
    }
}

struct SidebarView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Leave space for the window buttons because the sidebar extends under the title bar.
            Color.clear.frame(height: 28)
            if let tab = session.selectedTab {
                SelectedTabHeaderView(session: session, tab: tab)
            } else {
                Button(action: session.toggleSidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            List(selection: $session.selectedTabID) {
                ForEach(session.tabs) { tab in
                    TabRowView(tab: tab) { session.closeTab(tab) }
                        .tag(tab.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Button {
                session.openTab()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
    }
}

// Observes the selected tab directly so the controls reflect navigation within the page.
struct SelectedTabHeaderView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button(action: session.toggleSidebar) { Image(systemName: "sidebar.left") }
            Spacer()
            Button(action: session.goBack) { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Button(action: session.goForward) { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Button(action: session.reload) { Image(systemName: "arrow.clockwise") }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        HStack(spacing: 6) {
            Image(systemName: tab.isLoading ? "arrow.triangle.2.circlepath" : "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { session.navigate(to: text) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
        .onChange(of: tab.url) { url in text = url?.absoluteString ?? "" }
        .onChange(of: session.commandBarFocusRequest) { _ in isFocused = true }
        .onAppear { text = tab.url?.absoluteString ?? "" }
    }
}

struct TabRowView: View {
    @ObservedObject var tab: Tab
    let close: () -> Void

    var body: some View {
        HStack {
            Image(systemName: tab.isLoading ? "arrow.triangle.2.circlepath" : "globe")
                .foregroundStyle(.secondary)
            Text(tab.displayTitle)
                .lineLimit(1)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
