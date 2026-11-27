// Measured playback bars use the sidebar's existing selection fill.
import AppKit
import ARCHEngine
import SwiftUI

/// Draw over the backing and below the icon, title and controls.
struct TabPlaybackWaveform: View {
    @ObservedObject var tab: Tab
    var isEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.spaceTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bands = Data()

    var body: some View {
        GeometryReader { geometry in
            if bands.count == 24 {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<24) { index in
                        Rectangle()
                            .fill(SidebarFill.selected.color(in: colorScheme, isPrivate: theme.isPrivate))
                            .frame(width: geometry.size.width / 24, height: geometry.size.height)
                            .scaleEffect(y: 0.12 + 0.6 * Double(bands[bands.startIndex + index]) / 255, anchor: .bottom)
                    }
                }
                .animation(.linear(duration: 1.0 / 15), value: bands)
                .transition(.identity)
            }
        }
        // The AppKit view observes visibility and measurements; it draws no content.
        .background {
            PlaybackSpectrumObserver(feed: tab.webContents.audioSpectrum,
                                     isEnabled: isEnabled && !tab.isAudioMuted && !reduceMotion) {
                bands = $0
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PlaybackSpectrumObserver: NSViewRepresentable {
    let feed: (any EngineAudioSpectrum)?
    let isEnabled: Bool
    let receive: (Data) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.update(feed: feed, isEnabled: isEnabled, receive: receive)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.tearDown()
    }

    final class ObserverView: NSView {
        private var feed: (any EngineAudioSpectrum)?
        private var observation: UUID?
        private var generation = 0
        private var isEnabled = false
        private var receive: (Data) -> Void = { _ in }
        private var pendingBands = Data()
        private var deliveredBands = Data()
        private var deliveryScheduled = false
        private weak var observedClip: NSClipView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(feed: (any EngineAudioSpectrum)?, isEnabled: Bool, receive: @escaping (Data) -> Void) {
            self.receive = receive
            if self.feed !== feed {
                disconnect()
                self.feed = feed
            }
            self.isEnabled = isEnabled
            refresh()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            observedClip = nil
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                       name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            observeScroll()
            refresh()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeScroll()
            refresh()
        }

        override func viewDidHide() {
            super.viewDidHide()
            refresh()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            refresh()
        }

        override func layout() {
            super.layout()
            observeScroll()
            refresh()
        }

        func tearDown() {
            NotificationCenter.default.removeObserver(self)
            disconnect()
            feed = nil
            receive = { _ in }
        }

        private var isVisible: Bool {
            window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        }

        private func observeScroll() {
            let clip = enclosingScrollView?.contentView
            guard clip !== observedClip else { return }
            if let observedClip {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip)
            }
            observedClip = clip
            if let clip {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
            }
        }

        @objc private func visibilityChanged(_ notification: Notification) { refresh() }

        private func refresh() {
            guard isEnabled && isVisible && bounds.width > 0 && bounds.height > 0, let feed else {
                disconnect()
                return
            }
            guard observation == nil else { return }
            generation += 1
            let currentGeneration = generation
            observation = feed.observe { [weak self] bands in
                guard let self, self.generation == currentGeneration else { return }
                self.deliver(bands.count == 24 && bands.contains(where: { $0 != 0 }) ? bands : Data())
            }
        }

        private func disconnect() {
            generation += 1
            if let observation {
                self.observation = nil
                feed?.removeObserver(observation)
            }
            deliver(Data())
        }

        private func deliver(_ bands: Data) {
            pendingBands = bands
            guard !deliveryScheduled, pendingBands != deliveredBands else { return }
            deliveryScheduled = true
            // An engine may immediately deliver its current measure from observe(). Defer the
            // isolated drawing state update until after SwiftUI finishes updating this observer.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deliveryScheduled = false
                guard self.pendingBands != self.deliveredBands else { return }
                self.deliveredBands = self.pendingBands
                self.receive(self.deliveredBands)
            }
        }
    }
}
