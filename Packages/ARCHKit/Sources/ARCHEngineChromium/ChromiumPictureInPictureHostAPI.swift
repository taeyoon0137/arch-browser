import AppKit
import ARCHPrivateAPI
import Combine
import QuartzCore

/// Applies the sample-buffer PiP host workaround only while its private API flags allow it.
@MainActor
final class ChromiumPictureInPictureHostAPI {
    static let apiID = "avkit.sampleBufferPictureInPictureHost"
    static let featureID = "chromium.pictureInPictureScaling"

    private weak var panel: NSWindow?
    private weak var contentView: NSView?
    private weak var overlay: NSView?
    private var overlayWasHidden = false
    private var postedFrameChanges = false
    private var frameObservation: NSObjectProtocol?
    private var flagsObservation: AnyCancellable?
    private var renderSize = CGSize.zero
    private var resize: ((CGSize) -> Void)?
    private var restore: (() -> Void)?

    /// Call after AVKit has built its PiP hierarchy. A missing or changed hierarchy keeps the public behavior.
    @discardableResult
    func start(resize: @escaping (CGSize) -> Void, restore: @escaping () -> Void) -> Bool {
        stop()
        let flags = PrivateAPIFlags.shared
        flags.register(PrivateAPI(id: Self.apiID, name: "PIPPanel, AVPictureInPictureCALayerHostView", framework: "AVKit", check: {
            NSClassFromString("PIPPanel") is NSWindow.Type &&
                NSClassFromString("AVPictureInPictureCALayerHostView") is NSView.Type
        }))
        flags.register(PrivateAPIFeature(id: Self.featureID, name: "Chromium picture in picture scaling", apiIDs: [Self.apiID]))
        guard flags.allows(Self.featureID),
              let panelClass = NSClassFromString("PIPPanel") as? NSWindow.Type,
              let overlayClass = NSClassFromString("AVPictureInPictureCALayerHostView") as? NSView.Type else { return false }
        let panels = NSApp.windows.filter { $0.isVisible && ObjectIdentifier(type(of: $0)) == ObjectIdentifier(panelClass) }
        guard panels.count == 1, let panel = panels.first, let contentView = panel.contentView else { return false }
        var pending = [contentView], overlays: [NSView] = []
        while let view = pending.popLast() {
            if ObjectIdentifier(type(of: view)) == ObjectIdentifier(overlayClass) { overlays.append(view) }
            pending.append(contentsOf: view.subviews)
        }
        guard overlays.count == 1, let overlay = overlays.first, overlay !== contentView,
              overlay.superview?.layer != nil, Self.validSize(contentView.bounds.size) else { return false }

        self.panel = panel
        self.contentView = contentView
        self.overlay = overlay
        overlayWasHidden = overlay.isHidden
        postedFrameChanges = contentView.postsFrameChangedNotifications
        self.resize = resize
        self.restore = restore
        contentView.postsFrameChangedNotifications = true
        frameObservation = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                  object: contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSize() }
        }
        flagsObservation = flags.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !PrivateAPIFlags.shared.allows(Self.featureID) else { return }
                self.stop()
            }
        }
        updateSize()
        return self.restore != nil
    }

    /// Restore after AVKit stops, or immediately when a flag or hierarchy check fails.
    func stop() {
        if let frameObservation { NotificationCenter.default.removeObserver(frameObservation) }
        frameObservation = nil
        flagsObservation = nil
        let restore = self.restore
        self.restore = nil
        resize = nil
        renderSize = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if restore != nil {
            overlay?.isHidden = overlayWasHidden
            contentView?.postsFrameChangedNotifications = postedFrameChanges
        }
        overlay = nil
        contentView = nil
        panel = nil
        restore?()
        CATransaction.commit()
    }

    private func updateSize() {
        guard PrivateAPIFlags.shared.allows(Self.featureID),
              let panel, panel.isVisible, let contentView, panel.contentView === contentView,
              let overlay, overlay.isDescendant(of: contentView), overlay.superview?.layer != nil,
              Self.validSize(contentView.bounds.size) else { return stop() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The parent hosts the actual video. Only the separate overlay is hidden.
        overlay.isHidden = true
        let size = contentView.bounds.size
        if renderSize != size {
            renderSize = size
            resize?(size)
        }
        CATransaction.commit()
    }

    private static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
    }
}
