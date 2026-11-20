// Developer tools for a window's selected tab dock beside the page or open in their own window.
// Docked tools use a side and size shared by the app's windows. The engine hosts them inside a view, and the page area makes room on that side.
// Undock moves the same view to an app window, preserving the tools' state.
import AppKit
import ARCHEngine
import Combine
import SwiftUI

/// A dock edge for developer tools, or a separate floating window.
public enum DevToolsSide: String, CaseIterable {
    case right, bottom, left
    /// The tools keep a window of their own.
    case floating

    public var title: String {
        switch self {
        case .right: return "Dock to Right"
        case .bottom: return "Dock to Bottom"
        case .left: return "Dock to Left"
        case .floating: return "Undock"
        }
    }
}

/// The side and sizes of docked developer tools, which every window's dock shares, saved in `UserDefaults`. The Developer menu sets the side.
public final class DevToolsDockSettings: ObservableObject {
    public static let shared = DevToolsDockSettings(defaults: .standard)

    @Published public var side: DevToolsSide {
        didSet { defaults.set(side.rawValue, forKey: Self.sideKey) }
    }
    /// The tools' width beside the page.
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Self.widthKey) }
    }
    /// The tools' height below the page.
    @Published var height: CGFloat {
        didSet { defaults.set(Double(height), forKey: Self.heightKey) }
    }

    private let defaults: UserDefaults
    private static let sideKey = "ARCHDevToolsSide"
    private static let widthKey = "ARCHDevToolsWidth"
    private static let heightKey = "ARCHDevToolsHeight"

    /// Restores the shared dock side and dimensions from the supplied defaults.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        side = defaults.string(forKey: Self.sideKey).flatMap(DevToolsSide.init(rawValue:)) ?? .right
        width = CGFloat(defaults.object(forKey: Self.widthKey) as? Double ?? 480)
        height = CGFloat(defaults.object(forKey: Self.heightKey) as? Double ?? 320)
    }
}

/// The view of one browser window's selected tab's tools, placed on the shared side (`DevToolsDockSettings`): in the window's page area, or in the tools' own window while they float.
public final class DevToolsDock: ObservableObject {
    /// The selected tab's tools' view while they are open.
    @Published private(set) var view: NSView?

    private let settings: DevToolsDockSettings
    private let undockedWindows: DevToolsUndockedWindows
    private var observers: Set<AnyCancellable> = []
    private weak var devTools: (any EngineDevTools)?
    /// The titles of the tools' tab, which name the tools' window while they float.
    private var titles: AnyPublisher<String, Never> = Empty().eraseToAnyPublisher()

    /// The least width or height of docked tools, and the least content size of their window.
    static let minimumSize: CGFloat = 200
    /// The least width or height that docked tools leave the page beside them.
    static let minimumPageSize: CGFloat = 200

    /// The size docked tools show at in `room`, the page area's length along their side less the page's margins and the margin between the page and the tools: the saved size, or less so that the page keeps `minimumPageSize`, but not below `minimumSize` unless `room` itself is smaller. A size saved in a larger window then fits a smaller one, and a drag cannot push the page or the handle out of the window.
    static func shownSize(_ saved: CGFloat, in room: CGFloat) -> CGFloat {
        max(0, min(room, max(minimumSize, min(saved, room - minimumPageSize))))
    }

    /// Follows shared placement changes and floating tool windows.
    init(settings: DevToolsDockSettings = .shared, undockedWindows: DevToolsUndockedWindows = .shared) {
        self.settings = settings
        self.undockedWindows = undockedWindows
        // A side chosen in any window applies to this one at once. The settings publish a new side before they store it, so the placement takes the side it receives.
        settings.$side.dropFirst().sink { [weak self] side in self?.place(on: side) }.store(in: &observers)
        // Every dock that follows the tools learns that they opened or closed, whichever dock followed them first.
        undockedWindows.viewDidChange.sink { [weak self] devTools in
            guard let self, devTools === self.devTools else { return }
            self.view = devTools.view
            self.place(on: self.settings.side)
        }.store(in: &observers)
    }

