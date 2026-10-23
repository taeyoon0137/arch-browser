import Foundation

/// Session restore model. WebKit implements it with interactionState.
public struct EngineSessionTab: Hashable, Codable, Sendable {
    public var sessionID: String
    public var url: URL?
    public var title: String
    public var groupID: String?
    public init(sessionID: String, url: URL?, title: String, groupID: String? = nil) {
        self.sessionID = sessionID
        self.url = url
        self.title = title
        self.groupID = groupID
    }
}

public struct EngineSessionWindow: Hashable, Codable, Sendable {
    public var sessionID: String
    public var tabs: [EngineSessionTab]
    public init(sessionID: String, tabs: [EngineSessionTab]) {
        self.sessionID = sessionID
        self.tabs = tabs
    }
}
