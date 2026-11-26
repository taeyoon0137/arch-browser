import AppKit
import AVFoundation

/// Hosts the video layer directly, without an AppKit backing layer around AVKit's source.
@MainActor
final class ChromiumPictureInPictureSourceView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var stoppingRenderSize: CGSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        displayLayer.videoGravity = .resizeAspect
        // The order makes this a layer-hosting view. Keep source placement in the view's
        // coordinates instead of applying child-layer geometry to the hosted root.
        layer = displayLayer
        wantsLayer = true
    }

    /// Keep PiP's render bounds while its source frame moves to the inline video's rectangle.
    /// Changing those bounds during AVKit's return can expose the layer's letterboxing.
    func prepareForStop() {
        guard stoppingRenderSize == nil,
              ChromiumPictureInPicture.validSize(displayLayer.bounds.size) else { return }
        stoppingRenderSize = displayLayer.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        CATransaction.commit()
    }

    /// The view supplies the return rectangle; the layer keeps rendering at the PiP size.
    func setRenderSize(_ size: CGSize) {
        guard ChromiumPictureInPicture.validSize(size) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(origin: .zero, size: size)
        layoutSubtreeIfNeeded()
        let renderSize = stoppingRenderSize ?? size
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(origin: .zero, size: renderSize)
        displayLayer.position = CGPoint(x: size.width * displayLayer.anchorPoint.x,
                                        y: size.height * displayLayer.anchorPoint.y)
        displayLayer.setAffineTransform(CGAffineTransform(scaleX: size.width / renderSize.width,
                                                        y: size.height / renderSize.height))
        CATransaction.commit()
    }

    /// Call only after AVKit has released the content source, including on a stop timeout.
    func restoreAfterStop() {
        guard stoppingRenderSize != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stoppingRenderSize = nil
        setRenderSize(frame.size)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        CATransaction.commit()
    }

    /// Validates the aspect-fit geometry without changing AVKit's rendering layer.
    nonisolated static func aspectFitRect(for presentationSize: CGSize, in bounds: CGRect) -> CGRect? {
        guard presentationSize.width.isFinite, presentationSize.height.isFinite,
              presentationSize.width > 0, presentationSize.height > 0,
              !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              bounds.maxX.isFinite, bounds.maxY.isFinite else { return nil }
        let result = AVMakeRect(aspectRatio: presentationSize, insideRect: bounds)
        guard result.origin.x.isFinite, result.origin.y.isFinite,
              result.width.isFinite, result.height.isFinite, result.width > 0, result.height > 0,
              result.maxX.isFinite, result.maxY.isFinite else { return nil }
        return result
    }
}
