// A question that web extensions ask the user while they run, without any interface: more access an extension requests, more access an engine asks for in its own sentences, or a reload that lets extensions run on a page. The host shows it as it shows the tab's other prompts and answers whether the user agreed.
import ARCHEngine

public struct WebExtensionQuestion: Equatable {
    public enum Kind: Equatable {
        /// More access that the extension requested, as with `permissions.request`.
        case access
        /// More access that the engine describes in its own sentences.
        case enginePermissions
        /// A reload of the tab, so that the extensions it kept from running there run.
        case reload
    }

    public var kind: Kind
    /// The plugin's name, for a version of a pair the pair's. Empty for a reload, whose `message` names the extensions.
    public var extensionName: String
    /// The engine of the version of a pair that asks, whose copy alone the answer reaches.
    public var version: EngineKind?
    /// What the extension gets, one sentence each.
    public var items: [String]
    public var message: String?
    /// How long the extension keeps what the user allows.
    public var keeps: String?
    /// Whether Touch ID or the login password confirms Allow next, as for access to every website.
    public var confirmsNext: Bool

    public init(kind: Kind, extensionName: String, version: EngineKind? = nil, items: [String] = [], message: String? = nil, keeps: String? = nil, confirmsNext: Bool = false) {
        self.kind = kind
        self.extensionName = extensionName
        self.version = version
        self.items = items
        self.message = message
        self.keeps = keeps
        self.confirmsNext = confirmsNext
    }
}
