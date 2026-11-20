import SwiftUI

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

struct AgentSectionBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

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

struct AgentPrimaryAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action).controlSize(.small)
    }
}

struct AgentTechnicalDetails<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(title) { content }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
