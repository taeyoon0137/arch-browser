// The downloads list fills the top of the sidebar's library. Each row reflects one download's entry (`DownloadEntry.swift`) and offers open, reveal, pause, resume, cancel, and remove actions, and gives a file that a hook renamed its original name back.
import AppKit
import ARCHEngine
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsSectionView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var summary: DownloadSummary

    init(session: BrowserSession) {
        self.session = session
        _summary = ObservedObject(wrappedValue: session.downloadSummary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: session.clearFinishedDownloads)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .disabled(!summary.hasFinished)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            if session.downloads.isEmpty {
                Text("No downloads")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
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
                }
                .scrollIndicators(.never)
            }
        }
    }
}

struct DownloadRowView: View {
    /// Only the row's actions use the session, so the row does not follow its changes.
    let session: BrowserSession
    @ObservedObject var entry: DownloadEntry

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
                SidebarIconButton(symbol: "pause.circle", label: "Pause", action: entry.item.pause)
                SidebarIconButton(symbol: "xmark.circle", label: "Cancel", action: entry.item.cancel)
            } else if entry.state == .paused || entry.state == .failed {
                SidebarIconButton(symbol: "play.circle", label: "Resume", action: entry.item.resume)
                SidebarIconButton(symbol: "xmark.circle", label: "Cancel", action: entry.item.cancel)
            } else if entry.state == .completed, let path = entry.fileURL {
                SidebarIconButton(symbol: "magnifyingglass.circle", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.state == .completed, let path = entry.fileURL { NSWorkspace.shared.open(path) }
        }
        .contextMenu {
            if let path = entry.fileURL, entry.state == .completed {
                Button("Open") { NSWorkspace.shared.open(path) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                if entry.renamedPath != nil {
                    Button("Restore Original Name", action: entry.restoreOriginalName)
                }
                Divider()
            }
            Button("Remove from List") { session.removeDownload(entry) }
        }
    }
}
