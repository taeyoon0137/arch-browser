// Unloading implements bookmark rules 4 and 5 (`docs/bookmarks.md`, Unloading).
// It decides what each close does, when unseen tabs unload, and which stand-in replaces an unloaded page.
// It tracks typed input through a page script and reacts to memory pressure. `BrowserSession.swift` applies the parts; tests can drive them without a session.
import Agent
import AppKit
import ARCHEngine
import Foundation

/// What closing a tab does, decided for every path that closes one (bookmark rule 4). Every close goes through `BrowserSession.closeTab(_:reason:)` or asks the page first through `requestCloseTab(_:)`, apart from `closeAgentTab(_:reason:)`, which forgets an agent's own tab, as `forget` does, and posts the `agent` reason; only Delete Tab chooses `close(remember: true)` itself.
enum TabCloseAction: Equatable {
    /// The page closes, and the tab keeps its place, folder, and ID with a stand-in at its saved page, without page state. Nothing joins the closed list or the tab close log.
    case unload
    /// A favorite's tab ends: it leaves without a closed record, and its favorite opens at its own address again.
    case end
    /// The tab leaves its space's list, into the closed list when `remember` is set.
    case close(remember: Bool)
    /// An unkept agent tab closes without a closed record or a tab close log entry.
    case forget
    /// A live folder item's tab leaves its folder without a closed record, and the item stays out of the folder while the source lists it, until Show Dismissed Items (live folder rule 4).
    case dismiss

    /// What a close for `reason` does to the tab: a pinned tab unloads, except that Delete Persona closes it into the closed list with the Persona's other tabs; a favorite's tab, the only tab outside a space's list, ends; and any other tab closes into the closed list, except one that only pointed at a file. Archiving reaches only unpinned tabs. A live folder item's tab is dismissed when the user, an extension, a plugin, or the page closes it. It unloads and keeps its place, so that the next plan does not replace it, when it only pointed at a file or its page crashed, which the user did not choose, and it closes without a closed record when its Persona goes, so that the up to 1,000 item tabs of 20 live folders cannot push other records out of the closed list. An agent tab is forgotten on every path.
    @MainActor static func of(_ tab: Tab, reason: TabCloseReason) -> TabCloseAction {
        if tab.agentOwnerID != nil { return .forget }
        if tab.spaceID == nil { return .end }
        if tab.liveItemID != nil {
            switch reason {
            case .user, .page, .webExtension, .plugin: return .dismiss
            case .persona, .sync: return .close(remember: false)
            case .crash, .download, .archive: return .unload
            }
        }
        if tab.isPinned { return reason == .persona || reason == .sync ? .close(remember: true) : .unload }
        return .close(remember: reason != .download)
    }

    /// The record the closed list gains, without page state, activation date, or hook's name (`SessionSnapshot.TabRecord.closed`), or nil for an action that adds none. A pinned tab's record keeps its folder and saved page, so ⌘Z reopens it pinned with them.
    @MainActor func closedRecord(of tab: Tab) -> SessionSnapshot.TabRecord? {
        guard self == .close(remember: true), let spaceID = tab.spaceID else { return nil }
        return SessionSnapshot.TabRecord(id: tab.id, spaceID: spaceID, url: tab.url, title: tab.title, customTitle: tab.customTitle, isPinned: tab.isPinned, folderID: tab.folderID,
                                         engine: tab.preferredEngine, personaID: tab.personaID, savedPage: tab.savedPage)
    }
}

/// How hard macOS presses for memory, as the memory pressure source reports it.
enum UnloadPressure {
    case warning
    case critical
}

