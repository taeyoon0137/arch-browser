// Places each browser window's selected tab's developer tools beside the page, on the side and at the size every window shares. The engine makes the tools' window; while the tools are docked, that window becomes a child of the browser window over the space the page leaves free, so it moves with the window. Docking inside the browser window itself needs a CEF patch (VI.3).
import AppKit
import ARCHEngine
import Combine
import SwiftUI

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
    public static let shared = DevToolsDockSettings()

    @Published public var side: DevToolsSide {
        didSet { UserDefaults.standard.set(side.rawValue, forKey: Self.sideKey) }
    }
    /// The tools' width beside the page.
    @Published var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }
    /// The tools' height below the page.
    @Published var height: CGFloat {
        didSet { UserDefaults.standard.set(Double(height), forKey: Self.heightKey) }
    }

    private static let sideKey = "ARCHDevToolsSide"
    private static let widthKey = "ARCHDevToolsWidth"
    private static let heightKey = "ARCHDevToolsHeight"

    private init() {
        let defaults = UserDefaults.standard
        side = defaults.string(forKey: Self.sideKey).flatMap(DevToolsSide.init(rawValue:)) ?? .right
        width = CGFloat(defaults.object(forKey: Self.widthKey) as? Double ?? 480)
        height = CGFloat(defaults.object(forKey: Self.heightKey) as? Double ?? 320)
    }
}

/// The window of one browser window's selected tab's tools, placed on the shared side (`DevToolsDockSettings`).
public final class DevToolsDock: ObservableObject {
    /// The selected tab's tools window while it is open.
    @Published private(set) var window: NSWindow?

    private let settings = DevToolsDockSettings.shared
    private var sideObserver: AnyCancellable?
    private weak var devTools: (any EngineDevTools)?
    private weak var browserWindow: NSWindow?
    /// The space the page leaves free for the tools, in the browser window's coordinates.
    private var region: NSRect?

    static let minimumSize: CGFloat = 200

    init() {
        // A side chosen in any window applies to this one at once. The settings publish a new side before they store it, so the placement takes the side it receives.
        sideObserver = settings.$side.dropFirst().sink { [weak self] side in self?.place(on: side) }
    }

    /// The side the page makes room on, or nil while the selected tab's tools are closed or float.
    var dockedSide: DevToolsSide? { window != nil && settings.side != .floating ? settings.side : nil }

    /// Follows the selected tab's tools. The docked window of the tab left behind hides until its tab returns, unless another browser window has docked it since; floating windows stay.
    func track(_ devTools: (any EngineDevTools)?) {
        guard devTools !== self.devTools else { return }
        if let previous = window, settings.side != .floating, previous.parent == nil || previous.parent === browserWindow {
            previous.parent?.removeChildWindow(previous)
            previous.orderOut(nil)
        }
        self.devTools = devTools
        devTools?.didChangeWindow = { [weak self, weak devTools] in
            guard let self, let devTools, devTools === self.devTools else { return }
            self.window = devTools.window
            self.place(on: self.settings.side)
        }
        window = devTools?.window
        place(on: settings.side)
    }

    /// Records the space the page leaves free, as the window lays it out.
    func setRegion(_ region: NSRect?, in browserWindow: NSWindow?) {
        self.region = region
        if let browserWindow { self.browserWindow = browserWindow }
        place(on: settings.side)
    }

    /// Moves the tools window over the free space as a child of the browser window, or lets it go when the tools float on `side`.
    private func place(on side: DevToolsSide) {
        guard let window else { return }
        guard side != .floating, let browserWindow, let region else {
            if let parent = window.parent {
                parent.removeChildWindow(window)
                setDocked(false, window)
            }
            if side == .floating, !window.isVisible { window.orderFront(nil) }
            return
        }
        if window.parent !== browserWindow {
            browserWindow.addChildWindow(window, ordered: .above)
            setDocked(true, window)
        }
        window.setFrame(browserWindow.convertToScreen(region), display: true)
        if !window.isVisible { window.orderFront(nil) }
    }

