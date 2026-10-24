// The bottom-left button opens the library and pushes the sidebar aside. It lists downloads at the top and other tools at the bottom. The button shows download progress while files download and a badge for the finished downloads the user has not seen.
import SwiftUI

/// A library column with room for the window buttons. The library button stays in its sidebar position, under the pointer.
struct LibraryPanel: View {
    @ObservedObject var session: BrowserSession
    let windowButtons: WindowButtonMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(height: SidebarTopRow.height)
                .padding(.top, max(0, windowButtons.centerY - SidebarTopRow.height / 2))
            LibraryView(session: session)
                .padding(.top, 6)
                .frame(maxHeight: .infinity)
            HStack {
                LibraryButton(session: session)
                Spacer(minLength: 0)
            }
            .frame(height: 28)
        }
        .padding(.horizontal, SidebarView.inset)
        .padding(.bottom, 10)
    }
}

struct LibraryView: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DownloadsSectionView(session: session)
                .frame(maxHeight: .infinity, alignment: .top)
            Divider().padding(.horizontal, 10)
            VStack(spacing: 2) {
                LibraryToolRow(symbol: "arrow.uturn.backward", title: "Reopen Closed Tab", action: session.reopenLastClosedTab)
                    .disabled(!session.hasClosedTabs)
                LibraryToolRow(symbol: "gearshape", title: "Settings") { session.showSettings?() }
            }
        }
    }
}

struct LibraryToolRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering && isEnabled ? SidebarFill.hover.color(in: colorScheme) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
    }
}

/// Opens and closes the library. While files download it shows a download symbol over their combined progress.
struct LibraryButton: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.sidebarIsFloating) private var isFloating
    @State private var isHovering = false

    /// In the floating sidebar, the library opens in the card. Elsewhere, it also reveals a hidden sidebar.
    private func toggle() {
        if isFloating {
            windowModel.isLibraryVisible.toggle()
        } else {
            windowModel.toggleLibrary()
        }
    }

    private var activeDownloads: [DownloadEntry] {
        session.downloads.filter { $0.state == .inProgress }
    }

    /// The share of the active downloads' bytes received, or `nil` when none of them knows its size.
    private var progress: Double? {
        let sized = activeDownloads.filter { $0.totalBytes > 0 }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = sized.reduce(Int64(0)) { $0 + $1.completedBytes }
        return min(1, Double(received) / Double(total))
    }

    private var accessibilityValue: String {
        if !activeDownloads.isEmpty { return "Downloading" }
        let count = session.unseenDownloadIDs.count
        return count == 0 ? "" : count == 1 ? "1 new download" : "\(count) new downloads"
    }

    var body: some View {
        Button(action: toggle) {
            Group {
                if activeDownloads.isEmpty {
                    Image(systemName: "archivebox")
                        .font(.system(size: 15, weight: .medium))
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                        DownloadProgressBar(progress: progress)
                            .frame(width: 16, height: 3)
                    }
                }
            }
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(windowModel.isLibraryVisible ? 0.1 : isHovering ? 0.08 : 0)))
            .overlay(alignment: .topTrailing) {
                if activeDownloads.isEmpty, !session.unseenDownloadIDs.isEmpty {
                    Text("\(session.unseenDownloadIDs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 3, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(windowModel.isLibraryVisible ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help("Library")
        .accessibilityLabel("Library")
        .accessibilityValue(accessibilityValue)
    }
}

/// A thin bar for the library button. Without a known size a short segment slides back and forth.
struct DownloadProgressBar: View {
    let progress: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                if let progress {
                    Capsule().fill(Color.accentColor).frame(width: max(geometry.size.height, geometry.size.width * progress))
                } else {
                    SlidingSegment(width: geometry.size.width)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress)
    }
}

/// Starts sliding each time it appears, so the motion returns when a download's size becomes unknown again.
private struct SlidingSegment: View {
    let width: CGFloat
    @State private var isSliding = false

    var body: some View {
        Capsule().fill(Color.accentColor)
            .frame(width: width * 0.4)
            .offset(x: isSliding ? width * 0.6 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isSliding = true }
            }
    }
}
