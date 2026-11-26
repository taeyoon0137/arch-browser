// Follows the selected page's visibility. The engines keep ownership of automatic presentations separately from page and manual requests.
import AppKit
import ARCHEngine
import Combine
import Foundation

public enum AutomaticPictureInPictureSetting {
    public static let defaultsKey = "ARCHAutomaticPictureInPicture"
    public static let enabledByDefault = true
    public static var title: String { localized("Automatic Picture in Picture") }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? enabledByDefault : defaults.bool(forKey: defaultsKey)
    }
}

/// Focus is lost when any of these conditions fails, including a main browser window that gives the keyboard to another window of the app.
struct PictureInPictureFocus {
    var appIsActive: Bool
    var windowIsKey: Bool
    var windowIsMain: Bool
    var windowIsMinimized: Bool

    var showsInline: Bool { appIsActive && windowIsKey && windowIsMain && !windowIsMinimized }
}

@MainActor final class AutomaticPictureInPicture {
    private weak var previouslyFocused: (any EngineWebContents)?
    private weak var previouslyFocusedWindow: NSWindow?
    private var request: Request?
    /// Only the latest departure waits behind an outstanding stop. Returning or disabling cancels it.
    private struct Departure {
        let contents: any EngineWebContents
        weak var sourceWindow: NSWindow?
    }
    private var pendingDeparture: Departure?
    private var canStart: (any EngineWebContents, (any EngineWebContents)?) -> Bool = { _, _ in true }
    private var observers: Set<AnyCancellable> = []

    private final class Request {
        let contents: any EngineWebContents
        var shouldStop = false
        var isStarting = true
        var isStopping = false
        var hasObservedActive = false
        var stopWasSentBeforeStart = false
        init(_ contents: any EngineWebContents) { self.contents = contents }
    }

