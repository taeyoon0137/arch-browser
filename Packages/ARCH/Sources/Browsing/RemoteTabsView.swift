// Read-only rows below the space's pinned items. Icons use the cookie-free shared loader.
import ARCHEngine
import SwiftUI

struct RemoteTabsFolders: View {
    @ObservedObject var session: BrowserSession
    let space: Space

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ForEach(session.remoteTabs(in: space, now: context.date)) { group in
                RemoteTabsFolderView(session: session, group: group)
            }
        }
    }
}

private struct RemoteTabsFolderView: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    let group: RemoteTabGroup
    @State private var isHovering = false

    private var isCollapsed: Bool { session.collapsedRemoteTabGroupIDs.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: SpaceTabsView.rowSpacing) {
            Button(action: toggleCollapsed) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(group.title).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovering && !isDraggingTab ? SidebarFill.hover.color(in: colorScheme) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.title)
            .onHover { isHovering = $0 }
            .contextMenu {
                Button(RemoteTabsStrings.hideTabs) { session.showRemoteTabs = false }
            }
            .accessibilityValue(isCollapsed ? localized("Collapsed") : localized("Expanded"))
            if !isCollapsed {
                ForEach(Array(group.orderedTabs.enumerated()), id: \.offset) { _, tab in
                    RemoteTabRow(tab: tab) {
                        if let opened = session.openRemoteTab(tab, from: group, select: false) {
                            windowModel.selectTab(opened.id)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .padding(.bottom, SpaceTabsView.rowSpacing)
    }

    private func toggleCollapsed() {
        guard !isDraggingTab else { return }
        withAnimation(.easeInOut(duration: 0.2)) { session.toggleRemoteTabsCollapsed(group) }
    }
}

private struct RemoteTabRow: View {
    let tab: RemoteTab
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isDraggingTab) private var isDraggingTab
    @State private var isHovering = false
    @State private var icon: NSImage?
    @State private var iconURL: URL?

    private var title: String { tab.title.isEmpty ? tab.url.host ?? tab.url.absoluteString : tab.title }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "globe").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                Text(title).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .opacity(SidebarDimming.unopened)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering && !isDraggingTab ? SidebarFill.hover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title + "\n" + tab.url.absoluteString)
        .onHover { isHovering = $0 }
        .onAppear(perform: loadIcon)
        .onChange(of: tab.url) { loadIcon() }
    }

    private func loadIcon() {
        let url = FaviconLoader.defaultIconURL(for: tab.url)
        guard url != iconURL else { return }
        iconURL = url
        icon = nil
        guard let url else { return }
        FaviconLoader.load(url) { loaded in
            if iconURL == url { icon = loaded }
        }
    }
}

struct RemoteTabsToggle: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        Toggle(RemoteTabsStrings.showTabs, isOn: $session.showRemoteTabs)
            .disabled(!session.isSyncing)
    }
}
