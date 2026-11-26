// Keeps each video's last visible animation rectangle in its originating window.
import AppKit

struct ChromiumPictureInPictureGeometry {
    struct Snapshot: Decodable {
        var documentID: String
        var videos: [Video]
        var activeID: String?
    }

    struct Video: Decodable {
        struct Rect: Decodable { var x: CGFloat; var y: CGFloat; var width: CGFloat; var height: CGFloat }
        struct Point: Decodable { var x: CGFloat; var y: CGFloat }
        var id: String
        var rect: Rect
        var viewportOffset: Point
        var viewportScale: CGFloat
        var devicePixelRatio: CGFloat
        var visible: Bool

        /// DOM rectangles already include scrolling. Page zoom converts CSS pixels to view points;
        /// Retina scale converts those points to pixels and back, so it must not be applied again.
        func viewRect(in bounds: CGRect, isFlipped: Bool, pageZoom: CGFloat) -> CGRect? {
            guard pageZoom.isFinite, pageZoom > 0, viewportScale.isFinite, viewportScale > 0,
                  devicePixelRatio.isFinite, devicePixelRatio > 0,
                  viewportOffset.x.isFinite, viewportOffset.y.isFinite,
                  ChromiumPictureInPicture.validRect(bounds) else { return nil }
            let scale = pageZoom * viewportScale
            let x = (rect.x - viewportOffset.x) * scale
            let y = (rect.y - viewportOffset.y) * scale
            let width = rect.width * scale, height = rect.height * scale
            let result = CGRect(x: bounds.minX + x, y: isFlipped ? bounds.minY + y : bounds.maxY - y - height,
                                width: width, height: height)
            return ChromiumPictureInPicture.validRect(result) ? result : nil
        }
    }

    private(set) var snapshot: Snapshot?
    private(set) var windowRects: [String: CGRect] = [:]

    /// A hidden or invalid report can select a video but cannot erase its last visible position.
    mutating func update(_ report: Snapshot, visible: Bool, convert: (Video) -> CGRect?) {
        if snapshot?.documentID != report.documentID { windowRects.removeAll() }
        snapshot = report
        guard visible else { return }
        for video in report.videos where video.visible {
            if let rect = convert(video), ChromiumPictureInPicture.validRect(rect) { windowRects[video.id] = rect }
        }
    }

    func rect(for videoID: String?) -> CGRect? {
        videoID.flatMap { windowRects[$0] }
    }

    /// The native viewport at a transition. A reply can arrive after a tab has detached, so retain
    /// its conversion rather than converting through a view whose window has already changed.
    struct Viewport {
        let bounds: CGRect
        let isFlipped: Bool
        let pageZoom: CGFloat
        private let toWindow: CGAffineTransform

        @MainActor init(webView: NSView, pageZoom: CGFloat) {
            bounds = webView.bounds
            isFlipped = webView.isFlipped
            self.pageZoom = pageZoom
            let origin = webView.convert(CGPoint.zero, to: nil)
            let x = webView.convert(CGPoint(x: 1, y: 0), to: nil)
            let y = webView.convert(CGPoint(x: 0, y: 1), to: nil)
            toWindow = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                         c: y.x - origin.x, d: y.y - origin.y,
                                         tx: origin.x, ty: origin.y)
        }

        func windowRect(for video: Video) -> CGRect? {
            guard let local = video.viewRect(in: bounds, isFlipped: isFlipped, pageZoom: pageZoom),
                  local.intersects(bounds) else { return nil }
            let rect = local.applying(toWindow)
            return ChromiumPictureInPicture.validRect(rect) ? rect : nil
        }
    }

    /// Entry and return cache the same bottom-origin AppKit window rectangle.
    @MainActor static func windowRect(for video: Video, in webView: NSView, pageZoom: CGFloat) -> CGRect? {
        Viewport(webView: webView, pageZoom: pageZoom).windowRect(for: video)
    }
}
