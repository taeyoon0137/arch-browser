// The sheets that tabs ask for: a page's own dialogs, permission questions, sign-ins, leave-page checks, file choosers, and the app's notices about a page. Each waits in its tab's queue until a window shows the tab on screen, and each window shows one sheet at a time on its own AppKit window, so a background page cannot cover the page in front.
import AppKit

/// A sheet a tab asked for: an alert, or an open or save panel for the page's file chooser.
struct TabSheet {
    let tabID: UUID
    /// The sheet's own window.
    let window: NSWindow
    /// Shows the sheet on a window, which reports the response.
    let begin: (NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    /// An `alert`, `confirm`, or `prompt` from the page, which the engine can cancel.
    let isPageDialog: Bool
    /// Whether the sheet can be put away and shown again (`deferSheet(of:)`). A panel cannot: it gets `.cancel` instead, and the page can ask again.
    let canDefer: Bool
    let completion: (NSApplication.ModalResponse) -> Void
}

/// Sheets that tabs asked for, oldest first per tab. A window shows one of them at a time (`BrowserWindowModel.visibleSheet`), for a tab on its screen.
final class TabSheetQueue {
    /// The open browser windows, which the session supplies.
    var windows: () -> [BrowserWindowModel] = { [] }
    /// The sheets no window shows yet, by tab.
    private var pending: [UUID: [TabSheet]] = [:]

    /// Ends a sheet without answering it, so that it can show again.
    private static let deferredResponse = NSApplication.ModalResponse(rawValue: -1_100)

    func enqueue(_ alert: NSAlert, for tab: Tab, isPageDialog: Bool, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        enqueue(TabSheet(tabID: tab.id, window: alert.window, begin: { alert.beginSheetModal(for: $0, completionHandler: $1) },
                         isPageDialog: isPageDialog, canDefer: true, completion: completion))
    }

    /// Queues an open or save panel, whose response is `.OK` once the user chose.
    func enqueue(_ panel: NSSavePanel, for tab: Tab, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        enqueue(TabSheet(tabID: tab.id, window: panel, begin: { panel.beginSheetModal(for: $0, completionHandler: $1) },
                         isPageDialog: false, canDefer: false, completion: completion))
    }

    private func enqueue(_ sheet: TabSheet) {
        pending[sheet.tabID, default: []].append(sheet)
        showNext()
    }

    /// Each window that has an AppKit window and shows no sheet shows the oldest waiting sheet of the tabs on its screen, the selected tab's first. A sheet that does not come from a tab, such as a Persona's name prompt or the print panel, keeps the tabs' sheets waiting, and the window controller calls this again once AppKit has taken any sheet off the window. Nothing runs an app-modal alert inside an engine callback.
    func showNext() {
        for window in windows() where window.visibleSheet == nil {
            guard let nsWindow = window.nsWindow, nsWindow.attachedSheet == nil,
                  let tab = window.tabsOnScreen.first(where: { pending[$0.id]?.isEmpty == false }), var queue = pending[tab.id] else { continue }
            let sheet = queue.removeFirst()
            pending[tab.id] = queue.isEmpty ? nil : queue
            window.visibleSheet = sheet
            sheet.begin(nsWindow) { [weak self, weak window] response in
                window?.visibleSheet = nil
                // AppKit calls this before the sheet leaves its window, which keeps another window from showing it, so a deferred sheet shows again only once `deferSheet(of:)` has returned.
                if response == Self.deferredResponse, let self {
                    self.pending[sheet.tabID, default: []].insert(sheet, at: 0)
                } else {
                    sheet.completion(response)
                }
            }
        }
    }

    /// Puts away the window's sheet once its tab has left the window's screen, as when the window selects another tab or another window takes the tab. The sheet shows again first when a window shows its tab: the caller then calls `showNext()`, by which time `endSheet` has taken the sheet off this window. A panel ends with `.cancel` instead.
    ///
    /// `endSheet` runs the run loop while the sheet animates out, for about 0.27 seconds (`docs/windows-personas.md`, Facts), so events such as a click on another tab or an engine callback can arrive before this returns. The caller reads the windows' state again afterwards instead of what it read before.
    func deferSheet(of window: BrowserWindowModel) {
        guard let sheet = window.visibleSheet, !window.tabsOnScreen.contains(where: { $0.id == sheet.tabID }),
              let parent = sheet.window.sheetParent else { return }
        parent.endSheet(sheet.window, returnCode: sheet.canDefer ? Self.deferredResponse : .cancel)
    }

    /// Gives a tab's sheets the safe answer, `.cancel`, including one a window shows: all of them when the tab closes, or only the page's dialogs when the engine cancels those. The queue changes first, so that ending a visible sheet does not show one that is going too.
    func cancel(for tab: Tab, pageDialogsOnly: Bool = false) {
        let queue = pending.removeValue(forKey: tab.id) ?? []
        let waiting = pageDialogsOnly ? queue.filter(\.isPageDialog) : queue
        let kept = pageDialogsOnly ? queue.filter { !$0.isPageDialog } : []
        if !kept.isEmpty { pending[tab.id] = kept }
        for window in windows() {
            guard let sheet = window.visibleSheet, sheet.tabID == tab.id, !pageDialogsOnly || sheet.isPageDialog,
                  let parent = sheet.window.sheetParent else { continue }
            parent.endSheet(sheet.window, returnCode: .cancel)
        }
        waiting.forEach { $0.completion(.cancel) }
    }

    /// Gives every sheet the safe answer, `.cancel`, including those windows show.
    func cancelAll() {
        let waiting = pending.values.flatMap { $0 }
        pending = [:]
        for window in windows() {
            guard let sheet = window.visibleSheet, let parent = sheet.window.sheetParent else { continue }
            parent.endSheet(sheet.window, returnCode: .cancel)
        }
        waiting.forEach { $0.completion(.cancel) }
    }
}
