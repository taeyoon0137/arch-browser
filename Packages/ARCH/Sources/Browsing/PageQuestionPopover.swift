// The question popover: a question about the page, or about text selected in it, answered in a panel that floats over the page's top trailing corner, with Continue as Agent Task beside its Ask. The palette's Ask About This Page and the page context menu's Ask About Selection open it.
import AI
import SwiftUI

/// Shows the window's popover while it is open for the selected tab and no internal page covers the tab.
struct PageQuestionLayer: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        if let question = windowModel.pageQuestion, question.tabID == windowModel.selectedTabID, windowModel.internalPage == nil, let tab = windowModel.selectedTab {
            PageQuestionPopover(assistant: session.pageAssistant, question: question, tab: tab, conversation: question.conversation)
                // A new question gets a fresh field.
                .id(question.id)
        }
    }
}

private struct PageQuestionPopover: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let assistant: PageAssistant
    let question: PageQuestion
    @ObservedObject var tab: Tab
    @ObservedObject var conversation: PageConversation
    @ObservedObject private var settings = AIService.shared.settings
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(question.selection == nil ? "Ask About This Page" : "Ask About Selection")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                SidebarIconButton(symbol: "xmark", label: "Close Question", action: dismiss)
            }
            if let selection = question.selection {
                SelectionQuote(text: selection.text)
            }
            if let url = tab.url, !settings.allowsAI(on: url) {
                PageAIOffNotice(url: url)
            } else {
                questionField
                if let exchange = conversation.exchanges.last {
                    let answer = PageExchangeView(exchange: exchange, assistant: assistant, tab: tab, pageURL: tab.url, showsSelection: false) { conversation.retry(exchange.id) }
                    // As tall as the reply, up to a limit; a longer reply scrolls.
                    ViewThatFits(in: .vertical) {
                        answer
                        ScrollView { answer }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .padding(12)
        // Narrower in a narrow pane, so the popover stays over its page.
        .frame(maxWidth: 380)
        // A solid background, as the find bar has: a material over the engine's view cannot sample it.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .onAppear { DispatchQueue.main.async { isFieldFocused = true } }
        .onChange(of: tab.documentID) { _, current in
            if current != question.documentID { dismiss() }
        }
        // Allow AI on This Site puts the field in the notice's place, and the field takes the keys as on opening.
        .onChange(of: tab.url.map { settings.allowsAI(on: $0) }) { _, allows in
            if allows == true { DispatchQueue.main.async { isFieldFocused = true } }
        }
    }

    private var questionField: some View {
        HStack(spacing: 4) {
            TextField(question.selection == nil ? "Ask a question about this page" : "Ask a question about the selection", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .reportsFocus(of: .question, isFocused: isFieldFocused)
                .onSubmit(send)
                .onExitCommand(perform: dismiss)
            ContinueAsAgentTaskButton(source: .init(tab: tab, documentID: question.documentID, questionID: question.id),
                                      draft: draft, exchanges: conversation.exchanges, selection: question.selection)
            if conversation.isAnswering {
                SidebarIconButton(symbol: "stop.circle", label: "Stop Answering", action: conversation.cancel)
            } else {
                SidebarIconButton(symbol: "arrow.up.circle", label: "Ask", action: send)
                    .disabled(text.isEmpty)
            }
        }
    }

    private var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func dismiss() { windowModel.dismissPageQuestion(question.id) }

    private func send() {
        guard !text.isEmpty, windowModel.pageQuestion?.id == question.id, question.documentID == tab.documentID else { return }
        question.ask(text)
        draft = ""
    }
}
