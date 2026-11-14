// New Script Hook… and Edit… in Settings ▸ AI ▸ Agent Hooks (`docs/hooks.md`, Settings ▸ AI ▸ Agent Hooks): a JavaScript hook's name, situation, places, sites, engines, and tabs, what its script may do with tabs, and the script, which Save checks before the registry records it with its digest. Review opens the sheet on a script that changed outside Arch; saving it lets the hook run again. The user's edits in Arch need no Touch ID.
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
    var script: String

    init(new places: [HookPersonaPlaces]) {
        id = UUID()
        stored = nil
        isReview = false
        self.places = places
        name = "New Hook"
        kind = .pageLoaded
        script = Self.template(for: .pageLoaded)
        renamesTabs = true
    }

    init(editing hook: Hook, script: String, places: [HookPersonaPlaces], reviewing: Bool) {
        id = hook.id
        stored = hook
        isReview = reviewing
        self.places = places
        name = hook.name
        kind = hook.trigger.kind
        self.script = script
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
        readsTabs = hook.grant.permissions.contains(.tabs)
        renamesTabs = hook.grant.permissions.contains(.tabsRename)
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
        filter.scope = isEverywhere ? .everywhere : .places(Self.ordered(chosenPlaces, in: places))
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
    let dismiss: () -> Void
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
                }
                whenSection
                whereSection
                Section {
                    Toggle("Read Tab Titles and Addresses", isOn: $draft.readsTabs)
                    Toggle("Rename Tabs", isOn: $draft.renamesTabs)
                } header: {
                    Text("Tabs")
                } footer: {
                    aiFootnote("The script reaches only the tabs above, in the event's Persona. Without Read Tab Titles and Addresses, it sees which tabs they are but not their pages. A name from the script never replaces a name you gave a tab.")
                }
                if draft.stored?.origin.isOutsideProgram != true {
                    Section("Agent") {
                        Toggle("Allow Agent Runs", isOn: $draft.enablesAgent)
                        if draft.enablesAgent {
                            Picker("Model", selection: $draft.agentModel) {
                                Text("Choose a model").tag(nil as AIRouteChoice?)
                                ForEach(agentRoutes, id: \.self) { route in
                                    Text(agentRouteName(route)).tag(Optional(route))
                                }
                            }
                            Toggle("Allow the Agent to Rename Tabs", isOn: $draft.agentRenamesTabs)
                            Toggle("Allow the Agent to Read Page Text", isOn: $draft.readsPageText)
                            TextField("Instructions for the agent", text: $draft.agentPrompt, axis: .vertical)
                            Text("Use await arch.agent.run(event.hook.agent) in your script to send these instructions and the event tab’s title and address to this provider.").font(.caption)
                        }
                    }
                }
                Section("Script") {
                    TextEditor(text: $draft.script)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                }
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
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onChange(of: draft.kind) { oldKind, newKind in
            // An untouched template follows the situation.
            if draft.script == ScriptHookDraft.template(for: oldKind) { draft.script = ScriptHookDraft.template(for: newKind) }
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
                Toggle("Only when you close the tab", isOn: Binding(get: { draft.closeReasons == [.user] }, set: { draft.closeReasons = $0 ? [.user] : [] }))
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

    private var agentRoutes: [AIRouteChoice] {
        var routes = aiSettings.providers.flatMap { provider -> [AIRouteChoice] in
            guard case .http = provider.kind else { return [] }
            return provider.models.filter { provider.capabilities(of: $0).contains(.agent) }
                .map { .models([AIModelRef(provider: provider.id, model: $0.name)]) }
        }
        if let current = draft.agentModel, !routes.contains(current) { routes.append(current) }
        return routes
    }

    private func save() {
        let data = Data(draft.script.utf8)
        if let problem = HookScriptRunner.problem(in: data) {
            self.problem = problem
            return
        }
        if let sentence = draft.sitePatterns().problem {
            problem = sentence
            return
        }
        if !draft.isEverywhere && draft.chosenPlaces.isEmpty {
            problem = "Choose where the hook runs."
            return
        }
        if draft.kind == .titleChanged && draft.titleSources.isEmpty {
            problem = "Choose which title changes start the hook."
            return
        }
        if draft.tabKinds.isEmpty == false && draft.tabKinds.isDisjoint(with: ScriptHookDraft.offeredTabKinds) {
            problem = "Choose the tabs the hook runs for."
            return
        }
        let trigger = draft.trigger
        var hook = draft.stored ?? Hook(name: draft.name, trigger: trigger)
        hook.name = draft.name.trimmingCharacters(in: .whitespaces)
        if hook.trigger.kind != trigger.kind { hook.timing = HookTiming(for: trigger) }
        hook.trigger = trigger
        hook.filter = draft.filter
        var permissions = hook.grant.permissions.intersection([.agent])
        if draft.readsTabs { permissions.insert(.tabs) }
        if draft.renamesTabs { permissions.insert(.tabsRename) }
        hook.grant.permissions = permissions
        // A script the user wrote or changed is the user's, which the agent hook editor no longer writes.
        if case .javaScript(let digest, true) = hook.script, HookStore.digest(of: data) != digest { hook.script = .javaScript(digest: digest, generated: false) }
        do {
            if hook.origin.isOutsideProgram == false { try draft.configureAgent(in: &hook) }
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


private extension HookOrigin {
    var isOutsideProgram: Bool {
        if case .outsideClient = self { return true }
        return false
    }
}
