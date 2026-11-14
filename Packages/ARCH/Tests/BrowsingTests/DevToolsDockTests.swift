// Where a window's dock puts developer tools that the engine shows in a view: beside the page on the shared side, or in a window of their own while they float, what every dock and window learn when the tools close, and the size docked tools show at in the page area.
import AppKit
import ARCHEngine
import Combine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct DevToolsDockTests {
    private let defaults = TemporaryDefaults()
    private let windows = DevToolsUndockedWindows(frameName: nil)
    private let titles = Just("Example").eraseToAnyPublisher()
    private var settings: DevToolsDockSettings { defaults.settings }

    private func makeDock() -> DevToolsDock {
        DevToolsDock(settings: settings, undockedWindows: windows)
    }

    @Test func openToolsDockOnTheSharedSide() {
        let dock = makeDock()
        let tools = FakeDevTools()
        dock.track(tools, titles: titles)
        #expect(dock.dockedSide == nil)
        tools.open()
        #expect(dock.view === tools.view)
        #expect(dock.dockedSide == .right)
        settings.side = .bottom
        #expect(dock.dockedSide == .bottom)
        #expect(windows.windows.isEmpty)
    }

    @Test func undockMovesTheSameViewIntoAWindowAndBack() throws {
        let dock = makeDock()
        let tools = FakeDevTools()
        dock.track(tools, titles: titles)
        tools.open()
        let view = try #require(tools.view)
        settings.side = .floating
        let window = try #require(windows.window(of: tools))
        #expect(view.superview === window.contentView)
        #expect(window.title == "Developer Tools \u{2014} Example")
        #expect(dock.dockedSide == nil)
        settings.side = .left
        #expect(windows.window(of: tools) == nil)
        #expect(view.superview == nil)
        #expect(dock.view === view)
        #expect(dock.dockedSide == .left)
    }

    @Test func toolsThatOpenWhileUndockedOpenInAWindow() throws {
        settings.side = .floating
        let dock = makeDock()
        let tools = FakeDevTools()
        dock.track(tools, titles: titles)
        tools.open()
        let window = try #require(windows.window(of: tools))
        #expect(tools.view?.superview === window.contentView)
        #expect(dock.dockedSide == nil)
        tools.finishClosing()
        #expect(windows.windows.isEmpty)
    }

    @Test func theWindowsCloseButtonClosesTheToolsBeforeTheWindow() throws {
        settings.side = .floating
        let dock = makeDock()
        let tools = FakeDevTools()
        dock.track(tools, titles: titles)
        tools.open()
        let window = try #require(windows.window(of: tools))
        #expect(!windows.windowShouldClose(window))
        #expect(tools.closeRequests == 1)
        #expect(windows.window(of: tools) === window)
        tools.finishClosing()
        #expect(windows.window(of: tools) == nil)
        #expect(dock.view == nil)
    }

    @Test func floatingToolsKeepTheirWindowWhenAnotherTabIsSelected() {
        settings.side = .floating
        let dock = makeDock()
        let tools = FakeDevTools()
        let other = FakeDevTools()
        dock.track(tools, titles: titles)
        tools.open()
        dock.track(other, titles: titles)
        #expect(windows.window(of: tools) != nil)
        #expect(dock.view == nil)
        // Their tab is selected in no window, and their close still takes their window.
        tools.finishClosing()
        #expect(windows.window(of: tools) == nil)
    }

    @Test func floatingToolsAreFoundByTheirWindowAndDockFromItWhileTheirTabIsHidden() throws {
        settings.side = .floating
        let dock = makeDock()
        let tools = FakeDevTools()
        let other = FakeDevTools()
        dock.track(tools, titles: titles)
        tools.open()
        let window = try #require(windows.window(of: tools))
        dock.track(other, titles: titles)
        // The Developer menu finds the tools by their key window, not by the tab the dock follows.
        #expect(windows.devTools(in: window) === tools)
        #expect(windows.devTools(in: NSWindow()) == nil)
        #expect(windows.devTools(in: nil) == nil)
        // A side change alone leaves the tools of a hidden tab in their window. Chosen from that window, it docks them.
        settings.side = .right
        #expect(windows.window(of: tools) === window)
        windows.dock(tools)
        #expect(windows.devTools(in: window) == nil)
        #expect(tools.view?.superview == nil)
        #expect(tools.isOpen)
        dock.track(tools, titles: titles)
        #expect(dock.view === tools.view)
        #expect(dock.dockedSide == .right)
    }

    @Test func dockedToolsOfATabLeftBehindLeaveThePageAreaUntilItReturns() {
        let dock = makeDock()
        let tools = FakeDevTools()
        let other = FakeDevTools()
        dock.track(tools, titles: titles)
        tools.open()
        dock.track(other, titles: titles)
        #expect(dock.view == nil)
        other.open()
        #expect(dock.view === other.view)
        dock.track(tools, titles: titles)
        #expect(dock.view === tools.view)
        #expect(windows.windows.isEmpty)
    }

    @Test func theDockOfTheWindowATabMovesToLearnsOfItsToolsClosingAndOpening() {
        let first = makeDock()
        let second = makeDock()
        let tools = FakeDevTools()
        first.track(tools, titles: titles)
        tools.open()
        // The first window gives the tab up before the second shows it.
        first.track(nil, titles: titles)
        second.track(tools, titles: titles)
        #expect(second.view === tools.view)
        tools.finishClosing()
        #expect(second.view == nil)
        tools.open()
        #expect(second.view === tools.view)
        #expect(first.view == nil)
    }

    @Test func dockedToolsShowAtTheirSavedSizeOnlyWhileThePageKeepsItsRoom() {
        let page = DevToolsDock.minimumPageSize
        #expect(DevToolsDock.shownSize(480, in: 1200) == 480)
        // A size saved in a wider window, or dragged past the window's edge, leaves the page its least size.
        #expect(DevToolsDock.shownSize(1200, in: 900) == 900 - page)
        #expect(DevToolsDock.shownSize(5000, in: 900) == 900 - page)
        // The tools keep their own least size before the page does, and never grow past the room.
        #expect(DevToolsDock.shownSize(480, in: 300) == DevToolsDock.minimumSize)
        #expect(DevToolsDock.shownSize(480, in: 150) == 150)
        #expect(DevToolsDock.shownSize(480, in: -20) == 0)
        #expect(DevToolsDock.shownSize(50, in: 1200) == DevToolsDock.minimumSize)
    }
}