    /// The side the page makes room on, or nil while the selected tab's tools are closed or float.
    var dockedSide: DevToolsSide? { view != nil && settings.side != .floating ? settings.side : nil }

    /// Follows the tools of `tab`, the window's selected tab, or none.
    @MainActor func track(_ tab: Tab?) {
        track(tab?.webContents.devTools, titles: tab.map(Self.titles(of:)) ?? Empty().eraseToAnyPublisher())
    }

    /// Follows `devTools`, whose window takes the names that `titles` sends while they float. The docked tools of the tab left behind leave the page area until their tab returns; floating tools keep their window.
    func track(_ devTools: (any EngineDevTools)?, titles: AnyPublisher<String, Never>) {
        guard devTools !== self.devTools else { return }
        self.devTools = devTools
        self.titles = titles
        if let devTools { undockedWindows.follow(devTools) }
        view = devTools?.view
        place(on: settings.side)
    }

    /// Shows the open tools' view in their own window on `.floating`. On another side their window gives the view back, and the page area's dock space takes it.
    private func place(on side: DevToolsSide) {
        guard let devTools, devTools.view != nil else { return }
        if side == .floating {
            undockedWindows.show(devTools, titles: titles)
        } else {
            undockedWindows.dock(devTools)
        }
    }

    /// The floating tools whose window is `window`, or nil for any other window, such as a browser window. While their window is key, the Developer menu acts on them, whichever tab the active window shows.
    public static func floatingDevTools(in window: NSWindow?) -> (any EngineDevTools)? {
        DevToolsUndockedWindows.shared.devTools(in: window)
    }

    /// Gives floating tools' view back to the page area and closes their window. They show beside their tab's page while a window selects the tab.
    public static func dock(_ devTools: any EngineDevTools) {
        DevToolsUndockedWindows.shared.dock(devTools)
    }

