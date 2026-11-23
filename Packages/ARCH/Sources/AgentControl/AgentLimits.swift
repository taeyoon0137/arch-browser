// The limits every client of the tool host meets (docs/agents.md, Tools ▸ Limits). The tool catalog's schemas carry the per-call ones, so that a client sees them before it calls; the tool host enforces all of them.
import Foundation

/// Limits shared by agent tools, sessions, approvals, and event streams.
public enum AgentLimits {
    /// A snapshot's characters when the call names no `max_chars`, and the most a call may ask for. A cut lands on an element boundary.
    public static let snapshotDefaultCharacters = 16_000
    public static let snapshotMaximumCharacters = 40_000
    /// `read_text`'s characters per call, from a read of the page's text of at most `readTextMaximumCharacters`.
    public static let readTextCharactersPerCall = 20_000
    public static let readTextMaximumCharacters = 400_000
    /// The text of any one result, in bytes (48 KB).
    public static let resultTextBytes = 48 * 1024
    /// A name a page gives in a result, such as its title, a link's scheme, or a download's file name, in characters; a longer one is cut and ends with an ellipsis.
    public static let pageNameCharacters = 300

    /// A screenshot's longest side in pixels, its JPEG quality, and its size in bytes (1 MB). A full page taller than `screenshotFullPageCSSHeight` CSS pixels is cut there.
    public static let screenshotLongestSide = 1_568
    public static let screenshotJPEGQuality = 0.8
    public static let screenshotBytes = 1024 * 1024
    public static let screenshotFullPageCSSHeight = 8_000

    /// Agent tabs open at once per session or outside client.
    public static let agentTabs = 20
    /// Tool calls per user turn and per session in the app, per grant per day, and actions per second.
    public static let toolCallsPerTurn = 150
    public static let toolCallsPerSession = 600
    public static let toolCallsPerGrantPerDay = 2_000
    public static let actionsPerSecond = 10
    /// How long `wait_for`, and any other tool except those that wait for the user, may take.
    public static let toolWaitSeconds = 30
    /// `search_history`'s results per call.
    public static let historyResults = 20

    /// How long an in-app session's approval stays open, the outside clients' choices and default (Settings ▸ AI ▸ Agents), and how soon any call that waits for the user answers, with `approvalPending` if the user has not.
    public static let inAppApprovalMinutes = 10
    public static let outsideApprovalMinuteChoices = [2, 5, 10]
    public static let outsideApprovalDefaultMinutes = 5
    public static let callAnswerSeconds = 45

    /// Hours without a user message after which a session's CLI process ends; the next message continues as after Stop.
    public static let sessionIdleHours = 2
    /// Calls one connection runs at a time; more are refused with `busy`.
    public static let callsPerConnection = 4

    /// Outside programs' events (`docs/hooks.md`, arch-cli events; arch-mcp): the events Arch keeps per grant, the subscriptions a connection holds, the events a connection's queue holds before it drops the oldest, and the events one `watch_events` call returns.
    public static let eventBuffer = 500
    public static let subscriptionsPerConnection = 4
    public static let eventQueue = 1_000
    public static let watchEventsPerCall = 100
}
