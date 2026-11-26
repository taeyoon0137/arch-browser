// Bridges CloudKit's plugin list to each Persona's manager and installs missing packages.
import Combine
import Foundation
import Plugins

public struct PersonaPluginSyncItem: Hashable, Sendable {
    public let personaID: UUID
    public let item: PluginSyncItem

    public init(personaID: UUID, item: PluginSyncItem) {
        self.personaID = personaID
        self.item = item
    }
}

@MainActor public protocol SyncedPlugins: AnyObject {
    var pluginSyncItems: [PersonaPluginSyncItem] { get }
    var onPluginSyncChange: (() -> Void)? { get set }
    func applyPluginSync(_ items: [PersonaPluginSyncItem], deleted: [PersonaPluginSyncItem]) throws
    func setPluginSyncActive(_ active: Bool)
}

/// Text shared with Settings, kept in Browsing's English and Korean catalog.
public enum PluginSyncLabels {
    public static var toggle: String { localized("Sync Plugins") }
    public static var explanation: String { localized("Sync installed plugins, their enabled state, and non-secret settings. Plugin storage and secrets stay on this Mac.") }
    public static var install: String { localized("Install on this Mac") }
    public static var installing: String { localized("Installing synced plugin…") }
    public static var retry: String { localized("Retry Installation") }
    public static var remove: String { localized("Remove from Synced Plugins") }
}

extension BrowserSession: SyncedPlugins {
    public var pluginSyncItems: [PersonaPluginSyncItem] {
        personas.flatMap { persona in
            plugins(in: persona.id).syncItems.map { PersonaPluginSyncItem(personaID: persona.id, item: $0) }
        }
    }

    public var onPluginSyncChange: (() -> Void)? {
        get { pluginSync.onChange }
        set { pluginSync.onChange = newValue }
    }

    public func applyPluginSync(_ items: [PersonaPluginSyncItem], deleted: [PersonaPluginSyncItem]) throws {
        let incoming = Dictionary(grouping: items, by: \.personaID)
        let removals = Dictionary(grouping: deleted, by: \.personaID)
        for persona in personas {
            let manager = plugins(in: persona.id)
            try manager.applySyncItems(incoming[persona.id, default: []].map(\.item),
                                       deleting: Set(removals[persona.id, default: []].map { $0.item.id }))
        }
        pluginSync.reconcile(in: self)
    }

    public func setPluginSyncActive(_ active: Bool) {
        pluginSync.setActive(active, in: self)
    }

    public func retryPluginSync(_ item: PluginSyncItem, in personaID: UUID) {
        pluginSync.retry(item, personaID: personaID, in: self)
    }
}

/// Local downloads can be cancelled. Their progress and failures stay out of CloudKit.
@MainActor public final class PluginSyncCoordinator: ObservableObject {
    @Published public private(set) var failures: [UUID: [String: String]] = [:]
    @Published public private(set) var installing: [UUID: Set<String>] = [:]
    var onChange: (() -> Void)?
    @Published public private(set) var isActive = false
    private struct Key: Hashable { let persona: UUID; let id: String }
    private struct Install {
        let item: PluginSyncItem
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var tasks: [Key: Install] = [:]
    private var failedItems: [Key: PluginSyncItem] = [:]
    /// Tests supply staged packages without reaching a server or starting an engine.
    var stagePackage: ((PluginSyncItem, PluginManager) async throws -> PluginPackage)?

    func setActive(_ active: Bool, in session: BrowserSession) {
        if active && !isActive {
            failures.removeAll()
            failedItems.removeAll()
        }
        isActive = active
        if active { reconcile(in: session) }
        else {
            tasks.values.forEach { $0.task.cancel() }
            tasks.removeAll()
            installing.removeAll()
        }
    }

    func cancel(in persona: UUID) {
        for key in Array(tasks.keys) where key.persona == persona {
            tasks.removeValue(forKey: key)?.task.cancel()
        }
        failures[persona] = nil
        failedItems = failedItems.filter { $0.key.persona != persona }
        installing[persona] = nil
    }

    func retry(_ item: PluginSyncItem, personaID: UUID, in session: BrowserSession) {
        guard isActive else { return }
        failures[personaID]?[item.id] = nil
        failedItems[Key(persona: personaID, id: item.id)] = nil
        reconcile(in: session)
    }

    func reconcile(in session: BrowserSession) {
        guard isActive else { return }
        let pending = session.personas.flatMap { persona in
            session.plugins(in: persona.id).pendingSyncItems.map { PersonaPluginSyncItem(personaID: persona.id, item: $0) }
        }
        let wanted = Dictionary(pending.map { (Key(persona: $0.personaID, id: $0.item.id), $0.item) }, uniquingKeysWith: { first, _ in first })
        for (key, failed) in failedItems where wanted[key] != failed {
            failedItems[key] = nil
            failures[key.persona]?[key.id] = nil
        }
        for (key, running) in tasks where wanted[key] != running.item {
            running.task.cancel()
            tasks[key] = nil
            installing[key.persona]?.remove(key.id)
        }
        for (key, item) in wanted where item.source != nil && tasks[key] == nil && failures[key.persona]?[key.id] == nil {
            start(item, key: key, in: session)
        }
    }

    private func start(_ item: PluginSyncItem, key: Key, in session: BrowserSession) {
        let manager = session.plugins(in: key.persona)
        let generation = UUID()
        installing[key.persona, default: []].insert(key.id)
        let task = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                if tasks[key]?.generation == generation {
                    tasks[key] = nil
                    installing[key.persona]?.remove(key.id)
                }
            }
            do {
                let package: PluginPackage
                if let stagePackage { package = try await stagePackage(item, manager) }
                else {
                    switch item.source {
                    case let .webStore(id): package = try await session.webStore.stage(id, in: manager, includingInstalledVersion: true)
                    case let .url(url): package = try await PluginSyncDownload.stage(url, in: manager)
                    case nil: return
                    }
                }
                defer { manager.discard(package) }
                try Task.checkCancellation()
                guard isActive, !manager.isClosed, session.personas.contains(where: { $0.id == key.persona }),
                      manager.pendingSyncItems.contains(item), tasks[key]?.generation == generation else { return }
                try manager.installSynced(package, for: item)
                failures[key.persona]?[key.id] = nil
                failedItems[key] = nil
            } catch {
                if !Task.isCancelled, !manager.isClosed, tasks[key]?.generation == generation {
                    failedItems[key] = item
                    failures[key.persona, default: [:]][key.id] = localized("The synced plugin could not be installed. Retry or choose its package on this Mac.")
                }
            }
        }
        tasks[key] = Install(item: item, generation: generation, task: task)
    }
}
