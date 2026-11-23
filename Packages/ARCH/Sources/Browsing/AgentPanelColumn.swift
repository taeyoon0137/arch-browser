// The agent panel replaces the page reader in a main or small window's trailing column, at the reader's width (docs/agents.md, The agent panel).
// It shows a new-task composer, one session's conversation, or an outside client's steps and pending cards.
// The bottom bar's agents menu lists active sessions and outside clients and offers Stop All Agents. A space symbol gets a dot while its session waits for the user.
// `Agent` owns the views. This file supplies the reader's reply rendering and the window's link and tab actions.
import Agent
import AI
import SwiftUI

/// What the agent panel shows.
public enum AgentPanelContent: Equatable {
    case composer(AgentComposerContext)
    case session(UUID)
    /// An outside client's panel, by its grant's ID.
    case client(UUID)
}

struct AgentPanelColumn: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        if case .client(let ownerID) = windowModel.agentPanel, let agents = session.agents {
            AgentPanel(model: agents.panel, ownerID: ownerID, close: windowModel.hideAgentPanel)
                .frame(width: PageReaderColumn.width)
                .background(PageFrameShape().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
                .padding(EdgeInsets(top: BrowserWindowView.pageMargin, leading: 0, bottom: BrowserWindowView.pageMargin, trailing: BrowserWindowView.pageMargin))
                .transition(.move(edge: .trailing))
        } else if let content = windowModel.agentPanel, let agents = session.agents {
            AgentPanelFrame(agents: agents, permissions: session.sitePermissions, content: content, actions: actions, keepTabs: windowModel.panelKeepTabsAction)
                .frame(width: PageReaderColumn.width)
                // The page's own margin separates it from the panel.
                .padding(EdgeInsets(top: BrowserWindowView.pageMargin, leading: 0, bottom: BrowserWindowView.pageMargin, trailing: BrowserWindowView.pageMargin))
                .transition(.move(edge: .trailing))
        }
    }

    private var actions: AgentPanelActions {
        AgentPanelActions(formatReply: PageReply.text,
                          openLink: { [windowModel] url in
                              guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
                              windowModel.openReplyLink(url, in: windowModel.personaID)
                          },
                          showTab: { [windowModel] id in windowModel.showAgentTab(id) },
                          openAISettings: { [session] in session.pageAssistant.showAISettings?() },
                          signIn: { [session] provider in session.signInToAgentTool?(provider) },
                          openModelSettings: session.showAgentModelSettings,
                          showReadTab: { [windowModel] id in windowModel.showReadTab(id) })
    }
}

