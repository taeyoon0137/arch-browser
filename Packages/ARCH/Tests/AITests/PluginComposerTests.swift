// The plugin composer: AI writes a script plugin through the AI interface from the user's request, and Arch checks the reply against the rules for plugins that AI writes and stages it for the review without installing or running it. Problems go back to the model, three unusable replies end the request, and a change keeps the plugin's identifier.
import Foundation
import Plugins
import Testing
@testable import AI

@MainActor
@Suite struct PluginComposerTests {
    private let request = "Copy the tab's title and address as a Markdown link"
    private let folder = temporaryDirectory()
    private let persona = UUID()
    private let log = ProviderLog()

    /// A composer whose model gives `replies` in order, one per request, each finishing for `reason`, and finishes without text after the last, with the manager it stages in.
    private func composer(replying replies: [String], finishing reason: AIFinishReason = .completed,
                          model: AIModelConfiguration = AIModelConfiguration(name: "model-a")) -> (PluginComposer, PluginManager) {
        let queue = ReplyQueue(replies, finishing: reason)
        let service = stubService(providers: [provider("First", models: [model])]) { [log] configuration in
            ScriptedProvider(configuration: configuration, script: [model.name: queue.next()], log: log)
        }
        service.register(.pluginComposer)
        let plugins = PluginManager(persona: persona, directory: folder, builtIns: [])
        return (PluginComposer(plugins: plugins, service: service), plugins)
    }

    @Test func stagesThePluginWithoutInstallingIt() async throws {
        let (composer, plugins) = composer(replying: [reply()])
        let package = try await composer.write(request)
        #expect(package.origin == .generated(PluginComposition(requests: [request], model: "First \u{2014} model-a")))
        #expect(package.manifest.id.rawValue.hasPrefix("xyz.taeyoon.arch.generated.") && package.manifest.name == "Markdown Link")
        #expect(package.manifest.permissions == [.tabs, .clipboard] && package.manifest.contributions.commands.map(\.id) == ["copy"])
        #expect(package.files == ["background.js", "plugin.json"] && package.text(of: "background.js")?.contains("arch.ui.copy") == true)
        // Nothing is installed, so nothing can run.
        #expect(plugins.plugins.isEmpty && stagedPackages().count == 1)
        let sent = try #require(log.requests.first)
        #expect(log.requests.count == 1 && sent.instructions?.contains("You write plugins for Arch") == true)
        #expect(sent.messages.map(\.role) == [.user] && texts(of: sent.messages) == [request])
        guard case .json = sent.output else {
            Issue.record("Expected a JSON reply")
            return
        }
    }

    @Test func sendsTheProblemBackAndStagesTheCorrection() async throws {
        let broken = reply(files: ["background.js": "arch.commands.onRun(\"copy\", async () => {"])
        let (composer, _) = composer(replying: [broken, reply()])
        let package = try await composer.write(request)
        #expect(package.manifest.name == "Markdown Link" && stagedPackages().count == 1)
        let retry = try #require(log.requests.last)
        #expect(log.requests.count == 2 && retry.messages.map(\.role) == [.user, .assistant, .user])
        let sent = texts(of: retry.messages)
        #expect(sent.prefix(2) == [request, broken])
        #expect(sent.last?.hasPrefix("Arch cannot use this plugin: background.js does not parse as a script: SyntaxError:") == true)
        #expect(sent.last?.hasSuffix("Reply with the whole plugin again, corrected.") == true)
    }

    @Test func endsAfterThreeUnusableReplies() async throws {
        let cases: [(String, String)] = [
            ("[]", "The reply must be a JSON object with a manifest object and a files object."),
            ("{", "The reply is not valid JSON."),
            (reply(["sites": ["https://example.org/*"]]), "plugin.json: sites is not offered to plugins that AI writes."),
            (reply(["contributes": ["pageScripts": [["matches": ["<all_urls>"], "js": ["page.js"]]]]]),
             "plugin.json: contributes.pageScripts is not offered to plugins that AI writes."),
            (reply(["permissions": ["tabs", "ai"]]), "plugin.json: permissions lists “ai”, which is not offered to plugins that AI writes."),
            (reply(["permissions": [["ai": ["page"]]]]), "plugin.json: permissions lists “ai”, which is not offered to plugins that AI writes."),
            (reply(files: ["lib/background.js": ""]), "files names “lib/background.js”, which is not a plain file name that ends in .js."),
            (reply(files: ["notes.txt": ""]), "files names “notes.txt”, which is not a plain file name that ends in .js."),
            (reply(files: ["background.js": "", "format.js": ""]),
             "files names “format.js”, which is not the manifest\u{2019}s background script. Only the background script runs, so put all the code in it."),
            (reply(files: ["background.js": 1]), "files.background.js must be text."),
            // Staging checks what it checks for every package.
            (reply(["permissions": ["notifications"]]), "plugin.json: permissions lists “notifications”, which Arch does not grant."),
            (reply(["background": NSNull()], files: [:]), "plugin.json: commands need a background script."),
        ]
        for (unusable, problem) in cases {
            let (composer, _) = composer(replying: Array(repeating: unusable, count: 3))
            let requestCount = log.requests.count
            await #expect(throws: PluginComposerError.unusableReply(problem), "\(problem)") { try await composer.write(request) }
            #expect(log.requests.count == requestCount + 3, "\(problem)")
        }
        #expect(stagedPackages().isEmpty)
    }

