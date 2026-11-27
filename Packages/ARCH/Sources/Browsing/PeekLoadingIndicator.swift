import AppKit
import SwiftUI

/// The modal's loading track pulses before becoming a moving bar on longer loads.
struct PeekLoadingIndicator: NSViewRepresentable {
    let isLoading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.spaceTheme) private var theme

    func makeNSView(context: Context) -> PeekLoadingTrackView { PeekLoadingTrackView() }

    func updateNSView(_ view: PeekLoadingTrackView, context: Context) {
        let foreground = theme.isPrivate || colorScheme == .dark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8)
            : NSColor(displayP3Red: 14.0 / 255, green: 15.0 / 255, blue: 16.0 / 255, alpha: 0.9)
        view.update(isLoading: isLoading, reduceMotion: reduceMotion, foreground: foreground)
    }

    static func dismantleNSView(_ view: PeekLoadingTrackView, coordinator: ()) { view.stopClock() }
}

final class PeekLoadingTrackView: NSView {
    private enum Phase { case hidden, pulse, carousel }
    private let track = CALayer()
    private let fill = CALayer()
    private let bar = CAShapeLayer()
    private var phase = Phase.hidden
    private var isLoading = false
    private var timedOut = false
    private var reduceMotion = false
    private var foreground = NSColor.labelColor
    private var clock: Timer?
    private var loadStart = CACurrentMediaTime()
    private var motion = TrackMotion(value: 0, velocity: 0, target: 0, response: 0.8, damping: 0.92)

    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 4) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 4))
        wantsLayer = true
        track.masksToBounds = true
        track.cornerCurve = .continuous
        track.bounds = CGRect(x: 0, y: 0, width: 48, height: 4)
        track.cornerRadius = 2
        fill.frame = CGRect(x: 0, y: 0, width: 128, height: 4)
        fill.opacity = 0
        bar.frame = fill.frame
        bar.lineWidth = 4
        bar.opacity = 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 2))
        path.addLine(to: CGPoint(x: 128, y: 2))
        bar.path = path
        track.addSublayer(fill)
        track.addSublayer(bar)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopClock() } else { startClockIfNeeded() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawFrame(at: CACurrentMediaTime())
    }

    func update(isLoading: Bool, reduceMotion: Bool, foreground: NSColor) {
        self.foreground = foreground
        let loadingChanged = self.isLoading != isLoading
        let motionPreferenceChanged = self.reduceMotion != reduceMotion
        self.isLoading = isLoading
        self.reduceMotion = reduceMotion
        if loadingChanged {
            stopClock()
            let now = CACurrentMediaTime()
            let current = motion.sample(at: now)
            if isLoading { loadStart = now }
            timedOut = false
            motion = TrackMotion(value: current.value, velocity: current.velocity, target: isLoading ? 0.5 : 0,
                                 response: isLoading ? 3.2 : 0.8, damping: isLoading ? 0 : 0.92, start: now)
            setPhase(isLoading ? .pulse : .hidden, animated: !reduceMotion)
        } else if motionPreferenceChanged {
            // The presentation preference does not restart the load or its timeout.
            stopClock()
            setPhase(phase, animated: false)
        }
        drawFrame(at: CACurrentMediaTime())
        startClockIfNeeded()
    }

    func stopClock() { clock?.invalidate(); clock = nil }

    private func startClockIfNeeded() {
        guard window != nil else { stopClock(); return }
        if reduceMotion, !isLoading || timedOut { stopClock(); return }
        let current = motion.sample(at: CACurrentMediaTime())
        guard (isLoading && !timedOut) || abs(current.value) > 0.001 || abs(current.velocity) > 0.001 else { stopClock(); return }
        guard clock == nil else { return }
        let timer = Timer(timeInterval: reduceMotion ? 0.25 : 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.drawFrame(at: CACurrentMediaTime())
            }
        }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setPhase(_ next: Phase, animated: Bool) {
        phase = next
        let showsCarousel = next == .carousel && !reduceMotion
        let width: CGFloat = showsCarousel ? 128 : 48
        let bounds = CGRect(x: 0, y: 0, width: width, height: 4)
        let opacity: Float = showsCarousel ? 0.92 : 0
        if animated {
            animate(track, key: "bounds", from: NSValue(rect: track.presentation()?.bounds ?? track.bounds), to: NSValue(rect: bounds))
            animate(bar, key: "opacity", from: bar.presentation()?.opacity ?? bar.opacity, to: opacity)
        } else {
            track.removeAllAnimations()
            bar.removeAllAnimations()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.bounds = bounds
        bar.opacity = opacity
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, key: String, from: Any, to: Any) {
        let spring = CASpringAnimation(keyPath: key)
        let frequency = 2 * Double.pi / 0.8
        spring.mass = 1
        spring.stiffness = frequency * frequency
        spring.damping = 2 * 0.92 * frequency
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: key)
    }

    private func drawFrame(at now: TimeInterval) {
        var current = motion.sample(at: now)
        if isLoading, !timedOut, now - loadStart >= 30 {
            timedOut = true
            motion = TrackMotion(value: current.value, velocity: current.velocity, target: 0, response: 0.8, damping: 0.92, start: now)
            setPhase(.hidden, animated: !reduceMotion)
        }
        if !reduceMotion, isLoading, phase == .pulse, now - loadStart > 3.2, current.value <= 0.05 {
            motion = TrackMotion(value: current.value, velocity: current.velocity, target: 1, response: 0.8, damping: 0.92, start: now)
            setPhase(.carousel, animated: true)
            current = motion.sample(at: now)
        }
        let progress = reduceMotion ? (isLoading && !timedOut ? 1.0 : 0.0) : current.value
        var brightness: CGFloat = 0
        var color = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = foreground.usingColorSpace(.sRGB) ?? foreground
            brightness = resolved.brightnessComponent
            color = resolved.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color
        bar.strokeColor = color
        track.transform = CATransform3DMakeScale(0.88 + 0.12 * progress, 0.88 + 0.12 * progress, 1)
        let baseOpacity = phase == .carousel && !reduceMotion ? (brightness < 0.3 ? 0.276 : 0.46) : 0.92
        fill.opacity = Float(max(0, min(1, baseOpacity * progress)))
        if phase == .carousel && !reduceMotion {
            let cycle = max(0, now - loadStart - 3.2).truncatingRemainder(dividingBy: 1.125)
            bar.strokeStart = cycle >= 0.375 && cycle < 0.75 ? (cycle - 0.375) / 0.375 : 0
            bar.strokeEnd = cycle < 0.375 ? cycle / 0.375 : (cycle < 0.75 ? 1 : 0)
        }
        if (!isLoading || timedOut), reduceMotion || (abs(current.value) <= 0.001 && abs(current.velocity) <= 0.001) {
            fill.opacity = 0
            stopClock()
        }
        CATransaction.commit()
    }
}

/// Analytic solution of the track's spring, preserving velocity when its phase changes.
private struct TrackMotion {
    let value: Double
    let velocity: Double
    let target: Double
    let response: Double
    let damping: Double
    var start = CACurrentMediaTime()

    func sample(at now: TimeInterval) -> (value: Double, velocity: Double) {
        let time = max(0, now - start)
        let frequency = 2 * Double.pi / response
        let decay = damping * frequency
        let damped = frequency * sqrt(1 - damping * damping)
        let displacement = value - target
        let sineCoefficient = (velocity + decay * displacement) / damped
        let sine = sin(damped * time), cosine = cos(damped * time)
        let envelope = exp(-decay * time)
        return (target + envelope * (displacement * cosine + sineCoefficient * sine),
                envelope * ((sineCoefficient * damped - decay * displacement) * cosine - (displacement * damped + decay * sineCoefficient) * sine))
    }
}
