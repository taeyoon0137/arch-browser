// Previews show a page in a floating panel over the page area without opening a tab: Shift held while the pointer rests on a favorite, or a link in a page clicked with Shift. The panel's web contents belongs to no tab and closes with the panel, so the page never enters the tab list, the saved session, or history, unless it opens a page of its own and becomes a tab. Open in Tab loads the panel's page in a new tab; Escape or a click outside the panel closes it.
import AppKit
import ARCHEngine
import SwiftUI

/// A page in the preview panel. It reports the page's title, address, and loading state to the panel and passes the page's requests to open a tab, to use a permission, or to close on to its window. Dialogs and sign-in requests get the engine protocol's safe answers, so a preview asks the user nothing, and downloads are refused.
final class PagePreview: ObservableObject {
    let webContents: any EngineWebContents
    /// The Persona whose profile the page uses, as the tab or favorite it came from does.
    let personaID: Persona.ID
    /// The engine to request when the preview opens as a tab, even if its Persona is using a fallback.
    let requestedEngine: EngineKind
    /// The address the preview opened with, which it keeps across navigation.
    let openedURL: URL
    @Published private(set) var title = ""
    /// The page's address, which follows the page as the user moves around in it.
    @Published private(set) var url: URL
    @Published private(set) var isLoading: Bool
    /// The window that shows the preview sets this callback to open a page that the previewed page opens, such as a link to a new window, as a tab. The previewed page becomes a tab as well, which then reports to the tab instead.
    var openNewTab: ((any EngineWebContents) -> Void)?
    /// The window that shows the preview sets this callback to answer the page's permission requests. Without it every request is denied.
    var requestPermission: ((EnginePermissionRequest, @escaping (Bool) -> Void) -> Void)?
    /// The window that shows the preview sets this callback to close the panel when the page closes itself.
    var didClose: (() -> Void)?

    init(webContents: any EngineWebContents, personaID: Persona.ID, requestedEngine: EngineKind, openedURL: URL) {
        self.webContents = webContents
        self.personaID = personaID
        self.requestedEngine = requestedEngine
        self.openedURL = openedURL
        url = webContents.url ?? openedURL
        isLoading = webContents.isLoading
        webContents.uiDelegate = self
    }

    /// The site as the address pill names it.
    var host: String { AddressPillView.siteName(of: url) }
}

extension PagePreview: EngineWebContentsUIDelegate {
    func webContentsDidChangeTitle(_ webContents: any EngineWebContents) { title = webContents.title }
    func webContentsDidChangeURL(_ webContents: any EngineWebContents) {
        if let url = webContents.url { self.url = url }
    }
    func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) { isLoading = webContents.isLoading }
    func webContentsDidClose(_ webContents: any EngineWebContents) { didClose?() }
    func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {
        openNewTab?(newWebContents)
    }
    func webContents(_ webContents: any EngineWebContents, requestPermission request: EnginePermissionRequest, completion: @escaping (Bool) -> Void) {
        guard let requestPermission else { return completion(false) }
        requestPermission(request, completion)
    }
    /// A preview's page does not download, so closing the panel always closes the page at once. Once a tab takes the page, the tab decides.
    func webContents(_ webContents: any EngineWebContents, shouldDownload url: URL, hasPage: Bool) -> Bool { false }
    /// Places the items the engine hands as a tab's menu places them, in the order of WebKit's own menu. The tab's own items, which open tabs, ask about the selection, or move in the tab's history, and the plugins' items, stay out, as a preview belongs to no tab.
    func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {
        let handed = PageContextMenuSections(takingItemsOf: menu, for: element)
        PageContextMenuSections.show([handed.suggestions, handed.spelling, handed.lookUp, handed.editing, handed.fieldSubmenus, handed.share], in: menu)
    }
}

// MARK: Panel

/// The floating panel that shows a preview over the page area. A header with the page's title and site, Open in Tab, and Close sits above the page, which has a rounded frame inside the panel as the page has inside the window.
struct PagePreviewPanel: View {
    /// The space between the panel and the edges of the page area.
    static let inset: CGFloat = 32
    /// The margin around the page inside the panel, the same as around the page in the window.
    static let margin = BrowserWindowView.pageMargin
    /// Concentric with the page frame's corners.
    static let cornerRadius = PageFrameShape.cornerRadius + margin
    static let headerHeight: CGFloat = 40

    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject var preview: PagePreview

