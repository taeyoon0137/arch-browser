import AppKit
import Foundation

/// Tier 2: browser extensions. Provided by the Chromium engine only.
public struct EngineExtensionInfo: Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var isEnabled: Bool
    public var hasAction: Bool
    public init(id: String, name: String, version: String, description: String, isEnabled: Bool, hasAction: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.isEnabled = isEnabled
        self.hasAction = hasAction
    }
}

public protocol EngineExtensionsDelegate: AnyObject {
    func extensionsDidChange(_ extensions: any EngineExtensions)
}

public protocol EngineExtensions: AnyObject {
    var delegate: (any EngineExtensionsDelegate)? { get set }
    var isReady: Bool { get }
    func list() -> [EngineExtensionInfo]
    func setEnabled(_ enabled: Bool, id: String)
    func uninstall(id: String)
    func installFromWebstore(id: String, completion: @escaping (Result<EngineExtensionInfo, Error>) -> Void)
    func installUnpacked(at path: URL, completion: @escaping (Result<EngineExtensionInfo, Error>) -> Void)
    func pinnedOrder() -> [String]
    func setPinnedOrder(_ ids: [String])
    func executeAction(id: String, in webContents: any EngineWebContents)
}
