// New Script Hook… and Edit… in Settings ▸ AI ▸ Hooks edit a hook's name, situation, places, sites, engines, tabs, access, and script (`docs/hooks.md`).
// Save checks the script before the registry stores it with its digest. Review opens a script changed outside Arch; saving allows it to run again.
// Edits made in Arch need no Touch ID except for shell scripts. When Allow Shell Scripts is on, Shell Script shows the file's text and resolved interpreter path.
// It also shows what the script receives and what its commands may access. Arch copies it after Touch ID or the login password.
// Update from File, a changed interpreter, and Let Agent Runs Read Pages require that approval again.
import AppKit
import Agent
import AI
import ARCHEngine
import Events
import Hooks
import SwiftUI

/// A shell hook's file as the trust sheet shows it.
struct ShellScriptChoice: Equatable {
    /// Where the user keeps the file, which Update from File reads again.
    var source: String
    /// The bytes the user reads and trusts, which Arch copies.
    var contents: Data
    /// The interpreter as the first line resolves now; nil while the sheet resolves it or when it does not resolve.
    var resolution: HookInterpreterResolution?
    var problem: String?
    /// The lines that differ from the copy the user trusted last, by index, and how many of its lines are gone, after Update from File.
    var changedLines: Set<Int> = []
    var removedLines = 0

    var text: String { String(decoding: contents, as: UTF8.self) }
}

/// What the user last trusted of a shell hook, so that a save that changes none of it asks for no Touch ID.
struct ShellTrust: Equatable {
    /// The file's path, so that another file with the same bytes is trusted as a new file, which Update from File then reads.
    var source: String
    var contents: Data
    var interpreter: HookInterpreter
    var readsPages: Bool
}

/// What the sheet edits: a new hook, or a hook as stored, with its script's text.
struct ScriptHookDraft: Identifiable {
    enum SiteChoice: Hashable {
        case all, only, except
    }

    enum EngineChoice: Hashable {
        case both, webKit, chromium
    }

    let id: UUID
    /// The hook as stored, whose other settings a save keeps; nil for a new hook.
    let stored: Hook?
    /// The script changed outside Arch, and saving it resumes the hook.
    let isReview: Bool
    let places: [HookPersonaPlaces]
    var name: String
    var kind: BrowserEventKind
    var loads: HookPageLoads = .firstAfterOpen
    var includesRestoredTabs = false
    var addressChanges: HookAddressChanges = .newHost
    var titleSources: Set<BrowserTitleSource> = [.page]
    var closeReasons: Set<BrowserTabCloseReason> = []
    var personaChangesOnly = false
    var isEverywhere = true
    /// The stored scope that Where shows as Everywhere because it names the only Persona, which a save keeps, so that the hook does not reach a Persona added later.
    var scopeShownAsEverywhere: BrowserEventScope?
    var chosenPlaces: Set<BrowserPlace> = []
    var siteChoice = SiteChoice.all
    var siteList = ""
    var engine = EngineChoice.both
    /// Empty stands for every kind but agent tabs.
    var tabKinds: Set<BrowserTabKind> = []
    var readsTabs = false
    var renamesTabs = false
    var enablesAgent = false
    var agentModel: AIRouteChoice?
    var agentPrompt = ""
    var agentRenamesTabs = false
    var readsPageText = false
    var readsPageOutline = false
    var guided = false
    var generated = false
    var origin: HookOrigin = .user
    var agentRecord: AgentRunRecord = .none
    var seconds = 30
    var rounds = 2
    var toolCalls = 5
    var dailyLimit = 200
    var delay = 1.5
    var script: String
    /// Shell Script, for a new hook while Allow Shell Scripts is on, or a shell hook as stored.
    var isShell = false
    var shell: ShellScriptChoice?
    /// Let Agent Runs Read Pages on the trust sheet, off by default.
    var letsAgentReadPages = false
    var trusted: ShellTrust?
    /// Arch's copy as the user trusted it last, which Update from File and Choose Another File… mark changed lines against; nil for a new hook, and for a copy that changed outside Arch, which is no longer the trusted one.
    var trustedCopy: Data?

    init(new places: [HookPersonaPlaces], guided: Bool = false) {
        id = UUID()
        stored = nil
        isReview = false
        self.places = places
        name = localized("New Hook")
        kind = .pageLoaded
        script = Self.template(for: .pageLoaded)
        renamesTabs = !guided
        self.guided = guided
        generated = guided
        enablesAgent = guided
        if guided { name = localized("New Agent Hook") }
    }