/// What keeps a tab that no window shows loaded whatever the hours or the memory pressure (bookmark rule 5): a call, a page the user is writing in, and a web app that posts notifications must not stop because the user looked elsewhere.
enum UnloadExclusion: CaseIterable {
    /// The page plays sound through an audio or video element in its document, or its media session reports playing. Both engines learn this from a media script that watches the document's elements (`WebKitAudibleScript`, the bridge's `kAudibleScript`), so sound from Web Audio or from an element outside the document keeps no tab loaded.
    case media
    /// A video of the page plays in the system's picture-in-picture window, also paused or muted, which unloading would close (`EngineWebContents.isInPictureInPicture`).
    case pictureInPicture
    /// The page uses the camera or the microphone (`EngineWebContents.isCapturingMedia`).
    case capture
    /// The user typed into the page since it loaded (`Tab.hasTypedInput`).
    case typedInput
    /// The page's site may post notifications (`permissions.json`).
    case notifications
    /// A prompt waits for the tab's answer, shown as a card over its pane or not (`TabPromptQueue`).
    case prompt
    /// Downloads need the page (`EngineWebContents.closingStopsDownloads`), or the tab waits for the download of the file it points at.
    case downloads
    /// An agent owns the tab until the user takes it over.
    case agent
    /// A small window holds the tab.
    case smallWindow
    /// The page's developer tools are open, as in a window of their own, which unloading would close.
    case developerTools
    /// A window shows a page that this page opened, as a sign-in popup that reports back to it through `window.opener`.
    case opener
}

extension Tab {
    var hasPlayingMedia: Bool { isAudible || webContents.mediaSession.playbackState == .playing }

    /// These live pages count as active when the timer archives tabs and when a saved sidebar is restored.
    var hasActivityToPreserve: Bool {
        hasTypedInput || webContents.isCapturingMedia || hasPlayingMedia || webContents.isInPictureInPicture
    }
}

/// A loaded tab that no window shows, as automatic unloading weighs it: its ID, its kind, when a window last showed it, and what keeps it loaded. The session makes these, so tests can drive `TabUnloading.tabsToUnload` without one.
struct UnloadCandidate {
    enum Kind {
        case pinned
        case favorite
        /// A space's tab that is not pinned.
        case open
    }

    var id: UUID
    var kind: Kind
    var lastActivatedAt: Date
    var exclusions: Set<UnloadExclusion> = []
}

public enum TabUnloading {
    /// Settings ▸ Sidebar saves under this key the hours after which pinned tabs and favorites' tabs that no window shows unload; 0 turns automatic unloading off, under memory pressure too.
    public static let unloadAfterHoursKey = "ARCHUnloadAfterHours"

    /// The hours while nothing is saved under `unloadAfterHoursKey`.
    public static let unloadAfterHoursByDefault = 12

