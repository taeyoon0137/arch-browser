// Shows a tab's oldest prompt as a card over the tab's pane, in either kind of window and in each pane of a split view. The card hangs from 3 points above the page frame, in the window's margin, which a page cannot draw in, and comes down from behind that line; the dimming takes the page's events while the rest of the window works on. The tab's next prompt follows once the card has left, under the same dimming. A card that shows again, as after the user comes back to its tab, shows at once with its page.
import AppKit
import Combine
import SwiftUI

struct PanePromptLayer: View {
    /// How far the card reaches above the page frame into the window's margin.
    static let edgeOverlap: CGFloat = 3

    @ObservedObject var prompts: TabPromptQueue
    @ObservedObject var tab: Tab
    @EnvironmentObject private var windowModel: BrowserWindowModel
    /// Whether the window shows the tab's page now (`BrowserWindowModel.tabsOnScreen`).
    let isOnScreen: Bool
    /// Whether the pane is the window's focused pane, whose card alone takes the keys.
    let isFocusedPane: Bool
    /// Whether something covers the pane's page, an internal page or the preview panel, when the card waits.
    let isCovered: Bool
    /// The page frame's radius, or 0 while the page fills the window.
    let cornerRadius: CGFloat
    /// The room the card leaves at the pane's leading edge for the pane's close control, or 0 without one.
    let leadingClearance: CGFloat
    /// Selects the pane's tab, as a click on its page does.
    let selectPane: () -> Void

    /// The prompt the card shows, which lags the queue while a card leaves.
    @State private var displayed: PromptState?
    @State private var isArriving = false
    @State private var takesFocusOnShow = false
    @State private var focusRequests = 0
    @State private var hasFocus = false
    /// The next card, which arrives once the one before it has left.
    @State private var pendingShow: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The prompt the pane should show now.
    private var target: PromptState? {
        PromptPresentation.shownPrompt(in: prompts, tabID: tab.id, isOnScreen: isOnScreen, isCovered: isCovered)
    }

    /// Whether the find bar's or the question popover's field over the pane's page has the focus while the card does not. Only the focused pane has those fields.
    private var isPageFieldFocused: Bool {
        isFocusedPane && !hasFocus && !windowModel.focusedPageFields.isEmpty
    }

