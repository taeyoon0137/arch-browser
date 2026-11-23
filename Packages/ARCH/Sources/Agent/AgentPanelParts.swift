// Shared controls, metrics, and plain-language status words for the in-app agent panel (docs/agent-panel-design.md).
import AgentControl
import SwiftUI

/// The panel's sizes, as docs/agent-panel-design.md names them.
enum AgentPanelMetrics {
    /// The column's horizontal content inset.
    static let inset: CGFloat = 14
    static let titleSize: CGFloat = 13
    static let bodySize: CGFloat = 13
    static let supportingSize: CGFloat = 12
    static let detailSize: CGFloat = 11
    /// The inset inside a section box, and its corner radius.
    static let boxPadding: CGFloat = 10
    static let boxRadius: CGFloat = 10
    /// The user's message bubble: its inner padding, and the leading room that sets it apart from the agent's replies.
    static let bubblePadding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    static let bubbleLeadingRoom: CGFloat = 36
    /// The tallest a card's page capture is drawn, so its answer buttons stay in view.
    static let captureMaxHeight: CGFloat = 160
    /// The longest side of the capture's larger view.
    static let largeCaptureMaxSide: CGFloat = 640
    /// The share of the panel's height that waiting cards may take; the transcript keeps the rest.
    static let pendingShare: CGFloat = 0.6
    static let pendingMinHeight: CGFloat = 180
}

/// The fills the panel uses, by role.
enum AgentPanelFill {
    /// The user's own messages and the attachment chip.
    static let user = Color.primary.opacity(0.07)
    /// Exact text the user reviews before a decision.
    static let exactText = Color.primary.opacity(0.06)
    static let box = Color(nsColor: .controlBackgroundColor)
}

extension AgentResultStatus {
    /// What a step's result means, in words a person reads; nil for a step that went through.
    var plainWords: String? {
        switch self {
        case .ok: return nil
        case .denied: return localized("You declined")
        case .refused: return localized("Not allowed")
        case .stale: return localized("The page changed")
        case .timeout: return localized("Timed out")
        case .approvalPending: return localized("Waiting for you")
        case .error: return localized("Didn\u{2019}t work")
        }
    }

    /// The step's mark: secondary for a step that went through, orange otherwise.
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle"
        case .denied: return "hand.raised"
        case .refused: return "nosign"
        case .timeout, .approvalPending: return "clock"
        case .stale, .error: return "exclamationmark.triangle"
        }
    }

    var tint: Color { self == .ok ? .secondary : .orange }
}

/// Offers its content at most `maxHeight` and takes only the height the content uses. `frame(maxHeight:)` would instead grow to the offered height, so a short card would push the transcript away.
struct AgentHeightCap: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(proposal.height ?? maxHeight, maxHeight)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Shows a session title and status beside an optional action.
struct AgentStateHeader<Action: View>: View {
    let title: String
    let status: String
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: AgentPanelMetrics.titleSize, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .help(title)
                Spacer()
                action
            }
            Text(status).font(.system(size: AgentPanelMetrics.detailSize)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, AgentPanelMetrics.inset)
        .padding(.vertical, 8)
    }
}

/// Places panel content in a rounded section with consistent padding.
struct AgentSectionBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(AgentPanelMetrics.boxPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AgentPanelMetrics.boxRadius).fill(AgentPanelFill.box))
    }
}

/// A detail label and its content on one line, inside a section box, which gives the inset.
struct AgentDetailRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
        }
        .font(.system(size: AgentPanelMetrics.supportingSize))
    }
}

/// Shows a compact button for a primary session action.
struct AgentPrimaryAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action).controlSize(.small)
    }
}

/// Hides details in a disclosure group whose title is secondary; the content keeps its own styles, so controls in it do not read as disabled.
struct AgentTechnicalDetails<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup {
            content
        } label: {
            Text(title)
                .font(.system(size: AgentPanelMetrics.detailSize))
                .foregroundStyle(.secondary)
        }
    }
}
