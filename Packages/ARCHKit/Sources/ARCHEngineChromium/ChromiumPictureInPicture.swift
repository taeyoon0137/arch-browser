// Shows a Chromium video in picture in picture in the system's window. Arch's engine captures the video's frames into IOSurfaces and reports its playback state; AVKit shows them from an `AVSampleBufferDisplayLayer` that sits below the page.
import AppKit
import AVFoundation
import AVKit
import CEFBridge
import CoreMedia
import CoreVideo

/// One video's picture in picture, from the engine's start until AVKit has finished stopping. The web contents keeps it until then; a stop under way keeps itself until its deadline, also after the web contents has gone. AVKit calls its delegates on the main thread.
@MainActor
final class ChromiumPictureInPicture: NSObject {
    /// How long AVKit may take to offer and start picture in picture before the page's video leaves it.
    static let startTimeout: Duration = .seconds(2)
    /// How long a stop may take before the session ends without AVKit. In the prototype a stop stalled after `willStop` until the content source went (Risk 12).
    static let stopTimeout: Duration = .seconds(1)

    /// The session that AVKit shows. Only one video is in picture in picture at a time, so a new session ends an earlier one that is still stopping.
    private static weak var current: ChromiumPictureInPicture?

    /// Where the session is in AVKit's start and stop.
    enum Phase {
        /// Waiting for AVKit to offer picture in picture.
        case waiting
        /// `startPictureInPicture()` was called and `didStart` has not come.
        case starting
        case active
        case stopping
        case finished

        /// A pending start expires even after AVKit accepted the start call but sent no completion.
        var hasPendingStart: Bool { self == .waiting || self == .starting }
    }

    private weak var browser: ARCHCEFBrowser?
    private let requestActivation: () -> Void
    private let refreshSource: (@escaping () -> Void) -> Void
    private let didFinish: (ChromiumPictureInPicture) -> Void
    private var displayLayer: AVSampleBufferDisplayLayer { sourceView.displayLayer }
    /// The source has a local origin; its covered child window supplies the animation rectangle.
    private let sourceView = ChromiumPictureInPictureSourceView(frame: .zero)
    private var sourceWindow: NSWindow?
    private let hostAPI = ChromiumPictureInPictureHostAPI()
    private var unscaledSourceSize: CGSize?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    private var readyNotification: NSObjectProtocol?
    /// Kept while frames keep the same size and content rectangle.
    private var formatDescription: CMVideoFormatDescription?
    /// Set only after the first valid sample is enqueued; inline playback creates no session or layer.
    private var presentationSize = CGSize.zero
    private var phase = Phase.waiting
    private var ending = ChromiumPictureInPictureEnding()
    private var hasStopDeadline = false
    private var isPlaying = false
    private var canPlayPause = true