    var body: some View {
        let isDimmed = target != nil
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                ZStack {
                    if isDimmed {
                        PromptScrim(cornerRadius: cornerRadius, onMouseDown: activate)
                            .transition(.opacity)
                    }
                }
                .padding(.top, Self.edgeOverlap)
                .animation(PromptMotion.scrim(reduceMotion: reduceMotion), value: isDimmed)
                if let displayed {
                    PromptCard(state: displayed, width: PromptLayout.cardWidth(inPaneWidth: proxy.size.width - leadingClearance),
                               maxHeight: PromptLayout.maximumHeight(inPaneHeight: proxy.size.height), isFocusedPane: isFocusedPane,
                               isArriving: isArriving, takesFocusOnAppear: takesFocusOnShow, focusRequests: focusRequests,
                               onFocusChange: focusDidChange, onAnswer: { prompts.answer(displayed.id, with: $0) })
                        .padding(.leading, leadingClearance)
                        .simultaneousGesture(TapGesture().onEnded { if !isFocusedPane { activate() } })
                        .id(displayed.id)
                        .transition(PromptMotion.transition(reduceMotion: reduceMotion))
                        .zIndex(1)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height + Self.edgeOverlap, alignment: .top)
            // The card comes from behind the line 3 points above the page frame.
            .clipped()
            .offset(y: -Self.edgeOverlap)
        }
        .background(PromptFocusGuard(isEngaged: displayed != nil, pageView: tab.webContents.view, isPageFieldFocused: isPageFieldFocused,
                                     requestCardFocus: requestFocus).allowsHitTesting(false))
        .onAppear(perform: sync)
        .onChange(of: target?.id) { sync() }
        .onChange(of: isFocusedPane) { _, isFocused in
            if isFocused, displayed != nil { requestFocus() }
        }
        .onChange(of: windowModel.promptFocusRequests) {
            if isFocusedPane, displayed != nil { requestFocus() }
        }
        // The buttons that grant something arm again after the window comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let displayed, notification.object as? NSWindow === windowModel.nsWindow else { return }
            displayed.arming.restart(at: Date())
        }
        // A card whose content follows Arch's notification permission takes it again when the permission changes while it shows, as after the user turns notifications on in System Settings. `@Published` reports a change before the value changes, so the card takes it on the next turn of the main queue.
        .onReceive(windowModel.session.notificationAuthorization.$status.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)) { _ in
            displayed?.remake()
        }
        .onDisappear {
            pendingShow?.cancel()
            focusDidChange(false)
        }
    }

    // MARK: Showing and leaving

    /// Follows the queue: the card that should show arrives, and one that was answered leaves first. A card that only hides, as under an internal page, goes at once, and quitting takes every card at once. A card that waits for the one before it to leave waits no more once the pane should show another prompt or none, as when its page is covered meanwhile. The fields of a prompt that ended keep their text until its card has gone, and then let it go, so a password does not stay in memory.
    private func sync() {
        let next = target
        pendingShow?.cancel()
        pendingShow = nil
        guard next?.id != displayed?.id else { return }
        guard let current = displayed else { return show(next, afterFocusedCard: false) }
        let hadFocus = hasFocus
        let hasEnded = !prompts.contains(current.id)
        guard prompts.isAccepting, hasEnded else {
            withoutAnimation { displayed = nil }
            if hasEnded { current.fieldValues = [:] }
            return show(next, afterFocusedCard: false)
        }
        withAnimation(PromptMotion.departure(reduceMotion: reduceMotion)) { displayed = nil }
        let departure = PromptMotion.departureDuration(reduceMotion: reduceMotion)
        DispatchQueue.main.asyncAfter(deadline: .now() + departure) { current.fieldValues = [:] }
        guard let next else {
            // The tab has no more prompts, so the keys return to its page.
            if hadFocus { windowModel.focusPage() }
            return
        }
        let work = DispatchWorkItem { [prompts, tab] in
            guard prompts.current(for: tab.id)?.id == next.id else { return }
            show(next, afterFocusedCard: hadFocus)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + departure, execute: work)
    }

    /// Shows a card: the first time with its motion, after its page leaves fullscreen and the pane's region capture ends, and later at once. A prompt with a maker takes its content again each time, from what is true then, and again while it shows when Arch's notification permission changes, and the buttons that grant something arm again each time. The card takes the focus as the focus rules allow, or after the tab's card that had it, and VoiceOver announces one that shows without it.
    private func show(_ state: PromptState?, afterFocusedCard: Bool) {
        guard let state, prompts.isAccepting else { return }
        let isFirst = PromptPresentation.markAppeared(state)
        if isFirst {
            if windowModel.fullscreenTabID == tab.id { windowModel.exitPageFullscreen() }
            if windowModel.regionCaptureTabID == tab.id { windowModel.cancelRegionCapture() }
        }
        state.remake()
        state.arming.restart(at: Date())
        let takesFocus = afterFocusedCard || canTakeFocus()
        isArriving = isFirst
        takesFocusOnShow = takesFocus
        if isFirst {
            withAnimation(PromptMotion.arrival(reduceMotion: reduceMotion)) { displayed = state }
        } else {
            withoutAnimation { displayed = state }
        }
        if isFirst, !takesFocus { announce(state) }
    }

    /// The focus rules for a card that shows (`PromptPresentation.takesFocus`). While the palette is open, its field keeps the keys, and closing it gives them to the card (`BrowserWindowModel.focusPage()`). Before the window is known, as when the window first shows with its tab's card, the focused pane's card takes it, as selecting a tab gives it.
    private func canTakeFocus() -> Bool {
        guard windowModel.commandPaletteMode == nil else { return false }
        guard let window = windowModel.nsWindow else { return isFocusedPane }
        return PromptPresentation.takesFocus(firstResponder: window.firstResponder, pageView: tab.webContents.view, window: window,
                                             isFocusedPane: isFocusedPane, isPageFieldFocused: isPageFieldFocused)
    }

    private func announce(_ state: PromptState) {
        let content = state.content
        let subject = content.title ?? content.pageText.map { String($0.text.prefix(200)) } ?? content.kind.accessibilityName
        AccessibilityNotification.Announcement("\(content.identity.name) asks: \(subject)").post()
    }

    // MARK: Focus

    private func requestFocus() {
        focusRequests += 1
    }

    /// A click on the dimming or on another pane's card selects the pane's tab and gives the card the focus.
    private func activate() {
        selectPane()
        requestFocus()
    }

    /// The window knows which tab's card has the focus, so the floating sidebar does not count a card's field as sidebar text being edited.
    private func focusDidChange(_ isFocused: Bool) {
        hasFocus = isFocused
        if isFocused {
            if windowModel.focusedPromptTabID != tab.id { windowModel.focusedPromptTabID = tab.id }
        } else if windowModel.focusedPromptTabID == tab.id {
            windowModel.focusedPromptTabID = nil
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}
