// How a Chromium video in picture in picture reaches AVKit: where its source view sits below the page, how an engine frame becomes a sample buffer, and which stops pause the video or select its tab. AVKit's window and the engine need the running app.
import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumPictureInPictureTests {
    private let container = NSRect(x: 0, y: 0, width: 800, height: 600)

    @Test func aStartDeadlineCoversAVKitAcceptingTheCallWithoutCompleting() {
        #expect(ChromiumPictureInPicture.Phase.waiting.hasPendingStart)
        #expect(ChromiumPictureInPicture.Phase.starting.hasPendingStart)
        #expect(!ChromiumPictureInPicture.Phase.active.hasPendingStart)
        #expect(!ChromiumPictureInPicture.Phase.stopping.hasPendingStart)
        #expect(!ChromiumPictureInPicture.Phase.finished.hasPendingStart)
    }

    @Test func aVideoSizeMustHaveFinitePositivePixelDimensions() {
        let invalid = [CGSize.zero, CGSize(width: 320, height: 0), CGSize(width: -1, height: 180),
                       CGSize(width: CGFloat.nan, height: 180), CGSize(width: 320, height: CGFloat.infinity),
                       CGSize(width: 0.5, height: 180)]
        for size in invalid { #expect(!ChromiumPictureInPicture.validSize(size)) }
        #expect(ChromiumPictureInPicture.validSize(CGSize(width: 1, height: 1)))
        #expect(ChromiumPictureInPicture.validSize(CGSize(width: 3840, height: 2160)))
    }

    @Test func aStartRequiresTheFirstSamplesPresentationSizeAndValidViewAndLayerGeometry() {
        let size = CGSize(width: 1280, height: 720)
        #expect(ChromiumPictureInPicture.canStart(presentationSize: size, sourceFrame: container, layerBounds: container))
        #expect(!ChromiumPictureInPicture.canStart(presentationSize: .zero, sourceFrame: container, layerBounds: container))
        #expect(!ChromiumPictureInPicture.canStart(presentationSize: CGSize(width: CGFloat.nan, height: 720), sourceFrame: container, layerBounds: container))
        #expect(!ChromiumPictureInPicture.canStart(presentationSize: size, sourceFrame: .zero, layerBounds: container))
        #expect(!ChromiumPictureInPicture.canStart(presentationSize: size, sourceFrame: container, layerBounds: .zero))
        let invalidOrigin = CGRect(x: CGFloat.nan, y: 0, width: 320, height: 180)
        #expect(!ChromiumPictureInPicture.canStart(presentationSize: size, sourceFrame: invalidOrigin, layerBounds: container))
    }

    @Test func theFirstValidSamplePermitsStartingWithoutWaitingForTheCoveredLayerToDisplay() throws {
        // Metadata alone does not populate the session's presentation size. It remains zero until enqueue.
        #expect(!ChromiumPictureInPicture.canStart(presentationSize: .zero, sourceFrame: container, layerBounds: container))
        let surface = try #require(Self.surface(width: 64, height: 40))
        let (_, description) = try #require(ChromiumPictureInPicture.sampleBuffer(for: surface,
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 36), reusing: nil))
        let size = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true)
        #expect(size == CGSize(width: 64, height: 36))
        #expect(ChromiumPictureInPicture.canStart(presentationSize: size, sourceFrame: container, layerBounds: container))
    }

    @Test func aFrameShowsAtOnceWithoutACopy() throws {
        let surface = try #require(Self.surface(width: 64, height: 40))
        let (sampleBuffer, description) = try #require(ChromiumPictureInPicture.sampleBuffer(for: surface, contentRect: CGRect(x: 0, y: 0, width: 64, height: 40), reusing: nil))
        let pixelBuffer = try #require(CMSampleBufferGetImageBuffer(sampleBuffer))
        #expect(CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() === surface)
        #expect(CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, nil) == nil)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        #expect(dimensions.width == 64 && dimensions.height == 40)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]])
        #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    }

    @Test func aContentRectangleSmallerThanTheSurfaceBecomesTheCleanAperture() throws {
        let surface = try #require(Self.surface(width: 64, height: 40))
        let (sampleBuffer, description) = try #require(ChromiumPictureInPicture.sampleBuffer(for: surface, contentRect: CGRect(x: 0, y: 0, width: 64, height: 36), reusing: nil))
        let pixelBuffer = try #require(CMSampleBufferGetImageBuffer(sampleBuffer))
        let aperture = try #require(CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, nil) as? [CFString: Any])
        #expect(aperture[kCVImageBufferCleanApertureWidthKey] as? Double == 64)
        #expect(aperture[kCVImageBufferCleanApertureHeightKey] as? Double == 36)
        #expect(aperture[kCVImageBufferCleanApertureHorizontalOffsetKey] as? Double == 0)
        #expect(aperture[kCVImageBufferCleanApertureVerticalOffsetKey] as? Double == -2)
        let shown = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: false, useCleanAperture: true)
        #expect(shown == CGSize(width: 64, height: 36))
    }

    @Test func anInvalidOrEmptyApertureDoesNotBecomeAVKitContent() throws {
        let surface = try #require(Self.surface(width: 64, height: 40))
        let invalid = [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: CGFloat.nan, y: 0, width: 64, height: 40),
                       CGRect(x: 0, y: 0, width: 64, height: CGFloat.infinity), CGRect(x: 80, y: 0, width: 64, height: 40),
                       CGRect(x: 0, y: 0, width: -64, height: 40)]
        for content in invalid {
            #expect(ChromiumPictureInPicture.sampleBuffer(for: surface, contentRect: content, reusing: nil) == nil)
        }
    }

    @Test func aPartlyOutsideApertureIsClippedToFiniteSurfaceDimensions() throws {
        let surface = try #require(Self.surface(width: 64, height: 40))
        let (_, description) = try #require(ChromiumPictureInPicture.sampleBuffer(for: surface, contentRect: CGRect(x: -10, y: -10, width: 100, height: 46), reusing: nil))
        #expect(CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true) == CGSize(width: 64, height: 36))
    }

    @Test func theFormatDescriptionLastsWhileFramesMatchIt() throws {
        let first = try #require(Self.surface(width: 64, height: 40))
        let second = try #require(Self.surface(width: 64, height: 40))
        let letterboxed = CGRect(x: 0, y: 0, width: 64, height: 36)
        let (_, description) = try #require(ChromiumPictureInPicture.sampleBuffer(for: first, contentRect: letterboxed, reusing: nil))
        let (_, reused) = try #require(ChromiumPictureInPicture.sampleBuffer(for: second, contentRect: letterboxed, reusing: description))
        #expect(reused === description)
        // A reused surface drops the clean aperture of its earlier frame.
        let (sampleBuffer, replaced) = try #require(ChromiumPictureInPicture.sampleBuffer(for: first, contentRect: CGRect(x: 0, y: 0, width: 64, height: 40), reusing: description))
        #expect(replaced !== description)
        let pixelBuffer = try #require(CMSampleBufferGetImageBuffer(sampleBuffer))
        #expect(CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, nil) == nil)
    }

    @Test func theCloseButtonPausesOnlyAVideoThePageCanPause() {
        let ending = ChromiumPictureInPictureEnding()
        #expect(ending.closePausing(canPlayPause: true) == true)
        #expect(ending.closePausing(canPlayPause: false) == false)
    }

    @Test func theReturnButtonKeepsTheVideoPlaying() {
        var ending = ChromiumPictureInPictureEnding()
        let isReturn = ending.restoreRequested()
        #expect(isReturn)
        #expect(ending.closePausing(canPlayPause: true) == false)
    }

    @Test func aStopAfterTheEnginesEndSelectsNothingAndClosesNothing() {
        var ending = ChromiumPictureInPictureEnding()
        ending.engineDidEnd()
        let isReturn = ending.restoreRequested()
        #expect(!isReturn)
        #expect(!ending.isReturn)
        #expect(ending.closePausing(canPlayPause: true) == nil)
    }

    @Test func theEnginesEndAfterAReturnLeavesTheEngineAlone() {
        var ending = ChromiumPictureInPictureEnding()
        let isReturn = ending.restoreRequested()
        #expect(isReturn)
        ending.engineDidEnd()
        #expect(ending.closePausing(canPlayPause: true) == nil)
    }

    private static func surface(width: Int, height: Int) -> IOSurface? {
        IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA])
    }
}
