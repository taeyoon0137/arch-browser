// Where the agent panel shows (docs/agents.md, In the browser ▸ The agent panel; Sidebar and attention): in a main or small window's trailing column in place of the page reader and at its width, with the composer for a new task, one session's conversation, or an outside client's steps and the cards that wait for the user; the bottom bar's agents indicator, whose menu lists the acting sessions and outside clients and Stop All Agents; and the dot on the symbol of a space whose session waits for the user. The panel's views are the `Agent` module's; this file gives them the page reader's way of rendering replies and the window's ways of opening links and tabs.
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
                          openModelSettings: session.showAgentModelSettings)
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
                Text("Agent")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if case .session = content {
                    SidebarIconButton(symbol: "square.and.pencil", label: "New Agent Task") { windowModel.showAgentComposer() }
                }
                SidebarIconButton(symbol: "xmark", label: "Close Agent Panel", action: windowModel.hideAgentPanel)
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
                    Text("This session was deleted.")
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

/// A connected program's current access and its panel. Disconnect keeps its grant and cancels its work.
struct ConnectedAgentRows: View {
    @ObservedObject var agents: AgentService
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        let connected = agents.connectedGrants
        if !connected.isEmpty {
            ViewThatFits(in: .vertical) {
                rows(connected)
                ScrollView { rows(connected) }
            }
            .frame(maxHeight: min(CGFloat(connected.count) * 40, 120))
            .padding(.horizontal, SidebarView.inset)
        }
    }

    private func rows(_ grants: [AgentGrant]) -> some View {
        VStack(spacing: 0) {
            ForEach(grants) { grant in
                let name = grant.client.displayName
                let persona = agents.host.personas.first { $0.id == grant.personaID }?.name ?? "Deleted Persona"
                let access = "\(grant.level.title) · \(persona)"
                HStack(spacing: 8) {
                    Button { windowModel.showClientPanel(grant.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "terminal").frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).lineLimit(1)
                                Text(access).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(name)\n\(access)")
                    .accessibilityLabel("Show \(name)")
                    .accessibilityValue(access)
                    Button { agents.stopClient(grant.id) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Disconnect \(name)")
                    .accessibilityLabel("Disconnect \(name)")
                }
                .padding(.horizontal, 8)
                .frame(height: 40)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    Button(session.state == .waitingForUser ? "\(title) \u{2014} Waiting for You" : title) {
                        windowModel.showAgentSession(session.id)
                    }
                }
                ForEach(agents.connectedGrants) { grant in
                    let waits = approvals.pending.contains { $0.ownerID == grant.id }
                    Button(waits ? "\(grant.client.displayName) \u{2014} Waiting for You" : grant.client.displayName) { windowModel.showClientPanel(grant.id) }
                }
                Divider()
                Button("Stop All Agents", action: agents.stopAllAgents)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .symbolEffect(.pulse)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(approvals.pending.isEmpty ? "Agents are working" : "An agent is waiting for you")
            .accessibilityLabel("Agents")
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
                .accessibilityValue(isWaiting ? "An agent is waiting" : "")
        }
    }
}
