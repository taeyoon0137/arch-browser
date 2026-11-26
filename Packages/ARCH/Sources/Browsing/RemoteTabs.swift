// Open tabs from another Mac are addresses to open locally, never live tabs or saved page state.
import ARCHEngine
import Foundation

public struct RemoteTab: Codable, Hashable, Sendable {
    public var url: URL
    public var title: String
    public var engine: EngineKind
    public var order: Int

    public init(url: URL, title: String, engine: EngineKind, order: Int) {
        self.url = url
        self.title = title
        self.engine = engine
        self.order = order
    }

    /// Only web addresses without embedded credentials cross devices or open from remote rows.
    public static func address(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil
        parts.password = nil
        return parts.url
    }
}

public struct OpenTabsSpace: Codable, Hashable, Sendable {
    public var personaID: UUID
    public var spaceID: UUID
    public var tabs: [RemoteTab]

    public init(personaID: UUID, spaceID: UUID, tabs: [RemoteTab]) {
        self.personaID = personaID
        self.spaceID = spaceID
        self.tabs = tabs
    }

    /// The snapshot already excludes small windows, agent folders and their tabs, and favorites.
    static func project(_ snapshot: SessionSnapshot, defaultEngine: EngineKind) -> [OpenTabsSpace] {
        snapshot.spaces.map { space in
            let folders = (snapshot.folders ?? []).filter { $0.spaceID == space.id && !$0.isPinned && !$0.isAgentFolder }
            let tabs = snapshot.tabs.filter { !$0.isPinned && $0.spaceID == space.id && ($0.personaID ?? Persona.defaultID) == space.resolvedPersonaID }
            var ordered: [SessionSnapshot.TabRecord] = []
            var visited = Set<UUID>()
            func append(in parent: UUID?) {
                for folder in folders where folder.parentID == parent && visited.insert(folder.id).inserted {
                    append(in: folder.id)
                }
                ordered += tabs.filter { $0.folderID == parent }
            }
            append(in: nil)
            let pages = ordered.compactMap { tab -> RemoteTab? in
                guard let url = tab.url.flatMap(RemoteTab.address) else { return nil }
                return RemoteTab(url: url, title: Tab.displayTitle(customTitle: tab.customTitle, suggestedTitle: tab.suggestedTitle, title: tab.title, url: url),
                                 engine: tab.engine ?? defaultEngine, order: 0)
            }.enumerated().map { index, tab in
                var tab = tab
                tab.order = index
                return tab
            }
            return OpenTabsSpace(personaID: space.resolvedPersonaID, spaceID: space.id, tabs: pages)
        }
    }
}

public struct RemoteTabGroup: Identifiable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 14 * 24 * 60 * 60
    public var deviceID: String
    public var deviceName: String
    public var personaID: UUID
    public var spaceID: UUID
    public var tabs: [RemoteTab]
    public var updatedAt: Date
    public var id: String { deviceID + ":" + spaceID.uuidString }

    public init(deviceID: String, deviceName: String, personaID: UUID, spaceID: UUID, tabs: [RemoteTab], updatedAt: Date) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.personaID = personaID
        self.spaceID = spaceID
        self.tabs = tabs
        self.updatedAt = updatedAt
    }

    public var title: String { localized("\(deviceName)'s Tabs") }

    var orderedTabs: [RemoteTab] {
        tabs.enumerated().filter { RemoteTab.address($0.element.url) != nil }
            .sorted { $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order }
            .map(\.element)
    }

    func isVisible(in space: Space, now: Date) -> Bool {
        personaID == space.resolvedPersonaID && spaceID == space.id && !orderedTabs.isEmpty
            && now.timeIntervalSince(updatedAt) < Self.lifetime
    }
}

/// Shared labels use Browsing's catalog in Settings and both sidebar menus.
public enum RemoteTabsStrings {
    public static var showTabs: String { localized("Show Tabs from Other Macs") }
    public static var hideTabs: String { localized("Hide Tabs from Other Macs") }
    public static var explanation: String {
        localized("Sync Personas, spaces, favorites, pinned tabs and their folders, and some settings. Optionally share open tab addresses and titles with your other Macs. Cookies, website data, history, and sign-in state stay on this Mac.")
    }
}

extension BrowserSession {
    func remoteTabs(in space: Space, now: Date = Date()) -> [RemoteTabGroup] {
        guard isSyncing, showRemoteTabs else { return [] }
        return remoteTabGroups.filter { $0.isVisible(in: space, now: now) }.sorted {
            let comparison = $0.deviceName.localizedStandardCompare($1.deviceName)
            return comparison == .orderedSame ? $0.deviceID < $1.deviceID : comparison == .orderedAscending
        }
    }

    func toggleRemoteTabsCollapsed(_ group: RemoteTabGroup) {
        if !collapsedRemoteTabGroupIDs.insert(group.id).inserted { collapsedRemoteTabGroupIDs.remove(group.id) }
    }

    /// Opens a fresh local tab only while the remote row still belongs to an existing local space.
    @discardableResult
    public func openRemoteTab(_ tab: RemoteTab, from group: RemoteTabGroup, select: Bool = true, now: Date = Date()) -> Tab? {
        guard let space = spaces.first(where: { $0.id == group.spaceID }),
              remoteTabs(in: space, now: now).contains(where: { $0.id == group.id && $0.tabs.contains(tab) }),
              let url = RemoteTab.address(tab.url) else { return nil }
        return openTab(url: url, in: space.id, select: select, engine: tab.engine)
    }
}
