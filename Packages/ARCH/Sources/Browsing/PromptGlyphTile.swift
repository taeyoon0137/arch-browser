// The picture beside a prompt's title: an SF Symbol on a tile of its tint, or another app's icon. A compact card shows the symbol small before the title instead. Shapes and words carry the meaning, never the color alone.
import AppKit
import SwiftUI

struct PromptGlyphTile: View {
    let glyph: PromptGlyph
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        switch glyph {
        case let .symbol(name, tint, label):
            let fill = tint == .neutral ? Color.primary : tint.color
            let opacity = (colorScheme == .dark ? 0.24 : 0.14) + (contrast == .increased ? 0.08 : 0)
            PromptSymbol(name: name, tint: tint, size: 15)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill.opacity(tint == .neutral ? opacity * 0.6 : opacity)))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(fill.opacity(0.5))
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(label)
        case let .appIcon(image, label):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityLabel(label)
        }
    }
}

/// The glyph's symbol before the title of a compact card, which has no room for the tile.
struct PromptInlineGlyph: View {
    let glyph: PromptGlyph

    var body: some View {
        switch glyph {
        case let .symbol(name, tint, label):
            PromptSymbol(name: name, tint: tint, size: 13)
                .accessibilityLabel(label)
        case let .appIcon(image, label):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                // An image has no baseline, so it would sit on the title's; its center goes to the middle of the title's capitals, where the symbols sit.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                .accessibilityLabel(label)
        }
    }
}

/// A glyph's symbol in its tint. The warning triangle keeps its system colors, yellow with a dark mark.
private struct PromptSymbol: View {
    let name: String
    let tint: PromptTint
    let size: CGFloat

    var body: some View {
        if tint == .yellow {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .symbolRenderingMode(.multicolor)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint.color))
        }
    }
}

extension PromptTint {
    /// The system color of the tint. Neutral is the primary label color, which tiles use faintly.
    var color: Color {
        switch self {
        case .accent: .accentColor
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .red: .red
        case .yellow: .yellow
        case .neutral: .primary
        }
    }
}
