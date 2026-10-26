// Which view of a page's engine view a window focuses: the engine view when it takes focus, as on WebKit, or else the topmost visible view inside it that does, as the current page's view within CEF's view, which takes none.
import AppKit
import Testing
@testable import Browsing

@MainActor
@Suite struct PageFocusTests {
    /// A view that takes focus, as WebKit's page view and Chromium's page view do.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Chromium's tab: the adapter's container, a picture-in-picture source view below CEF's view, and inside CEF's view Chromium's contents view around its page view, the only view that takes focus.
    @MainActor private struct ChromiumTab {
        let container = NSView()
        let sourceView = NSView()
        let cefView = NSView()
        let contentsView = NSView()
        let pageView = FocusableView()

        init() {
            contentsView.addSubview(pageView)
            cefView.addSubview(contentsView)
            container.addSubview(sourceView)
            container.addSubview(cefView)
        }
    }

    @Test func anEngineViewThatTakesFocusTakesItItself() {
        let pageView = FocusableView()
        pageView.addSubview(FocusableView())
        #expect(BrowserWindowModel.viewTakingFocus(in: pageView) === pageView)
    }

    @Test func aChromiumTabGivesFocusToItsPageViewInsideCEFsView() {
        let tab = ChromiumTab()
        #expect(BrowserWindowModel.viewTakingFocus(in: tab.container) === tab.pageView)
    }

    @Test func thePageAboveTakesFocusBeforeAViewBelowIt() {
        let tab = ChromiumTab()
        tab.sourceView.addSubview(FocusableView())
        #expect(BrowserWindowModel.viewTakingFocus(in: tab.container) === tab.pageView)
    }

    /// Chromium adds the current page's view below the others and keeps the view of a page left for another site, hidden, while that page is in the back-forward cache.
    @Test func aHiddenPageLeftAboveTheCurrentPageTakesNoFocus() {
        let tab = ChromiumTab()
        let previousPageView = FocusableView()
        previousPageView.isHidden = true
        tab.contentsView.addSubview(previousPageView)
        #expect(BrowserWindowModel.viewTakingFocus(in: tab.container) === tab.pageView)
    }

    @Test func aPageWhoseViewIsHiddenStillGivesItFocus() {
        let tab = ChromiumTab()
        tab.pageView.isHidden = true
        #expect(BrowserWindowModel.viewTakingFocus(in: tab.container) === tab.pageView)
        tab.cefView.isHidden = true
        #expect(BrowserWindowModel.viewTakingFocus(in: tab.container) === tab.pageView)
    }

    @Test func aPageWithoutAViewThatTakesFocusLeavesItToTheWindow() {
        let tab = ChromiumTab()
        tab.pageView.removeFromSuperview()
        #expect(BrowserWindowModel.viewTakingFocus(in: tab.container) == nil)
        #expect(BrowserWindowModel.viewTakingFocus(in: NSView()) == nil)
    }

    @Test func theWindowFocusesThatViewAndNotCEFsView() {
        let tab = ChromiumTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(tab.container)
        window.makeFirstResponder(BrowserWindowModel.viewTakingFocus(in: tab.container))
        #expect(window.firstResponder === tab.pageView)
        // AppKit makes a view that takes no focus the first responder when asked, so the choice is the app's.
        window.makeFirstResponder(tab.cefView)
        #expect(window.firstResponder === tab.cefView)
    }
}