/// Tools that open in a new view at once and close only when the test finishes closing them, as CEF reports a close on a later task.
private final class FakeDevTools: EngineDevTools {
    private(set) var view: NSView?
    var didChangeView: (() -> Void)?
    var isPlacedByApp: Bool { true }
    var isOpen: Bool { view != nil }
    private(set) var closeRequests = 0

    func open() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        didChangeView?()
    }

    func close() { closeRequests += 1 }

    func finishClosing() {
        view = nil
        didChangeView?()
    }

    func openConsoleView() { open() }
    func openInspectView() { open() }
    func openNetworkView() { open() }
}

/// Dock settings in defaults of their own for one test, named after the checkout and the test and emptied when it starts and when it ends. macOS keeps an empty file for a removed domain, so each test reuses its name on every run in a checkout.
private final class TemporaryDefaults {
    private let name = "test.arch.devtools-dock.\(checkoutID).\(Test.current.map { String($0.name.prefix { $0 != "(" }) } ?? UUID().uuidString)"
    let settings: DevToolsDockSettings

    init() {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        settings = DevToolsDockSettings(defaults: defaults)
    }

    deinit {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
}

/// A part of the defaults names that stays the same on every run in a checkout and differs between checkouts, so that runs in two checkouts at the same time keep apart, while SwiftPM runs one command at a time in a checkout's build folder: a hash of this file's path.
private let checkoutID = String(#filePath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 36)