    @Test func endsAtOnceWithAReplyLargerThanAPlugin() async throws {
        let (composer, _) = composer(replying: [reply(files: ["background.js": "//" + String(repeating: "a", count: 256 * 1024)])])
        await #expect(throws: PluginComposerError.unusableReply("The plugin\u{2019}s files come to more than 256 KB.")) { try await composer.write(request) }
        #expect(log.requests.count == 1 && stagedPackages().isEmpty)
    }

    @Test func endsAtOnceWithAReplyCutAtTheLengthLimit() async throws {
        let (composer, _) = composer(replying: [String(reply().prefix(100))], finishing: .lengthLimit)
        await #expect(throws: PluginComposerError.unusableReply("The plugin is too long for one reply.")) { try await composer.write(request) }
        #expect(log.requests.count == 1 && stagedPackages().isEmpty)
    }

    @Test func writesChangesToTheSamePlugin() async throws {
        let change = "Give it the shortcut ctrl+opt+m"
        let first = reply()
        let changed = reply(["contributes": ["commands": [["id": "copy", "title": "Copy Markdown Link", "shortcut": "ctrl+opt+m"]]]])
        let (composer, _) = composer(replying: [first, changed])
        let original = try await composer.write(request)
        let package = try await composer.write(change)
        #expect(package.manifest.id == original.manifest.id)
        #expect(package.origin == .generated(PluginComposition(requests: [request, change], model: "First \u{2014} model-a")))
        #expect(package.manifest.contributions.commands.first?.shortcut?.description == "ctrl+opt+m")
        let sent = try #require(log.requests.last)
        #expect(sent.messages.map(\.role) == [.user, .assistant, .user] && texts(of: sent.messages) == [request, first, change])
        // The earlier version stays staged until the review discards it.
        #expect(stagedPackages().count == 2)
    }

    @Test func needsAModelThatRepliesInJSON() async throws {
        let (composer, _) = composer(replying: [reply()], model: AIModelConfiguration(name: "model-a", capabilities: []))
        do {
            _ = try await composer.write(request)
            Issue.record("Expected noUsableModel")
        } catch AIError.notConfigured(.noUsableModel) {
            #expect(log.requests.isEmpty && stagedPackages().isEmpty)
        }
    }

    /// The packages waiting for review in the Persona's staging folder.
    private func stagedPackages() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Plugins/\(persona.uuidString)/Staging").path)) ?? []
    }
}

/// A reply with a plugin that copies the tab as a Markdown link: its manifest with the keys of `changes` in place of its own, and `files` in place of its background script.
private func reply(_ changes: [String: Any] = [:], files: [String: Any]? = nil) -> String {
    var manifest: [String: Any] = [
        "name": "Markdown Link", "version": "1.0", "summary": "Copies the tab as a Markdown link.", "permissions": ["tabs", "clipboard"], "background": "background.js",
        "contributes": ["commands": [["id": "copy", "title": "Copy Markdown Link"]], "menus": [["command": "copy", "location": "tabContextMenu"]]],
    ]
    manifest.merge(changes) { $1 }
    let script = #"arch.commands.onRun("copy", async ({ tab }) => { await arch.ui.copy(`[${tab.title}](${tab.url})`); });"#
    let reply: [String: Any] = ["manifest": manifest, "files": files ?? ["background.js": script]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: reply, options: .sortedKeys), as: UTF8.self)
}

/// Each message's text: the composer sends text only.
private func texts(of messages: [AIMessage]) -> [String] {
    messages.map { message in
        message.parts.map { part in
            guard case .text(let text) = part else { return "<not text>" }
            return text
        }.joined()
    }
}

/// The replies a test's model gives, one per request.
@MainActor
private final class ReplyQueue {
    private var replies: [String]
    /// How each reply finishes.
    private let reason: AIFinishReason

    init(_ replies: [String], finishing reason: AIFinishReason) {
        self.replies = replies
        self.reason = reason
    }

    /// The next reply as a scripted provider's steps.
    func next() -> [Step] {
        guard !replies.isEmpty else { return [.event(.finished(.completed))] }
        return [.event(.text(replies.removeFirst())), .event(.finished(reason))]
    }
}
