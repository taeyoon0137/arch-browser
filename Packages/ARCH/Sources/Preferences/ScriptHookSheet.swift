// New Script Hook… and Edit… in Settings ▸ AI ▸ Hooks (`docs/hooks.md`, Settings ▸ AI ▸ Hooks): a JavaScript hook's name, situation, places, sites, engines, and tabs, what its script may do with tabs, and the script, which Save checks before the registry records it with its digest. Review opens the sheet on a script that changed outside Arch; saving it lets the hook run again. The user's edits in Arch need no Touch ID.
import Agent
import AI
import ARCHEngine
import Events
import Hooks
import SwiftUI

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
    var startsEnabled = true
    var agentRecord: AgentRunRecord = .none
    var seconds = 30
    var rounds = 2
    var toolCalls = 5
    var dailyLimit = 200
    var delay = 1.5
    var script: String

    init(new places: [HookPersonaPlaces], guided: Bool = false) {
        id = UUID()
        stored = nil
        isReview = false
        self.places = places
        name = "New Hook"
        kind = .pageLoaded
        script = Self.template(for: .pageLoaded)
        renamesTabs = !guided
        self.guided = guided
        generated = guided
        enablesAgent = guided
        if guided { name = "New Agent Hook" }
    }

    init(editing hook: Hook, script: String, places: [HookPersonaPlaces], reviewing: Bool, isNew: Bool = false) {
        id = hook.id
        stored = isNew ? nil : hook
        startsEnabled = hook.state == .active
        isReview = reviewing
        self.places = places
        name = hook.name
        kind = hook.trigger.kind
        self.script = script
        origin = hook.origin
        guided = hook.agent != nil && !hook.origin.isOutsideProgram
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
    }

    var scriptText: String { guided && generated ? AgentHookTemplate.script(for: kind) : script }

    mutating func editGeneratedScript() {
        script = scriptText
        generated = false
    }

    func makeHook() throws -> (hook: Hook, script: Data) {
        let bytes = Data(scriptText.utf8)
        func invalid(_ reason: String) -> HookRegistryError { .invalidAgentOptions(reason) }
        if let problem = HookScriptRunner.problem(in: bytes) ?? sitePatterns().problem { throw invalid(problem) }
        guard isEverywhere || !chosenPlaces.isEmpty else { throw invalid("Choose where the hook runs.") }
        guard kind != .titleChanged || !titleSources.isEmpty else { throw invalid("Choose which title changes start the hook.") }
        guard tabKinds.isEmpty || !tabKinds.isDisjoint(with: Self.offeredTabKinds) else { throw invalid("Choose its tab kinds.") }
        var hook = stored ?? Hook(id: id, name: name, trigger: trigger, state: startsEnabled ? .active : .paused(.user), origin: origin)
        hook.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hook.name.isEmpty else { throw invalid("Name the hook.") }
        if hook.trigger.kind != kind { hook.timing = HookTiming(for: trigger) }
        hook.trigger = trigger
        hook.filter = filter
        hook.grant.permissions = hook.grant.permissions.intersection([.agent])
        // An outside program's hook never reads other tabs' titles and addresses (`docs/hooks.md`, Hooks from outside programs).
        if readsTabs, !origin.isOutsideProgram { hook.grant.permissions.insert(.tabs) }
        if renamesTabs { hook.grant.permissions.insert(.tabsRename) }
        if !hook.origin.isOutsideProgram { try configureAgent(in: &hook) }
        if guided, let model = agentModel {
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
        guard let agentModel else { throw HookRegistryError.invalidAgentOptions("Choose the model for this hook.") }
        var grant = hook.grant.agent ?? AgentRunGrant(tools: [], maximumRecord: .none)
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
            guard let pattern = AISitePattern(parsing: entry) else { return (patterns, "\u{201C}\(entry)\u{201D} is not a site.") }
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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if draft.isReview {
                    Section {
                        Text("Its script changed outside Arch. Read the script below; saving it lets the hook run it again.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Name", text: $draft.name)
                    if draft.stored == nil, case .preset = draft.origin { Toggle("Enable this hook when saved", isOn: $draft.startsEnabled) }
                    if draft.guided { TabNamesWarning(settings: aiSettings, renames: draft.agentRenamesTabs, kind: draft.kind) }
                }
                whenSection
                whereSection
                if !draft.guided || !draft.generated {
                    Section("Script permissions") {
                        if !draft.origin.isOutsideProgram { Toggle("Read Tab Titles and Addresses", isOn: $draft.readsTabs) }
                        Toggle("Rename Tabs", isOn: $draft.renamesTabs)
                    }
                }
                if draft.stored?.origin.isOutsideProgram != true { agentSettings }
                if draft.guided { testSection }
                scriptSection
            }
            .formStyle(.grouped)
            HStack {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.stored == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(testing != nil || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || routeProblem != nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onDisappear { testing?.cancel() }
        .onChange(of: draft.kind) { oldKind, newKind in
            // An untouched template follows the situation.
            if draft.script == ScriptHookDraft.template(for: oldKind) { draft.script = ScriptHookDraft.template(for: newKind) }
        }
    }

    @ViewBuilder private var agentSettings: some View {
        Section("Agent") {
            if !draft.guided { Toggle("Allow Agent Runs", isOn: $draft.enablesAgent) }
            if draft.enablesAgent {
                TextField("Instructions", text: $draft.agentPrompt, prompt: Text("Give the tab a short name in its own language."), axis: .vertical)
                Toggle(draft.kind == .tabClosed ? "Read Text of the Tabs Left" : "Read Page Text", isOn: $draft.readsPageText)
                Toggle(draft.kind == .tabClosed ? "Read Outlines of the Tabs Left" : "Read Page Outline", isOn: $draft.readsPageOutline)
                if draft.readsPageOutline { Text("Outlines include page labels and links. Form values are hidden.").font(.caption) }
                if draft.readsPageText || draft.readsPageOutline {
                    Text("Sites excluded from AI are skipped.").font(.caption)
                } else {
                    Text("The model receives titles and reduced addresses on the allowed tabs.").font(.caption)
                }
                if draft.kind == .tabClosed { Text("The closed tab provides its last title and address. Actions apply to tabs left in its space.").font(.caption) }
            }
        }
        if draft.enablesAgent {
            Section("Model") {
                Picker("Use", selection: $draft.agentModel) {
                    Text("Choose a model").tag(nil as AIRouteChoice?)
                    ForEach(agentRoutes, id: \.self) { route in Text(agentRouteName(route)).tag(Optional(route)) }
                }
                if let routeProblem { Text(routeProblem).font(.caption).foregroundStyle(.secondary) }
                if let route = draft.agentModel {
                    let refs = models(on: route)
                    if case .tier(let tier) = route, refs.isEmpty {
                        Menu("Choose a model for the \(tier.title) tier") {
                            ForEach(connectedModels, id: \.self) { ref in Button(aiSettings.title(of: ref)) { aiSettings.setRoute(AIRoute(isEnabled: true, models: [ref]), for: .tier(tier)) } }
                        }
                    }
                    ForEach(refs, id: \.self) { model in
                        if let provider = aiSettings.providers.first(where: { $0.id == model.provider }) {
                            let destination = AgentRunRequest.destination(of: provider)
                            Text("\(aiSettings.title(of: model)) · \(destination)").font(.caption).textSelection(.enabled)
                            if case .commandLine = provider.kind { Text("Each run starts the signed-in command-line tool and can take a few seconds.").font(.caption) }
                        }
                    }
                }
            }
            Section("Allowed actions") {
                Toggle(draft.kind == .tabClosed ? "Rename the Tabs Left" : "Rename the Tab", isOn: $draft.agentRenamesTabs)
            }
            if draft.guided {
                Section("Record") {
                    Picker("Keep", selection: $draft.agentRecord) {
                        Text("Nothing").tag(AgentRunRecord.none)
                        Text("Activity Only").tag(AgentRunRecord.activity)
                        Text("The Session").tag(AgentRunRecord.session)
                    }
                    Text(recordDetail).font(.caption)
                }
                Section("Limits") {
                    Stepper("Time limit · \(draft.seconds) seconds", value: $draft.seconds, in: 5...600)
                    Stepper("Model rounds · \(draft.rounds)", value: $draft.rounds, in: 1...20)
                    Stepper("Tool calls · \(draft.toolCalls)", value: $draft.toolCalls, in: 1...50)
                    Stepper("Runs per day · \(draft.dailyLimit)", value: $draft.dailyLimit, in: 1...2000)
                    Stepper("Wait before running · \(draft.delay.formatted()) seconds", value: $draft.delay, in: 0...60, step: 0.5)
                }
            }
        }
    }

    private var recordDetail: String {
        switch draft.agentRecord {
        case .none: return "Keep usage totals only."
        case .activity: return "Keep activity without page content or replies."
        case .session: return "Keep the transcript in memory until quit."
        }
    }

    private var scriptSection: some View {
        Section("Script") {
            if draft.guided {
                if draft.generated {
                    Toggle("Show Script", isOn: $showsScript)
                    if showsScript {
                        Text(draft.scriptText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Edit Script") { draft.editGeneratedScript() }
                    }
                } else { Button("Restore Arch’s Script") { draft.generated = true; showsScript = true } }
            }
            if !draft.guided || !draft.generated {
                TextEditor(text: $draft.script).font(.system(.body, design: .monospaced)).frame(minHeight: 140)
            }
        }
    }

    private var testSection: some View {
        Section("Test") {
            Toggle("Apply Changes", isOn: $appliesTest)
            Button(testing == nil ? "Test on Current Tab" : "Stop Test") {
                if let testing { testing.cancel(); return }
                guard let tab = currentTab() else { testResult = "Select a tab first."; return }
                do {
                    let (hook, bytes) = try draft.makeHook()
                    let applying = appliesTest
                    testing = Task { @MainActor in
                        let started = ContinuousClock.now
                        let result = await registry.testDraft(hook, script: bytes, onTab: tab, applying: applying)
                        var lines = [HookSummary.description(of: result, hookName: hook.name)]
                        if case .finished(.completed(let actions, let use)) = result {
                            lines = [applying ? "Applied changes" : "Preview"]
                            if actions.isEmpty { lines.append("No changes.") }
                            for case .renamedTab(_, let name) in actions { lines.append("Suggested name: \(name)") }
                            if let reply = use?.reply { lines.append(reply) }
                            if let use, let model = use.model { lines.append("\(aiSettings.title(of: model)) · \(use.usage.inputTokens) input · \(use.usage.outputTokens) output tokens") }
                        }
                        lines.append(started.duration(to: .now).formatted())
                        testResult = lines.joined(separator: "\n")
                        testing = nil
                    }
                } catch { testResult = error.localizedDescription }
            }
            .disabled(testing == nil && routeProblem != nil)
            Text("Testing sends a request to the selected provider.").font(.caption)
            if let testResult { Text(testResult).textSelection(.enabled) }
        }
    }

    private var whenSection: some View {
        Section("When") {
            Picker("Situation", selection: $draft.kind) {
                Text("A new tab opens").tag(BrowserEventKind.tabOpened)
                Text("A tab loads a page").tag(BrowserEventKind.pageLoaded)
                Text("A tab's address changes").tag(BrowserEventKind.addressChanged)
                Text("A tab's title changes").tag(BrowserEventKind.titleChanged)
                Text("You select a tab").tag(BrowserEventKind.tabSelected)
                Text("A tab closes").tag(BrowserEventKind.tabClosed)
                Text("A download finishes").tag(BrowserEventKind.downloadFinished)
                Text("You switch spaces").tag(BrowserEventKind.spaceSwitched)
            }
            switch draft.kind {
            case .pageLoaded:
                Picker("Loads", selection: $draft.loads) {
                    Text("Only a new tab's first page").tag(HookPageLoads.firstAfterOpen)
                    Text("Each new address").tag(HookPageLoads.newAddress)
                    Text("Every load").tag(HookPageLoads.every)
                }
            case .addressChanged:
                Picker("Changes", selection: $draft.addressChanges) {
                    Text("Only a new site").tag(HookAddressChanges.newHost)
                    Text("Any change").tag(HookAddressChanges.any)
                }
            case .titleChanged:
                setToggle("The page's title", .page, in: $draft.titleSources)
                setToggle("Your names", .user, in: $draft.titleSources)
                setToggle("Names from hooks and agents", .suggested, in: $draft.titleSources)
            case .tabClosed:
                if draft.guided {
                    ForEach(BrowserTabCloseReason.allCases, id: \.self) { reason in setToggle(reason.rawValue.capitalized, reason, in: $draft.closeReasons) }
                    Text("Leave all reasons off to include every close.").font(.caption)
                } else { Toggle("Only when you close the tab", isOn: Binding(get: { draft.closeReasons == [.user] }, set: { draft.closeReasons = $0 ? [.user] : [] })) }
            case .spaceSwitched:
                Toggle("Only when the Persona changes", isOn: $draft.personaChangesOnly)
            default:
                EmptyView()
            }
        }
    }

    private var whereSection: some View {
        Section("Where") {
            Toggle("Everywhere", isOn: $draft.isEverywhere)
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
            Picker("Sites", selection: $draft.siteChoice) {
                Text("All Sites").tag(ScriptHookDraft.SiteChoice.all)
                Text("Only These Sites").tag(ScriptHookDraft.SiteChoice.only)
                Text("All Sites Except These").tag(ScriptHookDraft.SiteChoice.except)
            }
            if draft.siteChoice != .all {
                TextField("Sites", text: $draft.siteList, prompt: Text("example.com, news.example.org"), axis: .vertical)
            }
            Picker("Engines", selection: $draft.engine) {
                Text("Both").tag(ScriptHookDraft.EngineChoice.both)
                Text(EngineKind.webKit.displayName).tag(ScriptHookDraft.EngineChoice.webKit)
                Text(EngineKind.chromium.displayName).tag(ScriptHookDraft.EngineChoice.chromium)
            }
            tabKindToggle("Open tabs", .open)
            tabKindToggle("Pinned tabs", .pinned)
            tabKindToggle("Favorites' tabs", .favorite)
            tabKindToggle("Small windows' tabs", .smallWindow)
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
        guard let route = draft.agentModel else { return "Choose the model for this hook." }
        let refs = models(on: route)
        guard !refs.isEmpty, refs.allSatisfy(connectedModels.contains) else { return "Choose a connected model that supports agent runs." }
        let cli = refs.compactMap { ref in aiSettings.providers.first { $0.id == ref.provider } }.filter { provider in
            if case .commandLine = provider.kind { return true }
            return false
        }
        return cli.isEmpty || cli.count == refs.count ? nil : "Choose only API models or only command-line models for this route."
    }

    private var agentRoutes: [AIRouteChoice] {
        var routes = AIModelTier.allCases.map(AIRouteChoice.tier) + connectedModels.map { .models([$0]) }
        if let current = draft.agentModel, !routes.contains(current) { routes.append(current) }
        return routes
    }

    private func save() {
        do {
            let (hook, data) = try draft.makeHook()
            if draft.stored == nil {
                try registry.add(hook, script: data)
            } else {
                try registry.update(hook, script: data)
                // The reviewed script lets a hook that its change paused run again; a hook paused for another reason stays paused.
                if draft.isReview, registry.hooks.first(where: { $0.id == hook.id })?.state == .paused(.scriptChanged) { registry.resume(hook.id) }
            }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

extension HookOrigin {
    var isOutsideProgram: Bool {
        if case .outsideClient = self { return true }
        return false
    }
}
