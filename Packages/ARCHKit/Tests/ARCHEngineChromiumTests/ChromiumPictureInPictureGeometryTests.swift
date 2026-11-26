import AppKit
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumPictureInPictureGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func pageZoomConvertsCSSPixelsToViewPointsOnce() {
        let video = video(rect: CGRect(x: 40, y: 60, width: 320, height: 180))
        #expect(video.viewRect(in: bounds, isFlipped: true, pageZoom: 1.5)
            == CGRect(x: 60, y: 90, width: 480, height: 270))
    }

    @Test func retinaScaleDoesNotMultiplyPointCoordinates() {
        let expected = CGRect(x: 60, y: 90, width: 480, height: 270)
        for scale: CGFloat in [1, 2, 3] {
            let video = video(rect: CGRect(x: 40, y: 60, width: 320, height: 180), devicePixelRatio: scale)
            #expect(video.viewRect(in: bounds, isFlipped: true, pageZoom: 1.5) == expected)
        }
    }

    @Test func visualViewportOffsetsAndScaleApplyBeforeAppKitFlipping() {
        let video = video(rect: CGRect(x: 40, y: 60, width: 320, height: 180),
                          viewportOffset: CGPoint(x: 10, y: 20), viewportScale: 1.25)
        let shiftedBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        #expect(video.viewRect(in: shiftedBounds, isFlipped: true, pageZoom: 1.2)
            == CGRect(x: 55, y: 80, width: 480, height: 270))
        #expect(video.viewRect(in: shiftedBounds, isFlipped: false, pageZoom: 1.2)
            == CGRect(x: 55, y: 290, width: 480, height: 270))
    }

    @Test func scrollingUsesTheAlreadyScrolledDOMRectangle() {
        let before = video(rect: CGRect(x: 90, y: 120, width: 320, height: 180))
        // getBoundingClientRect moves up by the scroll distance; native conversion subtracts nothing again.
        let after = video(rect: CGRect(x: 90, y: 20, width: 320, height: 180))
        #expect(before.viewRect(in: bounds, isFlipped: false, pageZoom: 1)
            == CGRect(x: 90, y: 300, width: 320, height: 180))
        #expect(after.viewRect(in: bounds, isFlipped: false, pageZoom: 1)
            == CGRect(x: 90, y: 400, width: 320, height: 180))
    }

    @Test func partiallyScrolledVideoKeepsItsActualOriginAndSize() {
        let video = video(rect: CGRect(x: -40, y: -30, width: 320, height: 180))
        #expect(video.viewRect(in: bounds, isFlipped: true, pageZoom: 1)
            == CGRect(x: -40, y: -30, width: 320, height: 180))
        #expect(video.viewRect(in: bounds, isFlipped: false, pageZoom: 1)
            == CGRect(x: -40, y: 450, width: 320, height: 180))
    }

    @Test func malformedMeasurementsDoNotProduceAnAnimationRectangle() {
        let valid = video()
        for zoom: CGFloat in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            #expect(valid.viewRect(in: bounds, isFlipped: true, pageZoom: zoom) == nil)
        }
        for value: CGFloat in [0, -1, .nan, .infinity] {
            #expect(video(viewportScale: value).viewRect(in: bounds, isFlipped: true, pageZoom: 1) == nil)
            #expect(video(devicePixelRatio: value).viewRect(in: bounds, isFlipped: true, pageZoom: 1) == nil)
        }
        let invalidRects = [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 320, height: 180),
                            CGRect(x: 0, y: CGFloat.infinity, width: 320, height: 180),
                            CGRect(x: 0, y: 0, width: -1, height: 180),
                            CGRect(x: 0, y: 0, width: 320, height: CGFloat.infinity)]
        for rect in invalidRects {
            #expect(video(rect: rect).viewRect(in: bounds, isFlipped: true, pageZoom: 1) == nil)
        }
        for invalidBounds in [CGRect.zero, .null, .infinite] {
            #expect(valid.viewRect(in: invalidBounds, isFlipped: false, pageZoom: 1) == nil)
        }
        #expect(video(viewportOffset: CGPoint(x: CGFloat.nan, y: 0)).viewRect(in: bounds, isFlipped: true, pageZoom: 1) == nil)
    }

    @MainActor @Test func nestedFlippedAndUnflippedWebViewsConvertToTheSameWindowRectangle() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let tab = FlippedView(frame: CGRect(x: 200, y: 100, width: 800, height: 600))
        root.addSubview(tab)
        let video = video(rect: CGRect(x: 20, y: 30, width: 320, height: 180))
        for webView in [NSView(frame: .zero), FlippedView(frame: .zero)] {
            webView.frame = CGRect(x: 50, y: 60, width: 700, height: 500)
            tab.addSubview(webView)
            #expect(ChromiumPictureInPictureGeometry.windowRect(for: video, in: webView, pageZoom: 1)
                == CGRect(x: 270, y: 430, width: 320, height: 180))
            webView.removeFromSuperview()
        }
    }

    @MainActor @Test func eitherWebViewOrientationPlacesTheSourceAtTheMeasuredScreenRectangle() throws {
        _ = NSApplication.shared
        let windowBounds = CGRect(x: 0, y: 0, width: 1466, height: 964)
        let window = NSWindow(contentRect: CGRect(x: 118, y: 120, width: 1466, height: 964),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let inline = video(rect: CGRect(x: 258, y: 76, width: 834, height: 469))
        let expectedWindowRect = CGRect(x: 258, y: 419, width: 834, height: 469)
        let expectedScreenRect = CGRect(x: 376, y: 539, width: 834, height: 469)
        for webView in [NSView(frame: windowBounds), FlippedView(frame: windowBounds)] {
            window.contentView = webView
            let rect = try #require(ChromiumPictureInPictureGeometry.windowRect(for: inline, in: webView, pageZoom: 1))
            #expect(rect == expectedWindowRect)
            #expect(window.convertToScreen(rect) == expectedScreenRect)
            #expect(window.convertFromScreen(expectedScreenRect) == rect)
        }
        #expect(!window.isVisible)
    }

    @MainActor @Test func aSourceWindowSeparatesLocalVideoGeometryFromItsScreenPosition() {
        _ = NSApplication.shared
        let frame = CGRect(x: 376, y: 539, width: 834, height: 469)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let source = ChromiumPictureInPictureSourceView(frame: .zero)
        window.contentView = source
        source.frame = CGRect(origin: .zero, size: frame.size)
        source.displayLayer.frame = source.bounds
        source.layoutSubtreeIfNeeded()
        #expect(source.displayLayer.frame == CGRect(origin: .zero, size: frame.size))
        #expect(window.convertToScreen(source.convert(source.bounds, to: nil)) == frame)
        let moved = frame.offsetBy(dx: 100, dy: -80)
        window.setFrame(moved, display: false)
        #expect(source.displayLayer.frame == CGRect(origin: .zero, size: frame.size))
        #expect(window.convertToScreen(source.convert(source.bounds, to: nil)) == moved)
        #expect(!window.isVisible)
    }

    @MainActor @Test func aFreshRestoreUsesTheCurrentLayoutInsteadOfTheEntryViewport() throws {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let webView = FlippedView(frame: CGRect(x: 200, y: 100, width: 800, height: 600))
        root.addSubview(webView)
        let inline = video(rect: CGRect(x: 20, y: 30, width: 320, height: 180))
        let entry = ChromiumPictureInPictureGeometry.Viewport(webView: webView, pageZoom: 1)
        let entryRect = try #require(entry.windowRect(for: inline))
        #expect(entryRect == CGRect(x: 220, y: 490, width: 320, height: 180))
        webView.frame = CGRect(x: 240, y: 150, width: 800, height: 650)
        let restored = try #require(ChromiumPictureInPictureGeometry.windowRect(for: inline, in: webView, pageZoom: 1))
        #expect(restored == CGRect(x: 260, y: 590, width: 320, height: 180))
        #expect(entry.windowRect(for: inline) == entryRect)
        // A delayed entry reply keeps the native viewport captured before its tab was removed.
        webView.removeFromSuperview()
        #expect(entry.windowRect(for: inline) == entryRect)
    }

    @MainActor @Test func aFullyOffscreenMeasurementCannotReplaceTheLastVisibleRectangle() {
        let webView = NSView(frame: bounds)
        let outside = video(rect: CGRect(x: 900, y: 20, width: 320, height: 180))
        #expect(ChromiumPictureInPictureGeometry.windowRect(for: outside, in: webView, pageZoom: 1) == nil)
    }

    @Test func manualTabSwitchAppSwitchAndReturnShareTheLastVisibleRectangle() {
        var geometry = ChromiumPictureInPictureGeometry()
        let inline = video(id: "playing")
        let lastVisible = CGRect(x: 260, y: 140, width: 640, height: 360)
        let report = snapshot([inline], activeID: inline.id)
        geometry.update(report, visible: true) { _ in lastVisible }
        // Manual entry is measured while the page is visible.
        #expect(geometry.rect(for: geometry.snapshot?.activeID) == lastVisible)
        // A tab switch detaches the page before the native start arrives.
        var conversions = 0
        geometry.update(report, visible: false) { _ in conversions += 1; return .zero }
        #expect(conversions == 0)
        #expect(geometry.rect(for: geometry.snapshot?.activeID) == lastVisible)
        // An app switch can leave the view attached but the page's measurement hidden.
        let hidden = video(id: inline.id, rect: .zero, visible: false)
        geometry.update(snapshot([hidden], activeID: inline.id), visible: true) { _ in
            conversions += 1
            return .zero
        }
        #expect(conversions == 0)
        #expect(geometry.rect(for: geometry.snapshot?.activeID) == lastVisible)
        // Returning before a fresh measurement arrives retains the identical window-space target.
        #expect(geometry.rect(for: geometry.snapshot?.activeID) == lastVisible)
    }

    @Test func freshReturnMeasurementsReplaceOnlyThatVideosCache() {
        var geometry = ChromiumPictureInPictureGeometry()
        let first = video(id: "first"), second = video(id: "second")
        let firstRect = CGRect(x: 100, y: 200, width: 320, height: 180)
        let secondRect = CGRect(x: 500, y: 150, width: 240, height: 360)
        geometry.update(snapshot([first, second]), visible: true) { $0.id == first.id ? firstRect : secondRect }
        let returnedRect = CGRect(x: 130, y: 290, width: 480, height: 270)
        geometry.update(snapshot([first], activeID: first.id), visible: true) { _ in returnedRect }
        #expect(geometry.rect(for: first.id) == returnedRect)
        #expect(geometry.rect(for: second.id) == secondRect)
    }

    @Test func anInvalidFreshMeasurementRetainsTheCachedPosition() {
        var geometry = ChromiumPictureInPictureGeometry()
        let video = video()
        let rect = CGRect(x: 220, y: 170, width: 320, height: 180)
        let report = snapshot([video])
        geometry.update(report, visible: true) { _ in rect }
        for invalid in [CGRect.zero, .null, .infinite] {
            geometry.update(report, visible: true) { _ in invalid }
            #expect(geometry.rect(for: video.id) == rect)
        }
        geometry.update(report, visible: true) { _ in nil }
        #expect(geometry.rect(for: video.id) == rect)
    }

    @Test func missingMeasurementsNeverInventAnOriginOrBorrowAnotherVideosRectangle() {
        var geometry = ChromiumPictureInPictureGeometry()
        let first = video(id: "first"), second = video(id: "second", visible: false)
        geometry.update(snapshot([first, second], activeID: second.id), visible: true) { _ in
            CGRect(x: 120, y: 150, width: 320, height: 180)
        }
        #expect(geometry.rect(for: second.id) == nil)
        #expect(geometry.rect(for: "unknown") == nil)
        #expect(geometry.rect(for: nil) == nil)
    }

    @Test func aNewDocumentClearsTheOldVideosPositionsEvenWhileHidden() {
        var geometry = ChromiumPictureInPictureGeometry()
        let video = video()
        geometry.update(snapshot([video], documentID: "old"), visible: true) { _ in
            CGRect(x: 120, y: 150, width: 320, height: 180)
        }
        #expect(geometry.rect(for: video.id) != nil)
        geometry.update(snapshot([video], documentID: "new", activeID: video.id), visible: false) { _ in nil }
        #expect(geometry.windowRects.isEmpty)
        #expect(geometry.rect(for: video.id) == nil)
        #expect(geometry.snapshot?.documentID == "new")
    }

    private func video(id: String = "video", rect: CGRect = CGRect(x: 40, y: 60, width: 320, height: 180),
                       viewportOffset: CGPoint = .zero, viewportScale: CGFloat = 1,
                       devicePixelRatio: CGFloat = 2, visible: Bool = true) -> ChromiumPictureInPictureGeometry.Video {
        .init(id: id, rect: .init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height),
              viewportOffset: .init(x: viewportOffset.x, y: viewportOffset.y), viewportScale: viewportScale,
              devicePixelRatio: devicePixelRatio, visible: visible)
    }

    private func snapshot(_ videos: [ChromiumPictureInPictureGeometry.Video], documentID: String = "document",
                          activeID: String? = nil) -> ChromiumPictureInPictureGeometry.Snapshot {
        .init(documentID: documentID, videos: videos, activeID: activeID)
    }
}

@MainActor private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