    /// The tab's title as it changes. The tab announces a change before it makes it, so the title is read on the next turn of the run loop.
    @MainActor private static func titles(of tab: Tab) -> AnyPublisher<String, Never> {
        tab.objectWillChange
            .receive(on: DispatchQueue.main)
            .compactMap { [weak tab] _ in tab?.shownTitle }
            .prepend(tab.shownTitle)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

/// The windows of floating developer tools, one for each tools view, and the one listener of each tools object's view changes, which tells every dock. The tools' tab may be selected in no window while they float.
final class DevToolsUndockedWindows: NSObject, NSWindowDelegate {
    static let shared = DevToolsUndockedWindows(frameName: "ARCHDevToolsWindow")

    /// Sends the tools whose view opened or closed.
    let viewDidChange = PassthroughSubject<any EngineDevTools, Never>()
    /// The tools' windows, oldest first.
    private(set) var windows: [DevToolsWindow] = []
    /// The name the windows' frame is saved under, or nil to save none.
    private let frameName: String?

    init(frameName: String?) {
        self.frameName = frameName
    }

    /// Listens to the tools from the first time a dock follows them. The dock that shows their tab, other docks that followed them, and their window then all learn of a close.
    func follow(_ devTools: any EngineDevTools) {
        guard devTools.didChangeView == nil else { return }
        devTools.didChangeView = { [weak self, weak devTools] in
            guard let self, let devTools else { return }
            // A window shows only the view it was given, so a closed view closes it.
            if let window = self.window(of: devTools), window.toolsView !== devTools.view { window.close() }
            self.viewDidChange.send(devTools)
        }
    }

    /// The window of the tools while they float.
    func window(of devTools: any EngineDevTools) -> DevToolsWindow? {
        windows.first { $0.devTools === devTools }
    }

    /// The tools that `window` shows while they float, or nil for any other window.
    func devTools(in window: NSWindow?) -> (any EngineDevTools)? {
        windows.first { $0 === window }?.devTools
    }

    /// Moves the tools' view into their window, named after their tab. A new window comes forward at the saved frame, cascaded from the last tools window.
    func show(_ devTools: any EngineDevTools, titles: AnyPublisher<String, Never>) {
        guard let view = devTools.view else { return }
        let window = window(of: devTools) ?? makeWindow(for: devTools)
        window.follow(titles)
        guard let content = window.contentView, view.superview !== content else { return }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        window.toolsView = view
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    /// Gives the tools' view back to the page area and closes their window.
    func dock(_ devTools: any EngineDevTools) {
        guard let window = window(of: devTools) else { return }
        if let view = window.toolsView, view.superview === window.contentView { view.removeFromSuperview() }
        window.close()
    }

    /// Creates and positions a floating window for a tools view.
    private func makeWindow(for devTools: any EngineDevTools) -> DevToolsWindow {
        let window = DevToolsWindow(devTools: devTools)
        if !(frameName.map { window.setFrameUsingName($0) } ?? false) { window.center() }
        if let last = windows.last {
            // The first call puts the window on the last one and returns the next cascade point.
            window.cascadeTopLeft(from: window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        // The saved frame follows the user's moves, not this placement.
        window.delegate = self
        windows.append(window)
        return window
    }

    /// The close button closes the tools. Their window closes once they have.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let devTools = (sender as? DevToolsWindow)?.devTools, devTools.view != nil else { return true }
        devTools.close()
        return false
    }

    /// Saves a tools window's frame and removes it from the floating list.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? DevToolsWindow else { return }
        saveFrame(of: window)
        windows.removeAll { $0 === window }
    }

    func windowDidMove(_ notification: Notification) { saveFrame(of: notification.object as? NSWindow) }
    func windowDidResize(_ notification: Notification) { saveFrame(of: notification.object as? NSWindow) }

    private func saveFrame(of window: NSWindow?) {
        if let frameName { window?.saveFrame(usingName: frameName) }
    }
}

/// The window of one tools view while the tools float. The Window menu lists it under its title.
final class DevToolsWindow: NSWindow {
    private(set) weak var devTools: (any EngineDevTools)?
    /// The view the window was given, until the page area takes it back.
    weak var toolsView: NSView?
    private var titleObserver: AnyCancellable?

    convenience init(devTools: any EngineDevTools) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        self.devTools = devTools
        title = Self.title(for: nil)
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        contentMinSize = NSSize(width: DevToolsDock.minimumSize, height: DevToolsDock.minimumSize)
    }

    /// Names the window after the tools' tab as its title changes.
    func follow(_ titles: AnyPublisher<String, Never>) {
        titleObserver = titles.sink { [weak self] in self?.title = Self.title(for: $0) }
    }

    /// Names the tools window, including the page title when available.
    static func title(for pageTitle: String?) -> String {
        pageTitle.map { "Developer Tools \u{2014} \($0)" } ?? "Developer Tools"
    }
}

/// Makes room for docked developer tools beside the page: the page narrows by the tools' size, and the tools' view fills the free space in the page's rounded frame. The margin between the page and the tools is a handle that resizes them. The tools show at their shared size, made to fit the page area (`DevToolsDock.shownSize(_:in:)`), so the page area never grows past the window.
struct DevToolsDockSpace: ViewModifier {
    @ObservedObject var dock: DevToolsDock
    let isHidden: Bool
    /// The page's margins, which the tools repeat on their outer edges.
    let margins: EdgeInsets
    /// The side and sizes, which every window's tools share.
    @ObservedObject var settings = DevToolsDockSettings.shared

    private var side: DevToolsSide? { isHidden ? nil : dock.dockedSide }

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let room = side.map { self.room(for: $0, in: proxy.size) } ?? 0
            let size = DevToolsDock.shownSize(side == .bottom ? settings.height : settings.width, in: room)
            content
                .padding(side == .right ? .trailing : side == .left ? .leading : .bottom, side == nil ? 0 : size + gap(for: side!))
                .overlay(alignment: alignment) { if let side { space(for: side, size: size, room: room) } }
        }
    }

