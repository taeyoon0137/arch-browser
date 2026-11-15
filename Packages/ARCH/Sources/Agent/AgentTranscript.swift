// An in-app session's conversation as the agent panel shows it (docs/agents.md, In the browser ▸ The agent panel): the user's messages, the agent's replies and thinking from the CLI's stream, one step per tool call from Arch's tool host, notices, errors with one action each, and the model and tokens under each turn. It stays in memory until the session is deleted or Arch quits. Tool steps come from the host, not from the stream, so the panel shows what Arch did.
import AgentControl
import AI
import Foundation

/// A tool call as the panel names it: "Listed the agent tabs", with the tab it concerns and how it ended.
public struct AgentStep: Equatable, Sendable {
    public var tool: String
    public var sentence: String
    /// The handle of the tab the call named, such as `t1`, which the step's button shows.
    public var tabHandle: String?
    public var tabID: UUID?
    public var status: AgentResultStatus
}

/// A successful read's local document identity. These values never enter a model message.
struct AgentReadPage: Hashable {
    let tabID: UUID
    let handle: String
    let documentID: UUID
    let url: URL
    let ownerID: UUID?
}

/// What the panel offers beside an error, one action each (`docs/ai.md`, Errors).
public enum AgentErrorAction: Equatable, Sendable {
    /// Sends the last message again.
    case retry
    /// Opens the built-in terminal with the tool's sign-in typed.
    case signIn(AIProviderID)
    case openAISettings
}

public struct AgentTranscriptItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user(String)
        case reply(String)
        /// Shown collapsed.
        case thinking(String)
        case step(AgentStep)
        case notice(String)
        case error(String, AgentErrorAction?)
        /// The model and tokens under a turn; a subscription shows no cost.
        case turnFooter(model: AIModelRef?, usage: AIUsage?)
    }

    public let id: UUID
    public var kind: Kind
    /// Populated only on a turn footer, from successful host calls in that turn.
    var pagesRead: [AgentReadPage] = []

    init(_ kind: Kind) {
        id = UUID()
        self.kind = kind
    }
}

struct AgentTranscript: Equatable {
    private(set) var items: [AgentTranscriptItem] = []
    private(set) var retryableErrorID: UUID?
    /// The current turn's usage and whether its reply or thinking is still growing.
    private var turnUsage: AIUsage?
    private var turnPages: [AgentReadPage] = []
    private var growing: Growing?

    private enum Growing: Equatable {
        case reply, thinking
    }

    mutating func append(_ kind: AgentTranscriptItem.Kind) {
        growing = nil
        let item = AgentTranscriptItem(kind)
        items.append(item)
        if case .error(_, let action) = kind {
            retryableErrorID = action == .retry ? item.id : nil
        }
    }

    mutating func beginTurn(_ text: String, isRetry: Bool) {
        retryableErrorID = nil
        turnUsage = nil
        turnPages = []
        if !isRetry { append(.user(text)) }
    }

    /// Streamed text joins the reply it continues.
    mutating func replyText(_ text: String) {
        if growing == .reply, case .reply(let earlier)? = items.last?.kind {
            items[items.count - 1].kind = .reply(earlier + text)
        } else {
            append(.reply(text))
            growing = .reply
        }
    }

    mutating func thinkingText(_ text: String) {
        guard !text.isEmpty else { return }
        if growing == .thinking, case .thinking(let earlier)? = items.last?.kind {
            items[items.count - 1].kind = .thinking(earlier + text)
        } else {
            append(.thinking(text))
            growing = .thinking
        }
    }

    mutating func usage(_ usage: AIUsage) {
        turnUsage = usage
    }

    func containsRead(of tabID: UUID) -> Bool {
        items.contains { $0.pagesRead.contains { $0.tabID == tabID } }
    }

    mutating func read(_ page: AgentReadPage) {
        if !turnPages.contains(page) { turnPages.append(page) }
    }

    /// The footer under a turn that ended, with the model that held it.
    mutating func endTurn(model: AIModelRef?) {
        append(.turnFooter(model: model, usage: turnUsage))
        items[items.count - 1].pagesRead = turnPages
        turnPages = []
        turnUsage = nil
    }

    /// The last thing the user wrote, for Retry.
    var lastUserMessage: String? {
        items.reversed().lazy.compactMap { item -> String? in
            if case .user(let text) = item.kind { return text }
            return nil
        }.first
    }
}

/// The step sentences of the tools this build's host runs, and a plain one for the rest.
enum AgentStepText {
    /// `hostStep` is the tool host's sentence for a step that acts or navigates, such as "Clicked “Next” on example.org", whose page names stand in quotes.
    static func step(for call: AgentToolCall, result: AgentToolResult, tabHandle: String?, tabID: UUID?, hostStep: String? = nil) -> AgentStep {
        AgentStep(tool: call.name, sentence: sentence(for: call, result: result, hostStep: hostStep), tabHandle: tabHandle, tabID: tabID, status: result.status)
    }

    static func sentence(for call: AgentToolCall, result: AgentToolResult, hostStep: String? = nil) -> String {
        let done: String
        switch call.name {
        case "ask_user": done = "Asked you a question"
        case "request_tab": done = "Asked you to share a tab"
        case "read_text": done = "Read the page text"
        case "snapshot": done = "Read the page outline"
        case "session_info": done = "Read the session\u{2019}s details"
        case "list_spaces": done = "Listed the spaces"
        case "list_tabs": done = call.arguments["scope"]?.stringValue == "shared" ? "Listed the tabs you shared" : "Listed the agent tabs"
        case "guide":
            // The model wrote the topic, so only a topic the guide has appears in the sentence.
            done = call.arguments["topic"]?.stringValue.flatMap(AgentGuideTopic.init(rawValue:)).map { "Read the guide\u{2019}s \($0.rawValue) topic" } ?? "Read the guide"
        // A step that did not happen reads as what the agent asked for, such as "Open a page: you said no".
        case "open_tab": done = result.status == .ok ? "Opened a tab" : "Open a tab"
        case "navigate": done = result.status == .ok ? "Opened a page" : "Open a page"
        case "close_tab": done = result.status == .ok ? "Closed a tab" : "Close a tab"
        default:
            guard let tool = AgentToolCatalog.tool(named: call.name) else { return "Unrecognized tool" }
            done = hostStep ?? "Requested " + tool.name.replacingOccurrences(of: "_", with: " ")
        }
        // The sentence names a known code in words and never quotes the result's text; the activity log keeps the code.
        let reason: String? = switch result.code {
        case "stopped", "ended": "stopped with the turn"
        case "limitReached": "reached the call limit"
        case "tabNotFound": "the tab is gone"
        case "pageChanged": "the page changed"
        case "invalidArguments", "unknownTool", "notAvailable": "not available in this session"
        case let code? where code.first == "P" && Int(code.dropFirst()) != nil: "refused by an Arch rule"
        default: nil
        }
        switch result.status {
        case .ok, .approvalPending: return done
        case .denied where result.code == nil: return "\(done): you said no"
        case .refused, .denied: return "\(done): \(reason ?? "refused")"
        case .timeout: return "\(done): timed out"
        case .stale: return "\(done): the page changed"
        case .error: return "\(done): \(reason ?? "failed")"
        }
    }
}
