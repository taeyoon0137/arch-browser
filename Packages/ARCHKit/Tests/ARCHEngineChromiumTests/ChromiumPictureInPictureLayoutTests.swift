import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumPictureInPictureLayoutTests {
    @MainActor @Test func theSourceHostsTheVideoLayerDirectly() {
        let source = ChromiumPictureInPictureSourceView(frame: CGRect(x: 30, y: 40, width: 640, height: 360))
        #expect(source.layer === source.displayLayer)
        #expect(source.displayLayer.backgroundColor == CGColor(gray: 0, alpha: 1))
        #expect(source.displayLayer.videoGravity == .resizeAspect)
    }

    @MainActor @Test func detachingThePageKeepsTheSourceHostAndItsGeometry() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1466, height: 964))
        container.wantsLayer = true
        let page = NSView(frame: container.bounds)
        container.addSubview(page)
        let source = ChromiumPictureInPictureSourceView(frame: CGRect(x: 258, y: 419, width: 834, height: 469))
        container.addSubview(source, positioned: .below, relativeTo: page)
        source.layoutSubtreeIfNeeded()
        let sourceFrame = source.frame
        let videoFrame = source.displayLayer.frame
        let videoBounds = source.displayLayer.bounds
        for pageAttached in [true, false, true] {
            if pageAttached { container.addSubview(page, positioned: .above, relativeTo: source) }
            else { page.removeFromSuperview() }
            source.layoutSubtreeIfNeeded()
            #expect(source.superview === container)
            #expect(source.layer === source.displayLayer)
            #expect(source.frame == sourceFrame)
            #expect(source.displayLayer.frame == videoFrame)
            #expect(source.displayLayer.bounds == videoBounds)
            #expect(source.displayLayer.videoGravity == .resizeAspect)
            #expect(source.displayLayer.backgroundColor == CGColor(gray: 0, alpha: 1))
        }
    }

    @MainActor @Test func sourceLayoutDoesNotReplacePresentationGeometryWithLocalChildGeometry() {
        let source = ChromiumPictureInPictureSourceView(frame: CGRect(x: 258, y: 419, width: 834, height: 469))
        source.layoutSubtreeIfNeeded()
        for size in [CGSize(width: 376, height: 193), CGSize(width: 600, height: 400)] {
            let presentationFrame = CGRect(origin: CGPoint(x: 12, y: 24), size: size)
            source.displayLayer.frame = presentationFrame
            source.needsLayout = true
            source.layoutSubtreeIfNeeded()
            #expect(source.displayLayer.frame == presentationFrame)
            #expect(source.displayLayer.videoGravity == .resizeAspect)
        }
    }

    @MainActor @Test func aReturnKeepsPiPRenderBoundsWhenItsTargetChangesAspectRatio() {
        let cases: [(CGSize, [CGSize])] = [
            (CGSize(width: 320, height: 180), [CGSize(width: 640, height: 720), CGSize(width: 960, height: 360)]),
            (CGSize(width: 180, height: 320), [CGSize(width: 720, height: 640), CGSize(width: 360, height: 960)]),
        ]
        for (pipSize, targets) in cases {
            let source = ChromiumPictureInPictureSourceView(frame: .zero)
            source.setRenderSize(pipSize)
            #expect(source.displayLayer.frame == CGRect(origin: .zero, size: pipSize))
            source.prepareForStop()
            for target in targets {
                source.setRenderSize(target)
                source.prepareForStop()
                source.needsLayout = true
                source.layoutSubtreeIfNeeded()
                #expect(source.frame == CGRect(origin: .zero, size: target))
                #expect(source.displayLayer.bounds == CGRect(origin: .zero, size: pipSize))
                #expect(source.displayLayer.frame == CGRect(origin: .zero, size: target))
                #expect(source.displayLayer.affineTransform()
                    == CGAffineTransform(scaleX: target.width / pipSize.width, y: target.height / pipSize.height))
                #expect(source.displayLayer.videoGravity == .resizeAspectFill)
                #expect(source.displayLayer.backgroundColor == CGColor(gray: 0, alpha: 0))
            }
        }
    }

    @MainActor @Test func aCompletedStopRestoresNormalRenderingAtTheReturnSize() {
        let source = ChromiumPictureInPictureSourceView(frame: .zero)
        let pipSize = CGSize(width: 320, height: 180)
        let target = CGSize(width: 640, height: 720)
        source.setRenderSize(pipSize)
        source.prepareForStop()
        source.setRenderSize(target)
        source.restoreAfterStop()
        source.restoreAfterStop()
        source.needsLayout = true
        source.layoutSubtreeIfNeeded()
        #expect(source.displayLayer.bounds == CGRect(origin: .zero, size: target))
        #expect(source.displayLayer.frame == CGRect(origin: .zero, size: target))
        #expect(source.displayLayer.affineTransform() == .identity)
        #expect(source.displayLayer.videoGravity == .resizeAspect)
        #expect(source.displayLayer.backgroundColor == CGColor(gray: 0, alpha: 1))

        let resized = CGSize(width: 180, height: 320)
        source.setRenderSize(resized)
        #expect(source.displayLayer.bounds == CGRect(origin: .zero, size: resized))
        #expect(source.displayLayer.affineTransform() == .identity)
        source.prepareForStop()
        source.setRenderSize(target)
        #expect(source.displayLayer.bounds == CGRect(origin: .zero, size: resized))
    }

    @MainActor @Test func invalidRenderSizesLeaveEntryAndStopGeometryUntouched() {
        let source = ChromiumPictureInPictureSourceView(frame: .zero)
        source.prepareForStop()
        source.restoreAfterStop()
        #expect(source.displayLayer.videoGravity == .resizeAspect)
        #expect(source.displayLayer.backgroundColor == CGColor(gray: 0, alpha: 1))
        let pipSize = CGSize(width: 320, height: 180)
        let invalidSizes = [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: 0.5, height: 10),
                            CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10, height: CGFloat.infinity)]
        source.setRenderSize(pipSize)
        for stopping in [false, true] {
            if stopping {
                source.prepareForStop()
                source.setRenderSize(CGSize(width: 640, height: 720))
            }
            let frame = source.frame
            let layerFrame = source.displayLayer.frame
            let transform = source.displayLayer.affineTransform()
            for invalid in invalidSizes {
                source.setRenderSize(invalid)
                #expect(source.frame == frame)
                #expect(source.displayLayer.frame == layerFrame)
                #expect(source.displayLayer.bounds == CGRect(origin: .zero, size: pipSize))
                #expect(source.displayLayer.affineTransform() == transform)
                #expect(source.displayLayer.videoGravity == (stopping ? .resizeAspectFill : .resizeAspect))
                #expect(source.displayLayer.backgroundColor == CGColor(gray: 0, alpha: stopping ? 0 : 1))
            }
        }
    }

    @Test func widescreenVideoFitsBothSmallerAndLargerHosts() {
        let size = CGSize(width: 1920, height: 1080)
        #expect(ChromiumPictureInPictureSourceView.aspectFitRect(for: size, in: CGRect(x: 0, y: 0, width: 320, height: 240))
            == CGRect(x: 0, y: 30, width: 320, height: 180))
        #expect(ChromiumPictureInPictureSourceView.aspectFitRect(for: size, in: CGRect(x: 0, y: 0, width: 3840, height: 2400))
            == CGRect(x: 0, y: 120, width: 3840, height: 2160))
    }

    @Test func portraitVideoIsCenteredInNonzeroBounds() {
        #expect(ChromiumPictureInPictureSourceView.aspectFitRect(for: CGSize(width: 1080, height: 1920),
                                                               in: CGRect(x: 20, y: 30, width: 320, height: 320))
            == CGRect(x: 90, y: 30, width: 180, height: 320))
    }

    @Test func pixelResolutionDoesNotChangeTheFit() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let low = ChromiumPictureInPictureSourceView.aspectFitRect(for: CGSize(width: 640, height: 360), in: bounds)
        let high = ChromiumPictureInPictureSourceView.aspectFitRect(for: CGSize(width: 3840, height: 2160), in: bounds)
        #expect(low == high)
    }

    @Test func invalidGeometryHasNoAspectFit() {
        let invalidSizes = [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: CGFloat.nan, height: 10),
                            CGSize(width: 10, height: CGFloat.infinity)]
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        for size in invalidSizes {
            #expect(ChromiumPictureInPictureSourceView.aspectFitRect(for: size, in: bounds) == nil)
        }
        for invalid in [CGRect.zero, .null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 320, height: 180)] {
            #expect(ChromiumPictureInPictureSourceView.aspectFitRect(for: bounds.size, in: invalid) == nil)
        }
    }

    @Test func cleanApertureDeterminesTheFitInsteadOfSurfacePadding() throws {
        let surface = try #require(IOSurface(properties: [.width: 640, .height: 384, .bytesPerElement: 4,
                                                        .pixelFormat: kCVPixelFormatType_32BGRA]))
        let (_, description) = try #require(ChromiumPictureInPicture.sampleBuffer(for: surface,
            contentRect: CGRect(x: 0, y: 12, width: 640, height: 360), reusing: nil))
        let size = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true)
        #expect(size == CGSize(width: 640, height: 360))
        #expect(ChromiumPictureInPictureSourceView.aspectFitRect(for: size, in: CGRect(x: 0, y: 0, width: 320, height: 240))
            == CGRect(x: 0, y: 30, width: 320, height: 180))
    }

    @Test func aChangedFrameSizeReplacesThePresentationDescription() throws {
        let first = try #require(IOSurface(properties: [.width: 640, .height: 360, .bytesPerElement: 4,
                                                      .pixelFormat: kCVPixelFormatType_32BGRA]))
        let second = try #require(IOSurface(properties: [.width: 360, .height: 640, .bytesPerElement: 4,
                                                       .pixelFormat: kCVPixelFormatType_32BGRA]))
        let (_, original) = try #require(ChromiumPictureInPicture.sampleBuffer(for: first,
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360), reusing: nil))
        let (_, changed) = try #require(ChromiumPictureInPicture.sampleBuffer(for: second,
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 640), reusing: original))
        #expect(changed !== original)
        #expect(CMVideoFormatDescriptionGetPresentationDimensions(changed, usePixelAspectRatio: true, useCleanAperture: true)
            == CGSize(width: 360, height: 640))
    }
}
