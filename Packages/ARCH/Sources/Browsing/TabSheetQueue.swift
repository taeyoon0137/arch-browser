// The sheets that tabs ask for: a page's own dialogs, permission questions, sign-ins, leave-page checks, and the app's notices about a page. Each waits in its tab's queue until a window shows the tab on screen, and each window shows one sheet at a time on its own AppKit window, so a background page cannot cover the page in front.
import AppKit

/// A sheet a tab asked for.
struct TabSheet {
    let tabID: UUID
    let alert: NSAlert
    /// An `alert`, `confirm`, or `prompt` from the page, which the engine can cancel.
    let isPageDialog: Bool
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
        pending[tab.id, default: []].append(TabSheet(tabID: tab.id, alert: alert, isPageDialog: isPageDialog, completion: completion))
        showNext()
    }

    /// Each window that has an AppKit window and shows no sheet shows the oldest waiting sheet of the tabs on its screen, the selected tab's first. Nothing runs an app-modal alert inside an engine callback.
    func showNext() {
        for window in windows() where window.visibleSheet == nil {
            guard let nsWindow = window.nsWindow, let tab = window.tabsOnScreen.first(where: { pending[$0.id]?.isEmpty == false }),
                  var queue = pending[tab.id] else { continue }
            let sheet = queue.removeFirst()
            pending[tab.id] = queue.isEmpty ? nil : queue
            window.visibleSheet = sheet
            sheet.alert.beginSheetModal(for: nsWindow) { [weak self, weak window] response in
                window?.visibleSheet = nil
                guard let self else { return sheet.completion(response) }
                if response == Self.deferredResponse {
                    self.pending[sheet.tabID, default: []].insert(sheet, at: 0)
                } else {
                    sheet.completion(response)
                }
                self.showNext()
            }
        }
    }

    /// Puts away the window's sheet once its tab has left the window's screen, as when the window selects another tab or another window takes the tab. The sheet shows again first when a window shows its tab.
    func deferSheet(of window: BrowserWindowModel) {
        guard let sheet = window.visibleSheet, !window.tabsOnScreen.contains(where: { $0.id == sheet.tabID }),
              let parent = sheet.alert.window.sheetParent else { return }
        parent.endSheet(sheet.alert.window, returnCode: Self.deferredResponse)
    }

    /// Gives a tab's sheets the safe answer, `.cancel`, including one a window shows: all of them when the tab closes, or only the page's dialogs when the engine cancels those. The queue changes first, so that ending a visible sheet does not show one that is going too.
    func cancel(for tab: Tab, pageDialogsOnly: Bool = false) {
        let queue = pending.removeValue(forKey: tab.id) ?? []
        let waiting = pageDialogsOnly ? queue.filter(\.isPageDialog) : queue
        let kept = pageDialogsOnly ? queue.filter { !$0.isPageDialog } : []
        if !kept.isEmpty { pending[tab.id] = kept }
        for window in windows() {
            guard let sheet = window.visibleSheet, sheet.tabID == tab.id, !pageDialogsOnly || sheet.isPageDialog,
                  let parent = sheet.alert.window.sheetParent else { continue }
            parent.endSheet(sheet.alert.window, returnCode: .cancel)
        }
        waiting.forEach { $0.completion(.cancel) }
    }

    /// Gives every sheet the safe answer, `.cancel`, including those windows show.
    func cancelAll() {
        let waiting = pending.values.flatMap { $0 }
        pending = [:]
        for window in windows() {
            guard let sheet = window.visibleSheet, let parent = sheet.alert.window.sheetParent else { continue }
            parent.endSheet(sheet.alert.window, returnCode: .cancel)
        }
        waiting.forEach { $0.completion(.cancel) }
    }
}
