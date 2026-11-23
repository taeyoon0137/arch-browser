// The built-in hooks: Tab Names names a tab from its page, and Download Names renames a finished download's file from what is known about it. Each is an automatic feature, so it stays off until the user turns it on and gives it a model of its own in Settings ▸ AI, and its requests count toward the daily limit for automatic requests and the monthly spending limit.
import AI
import Foundation

extension AIFeature {
    static let tabNameHook = AIFeature(id: .tabNameHook, name: localized("Tab Names"),
                                       summary: localized("Names a tab in a few words from its page\u{2019}s title, address, and first \(BuiltInHooks.tabNamePageText.formatted()) characters, unless you named the tab."),
                                       trigger: .automatic, data: AIDataScope(kinds: [.page], pageTextLimit: BuiltInHooks.tabNamePageText))
    static let downloadNameHook = AIFeature(id: .downloadNameHook, name: localized("Download Names"),
                                            summary: localized("Gives a finished download a descriptive file name from its name, type, size, and the addresses of the file and its page, never its contents. Restore Original Name in its row undoes it."),
                                            trigger: .automatic, data: AIDataScope(kinds: [.download]))
}

/// Makes the hook registrations of the built-in Tab Names and Download Names features, as the file header describes.
enum BuiltInHooks {
    /// The characters of page text the tab name hook reads and sends.
    static let tabNamePageText = 2_000
    /// Room for a short name, and for models that think before they reply.
    private static let replyTokens = 256

    /// Asks for a name 1.5 seconds after a page loads, once titles that scripts set have settled, while `needsName` says the tab needs one.
    static func tabName(needsName: @escaping @Sendable (AIPageLoad) async -> Bool) -> AIHookRegistration {
        AIHookRegistration(feature: .tabNameHook, events: [.pageLoaded], delay: .milliseconds(1_500), allowedActions: [.renameTab]) { event, context in
            guard case .pageLoaded(let load) = event, await needsName(load) else { return .none }
            // A page without a document a script can read, such as an engine's error page, gets no name, and a tab that moved on during the wait gets its name from the newer page's event.
            guard let page = try? await context.pages.content(ofTab: load.tabID, limit: tabNamePageText),
                  page.url.withoutFragment == load.url.withoutFragment, await needsName(load), !Task.isCancelled else { return .none }
            let reply = try await context.client.reply(AIRequest(feature: .tabNameHook, instructions: tabNameInstructions,
                                                                  messages: [AIMessage(role: .user, parts: [.page(page)])], maxOutputTokens: replyTokens))
            let name = plainReply(reply.text)
            return name.isEmpty ? .none : .actions([.renameTab(load.tabID, title: name)], stop: false)
        }
    }

    /// Asks for a file name once a download finishes, unless the user chose the name in a save panel. The host keeps the file's extension and picks an unused name.
    static let downloadName = AIHookRegistration(feature: .downloadNameHook, events: [.downloadFinished], allowedActions: [.renameDownload]) { event, context in
        guard case .downloadFinished(let download) = event, !download.isNamedByUser else { return .none }
        let reply = try await context.client.reply(AIRequest(feature: .downloadNameHook, instructions: downloadNameInstructions,
                                                              messages: [AIMessage(role: .user, parts: [.download(download.info)])], maxOutputTokens: replyTokens))
        let name = plainReply(reply.text)
        return name.isEmpty ? .none : .actions([.renameDownload(download.downloadID, filename: name)], stop: false)
    }

    private static let tabNameInstructions = """
        Name the browser tab that shows the web page in the page block, so that the user can tell it from other tabs. \
        Reply with the name alone: at most four words, in the page's language, without quotes or a final period.
        """

    private static let downloadNameInstructions = """
        Suggest a descriptive file name for the downloaded file in the download block, from its current name, type, size, and address. \
        Reply with the name alone, in the language of its current name, without a folder, an extension, quotes, or a final period.
        """

    /// The first line of a reply, without the quotes, emphasis, or final period a model may add around it.
    static func plainReply(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'`*.\u{201C}\u{201D}\u{2018}\u{2019}\u{300C}\u{300D}")))
    }
}