    /// `contents` is a shell script's file, whose bytes the trust sheet shows and copies as they are, and `matchesDigest` whether it is still the copy the user trusted.
    init(editing hook: Hook, script: String, places: [HookPersonaPlaces], reviewing: Bool, isNew: Bool = false, contents: Data? = nil, matchesDigest: Bool = true) {
        id = hook.id
        stored = isNew ? nil : hook
        isReview = reviewing
        self.places = places
        name = hook.name
        kind = hook.trigger.kind
        self.script = script
        origin = hook.origin
        // The guided editor writes Arch's JavaScript, so a shell hook stays in the hand-written one.
        guided = hook.agent != nil && !hook.origin.isOutsideProgram && !hook.script.isShell
        if case .javaScript(_, let isGenerated) = hook.script { generated = isGenerated && !reviewing }
        agentRecord = hook.agent?.record ?? hook.record
        if let limits = hook.agent?.limits {
            seconds = Int(limits.timeout.components.seconds)
            rounds = limits.rounds
            toolCalls = limits.toolCalls
        }
        dailyLimit = hook.timing.runsPerDay
        let components = hook.timing.delay.components
        delay = Double(components.seconds) + Double(components.attoseconds) / 1e18
        switch hook.trigger {
        case .tabClosed(let reasons): closeReasons = reasons
        case .pageLoaded(let loads, let includesRestoredTabs):
            self.loads = loads
            self.includesRestoredTabs = includesRestoredTabs
        case .addressChanged(let changes): addressChanges = changes
        case .titleChanged(let sources): titleSources = sources
        case .spaceSwitched(let personaChangesOnly): self.personaChangesOnly = personaChangesOnly
        case .tabOpened, .tabSelected, .downloadFinished: break
        }
        if case .places(let chosen) = hook.filter.scope {
            isEverywhere = false
            chosenPlaces = Set(chosen)
            // With one Persona, Where names no Persona (Persona rule 7), and the Persona's place covers every place, as Everywhere does.
            if places.count == 1, let only = places.first, chosenPlaces.contains(.persona(only.id)) {
                isEverywhere = true
                scopeShownAsEverywhere = hook.filter.scope
                chosenPlaces = []
            }
        }
        if !hook.filter.sites.isEmpty {
            siteChoice = .only
            siteList = hook.filter.sites.map(\.value).joined(separator: "\n")
        } else if !hook.filter.exceptSites.isEmpty {
            siteChoice = .except
            siteList = hook.filter.exceptSites.map(\.value).joined(separator: "\n")
        }
        engine = hook.filter.engines == [.webKit] ? .webKit : hook.filter.engines == [.chromium] ? .chromium : .both
        tabKinds = hook.filter.tabKinds
        enablesAgent = hook.usesAgent
        agentModel = hook.agent?.model
        agentPrompt = hook.agent?.prompt ?? ""
        agentRenamesTabs = hook.grant.agent?.tools.contains("rename_tab") == true
        readsPageText = hook.grant.agent?.tools.contains("read_text") == true
        readsPageOutline = hook.grant.agent?.tools.contains("snapshot") == true
        readsTabs = hook.grant.permissions.contains(.tabs)
        renamesTabs = hook.grant.permissions.contains(.tabsRename)
        if case .shell(let source, _, let interpreter) = hook.script {
            isShell = true
            let bytes = contents ?? Data(script.utf8)
            shell = ShellScriptChoice(source: source, contents: bytes)
            letsAgentReadPages = hook.grant.agent?.tabAccess == .page
            if matchesDigest { trustedCopy = bytes }
            // A script under review is trusted again in full.
            if !reviewing { trusted = ShellTrust(source: source, contents: bytes, interpreter: interpreter, readsPages: letsAgentReadPages) }
        }
    }

    /// Whether saving needs Touch ID: a new shell script, another file, other bytes or another interpreter than the user trusted, or agent runs that now read pages.
    var needsTrust: Bool {
        guard isShell, let shell else { return false }
        guard let trusted, let interpreter = shell.resolution?.interpreter else { return true }
        return trusted.source != shell.source || trusted.contents != shell.contents || trusted.interpreter != interpreter
            || (enablesAgent && letsAgentReadPages && !trusted.readsPages)
    }

    var scriptText: String { guided && generated ? AgentHookTemplate.script(for: kind) : script }

    mutating func editGeneratedScript() {
        script = scriptText
        generated = false
    }

    /// Arch's script runs the agent, so restoring it turns agent runs back on.
    mutating func restoreGeneratedScript() {
        generated = true
        enablesAgent = true
    }

