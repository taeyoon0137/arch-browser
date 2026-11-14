// Generated hook scripts dispatch an event's typed agent options without adding page content to its instructions.
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
              await arch.agent.run({ ...event.hook.agent, closedTab: event.tab.id, tabs: left.map(tab => tab.id) });
            """
        case .spaceSwitched:
            body = """
              const tabs = (await arch.tabs.list()).filter(tab => tab.spaceId === event.spaceId);
              await arch.agent.run({ ...event.hook.agent, tabs: tabs.map(tab => tab.id) });
            """
        case .downloadFinished:
            body = """
              if (event.download?.tabId) await arch.agent.run({ ...event.hook.agent, tabs: [event.download.tabId] });
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

    public static func configure(_ hook: inout Hook, options: AgentRunOptions, dailyLimit: Int, delay: Duration, generated: Bool) {
        hook.agent = options
        hook.record = options.record
        hook.grant.permissions.insert(.agent)
        if generated { hook.grant.permissions = [.agent] }
        hook.grant.agent = AgentRunGrant(tools: Set(options.tools), tabAccess: options.tabAccess, minimumRecord: options.record,
                                        maximumRecord: options.record, runsPerDay: dailyLimit, limits: options.limits)
        hook.timing = HookTiming(delay: delay, timeout: options.limits.timeout, runsPerDay: dailyLimit)
        hook.script = .javaScript(digest: hook.script.digest, generated: generated)
    }
}