    var body: some View {
        let panel = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            header
            WebContentsHostView(contentView: preview.webContents.view)
                .background(PageBackgroundView(isEmpty: false))
                .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
        }
        .padding([.horizontal, .bottom], Self.margin)
        // A solid background, as under the find bar: a material over the engine's view cannot sample it.
        .background(panel.fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(panel.strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
        .contentShape(panel)
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .background(PreviewDismissal(close: windowModel.closePreview, ignoresEscape: { windowModel.isTabSwitcherVisible }))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
        .padding(Self.inset)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if preview.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: AddressPillView.symbol(for: preview.url, internalPage: nil))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 18, height: 18)
            // The site follows a title at the same size, set apart by weight and color, and keeps its width, so a long title truncates first. A page without a title yet, or a file titled with its own name, shows only the site.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(showsSite ? preview.title : preview.host)
                    .font(.system(size: 13, weight: .semibold))
                if showsSite {
                    Text(preview.host)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
            .lineLimit(1)
            .truncationMode(showsSite ? .tail : .middle)
            .help(preview.url.absoluteString)
            Spacer(minLength: 8)
            Button("Open in Tab", action: windowModel.openPreviewInTab)
            SidebarIconButton(symbol: "xmark", label: "Close Preview", action: windowModel.closePreview)
        }
        .padding(.leading, 6)
        .frame(height: Self.headerHeight)
    }

    private var showsSite: Bool { !preview.title.isEmpty && preview.title != preview.host }
}

/// Closes the preview on Escape and on a click in its window outside the panel, which then goes on to whatever it hit. A field of the app's own, such as the palette's or the find bar's, keeps its Escape. Clicks in other windows leave the panel open: the previewed page opens some of them, such as a date picker or the window a fullscreen video moves to.
struct PreviewDismissal: NSViewRepresentable {
    let close: () -> Void
    /// Whether something above the panel that has no field, such as the tab switcher, takes Escape first.
    let ignoresEscape: () -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.close = close
        view.ignoresEscape = ignoresEscape
    }

    /// Watches the app's keys and clicks while the panel is in a window. It lies behind the panel with the panel's frame and takes no clicks itself.
    final class MonitorView: NSView {
        var close: (() -> Void)?
        var ignoresEscape: (() -> Bool)?
        private var monitors: [Any] = []

        // A window that closes releases its views without moving them out of it first.
        deinit {
            monitors.forEach(NSEvent.removeMonitor)
        }

        // The monitors run before the focused view, so Escape closes the panel even while the previewed page has focus.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            guard window != nil else { return }
            let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.closesOnEscape(event) else { return event }
                self.close?()
                return nil
            }
            let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                if let self, self.closesOnClick(event) { self.close?() }
                return event
            }
            monitors = [escape, click].compactMap { $0 }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func closesOnEscape(_ event: NSEvent) -> Bool {
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  let window, event.window === window else { return false }
            let responder = window.firstResponder
            return !(responder is NSText) && (responder as? NSTextInputClient)?.hasMarkedText() != true && ignoresEscape?() != true
        }

        private func closesOnClick(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            return !bounds.contains(convert(event.locationInWindow, from: nil))
        }
    }
}

// MARK: Shift and hover

/// Runs `preview` once the pointer has rested on the view for a moment with Shift alone held, whichever began first.
struct ShiftHoverPreview: ViewModifier {
    let preview: () -> Void
    @StateObject private var shiftKey = ShiftHoverMonitor()

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                if isHovering { shiftKey.start(preview) } else { shiftKey.stop() }
            }
            // Hiding the sidebar or the card removes the view without ending its hover.
            .onDisappear { shiftKey.stop() }
    }
}

/// Watches the keys while the pointer is over one view and runs its preview once Shift alone has stayed down for `restDuration` with no other key pressed. The app sees key changes only while it is active.
final class ShiftHoverMonitor: ObservableObject {
    /// Passing over a view with Shift held, or pressing a shortcut that starts with Shift, opens no preview.
    static let restDuration = 0.25
    private var monitor: Any?
    private var preview: (() -> Void)?
    private var pendingPreview: DispatchWorkItem?

    func start(_ preview: @escaping () -> Void) {
        stop()
        self.preview = preview
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            // A key typed with Shift down, as for a capital letter, ends the wait until Shift is pressed again.
            if event.type == .keyDown { self?.cancelPendingPreview() } else { self?.modifiersDidChange(event.modifierFlags) }
            return event
        }
        modifiersDidChange(NSEvent.modifierFlags)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        preview = nil
        cancelPendingPreview()
    }

    deinit {
        stop()
    }

    private func cancelPendingPreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
    }

    /// Each change starts the wait again; any other modifier ends it.
    private func modifiersDidChange(_ flags: NSEvent.ModifierFlags) {
        cancelPendingPreview()
        guard Self.isShiftAlone(flags), let preview else { return }
        let work = DispatchWorkItem {
            guard NSApp.isActive, Self.isShiftAlone(NSEvent.modifierFlags) else { return }
            preview()
        }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDuration, execute: work)
    }

    /// Caps Lock and the like do not count.
    private static func isShiftAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .option, .control, .function]) == .shift
    }
}