    func makeHook() throws -> (hook: Hook, script: Data) {
        func invalid(_ reason: String) -> HookRegistryError { .invalidAgentOptions(reason) }
        let bytes: Data
        if isShell {
            guard let shell else { throw invalid(localized("Choose the script's file.")) }
            if let problem = shell.problem { throw invalid(problem) }
            guard shell.resolution != nil else { throw invalid(localized("Arch is still looking for the script's interpreter.")) }
            bytes = shell.contents
        } else {
            bytes = Data(scriptText.utf8)
            if let problem = HookScriptRunner.problem(in: bytes) { throw invalid(problem) }
        }
        if let problem = sitePatterns().problem { throw invalid(problem) }
        guard isEverywhere || !chosenPlaces.isEmpty else { throw invalid(localized("Choose where the hook runs.")) }
        guard kind != .titleChanged || !titleSources.isEmpty else { throw invalid(localized("Choose which title changes start the hook.")) }
        guard tabKinds.isEmpty || !tabKinds.isDisjoint(with: Self.offeredTabKinds) else { throw invalid(localized("Choose its tab kinds.")) }
        var hook = stored ?? Hook(id: id, name: name, trigger: trigger, origin: origin)
        if isShell, let shell, let interpreter = shell.resolution?.interpreter {
            hook.script = .shell(source: shell.source, digest: hook.script.digest, interpreter: interpreter)
        }
        hook.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hook.name.isEmpty else { throw invalid(localized("Name the hook.")) }
        if hook.trigger.kind != kind { hook.timing = HookTiming(for: trigger) }
        hook.trigger = trigger
        hook.filter = filter
        hook.grant.permissions = hook.grant.permissions.intersection([.agent])
        // An outside program's hook never reads other tabs' titles and addresses (`docs/hooks.md`, Hooks from outside programs).
        if readsTabs, !origin.isOutsideProgram { hook.grant.permissions.insert(.tabs) }
        if renamesTabs { hook.grant.permissions.insert(.tabsRename) }
        if !hook.origin.isOutsideProgram {
            // A shell hook's agent runs read pages only with Let Agent Runs Read Pages.
            var choices = self
            if isShell {
                choices.readsPageText = letsAgentReadPages
                choices.readsPageOutline = letsAgentReadPages
            }
            try choices.configureAgent(in: &hook)
        }
        if isShell, let grant = hook.grant.agent {
            let limited = HookShellScript.agentGrant(grant, readsPages: letsAgentReadPages)
            hook.grant.agent = limited
            hook.agent?.tools.removeAll { !limited.tools.contains($0) }
            if limited.tabAccess == .title { hook.agent?.tabAccess = .title }
        }
        // A hand-written script hook that opens guided can still turn its agent runs off.
        if guided, enablesAgent, let model = agentModel {
            let tools = (agentRenamesTabs ? ["rename_tab"] : []) + (readsPageText ? ["read_text"] : []) + (readsPageOutline ? ["snapshot"] : [])
            let options = AgentRunOptions(prompt: agentPrompt, tabAccess: readsPageText || readsPageOutline ? .page : .title, model: model, record: agentRecord,
                                          tools: tools, limits: AgentRunLimits(timeout: .seconds(seconds), rounds: rounds, toolCalls: toolCalls))
            AgentHookTemplate.configure(&hook, options: options, dailyLimit: dailyLimit, delay: .seconds(delay), generated: generated)
            if let reason = hook.grant.agent?.refusal(for: options) { throw invalid(reason) }
        }
        return (hook, bytes)
    }

    /// Keep a stored grant's ceilings. A newly authorized script can use titles and suggest names only.
    func configureAgent(in hook: inout Hook) throws {
        guard enablesAgent else {
            hook.grant.permissions.remove(.agent)
            hook.grant.agent = nil
            hook.agent = nil
            return
        }
        guard let agentModel else { throw HookRegistryError.invalidAgentOptions(localized("Choose the model for this hook.")) }
        var grant = hook.grant.agent ?? AgentRunGrant(tools: [], maximumRecord: .none)
        // The agent runs' daily count agrees with the hook's, so that the runner does not refuse runs the registry starts.
        grant.runsPerDay = min(max(hook.timing.runsPerDay, 1), 2_000)
        let previouslyGranted = grant.tools
        if agentRenamesTabs { grant.tools.insert("rename_tab") } else { grant.tools.remove("rename_tab") }
        if readsPageText { grant.tools.insert("read_text") } else { grant.tools.remove("read_text") }
        if readsPageOutline { grant.tools.insert("snapshot") } else { grant.tools.remove("snapshot") }
        grant.tabAccess = grant.tools.contains("read_text") || grant.tools.contains("snapshot") ? .page : .title
        var options = hook.agent ?? AgentRunOptions(prompt: agentPrompt, model: agentModel, tools: [])
        options.tools = Set(options.tools).intersection(grant.tools).union(grant.tools.subtracting(previouslyGranted)).sorted()
        options.tabAccess = grant.tabAccess
        options.model = agentModel
        options.prompt = agentPrompt
        hook.grant.permissions.insert(.agent)
        hook.agent = options
        hook.grant.agent = grant
    }

    var trigger: HookTrigger {
        switch kind {
        case .tabOpened: return .tabOpened
        case .tabClosed: return .tabClosed(reasons: closeReasons)
        case .pageLoaded: return .pageLoaded(loads: loads, includesRestoredTabs: includesRestoredTabs)
        case .addressChanged: return .addressChanged(changes: addressChanges)
        case .titleChanged: return .titleChanged(sources: titleSources)
        case .tabSelected: return .tabSelected
        case .downloadFinished: return .downloadFinished
        case .spaceSwitched: return .spaceSwitched(personaChangesOnly: personaChangesOnly)
        }
    }