    /// `requestActivation` asks the app to show the page, for the window's return button. `didFinish` tells the web contents to release the session.
    init(browser: ARCHCEFBrowser, requestActivation: @escaping () -> Void, refreshSource: @escaping (@escaping () -> Void) -> Void, didFinish: @escaping (ChromiumPictureInPicture) -> Void) {
        self.browser = browser
        self.requestActivation = requestActivation
        self.refreshSource = refreshSource
        self.didFinish = didFinish
        super.init()
        if #available(macOS 14.4, *) {
            readyNotification = NotificationCenter.default.addObserver(forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                                                                       object: displayLayer, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.startIfPossible() }
            }
        } else {
            readyObservation = displayLayer.sampleBufferRenderer.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.startIfPossible() }
            }
        }
    }

    /// Starts only after both a captured sample and a measured source rectangle are available.
    func start() {
        Self.current?.end()
        Self.current = self
        Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            self?.startDidTimeOut()
        }
    }

    /// Shows a frame without copying its pixels. The engine leaves the surface unchanged until three later frames have arrived, which covers the layer's hold.
    func enqueue(_ surface: IOSurfaceRef, contentRect: CGRect) {
        guard phase != .finished, phase != .stopping,
              let (sampleBuffer, description) = Self.sampleBuffer(for: surface, contentRect: contentRect, reusing: formatDescription) else { return }
        let size = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true)
        guard Self.validSize(size) else { return }
        formatDescription = description
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
        presentationSize = size
        startIfPossible()
    }

    func update(isPlaying: Bool, canPlayPause: Bool) {
        self.isPlaying = isPlaying
        self.canPlayPause = canPlayPause
        controller?.invalidatePlaybackState()
    }

    /// The engine ended picture in picture and sends no more frames. AVKit stops, or the session ends at once when AVKit has not started. When AVKit has stopped already, this comes from inside the engine call that `didStop` makes, and nothing more happens.
    func engineDidStop() {
        guard phase != .finished else { return }
        ending.engineDidEnd()
        switch phase {
        case .waiting, .starting:
            end()
        case .active:
            beginStopping()
            refreshSourceForStop { [weak self] in
                guard let self, self.phase == .stopping else { return }
                self.controller?.stopPictureInPicture()
                self.scheduleStopDeadline()
            }
        case .stopping:
            scheduleStopDeadline()
        case .finished:
            break
        }
    }

    /// Ends the session at once, without AVKit's stop animation, leaving the page's video playing.
    func end() {
        finish(closingEnginePausing: false)
    }

    private func startIfPossible() {
        guard phase == .waiting, sourceView.window != nil else { return }
        guard Self.canStart(presentationSize: presentationSize, sourceFrame: sourceView.frame, layerBounds: displayLayer.bounds) else { return }
        // Enqueueing a valid sample does not mean its image is available to AVKit yet.
        if #available(macOS 14.4, *) {
            guard displayLayer.isReadyForDisplay else { return }
        } else {
            guard displayLayer.sampleBufferRenderer.status == .rendering else { return }
        }
        if controller == nil {
            let controller = AVPictureInPictureController(contentSource: AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
            // The content is reported as live, so the window offers play and pause only.
            controller.requiresLinearPlayback = true
            controller.delegate = self
            self.controller = controller
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.startIfPossible() }
            }
        }
        guard let controller, controller.isPictureInPicturePossible else { return }
        phase = .starting
        controller.startPictureInPicture()
    }

    private func startDidTimeOut() {
        guard phase.hasPendingStart else { return }
        NSLog("Arch picture in picture timed out while %@.", phase == .waiting ? "waiting for availability" : "starting")
        end()
    }

    /// Keep the video layer at a local origin, with the measured rectangle on a child window.
    /// Page reports keep updating their cache during presentation; only entry and return change
    /// this render host, so background layout cannot move AVKit's live source.
    func updateSource(windowRect: CGRect, in window: NSWindow) {
        guard phase == .waiting || phase == .stopping, Self.validRect(windowRect) else { return }
        let frame = window.convertToScreen(windowRect)
        guard Self.validRect(frame) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let host: NSWindow
        if let sourceWindow {
            host = sourceWindow
        } else {
            host = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.ignoresMouseEvents = true
            host.hasShadow = false
            host.isOpaque = true
            host.backgroundColor = .black
            host.animationBehavior = .none
            host.contentView = sourceView
            sourceWindow = host
        }
        if host.parent !== window {
            host.parent?.removeChildWindow(host)
            window.addChildWindow(host, ordered: .below)
        }
        host.setFrame(frame, display: false)
        sourceView.setRenderSize(frame.size)
        displayLayer.contentsScale = host.backingScaleFactor
        CATransaction.commit()
        startIfPossible()
    }

    private func beginStopping() {
        phase = .stopping
        sourceView.prepareForStop()
    }

    /// Showing the source tab can defer its layout until the next main turn. Measure only after
    /// that layout, using the entry conversion, and commit the source geometry before AVKit is
    /// allowed to animate back. Otherwise restoration can use the previous host's coordinates.
    private func refreshSourceForStop(completion: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase != .finished else { return completion() }
            self.sourceWindow?.parent?.contentView?.layoutSubtreeIfNeeded()
            self.refreshSource { [weak self] in
                guard let self, self.phase != .finished else { return completion() }
                self.sourceView.superview?.layoutSubtreeIfNeeded()
                self.sourceView.layoutSubtreeIfNeeded()
                CATransaction.flush()
                completion()
            }
        }
    }

    /// The system's sample-buffer host copies source pixels at 1:1 on affected macOS versions.
    /// Match only this covered render window to it; the page's measured return rectangle stays intact.
    private func resizeSource(to size: CGSize) {
        guard phase == .active, Self.validSize(size), let sourceWindow else { return }
        if unscaledSourceSize == nil { unscaledSourceSize = sourceWindow.frame.size }
        let frame = CGRect(x: sourceWindow.frame.minX, y: sourceWindow.frame.maxY - size.height,
                           width: size.width, height: size.height)
        setRenderFrame(frame)
        sourceWindow.alphaValue = 0
    }

    private func restoreSourceSize() {
        // A flag change or disappearing PiP host can ask early. Keep the animation's source
        // intact; finish drains this restoration after disconnecting AVKit even in that case.
        guard phase != .stopping, let size = unscaledSourceSize, let sourceWindow else { return }
        unscaledSourceSize = nil
        let frame = CGRect(x: sourceWindow.frame.minX, y: sourceWindow.frame.maxY - size.height,
                           width: size.width, height: size.height)
        setRenderFrame(frame)
        sourceWindow.alphaValue = 1
    }

    private func setRenderFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceWindow?.setFrame(frame, display: false)
        sourceView.setRenderSize(frame.size)
        CATransaction.commit()
    }

    /// The task keeps the session until the deadline, also after the web contents has gone, since a released controller leaves the system's window open.
    private func scheduleStopDeadline() {
        guard !hasStopDeadline else { return }
        hasStopDeadline = true
        Task {
            try? await Task.sleep(for: Self.stopTimeout)
            self.stopDidTimeOut()
        }
    }

    /// Finishing releases the controller's content source, which ended a stalled session at once in the prototype.
    private func stopDidTimeOut() {
        guard phase != .finished else { return }
        stopDidFinish()
    }

    private func stopDidFinish() {
        finish(closingEnginePausing: ending.closePausing(canPlayPause: canPlayPause))
    }

    /// Takes the source view out of the page and the frames out of the layer, then ends the engine's picture in picture, pausing the video or not, unless `pausing` is nil or the engine ended it. The web contents releases the session last.
    private func finish(closingEnginePausing pausing: Bool?) {
        guard phase != .finished else { return }
        phase = .finished
        if Self.current === self { Self.current = nil }
        possibleObservation = nil
        readyObservation = nil
        if let readyNotification { NotificationCenter.default.removeObserver(readyNotification) }
        readyNotification = nil
        controller?.delegate = nil
        controller?.contentSource = nil
        controller = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceView.restoreAfterStop()
        hostAPI.stop()
        restoreSourceSize()
        CATransaction.commit()
        if let sourceWindow {
            sourceWindow.parent?.removeChildWindow(sourceWindow)
            sourceWindow.orderOut(nil)
            sourceWindow.close()
            self.sourceWindow = nil
        }
        sourceView.removeFromSuperview()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        // The engine reports its end from inside this call, which the finished session ignores.
        if let pausing, !ending.engineEnded { browser?.closePictureInPicture(pausingVideo: pausing) }
        didFinish(self)
    }

    /// Finite, nonzero dimensions keep AVKit's aspect ratio calculations defined. Subpixel sizes cannot describe a captured video frame.
    nonisolated static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
    }

    nonisolated static func validRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && validSize(rect.size) && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }

    nonisolated static func canStart(presentationSize: CGSize, sourceFrame: CGRect, layerBounds: CGRect) -> Bool {
        validSize(presentationSize) && validRect(sourceFrame) && validRect(layerBounds) &&
            ChromiumPictureInPictureSourceView.aspectFitRect(for: presentationSize, in: layerBounds) != nil
    }

    /// Wraps a frame's IOSurface in a sample buffer that the layer shows at once. A clean aperture limits the picture to `contentRect`, in pixels from the surface's top left, when the rectangle is smaller than the surface. The format description is reused while it matches the frame.
    nonisolated static func sampleBuffer(for surface: IOSurfaceRef, contentRect: CGRect, reusing description: CMVideoFormatDescription?) -> (CMSampleBuffer, CMVideoFormatDescription)? {
        guard validRect(contentRect) else { return nil }
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanagedPixelBuffer) == kCVReturnSuccess,
              let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard validRect(bounds) else { return nil }
        let content = contentRect.intersection(bounds)
        guard validRect(content) else { return nil }
        // The engine reuses its surfaces, which may keep an earlier frame's attachments.
        if content == bounds {
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferCleanApertureKey)
        } else {
            let aperture: [CFString: Any] = [
                kCVImageBufferCleanApertureWidthKey: content.width,
                kCVImageBufferCleanApertureHeightKey: content.height,
                kCVImageBufferCleanApertureHorizontalOffsetKey: content.midX - bounds.midX,
                kCVImageBufferCleanApertureVerticalOffsetKey: content.midY - bounds.midY,
            ]
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
        }
        // The engine captures in 8-bit sRGB.
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        var formatDescription = description
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            formatDescription = nil
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription) == noErr else { return nil }
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: formatDescription, sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return nil }
        // Frames carry no times, so each replaces the one shown.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return (sampleBuffer, formatDescription)
    }
}

