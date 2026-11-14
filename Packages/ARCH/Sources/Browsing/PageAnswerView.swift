// What the page reader and the question popover show for each question: the reply as text with inline Markdown, the model that wrote it with its tokens and estimated cost, and the AI module's errors with one action each. Also the notice and the switch for a site where AI is off.
import AI
import SwiftUI

/// One question and its reply.
struct PageExchangeView: View {
    let exchange: PageConversation.Exchange
    let assistant: PageAssistant
    /// The tab whose page the question was about, whose window and Persona open the reply's links.
    let tab: Tab
    /// The page the question was about, for Allow AI on This Site.
    let pageURL: URL?
    /// The popover shows the selected text above its field instead.
    var showsSelection = true
    /// Clears the conversation and asks the question again on its own, for a question that went out with earlier ones and was too long for the model. The popover asks each question on its own and passes none.
    var startOver: (() -> Void)? = nil
    let retry: () -> Void
    @ObservedObject private var settings = AIService.shared.settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exchange.title)
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.enabled)
            if showsSelection, let selection = exchange.selection {
                SelectionQuote(text: selection)
            }
            if !exchange.reply.isEmpty {
                Text(PageReply.text(exchange.reply))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { assistant.openLink($0, from: tab) })
    }

    @ViewBuilder private var status: some View {
        switch exchange.state {
        case .readingPage:
            progress("Reading the page\u{2026}")
        case .sent:
            progress("Waiting for the model\u{2026}")
        case .waiting(.queued):
            progress("Waiting for a free request slot\u{2026}")
        case .waiting(.rateLimited(let until)):
            progress("Waiting for the provider\u{2019}s rate limit until \(until.formatted(date: .omitted, time: .standard))\u{2026}")
        case .answering:
            progress(exchange.model.map { "Answering with \(settings.title(of: $0))\u{2026}" } ?? "Answering\u{2026}")
        case .finished(let reason):
            note(PageReply.footer(for: exchange, finishedBecause: reason, settings: settings))
        case .stopped:
            // A reply stopped by closing the reader, as its first summary can be, is asked for again here.
            VStack(alignment: .leading, spacing: 6) {
                note("Stopped.")
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        case .failed(let error):
            failure(error)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            note(text)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One sentence and one action, as the AI interface shows every error. A page that could not be read offers Retry.
    private func failure(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error is AIError ? settings.message(for: error) : "Arch could not read this page.")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            if let action = action(for: error) {
                Button(action.title, action: action.perform)
                    .controlSize(.small)
            }
        }
    }

    /// A cancelled request never fails: the conversation shows it as stopped. Retry would only fail again where the conversation or Settings must change: a conversation too long for the model starts over, and a question too long on its own, or for a command-line tool that gets no page data, needs another model.
    private func action(for error: Error) -> (title: String, perform: () -> Void)? {
        switch error as? AIError {
        case .contextTooLong:
            if exchange.followsEarlierQuestions, let startOver { return ("Start Over", startOver) }
            return assistant.showAISettings.map { ("Open AI Settings", $0) }
        case .notConfigured, .authentication, .budgetReached, .blockedByPolicy(.commandLineToolWithPageData):
            return assistant.showAISettings.map { ("Open AI Settings", $0) }
        case .blockedByPolicy(.siteExcluded):
            guard let pageURL else { return nil }
            // The switch helps only while the page's own site is off; data from another address, such as a page that changed while it was read, is asked for again.
            guard !settings.allowsAI(on: pageURL) else { return ("Retry", retry) }
            return ("Allow AI on This Site", { [settings, retry] in
                settings.setAllowsAI(true, on: pageURL)
                retry()
            })
        default:
            return ("Retry", retry)
        }
    }
}

/// Selected text a question is about, as a short quote.
struct SelectionQuote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2) }
    }
}

/// Shown in place of a question field on a site where AI is off. Nothing about the page is read or sent until the user allows it.
struct PageAIOffNotice: View {
    let url: URL
    @ObservedObject private var settings = AIService.shared.settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Body text under the panel's semibold header, set apart from the note below by color alone.
            Text("AI is off for \(PageAssistant.siteName(of: url)).")
                .font(.system(size: 13))
            Text("Nothing from this site goes to any provider.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Allow AI on This Site") { settings.setAllowsAI(true, on: url) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The site settings popover's switch for AI on the current page's site. It shows while a feature that reads pages can run.
struct PageAISiteSection: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var service = AIService.shared
    @ObservedObject private var settings = AIService.shared.settings

    var body: some View {
        if let url = tab.url, PageAssistant.canRead(url), service.isAvailable(.pageReader) || service.isAvailable(.pageQuestion) {
            SiteSettingsSection(title: "AI", note: "Features such as the page reader can send this site\u{2019}s pages to the models you chose for them.") {
                HStack {
                    Text("Allow AI on this site")
                    Spacer()
                    Toggle("Allow AI on this site", isOn: Binding(get: { settings.allowsAI(on: url) }, set: { settings.setAllowsAI($0, on: url) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// How replies show. They render as text, never loading an image, and each link shows its full address, so a reply cannot hide where a link goes or send page data through an image's address.
enum PageReply {
    /// The reply with inline Markdown (emphasis, code, and links) and its line breaks kept. A link's address follows its text and is what opens it.
    static func text(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return AttributedString(markdown) }
        var reply = AttributedString()
        for (link, range) in parsed.runs[\.link] {
            var piece = AttributedString(parsed[range])
            if let link, String(piece.characters) != link.absoluteString {
                piece.link = nil
                var address = AttributedString(link.absoluteString)
                address.link = link
                piece += AttributedString(" (") + address + AttributedString(")")
            }
            reply += piece
        }
        reply.imageURL = nil
        return reply
    }

    /// The model that answered, its tokens, and the estimated cost when the model has a price. A provider that reports no usage, such as a command-line tool covered by the user's subscription, shows only the model.
    @MainActor static func footer(for exchange: PageConversation.Exchange, finishedBecause reason: AIFinishReason, settings: AISettingsStore) -> String {
        var parts = [exchange.model.map { "Answered by \(settings.title(of: $0))" } ?? "Answered"]
        if let usage = exchange.usage {
            parts.append("\((usage.inputTokens + usage.cachedInputTokens).formatted()) input and \(usage.outputTokens.formatted()) output tokens")
            if let model = exchange.model, let cost = settings.estimatedCost(of: usage, on: model) {
                // A single answer often costs a fraction of a cent.
                parts.append("about \(cost.amount.formatted(.currency(code: cost.currency).precision(.fractionLength(2...4))))")
            }
        }
        let footer = parts.joined(separator: " \u{00B7} ")
        return reason == .lengthLimit ? "\(footer). The reply reached the length limit." : footer
    }
}
