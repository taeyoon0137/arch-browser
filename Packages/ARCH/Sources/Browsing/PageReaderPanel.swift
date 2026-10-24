// The page reader: a panel beside the page that summarizes the selected tab's page and answers follow-up questions about it. Each tab keeps its own conversation, also while the panel is closed or another tab is selected.
import AI
import SwiftUI

/// Places the reader beside the page while it is open, a provider can serve it, and no internal page covers the tab. The page narrows to make room.
struct PageReaderColumn: View {
    static let width: CGFloat = 340

    @ObservedObject var session: BrowserSession
    @ObservedObject var assistant: PageAssistant
    @ObservedObject private var service = AIService.shared
    @ObservedObject private var settings = AIService.shared.settings

    var body: some View {
        if assistant.isReaderVisible, service.isAvailable(.pageReader), session.internalPage == nil {
            PageReaderPanel(assistant: assistant, tab: session.selectedTab)
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
    let tab: Tab?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Page Reader")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                SidebarIconButton(symbol: "xmark", label: "Close Page Reader", action: assistant.toggleReader)
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
                        PageExchangeView(exchange: exchange, assistant: assistant, pageURL: url) { conversation.retry(exchange.id) }
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
