// The `PluginContext` of a JavaScript hook script's instance (`docs/hooks.md`, JavaScript scripts; Run tabs): bound to one hook in one Persona with the hook's grant, it acts only during a run, for that run. `arch.tabs` reaches only the run's tabs, renames go to the run's document for each tab with the run's cause and its test flag, and for a hook with `agent` the tabs on sites excluded from AI show neither title nor address. Storage and secrets are empty and take no values; a hook script has no settings, badges, or clipboard.
import Agent
import Events
import Foundation
import Plugins

@MainActor
final class HookScriptContext: PluginContext {
    let pluginID: PluginID
    let personaID: PersonaID
    let grant: PluginGrant
    let storage: any PluginStorage = EmptyHookStorage()
    let secrets: any PluginSecrets = EmptyHookSecrets()
    private let host: any PluginBrowserHost
    private let usesAgent: Bool
    /// The AI interface's site check, which a hook with `agent` applies to each tab's title and address (hook decision 14).
    private let allowsAI: (URL) -> Bool
    private var run: HookInvocation?
    private var actions: [AgentRunAction] = []
    private var hasEnded = false

    init(hook: Hook, personaID: PersonaID, host: any PluginBrowserHost, allowsAI: @escaping (URL) -> Bool) {
        pluginID = HookScriptContext.pluginID(of: hook.id)
        self.personaID = personaID
        grant = PluginGrant(permissions: HookScriptContext.permissions(of: hook.grant), sites: [])
        usesAgent = hook.usesAgent
        self.host = host
        self.allowsAI = allowsAI
    }

    /// `xyz.taeyoon.arch.hook.<hook id>`, the identifier of the hook's package and its sandbox's origin.
    static func pluginID(of hook: UUID) -> PluginID {
        // A UUID's text is letters, digits, and hyphens.
        PluginID(rawValue: "xyz.taeyoon.arch.hook.\(hook.uuidString)")!
    }

    /// The plugin permissions that stand for the hook's: `tabs` and `tabs.rename`. The agent run API brings `agent` (VII.27).
    static func permissions(of grant: HookGrant) -> Set<PluginPermission> {
        var permissions: Set<PluginPermission> = []
        if grant.permissions.contains(.tabs) { permissions.insert(.tabs) }
        if grant.permissions.contains(.tabsRename) { permissions.insert(.renameTabs) }
        return permissions
    }

    /// The run whose calls the instance makes from now until `finish()`.
    func begin(_ invocation: HookInvocation) {
        run = invocation
        actions = []
    }

    /// Ends the run and returns its actions: applied, or in a test proposed.
    func finish() -> [AgentRunAction] {
        run = nil
        defer { actions = [] }
        return actions
    }

    /// The instance stopped; no call acts any more.
    func end() {
        hasEnded = true
        run = nil
    }

    private func currentRun() throws -> HookInvocation {
        guard !hasEnded, let run else { throw PluginError.stopped }
        return run
    }

    func setting(_ key: String) -> PluginValue? { nil }

    func setBadge(_ text: String?, onSidebarItem id: String) {}

    func copyToClipboard(_ text: String) throws {
        throw PluginError.permissionDenied(.clipboard)
    }

    func tabs() throws -> [PluginTab] {
        let run = try currentRun()
        return host.tabs(in: personaID).filter { run.tabs.contains($0.id) }.map { shown($0, document: run.documents[$0.id]) }
    }

    func tab(_ id: PluginTab.ID) throws -> PluginTab? {
        try tabs().first { $0.id == id }
    }

    /// A tab outside the run's tabs is refused; a tab without a document for the run, one without a committed address when the run started, takes no name.
    func renameTab(_ id: PluginTab.ID, to name: String?) throws -> Bool {
        let run = try currentRun()
        guard grant.permissions.contains(.renameTabs) else { throw PluginError.permissionDenied(.renameTabs) }
        guard run.tabs.contains(id) else { throw PluginError.notGranted(id) }
        guard let document = run.documents[id] else { return false }
        let took = host.renameTab(id, to: name, showing: document, cause: run.cause, applying: run.appliesActions)
        if took, let shown = name.flatMap(PluginTab.name(from:)) { actions.append(.renamedTab(tab: id, name: shown)) }
        return took
    }

    /// The tab without its title and address unless the grant has `tabs`, and for a hook with `agent` also when the address it shows or the document it committed is on a site excluded from AI, since a tab that leaves such a page still shows that page's title until the next one commits.
    private func shown(_ tab: PluginTab, document: URL?) -> PluginTab {
        let excluded = usesAgent && [tab.url, document].contains { $0.map { !allowsAI($0) } ?? false }
        guard !grant.permissions.contains(.tabs) || excluded else { return tab }
        var tab = tab
        tab.title = nil
        tab.url = nil
        return tab
    }
}

/// A hook script's storage, which holds nothing and takes nothing.
@MainActor
private final class EmptyHookStorage: PluginStorage {
    func value(forKey key: String) -> PluginValue? { nil }

    func setValue(_ value: PluginValue?, forKey key: String) throws {
        throw PluginError.quotaExceeded
    }

    func allKeys() -> [String] { [] }
}

/// A hook script's secrets, which hold nothing and take nothing.
@MainActor
private final class EmptyHookSecrets: PluginSecrets {
    func secret(forKey key: String) throws -> String? { nil }

    func setSecret(_ secret: String?, forKey key: String) throws {
        throw PluginError.quotaExceeded
    }
}
