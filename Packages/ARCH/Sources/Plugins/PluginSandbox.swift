// The sandbox of a script plugin's web views. Their documents load only from the plugin's package through the `arch-plugin` scheme, under a content security policy that allows neither inline nor evaluated code and limits connections to the package. A rule list blocks every other load, Lockdown Mode takes away WebRTC, whose connections neither covers, a data store of their own keeps nothing, and the bridge is their only way to the app. Each web view runs in a WebKit web content process apart from the app and the tabs.
import UniformTypeIdentifiers
import WebKit

@MainActor
enum PluginSandbox {
    static let scheme = "arch-plugin"
    /// The package's own scripts, styles, images, and connections, and neither inline code nor `eval`. Every response carries it.
    static let contentSecurityPolicy = "default-src 'self'"

    /// The root of the plugin's origin, where the background document loads.
    static func backgroundURL(of id: PluginID) -> URL {
        // Plugin identifiers are host names.
        URL(string: "\(scheme)://\(id.rawValue)/")!
    }

    /// A configuration for a web view of the package, whose bridge calls go to `bridge`.
    static func configuration(for package: PluginPackage, bridge: ScriptPluginBridge) async throws -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Neither the policy nor the rule list covers WebRTC connections. Lockdown Mode takes WebRTC away from every frame of the web view.
        configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
        configuration.setURLSchemeHandler(PluginSchemeHandler(package: package), forURLScheme: scheme)
        let controller = configuration.userContentController
        controller.add(try await blockingRules())
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: ScriptPluginBridge.handlerName)
        controller.addUserScript(WKUserScript(source: bridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        return configuration
    }

    private static var compiledRules: WKContentRuleList?

    /// Blocks every load outside the scheme, compiled at first use.
    private static func blockingRules() async throws -> WKContentRuleList {
        if let compiledRules { return compiledRules }
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^arch-plugin:"},"action":{"type":"ignore-previous-rules"}}]"#
        // WebKit answers with the list or an error.
        let compiled = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ARCHPluginSandbox", encodedContentRuleList: rules)!
        compiledRules = compiled
        return compiled
    }
}

/// Serves one plugin's package at `arch-plugin://<plugin id>/<package path>`, from its folder or, for a package held in memory, from memory, and at the root the document that runs the background script. Every response carries the sandbox's content security policy; other hosts, and paths that name no file of the package, get 404.
@MainActor
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    private let package: PluginPackage

    init(package: PluginPackage) {
        self.package = package
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let (status, contentType, body) = response(for: url)
        // The status and fields are valid, so the response exists.
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": contentType, "Content-Security-Policy": PluginSandbox.contentSecurityPolicy])!)
        task.didReceive(body)
        task.didFinish()
    }

    /// Each task finishes as it starts, so there is none to stop.
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    func response(for url: URL) -> (status: Int, contentType: String, body: Data) {
        let notFound = (404, "text/plain; charset=utf-8", Data())
        guard url.scheme == PluginSandbox.scheme, url.host() == package.manifest.id.rawValue else { return notFound }
        let path = String(url.path(percentEncoded: false).drop { $0 == "/" })
        if path.isEmpty {
            return backgroundDocument.map { (200, "text/html; charset=utf-8", $0) } ?? notFound
        }
        let body: Data
        if let memoryFiles = package.memoryFiles {
            guard let held = memoryFiles[path] else { return notFound }
            body = held
        } else {
            guard let file = PluginPackage.file(path, in: package.rootURL), let read = try? Data(contentsOf: file) else { return notFound }
            body = read
        }
        let type = UTType(filenameExtension: (path as NSString).pathExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        return (200, type?.conforms(to: .text) == true ? mimeType + "; charset=utf-8" : mimeType, body)
    }

    /// A document that runs the background script as a classic script, or nil for a plugin without one.
    private var backgroundDocument: Data? {
        guard let background = package.background, let source = background.addingPercentEncoding(withAllowedCharacters: Self.attributePathCharacters) else { return nil }
        return Data(#"<!doctype html><meta charset="utf-8"><script src="/\#(source)"></script>"#.utf8)
    }

    /// The characters of a path that stand in an attribute value as they are.
    private static let attributePathCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "\"'&<>"))
}
