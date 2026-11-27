import AppKit
import ScreenCaptureKit

/// Reads only this process's window pixels for a transient presentation, without attaching to the page's engine.
@MainActor enum WindowSnapshot {
    static func capture(_ view: NSView, completion: @escaping (NSImage?) -> Void) {
        guard #available(macOS 14.4, *), let window = view.window, window.isVisible, window.alphaValue == 1,
              window.windowNumber > 0, !window.isMiniaturized, !view.bounds.isEmpty,
              !view.isHiddenOrHasHiddenAncestor else { return completion(nil) }
        let windowID = CGWindowID(window.windowNumber)
        let frame = window.frame
        let bounds = view.bounds
        let viewFrame = view.convert(bounds, to: nil)
        let backingScale = window.backingScaleFactor
        guard frame.width > 0, frame.height > 0, backingScale > 0,
              CGRect(origin: .zero, size: frame.size).contains(viewFrame) else { return completion(nil) }
        let reply = Reply(completion)
        // The system capture can finish late; the caller gets one bounded answer and late pixels are discarded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak reply] in reply?.finish(nil) }
        Task { @MainActor [weak window, weak view] in
            @MainActor func isCurrent() -> Bool {
                guard let window, let view else { return false }
                return reply.isPending && window.isVisible && window.alphaValue == 1 && !window.isMiniaturized
                    && window.windowNumber == Int(windowID) && window.frame == frame
                    && window.backingScaleFactor == backingScale && view.window === window
                    && view.bounds == bounds && view.convert(bounds, to: nil) == viewFrame
                    && !view.isHiddenOrHasHiddenAncestor
            }
            do {
                // This API lists only content capturable by the current process without TCC consent.
                let content = try await SCShareableContent.currentProcess
                guard isCurrent(), let source = content.windows.first(where: { $0.windowID == windowID }),
                      source.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier else {
                    reply.finish(nil)
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: source)
                let configuration = SCStreamConfiguration()
                configuration.width = Int(ceil(frame.width * backingScale))
                configuration.height = Int(ceil(frame.height * backingScale))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.ignoreGlobalClipSingleWindow = true
                configuration.includeChildWindows = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard isCurrent() else { return reply.finish(nil) }
                // Window coordinates start at bottom-left; image pixels start at top-left.
                let scaleX = CGFloat(image.width) / frame.width
                let scaleY = CGFloat(image.height) / frame.height
                let pixels = CGRect(x: viewFrame.minX * scaleX, y: (frame.height - viewFrame.maxY) * scaleY,
                                    width: viewFrame.width * scaleX, height: viewFrame.height * scaleY)
                guard let crop = image.cropping(to: pixels) else { return reply.finish(nil) }
                reply.finish(NSImage(cgImage: crop, size: bounds.size))
            } catch {
                reply.finish(nil)
            }
        }
    }

    private final class Reply {
        private var completion: ((NSImage?) -> Void)?
        var isPending: Bool { completion != nil }

        init(_ completion: @escaping (NSImage?) -> Void) { self.completion = completion }

        func finish(_ image: NSImage?) {
            guard let completion else { return }
            self.completion = nil
            completion(image)
        }
    }
}