private struct AgentPanelFrame: View {
    @ObservedObject var agents: AgentService
    @ObservedObject var permissions: SitePermissionStore
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let content: AgentPanelContent
    let actions: AgentPanelActions
    let keepTabs: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if case .session = content {
                    SidebarIconButton(symbol: "square.and.pencil", label: localized("New Agent Task")) { windowModel.showAgentComposer() }
                }
                SidebarIconButton(symbol: "xmark", label: localized("Close Agent Panel"), action: windowModel.hideAgentPanel)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 40)
            Divider()
            switch content {
            case .composer(let context):
                let note = permissions.agentPermissionNote(for: context.personaID, agentOnlyPersonaID: windowModel.session.agentOnlyPersonaID)
                AgentComposer(service: agents, context: context, actions: actions, permissionNote: note) {
                    windowModel.agentTaskDidStart($0.id, from: context)
                }
                // A new context, as from New Agent Task with another tab selected, starts a new draft.
                .id(context.id)
            case .client:
                // The column shows an outside client's panel on its own.
                EmptyView()
            case .session(let id):
                if let session = agents.session(withID: id) {
                    AgentSessionPanel(service: agents, session: session, actions: actions, keepTabs: keepTabs)
                        .id(id)
                } else {
                    Text("This session was deleted.", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(PageFrameShape().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
    }
}

/// A connected program's current access and its panel. Disconnect keeps its grant and cancels its work. The sidebar's list scrolls the rows and gives them its inset.
struct ConnectedAgentRows: View {
    @ObservedObject var agents: AgentService

    var body: some View {
        let connected = agents.connectedGrants
        if !connected.isEmpty {
            VStack(spacing: 2) {
                ForEach(connected) { ConnectedAgentRow(agents: agents, grant: $0) }
            }
        }
    }
}

/// Drawn as a plugin's sidebar row, with the access and "Persona / Space" on a second line.
private struct ConnectedAgentRow: View {
    let agents: AgentService
    let grant: AgentGrant
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        let name = grant.client.displayName
        let access = "\(grant.level.localizedTitle) \u{00B7} \(agents.place(of: grant))"
        HStack(spacing: 8) {
            Button { windowModel.showClientPanel(grant.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                        Text(access).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(name)\n\(access)")
            .accessibilityLabel(localized("Show \(name)"))
            .accessibilityValue(access)
            Button { agents.stopClient(grant.id) } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(localized("Disconnect \(name)"))
            .accessibilityLabel(localized("Disconnect \(name)"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering ? SidebarFill.hover.color(in: colorScheme) : .clear))
        .onHover { isHovering = $0 }
    }
}

/// The bottom bar's agents indicator, while a session's turn runs or an outside client is connected.
struct AgentsIndicator: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        if let agents = session.agents {
            AgentsIndicatorMenu(agents: agents)
        }
    }
}

private struct AgentsIndicatorMenu: View {
    @ObservedObject var agents: AgentService
    /// The cards that wait, which a client's row names, since a composer or a session in the column does not give way to a client's panel.
    @ObservedObject var approvals: AgentApprovals
    @EnvironmentObject private var windowModel: BrowserWindowModel

    init(agents: AgentService) {
        self.agents = agents
        approvals = agents.approvals
    }

    var body: some View {
        if agents.isAnyAgentActing {
            Menu {
                ForEach(agents.sessions.filter(\.isTurnRunning)) { session in
                    let title = "\(session.title) \u{2014} \(agents.place(of: session))"
                    Button(session.state == .waitingForUser ? localized("\(title) \u{2014} Waiting for You") : title) {
                        windowModel.showAgentSession(session.id)
                    }
                }
                ForEach(agents.connectedGrants) { grant in
                    let waits = approvals.pending.contains { $0.ownerID == grant.id }
                    Button(waits ? localized("\(grant.client.displayName) \u{2014} Waiting for You") : grant.client.displayName) { windowModel.showClientPanel(grant.id) }
                }
                Divider()
                Button(localized("Stop All Agents"), action: agents.stopAllAgents)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .symbolEffect(.pulse)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(approvals.pending.isEmpty ? localized("Agents are working") : localized("An agent is waiting for you"))
            .accessibilityLabel(localized("Agents"))
        }
    }
}

/// A dot on the bottom bar's symbol of a space other than the window's own while a session of that space waits for the user. It follows the symbol's scale.
struct AgentWaitingDot: ViewModifier {
    let agents: AgentService?
    let spaceID: UUID
    let isCurrent: Bool
    let scale: CGFloat

    /// Only `agents` chooses the branch, which stays the same for the app's life, so switching spaces keeps the symbol's identity and its size and color animate.
    @ViewBuilder func body(content: Content) -> some View {
        if let agents {
            content.modifier(Mark(agents: agents, spaceID: spaceID, isCurrent: isCurrent, scale: scale))
        } else {
            content
        }
    }

    private struct Mark: ViewModifier {
        @ObservedObject var agents: AgentService
        let spaceID: UUID
        let isCurrent: Bool
        let scale: CGFloat

        func body(content: Content) -> some View {
            let isWaiting = !isCurrent && agents.spacesWaitingForUser.contains(spaceID)
            content
                .overlay {
                    if isWaiting {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            // Beside the symbol's top trailing corner; scaling after the offset shrinks the distance with the symbol.
                            .offset(x: 6, y: -6)
                            .scaleEffect(scale)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityValue(isWaiting ? localized("An agent is waiting") : "")
        }
    }
}
