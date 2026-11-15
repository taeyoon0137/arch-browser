// Plugin page scripts as the engines run them: a plugin's scripts share a world apart from other plugins' scripts, and each starts only in documents that its patterns and its plugin's granted sites cover.
import ARCHEngine
import Foundation
import JavaScriptCore

extension PluginID {
    /// The world of the plugin's page scripts.
    var pageScriptWorld: String {
        "ARCHPlugin." + rawValue
    }
}

extension PluginPageScript {
    /// The script as the engines run it, or nil when its source is not a function body on its own. Its function checks the document's address as `covers(_:)` and the granted sites do, then runs the script's body with the world's channel as `arch`. The body stands on lines of its own, so a final line comment in it cannot hide the brackets after it, and a body that parses on its own cannot close them, so it cannot run outside the check.
    @MainActor
    func engineScript(world: String, sites: [MatchPattern]) -> EnginePageScript? {
        guard FunctionBodyCheck.shared.accepts(source) else { return nil }
        let guarded = """
        (channel) => {
          const covers = \(MatchPattern.javaScriptMatcher);
          if (!covers(location, \(MatchPattern.javaScriptLiteral(matches))) || covers(location, \(MatchPattern.javaScriptLiteral(excludes)))
            || !covers(location, \(MatchPattern.javaScriptLiteral(sites)))) return;
          ((arch) => {
        \(source)
          })(channel);
        }
        """
        return EnginePageScript(world: world, source: guarded, injectionTime: runAt, mainFrameOnly: !allFrames)
    }
}

/// A script that a plugin runs once in a tab's page (`PluginContext.runPageScript(_:in:)`), as `executeJavaScript(_:inWorld:completion:)` calls it, and what it returns.
enum PluginPageRun {
    /// What the run came to.
    enum Outcome {
        /// What the script's body returned, null for `undefined`, a function, or a symbol.
        case value(PluginValue)
        /// What the script threw, as text.
        case failed(String)
        /// The granted sites do not cover the document, so the script did not run.
        case outside
    }

    /// The function that the engine calls with the world's channel, or nil when `source` is not a function body on its own. Like a page script's guard, it checks the document's `location` against the granted sites first and runs nothing outside them. It returns JSON text: `{"value": …}`, `{"error": text}` with what the body threw, as the bridge describes a listener's, or `{"outside": true}`. The body stands on lines of its own, so a final line comment in it cannot hide the brackets after it.
    @MainActor
    static func function(running source: String, sites: [MatchPattern]) -> String? {
        guard FunctionBodyCheck.shared.accepts(source) else { return nil }
        return """
        (channel) => {
          const covers = \(MatchPattern.javaScriptMatcher);
          if (!covers(location, \(MatchPattern.javaScriptLiteral(sites)))) return '{"outside":true}';
          const failed = (text) => JSON.stringify({ error: text });
          let value;
          try {
            value = ((arch) => {
        \(source)
            })(channel);
          } catch (thrown) {
            try {
              if (thrown instanceof Error) return failed(thrown.name === "Error" ? thrown.message : `${thrown.name}: ${thrown.message}`);
              return failed(String(thrown));
            } catch {
              return failed("The script threw a value that has no text.");
            }
          }
          let json;
          try {
            json = JSON.stringify(value === undefined ? null : value);
          } catch {
            return failed("The script returned a value that JSON cannot hold.");
          }
          return '{"value":' + (json === undefined ? "null" : json) + '}';
        }
        """
    }

    /// The run's outcome from the function's reply. Throws `PluginError.pageScriptFailed` for a reply it cannot read, as when a page that shares the script's world on Chromium replaced `JSON.stringify`.
    static func outcome(of reply: String?) throws -> Outcome {
        guard let reply, case let .object(fields)? = try? JSONDecoder().decode(PluginValue.self, from: Data(reply.utf8)) else {
            throw PluginError.pageScriptFailed("Arch could not read what the script returned.")
        }
        if fields["outside"] == .bool(true) { return .outside }
        if case let .string(text)? = fields["error"] { return .failed(text) }
        guard let value = fields["value"] else { throw PluginError.pageScriptFailed("Arch could not read what the script returned.") }
        return .value(value)
    }
}

/// Tells whether a page script's source is a function body on its own. The `Function` constructor parses its last argument as a function body alone and runs none of it, so JavaScriptCore checks the source without running plugin code in the app. A check of the source inside brackets would not do: a source can close the brackets and open new ones. Each check has a JavaScriptCore context of its own, which one thread uses at a time.
final class FunctionBodyCheck {
    /// The check of the contribution index.
    @MainActor static let shared = FunctionBodyCheck()

    private let check = JSContext()?.evaluateScript(#"(source) => { try { new Function("arch", source); return true; } catch { return false; } }"#)

    func accepts(_ source: String) -> Bool {
        check?.call(withArguments: [source])?.toBool() ?? false
    }
}