    /// The sites as patterns, one per line or separated by commas, and a sentence about the first entry that is not a site.
    func sitePatterns() -> (patterns: [AISitePattern], problem: String?) {
        var patterns: [AISitePattern] = []
        for entry in siteList.split(whereSeparator: { $0.isNewline || $0 == "," }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !entry.isEmpty {
            guard let pattern = AISitePattern(parsing: entry) else { return (patterns, localized("\u{201C}\(entry)\u{201D} is not a site.")) }
            patterns.append(pattern)
        }
        return (patterns, nil)
    }

    var filter: BrowserEventFilter {
        var filter = stored?.filter ?? BrowserEventFilter()
        filter.scope = isEverywhere ? scopeShownAsEverywhere ?? .everywhere : .places(Self.ordered(chosenPlaces, in: places))
        let patterns = sitePatterns().patterns
        filter.sites = siteChoice == .only ? patterns : []
        filter.exceptSites = siteChoice == .except ? patterns : []
        switch engine {
        case .both: filter.engines = []
        case .webKit: filter.engines = [.webKit]
        case .chromium: filter.engines = [.chromium]
        }
        filter.tabKinds = tabKinds
        return filter
    }

    /// The close reasons When offers: every reason but closes by hooks, which cannot close tabs yet.
    static let offeredCloseReasons = BrowserTabCloseReason.allCases.filter { $0 != .hook }

    /// A close reason in words, as `TabCloseReason` describes the closes it stands for.
    static func label(of reason: BrowserTabCloseReason) -> String {
        switch reason {
        case .user: return localized("You close it")
        case .page: return localized("The page closes itself")
        case .crash: return localized("Its page\u{2019}s process quits")
        case .archive: return localized("Arch archives it")
        case .download: return localized("It only opened a download")
        case .webExtension: return localized("A web extension closes it")
        case .plugin: return localized("A plugin closes it")
        case .hook: return localized("A hook closes it")
        case .agent: return localized("An agent closes it")
        case .spaceDeleted: return localized("Its Persona is deleted")
        case .sync: return localized("Sync removes it")
        }
    }

    /// The tab kinds Where offers, which all on stand for an empty set.
    static let offeredTabKinds: Set<BrowserTabKind> = [.open, .pinned, .favorite, .smallWindow]

    /// Whether the hook runs for tabs of the kind: every kind when the set is empty.
    func includes(_ kind: BrowserTabKind) -> Bool {
        tabKinds.isEmpty || tabKinds.contains(kind)
    }

    /// Whether Where lets the user turn the kind off: not the last kind left on, since no kind at all would read as every kind.
    func mayExclude(_ kind: BrowserTabKind) -> Bool {
        let included = tabKinds.isEmpty ? Self.offeredTabKinds : tabKinds.intersection(Self.offeredTabKinds)
        return included != [kind]
    }

    /// Turns the kind on or off; all four on become the empty set, and the last kind left on stays on.
    mutating func setIncludes(_ kind: BrowserTabKind, _ isOn: Bool) {
        guard isOn || mayExclude(kind) else { return }
        var kinds = tabKinds.isEmpty ? Self.offeredTabKinds : tabKinds
        if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
        tabKinds = kinds == Self.offeredTabKinds ? [] : kinds
    }

    /// The chosen places in the session's order.
    static func ordered(_ chosen: Set<BrowserPlace>, in places: [HookPersonaPlaces]) -> [BrowserPlace] {
        places.flatMap { persona in [BrowserPlace.persona(persona.id)] + persona.spaces.map { BrowserPlace.space($0.id) } }.filter(chosen.contains)
    }

    /// The script a new hook starts with, for the situation's kind.
    static func template(for kind: BrowserEventKind) -> String {
        let action: String
        switch kind {
        case .pageLoaded, .addressChanged, .titleChanged, .tabOpened, .tabSelected:
            action = """
              // For example, name the tab after its site, which needs Rename Tabs and Read Tab Titles and Addresses:
              // const tab = await arch.tabs.get(event.tab.id);
              // if (tab?.url) await arch.tabs.rename(tab.id, new URL(tab.url).hostname);
            """
        default:
            action = """
              // arch.tabs.list() gives the tabs this hook reaches.
            """
        }
        return """
        // Arch runs this script in its sandbox when the hook's situation happens, with the event as `event`.
        arch.events.on("\(kind.rawValue)", async (event) => {
        \(action)
        });

        """
    }
}

struct ScriptHookSheet: View {
    @ObservedObject var registry: HookRegistry
    @ObservedObject private var aiSettings = AIService.shared.settings
    @State var draft: ScriptHookDraft
    var currentTab: () -> UUID? = { nil }
    let dismiss: () -> Void
    @State private var showsScript = false
    @State private var appliesTest = false
    @State private var testing: Task<Void, Never>?
    @State private var testResult: String?
    @State private var problem: String?
    @State private var resolving: Task<Void, Never>?
    /// Asks for Touch ID or the login password, then saves; a sheet that closes meanwhile saves nothing.
    @State private var trusting: Task<Void, Never>?

