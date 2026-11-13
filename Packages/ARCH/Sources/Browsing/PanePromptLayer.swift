// Shows a tab's oldest prompt as a card over the tab's pane, in either kind of window and in each pane of a split view. The card hangs from 3 points above the page frame, in the window's margin, which a page cannot draw in, and comes down from behind that line; the dimming takes the page's events while the rest of the window works on. The tab's next prompt follows once the card has left, under the same dimming. A card that shows again, as after the user comes back to its tab, shows at once with its page.
import AppKit
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
    /// Whether an internal page covers the pane, when the card waits.
    let isCovered: Bool
    /// The page frame's radius, or 0 while the page fills the window.
    let cornerRadius: CGFloat
    /// Selects the pane's tab, as a click on its page does.
    let selectPane: () -> Void

    /// The prompt the card shows, which lags the queue while a card leaves.
    @State private var displayed: PromptState?
    @State private var isArriving = false
    @State private var takesFocusOnShow = false
    @State private var focusRequests = 0
    @State private var hasFocus = false
    @State private var cardFrame = CGRect.zero
    /// The view that covers the pane, which focus checks measure against.
    @State private var paneView: NSView?
    /// The next card, which arrives once the one before it has left.
    @State private var pendingShow: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "PanePromptLayer"

    /// The prompt the pane should show now.
    private var target: PromptState? {
        PromptPresentation.shownPrompt(in: prompts, tabID: tab.id, isOnScreen: isOnScreen, isCoveredByInternalPage: isCovered)
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
                    PromptCard(state: displayed, width: PromptLayout.cardWidth(inPaneWidth: proxy.size.width),
                               maxHeight: PromptLayout.maximumHeight(inPaneHeight: proxy.size.height), isFocusedPane: isFocusedPane,
                               isArriving: isArriving, takesFocusOnAppear: takesFocusOnShow, focusRequests: focusRequests,
                               onFocusChange: focusDidChange, onAnswer: { prompts.answer(displayed.id, with: $0) })
                        .simultaneousGesture(TapGesture().onEnded { if !isFocusedPane { activate() } })
                        .background(GeometryReader { card in
                            Color.clear.preference(key: PromptCardFrameKey.self, value: card.frame(in: .named(Self.space)))
                        })
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
        .coordinateSpace(name: Self.space)
        .background(PromptFocusGuard(isEngaged: displayed != nil, cardFrame: cardFrame, requestCardFocus: requestFocus) { paneView = $0 }.allowsHitTesting(false))
        .onPreferenceChange(PromptCardFrameKey.self) { cardFrame = $0 }
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
        .onDisappear {
            pendingShow?.cancel()
            focusDidChange(false)
        }
    }

    // MARK: Showing and leaving

    /// Follows the queue: the card that should show arrives, and one that was answered leaves first. A card that only hides, as under an internal page, goes at once, and quitting takes every card at once.
    private func sync() {
        let next = target
        guard next?.id != displayed?.id else { return }
        pendingShow?.cancel()
        pendingShow = nil
        guard let current = displayed else { return show(next, afterFocusedCard: false) }
        let hadFocus = hasFocus
        guard prompts.isAccepting, !prompts.contains(current.id) else {
            withoutAnimation { displayed = nil }
            return show(next, afterFocusedCard: false)
        }
        withAnimation(PromptMotion.departure(reduceMotion: reduceMotion)) { displayed = nil }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + PromptMotion.departureDuration(reduceMotion: reduceMotion), execute: work)
    }

    /// Shows a card: the first time with its motion, after its page leaves fullscreen and the pane's region capture ends, and later at once. The buttons that grant something arm again each time. The card takes the focus as the focus rules allow, or after the tab's card that had it, and VoiceOver announces one that shows without it.
    private func show(_ state: PromptState?, afterFocusedCard: Bool) {
        guard let state, prompts.isAccepting else { return }
        let isFirst = PromptPresentation.markAppeared(state)
        if isFirst {
            if windowModel.fullscreenTabID == tab.id { windowModel.exitPageFullscreen() }
            if windowModel.regionCaptureTabID == tab.id { windowModel.cancelRegionCapture() }
        }
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

    /// The focus rules for a card that shows (`PromptPresentation.takesFocus`). Before the pane's view is known, as when the pane first shows with its tab's card, the focused pane's card takes it, as selecting a tab gives it.
    private func canTakeFocus() -> Bool {
        guard let paneView, let window = windowModel.nsWindow else { return isFocusedPane }
        return PromptPresentation.takesFocus(firstResponder: window.firstResponder, pane: paneView, window: window, isFocusedPane: isFocusedPane)
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

/// The card's frame in its layer, which the focus guard lets keep the focus.
private struct PromptCardFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
