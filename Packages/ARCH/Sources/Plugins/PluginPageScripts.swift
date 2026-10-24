// Plugin page scripts as the engines run them: a plugin's scripts share a world apart from other plugins' scripts, and each starts only in documents that its patterns and its plugin's granted sites cover.
import ARCHEngine
import Foundation

extension PluginID {
    /// The world of the plugin's page scripts.
    var pageScriptWorld: String {
        "ARCHPlugin." + rawValue
    }
}

extension PluginPageScript {
    /// The script as the engines run it. Its function checks the document's address, then runs the script's body with the world's channel as `arch`. The body stands on lines of its own, so a final line comment in it cannot hide the brackets after it.
    func engineScript(world: String, sites: [MatchPattern]) -> EnginePageScript {
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
