// Plugin page scripts as the engines run them: a plugin's scripts share a world apart from other plugins' scripts, and each starts only in documents that its patterns and its plugin's granted sites cover, where it adds its styles before it runs.
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
    /// The script as the engines run it, or nil when its source is not a function body on its own. Its function checks the document's address as `covers(_:)` and the granted sites do, and, with `within`, as one of those patterns does too, as the host of a tab's `whenInvoked` access does, then adds the script's styles to the document and runs the script's body with the world's channel as `arch`. With `once`, it runs only the first time it runs in a frame's world under that key, so a script that a command runs at once in a document that already ran it from the tab's list runs no second time and adds its styles no second time. The body stands on lines of its own, so a final line comment in it cannot hide the brackets after it, and a body that parses on its own cannot close them, so it cannot run outside the check.
    @MainActor
    func engineScript(world: String, sites: [MatchPattern], within: [MatchPattern]? = nil, once key: String? = nil) -> EnginePageScript? {
        guard FunctionBodyCheck.shared.accepts(source) else { return nil }
        let guarded = """
        (channel) => {
          const covers = \(MatchPattern.javaScriptMatcher);
          if (!covers(location, \(MatchPattern.javaScriptLiteral(matches))) || covers(location, \(MatchPattern.javaScriptLiteral(excludes)))
            || !covers(location, \(MatchPattern.javaScriptLiteral(sites)))\(PluginPageRun.withinCheck(within))) return;\(Self.onceCheck(key))\(Self.styleLines(styles, atStart: runAt == .documentStart))
          ((arch) => {
        \(source)
          })(channel);
        }
        """
        return EnginePageScript(world: world, source: guarded, injectionTime: runAt, mainFrameOnly: !allFrames)
    }

    /// The lines that end the function when the frame's world already ran a script under `key` and otherwise mark it, or none without a key.
    private static func onceCheck(_ key: String?) -> String {
        guard let key else { return "" }
        let literal = String(decoding: (try? JSONEncoder().encode(key)) ?? Data("\"\"".utf8), as: UTF8.self)
        return "\n  if (globalThis[\(literal)]) return;\n  globalThis[\(literal)] = true;"
    }

    /// The lines that add `styles` to the document in `<style>` elements, in their order, or none without styles. With `atStart`, as for a document-start script, they go at the start of the document's root element, before the page's own styles, which win where both give a property with the same specificity, also in a document that has those already, as when a command runs the script at once; otherwise at the root's end, after the styles the page has by then. A document without a root element yet, as Chromium's helper may run a document-start script before the parser adds one, gets them once the root appears, after the script's body has run, and at the root's start all the same, however much of the page the parser has added by then. The text goes in as JSON strings through `textContent`, so it never runs as script.
    private static func styleLines(_ styles: [String], atStart: Bool) -> String {
        guard !styles.isEmpty else { return "" }
        let literal = String(decoding: (try? JSONEncoder().encode(styles)) ?? Data("[]".utf8), as: UTF8.self)
        return """

          ((styles) => {
            const add = (root) => {
              const sheets = document.createDocumentFragment();
              for (let index = 0; index < styles.length; index++) {
                const style = document.createElementNS("http://www.w3.org/1999/xhtml", "style");
                style.textContent = styles[index];
                sheets.appendChild(style);
              }
              root.insertBefore(sheets, \(atStart ? "root.firstChild" : "null"));
            };
            if (document.documentElement) return add(document.documentElement);
            const observer = new MutationObserver(() => {
              if (!document.documentElement) return;
              observer.disconnect();
              add(document.documentElement);
            });
            observer.observe(document, { childList: true });
          })(\(literal));
        """
    }
}

/// A script that a plugin runs once in a tab's page (`PluginContext.runPageScript(_:in:)`), as `executeJavaScriptWithoutUserGesture(_:inWorld:completion:)` calls it, and what it returns.
enum PluginPageRun {
    /// Where the script's text comes from: given, as a built-in plugin's, or a file of a script plugin's package, by package path.
    enum Source: Sendable {
        case text(String)
        case file(String, of: PluginPackage)
    }

    /// What the run came to.
    enum Outcome {
        /// What the script's body returned, null for `undefined`, a function, or a symbol.
        case value(PluginValue)
        /// What the script threw, as text.
        case failed(String)
        /// The granted sites do not cover the document, so the script did not run.
        case outside
    }

    /// The function that the engine calls with the world's channel, made off the main actor, which neither reading a large package file nor parsing it then holds up, and which runs only where `sites` and, if given, `within` cover the document. Throws `PluginError.invalidPageScript` for a path that names no text file of the package and for a source that is not a function body on its own.
    static func function(running source: Source, sites: [MatchPattern], within: [MatchPattern]? = nil) async throws -> String {
        try await Task.detached {
            let text: String
            switch source {
            case let .text(given):
                text = given
            case let .file(path, package):
                guard let read = package.text(of: path) else { throw PluginError.invalidPageScript("\u{201C}\(path)\u{201D} is not a text file of the plugin\u{2019}s package.") }
                text = read
            }
            guard FunctionBodyCheck().accepts(text) else { throw PluginError.invalidPageScript("The script does not parse as the body of a function, as a page script must.") }
            return function(running: text, sites: sites, within: within)
        }.value
    }

    /// The condition that no pattern of `within` covers the document's address, which a guard joins to its check of the sites so that it runs nothing then, or nothing without `within`.
    static func withinCheck(_ within: [MatchPattern]?) -> String {
        within.map { " || !covers(location, \(MatchPattern.javaScriptLiteral($0)))" } ?? ""
    }

    /// The function for a source that is a function body on its own. Like a page script's guard, it checks the document's `location` against the granted sites, and `within` when given, first and runs nothing outside them. It returns JSON text: `{"value": …}`, `{"error": text}` with what the body threw, as the bridge describes a listener's, or `{"outside": true}`. The body stands on lines of its own, so a final line comment in it cannot hide the brackets after it.
    private static func function(running source: String, sites: [MatchPattern], within: [MatchPattern]?) -> String {
        """
        (channel) => {
          const covers = \(MatchPattern.javaScriptMatcher);
          if (!covers(location, \(MatchPattern.javaScriptLiteral(sites)))\(withinCheck(within))) return '{"outside":true}';
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
