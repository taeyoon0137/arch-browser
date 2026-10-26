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
    /// How long AVKit may take to offer picture in picture before the page's video leaves it.
    static let startTimeout: Duration = .seconds(2)
    /// How long a stop may take before the session ends without AVKit. In the prototype a stop stalled after `willStop` until the content source went (Risk 12).
    static let stopTimeout: Duration = .seconds(1)

    /// The session that AVKit shows. Only one video is in picture in picture at a time, so a new session ends an earlier one that is still stopping.
    private static weak var current: ChromiumPictureInPicture?

    private enum Phase {
        /// Waiting for AVKit to offer picture in picture.
        case waiting
        /// `startPictureInPicture()` was called and `didStart` has not come.
        case starting
        case active
        case stopping
        case finished
    }

    private weak var browser: ARCHCEFBrowser?
    private let requestActivation: () -> Void
    private let didFinish: (ChromiumPictureInPicture) -> Void
    private let displayLayer = AVSampleBufferDisplayLayer()
    /// Holds the layer below the page, at the video's place in the page, which AVKit animates from and back to.
    private let sourceView = NSView()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    /// Kept while frames keep the same size and content rectangle.
    private var formatDescription: CMVideoFormatDescription?
    private var phase = Phase.waiting
    private var ending = ChromiumPictureInPictureEnding()
    private var hasStopDeadline = false
    private var isPlaying = false
    private var canPlayPause = true

    /// `requestActivation` asks the app to show the page, for the window's return button. `didFinish` tells the web contents to release the session.
    init(browser: ARCHCEFBrowser, requestActivation: @escaping () -> Void, didFinish: @escaping (ChromiumPictureInPicture) -> Void) {
        self.browser = browser
        self.requestActivation = requestActivation
        self.didFinish = didFinish
        super.init()
    }

    /// Puts the source view into `container` below `browserView`, which covers it, and starts picture in picture once AVKit offers it. `sourceRect` is the video's place in points from the top left of the browser's view, which fills the container.
    func start(in container: NSView, below browserView: NSView?, sourceRect: NSRect, naturalSize: NSSize) {
        Self.current?.end()
        Self.current = self
        displayLayer.videoGravity = .resizeAspect
        sourceView.layer = displayLayer
        sourceView.wantsLayer = true
        sourceView.frame = Self.sourceFrame(sourceRect, naturalSize: naturalSize, in: container.bounds, isFlipped: container.isFlipped)
        // The page keeps the video's distance from its top as the view resizes.
        sourceView.autoresizingMask = container.isFlipped ? [.maxXMargin, .maxYMargin] : [.maxXMargin, .minYMargin]
        container.addSubview(sourceView, positioned: .below, relativeTo: browserView)
        let controller = AVPictureInPictureController(contentSource: AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
        // The content is reported as live, so the window offers play and pause only.
        controller.requiresLinearPlayback = true
        controller.delegate = self
        self.controller = controller
        // AVKit offered picture in picture at once in the prototype, also for a covered layer in no window.
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startIfPossible() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            self?.startDidTimeOut()
        }
    }

    /// Shows a frame without copying its pixels. The engine leaves the surface unchanged until three later frames have arrived, which covers the layer's hold.
    func enqueue(_ surface: IOSurfaceRef, contentRect: CGRect) {
        guard phase != .finished, let (sampleBuffer, description) = Self.sampleBuffer(for: surface, contentRect: contentRect, reusing: formatDescription) else { return }
        formatDescription = description
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
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
            phase = .stopping
            keepSourceViewInWindow()
            controller?.stopPictureInPicture()
            scheduleStopDeadline()
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
        guard phase == .waiting, let controller, controller.isPictureInPicturePossible else { return }
        phase = .starting
        controller.startPictureInPicture()
    }

    private func startDidTimeOut() {
        guard phase == .waiting else { return }
        end()
    }

    /// Moves the source view, at its size, to the top left of the content view of the front visible window that can become key, below the window's content, when the page's view is in no window, as while another tab is selected. In the prototype a stop led to no delegate call while the layer's view was in no window, and releasing the content source ended only a stop whose layer was in a window (Risk 12). The windows count also while the app is inactive; AVKit's own panel cannot become key (prototype fact 25), and a hidden app has no visible window. AVKit's own stops keep the view in the page, where the return button shows it again.
    private func keepSourceViewInWindow() {
        guard sourceView.window == nil, let contentView = NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey })?.contentView else { return }
        sourceView.frame = Self.sourceFrame(NSRect(origin: .zero, size: sourceView.frame.size), naturalSize: .zero, in: contentView.bounds, isFlipped: contentView.isFlipped)
        sourceView.autoresizingMask = contentView.isFlipped ? [.maxXMargin, .maxYMargin] : [.maxXMargin, .minYMargin]
        contentView.addSubview(sourceView, positioned: .below, relativeTo: nil)
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
        controller?.delegate = nil
        controller?.contentSource = nil
        controller = nil
        sourceView.removeFromSuperview()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        // The engine reports its end from inside this call, which the finished session ignores.
        if let pausing, !ending.engineEnded { browser?.closePictureInPicture(pausingVideo: pausing) }
        didFinish(self)
    }

    /// The source view's frame in a container with `bounds`: the video's place in the page, from the top left, or, when the page gave it no size, a small rectangle of the video's shape at the top left.
    nonisolated static func sourceFrame(_ sourceRect: NSRect, naturalSize: NSSize, in bounds: NSRect, isFlipped: Bool) -> NSRect {
        var rect = sourceRect
        if rect.width < 1 || rect.height < 1 {
            let aspectRatio = naturalSize.width > 0 && naturalSize.height > 0 ? naturalSize.height / naturalSize.width : 9.0 / 16.0
            rect = NSRect(x: 0, y: 0, width: 320, height: (320 * aspectRatio).rounded())
        }
        let top = isFlipped ? bounds.minY + rect.minY : bounds.maxY - rect.maxY
        return NSRect(x: bounds.minX + rect.minX, y: top, width: rect.width, height: rect.height)
    }

    /// Wraps a frame's IOSurface in a sample buffer that the layer shows at once. A clean aperture limits the picture to `contentRect`, in pixels from the surface's top left, when the rectangle is smaller than the surface. The format description is reused while it matches the frame.
    nonisolated static func sampleBuffer(for surface: IOSurfaceRef, contentRect: CGRect, reusing description: CMVideoFormatDescription?) -> (CMSampleBuffer, CMVideoFormatDescription)? {
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanagedPixelBuffer) == kCVReturnSuccess,
              let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let content = contentRect.intersection(bounds)
        // The engine reuses its surfaces, which may keep an earlier frame's attachments.
        if content.isNull || content.isEmpty || content == bounds {
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
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        end()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard phase != .finished else { return }
        phase = .stopping
        scheduleStopDeadline()
    }

    /// AVKit asks for this for the window's return button and also for a stop the app requests (prototype fact 29), so it counts as a return only while the engine has not ended the session.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard phase != .finished, ending.restoreRequested() else { return completionHandler(false) }
        requestActivation()
        completionHandler(true)
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
