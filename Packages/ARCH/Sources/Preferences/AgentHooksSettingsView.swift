// Settings ▸ AI ▸ Hooks controls Run Hooks and Allow Shell Scripts (`docs/hooks.md`).
// It shows notices about `hooks.json`, New Script Hook…, hooks in run order, and Clear Activity.
// Each row shows its switch, name, situation, last run, and the program that added it. Agent hooks also show their model and record.
// A paused row shows its reason with Resume or Review. Its menu offers Edit…, Run on Current Tab, Duplicate, and Delete.
// Dragging reorders rows. Opening a row shows its last runs, including a shell script's standard error.
// A run kept with Keep the Session offers Show Session and Delete Session…. An agent-capable model enables New Agent Hook….
import Agent
import AI
import Browsing
import Events
import Hooks
import SwiftUI

struct AgentHooksPage: View {
    @ObservedObject var registry: HookRegistry
    /// The agents' runner, whose kept runs Show Session shows.
    @ObservedObject var runner: AgentRunner
    @ObservedObject private var aiSettings = AIService.shared.settings
    /// The front main window's selected tab, for Run on Current Tab.
    let currentTab: () -> UUID?
    @State private var sheet: ScriptHookDraft?
    @State private var deleting: Hook?
    @State private var opened: Set<UUID> = []
    /// The last runs whose transcript is shown.
    @State private var shownSessions: Set<UUID> = []
    /// The last run whose Delete Session… waits for confirmation.
    @State private var deletingSession: UUID?
    @State private var message: String?

    private struct ProviderReview {
        let hook: UUID
        let providers: [HookKnownProvider]
        let description: String
    }
    @State private var providerReview: ProviderReview?

