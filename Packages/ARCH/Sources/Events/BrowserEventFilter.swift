// Which events a subscriber, a hook, or an outside program's watch takes (`docs/hooks.md`, The bus). Site lists match through `AISitePattern`, the matcher that site exclusions use.
import AI
import ARCHEngine
import Foundation

public struct BrowserEventFilter: Codable, Hashable, Sendable {
    /// Empty matches every kind.
    public var kinds: Set<BrowserEventKind>
    public var scope: BrowserEventScope
    /// Empty matches every site. Otherwise an event matches only when one of its addresses matches a pattern, so an event without an address never matches a site list.
    public var sites: [AISitePattern]
    /// An event none of whose addresses matches one of these.
    public var exceptSites: [AISitePattern]
    /// Empty matches both engines. Events without a tab ignore it.
    public var engines: Set<EngineKind>
    /// Empty matches every kind but `agent`, which only a filter that names it matches. Events without a tab ignore it.
    public var tabKinds: Set<BrowserTabKind>

    public init(kinds: Set<BrowserEventKind> = [], scope: BrowserEventScope = .everywhere, sites: [AISitePattern] = [], exceptSites: [AISitePattern] = [],
                engines: Set<EngineKind> = [], tabKinds: Set<BrowserTabKind> = []) {
        self.kinds = kinds
        self.scope = scope
        self.sites = sites
        self.exceptSites = exceptSites
        self.engines = engines
        self.tabKinds = tabKinds
    }

    /// Every event but those of agent tabs.
    public static let everything = BrowserEventFilter()

    public func matches(_ event: BrowserEvent) -> Bool {
        guard kinds.isEmpty || kinds.contains(event.kind), scope.contains(event) else { return false }
        let urls = event.urls
        guard sites.isEmpty || urls.contains(where: { url in sites.contains { $0.matches(url) } }),
              !urls.contains(where: { url in exceptSites.contains { $0.matches(url) } }) else { return false }
        guard let tab = event.tab else { return true }
        return (engines.isEmpty || engines.contains(tab.engine)) && (tabKinds.isEmpty ? tab.kind != .agent : tabKinds.contains(tab.kind))
    }
}

/// In JSON, `"everywhere"` or the list of places.
public enum BrowserEventScope: Codable, Hashable, Sendable {
    case everywhere
    /// Whole Personas and single spaces, which the interface shows as "Persona" and "Persona / Space".
    case places([BrowserPlace])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let word = try? container.decode(String.self) {
            guard word == "everywhere" else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown scope \(word)") }
            self = .everywhere
        } else {
            self = .places(try container.decode([BrowserPlace].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .everywhere: try container.encode("everywhere")
        case .places(let places): try container.encode(places)
        }
    }

    /// Whether the event happened in one of the places: its Persona, or its space (`BrowserEvent.spaceID`), which for `spaceSwitched` is the space the window switched to. A favorite's tab and a download belong to their Persona only, so only a whole Persona takes them.
    func contains(_ event: BrowserEvent) -> Bool {
        guard case .places(let places) = self else { return true }
        return places.contains { place in
            switch place {
            case .persona(let id): return id == event.personaID
            case .space(let id): return id == event.spaceID
            }
        }
    }
}

/// In JSON, `{"persona": "<id>"}` or `{"space": "<id>"}`.
public enum BrowserPlace: Codable, Hashable, Sendable {
    case persona(UUID)
    case space(UUID)

    private enum CodingKeys: String, CodingKey {
        case persona, space
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .persona) {
            self = .persona(id)
        } else {
            self = .space(try container.decode(UUID.self, forKey: .space))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .persona(let id): try container.encode(id, forKey: .persona)
        case .space(let id): try container.encode(id, forKey: .space)
        }
    }
}
