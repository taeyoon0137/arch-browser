// The prompts that tabs ask for: a page's own dialogs, permission questions, logins, leave-page checks, links for other apps, extensions' questions, file choosers, and the app's notices about a page. Each tab's prompts wait in order, and a window shows a tab's oldest one as a card over the tab's pane while the tab is on its screen (`PanePromptLayer`), or a file chooser's panel as a sheet on the window, so a prompt never covers another tab's page and a background tab's prompt waits until the tab shows.
import AppKit
import Combine
import SwiftUI

final class TabPromptQueue: ObservableObject {
    /// The prompts of each tab, oldest first. The first is the one a card shows.
    @Published private(set) var waiting: [UUID: [PromptState]] = [:]
    /// Each waiting prompt's completion, which runs once.
    private var completions: [PromptState.ID: (PromptResponse) -> Void] = [:]
    /// False while Arch quits, when every new prompt ends at once.
    private(set) var isAccepting = true

    /// Adds a prompt after the tab's others, with `content`, or, with `makeContent`, the content that it makes each time a card shows the prompt (`PromptState.remake()`). While Arch quits, it ends at once with `.dismissed`.
    func enqueue(_ content: PromptContent, panel: NSSavePanel? = nil, for tabID: UUID, makeContent: (() -> PromptContent)? = nil, completion: @escaping (PromptResponse) -> Void) {
        guard isAccepting else { return completion(.dismissed) }
        let state = PromptState(tabID: tabID, content: content, panel: panel, makeContent: makeContent)
        completions[state.id] = completion
        waiting[tabID, default: []].append(state)
    }

    /// The tab's oldest prompt, the one a card shows.
    func current(for tabID: UUID) -> PromptState? {
        waiting[tabID]?.first
    }

    func hasPrompt(for tabID: UUID?) -> Bool {
        tabID.map { waiting[$0]?.isEmpty == false } ?? false
    }

    /// Whether the prompt still waits for its answer.
    func contains(_ id: PromptState.ID) -> Bool {
        completions[id] != nil
    }

    /// Ends the prompt a card shows with the user's answer. The prompt leaves the queue before its completion runs, so a prompt the completion asks for comes after the tab's others. A prompt that has ended, or one that is not first for its tab, is left alone. The queue lets go of an ended prompt, and the card that showed it clears its fields once it has gone (`PanePromptLayer`).
    func answer(_ id: PromptState.ID, with answer: PromptAnswer) {
        guard let (tabID, queue) = waiting.first(where: { $0.value.first?.id == id }) else { return }
        waiting[tabID] = queue.count > 1 ? Array(queue.dropFirst()) : nil
        let completion = completions.removeValue(forKey: id)
        completion?(.answered(answer))
    }

    /// Ends the tab's prompts without the user, oldest first: all of them when the tab closes or switches engines, or only the page's own dialogs when the engine cancels those. The queue changes before any completion runs.
    func dismiss(tabID: UUID, pageDialogsOnly: Bool = false) {
        guard let queue = waiting[tabID] else { return }
        let ending = pageDialogsOnly ? queue.filter(\.content.kind.isPageDialog) : queue
        guard !ending.isEmpty else { return }
        let kept = pageDialogsOnly ? queue.filter { !$0.content.kind.isPageDialog } : []
        waiting[tabID] = kept.isEmpty ? nil : kept
        finish(ending)
    }

    /// Readies the tab for a close the user asked for, and says whether the close goes on: while the tab's leave-page card shows, that card is the question, so nothing changes and the close stops; otherwise the tab's prompts end, so that a page that waits on its own dialog can answer its `beforeunload` check.
    func endForClose(tabID: UUID) -> Bool {
        guard current(for: tabID)?.content.kind != .leavePage else { return false }
        dismiss(tabID: tabID)
        return true
    }

    /// Quitting: ends every tab's prompts without the user, each tab's oldest first, and the ones asked for until `reopen()`. Their cards go at once, without their motion. A file chooser's panel that shows as a sheet ends first with Cancel, which answers its prompt (`PanePromptLayer`), before AppKit decides whether to quit, since AppKit stops a quit for a sheet with more than one button and the card's view would end the panel only at its next update.
    func close() {
        isAccepting = false
        for panel in waiting.values.flatMap({ $0 }).compactMap(\.panel) {
            panel.sheetParent?.endSheet(panel, returnCode: .cancel)
        }
        let ending = waiting
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { waiting = [:] }
        ending.values.forEach(finish)
    }

    /// The quit did not happen, as when a window's own sheet held it, so prompts wait for answers again.
    func reopen() {
        isAccepting = true
    }

    private func finish(_ states: [PromptState]) {
        let handlers = states.map { completions.removeValue(forKey: $0.id) }
        handlers.forEach { $0?(.dismissed) }
    }
}
