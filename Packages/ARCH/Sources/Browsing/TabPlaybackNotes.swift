// Rising notes behind a playing tab's icon, for engines that supply no measured spectrum.
import AppKit
import SwiftUI

/// Notes rise from the icon's center while the tab plays sound and its engine has no spectrum feed.
/// Size the view to the row or tile's backing; the notes stay inside its rounded corners.
struct TabPlaybackNotes: View {
    @ObservedObject var tab: Tab
    var isEnabled = true
    /// The icon center's distance from the leading edge; nil centers it, as in a favorite tile.
    var iconCenterX: CGFloat?
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isEnabled && tab.isAudible && tab.webContents.audioSpectrum == nil && !reduceMotion {
            NoteEmitter(isDark: colorScheme == .dark, iconCenterX: iconCenterX, cornerRadius: cornerRadius)
                // A new emitter restarts the notes in the new appearance's color.
                .id(colorScheme)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct NoteEmitter: NSViewRepresentable {
    let isDark: Bool
    let iconCenterX: CGFloat?
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> EmitterView { EmitterView(isDark: isDark) }
    func updateNSView(_ view: EmitterView, context: Context) {
        view.iconCenterX = iconCenterX
        // SwiftUI clipping does not reach an AppKit view, so its layer clips the notes to the backing's corners.
        view.layer?.cornerRadius = cornerRadius
        view.needsLayout = true
    }

    final class EmitterView: NSView {
        private let emitter = CAEmitterLayer()
        var iconCenterX: CGFloat?

        init(isDark: Bool) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.cornerCurve = .continuous
            emitter.emitterShape = .circle
            emitter.emitterSize = CGSize(width: 6, height: 6)
            emitter.emitterCells = [Self.cell(isDark: isDark)]
            layer?.addSublayer(emitter)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            emitter.frame = bounds
            emitter.emitterPosition = CGPoint(x: iconCenterX ?? bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        /// Each note starts at no size, grows, drifts upward, and fades.
        private static func cell(isDark: Bool) -> CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = noteImage
            cell.contentsScale = 2
            // The white note takes the cell's color: dark in the light appearance, light in the dark one.
            cell.color = isDark ? CGColor(gray: 1, alpha: 0.64) : CGColor(gray: 0, alpha: 0.36)
            cell.birthRate = 2.4
            cell.lifetime = 2
            cell.scale = 0
            cell.scaleRange = 0.2
            cell.scaleSpeed = 1
            cell.alphaRange = 0.15
            cell.alphaSpeed = -0.5
            // The view is not flipped, so a quarter turn points up.
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 3
            cell.velocity = 20
            cell.velocityRange = 5
            return cell
        }

        /// A white 12-point note drawn at twice its size.
        private static let noteImage: CGImage? = {
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            guard let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return nil }
            let side: CGFloat = 12
            guard let context = CGContext(data: nil, width: Int(side * 2), height: Int(side * 2), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: 2, y: 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let size = symbol.size
            symbol.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                   width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
        }()
    }
}
