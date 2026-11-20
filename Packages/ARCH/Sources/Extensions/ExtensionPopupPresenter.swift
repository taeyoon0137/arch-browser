// Shows an action's popup in a popover: WebKit's own popover as it is, and a popup page's view, as Chromium gives it, in a popover of the presenter's, sized as the page asks within the limits that browsers keep popups in. Closing either side closes the other.
import AppKit
import ARCHEngine

/// Presents an engine extension's popup and keeps its page within popup size limits.
@MainActor
public enum ExtensionPopupPresenter {
    /// The smallest and largest size of a popup page, in points.
    static let minimumSize = CGSize(width: 25, height: 25)
    static let maximumSize = CGSize(width: 800, height: 600)

    /// The size a popover gives a page that asks for `size`.
    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, minimumSize.width), maximumSize.width), height: min(max(size.height, minimumSize.height), maximumSize.height))
    }

    /// Shows the popup from `rect` in `view`. A page's popover closes on a click outside it, and Escape reaches the page, which closes itself.
    public static func present(_ popup: EngineExtensionPopup, relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        switch popup {
        case let .popover(popover):
            popover.show(relativeTo: rect, of: view, preferredEdge: edge)
        case let .view(page):
            let controller = PopupPageController(page: page)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.contentSize = clamped(page.preferredSize)
            controller.popover = popover
            popover.show(relativeTo: rect, of: view, preferredEdge: edge)
            controller.didShow()
        }
    }
}

/// Holds a popup page's view in a popover, which it keeps until either closes.
private final class PopupPageController: NSViewController, NSPopoverDelegate {
    private let page: any EngineExtensionPopupView
    weak var popover: NSPopover? {
        didSet { popover?.delegate = self }
    }

    init(page: any EngineExtensionPopupView) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// Embeds the popup page and connects its resize and close callbacks to the popover.
    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: ExtensionPopupPresenter.clamped(page.preferredSize)))
        page.view.frame = container.bounds
        page.view.autoresizingMask = [.width, .height]
        container.addSubview(page.view)
        view = container
        page.sizeDidChange = { [weak self] size in self?.popover?.contentSize = ExtensionPopupPresenter.clamped(size) }
        page.didClose = { [weak self] in self?.popover?.close() }
    }

    /// The popover's window takes the keys, so that the page's own focus reaches its fields.
    func didShow() {
        view.window?.makeKey()
    }

    /// Removes the page's callbacks and view after the popover closes.
    func popoverDidClose(_ notification: Notification) {
        page.sizeDidChange = nil
        page.didClose = nil
        page.close()
        page.view.removeFromSuperview()
    }
}