    func observe(_ session: BrowserSession) {
        canStart = { [weak session] candidate, stopped in
            guard let session, session.allTabs.contains(where: { $0.webContents === candidate }) else { return false }
            return !session.allTabs.contains { $0.webContents !== stopped && $0.webContents.isInPictureInPicture }
        }
        let notifications: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification, NSWindow.willMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            UserDefaults.didChangeNotification]
        for name in notifications {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak session] note in
                    guard let self, let session else { return }
                    if let window = note.object as? NSWindow, session.window(for: window) == nil { return }
                    let lostFocus = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification,
                                     NSWindow.didResignMainNotification, NSWindow.willMiniaturizeNotification].contains(note.name)
                    // Ignore a late loss report from the previous window after another browser window already became main.
                    if let window = note.object as? NSWindow, lostFocus, window !== session.activeWindow?.nsWindow { return }
                    self.refresh(session, losingFocus: lostFocus)
                }
                .store(in: &observers)
        }
    }

    func refresh(_ session: BrowserSession, losingFocus: Bool = false) {
        let model = session.activeWindow
        let window = model?.nsWindow
        let focus = PictureInPictureFocus(appIsActive: NSApp?.isActive == true, windowIsKey: window?.isKeyWindow == true,
                                          windowIsMain: window?.isMainWindow == true, windowIsMinimized: window?.isMiniaturized == true)
        let tab = model?.selectedTab
        let contents = tab.flatMap { tab in model?.shows(tab) == true && model?.isSelectedPageCovered == false && tab.isLoaded ? tab.webContents : nil }
        let presentations = session.allTabs.map(\.webContents).filter { $0.isInPictureInPicture }
        update(selected: contents, isFocused: focus.showsInline && !losingFocus,
               enabled: AutomaticPictureInPictureSetting.isEnabled(),
               hasPictureInPicture: !presentations.isEmpty, activePresentations: presentations)
    }

    /// Called after a selection changes, before the old page's view leaves its window, and for app/window focus notifications. Repeated loss notifications make only one request.
    func update(selected: (any EngineWebContents)?, isFocused: Bool, enabled: Bool, hasPictureInPicture: Bool,
                activePresentations: [any EngineWebContents] = []) {
        let previous = previouslyFocused
        let sourceWindow = previouslyFocusedWindow ?? previous?.view.window
        previouslyFocused = isFocused ? selected : nil
        previouslyFocusedWindow = isFocused ? selected?.view.window : nil
        if !enabled || (isFocused && selected === pendingDeparture?.contents) { pendingDeparture = nil }
        // Native reports can arrive after the entry result. Only a presentation observed active can be retired from its later inactive report.
        if let request {
            if request.contents.isInPictureInPicture { request.hasObservedActive = true }
            else if request.hasObservedActive && !request.isStarting && !request.isStopping { self.request = nil }
        }
        if let request, !enabled || (isFocused && selected === request.contents) { stop(request) }
        // A timed-out entry can arrive later and fail its first exit after Swift released the request.
        // The engine's ownership check makes these retries harmless for manual and page presentations.
        if !enabled {
            for contents in activePresentations where contents !== selected { stopUntracked(contents) }
        }
        if !enabled || isFocused, let selected { stopUntracked(selected) }
        guard enabled, let previous,
              !previous.isInPictureInPicture || (request?.shouldStop == true && request?.contents === previous),
              !isFocused || selected !== previous else { return }
        if let request {
            // A quick return and second departure waits for the first request to finish stopping. An inactive report without an observed start is also reconciled through the owned stop, rather than abandoning an entry whose native report was late.
            guard request.shouldStop || (!request.isStarting && !request.contents.isInPictureInPicture),
                  !hasPictureInPicture || request.contents.isInPictureInPicture else { return }
            pendingDeparture = Departure(contents: previous, sourceWindow: sourceWindow)
            stop(request)
        } else if !hasPictureInPicture {
            start(previous, sourceWindow: sourceWindow)
        }
    }

    private func stopUntracked(_ contents: any EngineWebContents) {
        guard contents !== request?.contents, contents.isInPictureInPicture else { return }
        contents.setAutomaticPictureInPicture(false, sourceWindow: nil) { _ in }
    }

    private func start(_ contents: any EngineWebContents, sourceWindow: NSWindow?, afterStopping stopped: (any EngineWebContents)? = nil) {
        guard (!contents.isInPictureInPicture || contents === stopped), canStart(contents, stopped) else { return }
        let pending = Request(contents)
        request = pending
        contents.setAutomaticPictureInPicture(true, sourceWindow: sourceWindow) { [weak self, weak pending] started in
            guard let self, let pending, self.request === pending else { return }
            pending.isStarting = false
            pending.hasObservedActive = pending.contents.isInPictureInPicture
            if pending.shouldStop {
                // The script may have begun after the earlier stop was sent.
                if started { self.stop(pending) }
                else if !pending.isStopping { self.finished(pending, stopped: false) }
            } else if !started {
                self.finished(pending, stopped: false)
            }
        }
    }

    private func stop(_ pending: Request) {
        pending.shouldStop = true
        guard !pending.isStopping, !pending.isStarting || !pending.stopWasSentBeforeStart else { return }
        if pending.isStarting { pending.stopWasSentBeforeStart = true }
        pending.isStopping = true
        pending.contents.setAutomaticPictureInPicture(false, sourceWindow: nil) { [weak self, weak pending] stopped in
            guard let self, let pending, self.request === pending else { return }
            pending.isStopping = false
            if !pending.isStarting { self.finished(pending, stopped: stopped) }
        }
    }

    private func finished(_ pending: Request, stopped: Bool) {
        // A refused exit still belongs to us. A later return or settings change may retry it.
        if pending.shouldStop && !stopped && pending.contents.isInPictureInPicture { return }
        request = nil
        guard let next = pendingDeparture else { return }
        pendingDeparture = nil
        start(next.contents, sourceWindow: next.sourceWindow, afterStopping: stopped ? pending.contents : nil)
    }

    /// Replacing a selected tab's engine keeps its focus without creating a departure from the old page.
    func contentsWillBeReplaced(_ contents: any EngineWebContents, with replacement: any EngineWebContents) {
        if previouslyFocused === contents { previouslyFocused = replacement }
    }

    /// The engine has closed or replaced this page and owns ending its native presentations.
    func contentsDidRetire(_ contents: any EngineWebContents) {
        if previouslyFocused === contents {
            previouslyFocused = nil
            previouslyFocusedWindow = nil
        }
        if pendingDeparture?.contents === contents { pendingDeparture = nil }
        if let request, request.contents === contents { finished(request, stopped: true) }
    }

    /// Closing a browser window is not a focus transition that should open a new presentation.
    func windowWillClose(_ window: BrowserWindowModel) {
        if let contents = window.selectedTab?.webContents {
            if previouslyFocused === contents { previouslyFocused = nil }
            if pendingDeparture?.contents === contents { pendingDeparture = nil }
        }
        if let request, window.shownTabIDs.contains(where: { id in window.session.allTabs.first { $0.id == id }?.webContents === request.contents }) {
            stop(request)
        }
    }
}