    private var isTrusting: Bool { trusting != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if draft.isReview {
                    Section {
                        Text(draft.isShell ? localized("Its script or its interpreter changed. Read both below; trusting them again lets the hook run.")
                                           : localized("Its script changed outside Arch. Read the script below; saving it lets the hook run it again.")).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField(localized("Name"), text: $draft.name)
                    if draft.guided { TabNamesWarning(settings: aiSettings, renames: draft.agentRenamesTabs, kind: draft.kind) }
                }
                whenSection
                whereSection
                if !draft.guided || !draft.generated {
                    Section(localized("Script permissions")) {
                        if !draft.origin.isOutsideProgram { Toggle(localized("Read Tab Titles and Addresses"), isOn: $draft.readsTabs) }
                        Toggle(localized("Rename Tabs"), isOn: $draft.renamesTabs)
                    }
                }
                if draft.stored?.origin.isOutsideProgram != true { agentSettings }
                // Bytes that another program wrote run only once the user has read and saved them (hook decision 8).
                if draft.guided && draft.enablesAgent && !draft.isReview { testSection }
                scriptSection
            }
            .formStyle(.grouped)
            HStack {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
                // While Touch ID is asked for, the answer decides; Cancel would leave a save behind.
                Button(localized("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isTrusting)
                Button(saveTitle) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(testing != nil || isTrusting || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || routeProblem != nil
                              || (draft.isShell && draft.shell?.resolution == nil))
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear { if draft.isShell, draft.shell?.resolution == nil { resolveInterpreter() } }
        .onDisappear {
            testing?.cancel()
            resolving?.cancel()
            trusting?.cancel()
        }
        .onChange(of: draft.kind) { oldKind, newKind in
            // An untouched template follows the situation.
            if draft.script == ScriptHookDraft.template(for: oldKind) { draft.script = ScriptHookDraft.template(for: newKind) }
        }
        .onChange(of: draft.isShell) { _, isShell in
            // A shell script starts no agent runs yet, so a new shell hook gets no agent grant.
            if isShell { draft.enablesAgent = false }
        }
    }

    @ViewBuilder private var agentSettings: some View {
        Section(localized("Agent")) {
            // A shell script starts its agent runs with `arch-cli agent run`, under the hook's grant and run tabs.
            if !draft.guided || !draft.generated {
                Toggle(localized("Allow Agent Runs"), isOn: $draft.enablesAgent)
            }
            if draft.enablesAgent {
                TextField(localized("Instructions"), text: $draft.agentPrompt, prompt: Text("Give the tab a short name in its own language.", bundle: .module), axis: .vertical)
                if draft.isShell {
                    // The trust sheet's Let Agent Runs Read Pages decides a shell hook's page reads.
                    Text(draft.letsAgentReadPages ? localized("The model may read page text on the allowed tabs. Sites excluded from AI are skipped.")
                                                  : localized("The model receives titles and reduced addresses on the allowed tabs.")).font(.caption)
                } else {
                    Toggle(draft.kind == .tabClosed ? localized("Read Text of the Tabs Left") : localized("Read Page Text"), isOn: $draft.readsPageText)
                    Toggle(draft.kind == .tabClosed ? localized("Read Outlines of the Tabs Left") : localized("Read Page Outline"), isOn: $draft.readsPageOutline)
                    if draft.readsPageOutline { Text("Outlines include headings, labels, and links, not the page\u{2019}s text. Form values are hidden.", bundle: .module).font(.caption) }
                    if draft.readsPageText {
                        Text("The model may read page text on the allowed tabs. Sites excluded from AI are skipped.", bundle: .module).font(.caption)
                    } else if draft.readsPageOutline {
                        Text("Sites excluded from AI are skipped.", bundle: .module).font(.caption)
                    } else {
                        Text("The model receives titles and reduced addresses on the allowed tabs.", bundle: .module).font(.caption)
                    }
                }
                if draft.kind == .tabClosed { Text("The closed tab provides its last title and address. Actions apply to tabs left in its space.", bundle: .module).font(.caption) }
            }
        }
        if draft.enablesAgent {
            Section(localized("Model")) {
                Picker(localized("Use"), selection: $draft.agentModel) {
                    Text("Choose a model", bundle: .module).tag(nil as AIRouteChoice?)
                    ForEach(agentRoutes, id: \.self) { route in Text(agentRouteName(route)).tag(Optional(route)) }
                }
                if let routeProblem { Text(routeProblem).font(.caption).foregroundStyle(.secondary) }
                if let route = draft.agentModel {
                    let refs = models(on: route)
                    if case .tier(let tier) = route, refs.isEmpty {
                        Menu(localized("Choose a Model for the \(tier.title) Tier")) {
                            ForEach(connectedModels, id: \.self) { ref in Button(aiSettings.title(of: ref)) { aiSettings.setRoute(AIRoute(isEnabled: true, models: [ref]), for: .tier(tier)) } }
                        }
                    }
                    ForEach(refs, id: \.self) { model in
                        if let provider = aiSettings.providers.first(where: { $0.id == model.provider }) {
                            let destination = provider.hookDestination
                            Text("\(aiSettings.title(of: model)) · \(destination)").font(.caption).textSelection(.enabled)
                            if case .commandLine = provider.kind { Text("Each run starts the signed-in command-line tool and can take a few seconds.", bundle: .module).font(.caption) }
                        }
                    }
                }
            }
            Section(localized("Allowed actions")) {
                Toggle(draft.kind == .tabClosed ? localized("Rename the Tabs Left") : localized("Rename the Tab"), isOn: $draft.agentRenamesTabs)
            }
            if draft.guided {
                Section(localized("Record")) {
                    Picker(localized("Keep"), selection: $draft.agentRecord) {
                        Text("Nothing", bundle: .module).tag(AgentRunRecord.none)
                        Text("Activity Only", bundle: .module).tag(AgentRunRecord.activity)
                        Text("The Session", bundle: .module).tag(AgentRunRecord.session)
                    }
                    Text(recordDetail).font(.caption)
                }
                Section(localized("Limits")) {
                    numberRow(localized("Time limit"), value: $draft.seconds, in: 5...600, unit: localized("seconds"))
                    numberRow(localized("Model rounds"), value: $draft.rounds, in: 1...20, unit: nil)
                    numberRow(localized("Tool calls"), value: $draft.toolCalls, in: 1...50, unit: nil)
                    numberRow(localized("Runs per day"), value: $draft.dailyLimit, in: 1...2_000, unit: nil)
                    Stepper(localized("Wait before running · \(draft.delay.formatted()) seconds"), value: $draft.delay, in: 0...60, step: 0.5)
                }
            }
        }
    }

    /// A number the user can type or step, since some ranges are too wide to step through; Save refuses a typed value outside the range.
    private func numberRow(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, unit: String?) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                if let unit { Text(unit).foregroundStyle(.secondary) }
                Stepper(title, value: value, in: range)
                    .labelsHidden()
                    .accessibilityLabel(title)
            }
        }
    }

