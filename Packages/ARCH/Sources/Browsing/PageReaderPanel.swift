// The page reader: a panel beside the page that summarizes the selected tab's page and answers follow-up questions about it, with Continue as Agent Task beside its Ask. Each tab keeps its own conversation, also while the panel is closed or another tab is selected.
import Agent
import AI
import SwiftUI

/// Places the reader beside the page while it is open, a provider can serve it, and no internal page covers the tab. The page narrows to make room.
struct PageReaderColumn: View {
    static let width: CGFloat = 340

    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject private var service = AIService.shared
    @ObservedObject private var settings = AIService.shared.settings

    var body: some View {
        if windowModel.isPageReaderVisible, service.isAvailable(.pageReader), windowModel.internalPage == nil {
            PageReaderPanel(assistant: session.pageAssistant, tab: windowModel.selectedTab)
                .frame(width: Self.width)
                // The page's own margin separates it from the panel.
                .padding(EdgeInsets(top: BrowserWindowView.pageMargin, leading: 0, bottom: BrowserWindowView.pageMargin, trailing: BrowserWindowView.pageMargin))
                .transition(.move(edge: .trailing))
        }
    }
}

/// Observes the assistant, which publishes a change when a tab's conversation goes, so a tab that moved to another site shows a new one.
private struct PageReaderPanel: View {
    @ObservedObject var assistant: PageAssistant
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let tab: Tab?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Page Reader")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                SidebarIconButton(symbol: "xmark", label: "Close Page Reader", action: windowModel.togglePageReader)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 40)
            Divider()
            if let tab {
                PageReaderTabView(assistant: assistant, tab: tab, conversation: assistant.readerConversation(for: tab))
                    // Each tab has its own draft and scroll position.
                    .id(tab.id)
            } else {
                PageReaderPlaceholder(text: "Open a page to read it here.")
            }
        }
        .background(PageFrameShape().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(PageFrameShape().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
    }
}

/// The selected tab's conversation and the field for the next question, or what keeps the reader from reading the page.
private struct PageReaderTabView: View {
    let assistant: PageAssistant
    @ObservedObject var tab: Tab
    @ObservedObject var conversation: PageConversation
    @ObservedObject private var settings = AIService.shared.settings
    @State private var draft = ""

    var body: some View {
        if let url = tab.url, PageAssistant.canRead(url) {
            if settings.allowsAI(on: url) {
                VStack(spacing: 0) {
                    exchanges(about: url)
                    Divider()
                    questionField
                }
            } else {
                PageAIOffNotice(url: url)
                    .padding(14)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            PageReaderPlaceholder(text: "The page reader reads web pages and local files.")
        }
    }

    /// Follows the reply as it streams in.
    private func exchanges(about url: URL) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(conversation.exchanges) { exchange in
                        PageExchangeView(exchange: exchange, assistant: assistant, tab: tab, pageURL: url, startOver: { conversation.startOver(asking: exchange.id) }) { conversation.retry(exchange.id) }
                            .id(exchange.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: conversation.exchanges.last?.reply) {
                if let last = conversation.exchanges.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .overlay {
            if conversation.exchanges.isEmpty {
                Button("Summarize This Page") { assistant.summarize(tab) }
            }
        }
    }

    private var questionField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("Ask about this page", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .onSubmit(send)
                .padding(.vertical, 6)
            ContinueAsAgentTaskButton(tab: tab, draft: draft, exchanges: conversation.exchanges)
            if conversation.isAnswering {
                SidebarIconButton(symbol: "stop.circle", label: "Stop Answering", action: conversation.cancel)
            } else {
                SidebarIconButton(symbol: "arrow.up.circle", label: "Ask", action: send)
                    .disabled(question.isEmpty)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    private var question: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !question.isEmpty else { return }
        assistant.askInReader(question, about: tab)
        draft = ""
    }
}

private struct PageReaderPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Continue as Agent Task beside Ask in the page reader and the question popover (docs/agents.md, In the browser ▸ Starting a session), while a Claude Code or Codex model can run a session: the composer with the question and the selected tab, whose page the question is about.
struct ContinueAsAgentTaskButton: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let tab: Tab
    let draft: String
    let exchanges: [PageConversation.Exchange]
    var selection: AISelection? = nil

    var body: some View {
        if windowModel.canStartAgentTask {
            SidebarIconButton(symbol: "arrowshape.turn.up.right", label: "Continue as Agent Task") {
                let excerpt = Self.excerpt(tabID: tab.id, url: tab.url, exchange: exchanges.last, selection: selection)
                windowModel.continueAsAgentTask(Self.task(draft: draft, exchanges: exchanges), excerpt: excerpt)
            }
        }
    }

    /// The question typed in the field, or else the last question the user asked. A summary, which Arch asks for, shows a title of its own and gives no question, and neither the selected text nor a reply joins the task, which carries only the user's words.
    static func task(draft: String, exchanges: [PageConversation.Exchange]) -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return typed }
        return exchanges.last { $0.title == $0.prompt }?.prompt ?? ""
    }

    /// Only the visible selection and a completed answer from this page are offered to the composer.
    static func excerpt(tabID: UUID, url: URL?, exchange: PageConversation.Exchange?, selection: AISelection?) -> AgentReaderExcerpt? {
        guard let url else { return nil }
        let selected = selection ?? exchange?.selection
        let reply: String?
        if let exchange, exchange.replySourceURL == url, case .finished(.completed) = exchange.state {
            reply = exchange.reply
        } else {
            reply = nil
        }
        return AgentReaderExcerpt(tabID: tabID, url: url, selection: selected?.pageURL == url ? selected?.text : nil, reply: reply)
    }
}
