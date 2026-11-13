// Where the agent panel shows (docs/agents.md, In the browser ▸ The agent panel; Sidebar and attention): in a main window's trailing column in place of the page reader and at its width, with the composer for a new task or one session's conversation, and the bottom bar's agents indicator, whose menu lists the acting sessions and outside clients and Stop All Agents. The panel's views are the `Agent` module's; this file gives them the page reader's way of rendering replies and the window's ways of opening links and tabs.
import Agent
import AI
import SwiftUI

/// What the agent panel shows.
public enum AgentPanelContent: Equatable {
    case composer(AgentComposerContext)
    case session(UUID)
}

struct AgentPanelColumn: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        if let content = windowModel.agentPanel, let agents = session.agents {
            AgentPanelFrame(agents: agents, content: content, actions: actions)
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
                              windowModel.openTab(url: url)
                          },
                          showTab: { [windowModel] id in windowModel.selectTab(id) },
                          openAISettings: { [session] in session.pageAssistant.showAISettings?() },
                          signIn: { [session] provider in session.signInToAgentTool?(provider) })
    }
}

private struct AgentPanelFrame: View {
    @ObservedObject var agents: AgentService
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let content: AgentPanelContent
    let actions: AgentPanelActions

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
                AgentComposer(service: agents, context: context, actions: actions) { windowModel.showAgentSession($0.id) }
                    // A new context, as from New Agent Task with another tab selected, starts a new draft.
                    .id(context.id)
            case .session(let id):
                if let session = agents.session(withID: id) {
                    AgentSessionPanel(service: agents, session: session, actions: actions)
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
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        if agents.isAnyAgentActing {
            Menu {
                ForEach(agents.sessions.filter(\.isTurnRunning)) { session in
                    Button("\(session.title) \u{2014} \(agents.place(of: session))") { windowModel.showAgentSession(session.id) }
                }
                ForEach(agents.grants.filter { agents.connectedGrantIDs.contains($0.id) }) { grant in
                    Text(grant.client.displayName)
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
            .help("Agents are working")
            .accessibilityLabel("Agents")
        }
    }
}
