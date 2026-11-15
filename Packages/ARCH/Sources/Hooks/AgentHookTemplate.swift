// Generated hook scripts dispatch an event's typed agent options without adding page content to its instructions. A script calls no agent when no tab is left to act on, as for the last tab's close or a switch to an empty space, so that such an event costs no run.
import Agent
import Events
import Foundation

public enum AgentHookTemplate {
    public static func script(for kind: BrowserEventKind) -> String {
        let body: String
        switch kind {
        case .tabClosed:
            body = """
              const left = (await arch.tabs.list()).filter(tab => tab.spaceId === event.tab.spaceId);
              if (left.length) await arch.agent.run({ ...event.hook.agent, closedTab: event.tab.id, tabs: left.map(tab => tab.id) });
            """
        case .spaceSwitched:
            body = """
              const tabs = (await arch.tabs.list()).filter(tab => tab.spaceId === event.spaceId);
              if (tabs.length) await arch.agent.run({ ...event.hook.agent, tabs: tabs.map(tab => tab.id) });
            """
        case .downloadFinished:
            body = """
              const tabId = event.download?.tabId;
              if (tabId && (await arch.tabs.list()).some(tab => tab.id === tabId)) await arch.agent.run({ ...event.hook.agent, tabs: [tabId] });
            """
        default:
            body = """
              await arch.agent.run({ ...event.hook.agent, tabs: [event.tab.id] });
            """
        }
        return """
        arch.events.on("\(kind.rawValue)", async event => {
        \(body)
        });

        """
    }

    /// The hook's timeout is the agent run's time limit and 5 seconds, since the hook's counts from its step's start, before its script and the agent run start.
    public static func configure(_ hook: inout Hook, options: AgentRunOptions, dailyLimit: Int, delay: Duration, generated: Bool) {
        hook.agent = options
        hook.record = options.record
        hook.grant.permissions.insert(.agent)
        if generated { hook.grant.permissions = [.agent] }
        hook.grant.agent = AgentRunGrant(tools: Set(options.tools), tabAccess: options.tabAccess, minimumRecord: options.record,
                                        maximumRecord: options.record, runsPerDay: dailyLimit, limits: options.limits)
        hook.timing = HookTiming(delay: delay, timeout: options.limits.timeout + .seconds(5), runsPerDay: dailyLimit)
        hook.script = .javaScript(digest: hook.script.digest, generated: generated)
    }
}
