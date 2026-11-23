// Tab close log: why each tab closed this launch, with its title, address, and crash counts, and why an engine or a Persona's profile did not start, shown in a debug window from View ▸ Developer.
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
    /// A plugin closed it with `PluginContext.closeTab(_:)`.
    case plugin
    /// Delete Persona closed it with the rest of its Persona.
    case persona
    /// A sidebar sync deletion or a first-sync match from another Mac removed it.
    case sync

    var title: String {
        switch self {
        case .user: return localized("User")
        case .page: return localized("Page")
        case .crash: return localized("Crash")
        case .archive: return localized("Archive")
        case .download: return localized("Download")
        case .webExtension: return localized("Extension")
        case .plugin: return localized("Plugin")
        case .persona: return localized("Persona")
        case .sync: return localized("Sync")
        }
    }

    var detail: String {
        switch self {
        case .user: return localized("Closed by the user")
        case .page: return localized("Closed by the page")
        case .crash: return localized("Closed by the page after its process quit")
        case .archive: return localized("Archived after the archive delay")
        case .download: return localized("Closed because it only pointed at a file")
        case .webExtension: return localized("Closed by a web extension")
        case .plugin: return localized("Closed by a plugin")
        case .persona: return localized("Closed because its Persona was deleted")
        case .sync: return localized("Removed by sidebar sync")
        }
    }
}

/// One tab's close reason and page state captured for the debug log.
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
        title = record.customTitle ?? (record.title.isEmpty ? record.url?.host ?? localized("New Tab") : record.title)
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

    /// Prepends an entry and discards the oldest one above the log limit.
    func record(_ entry: TabCloseLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast() }
    }
}

/// An engine that did not start this launch, or did not open a Persona's profile, with the engine's reason.
public struct EngineStartFailure: Identifiable {
    public let id = UUID()
    public let date = Date()
    public let engine: EngineKind
    /// The Persona whose profile did not open, or nil when the engine itself did not start.
    public let personaID: Persona.ID?
    public let personaName: String?
    /// The engine's reason in the interface's language.
    public let reason: String
    /// The error as the engine names it, such as `ARCHEngineChromium.ChromiumEngine.StartError.initializationFailed`.
    public let error: String

    init(engine: EngineKind, persona: Persona?, error: any Error) {
        self.engine = engine
        personaID = persona?.id
        personaName = persona?.name
        reason = error.localizedDescription
        self.error = String(reflecting: error)
    }
}

/// The engines and profiles that did not start this launch, oldest first, in memory only. A failure that repeats with the same reason, as each time a tab asks for the engine again, is kept once.
public final class EngineStartLog: ObservableObject {
    @Published public private(set) var failures: [EngineStartFailure] = []

    func record(_ failure: EngineStartFailure) {
        guard !failures.contains(where: { $0.engine == failure.engine && $0.personaID == failure.personaID && $0.error == failure.error }) else { return }
        failures.append(failure)
    }
}

/// Owns the tab close log window, which stays in memory when closed. Above the closes, it lists the engines and profiles that did not start this launch.
public final class TabCloseLogWindowController: NSWindowController {
    public init(log: TabCloseLog, startLog: EngineStartLog) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: TabCloseLogView(log: log, startLog: startLog)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = localized("Tab Close Log")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 420))
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    public func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The debug window's contents: the engine start failures above the list of this launch's tab closes.
private struct TabCloseLogView: View {
    @ObservedObject var log: TabCloseLog
    @ObservedObject var startLog: EngineStartLog

    var body: some View {
        VStack(spacing: 0) {
            if !startLog.failures.isEmpty {
                EngineStartFailuresView(failures: startLog.failures)
                Divider()
            }
            closes
        }
        .frame(minWidth: 560, minHeight: 240)
    }

    private var closes: some View {
        Group {
            if log.entries.isEmpty {
                Text("No Tabs Closed", bundle: .module)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(log.entries) {
                    TableColumn(localized("Time")) { entry in
                        Text(entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                            .monospacedDigit()
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn(localized("Reason")) { entry in
                        Text(entry.reason.title)
                            .help(entry.reason.detail)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn(localized("Title")) { entry in
                        Text(entry.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(entry.title)
                    }
                    TableColumn(localized("Address")) { entry in
                        Text(entry.url?.absoluteString ?? "")
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .help(entry.url?.absoluteString ?? "")
                    }
                    TableColumn(localized("Engine")) { entry in
                        Text(entry.engine?.displayName ?? "")
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn(localized("Tab Crashes")) { entry in
                        Text("\(entry.tabCrashCount)")
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn(localized("All Crashes")) { entry in
                        Text("\(entry.sessionCrashCount)")
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 80)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// One line per engine or profile that did not start: when, which engine, which Persona or all of them, and the engine's reason, with the error's name in its help tag.
private struct EngineStartFailuresView: View {
    let failures: [EngineStartFailure]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Engines That Did Not Start", bundle: .module)
                .font(.headline)
            ForEach(failures) { failure in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(failure.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(failure.engine.displayName)
                    Text(failure.personaName ?? localized("Every Persona"))
                        .foregroundStyle(.secondary)
                    Text(failure.reason)
                        .help(failure.error)
                }
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
