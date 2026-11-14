// Plugins that AI writes. The composer asks the AI interface for a script plugin that does what the user describes, checks the reply against the rules for plugins that AI writes, sends the problems it finds back to the model, and stages the plugin for the review sheet, as a package the user chose would be. Nothing of it runs until the user installs and enables it.
import AI
import Foundation
import JavaScriptCore

extension AIFeature {
    /// The composer's feature, which Settings registers.
    public static let pluginComposer = AIFeature(id: .pluginComposer, name: "Plugin Writer",
                                                 summary: "Writes a plugin for the feature you describe in Settings \u{25B8} Plugins, which you review before it runs. It sends your description and Arch's plugin reference, never page data.",
                                                 trigger: .user, data: .textOnly, requirements: [.jsonOutput])
}

/// Writes one plugin, then each change the user asks for in its review, under one identifier. Each version is a staged package, which the caller installs or discards.
@MainActor
public final class PluginComposer {
    /// The replies one request may take, so that the model can correct the problems Arch finds twice before the user sees them.
    private static let attemptLimit = 3
    /// The UTF-8 bytes that a plugin's files, `plugin.json` among them, may hold together. A command-line tool gets no output limit, so its reply can be larger.
    private static let sizeLimit = 256 * 1024
    /// Room for a whole plugin in one reply, which the instructions give the model as the reply's limit.
    static let replyTokens = 8_192

    private let plugins: PluginManager
    private let service: AIService
    /// The start of the identifiers that the composer gives plugins, which a UUID follows.
    nonisolated static let identifierPrefix = "xyz.taeyoon.arch.generated."
    /// The identifier of every version. Arch gives it rather than the model, so that a version written here can replace no other plugin. A UUID's text is always a valid label.
    private let pluginID = PluginID(rawValue: PluginComposer.identifierPrefix + UUID().uuidString)!
    /// What the user asked for so far: the request, then each change.
    private var requests: [String] = []
    /// The last version's reply, from which a change starts.
    private var currentReply: String?

    /// Stages each version in the Persona of `plugins` and writes it through `service`.
    public init(plugins: PluginManager, service: AIService) {
        self.plugins = plugins
        self.service = service
    }

    /// Asks the model for the plugin that `request` describes, or, once a version exists, for the change it describes to that version, and stages the new version in the composer's Persona for the review without running any of it. A reply that breaks a rule goes back to the model with the problem, at most twice, unless it is larger than a plugin may be; one cut at the output limit ends the request. Throws the AI interface's errors, `PluginComposerError.unusableReply` when no reply could be used, and file errors from staging.
    public func write(_ request: String) async throws -> PluginPackage {
        var messages = [AIMessage(role: .user, parts: [.text(requests.first ?? request)])]
        if let currentReply {
            messages += [AIMessage(role: .assistant, parts: [.text(currentReply)]), AIMessage(role: .user, parts: [.text(request)])]
        }
        var problem = ""
        for _ in 0..<Self.attemptLimit {
            let reply: AIReply
            do {
                reply = try await service.reply(AIRequest(feature: .pluginComposer, instructions: Self.instructions, messages: messages,
                                                          output: .json(schema: Self.replySchema), maxOutputTokens: Self.replyTokens))
            } catch AIError.malformedReply(let message) {
                // Without the reply to send back, the same request goes again.
                problem = message
                continue
            } catch AIError.replyTooLong {
                // The same request would be cut at the same limit.
                throw PluginComposerError.unusableReply("The plugin is too long for one reply.")
            }
            let composition = PluginComposition(requests: requests + [request], model: service.settings.title(of: reply.model))
            do {
                let package = try await plugins.stage(try files(of: reply.text), writtenBy: composition)
                guard !Task.isCancelled else {
                    plugins.discard(package)
                    throw AIError.cancelled
                }
                requests = composition.requests
                currentReply = reply.text
                return package
            } catch let error as PluginError {
                problem = error.localizedDescription
                // A reply larger than a plugin may be would cost more to send back than the model can fix.
                guard reply.text.utf8.count <= Self.sizeLimit else { break }
                messages += [AIMessage(role: .assistant, parts: [.text(reply.text)]),
                             AIMessage(role: .user, parts: [.text("Arch cannot use this plugin: \(problem) Reply with the whole plugin again, corrected.")])]
            }
        }
        throw PluginComposerError.unusableReply(problem)
    }

    /// The package's files that a reply describes, with `plugin.json` written from its manifest and the identifier and plugin API version that Arch gives. Throws `PluginError.invalidPackage` for a reply that breaks a rule for plugins that AI writes; staging checks the rest, as it does for every package.
    private func files(of reply: String) throws -> [String: String] {
        guard case let .object(fields)? = try? JSONDecoder().decode(PluginValue.self, from: Data(reply.utf8)),
              case var .object(manifest)? = fields["manifest"], case let .object(written)? = fields["files"] else {
            throw PluginError.invalidPackage("The reply must be a JSON object with a manifest object and a files object.")
        }
        var contributions: [String: PluginValue] = [:]
        if case let .object(fields)? = manifest["contributes"] { contributions = fields }
        // Plugins that AI writes do not reach pages. A key with `null` or an empty list asks for nothing, as staging reads it.
        let absent: [PluginValue?] = [nil, .null, .array([])]
        for (key, value) in [("sites", manifest["sites"]), ("contributes.pageScripts", contributions["pageScripts"])] where !absent.contains(value) {
            throw PluginError.invalidPackage("plugin.json: \(key) is not offered to plugins that AI writes.")
        }
        manifest["id"] = .string(pluginID.rawValue)
        manifest["apiVersion"] = .number(Double(PluginManifest.apiVersion))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var files = ["plugin.json": String(decoding: try encoder.encode(PluginValue.object(manifest)), as: UTF8.self)]
        let context = JSContext()
        for (name, value) in written.sorted(by: { $0.key < $1.key }) {
            guard Self.isScriptName(name) else { throw PluginError.invalidPackage("files names “\(name)”, which is not a plain file name that ends in .js.") }
            // The background document loads the background script and no other file.
            guard manifest["background"] == .string(name) else {
                throw PluginError.invalidPackage("files names “\(name)”, which is not the manifest's background script. Only the background script runs, so put all the code in it.")
            }
            guard case let .string(source) = value else { throw PluginError.invalidPackage("files.\(name) must be text.") }
            if let error = Self.syntaxError(in: source, context: context) {
                throw PluginError.invalidPackage("\(name) does not parse as a script: \(error).")
            }
            files[name] = source
        }
        guard files.values.reduce(0, { $0 + $1.utf8.count }) <= Self.sizeLimit else {
            throw PluginError.invalidPackage("The plugin's files come to more than \(Self.sizeLimit / 1024) KB.")
        }
        return files
    }

    /// Whether `name` is a plain file name that ends in `.js`: letters, digits, `-`, `_`, and `.`, starting with no dot.
    private static func isScriptName(_ name: String) -> Bool {
        name.hasSuffix(".js") && !name.hasPrefix(".") && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The syntax error of `source` as a classic script, as the background document runs it (`ScriptPlugin.syntaxError(in:)`).
    private static func syntaxError(in source: String, context: JSContext?) -> String? {
        ScriptPlugin.syntaxError(in: source, context: context)
    }
}

public enum PluginComposerError: Error, Hashable, Sendable {
    /// Every reply to a request broke a rule for plugins that AI writes; the text states the last reply's problem as a sentence.
    case unusableReply(String)
}

extension PluginComposerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unusableReply(problem): return "AI wrote a plugin that Arch cannot use. \(problem)"
        }
    }
}
