// Reads a page's readable text with the script `ARCHEngine` shares with the Chromium adapter. It runs in its own content world, so the page's scripts cannot see or replace it.
import ARCHEngine
import WebKit

extension WebKitWebContents {
    private static let readableContentWorld = WKContentWorld.world(name: "ARCHReadableContent")

    public func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void) {
        webView.callAsyncJavaScript("return (\(EngineReadableContent.script))(limit);", arguments: ["limit": limit], in: nil, in: Self.readableContentWorld) { result in
            completion(Result { try EngineReadableContent(scriptResult: (try? result.get()) as? String) })
        }
    }
}