extension ChromiumPictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if phase == .starting { phase = .active }
        // AVKit finishes installing its host views after the start callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.phase == .active else { return }
            self.hostAPI.start(resize: { [weak self] in self?.resizeSource(to: $0) },
                               restore: { [weak self] in self?.restoreSourceSize() })
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let error = error as NSError
        NSLog("Arch picture in picture failed to start (%@, %ld).", error.domain, error.code)
        end()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard phase != .finished else { return }
        // Engine stops and returns already measured before allowing AVKit to stop. Do not start
        // another asynchronous update that could move the target after its animation begins.
        if phase != .stopping {
            beginStopping()
            refreshSourceForStop {}
        }
        scheduleStopDeadline()
    }

    /// AVKit asks for this for the window's return button and also for a stop the app requests (prototype fact 29), so it counts as a return only while the engine has not ended the session.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard phase != .finished, ending.restoreRequested() else { return completionHandler(false) }
        beginStopping()
        requestActivation()
        refreshSourceForStop { [weak self] in completionHandler(self?.phase == .stopping) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        stopDidFinish()
    }
}

extension ChromiumPictureInPicture: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    /// The page's Media Session handlers run when it has them, as in Chromium's own window. A page that offers no control keeps playing, and the window shows that again.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard canPlayPause else { return pictureInPictureController.invalidatePlaybackState() }
        browser?.setPictureInPicturePlaying(playing)
    }

    /// Live content: the window shows no timeline and no skip buttons.
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !isPlaying
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// How a session ends, which tells AVKit's stops apart: the window's close button, its return button, and a stop that the engine's end requests.
struct ChromiumPictureInPictureEnding {
    /// Set once the engine reported the end, after which it needs no call.
    private(set) var engineEnded = false
    /// Set when AVKit's request to restore the interface came from the return button.
    private(set) var isReturn = false

    mutating func engineDidEnd() {
        engineEnded = true
    }

    /// Whether AVKit's request to restore the interface is the return button, which it is only while the engine has not ended the session.
    mutating func restoreRequested() -> Bool {
        guard !engineEnded else { return false }
        isReturn = true
        return true
    }

    /// What the engine needs once AVKit has stopped: nil when the engine ended the session, otherwise whether closing pauses the video. A return keeps it playing; the close button pauses it unless the page offers no play or pause control, as Chromium's own window does.
    func closePausing(canPlayPause: Bool) -> Bool? {
        engineEnded ? nil : !isReturn && canPlayPause
    }
}
