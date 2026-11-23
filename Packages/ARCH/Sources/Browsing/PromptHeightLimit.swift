// Gives its view the height of its content, up to a limit, whatever height its container offers. A taller view gets the limit, which a prompt card fills by scrolling between its identity row and its buttons. A frame with only a maximum height would take all the height its container offers, up to that maximum.
import SwiftUI

/// A layout that gives its one view its content's height, up to `maxHeight`; `PromptCard` and `PromptScrollArea` use it.
struct PromptHeightLimit: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
