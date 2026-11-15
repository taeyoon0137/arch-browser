// Scrolling a list while a drag holds the pointer near its ends (`DragAutoScroll.swift`): the bands and the eased step, the stop at each end, and the scroller moving an AppKit scroll view and a SwiftUI one, whose rows' frames follow, frame by frame. Placement after a scroll is in `SidebarTabSlotTests`; the display link, the gesture, and the feel are app checks.
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
        scroller.update(point: CGPoint(x: 120, y: 284), visible: visible, limit: 30)
        var frames = 0
        while scroller.advance(over: 1.0 / 60) != 0, frames < 100 { frames += 1 }
        #expect(frames == 10 && reported == Array(repeating: 3, count: 10))
        #expect(scrollView.contentView.bounds.minY == 30)
        // At the top edge: 12 points a frame, up to the top.
        scroller.update(point: CGPoint(x: 120, y: 0), visible: visible, limit: 30)
        #expect(scroller.advance(over: 1.0 / 60) == -12)
        #expect(scroller.advance(over: 1.0 / 60) == -12)
        #expect(scroller.advance(over: 1.0 / 60) == -6)
        #expect(scroller.advance(over: 1.0 / 60) == 0)
        #expect(scrollView.contentView.bounds.minY == 0)
        // Between the bands, without a pointer, and outside a scroll view, nothing scrolls.
        scroller.update(point: CGPoint(x: 120, y: 150), visible: visible, limit: 30)
        #expect(scroller.advance(over: 1.0 / 60) == 0)
        scroller.update(point: nil, visible: visible, limit: 30)
        #expect(scroller.advance(over: 1.0 / 60) == 0)
        let loose = DragAutoScroller.ScrollerView()
        loose.update(point: CGPoint(x: 120, y: 0), visible: visible, limit: 30)
        #expect(loose.advance(over: 1.0 / 60) == 0)
        #expect(reported.count == 13)
    }

    @Test func theScrollerScrollsASwiftUIScrollViewAndItsRowsFollow() async throws {
        let model = FixtureFrames()
        let host = NSHostingView(rootView: ScrollFixture(point: CGPoint(x: 100, y: 284), model: model))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { model.frames[0]?.minY == 0 })
        let scroller = try #require(descendants(of: host).compactMap { $0 as? DragAutoScroller.ScrollerView }.first)

        #expect(scroller.advance(over: 1.0 / 60) == 3)
        host.layoutSubtreeIfNeeded()
        // Each row is 3 points higher in the scroll view.
        #expect(await waitUntil { model.frames[0]?.minY == -3 && model.frames[5]?.minY == 5 * 38 - 3 })
        #expect(model.distances == [3])
        // A new body with the pointer between the bands keeps the scroll and stops it.
        let between = CGPoint(x: 100, y: 150), band = CGPoint(x: 100, y: 284)
        host.rootView = ScrollFixture(point: between, model: model)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { scroller.point == between })
        #expect(scroller.advance(over: 1.0 / 60) == 0)
        #expect(model.frames[0]?.minY == -3)
        // Back in the band, it stops once the last row shows: 458 points down, 3 at a time, with 2 in the last frame.
        host.rootView = ScrollFixture(point: band, model: model)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { scroller.point == band })
        var frames = 1
        while scroller.advance(over: 1.0 / 60) != 0, frames < 500 { frames += 1 }
        #expect(frames == 153 && model.distances.reduce(0, +) == ScrollFixture.limit)
        host.layoutSubtreeIfNeeded()
        #expect(await waitUntil { model.frames[19]?.maxY == 300 })
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
            .background(DragAutoScroller(point: point, visible: Self.visible, limit: Self.limit, onScroll: { model.distances.append($0) }).frame(width: 0, height: 0))
            .onPreferenceChange(FixtureFramesKey.self) { model.frames = $0 }
        }
        .coordinateSpace(name: "list")
        .frame(width: Self.visible.width, height: Self.visible.height)
    }
}

@MainActor private final class FixtureFrames {
    var frames: [Int: CGRect] = [:]
    var distances: [CGFloat] = []
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
