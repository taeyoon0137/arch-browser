// The Library's History tab uses the window's Persona and the downloads list's row styles.
import AppKit
import ARCHEngine
import History
import SwiftUI

struct LibraryHistoryView: View {
    @StateObject private var model: LibraryHistoryModel
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @State private var isClearHovering = false
    @State private var contentFrame = CGRect.zero
    @State private var listHeight: CGFloat = 0
    private static let scrollSpace = "LibraryHistoryScroll"

    init(store: HistoryStore, persona: UUID) {
        _model = StateObject(wrappedValue: LibraryHistoryModel(store: store, persona: persona))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("History", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(localized("Clear History…"), action: confirmClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(isClearHovering ? .primary : .secondary)
                    .onHover { isClearHovering = $0 }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            TextField(localized("Search History"), text: $model.query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
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
                            LibraryHistoryRow(entry: entry, open: { background in open(entry, background: background) },
                                              openWindow: { openWindow(entry) }, delete: { model.delete(entry) })
                        }
                    }
                    if model.hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .task(id: model.entries.count) { await model.loadNextPage() }
                    } else if model.entries.isEmpty {
                        Text(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localized("No History") : localized("No Results"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .background(GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(Self.scrollSpace))
                    Color.clear
                        .onAppear { contentFrame = frame }
                        .onChange(of: frame) { contentFrame = $1 }
                })
            }
            .scrollIndicators(.never)
            .coordinateSpace(name: Self.scrollSpace)
            .mask(ScrollEdgeFade(hiddenAbove: -contentFrame.minY, hiddenBelow: contentFrame.maxY - listHeight))
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { listHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { listHeight = $1 }
            })
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
    let open: (Bool) -> Void
    let openWindow: () -> Void
    let delete: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var icon: NSImage?

    var body: some View {
        Button { open(NSEvent.modifierFlags.contains(.command)) } label: {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 32, height: 32)
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
            .padding(6)
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
            if icon == nil, let url = FaviconLoader.defaultIconURL(for: entry.url) {
                FaviconLoader.load(url) { icon = $0 }
            }
        }
    }
}
