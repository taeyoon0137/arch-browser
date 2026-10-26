// How a Chromium video in picture in picture reaches AVKit: where its source view sits below the page, how an engine frame becomes a sample buffer, and which stops pause the video or select its tab. AVKit's window and the engine need the running app.
import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumPictureInPictureTests {
    private let container = NSRect(x: 0, y: 0, width: 800, height: 600)

    @Test func theSourceViewTakesTheVideosPlaceFromThePagesTop() {
        let source = NSRect(x: 10, y: 20, width: 320, height: 180)
        #expect(ChromiumPictureInPicture.sourceFrame(source, naturalSize: NSSize(width: 1280, height: 720), in: container, isFlipped: false)
            == NSRect(x: 10, y: 400, width: 320, height: 180))
        #expect(ChromiumPictureInPicture.sourceFrame(source, naturalSize: NSSize(width: 1280, height: 720), in: container, isFlipped: true) == source)
    }

    @Test func aVideoWithoutAPlaceInThePageGetsOneOfItsShapeAtTheTop() {
        #expect(ChromiumPictureInPicture.sourceFrame(.zero, naturalSize: NSSize(width: 960, height: 720), in: container, isFlipped: false)
            == NSRect(x: 0, y: 360, width: 320, height: 240))
        #expect(ChromiumPictureInPicture.sourceFrame(.zero, naturalSize: .zero, in: container, isFlipped: true) == NSRect(x: 0, y: 0, width: 320, height: 180))
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
