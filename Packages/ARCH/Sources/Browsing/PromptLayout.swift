// The size of a prompt card in its pane, and the compact layout of a narrow card, which drops the glyph tile, tightens the spacing, and stacks its buttons.
import CoreGraphics

/// A prompt card's layout, regular or compact, and its size in a pane.
enum PromptLayout: Equatable {
    case regular, compact

    static let preferredWidth: CGFloat = 420
    /// A narrower card uses the compact layout.
    static let compactBelow: CGFloat = 320

    /// 420 points, or the pane's width less 12 points a side; in a pane so narrow that leaves less than 200, the pane's width less 4 points a side.
    static func cardWidth(inPaneWidth paneWidth: CGFloat) -> CGFloat {
        let inset = paneWidth - 24
        return inset < 200 ? max(paneWidth - 8, 0) : min(preferredWidth, inset)
    }

    /// The pane's height less 16 points; a taller card scrolls between its identity row and its buttons.
    static func maximumHeight(inPaneHeight paneHeight: CGFloat) -> CGFloat {
        max(paneHeight - 16, 0)
    }

    static func layout(forCardWidth width: CGFloat) -> PromptLayout {
        width < compactBelow ? .compact : .regular
    }

    /// A regular spacing as this layout uses it.
    func spacing(_ regular: CGFloat) -> CGFloat {
        self == .compact ? regular * 0.75 : regular
    }
}
