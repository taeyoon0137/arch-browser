// Tab close log: why each tab closed this launch, with its title, address, and crash counts, shown in a debug window from View ▸ Developer.
import AppKit
import ARCHEngine
import SwiftUI

/// What closed a tab.
public enum TabCloseReason: String {
    /// The close button, ⌘W, Close Other Tabs, or the tab's context menu.
    case user
    /// The page closed itself with `window.close()`.
    case page
    /// The page closed itself after its process quit.
    case crash
    /// The tab went unselected for longer than the archive delay; the timer or the restore archived it.
    case archive
    /// The tab only pointed at a file. It closes once the file's download starts, or at once when restored, since a restored tab does not download the file again.
    case download
    /// A web extension closed it with `tabs.remove`.
    case webExtension
    /// Delete Persona closed it with the rest of its Persona.
    case persona
    case sync

    var title: String {
        switch self {
        case .user: return "User"
        case .page: return "Page"
        case .crash: return "Crash"
        case .archive: return "Archive"
        case .download: return "Download"
        case .webExtension: return "Extension"
        case .persona: return "Persona"
        case .sync: return "Sync"
        }
    }

    var detail: String {
        switch self {
        case .user: return "Closed by the user"
        case .page: return "Closed by the page"
        case .crash: return "Closed by the page after its process quit"
        case .archive: return "Archived after the archive delay"
        case .download: return "Closed because it only pointed at a file"
        case .webExtension: return "Closed by a web extension"
        case .persona: return "Closed because its Persona was deleted"
        case .sync: return "Removed by sidebar sync"
        }
    }
}

public struct TabCloseLogEntry: Identifiable {
    public let id = UUID()
    public let date = Date()
    public let reason: TabCloseReason
    public let title: String
    public let url: URL?
    public let engine: EngineKind?
    /// How many times the tab's page process quit.
    public let tabCrashCount: Int
    /// The engines' total of page process crashes this launch when the tab closed.
    public let sessionCrashCount: Int

    @MainActor init(reason: TabCloseReason, tab: Tab, sessionCrashCount: Int) {
        self.reason = reason
        title = tab.displayTitle
        url = tab.url
        engine = tab.engineKind
        tabCrashCount = tab.crashCount
        self.sessionCrashCount = sessionCrashCount
    }

    /// A tab archived at restore, before it had a page.
    init(archived record: SessionSnapshot.TabRecord) {
        reason = .archive
        title = record.customTitle ?? (record.title.isEmpty ? record.url?.host ?? "New Tab" : record.title)
        url = record.url
        engine = record.engine
        tabCrashCount = 0
        sessionCrashCount = 0
    }
}

/// The closes of this launch, newest first. It is kept in memory only, up to `limit` entries.
public final class TabCloseLog: ObservableObject {
    @Published public private(set) var entries: [TabCloseLogEntry] = []
    static let limit = 500

    func record(_ entry: TabCloseLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast() }
    }
}

/// Owns the tab close log window, which stays in memory when closed.
public final class TabCloseLogWindowController: NSWindowController {
    public init(log: TabCloseLog) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: TabCloseLogView(log: log)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Tab Close Log"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 420))
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabCloseLogWindowController is created with a log")
    }

    public func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct TabCloseLogView: View {
    @ObservedObject var log: TabCloseLog

    var body: some View {
        Group {
            if log.entries.isEmpty {
                Text("No Tabs Closed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(log.entries) {
                    TableColumn("Time") { entry in
                        Text(entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                            .monospacedDigit()
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn("Reason") { entry in
                        Text(entry.reason.title)
                            .help(entry.reason.detail)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Title") { entry in
                        Text(entry.title)
                            .help(entry.title)
                    }
                    TableColumn("Address") { entry in
                        Text(entry.url?.absoluteString ?? "")
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .help(entry.url?.absoluteString ?? "")
                    }
                    TableColumn("Engine") { entry in
                        Text(entry.engine?.displayName ?? "")
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Tab Crashes") { entry in
                        Text("\(entry.tabCrashCount)")
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn("All Crashes") { entry in
                        Text("\(entry.sessionCrashCount)")
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 80)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 240)
    }
}