    private var recordDetail: String {
        switch draft.agentRecord {
        case .none: return localized("Keep usage totals only.")
        case .activity: return localized("Keep activity without page content or replies.")
        case .session: return localized("Keep the transcript in memory until quit.")
        }
    }

    private var scriptSection: some View {
        Section(localized("Script")) {
            // Shell scripts are offered for new hand-written hooks while Allow Shell Scripts is on.
            if draft.stored == nil, !draft.guided, registry.allowsShellScripts {
                Picker(localized("Language"), selection: $draft.isShell) {
                    Text("JavaScript", bundle: .module).tag(false)
                    Text("Shell Script", bundle: .module).tag(true)
                }
                .pickerStyle(.segmented)
            }
            if draft.isShell {
                shellScript
            } else {
                javaScript
            }
        }
    }

    @ViewBuilder private var javaScript: some View {
        if draft.guided {
            if draft.generated {
                Toggle(localized("Show Script"), isOn: $showsScript)
                if showsScript {
                    Text(draft.scriptText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(localized("Edit Script")) { draft.editGeneratedScript() }
                }
            } else {
                Button(localized("Restore Arch’s Script")) { draft.restoreGeneratedScript(); showsScript = true }
            }
        }
        if !draft.guided || !draft.generated {
            TextEditor(text: $draft.script).font(.system(.body, design: .monospaced)).frame(minHeight: 140)
        }
    }

    /// The trust sheet's part: the file, its interpreter, what the script receives and what its commands get, Let Agent Runs Read Pages, and the file's full text with the lines Update from File changed marked.
    @ViewBuilder private var shellScript: some View {
        if let shell = draft.shell {
            LabeledContent(localized("File")) {
                Text(shell.source).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
        }
        HStack {
            Button(draft.shell == nil ? localized("Choose File\u{2026}") : localized("Choose Another File\u{2026}")) { chooseShellFile() }
            if draft.stored != nil, let source = draft.shell?.source {
                Button(localized("Update from File")) { loadShellFile(at: URL(fileURLWithPath: source)) }
            }
        }
        if let shell = draft.shell {
            if let problem = shell.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if let resolution = shell.resolution {
                LabeledContent(localized("Interpreter")) {
                    Text(resolution.interpreter.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                if resolution.named != resolution.interpreter.path { Text("Found as \(resolution.named).", bundle: .module).font(.caption) }
                ForEach(resolution.writableFolders, id: \.self) { folder in
                    Text("You can change the files in \(folder), which holds this interpreter. If it changes, Arch pauses the hook until you trust it again.", bundle: .module).font(.caption)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Text(HookShellScript.inputSentence).font(.caption)
            Text(HookShellScript.pathSentence).font(.caption)
            if draft.enablesAgent {
                Toggle(localized("Let Agent Runs Read Pages"), isOn: $draft.letsAgentReadPages)
                Text(HookShellScript.readsPagesSentence).font(.caption)
            }
            if !shell.changedLines.isEmpty || shell.removedLines > 0 {
                Text(changeSummary(shell)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(HookShellScript.lines(of: shell.text).enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(shell.changedLines.contains(index) ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(minHeight: 140, maxHeight: 260)
        } else {
            Text(HookShellScript.pathSentence).font(.caption)
        }
    }

    private func changeSummary(_ shell: ShellScriptChoice) -> String {
        let changed = shell.changedLines.count == 1 ? localized("1 line is new or changed") : localized("\(shell.changedLines.count) lines are new or changed")
        guard shell.removedLines > 0 else { return localized("\(changed), marked below.") }
        return shell.removedLines == 1 ? localized("\(changed), marked below, and 1 line is gone.") : localized("\(changed), marked below, and \(shell.removedLines) lines are gone.")
    }

    /// An open panel for the script's file, over the settings window.
    private func chooseShellFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = localized("Choose the shell script this hook runs. Arch shows it before it trusts it.")
        panel.prompt = localized("Review")
        if let source = draft.shell?.source { panel.directoryURL = URL(fileURLWithPath: source).deletingLastPathComponent() }
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { loadShellFile(at: url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Reads the file and resolves its interpreter. A hook whose copy is still the one the user trusted marks the lines that differ from it.
    private func loadShellFile(at url: URL) {
        do {
            let data = try HookShellScript.read(fileAt: url)
            var choice = ShellScriptChoice(source: url.path, contents: data)
            if let previous = draft.trustedCopy {
                let changes = HookShellScript.changes(from: String(decoding: previous, as: UTF8.self), to: choice.text)
                choice.changedLines = changes.changed
                choice.removedLines = changes.removed
            }
            draft.shell = choice
            problem = nil
            resolveInterpreter()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Resolves the first line in the PATH the script will get, off the main thread, since the interpreter's digest reads the whole program. Without the login shell's PATH nothing resolves, so the sheet records no interpreter that the runs would not find, and Choose Another File… or Update from File tries again.
    private func resolveInterpreter() {
        guard let contents = draft.shell?.contents else { return }
        draft.shell?.resolution = nil
        draft.shell?.problem = nil
        resolving?.cancel()
        resolving = Task { @MainActor in
            guard let login = await AILoginShell.path() else {
                guard !Task.isCancelled, draft.shell?.contents == contents else { return }
                draft.shell?.problem = HookShellScript.loginPathSentence
                return
            }
            let searchPath = HookShellScript.searchPath(helpers: HookShellScript.appHelpers, loginPath: login)
            let result = await Task.detached { HookShellScript.inspect(contents, searchPath: searchPath) }.value
            guard !Task.isCancelled, draft.shell?.contents == contents else { return }
            switch result {
            case .success(let resolution): draft.shell?.resolution = resolution
            case .failure(let failure): draft.shell?.problem = failure.sentence
            }
        }
    }

    private var testSection: some View {
        Section(localized("Test")) {
            Toggle(localized("Apply Changes"), isOn: $appliesTest)
            Button(testing == nil ? localized("Test on Current Tab") : localized("Stop Test")) {
                if let testing { testing.cancel(); return }
                guard let tab = currentTab() else { testResult = localized("Select a tab first."); return }
                do {
                    let (hook, bytes) = try draft.makeHook()
                    let applying = appliesTest
                    testing = Task { @MainActor in
                        let started = ContinuousClock.now
                        let result = await registry.testDraft(hook, script: bytes, onTab: tab, applying: applying)
                        var lines = [HookSummary.description(of: result, hookName: hook.name)]
                        if case .finished(.completed(let actions, let use)) = result {
                            lines = [applying ? localized("Applied changes") : localized("Preview")]
                            if actions.isEmpty { lines.append(localized("No changes.")) }
                            for case .renamedTab(_, let name) in actions { lines.append(localized("Suggested name: \(name)")) }
                            if let reply = use?.reply { lines.append(reply) }
                            if let use, let model = use.model { lines.append(localized("\(aiSettings.title(of: model)) · \(use.usage.inputTokens) input · \(use.usage.outputTokens) output tokens")) }
                        }
                        lines.append(started.duration(to: .now).formatted())
                        testResult = lines.joined(separator: "\n")
                        testing = nil
                    }
                } catch { testResult = error.localizedDescription }
            }
            .disabled(testing == nil && routeProblem != nil)
            Text("Testing sends a request to the selected provider.", bundle: .module).font(.caption)
            if let testResult { Text(testResult).textSelection(.enabled) }
        }
    }

    private var whenSection: some View {
        Section(localized("When")) {
            Picker(localized("Situation"), selection: $draft.kind) {
                Text("A new tab opens", bundle: .module).tag(BrowserEventKind.tabOpened)
                Text("A tab loads a page", bundle: .module).tag(BrowserEventKind.pageLoaded)
                Text("A tab's address changes", bundle: .module).tag(BrowserEventKind.addressChanged)
                Text("A tab's title changes", bundle: .module).tag(BrowserEventKind.titleChanged)
                Text("You select a tab", bundle: .module).tag(BrowserEventKind.tabSelected)
                Text("A tab closes", bundle: .module).tag(BrowserEventKind.tabClosed)
                Text("A download finishes", bundle: .module).tag(BrowserEventKind.downloadFinished)
                Text("You switch spaces", bundle: .module).tag(BrowserEventKind.spaceSwitched)
            }
            switch draft.kind {
            case .pageLoaded:
                Picker(localized("Loads"), selection: $draft.loads) {
                    Text("Only a new tab's first page", bundle: .module).tag(HookPageLoads.firstAfterOpen)
                    Text("Each new address", bundle: .module).tag(HookPageLoads.newAddress)
                    Text("Every load", bundle: .module).tag(HookPageLoads.every)
                }
            case .addressChanged:
                Picker(localized("Changes"), selection: $draft.addressChanges) {
                    Text("Only a new site", bundle: .module).tag(HookAddressChanges.newHost)
                    Text("Any change", bundle: .module).tag(HookAddressChanges.any)
                }
            case .titleChanged:
                setToggle(localized("The page's title"), .page, in: $draft.titleSources)
                setToggle(localized("Your names"), .user, in: $draft.titleSources)
                setToggle(localized("Names from hooks and agents"), .suggested, in: $draft.titleSources)
            case .tabClosed:
                if draft.guided {
                    ForEach(ScriptHookDraft.offeredCloseReasons, id: \.self) { reason in setToggle(ScriptHookDraft.label(of: reason), reason, in: $draft.closeReasons) }
                    Text("Leave all reasons off to include every close.", bundle: .module).font(.caption)
                } else { Toggle(localized("Only when you close the tab"), isOn: Binding(get: { draft.closeReasons == [.user] }, set: { draft.closeReasons = $0 ? [.user] : [] })) }
            case .spaceSwitched:
                Toggle(localized("Only when the Persona changes"), isOn: $draft.personaChangesOnly)
            default:
                EmptyView()
            }
        }
    }

    private var whereSection: some View {
        Section(localized("Where")) {
            Toggle(localized("Everywhere"), isOn: $draft.isEverywhere)
            if !draft.isEverywhere {
                // Places read as Persona rule 7 names them; with one Persona, Where lists its spaces alone.
                let namesPersonas = draft.places.count > 1
                ForEach(draft.places, id: \.id) { persona in
                    if namesPersonas {
                        setToggle(HookSummary.name(of: .persona(persona.id), places: draft.places), .persona(persona.id), in: $draft.chosenPlaces)
                    }
                    ForEach(persona.spaces, id: \.id) { space in
                        setToggle(HookSummary.name(of: .space(space.id), places: draft.places), .space(space.id), in: $draft.chosenPlaces)
                            .padding(.leading, namesPersonas ? 16 : 0)
                    }
                }
            }
            Picker(localized("Sites"), selection: $draft.siteChoice) {
                Text("All Sites", bundle: .module).tag(ScriptHookDraft.SiteChoice.all)
                Text("Only These Sites", bundle: .module).tag(ScriptHookDraft.SiteChoice.only)
                Text("All Sites Except These", bundle: .module).tag(ScriptHookDraft.SiteChoice.except)
            }
            if draft.siteChoice != .all {
                TextField(localized("Sites"), text: $draft.siteList, prompt: Text(verbatim: "example.com, news.example.org"), axis: .vertical)
            }
            Picker(localized("Engines"), selection: $draft.engine) {
                Text("Both", bundle: .module).tag(ScriptHookDraft.EngineChoice.both)
                Text(EngineKind.webKit.displayName).tag(ScriptHookDraft.EngineChoice.webKit)
                Text(EngineKind.chromium.displayName).tag(ScriptHookDraft.EngineChoice.chromium)
            }
            tabKindToggle(localized("Open tabs"), .open)
            tabKindToggle(localized("Pinned tabs"), .pinned)
            tabKindToggle(localized("Favorites' tabs"), .favorite)
            tabKindToggle(localized("Small windows' tabs"), .smallWindow)
        }
    }

    private func setToggle<Element: Hashable>(_ title: String, _ element: Element, in set: Binding<Set<Element>>) -> some View {
        Toggle(title, isOn: Binding(get: { set.wrappedValue.contains(element) }, set: { isOn in
            if isOn { set.wrappedValue.insert(element) } else { set.wrappedValue.remove(element) }
        }))
    }

    /// The four kinds all on stand for an empty set, which matches every kind but agent tabs, so the last kind left on cannot be turned off.
    private func tabKindToggle(_ title: String, _ kind: BrowserTabKind) -> some View {
        Toggle(title, isOn: Binding(get: { draft.includes(kind) }, set: { draft.setIncludes(kind, $0) }))
            .disabled(draft.includes(kind) && !draft.mayExclude(kind))
    }

    private func agentRouteName(_ route: AIRouteChoice) -> String {
        if case .models(let models) = route { return models.map(aiSettings.title(of:)).joined(separator: ", ") }
        return HookSummary.model(of: route)
    }

    private var connectedModels: [AIModelRef] {
        aiSettings.providers.flatMap { provider in
            provider.models.filter { provider.capabilities(of: $0).contains(.agent) }
                .map { AIModelRef(provider: provider.id, model: $0.name) }
        }
    }

    private func models(on route: AIRouteChoice) -> [AIModelRef] {
        switch route {
        case .models(let models): return models
        case .tier(let tier): return aiSettings.route(for: .tier(tier)).models
        }
    }

    private var routeProblem: String? {
        guard draft.enablesAgent, draft.stored?.origin.isOutsideProgram != true else { return nil }
        guard let route = draft.agentModel else { return localized("Choose the model for this hook.") }
        let refs = models(on: route)
        guard !refs.isEmpty, refs.allSatisfy(connectedModels.contains) else { return localized("Choose a connected model that supports agent runs.") }
        let cli = refs.compactMap { ref in aiSettings.providers.first { $0.id == ref.provider } }.filter { provider in
            if case .commandLine = provider.kind { return true }
            return false
        }
        return cli.isEmpty || cli.count == refs.count ? nil : localized("Choose only API models or only command-line models for this route.")
    }

    private var agentRoutes: [AIRouteChoice] {
        var routes = AIModelTier.allCases.map(AIRouteChoice.tier) + connectedModels.map { .models([$0]) }
        if let current = draft.agentModel, !routes.contains(current) { routes.append(current) }
        return routes
    }

    private var saveTitle: String {
        guard draft.needsTrust else { return draft.stored == nil ? localized("Add") : localized("Save") }
        return draft.stored == nil ? localized("Trust and Add") : localized("Trust and Save")
    }

    /// Saves the hook; a shell script that needs trust waits for Touch ID or the login password first, and the bytes the sheet showed are the ones Arch copies.
    private func save() {
        do {
            let (hook, data) = try draft.makeHook()
            guard draft.needsTrust else { return try commit(hook, data, trusted: false) }
            trusting = Task { @MainActor in
                defer { trusting = nil }
                let trusted = await AgentDeviceOwnerAuthentication().authenticate(reason: localized("trust the shell script of the hook \u{201C}\(hook.name)\u{201D}"))
                guard !Task.isCancelled else { return }
                guard trusted else {
                    problem = localized("Arch did not trust the script.")
                    return
                }
                do {
                    try commit(hook, data, trusted: true)
                } catch {
                    problem = error.localizedDescription
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func commit(_ hook: Hook, _ data: Data, trusted: Bool) throws {
        if draft.stored == nil {
            try registry.add(hook, script: data)
        } else {
            // A shell hook takes other bytes or another interpreter only through trust, which also lifts a pause for a changed script or interpreter.
            try registry.update(hook, script: draft.isShell && !trusted ? nil : data)
            // The reviewed script lets a hook that its change paused run again; a hook paused for another reason stays paused.
            if !draft.isShell, draft.isReview, registry.hooks.first(where: { $0.id == hook.id })?.state == .paused(.scriptChanged) { registry.resume(hook.id) }
        }
        dismiss()
    }
}

extension HookOrigin {
    var isOutsideProgram: Bool {
        if case .outsideClient = self { return true }
        return false
    }
}
