// Scrolling a list while a drag holds the pointer near its ends (`DragAutoScroll.swift`): the bands and the eased step, a drag that starts in a band, the stop at each end, the steps on whole pixels, and the scroller moving an AppKit scroll view and a SwiftUI one, whose rows' frames follow, frame by frame, and reporting each scroll under the drag. Placement after a scroll is in `SidebarTabSlotTests`; the display link, the gesture, and the feel are app checks.
import AppKit
import SwiftUI
import Testing
@testable import Browsing

@MainActor
@Suite struct DragAutoScrollTests {
    /// The visible list in the window, as in `SidebarTabSlotTests`: from 40 down to 540.
    private let list = CGRect(x: 0, y: 40, width: 240, height: 500)

    private func step(_ y: CGFloat, in visible: CGRect? = nil, over interval: TimeInterval = 1.0 / 60) -> CGFloat {
        DragAutoScroll.step(at: CGPoint(x: 120, y: y), in: visible ?? list, over: interval)
    }

    @Test func eachBandScrollsTowardItsEdgeFasterNearerTheEdge() {
        // Between the bands, on their inner edges, and outside the list, nothing scrolls.
        for y: CGFloat in [72, 290, 508, 30, 540, 600] { #expect(step(y) == 0) }
        #expect(DragAutoScroll.step(at: CGPoint(x: 250, y: 50), in: list) == 0)
        // At the edge the step is 12 points; halfway into a band, a quarter of that.
        #expect(step(40) == -12)
        #expect(step(56) == -3 && step(524) == 3)
        #expect(abs(step(539) - 12 * (31.0 / 32) * (31.0 / 32)) < 1e-9)
        // It grows on the way to each edge, alike at both ends.
        let towardTop = [70, 60, 50, 41].map { -step($0) }, towardBottom = [510, 520, 530, 539].map { step($0) }
        #expect(towardTop == towardBottom && towardTop.allSatisfy { $0 > 0 })
        #expect(zip(towardTop, towardTop.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func theStepFollowsTheFramesIntervalAndAShortListSplitsItsBands() {
        // Per sixtieth of a second, so a 120 Hz display scrolls as fast with half steps.
        #expect(step(40, over: 1.0 / 120) == -6)
        #expect(step(40, over: 1.0 / 30) == -24)
        // A list of 40 points has bands of 20, and its middle scrolls neither way.
        let short = CGRect(x: 0, y: 0, width: 240, height: 40)
        #expect(step(10, in: short) == -3 && step(20, in: short) == 0 && step(30, in: short) == 3)
        #expect(step(0, in: CGRect(x: 0, y: 0, width: 240, height: 0)) == 0)
    }

    @Test func aDragThatStartsInABandScrollsOnceItLeavesTheBandOrHeadsForItsEdge() {
        func arms(from start: CGFloat, at y: CGFloat) -> Bool {
            DragAutoScroll.arms(from: CGPoint(x: 120, y: start), at: CGPoint(x: 120, y: y), in: list)
        }
        // A row grabbed 10 points above the list's bottom moves within the band without scrolling, until it is 8 points nearer the edge or out of the band.
        #expect(!arms(from: 530, at: 526) && !arms(from: 530, at: 537) && !arms(from: 530, at: 509))
        #expect(arms(from: 530, at: 538) && arms(from: 530, at: 508) && arms(from: 530, at: 300))
        // The same at the top, where the pointer also leaves the band past the list's edge.
        #expect(!arms(from: 50, at: 43) && !arms(from: 50, at: 71))
        #expect(arms(from: 50, at: 42) && arms(from: 50, at: 72) && arms(from: 50, at: 30))
        // A drag that starts between the bands scrolls as soon as it reaches one.
        #expect(arms(from: 290, at: 530) && arms(from: 290, at: 290))
    }

    @Test func theListStopsAtEitherEnd() {
        #expect(DragAutoScroll.distance(12, from: 0, limit: 300) == 12)
        #expect(DragAutoScroll.distance(12, from: 295, limit: 300) == 5)
        #expect(DragAutoScroll.distance(12, from: 300, limit: 300) == 0)
        #expect(DragAutoScroll.distance(-12, from: 5, limit: 300) == -5)
        #expect(DragAutoScroll.distance(-12, from: 0, limit: 300) == 0)
        // A list scrolled past its limit, as into the height a dragged folder's hidden rows keep, scrolls up but no further down.
        #expect(DragAutoScroll.distance(12, from: 320, limit: 300) == 0)
        #expect(DragAutoScroll.distance(-12, from: 320, limit: 300) == -12)
        // Content shorter than the list does not scroll.
        #expect(DragAutoScroll.distance(12, from: 0, limit: 0) == 0)
    }

    @Test func stepsUnderAPixelAddUpAndTheListStopsOnWholePixels() throws {
        // At 2 pixels a point, 0.1875 points a frame scrolls half a point every two or three frames, carrying the rest.
        var offset: CGFloat = 100, carried: CGFloat = 0, offsets: [CGFloat] = []
        for _ in 0..<8 {
            let next = try #require(DragAutoScroll.scroll(from: offset, by: 0.1875, carrying: carried, limit: 300, scale: 2))
            (offset, carried) = next
            offsets.append(offset)
        }
        #expect(offsets == [100, 100, 100.5, 100.5, 100.5, 101, 101, 101.5] && carried == 0)
        // From an offset off the grid, the list scrolls up onto it, and the last frame reaches the top.
        offset = 10.25
        offsets = []
        while let next = DragAutoScroll.scroll(from: offset, by: -3, carrying: carried, limit: 300, scale: 2), offsets.count < 10 {
            (offset, carried) = next
            offsets.append(offset)
        }
        #expect(offsets == [7.5, 4.5, 1.5, 0])
        // An end off the grid is reached exactly, once the carried part reaches it.
        let first = try #require(DragAutoScroll.scroll(from: 100, by: 0.125, carrying: 0, limit: 100.25, scale: 2))
        #expect(first == (100, 0.125))
        let last = try #require(DragAutoScroll.scroll(from: 100, by: 0.125, carrying: 0.125, limit: 100.25, scale: 2))
        #expect(last == (100.25, 0))
        #expect(DragAutoScroll.scroll(from: 100.25, by: 0.125, carrying: 0, limit: 100.25, scale: 2) == nil)
        // A step toward the other end drops what was carried; a step that stays on a pixel moves nothing.
        let turned = try #require(DragAutoScroll.scroll(from: 100, by: -0.125, carrying: 0.375, limit: 300, scale: 2))
        #expect(turned == (100, -0.125))
        // At 1 pixel a point, whole steps stay whole.
        let whole = try #require(DragAutoScroll.scroll(from: 30, by: 3, carrying: 0, limit: 300, scale: 1))
        #expect(whole == (33, 0))
    }

    @Test func theScrollerMovesItsEnclosingScrollViewFrameByFrameUntilTheEnd() {
        let visible = CGRect(x: 0, y: 0, width: 240, height: 300)
        let scrollView = NSScrollView(frame: visible)
        let document = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 240, height: 330))
        scrollView.documentView = document
        let scroller = DragAutoScroller.ScrollerView()
        document.addSubview(scroller)
        var reported: [CGFloat] = []
        scroller.onScroll = { reported.append($0) }

