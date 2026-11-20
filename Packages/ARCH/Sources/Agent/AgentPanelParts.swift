// Shared controls and layout pieces for the in-app agent panel.
import SwiftUI

/// Shows a session title and status beside an optional action.
struct AgentStateHeader<Action: View>: View {
    let title: String
    let status: String
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer()
                action
            }
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Places panel content in a rounded section with consistent padding.
struct AgentSectionBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Aligns a detail label and its content in a panel row.
struct AgentDetailRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
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

/// Hides technical session details in a disclosure group.
struct AgentTechnicalDetails<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(title) { content }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
