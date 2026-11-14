// The first message of an in-app session (agent decision 12): a short preamble with the handles of the tabs the user attached, then the user's words. Session facts never go into the CLI's arguments, and the preamble names no title, address, or page text: the agent reads those through its tools, whose results Arch checks against the site exclusions and marks as untrusted.
import Foundation

enum AgentSessionPreamble {
    static func firstMessage(_ words: String, attachedTabHandles: [String]) -> String {
        let tabs: String
        switch attachedTabHandles.count {
        case 0: tabs = "The user attached no tab."
        case 1: tabs = "The user attached the tab \(attachedTabHandles[0]), which list_tabs with scope shared lists."
        default: tabs = "The user attached the tabs \(attachedTabHandles.joined(separator: ", ")), which list_tabs with scope shared lists."
        }
        return """
            <arch-session>
            This message starts a session in Arch. \(tabs) Call session_info first for the session context and any reader excerpt the user shared.
            </arch-session>

            \(words)
            """
    }
}