        // Halfway into the bottom band: 3 points a frame, down to the limit of 30.
        scroller.update(point: CGPoint(x: 120, y: 284), scrolls: true, visible: visible, limit: 30)
        var frames = 0
        while scroller.advance(over: 1.0 / 60) != nil, frames < 100 { frames += 1 }
        #expect(frames == 10 && reported == Array(repeating: 3, count: 10))
        #expect(scrollView.contentView.bounds.minY == 30)
        // At the top edge: 12 points a frame, up to the top.
        scroller.update(point: CGPoint(x: 120, y: 0), scrolls: true, visible: visible, limit: 30)
        #expect(scroller.advance(over: 1.0 / 60) == -12)
        #expect(scroller.advance(over: 1.0 / 60) == -12)
        #expect(scroller.advance(over: 1.0 / 60) == -6)
        #expect(scroller.advance(over: 1.0 / 60) == nil)
        #expect(scrollView.contentView.bounds.minY == 0)
        // Before the drag arms the bands, between them, without a pointer, and outside a scroll view, nothing scrolls.
        scroller.update(point: CGPoint(x: 120, y: 299), scrolls: false, visible: visible, limit: 30)
        #expect(scroller.advance(over: 1.0 / 60) == nil)
        scroller.update(point: CGPoint(x: 120, y: 150), scrolls: true, visible: visible, limit: 30)
        #expect(scroller.advance(over: 1.0 / 60) == nil)
        scroller.update(point: nil, scrolls: true, visible: visible, limit: 30)
        #expect(scroller.advance(over: 1.0 / 60) == nil)
        let loose = DragAutoScroller.ScrollerView()
        loose.update(point: CGPoint(x: 120, y: 0), scrolls: true, visible: visible, limit: 30)
        #expect(loose.advance(over: 1.0 / 60) == nil)
        #expect(reported.count == 13 && scrollView.contentView.bounds.minY == 0)
    }

    @Test func theScrollerReportsEachScrollUnderTheDragAndStopsWhereTheScrollViewRefusesOne() {
        let visible = CGRect(x: 0, y: 0, width: 240, height: 300)
        let scrollView = NSScrollView(frame: visible)
        scrollView.contentView = ConstrainedClip()
        scrollView.documentView = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 240, height: 330))
        let clip = scrollView.contentView
        let scroller = DragAutoScroller.ScrollerView()
        scrollView.documentView?.addSubview(scroller)
        var reported: [CGFloat] = []
        scroller.onScroll = { reported.append($0) }
        // Without a drag, a scroll goes unreported.
        clip.scroll(to: NSPoint(x: 0, y: 10))
        #expect(reported.isEmpty)
        // During a drag, another input's scroll, such as a mouse's wheel, is reported, also before the drag arms the bands.
        scroller.update(point: CGPoint(x: 120, y: 150), scrolls: false, visible: visible, limit: 30)
        clip.scroll(to: NSPoint(x: 0, y: 25))
        clip.scroll(to: NSPoint(x: 0, y: 5))
        #expect(reported == [15, -20])
        // With a limit past the document's end, a clip view that keeps its bounds in the document stops the list at 30. The reports add up to the distance the list moved, and the scroll the clip view refuses ends the scrolling.
        reported = []
        scroller.update(point: CGPoint(x: 120, y: 299), scrolls: true, visible: visible, limit: 60)
        var frames = 0
        while scroller.advance(over: 1.0 / 60) != nil, frames < 100 { frames += 1 }
        #expect(frames < 100 && clip.bounds.minY == 30 && reported.reduce(0, +) == 25)
        // After the drag, scrolls go unreported again.
        scroller.update(point: nil, scrolls: false, visible: visible, limit: 30)
        clip.scroll(to: NSPoint(x: 0, y: 0))
        #expect(reported.reduce(0, +) == 25)
    }

    @Test func theScrollerScrollsASwiftUIScrollViewAndItsRowsFollow() async throws {
        let model = FixtureFrames()
        let host = NSHostingView(rootView: ScrollFixture(point: CGPoint(x: 100, y: 284), model: model))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { model.frames[0]?.minY == 0 })
        let scroller = try #require(descendants(of: host).compactMap { $0 as? DragAutoScroller.ScrollerView }.first)

        #expect(scroller.advance(over: 1.0 / 60) == 3)
        // The scroll is reported before the rows report their new frames.
        #expect(model.distances == [3] && model.firstRowTopAtEachScroll == [0])
        host.layoutSubtreeIfNeeded()
        // Each row is 3 points higher in the scroll view.
        #expect(await waitUntil { model.frames[0]?.minY == -3 && model.frames[5]?.minY == 5 * 38 - 3 })
        #expect(model.distances == [3])
        // A new body with the pointer between the bands keeps the scroll and stops it.
        let between = CGPoint(x: 100, y: 150), band = CGPoint(x: 100, y: 284)
        host.rootView = ScrollFixture(point: between, model: model)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { scroller.point == between })
        #expect(scroller.advance(over: 1.0 / 60) == nil)
        #expect(model.frames[0]?.minY == -3)
        // Back in the band, it stops once the last row shows: 458 points down, 3 at a time, with 2 in the last frame.
        host.rootView = ScrollFixture(point: band, model: model)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { scroller.point == band })
        var frames = 1
        while scroller.advance(over: 1.0 / 60) != nil, frames < 500 { frames += 1 }
        #expect(frames == 153 && model.distances.reduce(0, +) == ScrollFixture.limit)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { model.frames[19]?.maxY == 300 })
        // After the layout, SwiftUI keeps the list at its end, so nothing scrolls it back and the scroller stays stopped.
        host.layoutSubtreeIfNeeded()
        #expect(scroller.advance(over: 1.0 / 60) == nil)
        #expect(model.distances.reduce(0, +) == ScrollFixture.limit && model.frames[19]?.maxY == 300)
    }
}

