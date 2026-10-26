// Where a window's dock puts developer tools that the engine shows in a view: beside the page on the shared side, or in a window of their own while they float, and what every dock and window learn when the tools close.
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
        #expect(window.title == "Developer Tools \u{2013} Example")
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

/// Dock settings in defaults of their own for one test, removed when the test ends.
private final class TemporaryDefaults {
    private let name = "ArchDevToolsDockTests-\(UUID().uuidString)"
    let settings: DevToolsDockSettings

    init() {
        settings = DevToolsDockSettings(defaults: UserDefaults(suiteName: name)!)
    }

    deinit {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
}