    var body: some View {
        Section {
            Toggle(localized("Run Hooks"), isOn: $registry.runsHooks)
                .disabled(!registry.isReady)
            Toggle(localized("Allow Shell Scripts"), isOn: Binding(get: { registry.allowsShellScripts }, set: { registry.setAllowsShellScripts($0) }))
                .disabled(!registry.isReady)
            if let notice = registry.notice {
                HStack(alignment: .firstTextBaseline) {
                    Text(HookSummary.sentence(for: notice)).foregroundStyle(.secondary)
                    if case .keyUnavailable = notice {
                        Spacer()
                        Button(localized("Try Again")) { registry.retryLoading() }
                    }
                }
            }
            HStack {
                Spacer()
                if aiSettings.providers.contains(where: { provider in provider.models.contains { provider.capabilities(of: $0).contains(.agent) } }) {
                    Menu(localized("Presets")) {
                        Button(localized("Tidy Tab Names")) {
                            let hook = HookPresets.tidyTabNames
                            sheet = ScriptHookDraft(editing: hook, script: AgentHookTemplate.script(for: hook.trigger.kind),
                                                    places: registry.places, reviewing: false, isNew: true)
                        }
                    }
                    .disabled(!registry.isReady)
                    Button(localized("New Agent Hook…")) { sheet = ScriptHookDraft(new: registry.places, guided: true) }
                        .disabled(!registry.isReady)
                }
                Button(localized("New Script Hook…")) { sheet = ScriptHookDraft(new: registry.places) }
                    .disabled(!registry.isReady)
            }
        } footer: {
            formFootnote(localized("A hook runs a script when something happens in a tab, such as a new tab loading its first page. Hooks run one after another, in this list's order, after Arch's own AI features. While Run Hooks is off, no hook runs. A shell script runs outside Arch's sandbox with your rights, only while Allow Shell Scripts is on and after you trust its file with Touch ID or your login password."))
        }
        Section {
            if registry.hooks.isEmpty {
                Text("No hooks yet.", bundle: .module).foregroundStyle(.secondary)
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
            HStack {
                Spacer()
                Button(localized("Clear Activity")) {
                    registry.clearActivity()
                    shownSessions = []
                }
                .disabled(registry.lastRuns.isEmpty && registry.log.entries.isEmpty)
            }
        } header: {
            Text("Hooks", bundle: .module)
        } footer: {
            formFootnote(localized("Arch keeps \(HookRunLog.keptDays) days of hook runs, without titles, page text, prompts, or replies. A hook that keeps nothing logs no run. A hook that keeps the session keeps its agent's transcript in memory until you choose Delete Session or Clear Activity, or quit Arch. With a model on an API key, the Activity page also keeps what each request sent until Arch quits."))
        }
        .sheet(item: $sheet) { draft in
            ScriptHookSheet(registry: registry, draft: draft, currentTab: currentTab) { sheet = nil }
        }
        .confirmationDialog(localized("Allow this hook’s provider destinations?"), isPresented: Binding(get: { providerReview != nil }, set: { if !$0 { providerReview = nil } }),
                            titleVisibility: .visible, presenting: providerReview) { review in
            Button(localized("Allow")) { registry.approveProviders(review.providers, for: review.hook) }
        } message: { review in
            Text(review.description)
        }
        .confirmationDialog(localized("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { hook in
            Button(localized("Delete"), role: .destructive) { registry.remove(hook.id) }
        } message: { _ in
            Text("Arch deletes the hook and its script.", bundle: .module)
        }
        .confirmationDialog(localized("Delete this run\u{2019}s session?"), isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }),
                            titleVisibility: .visible, presenting: deletingSession) { run in
            Button(localized("Delete Session"), role: .destructive) {
                shownSessions.remove(run)
                runner.deleteKeptRuns(ofHookRuns: [run])
            }
        } message: { _ in
            Text("Arch deletes the agent\u{2019}s transcript of this run. The run stays in the hook\u{2019}s last runs.", bundle: .module)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(localized("OK")) { message = nil }
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
                .accessibilityLabel(hook.name)
                .toggleStyle(.switch)
                .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hook.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                    ForEach(HookSummary.lines(for: hook, places: registry.places, lastRun: registry.lastRuns[hook.id]?.last), id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                    if hook.state == .active {
                        TabNamesWarning(settings: aiSettings, renames: hook.grant.permissions.contains(.tabsRename) || hook.grant.agent?.tools.contains("rename_tab") == true,
                                        kind: hook.trigger.kind)
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
            Text(reason == .scriptChanged && hook.script.isShell ? localized("Its script or its interpreter changed.") : HookSummary.sentence(for: reason)).font(.caption).foregroundStyle(.orange)
            switch reason {
            case .scriptChanged:
                Button(localized("Review")) { edit(hook, reviewing: true) }
            case .unknownProvider:
                Button(localized("Review")) {
                    let providers = registry.providersForReview(of: hook.id)
                    guard !providers.isEmpty else { return registry.resume(hook.id) }
                    let settings = AIService.shared.settings
                    let described = providers.map { item in settings.providers.first { $0.id == item.id }.map(HookSummary.review(of:)) ?? item.id.rawValue }
                    providerReview = ProviderReview(hook: hook.id, providers: providers, description: ([HookSummary.reviewIntro] + described).joined(separator: "\n\n"))
                }
            // Allow Shell Scripts resumes the shell hooks it paused.
            case .user, .needsNewerArch, .shellScriptsOff:
                EmptyView()
            default:
                Button(localized("Resume")) { registry.resume(hook.id) }
            }
        }
    }

    private func menu(for hook: Hook) -> some View {
        let isReadable = hook.state != .paused(.needsNewerArch)
        return Menu {
            Button(localized("Edit…")) { edit(hook, reviewing: false) }
                .disabled(!isReadable)
            Button(localized("Run on Current Tab")) { runOnCurrentTab(hook) }
                .disabled(!isReadable)
            // The user trusts a shell script for its own hook only.
            Button(localized("Duplicate")) { duplicate(hook) }
                .disabled(!isReadable || hook.state == .paused(.scriptChanged) || hook.script.isShell)
            Divider()
            Button(localized("Delete…"), role: .destructive) { deleting = hook }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(localized("Hook Actions"))
        .help(localized("Hook Actions"))
    }

    @ViewBuilder
    private func lastRuns(of hook: Hook) -> some View {
        let runs = (registry.lastRuns[hook.id] ?? []).reversed()
        if runs.isEmpty {
            Text("No runs since Arch started.", bundle: .module).foregroundStyle(.secondary)
        }
        ForEach(Array(runs)) { run in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(run.date.formatted(date: .omitted, time: .standard)) · \(HookSummary.description(of: run))")
                if let message = run.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                // A shell script's standard error, kept in memory only, in the type and scroll view of Show Session.
                if let output = run.errorOutput {
                    ScrollView {
                        Text(output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                keptSession(of: run)
            }
        }
    }

    /// Show Session and Delete Session… for a run with kept agent runs, and their transcript while shown, in the type and scroll view of Activity's Show Content.
    @ViewBuilder
    private func keptSession(of run: HookRunSummary) -> some View {
        let kept = HookSummary.keptRuns(of: run.id, in: runner.keptRuns)
        if !kept.isEmpty {
            let isShown = shownSessions.contains(run.id)
            HStack {
                Button(isShown ? localized("Hide Session") : localized("Show Session")) {
                    if isShown { shownSessions.remove(run.id) } else { shownSessions.insert(run.id) }
                }
                .buttonStyle(.link)
                // Destructive, as the page's other deletions, and asking first, as an agent's Delete Session… does.
                Button(localized("Delete Session\u{2026}"), role: .destructive) { deletingSession = run.id }
                    .buttonStyle(.borderless)
            }
            .font(.subheadline)
            if isShown {
                ScrollView {
                    Text(HookSummary.transcript(of: kept))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
    }

    // MARK: Actions

    private func edit(_ hook: Hook, reviewing: Bool) {
        do {
            sheet = try HookScriptActions.draft(editing: hook, file: registry.scriptFile(of: hook.id), places: registry.places, reviewing: reviewing)
        } catch {
            message = error.localizedDescription
        }
    }

    private func runOnCurrentTab(_ hook: Hook) {
        guard let tab = currentTab() else {
            message = localized("Select a tab in a browser window first.")
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

/// Both features can name the same new tab. Turning off Tab Names keeps its saved route.
struct TabNamesWarning: View {
    @ObservedObject var settings: AISettingsStore
    let renames: Bool
    let kind: BrowserEventKind

    static func applies(renames: Bool, kind: BrowserEventKind, tabNames: AIRoute) -> Bool {
        renames && (kind == .tabOpened || kind == .pageLoaded) && tabNames.isEnabled
    }

    var body: some View {
        let route = settings.route(for: .tabNameHook)
        if Self.applies(renames: renames, kind: kind, tabNames: route) {
            Text("Tab Names also names tabs. Turn on one of them.", bundle: .module).font(.caption)
            Button(localized("Turn Off Tab Names")) {
                var updated = route
                updated.isEnabled = false
                settings.setRoute(updated, for: .tabNameHook)
            }
        }
    }
}

/// What Edit…, Review, and Duplicate make of a hook and its script file. A file changed outside Arch opens only for review, with its notice, and no copy takes it, so bytes that another program wrote run only once the user has read and saved them (hook decision 8).
enum HookScriptActions {
    struct Refusal: LocalizedError {
        let sentence: String
        var errorDescription: String? { sentence }
    }

    /// The sheet's draft for the hook with the file's text, in review when the user asked for it or the file no longer matches its digest. Refused for a file that is missing or not text, which an empty editor would replace unseen. A shell script's bytes go to the trust sheet as they are.
    static func draft(editing hook: Hook, file: HookScriptFile?, places: [HookPersonaPlaces], reviewing: Bool) throws -> ScriptHookDraft {
        guard let file, let script = String(data: file.contents, encoding: .utf8) else { throw Refusal(sentence: localized("Arch cannot read the script of \u{201C}\(hook.name)\u{201D}.")) }
        return ScriptHookDraft(editing: hook, script: script, places: places, reviewing: reviewing || !file.matchesDigest, contents: hook.script.isShell ? file.contents : nil,
                               matchesDigest: file.matchesDigest)
    }

    /// A copy for after the list's last hook, with the original's script, switched on and the user's. Refused for a file that is missing or changed outside Arch, and for an outside program's hook, whose copy would lose the caps of its origin.
    static func copy(of hook: Hook, file: HookScriptFile?) throws -> (hook: Hook, script: Data) {
        let name = "\u{201C}\(hook.name)\u{201D}"
        guard !hook.origin.isOutsideProgram else { throw Refusal(sentence: localized("Hooks that other programs added cannot be duplicated.")) }
        guard !hook.script.isShell else { throw Refusal(sentence: localized("A shell script is trusted for its own hook only. Make a new hook with its file instead.")) }
        guard let file else { throw Refusal(sentence: localized("Arch cannot read the script of \(name).")) }
        guard file.matchesDigest else { throw Refusal(sentence: localized("The script of \(name) changed outside Arch. Review it before you duplicate the hook.")) }
        var copy = hook
        copy.id = UUID()
        copy.name = localized("\(hook.name) Copy")
        copy.state = .active
        copy.origin = .user
        copy.created = Date()
        return (copy, file.contents)
    }
}

// MARK: - Texts

/// The sentences Settings ▸ AI ▸ Hooks shows for hooks, their places, their runs, and the notices about `hooks.json`.
@MainActor
enum HookSummary {
    /// The row's lines under the name: the situation, the scope, and the sites; a shell hook's file; an agent hook's model and record; the last run; and the program that added the hook.
    static func lines(for hook: Hook, places: [HookPersonaPlaces], lastRun: HookRunSummary?) -> [String] {
        var lines = [[situation(of: hook.trigger), scope(of: hook.filter.scope, places: places), sites(of: hook.filter)].joined(separator: " · ")]
        if case .shell(let source, _, _) = hook.script {
            lines.append(localized("Shell script · \((source as NSString).lastPathComponent)"))
        }
        if hook.usesAgent, let agent = hook.agent {
            lines.append([model(of: agent.model), record(of: hook.record)].joined(separator: " · "))
        } else if hook.record == .none {
            lines.append(record(of: hook.record))
        }
        if let lastRun {
            lines.append("\(lastRun.date.formatted(.relative(presentation: .named))) · \(description(of: lastRun))")
        }
        if case .outsideClient(_, let name) = hook.origin {
            lines.append(localized("Added by \(name)"))
        }
        return lines
    }

    static func situation(of trigger: HookTrigger) -> String {
        switch trigger {
        case .tabOpened: return localized("When a new tab opens")
        case .tabClosed(let reasons): return reasons == [.user] ? localized("When you close a tab") : localized("When a tab closes")
        case .pageLoaded(let loads, _):
            switch loads {
            case .firstAfterOpen: return localized("When a new tab loads its first page")
            case .newAddress: return localized("When a tab loads a new address")
            case .every: return localized("When a tab loads a page")
            }
        case .addressChanged(let changes): return changes == .newHost ? localized("When a tab moves to another site") : localized("When a tab's address changes")
        case .titleChanged: return localized("When a tab's title changes")
        case .tabSelected: return localized("When you select a tab")
        case .downloadFinished: return localized("When a download finishes")
        case .spaceSwitched(let personaChangesOnly): return personaChangesOnly ? localized("When you switch to another Persona") : localized("When you switch spaces")
        }
    }

    /// "Everywhere", or each place as `name(of:places:)` names it.
    static func scope(of scope: BrowserEventScope, places: [HookPersonaPlaces]) -> String {
        guard case .places(let chosen) = scope else { return localized("Everywhere") }
        guard !chosen.isEmpty else { return localized("Nowhere") }
        return chosen.map { name(of: $0, places: places) }.joined(separator: ", ")
    }

    /// A place as Persona rule 7 names it (`BrowserSession.displayedPlace(ofPersona:space:among:)`): a space as "Persona / Space" and a whole Persona by its name, while the default Persona is the only one a space by its name alone and the Persona, which then covers every place, as Everywhere.
    static func name(of place: BrowserPlace, places: [HookPersonaPlaces]) -> String {
        let personas = places.map { Persona(id: $0.id, name: $0.name) }
        switch place {
        case .persona(let id):
            guard places.contains(where: { $0.id == id }) else { return localized("Deleted Persona") }
            return BrowserSession.displayedPlace(ofPersona: id, space: nil, among: personas) ?? localized("Everywhere")
        case .space(let id):
            guard let persona = places.first(where: { $0.spaces.contains { $0.id == id } }), let space = persona.spaces.first(where: { $0.id == id }) else { return localized("Deleted Space") }
            return BrowserSession.displayedPlace(ofPersona: persona.id, space: Space(id: space.id, name: space.name, personaID: persona.id), among: personas) ?? space.name
        }
    }

    static func sites(of filter: BrowserEventFilter) -> String {
        if !filter.sites.isEmpty { return localized("Only \(filter.sites.map(\.value).joined(separator: ", "))") }
        if !filter.exceptSites.isEmpty { return localized("All sites except \(filter.exceptSites.map(\.value).joined(separator: ", "))") }
        return localized("All sites")
    }

    static func model(of choice: AIRouteChoice) -> String {
        switch choice {
        case .tier(let tier):
            let model = AIService.shared.settings.route(for: .tier(tier)).models.first?.model
            return model.map { "\(tier.title) · \($0.isEmpty ? localized("default model") : $0)" } ?? localized("\(tier.title) · no model")
        case .models(let models):
            return models.first.map { $0.model.isEmpty ? localized("Default model") : $0.model } ?? localized("No model")
        }
    }

    static func record(of record: AgentRunRecord) -> String {
        switch record {
        case .session: return localized("Keeps the session")
        case .activity: return localized("Keeps activity only")
        case .none: return localized("Keeps nothing")
        }
    }

    /// "Completed · renamed a tab", "Failed: …", "Skipped: rate limit", and so on.
    static func description(of run: HookRunSummary) -> String {
        let prefix = run.test ? localized("Test · ") : ""
        switch run.outcome {
        case .completed:
            let renames = run.actions?["renameTab"] ?? 0
            return prefix + (renames == 0 ? localized("Completed") : renames == 1 ? localized("Renamed a tab") : localized("Renamed \(renames) tabs"))
        case .failed: return prefix + localized("Failed") + (run.code.map { " (\($0))" } ?? "")
        case .timedOut: return prefix + localized("Ran out of time")
        case .cancelled: return prefix + localized("Stopped")
        case .skipped:
            switch run.reason {
            case .loop?: return localized("Skipped: its own change or a chain of hooks")
            case .rateLimit?: return localized("Skipped: too many runs in a minute")
            case .dailyLimit?: return localized("Skipped: today's runs are used up")
            case .budget?: return localized("Skipped: an AI limit was reached")
            case .dropped?: return localized("Skipped: too many runs waited")
            case nil: return localized("Skipped")
            }
        }
    }

    /// The agent runs a hook run kept, oldest first, from the runner's newest-first list.
    static func keptRuns(of run: UUID, in kept: [AgentRunner.KeptRun]) -> [AgentRunner.KeptRun] {
        kept.filter { $0.hookRun == run }.reversed()
    }

    /// What Show Session shows: each kept run's messages one after another, under "Arch" for the message Arch wrote and the tools' results, or "Agent" for the agent's replies and tool calls. A message's lines are indented under its label and page and selection text is quoted with ">", so that no page text reads as a label or as Arch's own line.
    static func transcript(of runs: [AgentRunner.KeptRun]) -> String {
        runs.map { transcript(of: $0.messages) }.joined(separator: "\n\n")
    }

    static func transcript(of messages: [AIMessage]) -> String {
        var toolNames: [String: String] = [:]
        func lines(of parts: [AIPart]) -> [String] {
            parts.map { part in
                switch part {
                case .text(let text): return text
                case .page(let page): return pageLine(title: page.title, url: page.url, text: page.text)
                case .selection(let selection): return localized("Selection from ") + pageLine(title: selection.pageTitle, url: selection.pageURL, text: selection.text)
                case .file(let file): return localized("File \(file.name)")
                case .download(let download): return localized("Download \(download.filename)")
                case .toolCall(let call):
                    toolNames[call.id] = call.name
                    return localized("Called \(call.name) \(String(decoding: call.arguments, as: UTF8.self))")
                case .toolResult(let result):
                    return localized("Result of \(toolNames[result.callID] ?? localized("a tool")): ") + lines(of: result.parts).joined(separator: "\n")
                }
            }
        }
        return messages.map { message in
            let body = lines(of: message.parts).flatMap(splitLines).map { $0.isEmpty ? "" : "  " + $0 }
            return ([message.role == .assistant ? localized("Agent") : "Arch"] + body).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// A page's title and address on one line, then each line of its text quoted, when the part carries any.
    private static func pageLine(title: String, url: URL, text: String) -> String {
        let title = splitLines(title).joined(separator: " ")
        let line = title.isEmpty ? url.absoluteString : "\(title) \u{00B7} \(url.absoluteString)"
        guard !text.isEmpty else { return line }
        return ([line] + splitLines(text).map { $0.isEmpty ? ">" : "> " + $0 }).joined(separator: "\n")
    }

    /// The text's lines, split at every character that starts a new line.
    private static func splitLines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// What Run on Current Tab reports.
    static func description(of result: HookRunResult, hookName: String) -> String {
        let name = "\u{201C}\(hookName)\u{201D}"
        switch result {
        case .notRun(let sentence): return localized("\(name) did not run. \(sentence)")
        case .finished(let outcome):
            switch outcome {
            case .completed(let actions, _):
                let renames = actions.filter { $0.kind == "renameTab" }.count
                return renames == 0 ? localized("\(name) ran and changed nothing.") : renames == 1 ? localized("\(name) ran and renamed a tab.") : localized("\(name) ran and renamed \(renames) tabs.")
            case .failed(_, let message): return localized("\(name) failed: \(message)")
            case .timedOut: return localized("\(name) ran out of time.")
            case .cancelled: return localized("\(name) was stopped.")
            }
        }
    }

    /// What the provider review says first: the settings came from outside Settings ▸ AI ▸ Providers.
    static var reviewIntro: String { localized("Arch did not see these provider settings set up in Settings ▸ AI ▸ Providers, so another program may have changed them. The hook sends nothing until you allow them. Allow only settings you recognize.") }

    /// A provider as its review shows it, from its settings now: an HTTP provider's base address, or a command-line tool's executable, arguments, and environment, which can send its requests elsewhere, with the values of variables whose names suggest a secret hidden. The digest that `hooks.json` records changes with any of them, so it would show nothing to compare.
    static func review(of provider: AIProviderConfiguration) -> String {
        switch provider.kind {
        case .http(let http):
            return "\(provider.name) \u{2014} \(http.baseURL.absoluteString)"
        case .commandLine(let tool):
            var lines = ["\(provider.name) \u{2014} " + ([tool.executable.path] + tool.arguments).joined(separator: " ")]
            for (name, value) in tool.environment.sorted(by: { $0.key < $1.key }) {
                let secret = ["KEY", "TOKEN", "SECRET"].contains { name.uppercased().contains($0) }
                lines.append("\(name)=\(secret ? "\u{2022}\u{2022}\u{2022}\u{2022}" : value)")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func sentence(for reason: HookPauseReason) -> String {
        switch reason {
        case .user: return localized("Paused.")
        case .failures: return localized("Paused after \(HookRegistry.failuresBeforePause) failed runs in a row.")
        case .providerErrors: return localized("Paused after repeated errors from its model's provider.")
        case .ranTooOften: return localized("This hook ran too often, so Arch paused it.")
        case .stopAllAgents: return localized("Paused by Stop All Agents.")
        case .placeDeleted: return localized("Paused: the Personas and spaces it ran in were deleted.")
        case .scriptChanged: return localized("Its script changed outside Arch.")
        case .shellScriptsOff: return localized("Shell scripts are off.")
        case .needsNewerArch: return localized("This hook needs a newer version of Arch.")
        case .grantEnded: return localized("The program's access ended.")
        case .unknownProvider: return localized("Its run would reach a provider that was not set up in Arch.")
        }
    }

    static func sentence(for notice: HookStoreNotice) -> String {
        switch notice {
        case .setAside: return localized("hooks.json could not be opened, so Arch renamed it hooks.json.unreadable and started with no hooks.")
        case .keyUnavailable(let reason): return localized("The Keychain did not give the key of hooks.json, so no hook runs: \(reason)")
        case .newerVersion(let version): return localized("hooks.json is from a newer version of Arch, version \(version). Arch lists the hooks it cannot read without running them.")
        case .notSaved(let reason): return localized("Arch could not save the last change to the hooks: \(reason)")
        }
    }
}
