// The Library's History tab uses the window's Persona and the downloads list's row styles.
import AppKit
import ARCHEngine
import History
import SwiftUI

struct LibraryHistoryView: View {
    @ObservedObject private var model: LibraryHistoryModel
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.sidebarIsFloating) private var isFloating
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentFrame = CGRect.zero
    @State private var listHeight: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
    private static let scrollSpace = "LibraryHistoryScroll"

    init(model: LibraryHistoryModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// The departing floating host must not overwrite the docked host's scroll position or take its focus.
    private var isActiveHost: Bool {
        model.persona == windowModel.personaID && windowModel.isLibraryVisible
            && windowModel.libraryTab == .history && !windowModel.isPageFullscreen
            && (isFloating ? !windowModel.isSidebarVisible : windowModel.isSidebarVisible)
    }

    private var scrollAnchor: Binding<URL?> {
        Binding(get: { model.scrollAnchor }, set: { id in
            if isActiveHost, model.scrollAnchor != id { model.scrollAnchor = id }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarView.rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                TextField(localized("Search History"), text: $model.query)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onExitCommand { isSearchFocused = false }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(SidebarFill.field.color(in: colorScheme)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.days) { day in
                        Text(day.title())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.entries) { entry in
                            LibraryHistoryRow(entry: entry, storedIcon: windowModel.session.siteIcons.icon(for: entry.url, in: model.persona),
                                              open: { background in open(entry, background: background) },
                                              openWindow: { openWindow(entry) }, delete: { model.delete(entry) })
                                .id(entry.id)
                        }
                    }
                    if model.hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .task(id: model.entries.count) {
                                // The shared model's read must survive removal of either sidebar host.
                                _ = Task { [model] in await model.loadNextPage() }
                            }
                    } else if model.entries.isEmpty {
                        Text(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localized("No History") : localized("No Results"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .scrollTargetLayout()
                .background(GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(Self.scrollSpace))
                    Color.clear
                        .onAppear { contentFrame = frame }
                        .onChange(of: frame) { contentFrame = $1 }
                })
            }
            .scrollPosition(id: scrollAnchor, anchor: .top)
            .scrollIndicators(.never)
            .coordinateSpace(name: Self.scrollSpace)
            .mask(ScrollEdgeFade(hiddenAbove: -contentFrame.minY, hiddenBelow: contentFrame.maxY - listHeight))
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { listHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { listHeight = $1 }
            })
            LibraryToolRow(symbol: "trash", title: localized("Clear History…"), action: confirmClear)
        }
        .onChange(of: windowModel.isLibraryVisible) { _, isVisible in
            if !isVisible { isSearchFocused = false }
        }
        .onChange(of: isActiveHost) { _, isActive in
            if !isActive { isSearchFocused = false }
        }
        .onChange(of: windowModel.libraryHistorySearchRequest) { _, _ in
            if isActiveHost, windowModel.isShowingLibraryHistory { isSearchFocused = true }
        }
    }

    private func open(_ entry: HistoryEntry, background: Bool) {
        guard windowModel.personaID == model.persona else { return }
        let tab = windowModel.session.openTab(url: entry.url, in: windowModel.currentSpaceID, select: false)
        if !background { windowModel.selectTab(tab.id) }
    }

    private func openWindow(_ entry: HistoryEntry) {
        guard windowModel.personaID == model.persona else { return }
        let space = windowModel.currentSpaceID
        let window = windowModel.session.openWindow()
        window.currentSpaceID = space
        window.openTab(url: entry.url)
    }

    /// The sheet captures its model, so switching spaces cannot change the Persona being cleared.
    private func confirmClear() {
        guard let window = windowModel.nsWindow, window.attachedSheet == nil else { return }
        let ranges = LibraryHistoryClearRange.allCases
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        picker.addItems(withTitles: ranges.map(\.title))
        picker.setAccessibilityLabel(localized("Time Range"))
        let alert = NSAlert()
        alert.messageText = localized("Clear History")
        if let persona = BrowserWindowModel.sheetName(ofPersona: model.persona, space: windowModel.currentSpace, among: windowModel.session.personas) {
            alert.informativeText = localized("This removes pages last visited in the selected range from history and address suggestions in \(persona). This cannot be undone.")
        } else {
            alert.informativeText = localized("This removes pages last visited in the selected range from history and address suggestions. This cannot be undone.")
        }
        alert.accessoryView = picker
        alert.addButton(withTitle: localized("Clear History")).hasDestructiveAction = true
        alert.addButton(withTitle: localized("Cancel"))
        alert.beginSheetModal(for: window) { [model] response in
            guard response == .alertFirstButtonReturn else { return }
            model.clear(ranges[picker.indexOfSelectedItem])
        }
    }
}

private struct LibraryHistoryRow: View {
    let entry: HistoryEntry
    /// The icon a page of the site showed before (`SiteIconStore`); without one, the row downloads the site's `/favicon.ico`.
    let storedIcon: NSImage?
    let open: (Bool) -> Void
    let openWindow: () -> Void
    let delete: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var icon: NSImage?

    var body: some View {
        Button { open(NSEvent.modifierFlags.contains(.command)) } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 18, height: 32)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title.isEmpty ? entry.url.host ?? entry.url.absoluteString : entry.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(entry.url.host ?? entry.url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(entry.lastVisit.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.url.absoluteString)
        .contextMenu {
            Button(localized("Open")) { open(false) }
            Button(localized("Open in New Window"), action: openWindow)
            Button(localized("Copy Address")) {
                Tab.copyToPasteboard(entry.url)
            }
            Divider()
            Button(localized("Delete from History"), role: .destructive, action: delete)
        }
        .onAppear {
            if icon == nil { icon = storedIcon }
            if icon == nil, let url = FaviconLoader.defaultIconURL(for: entry.url) {
                FaviconLoader.load(url) { icon = $0 }
            }
        }
    }
}
