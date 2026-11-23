// The downloads list fills the top of the sidebar's library. Each row reflects one download's entry (`DownloadEntry.swift`) and offers open, reveal, pause, resume, retry, cancel, and remove actions, and gives a file that a hook renamed its original name back.
import Accessibility
import AppKit
import ARCHEngine
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsSectionView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var summary: DownloadSummary
    @State private var isClearHovering = false
    /// The list's content in the scroll view's visible area, and the visible area's height, which tell how much is hidden above and below.
    @State private var contentFrame = CGRect.zero
    @State private var listHeight: CGFloat = 0
    private static let scrollSpace = "DownloadsScroll"

    init(session: BrowserSession) {
        self.session = session
        _summary = ObservedObject(wrappedValue: session.downloadSummary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The section's title and its action share one size and baseline, as the space header's line does.
            HStack(alignment: .firstTextBaseline) {
                Text("Downloads", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(localized("Clear"), action: session.clearFinishedDownloads)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    // Brightens under the pointer while there is something to clear, as the new space button does.
                    .foregroundStyle(isClearHovering && summary.hasFinished ? .primary : .secondary)
                    .onHover { isClearHovering = $0 }
                    .disabled(!summary.hasFinished)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            if session.downloads.isEmpty {
                Text("No Downloads", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        // Newest first.
                        ForEach(session.downloads.reversed()) { entry in
                            DownloadRowView(session: session, entry: entry)
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
                // Rows fade out under the header and above the divider instead of being cut off, at each end only while rows are hidden past it, as the tab list's do.
                .mask(ScrollEdgeFade(hiddenAbove: -contentFrame.minY, hiddenBelow: contentFrame.maxY - listHeight))
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { listHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { listHeight = $1 }
                })
            }
        }
    }
}

struct DownloadRowView: View {
    /// Only the row's actions use the session, so the row does not follow its changes.
    let session: BrowserSession
    @ObservedObject var entry: DownloadEntry
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var fileIssue: DownloadEntry.FileIssue?

    /// A finished file opens on a click, so only its row shows the hover fill and answers VoiceOver's press.
    private var opensFile: Bool { entry.state == .completed }

    private func showIssue(_ issue: DownloadEntry.FileIssue?) {
        fileIssue = issue
        if let issue { AccessibilityNotification.Announcement(issue.rawValue).post() }
    }

    private func openFile() {
        showIssue(entry.accessFile(onFailure: .open) { NSWorkspace.shared.open($0) })
    }

    private func revealFile() {
        showIssue(entry.accessFile(onFailure: .reveal) { NSWorkspace.shared.selectFile($0.path, inFileViewerRootedAtPath: "") })
    }

    private func showFolder() {
        if let issue = entry.showContainingFolder({ NSWorkspace.shared.open($0) }) { showIssue(issue) }
    }

    private var icon: NSImage {
        if let path = entry.fileURL?.path, entry.state == .completed { return NSWorkspace.shared.icon(forFile: path) }
        return NSWorkspace.shared.icon(for: .data)
    }

    private var status: String {
        let formatter = ByteCountFormatter()
        switch entry.state {
        case .inProgress:
            let total = entry.totalBytes > 0 ? " of \(formatter.string(fromByteCount: entry.totalBytes))" : ""
            return formatter.string(fromByteCount: entry.completedBytes) + total
        case .paused: return "Paused"
        case .completed: return formatter.string(fromByteCount: entry.totalBytes > 0 ? entry.totalBytes : entry.completedBytes)
        case .cancelled: return "Cancelled"
        case .failed: return entry.canRetry ? "Failed" : "Failed — start again from the page"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // VoiceOver reads the name, progress, and status as one element, which opens a finished file; the buttons around it stay elements of their own.
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.filename)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        // Keeps the extension, as the Finder does.
                        .truncationMode(.middle)
                    // Without a known size the bar is indeterminate, as the library button's is, so a running download always shows one.
                    if entry.state == .inProgress {
                        Group {
                            if entry.totalBytes > 0 {
                                ProgressView(value: Double(entry.completedBytes), total: Double(entry.totalBytes))
                            } else {
                                ProgressView()
                            }
                        }
                        .progressViewStyle(.linear)
                    }
                    Text(fileIssue?.rawValue ?? status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        // The instruction on a failed download without buttons gets a second line at the default sidebar width.
                        .lineLimit(entry.state == .failed && !entry.canRetry ? 2 : 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(opensFile ? .isButton : [])
                // A tap gesture alone does not answer the accessibility press, so VoiceOver could not open the file.
                .accessibilityAction { openFile() }
                if fileIssue != nil {
                    HStack {
                        if entry.containingFolder != nil {
                            Button(localized("Show Folder"), action: showFolder)
                        }
                        Button(localized("Remove from List")) { session.removeDownload(entry) }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
            // A pair of buttons touches, as the address pill's do. A failed download starts a new attempt, which may begin again from the start, so it offers Retry rather than Resume.
            if entry.state == .inProgress {
                HStack(spacing: 0) {
                    SidebarIconButton(symbol: "pause.circle", label: "Pause", action: entry.item.pause)
                    SidebarIconButton(symbol: "xmark.circle", label: "Cancel", action: entry.item.cancel)
                }
            } else if entry.state == .paused {
                HStack(spacing: 0) {
                    SidebarIconButton(symbol: "play.circle", label: "Resume", action: entry.item.resume)
                    SidebarIconButton(symbol: "xmark.circle", label: "Cancel", action: entry.item.cancel)
                }
            } else if entry.state == .failed, entry.canRetry {
                HStack(spacing: 0) {
                    SidebarIconButton(symbol: "arrow.clockwise.circle", label: "Retry", action: entry.item.resume)
                    SidebarIconButton(symbol: "xmark.circle", label: "Cancel", action: entry.item.cancel)
                }
            } else if entry.state == .completed, entry.fileURL != nil {
                SidebarIconButton(symbol: "magnifyingglass.circle", label: "Show in Finder", action: revealFile)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering && opensFile ? SidebarFill.hover.color(in: colorScheme) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: openFile)
        .onChange(of: entry.fileURL) { fileIssue = nil }
        .contextMenu {
            if entry.state == .completed {
                Button(localized("Open"), action: openFile)
                if entry.fileURL != nil {
                    Button(localized("Show in Finder"), action: revealFile)
                }
                if fileIssue != nil, entry.containingFolder != nil {
                    Button(localized("Show Folder"), action: showFolder)
                }
                if entry.renamedPath != nil {
                    Button(localized("Restore Original Name")) {
                        showIssue(entry.accessFile(onFailure: .restore) { _ in entry.restoreOriginalName() })
                    }
                }
                Divider()
            }
            Button(localized("Remove from List")) { session.removeDownload(entry) }
        }
    }
}
