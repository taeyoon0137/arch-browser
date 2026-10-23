// The downloads list shows in a popover from the sidebar. Each row mirrors one engine download item and offers open, reveal, pause, resume, cancel, and remove.
import AppKit
import ARCHEngine
import SwiftUI
import UniformTypeIdentifiers

/// Publishes one engine download item's state for the list. The session refreshes it on each engine update.
public final class DownloadEntry: ObservableObject, Identifiable {
    public let id: String
    let item: any EngineDownloadItem
    @Published public private(set) var state: EngineDownloadState
    @Published public private(set) var completedBytes: Int64
    @Published public private(set) var totalBytes: Int64
    @Published public private(set) var targetPath: URL?

    init(item: any EngineDownloadItem) {
        self.item = item
        id = item.id
        state = item.state
        completedBytes = item.completedBytes
        totalBytes = item.totalBytes
        targetPath = item.targetPath
    }

    func refresh() {
        state = item.state
        completedBytes = item.completedBytes
        totalBytes = item.totalBytes
        targetPath = item.targetPath
    }

    public var filename: String {
        targetPath?.lastPathComponent ?? item.sourceURL.lastPathComponent
    }

    public var isFinished: Bool {
        state == .completed || state == .cancelled || state == .failed
    }
}

struct DownloadsListView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear", action: session.clearFinishedDownloads)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!session.downloads.contains(where: \.isFinished))
            }
            Divider()
            if session.downloads.isEmpty {
                Text("No downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        // Newest first.
                        ForEach(session.downloads.reversed()) { entry in
                            DownloadRowView(session: session, entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

struct DownloadRowView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var entry: DownloadEntry

    private var icon: NSImage {
        if let path = entry.targetPath?.path, entry.state == .completed { return NSWorkspace.shared.icon(forFile: path) }
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
        case .failed: return "Failed"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.filename)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if entry.state == .inProgress, entry.totalBytes > 0 {
                    ProgressView(value: Double(entry.completedBytes), total: Double(entry.totalBytes))
                        .progressViewStyle(.linear)
                }
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.state == .inProgress {
                SidebarIconButton(symbol: "pause.circle", action: entry.item.pause)
                SidebarIconButton(symbol: "xmark.circle", action: entry.item.cancel)
            } else if entry.state == .paused || entry.state == .failed {
                SidebarIconButton(symbol: "play.circle", action: entry.item.resume)
                SidebarIconButton(symbol: "xmark.circle", action: entry.item.cancel)
            } else if entry.state == .completed, let path = entry.targetPath {
                SidebarIconButton(symbol: "magnifyingglass.circle") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.state == .completed, let path = entry.targetPath { NSWorkspace.shared.open(path) }
        }
        .contextMenu {
            if let path = entry.targetPath, entry.state == .completed {
                Button("Open") { NSWorkspace.shared.open(path) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                Divider()
            }
            Button("Remove from List") { session.removeDownload(entry) }
        }
    }
}
