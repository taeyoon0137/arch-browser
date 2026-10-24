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
    /// The script as the engines run it, or nil when its source is not a function body on its own. Its function checks the document's address, then runs the script's body with the world's channel as `arch`. The body stands on lines of its own, so a final line comment in it cannot hide the brackets after it, and a body that parses on its own cannot close them, so it cannot run outside the check.
    @MainActor
    func engineScript(world: String, sites: [MatchPattern]) -> EnginePageScript? {
        guard FunctionBodyCheck.accepts(source) else { return nil }
        let guarded = """
        (channel) => {
          const covers = \(MatchPattern.javaScriptMatcher);
          if (!covers(location, \(MatchPattern.javaScriptLiteral(matches))) || !covers(location, \(MatchPattern.javaScriptLiteral(sites)))) return;
          ((arch) => {
        \(source)
          })(channel);
        }
        """
        return EnginePageScript(world: world, source: guarded, injectionTime: runAt, mainFrameOnly: !allFrames)
    }
}

/// Tells whether a page script's source is a function body on its own. The `Function` constructor parses its last argument as a function body alone and runs none of it, so JavaScriptCore checks the source without running plugin code in the app. A check of the source inside brackets would not do: a source can close the brackets and open new ones.
@MainActor
private enum FunctionBodyCheck {
    private static let check = JSContext()?.evaluateScript(#"(source) => { try { new Function("arch", source); return true; } catch { return false; } }"#)

    static func accepts(_ source: String) -> Bool {
        check?.call(withArguments: [source])?.toBool() ?? false
    }
}