/// Twenty rows of 36 points, 2 apart, in a scroll view 300 points tall, with the scroller in their content as a space's list has it.
private struct ScrollFixture: View {
    static let visible = CGRect(x: 0, y: 0, width: 200, height: 300)
    static let limit: CGFloat = 20 * 36 + 19 * 2 - 300

    let point: CGPoint?
    let model: FixtureFrames

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { index in
                    Color.clear.frame(height: 36)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: FixtureFramesKey.self, value: [index: proxy.frame(in: .named("list"))])
                        })
                }
            }
            .frame(maxWidth: .infinity)
            .background(DragAutoScroller(point: point, scrolls: true, visible: Self.visible, limit: Self.limit, onScroll: { distance in
                model.distances.append(distance)
                model.firstRowTopAtEachScroll.append(model.frames[0]?.minY)
            }).frame(width: 0, height: 0))
            .onPreferenceChange(FixtureFramesKey.self) { model.frames = $0 }
        }
        .coordinateSpace(name: "list")
        .frame(width: Self.visible.width, height: Self.visible.height)
    }
}

@MainActor private final class FixtureFrames {
    var frames: [Int: CGRect] = [:]
    var distances: [CGFloat] = []
    /// The first row's top as reported when each scroll is.
    var firstRowTopAtEachScroll: [CGFloat?] = []
}

private struct FixtureFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A clip view whose scrolls stay within its document, unlike `NSClipView.scroll(to:)`, which also goes past it, as SwiftUI's does.
private final class ConstrainedClip: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: constrainBoundsRect(NSRect(origin: newOrigin, size: bounds.size)).origin)
    }
}

private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(of: $0) }
}

/// Waits up to `limit` for `condition`, checking every 10 milliseconds.
@MainActor private func waitUntil(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