    /// The hours saved in `defaults` under `unloadAfterHoursKey`, 0 for a negative number, or `unloadAfterHoursByDefault` while none are.
    static func unloadAfterHours(in defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: unloadAfterHoursKey) == nil ? unloadAfterHoursByDefault : max(0, defaults.integer(forKey: unloadAfterHoursKey))
    }

    /// How long a tab must have gone unshown to unload at a memory pressure warning.
    static let warningInactivity: TimeInterval = 30 * 60

    /// The IDs of the candidates that unload now, in their order: without `pressure`, as the archive timer asks, the pinned tabs and favorites' tabs that no window has shown for `hours`; at a memory pressure warning, every candidate unshown for `warningInactivity`; at critical pressure, every candidate. Nothing unloads while `hours` is 0, and a candidate with an exclusion never does.
    static func tabsToUnload(_ candidates: [UnloadCandidate], now: Date, after hours: Int, pressure: UnloadPressure?) -> [UUID] {
        guard hours > 0 else { return [] }
        return candidates.filter { candidate in
            guard candidate.exclusions.isEmpty else { return false }
            let inactivity = now.timeIntervalSince(candidate.lastActivatedAt)
            switch pressure {
            case .critical: return true
            case .warning: return inactivity >= warningInactivity
            case nil: return candidate.kind != .open && inactivity >= TimeInterval(hours) * 3600
            }
        }.map(\.id)
    }

    // MARK: Typed text

    /// The world of `inputScript`, apart from every plugin's (`ARCHPlugin.<id>`).
    static let inputWorld = "arch.unloading"

    /// Runs at the start of every frame's document and tells the tab when the user types there (`Tab.hasTypedInput`): the main frame's new document sends `start`, and each document sends `typed` at the first `input` event the user causes, which reaches the window before the page's own listeners, and again when it returns from the back-forward cache. The tab clears its flag when a main document commits, which both engines report before a restored document's frames can send `typed`. On Chromium the page shares the script's world, so a page could at most keep its own tab loaded and out of automatic archiving.
    static let inputScript = EnginePageScript(world: inputWorld, source: """
    (channel) => {
      const isMainFrame = window.top === window;
      let hasTyped = false;
      if (isMainFrame) channel.send("start");
      addEventListener("input", (event) => {
        if (!event.isTrusted || hasTyped) return;
        hasTyped = true;
        channel.send("typed");
      }, true);
      addEventListener("pageshow", (event) => {
        if (event.isTrusted && event.persisted && hasTyped) channel.send("typed");
      });
    }
    """, injectionTime: .documentStart, mainFrameOnly: false)

    /// A tab's page scripts: `inputScript`, in an agent tab the target check of the agents' trusted input (`AgentPageScripts.targetCheck`), then its Persona's plugins' `scripts`.
    static func pageScripts(withPluginScripts scripts: [EnginePageScript], inAgentTab: Bool = false) -> [EnginePageScript] {
        [inputScript] + (inAgentTab ? [AgentPageScripts.targetCheck] : []) + scripts
    }

    /// What `inputScript` reports.
    enum InputEvent: Equatable {
        /// The main frame started a new document. The tab also clears its flag when a main document commits.
        case start
        /// The user typed into a document of the page.
        case typed

        /// The event a message of `inputWorld` carries, or nil for another message. Only the main frame starts a document over.
        init?(_ message: EnginePageScriptMessage) {
            guard message.world == TabUnloading.inputWorld, let value = try? JSONDecoder().decode(String.self, from: Data(message.json.utf8)) else { return nil }
            switch value {
            case "start" where message.isMainFrame: self = .start
            case "typed": self = .typed
            default: return nil
            }
        }
    }
}

/// Hands each memory pressure warning and critical event that macOS reports for the app to `handler` on the main queue, for as long as it exists.
final class MemoryPressureMonitor {
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    init(handler: @escaping (UnloadPressure) -> Void) {
        source.setEventHandler { [weak self] in
            guard let event = self?.source.data else { return }
            if event.contains(.critical) {
                handler(.critical)
            } else if event.contains(.warning) {
                handler(.warning)
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}

// MARK: Stand-ins

extension Tab {
    /// Closing a pinned tab (bookmark rule 4): the tab takes a stand-in at its saved page, or at its address without one, in its engine and without page state, and returns its page for the session to close. Opening it again is the user's choice: its first load counts as a visit, and an address that turns out to be a file downloads it. The session has the stand-in load the site's icon, or, for a live folder item's tab, shows its folder's.
    func unloadToSavedPage() -> any EngineWebContents {
        let standIn = UnloadedWebContents(url: savedPage?.url ?? url, title: savedPage?.title ?? title, engine: preferredEngine, state: nil, requestsSiteIcon: liveItemID == nil)
        isRestored = false
        recordedURL = nil
        return takeStandIn(standIn)
    }

    /// An automatic unload (bookmark rule 5): the tab takes a stand-in that keeps its address, title, icon, and its engine's page state, which a Chromium page lacks, and returns its page for the session to close. Loading it again resumes it, as after a relaunch, and the page takes its host's remembered zoom once it loads.
    func unloadKeepingPage() -> any EngineWebContents {
        takeStandIn(UnloadedWebContents(url: url, title: title, engine: preferredEngine, state: restorableStateForPreferredEngine, icon: favicon, requestsSiteIcon: liveItemID == nil))
    }

    /// Puts `standIn` in place of the tab's web contents, takes its title and icon, and returns the web contents it replaced.
    private func takeStandIn(_ standIn: UnloadedWebContents) -> any EngineWebContents {
        let page = webContents
        replaceWebContents(with: standIn)
        webContentsDidChangeTitle(standIn)
        webContentsDidChangeFavicon(standIn)
        return page
    }
}
