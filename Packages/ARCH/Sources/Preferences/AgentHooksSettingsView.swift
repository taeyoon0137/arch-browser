// Settings ▸ AI ▸ Agent Hooks (`docs/hooks.md`, Settings ▸ AI ▸ Agent Hooks): Run Hooks, the notices about `hooks.json`, New Script Hook…, and every hook in run order. Each row has its switch, name, situation, model and record for an agent hook, last run, and the program that added it, a paused hook's reason with Resume or Review, and a menu with Edit…, Run on Current Tab, Duplicate, and Delete; dragging reorders the rows, and a row opens to its last runs. New Agent Hook…, the presets, and Allow Shell Scripts come with the tasks that build them.
import Agent
import AI
import Browsing
import Events
import Hooks
import SwiftUI

struct AgentHooksPage: View {
    @ObservedObject var registry: HookRegistry
    /// The front main window's selected tab, for Run on Current Tab.
    let currentTab: () -> UUID?
    @State private var sheet: ScriptHookDraft?
    @State private var deleting: Hook?
    @State private var opened: Set<UUID> = []
    @State private var message: String?

    private struct ProviderReview {
        let hook: UUID
        let providers: [HookKnownProvider]
        let description: String
    }
    @State private var providerReview: ProviderReview?

    var body: some View {
        Section {
            Toggle("Run Hooks", isOn: $registry.runsHooks)
                .disabled(!registry.isReady)
            if let notice = registry.notice {
                HStack(alignment: .firstTextBaseline) {
                    Text(HookSummary.sentence(for: notice)).foregroundStyle(.secondary)
                    if case .keyUnavailable = notice {
                        Spacer()
                        Button("Try Again") { registry.retryLoading() }
                    }
                }
            }
            HStack {
                Spacer()
                Button("New Script Hook…") { sheet = ScriptHookDraft(new: registry.places) }
                    .disabled(!registry.isReady)
            }
        } footer: {
            formFootnote("A hook runs a script when something happens in a tab, such as a new tab loading its first page. Hooks run one after another, in this list's order, after Arch's own AI features. While Run Hooks is off, no hook runs.")
        }
        Section("Hooks") {
            if registry.hooks.isEmpty {
                Text("No hooks yet.").foregroundStyle(.secondary)
            }
            ForEach(registry.hooks) { hook in
                row(for: hook)
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                let hook = registry.hooks[from]
                // `onMove` counts the destination before the moved row leaves.
                registry.move(hook.id, to: destination > from ? destination - 1 : destination)
            }
        }
        .sheet(item: $sheet) { draft in
            ScriptHookSheet(registry: registry, draft: draft) { sheet = nil }
        }
        .confirmationDialog("Allow this hook’s provider destinations?", isPresented: Binding(get: { providerReview != nil }, set: { if !$0 { providerReview = nil } }),
                            titleVisibility: .visible, presenting: providerReview) { review in
            Button("Allow") { registry.approveProviders(review.providers, for: review.hook) }
        } message: { review in
            Text(review.description)
        }
        .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { hook in
            Button("Delete", role: .destructive) { registry.remove(hook.id) }
        } message: { _ in
            Text("Arch deletes the hook and its script.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
    }

    private func row(for hook: Hook) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { opened.contains(hook.id) }, set: { isOpen in
            if isOpen { opened.insert(hook.id) } else { opened.remove(hook.id) }
        })) {
            lastRuns(of: hook)
        } label: {
            HStack(alignment: .top) {
                Toggle(hook.name, isOn: Binding(get: { hook.state == .active }, set: { isOn in
                    if isOn { registry.resume(hook.id) } else { registry.pause(hook.id) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hook.name).fontWeight(.medium)
                    ForEach(HookSummary.lines(for: hook, places: registry.places, lastRun: registry.lastRuns[hook.id]?.last), id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = hook.state.pauseReason {
                        pauseRow(for: hook, reason: reason)
                    }
                }
                Spacer()
                menu(for: hook)
            }
        }
    }

    private func pauseRow(for hook: Hook, reason: HookPauseReason) -> some View {
        HStack {
            Text(HookSummary.sentence(for: reason)).font(.caption).foregroundStyle(.orange)
            switch reason {
            case .scriptChanged:
                Button("Review") { edit(hook, reviewing: true) }
                    .disabled(hook.script.isShell)
            case .unknownProvider:
                Button("Review") {
                    let providers = registry.providersForReview(of: hook.id)
                    guard !providers.isEmpty else { return registry.resume(hook.id) }
                    let settings = AIService.shared.settings
                    let destinations = providers.map { item in
                        let name = settings.providers.first { $0.id == item.id }?.name ?? item.id.rawValue
                        return "\(name) — \(item.destination)"
                    }
                    providerReview = ProviderReview(hook: hook.id, providers: providers, description: destinations.joined(separator: "\n"))
                }
            case .user, .needsNewerArch:
                EmptyView()
            default:
                Button("Resume") { registry.resume(hook.id) }
            }
        }
    }

    private func menu(for hook: Hook) -> some View {
        let isReadable = hook.state != .paused(.needsNewerArch)
        return Menu {
            Button("Edit…") { edit(hook, reviewing: false) }
                .disabled(!isReadable || hook.script.isShell)
            Button("Run on Current Tab") { runOnCurrentTab(hook) }
                .disabled(!isReadable)
            Button("Duplicate") { duplicate(hook) }
                .disabled(!isReadable || hook.state == .paused(.scriptChanged))
            Divider()
            Button("Delete…", role: .destructive) { deleting = hook }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func lastRuns(of hook: Hook) -> some View {
        let runs = (registry.lastRuns[hook.id] ?? []).reversed()
        if runs.isEmpty {
            Text("No runs since Arch started.").foregroundStyle(.secondary)
        }
        ForEach(Array(runs)) { run in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(run.date.formatted(date: .omitted, time: .standard)) · \(HookSummary.description(of: run))")
                if let message = run.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    // MARK: Actions

    private func edit(_ hook: Hook, reviewing: Bool) {
        sheet = HookScriptActions.draft(editing: hook, file: registry.scriptFile(of: hook.id), places: registry.places, reviewing: reviewing)
    }

    private func runOnCurrentTab(_ hook: Hook) {
        guard let tab = currentTab() else {
            message = "Select a tab in a browser window first."
            return
        }
        Task {
            let result = await registry.test(hook.id, onTab: tab, applying: true)
            message = HookSummary.description(of: result, hookName: hook.name)
        }
    }

    private func duplicate(_ hook: Hook) {
        do {
            let copy = try HookScriptActions.copy(of: hook, file: registry.scriptFile(of: hook.id))
            try registry.add(copy.hook, script: copy.script)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// What Edit…, Review, and Duplicate make of a hook and its script file. A file changed outside Arch opens only for review, with its notice, and no copy takes it, so bytes that another program wrote run only once the user has read and saved them (hook decision 8).
enum HookScriptActions {
    struct Refusal: LocalizedError {
        let sentence: String
        var errorDescription: String? { sentence }
    }

    /// The sheet's draft for the hook with the file's text, in review when the user asked for it or the file no longer matches its digest.
    static func draft(editing hook: Hook, file: HookScriptFile?, places: [HookPersonaPlaces], reviewing: Bool) -> ScriptHookDraft {
        let script = file.flatMap { String(data: $0.contents, encoding: .utf8) } ?? ""
        return ScriptHookDraft(editing: hook, script: script, places: places, reviewing: reviewing || file?.matchesDigest == false)
    }

    /// A copy for after the list's last hook, with the original's script, switched on and the user's. Refused for a file that is missing or changed outside Arch.
    static func copy(of hook: Hook, file: HookScriptFile?) throws -> (hook: Hook, script: Data) {
        let name = "\u{201C}\(hook.name)\u{201D}"
        guard let file else { throw Refusal(sentence: "Arch cannot read the script of \(name).") }
        guard file.matchesDigest else { throw Refusal(sentence: "The script of \(name) changed outside Arch. Review it before you duplicate the hook.") }
        var copy = hook
        copy.id = UUID()
        copy.name = "\(hook.name) Copy"
        copy.state = .active
        copy.origin = .user
        copy.created = Date()
        return (copy, file.contents)
    }
}

// MARK: - Texts

/// The sentences Settings ▸ AI ▸ Agent Hooks shows for hooks, their places, their runs, and the notices about `hooks.json`.
@MainActor
enum HookSummary {
    /// The row's lines under the name: the situation, the scope, and the sites; an agent hook's model and record; the last run; and the program that added the hook.
    static func lines(for hook: Hook, places: [HookPersonaPlaces], lastRun: HookRunSummary?) -> [String] {
        var lines = [[situation(of: hook.trigger), scope(of: hook.filter.scope, places: places), sites(of: hook.filter)].joined(separator: " · ")]
        if hook.usesAgent, let agent = hook.agent {
            lines.append([model(of: agent.model), record(of: hook.record)].joined(separator: " · "))
        } else if hook.record == .none {
            lines.append(record(of: hook.record))
        }
        if let lastRun {
            lines.append("\(lastRun.date.formatted(.relative(presentation: .named))) · \(description(of: lastRun))")
        }
        if case .outsideClient(_, let name) = hook.origin {
            lines.append("Added by \(name)")
        }
        return lines
    }

    static func situation(of trigger: HookTrigger) -> String {
        switch trigger {
        case .tabOpened: return "When a new tab opens"
        case .tabClosed(let reasons): return reasons == [.user] ? "When you close a tab" : "When a tab closes"
        case .pageLoaded(let loads, _):
            switch loads {
            case .firstAfterOpen: return "When a new tab loads its first page"
            case .newAddress: return "When a tab loads a new address"
            case .every: return "When a tab loads a page"
            }
        case .addressChanged(let changes): return changes == .newHost ? "When a tab moves to another site" : "When a tab's address changes"
        case .titleChanged: return "When a tab's title changes"
        case .tabSelected: return "When you select a tab"
        case .downloadFinished: return "When a download finishes"
        case .spaceSwitched(let personaChangesOnly): return personaChangesOnly ? "When you switch to another Persona" : "When you switch spaces"
        }
    }

    /// "Everywhere", or each place as `name(of:places:)` names it.
    static func scope(of scope: BrowserEventScope, places: [HookPersonaPlaces]) -> String {
        guard case .places(let chosen) = scope else { return "Everywhere" }
        guard !chosen.isEmpty else { return "Nowhere" }
        return chosen.map { name(of: $0, places: places) }.joined(separator: ", ")
    }

    /// A place as Persona rule 7 names it (`BrowserSession.displayedPlace(ofPersona:space:among:)`): a space as "Persona / Space" and a whole Persona by its name, while the default Persona is the only one a space by its name alone and the Persona, which then covers every place, as Everywhere.
    static func name(of place: BrowserPlace, places: [HookPersonaPlaces]) -> String {
        let personas = places.map { Persona(id: $0.id, name: $0.name) }
        switch place {
        case .persona(let id):
            guard places.contains(where: { $0.id == id }) else { return "Deleted Persona" }
            return BrowserSession.displayedPlace(ofPersona: id, space: nil, among: personas) ?? "Everywhere"
        case .space(let id):
            guard let persona = places.first(where: { $0.spaces.contains { $0.id == id } }), let space = persona.spaces.first(where: { $0.id == id }) else { return "Deleted Space" }
            return BrowserSession.displayedPlace(ofPersona: persona.id, space: Space(id: space.id, name: space.name, personaID: persona.id), among: personas) ?? space.name
        }
    }

    static func sites(of filter: BrowserEventFilter) -> String {
        if !filter.sites.isEmpty { return "Only " + filter.sites.map(\.value).joined(separator: ", ") }
        if !filter.exceptSites.isEmpty { return "All sites except " + filter.exceptSites.map(\.value).joined(separator: ", ") }
        return "All sites"
    }

    static func model(of choice: AIRouteChoice) -> String {
        switch choice {
        case .tier(let tier):
            let model = AIService.shared.settings.route(for: .tier(tier)).models.first?.model
            return model.map { "\(tier.title) · \($0.isEmpty ? "default model" : $0)" } ?? "\(tier.title) · no model"
        case .models(let models):
            return models.first.map { $0.model.isEmpty ? "Default model" : $0.model } ?? "No model"
        }
    }

    static func record(of record: AgentRunRecord) -> String {
        switch record {
        case .session: return "Keeps the session"
        case .activity: return "Keeps activity only"
        case .none: return "Keeps nothing"
        }
    }

    /// "Completed · renamed a tab", "Failed: …", "Skipped: rate limit", and so on.
    static func description(of run: HookRunSummary) -> String {
        let prefix = run.test ? "Test · " : ""
        switch run.outcome {
        case .completed:
            let renames = run.actions?["renameTab"] ?? 0
            return prefix + (renames == 0 ? "Completed" : renames == 1 ? "Renamed a tab" : "Renamed \(renames) tabs")
        case .failed: return prefix + "Failed" + (run.code.map { " (\($0))" } ?? "")
        case .timedOut: return prefix + "Ran out of time"
        case .cancelled: return prefix + "Stopped"
        case .skipped:
            switch run.reason {
            case .loop?: return "Skipped: its own change or a chain of hooks"
            case .rateLimit?: return "Skipped: too many runs in a minute"
            case .dailyLimit?: return "Skipped: today's runs are used up"
            case .budget?: return "Skipped: an AI limit was reached"
            case .dropped?: return "Skipped: too many runs waited"
            case nil: return "Skipped"
            }
        }
    }

    /// What Run on Current Tab reports.
    static func description(of result: HookRunResult, hookName: String) -> String {
        let name = "\u{201C}\(hookName)\u{201D}"
        switch result {
        case .notRun(let sentence): return "\(name) did not run. \(sentence)"
        case .finished(let outcome):
            switch outcome {
            case .completed(let actions, _):
                let renames = actions.filter { $0.kind == "renameTab" }.count
                return renames == 0 ? "\(name) ran and changed nothing." : "\(name) ran and renamed \(renames == 1 ? "a tab" : "\(renames) tabs")."
            case .failed(_, let message): return "\(name) failed: \(message)"
            case .timedOut: return "\(name) ran out of time."
            case .cancelled: return "\(name) was stopped."
            }
        }
    }

    static func sentence(for reason: HookPauseReason) -> String {
        switch reason {
        case .user: return "Paused."
        case .failures: return "Paused after \(HookRegistry.failuresBeforePause) failed runs in a row."
        case .providerErrors: return "Paused after repeated errors from its model's provider."
        case .ranTooOften: return "This hook ran too often, so Arch paused it."
        case .stopAllAgents: return "Paused by Stop All Agents."
        case .placeDeleted: return "Paused: the Personas and spaces it ran in were deleted."
        case .scriptChanged: return "Its script changed outside Arch."
        case .shellScriptsOff: return "Shell scripts are off."
        case .needsNewerArch: return "This hook needs a newer version of Arch."
        case .grantEnded: return "The program's access ended."
        case .unknownProvider: return "Its run would reach a provider that was not set up in Arch."
        }
    }

    static func sentence(for notice: HookStoreNotice) -> String {
        switch notice {
        case .setAside: return "hooks.json could not be opened, so Arch renamed it hooks.json.unreadable and started with no hooks."
        case .keyUnavailable(let reason): return "The Keychain did not give the key of hooks.json, so no hook runs: \(reason)"
        case .newerVersion(let version): return "hooks.json is from a newer version of Arch, version \(version). Arch kept a copy as hooks-v\(version).json and lists the hooks it cannot read without running them."
        case .notSaved(let reason): return "Arch could not save the last change to the hooks: \(reason)"
        }
    }
}