    private var alignment: Alignment { side == .left ? .leading : side == .bottom ? .bottom : .trailing }

    /// The length that the page and the tools share along the tools' side of the page area, `size`: the page area's length less the page's margins on that axis and the margin between the page and the tools.
    private func room(for side: DevToolsSide, in size: CGSize) -> CGFloat {
        side == .bottom ? size.height - margins.top - margins.bottom - gap(for: side) : size.width - margins.leading - margins.trailing - gap(for: side)
    }

    /// The page's own margin on that side already separates it from the tools, so only the tools' outer margin is added.
    private func gap(for side: DevToolsSide) -> CGFloat {
        switch side {
        case .left: return margins.leading
        case .bottom: return margins.bottom
        default: return margins.trailing
        }
    }

    /// The tools at `size`, the size they show at in `room`, with the handle that resizes them within it.
    @ViewBuilder private func space(for side: DevToolsSide, size: CGFloat, room: CGFloat) -> some View {
        switch side {
        case .bottom:
            VStack(spacing: 0) {
                DevToolsResizeHandle(axis: .vertical, size: $settings.height, shownSize: size, room: room, sign: -1)
                    .frame(height: margins.bottom)
                WebContentsHostView(contentView: dock.view)
                    .modifier(DevToolsFrame())
                    .frame(height: size)
            }
            .padding(EdgeInsets(top: 0, leading: margins.leading, bottom: margins.bottom, trailing: margins.trailing))
        case .left:
            HStack(spacing: 0) {
                WebContentsHostView(contentView: dock.view)
                    .modifier(DevToolsFrame())
                    .frame(width: size)
                DevToolsResizeHandle(axis: .horizontal, size: $settings.width, shownSize: size, room: room, sign: 1)
                    .frame(width: margins.leading)
            }
            .padding(EdgeInsets(top: margins.top, leading: margins.leading, bottom: margins.bottom, trailing: 0))
        default:
            HStack(spacing: 0) {
                DevToolsResizeHandle(axis: .horizontal, size: $settings.width, shownSize: size, room: room, sign: -1)
                    .frame(width: margins.trailing)
                WebContentsHostView(contentView: dock.view)
                    .modifier(DevToolsFrame())
                    .frame(width: size)
            }
            .padding(EdgeInsets(top: margins.top, leading: 0, bottom: margins.bottom, trailing: margins.trailing))
        }
    }
}

/// The page's rounded frame around docked tools: the page's background and shadow under the engine's view, and the page's faint edge over it.
private struct DevToolsFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(PageBackgroundView(isEmpty: false))
            .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
    }
}

/// The margin between the page and the tools. Dragging it resizes the tools from the size they show at, within `room` as `DevToolsDock.shownSize(_:in:)` limits it, and saves the result; `sign` is -1 where dragging toward the page enlarges them.
private struct DevToolsResizeHandle: View {
    let axis: Axis
    /// The saved size, which every window's tools share.
    @Binding var size: CGFloat
    /// The size the tools show at, which a smaller window makes less than the saved one.
    let shownSize: CGFloat
    let room: CGFloat
    let sign: CGFloat
    @State private var startSize: CGFloat?
    /// Whether the handle has pushed the resize pointer, which it pops once.
    @State private var hasPushedCursor = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .accessibilityLabel("Resize Developer Tools")
            .onHover { isInside in
                guard isInside != hasPushedCursor else { return }
                hasPushedCursor = isInside
                if isInside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            // Closing the tools removes the handle without ending its hover, which would leave the resize pointer on the page.
            .onDisappear {
                if hasPushedCursor { NSCursor.pop() }
                hasPushedCursor = false
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startSize ?? shownSize
                    startSize = start
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    size = DevToolsDock.shownSize(start + sign * delta, in: room)
                }
                .onEnded { _ in startSize = nil })
    }
}
