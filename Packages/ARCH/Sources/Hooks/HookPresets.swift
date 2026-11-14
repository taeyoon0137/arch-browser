// An editable starting point in Settings. A preset has no registered hook or AI feature until the user saves it.
import Agent
import Events
import Foundation

public enum HookPresets {
    public static var tidyTabNames: Hook {
        var hook = Hook(name: "Tidy Tab Names", trigger: .pageLoaded(loads: .firstAfterOpen, includesRestoredTabs: false),
                        filter: BrowserEventFilter(tabKinds: [.open, .pinned]), state: .paused(.user), origin: .preset("tidyTabNames"))
        let prompt = """
        Give this browser tab a short name that tells it apart from other tabs: at most four words, in the language of its title. Use the title and address in the tab block, and drop site names, slogans, counters, and separators unless the name needs them. Call rename_tab once with the name. If the title is already short and clear, do not call it.
        """
        let options = AgentRunOptions(prompt: prompt, tabAccess: .title, model: .tier(.fast), record: .none, tools: ["rename_tab"],
                                      limits: AgentRunLimits(timeout: .seconds(20), rounds: 1, toolCalls: 2))
        AgentHookTemplate.configure(&hook, options: options, dailyLimit: 300, delay: .milliseconds(1500), generated: true)
        return hook
    }
}