    /// A docked window moves only with the browser window, only its close button applies, and the Window menu leaves it out, so that the menu lists browser windows.
    private func setDocked(_ isDocked: Bool, _ window: NSWindow) {
        window.isMovable = !isDocked
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isDocked
        window.standardWindowButton(.zoomButton)?.isHidden = isDocked
        window.isExcludedFromWindowsMenu = isDocked
    }
}

/// Makes room for docked developer tools beside the page: the page narrows by the tools' size, and the free space reports its frame so the tools window covers it. The margin between the page and the tools is a handle that resizes them.
struct DevToolsDockSpace: ViewModifier {
    @ObservedObject var dock: DevToolsDock
    let isHidden: Bool
    /// The page's margins, which the tools repeat on their outer edges.
    let margins: EdgeInsets
    /// The side and sizes, which every window's tools share.
    @ObservedObject var settings = DevToolsDockSettings.shared

    private var side: DevToolsSide? { isHidden ? nil : dock.dockedSide }

    func body(content: Content) -> some View {
        content
            .padding(side == .right ? .trailing : side == .left ? .leading : .bottom, side == nil ? 0 : size + gap(for: side!))
            .overlay(alignment: alignment) { if let side { space(for: side) } }
            .onChange(of: side) { if $1 == nil { dock.setRegion(nil, in: nil) } }
    }

    private var size: CGFloat { side == .bottom ? settings.height : settings.width }
    private var alignment: Alignment { side == .left ? .leading : side == .bottom ? .bottom : .trailing }

    /// The page's own margin on that side already separates it from the tools, so only the tools' outer margin is added.
    private func gap(for side: DevToolsSide) -> CGFloat {
        switch side {
        case .left: return margins.leading
        case .bottom: return margins.bottom
        default: return margins.trailing
        }
    }

    @ViewBuilder private func space(for side: DevToolsSide) -> some View {
        switch side {
        case .bottom:
            VStack(spacing: 0) {
                DevToolsResizeHandle(axis: .vertical, size: $settings.height, sign: -1)
                    .frame(height: margins.bottom)
                DevToolsRegionReader(dock: dock)
                    .frame(height: settings.height)
            }
            .padding(EdgeInsets(top: 0, leading: margins.leading, bottom: margins.bottom, trailing: margins.trailing))
        case .left:
            HStack(spacing: 0) {
                DevToolsRegionReader(dock: dock)
                    .frame(width: settings.width)
                DevToolsResizeHandle(axis: .horizontal, size: $settings.width, sign: 1)
                    .frame(width: margins.leading)
            }
            .padding(EdgeInsets(top: margins.top, leading: margins.leading, bottom: margins.bottom, trailing: 0))
        default:
            HStack(spacing: 0) {
                DevToolsResizeHandle(axis: .horizontal, size: $settings.width, sign: -1)
                    .frame(width: margins.trailing)
                DevToolsRegionReader(dock: dock)
                    .frame(width: settings.width)
            }
            .padding(EdgeInsets(top: margins.top, leading: 0, bottom: margins.bottom, trailing: margins.trailing))
        }
    }
}

/// The margin between the page and the tools. Dragging it resizes the tools; `sign` is -1 where dragging toward the page enlarges them.
private struct DevToolsResizeHandle: View {
    let axis: Axis
    @Binding var size: CGFloat
    let sign: CGFloat
    @State private var startSize: CGFloat?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { isInside in
                let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
                isInside ? cursor.push() : NSCursor.pop()
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startSize ?? size
                    startSize = start
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    size = max(DevToolsDock.minimumSize, start + sign * delta)
                }
                .onEnded { _ in startSize = nil })
    }
}

/// Reports the free space's frame in its window whenever the layout moves or resizes it.
private struct DevToolsRegionReader: NSViewRepresentable {
    let dock: DevToolsDock

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.dock = dock
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {
        view.dock = dock
        view.report()
    }

    final class RegionView: NSView {
        weak var dock: DevToolsDock?

        func report() {
            guard let window else { return }
            dock?.setRegion(convert(bounds, to: nil), in: window)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
