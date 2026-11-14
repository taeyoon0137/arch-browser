// Settings ▸ AI ▸ Agents (docs/agents.md, Settings ▸ AI ▸ Agents): the in-app sessions' mode, history search, and Codex's copy of their conversations; Allow Outside Clients with what it lets programs do, the command-line tools with their PATH links and MCP configurations, the entry skill for Claude Code and Codex, the grants with Revoke and Revoke All, and the activity log by day with filters by client and site and Clear Activity. It also says when `agent.json` was set aside or its key could not be read, and when the agent socket cannot listen.
import Agent
import AgentControl
import AI
import AppKit
import SwiftUI

struct AgentSettingsPage: View {
    @ObservedObject var service: AgentService
    @ObservedObject var activity: AgentActivityLog
    var hookName: (UUID) -> String? = { _ in nil }
    @State private var isChangingAccess = false
    @State private var accessError: String?
    @State private var clientFilter: String?
    @State private var siteFilter: String?

    /// The most entries the page lists at once, newest first, so that a busy log does not slow the window.
    private static let listedEntries = 300

    var body: some View {
        if let notice = settingsNotice {
            Section {
                Text(notice).foregroundStyle(.secondary)
                if case .keyUnavailable = service.state {
                    Button("Try Again") { service.retryReadingSettings() }
                }
            }
        }
        sessionsSection
        Section {
            Toggle("Allow Outside Clients (arch-cli and arch-mcp)", isOn: Binding(get: { service.settings.allowsOutsideClients }, set: setAllowsOutsideClients))
                .disabled(!service.canChangeSettings || isChangingAccess)
            if let accessError {
                Text(accessError).font(.callout).foregroundStyle(.red)
            }
            if let problem = service.channelProblem {
                HStack {
                    Text(problem).font(.callout).foregroundStyle(.red)
                    Spacer()
                    Button("Try Again") { service.retryChannel() }
                }
            }
            if let problem = service.saveProblem {
                Text("agent.json could not be written: \(problem)").font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Outside Clients")
        } footer: {
            aiFootnote("Programs you run, such as Claude Code or Codex in a terminal, can then ask to use Arch through arch-cli and arch-mcp, which come with Arch. The first time each program asks, Arch shows which program it is and lets you choose its Persona, space, and access; the Agents Persona, with no sign-ins, and Read Only come first. Pages a program reads may contain text aimed at it. If it can run commands on your Mac, a page could try to make it do so, and Arch cannot prevent that. Programs that run as you can still start arch-cli, so Arch's checks make misuse harder but are not a wall against your own account.")
        }
        AgentCommandLineToolsSection()
        AgentSkillsSection()
        grantsSection
        activitySection
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        Section {
            Picker("New sessions start in", selection: Binding(get: { service.newSessionMode }, set: service.setNewSessionMode)) {
                ForEach(AgentAccessLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Let In-App Agents Search History", isOn: Binding(get: { service.settings.inAppAgentsSearchHistory }, set: service.setInAppAgentsSearchHistory))
            Toggle("Keep Codex\u{2019}s Copy of Agent Conversations", isOn: Binding(get: { service.keepsCodexCopy }, set: service.setKeepsCodexCopy))
        } header: {
            Text("Agent Sessions")
        } footer: {
            aiFootnote("A session the user starts begins in this mode and can be lowered at any time; raising it asks first. Sessions that a program starts with arch-cli task begin at most in this mode. Codex keeps its own copy of each agent conversation, with the pages the agent read, until Arch deletes it with the session, unless you keep it here; Claude Code keeps none of Arch\u{2019}s sessions.")
        }
        .disabled(!service.canChangeSettings)
    }

    private var settingsNotice: String? {
        switch service.state {
        case .ready: return nil
        case .reading: return "Checking agent.json\u{2026}"
        case .replacedUnreadable: return "agent.json could not be verified, so Arch renamed it agent.json.unreadable and started with outside access off and no grants."
        case .keyUnavailable(let reason): return "Arch could not read the key that protects its agent settings from the Keychain: \(reason) Until it can, outside access is off, no grant is used, new sessions start in Read Only, and Codex keeps its copy of agent conversations."
        }
    }

    private func setAllowsOutsideClients(_ isOn: Bool) {
        isChangingAccess = true
        Task {
            do {
                try await service.setAllowsOutsideClients(isOn)
                accessError = nil
            } catch {
                accessError = error.localizedDescription
            }
            isChangingAccess = false
        }
    }

    // MARK: Grants

    private var grantsSection: some View {
        Section {
            if service.grants.isEmpty {
                Text("No program has access to Arch.").foregroundStyle(.secondary)
            }
            ForEach(service.grants) { grant in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(grant.client.displayName).fontWeight(.medium)
                        if service.connectedGrantIDs.contains(grant.id) {
                            Text("Connected").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        Button("Revoke") { service.revoke(grant.id) }
                    }
                    Text(grant.client.executablePath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(details(of: grant)).font(.caption).foregroundStyle(.secondary)
                    if grant.client.reachedThroughShell {
                        Text(AgentClientIdentity.shellNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if service.grants.count > 1 {
                HStack {
                    Spacer()
                    Button("Revoke All") { service.revokeAll() }
                }
            }
        } header: {
            Text("Grants")
        } footer: {
            aiFootnote("Revoking ends a program's access at once: its connections close, and its next command asks again.")
        }
    }

    private func details(of grant: AgentGrant) -> String {
        let persona = service.host.personas.first { $0.id == grant.personaID }?.name ?? "Deleted Persona"
        let spaces = service.host.spaces(in: grant.personaID)
        let space = (spaces.first { $0.id == grant.spaceID } ?? spaces.first)?.name
        // A Persona's place reads as "Persona / Space".
        var parts = [grant.level.title, space.map { "\(persona) / \($0)" } ?? persona]
        if grant.scopes.searchHistory { parts.append("searches history") }
        if grant.scopes.startTasks { parts.append("starts agent tasks") }
        switch grant.expiry {
        case .whenArchQuits: parts.append("until Arch quits")
        case .whenRevoked: parts.append("until revoked")
        case .at(let date): parts.append("until \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        parts.append(grant.lastUsedAt.map { "last used \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "not used yet")
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Activity

    @ViewBuilder private var activitySection: some View {
        let entries = activity.entries.reversed().filter { entry in
            (clientFilter == nil || entry.clientName == clientFilter) && (siteFilter == nil || entry.site == siteFilter)
        }
        let listed = Array(entries.prefix(Self.listedEntries))
        Section {
            Picker("Client", selection: $clientFilter) {
                Text("All").tag(String?.none)
                ForEach(Array(Set(activity.entries.map(\.clientName))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker("Site", selection: $siteFilter) {
                Text("All").tag(String?.none)
                ForEach(Array(Set(activity.entries.compactMap(\.site))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            if listed.isEmpty {
                Text("No activity.").foregroundStyle(.secondary)
            }
            ForEach(Self.days(of: listed), id: \.day) { day in
                Text(day.day.formatted(date: .complete, time: .omitted)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(day.entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.date, style: .time).monospacedDigit()
                        Text(entry.hookID.flatMap(hookName) ?? entry.clientName)
                        Spacer()
                        Text(Self.summary(of: entry)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            HStack {
                if entries.count > listed.count {
                    Text("Showing the latest \(listed.count) of \(entries.count).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Activity") { activity.clear() }
                    .disabled(activity.entries.isEmpty)
            }
        } header: {
            Text("Activity")
        } footer: {
            aiFootnote("Arch keeps \(AgentActivityLog.keptDays) days of what agents did and what you decided, without page text, typed text, addresses' paths, or screenshots.")
        }
    }

    private struct Day {
        var day: Date
        var entries: [AgentActivityEntry]
    }

    /// The entries by day, in the order given.
    private static func days(of entries: [AgentActivityEntry]) -> [Day] {
        var days: [Day] = []
        for entry in entries {
            let day = Calendar.current.startOfDay(for: entry.date)
            if days.last?.day == day {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(Day(day: day, entries: [entry]))
            }
        }
        return days
    }

    private static func summary(of entry: AgentActivityEntry) -> String {
        switch entry.event {
        case .toolCall:
            var parts = [entry.tool ?? "unknown tool"]
            if let site = entry.site { parts.append(site) }
            if let rule = entry.rule { parts.append("refused by \(rule)") } else if let outcome = entry.outcome { parts.append(outcome) }
            return parts.joined(separator: " \u{00B7} ")
        case .granted: return entry.decision == .approvedWithTouchID ? "Allowed with Touch ID or password" : "Allowed"
        case .firstUse: return "First use since Arch started"
        case .revoked: return "Revoked"
        case .released: return "Gave up its access"
        case .expired: return "Access expired"
        case .declined: return "Not allowed"
        case .refusedPeer: return "Connection refused: \(entry.outcome ?? "")"
        }
    }
}

// MARK: - Command-line tools

/// The command-line tools part of Settings ▸ AI ▸ Agents apart from its view, for one bundle and one PATH: the links that Install Command-Line Tools… writes, the links into an Arch bundle that Remove removes, and the sentences that show them. `AgentLinkInstaller` makes every decision about folders and files.
struct AgentCommandLineTools {
    let bundle: AgentBundleLayout
    let installer: AgentLinkInstaller

    /// `searchPath` is the login shell's PATH, since the app's own PATH lacks the folders a shell profile adds.
    init(bundle: AgentBundleLayout, homeFolder: URL, searchPath: String) {
        self.bundle = bundle
        installer = AgentLinkInstaller(homeFolder: homeFolder, searchPath: searchPath)
    }

    /// Whether the bundle holds `arch-cli`. An app run from the build folder has no bundle, and so no tools to link or name.
    static func hasTools(_ bundle: AgentBundleLayout) -> Bool {
        FileManager.default.isExecutableFile(atPath: bundle.cliExecutableURL.path)
    }

    /// Whether macOS runs the bundle from a temporary folder (App Translocation), as it does for a downloaded app opened before it was moved. The folder changes at each launch, so a link, configuration, or skill that names it stops working; Settings then offers neither Install nor Update, nor the configurations.
    static func isTranslocated(_ bundle: AgentBundleLayout) -> Bool {
        bundle.bundleURL.pathComponents.contains("AppTranslocation")
    }

    static let translocatedSentence = "macOS runs this copy of Arch from a temporary folder that changes at each launch, so Arch gives its path to no other tool. Move Arch to the Applications folder in Finder, then open it again."

    /// Both links in the folder that `AgentLinkInstaller` picks from PATH, `~/.local/bin` first.
    func plannedLinks() throws -> [AgentLinkInstaller.Link] {
        AgentLinkInstaller.links(in: try installer.installFolder(named: nil), for: bundle)
    }

    /// Writes the links; the installer checks both places again first.
    func install(_ links: [AgentLinkInstaller.Link]) throws {
        try installer.install(links)
    }

    /// The links into an Arch bundle's `Contents/Helpers` in PATH's folders inside the home folder, each folder once however PATH spells it, and each link with where it points: what Remove removes.
    func installedLinks() -> [AgentLinkInstaller.Link] {
        // Without a named folder, `removalFolders` does not throw.
        let folders = (try? installer.removalFolders(named: nil)) ?? []
        return folders.flatMap { folder in
            AgentLinkInstaller.names.compactMap { name -> AgentLinkInstaller.Link? in
                let location = folder.appendingPathComponent(name)
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: location.path),
                      AgentLinkInstaller.isArchLink(destination: destination, in: folder) else { return nil }
                return AgentLinkInstaller.Link(location: location, destination: URL(fileURLWithPath: destination, relativeTo: folder).standardizedFileURL)
            }
        }
    }

    /// Removes the links that `installedLinks` lists and returns their locations.
    func removeLinks() throws -> [URL] {
        try installer.remove(from: installer.removalFolders(named: nil))
    }

    /// What the confirmation shows before anything is written: where the tools are, and each link with the file it will point to.
    static func confirmation(for links: [AgentLinkInstaller.Link], bundle: AgentBundleLayout) -> String {
        let folder = links.first?.location.deletingLastPathComponent().path ?? ""
        return (["arch-cli and arch-mcp are in \(bundle.helpersURL.path). Arch links them into \(folder):"] + links.map(line)).joined(separator: "\n")
    }

    static func line(_ link: AgentLinkInstaller.Link) -> String {
        "\(link.location.path) \u{2192} \(link.destination.path)"
    }

    /// What Install says after writing the links: the folder, and each file that PATH reaches first by a link's name and that a terminal runs instead, with Remove and Install again for one that Remove removes.
    func installedSentence(for links: [AgentLinkInstaller.Link]) -> String {
        let folder = links.first?.location.deletingLastPathComponent().path ?? ""
        let shadows = links.compactMap(installer.shadow(of:)).map { shadow in
            "\(shadow.file.path) comes first on your PATH and runs instead" + (shadow.isRemovable ? "; Remove, then Install again, to replace it." : ".")
        }
        return (["Linked arch-cli and arch-mcp into \(folder)."] + shadows).joined(separator: " ")
    }

    /// The installer's sentence. With no writable folder, Settings has no `--dir`, so the sentence names the bundle's `arch-cli links install --dir`; and Arch reads the login shell's PATH once per launch, so a folder added to PATH counts only after Arch is opened again.
    static func sentence(for failure: AgentLinkInstaller.Failure, bundle: AgentBundleLayout) -> String {
        guard failure == .noFolder else { return failure.message }
        let command = AgentMCPConfiguration.shellCommand([bundle.cliExecutableURL.path, "links", "install", "--dir"]) + " <folder>"
        return AgentLinkInstaller.Failure.noFolderMessage(orElse: "run \(command) in a terminal") + " Arch reads PATH from your login shell once per launch, so quit and reopen Arch after changing it."
    }

    /// What the section says when it cannot read the login shell's PATH, and so cannot tell which links are there: the bundle's commands that link and unlink with a terminal's PATH.
    static func unreadPathSentence(bundle: AgentBundleLayout) -> String {
        let command = { (action: String) in AgentMCPConfiguration.shellCommand([bundle.cliExecutableURL.path, "links", action]) }
        return "Arch could not read PATH from your login shell. In a terminal, \(command("install")) links the tools with that shell's PATH, and \(command("remove")) removes Arch's links."
    }
}

/// Settings ▸ AI ▸ Agents ▸ Command-Line Tools: where `arch-cli` and `arch-mcp` are, Install Command-Line Tools…, which shows both paths and then links both tools into a folder on the login shell's PATH, Remove, and the MCP configurations for Claude Code and Codex with Copy. Arch never edits another tool's configuration.
struct AgentCommandLineToolsSection: View {
    var bundle = AgentBundleLayout(bundleURL: Bundle.main.bundleURL)
    /// nil until the login shell's PATH is read, and while it cannot be.
    @State private var tools: AgentCommandLineTools?
    @State private var isReadingPath = true
    @State private var installed: [AgentLinkInstaller.Link] = []
    @State private var pendingLinks: [AgentLinkInstaller.Link] = []
    @State private var isConfirmingInstall = false
    @State private var outcome: String?
    @State private var problem: String?

    /// The configurations shown; `arch-cli mcp-config` also prints the JSON other MCP clients read.
    private static let configurations: [AgentMCPConfigurationFormat] = [.claude, .codex]

    var body: some View {
        Section {
            if AgentCommandLineTools.hasTools(bundle) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("arch-cli and arch-mcp are in")
                    pathText(bundle.helpersURL.path)
                }
                .task { await readTools() }
                .alert("Install Command-Line Tools?", isPresented: $isConfirmingInstall) {
                    Button("Install") { install(pendingLinks) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(AgentCommandLineTools.confirmation(for: pendingLinks, bundle: bundle))
                }
                linksRow
                if AgentCommandLineTools.isTranslocated(bundle) {
                    Text(AgentCommandLineTools.translocatedSentence).foregroundStyle(.secondary)
                } else {
                    ForEach(Self.configurations, id: \.self) { format in
                        configurationRow(format)
                    }
                }
            } else {
                Text("This copy of Arch does not run from an app bundle, so it has no arch-cli or arch-mcp to link or configure.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Command-Line Tools")
        } footer: {
            aiFootnote("Install links both tools into a folder on your PATH inside your home folder, ~/.local/bin first, so that terminals and agents run them by name; Arch replaces and removes only links into Arch. Arch never edits Claude Code's or Codex's settings: run the Claude Code command in a terminal, or add the table to Codex's config.toml. Either reaches Arch only while Allow Outside Clients is on.")
        }
    }

    @ViewBuilder private var linksRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isReadingPath {
                Text("Reading PATH from your login shell\u{2026}").foregroundStyle(.secondary)
            } else if tools == nil {
                Text("Arch could not check the links on your PATH.").foregroundStyle(.secondary)
            } else if installed.isEmpty {
                Text("Not linked into a folder on your PATH.").foregroundStyle(.secondary)
            } else {
                Text("Linked on your PATH:")
                ForEach(installed, id: \.location.path) { pathText(AgentCommandLineTools.line($0)) }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if let outcome {
                Text(outcome).font(.callout).foregroundStyle(.secondary)
            }
        }
        HStack {
            Spacer()
            Button("Remove") { remove() }
                .disabled(isReadingPath || installed.isEmpty)
            if !AgentCommandLineTools.isTranslocated(bundle) {
                Button("Install Command-Line Tools\u{2026}") { Task { await prepareInstall() } }
                    .disabled(isReadingPath)
            }
        }
    }

    private func configurationRow(_ format: AgentMCPConfigurationFormat) -> some View {
        let text = AgentMCPConfiguration.text(format, mcpPath: bundle.mcpExecutableURL.path)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(format.title)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            pathText(text)
        }
    }

    private func pathText(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }

    /// Reads the login shell's PATH and the links already on it. A failed read leaves `tools` nil, and Install reads again.
    private func readTools() async {
        isReadingPath = true
        defer { isReadingPath = false }
        guard let home = AgentLinkInstaller.userHomeFolder else {
            problem = "Arch could not read your home folder."
            return
        }
        guard let searchPath = await AILoginShell.path() else {
            problem = AgentCommandLineTools.unreadPathSentence(bundle: bundle)
            return
        }
        let tools = AgentCommandLineTools(bundle: bundle, homeFolder: home, searchPath: searchPath)
        self.tools = tools
        installed = tools.installedLinks()
    }

    /// Picks the folder and shows both paths for confirmation before anything is written.
    private func prepareInstall() async {
        outcome = nil
        problem = nil
        if tools == nil { await readTools() }
        guard let tools else { return }
        do {
            pendingLinks = try tools.plannedLinks()
            isConfirmingInstall = true
        } catch {
            problem = sentence(for: error)
        }
    }

    private func install(_ links: [AgentLinkInstaller.Link]) {
        guard let tools, !links.isEmpty else { return }
        do {
            try tools.install(links)
            outcome = tools.installedSentence(for: links)
            problem = nil
        } catch {
            problem = sentence(for: error)
        }
        installed = tools.installedLinks()
    }

    private func remove() {
        guard let tools else { return }
        outcome = nil
        problem = nil
        do {
            let removed = try tools.removeLinks()
            outcome = removed.isEmpty ? "No links to Arch's tools were found." : "Removed \(removed.map(\.path).formatted(.list(type: .and)))."
        } catch {
            problem = sentence(for: error)
        }
        installed = tools.installedLinks()
    }

    private func sentence(for error: Error) -> String {
        (error as? AgentLinkInstaller.Failure).map { AgentCommandLineTools.sentence(for: $0, bundle: bundle) } ?? error.localizedDescription
    }
}

// MARK: - Skills

/// The skills part of Settings ▸ AI ▸ Agents apart from its view, for one bundle and the login shell's environment: where the entry skill goes for Claude Code and Codex, its state there, what each row offers, and the sentences the section shows. `AgentSkillInstaller` makes every decision about folders and files.
struct AgentSkillPlaces {
    /// The rows that offer Install: Claude Code's skill folder, and Codex's in `$HOME/.agents/skills` only, since Codex lists the skill twice when the folder under `CODEX_HOME` holds a copy too.
    static let targets: [AgentSkillInstaller.Target] = [.claude, .codex]

    /// The bundle's `arch-cli`, which the skill names.
    let cliPath: String
    let skill: AgentSkill
    let installer: AgentSkillInstaller
    /// Whether macOS runs the bundle from a temporary folder, whose `arch-cli` path a skill must not name.
    let isTranslocated: Bool

    /// `environment` is the login shell's, since the app's own lacks the `CLAUDE_CONFIG_DIR` and `CODEX_HOME` that a profile exports; `accountHomeFolder` stands in for an unset `HOME`.
    init(bundle: AgentBundleLayout, accountHomeFolder: URL, environment: [String: String]) {
        cliPath = bundle.cliExecutableURL.path
        skill = AgentHarness.entrySkill(cliPath: cliPath)
        installer = AgentSkillInstaller(accountHomeFolder: accountHomeFolder, environment: environment)
        isTranslocated = AgentCommandLineTools.isTranslocated(bundle)
    }

    /// A row of the section: a tool's folder and the state there, or why the folder cannot be named, with the buttons the row offers and its sentence.
    struct Row: Equatable {
        var target: AgentSkillInstaller.Target
        var place: Place
        var actions: [Action]
        var sentence: String

        var destination: AgentSkillInstaller.Destination? {
            guard case .found(let destination, _) = place else { return nil }
            return destination
        }
    }

    /// Claude Code's and Codex's rows, and the folder under `CODEX_HOME` while it holds a skill of that name, as `arch-cli skills install --target codex-home` writes it, since Codex reads that one too, unless it is Codex's row's folder itself. That row offers only Remove, and Codex's row offers no Install meanwhile, which would add a copy that Codex lists twice. A translocated bundle offers neither Install nor Update.
    func rows() -> [Row] {
        var rows = Self.targets.map(row(for:))
        let codexHome = row(for: .codexHome)
        guard case .found(let destination, let state) = codexHome.place, state != .absent,
              !rows.contains(where: { $0.destination?.folder.path == destination.folder.path }) else { return rows }
        if let index = rows.firstIndex(where: { $0.target == .codex }), case .found(_, .absent) = rows[index].place {
            rows[index].actions = []
            rows[index].sentence = Self.codexHomeCopySentence
        }
        rows.append(codexHome)
        return rows
    }

    static let codexHomeCopySentence = "Not installed here. Codex reads the skill under CODEX_HOME, and would list a second copy here twice."

    /// A tool's row with the buttons its state offers; Settings writes nothing under `CODEX_HOME`, and nothing that names a translocated bundle.
    private func row(for target: AgentSkillInstaller.Target) -> Row {
        let place = place(for: target)
        switch place {
        case .found(_, let state):
            var actions = Self.actions(for: state)
            if target == .codexHome || isTranslocated { actions.removeAll { $0 != .remove } }
            return Row(target: target, place: place, actions: actions, sentence: Self.sentence(for: state))
        case .unresolved(let problem):
            return Row(target: target, place: place, actions: [], sentence: problem)
        }
    }

    /// A tool's row: the skill's folder and the state there, or why the folder cannot be named, as when a variable is not an absolute path.
    enum Place: Equatable {
        case found(AgentSkillInstaller.Destination, AgentSkillInstaller.State)
        case unresolved(String)
    }

    enum Action: Hashable {
        case install, update, remove

        var buttonTitle: String {
            switch self {
            case .install: return "Install\u{2026}"
            case .update: return "Update\u{2026}"
            case .remove: return "Remove"
            }
        }
    }

    func place(for target: AgentSkillInstaller.Target) -> Place {
        do {
            let destination = try installer.destination(for: .target(target), skillName: skill.name)
            return .found(destination, installer.state(of: destination, skill: skill))
        } catch {
            return .unresolved(Self.sentence(for: error))
        }
    }

    /// What a row offers: Install where no copy is, Remove and Update for an outdated copy, Remove for a current one, and nothing for a folder that Arch leaves alone.
    static func actions(for state: AgentSkillInstaller.State) -> [Action] {
        switch state {
        case .absent: return [.install]
        case .current: return [.remove]
        case .outdated: return [.remove, .update]
        case .modified, .foreign: return []
        }
    }

    static func sentence(for state: AgentSkillInstaller.State) -> String {
        switch state {
        case .absent: return "Not installed."
        case .current: return "Installed, with this Arch's text."
        case .outdated: return "Installed, but older than this Arch or written by a copy of Arch elsewhere."
        case .modified: return "Arch's copy with changes made after Arch wrote it, which Arch leaves alone."
        case .foreign: return "A folder that Arch did not write, which Arch leaves alone."
        }
    }

    /// What the confirmation shows before Install or Update writes: the file, and the `arch-cli` that the skill names.
    func confirmation(for action: Action, at destination: AgentSkillInstaller.Destination) -> String {
        switch action {
        case .update: return "Arch replaces its copy at \(destination.file.path) with this Arch's skill, which names \(cliPath)."
        case .install, .remove: return "Arch writes its skill to \(destination.file.path), a copy that names \(cliPath)."
        }
    }

    /// Writes the skill, or replaces Arch's earlier copy; the installer checks the folder again first.
    func install(at destination: AgentSkillInstaller.Destination) throws {
        try installer.install(skill, at: [destination])
    }

    /// Removes Arch's unchanged copy and returns whether there was one.
    func remove(at destination: AgentSkillInstaller.Destination) throws -> Bool {
        try installer.remove(at: destination)
    }

    static func installedSentence(at destination: AgentSkillInstaller.Destination, for target: AgentSkillInstaller.Target) -> String {
        "Wrote \(destination.file.path). New \(target.title) sessions read it."
    }

    static func removedSentence(at destination: AgentSkillInstaller.Destination, removed: Bool) -> String {
        removed ? "Removed \(destination.folder.path)." : "No skill of Arch's is at \(destination.folder.path)."
    }

    /// The installer's sentence as Settings says it: Arch, not arch-cli, leaves the folder alone.
    static func sentence(for error: Error) -> String {
        guard let failure = error as? AgentSkillInstaller.Failure else { return error.localizedDescription }
        switch failure {
        case .insideAppBundle(let path): return "\(path) is inside an app bundle, whose signature covers its files, so Arch leaves it alone."
        case .foreignFolder(let path): return "\(path) holds files that Arch did not write, so Arch leaves it alone."
        case .modifiedSkill(let path): return "\(path) holds Arch's skill with changes made after Arch wrote it, so Arch leaves it alone."
        case .notAbsolute, .notAFolder, .system: return failure.message
        }
    }

    /// What the section says when it cannot read the login shell's environment, and so cannot tell where the tools read skills: the bundle's commands that write and remove the skill with a terminal's environment.
    static func unreadEnvironmentSentence(bundle: AgentBundleLayout) -> String {
        let command = { (action: String) in AgentMCPConfiguration.shellCommand([bundle.cliExecutableURL.path, "skills", action, "--target", "claude", "--target", "codex"]) }
        return "Arch could not read your login shell's environment, which tells where Claude Code and Codex read skills. In a terminal, \(command("install")) writes the skill, and \(command("remove")) removes Arch's copies."
    }
}

/// Settings ▸ AI ▸ Agents ▸ Skills: for Claude Code and Codex, the entry skill's folder from the login shell's environment and the state there, with Install, which shows the file before writing it, Update for an outdated copy, and Remove, and the folder under `CODEX_HOME` with Remove while it holds a skill of that name. A folder Arch did not write, and Arch's copy changed since Arch wrote it, show that Arch leaves them alone, with no buttons; a translocated bundle offers only Remove.
struct AgentSkillsSection: View {
    var bundle = AgentBundleLayout(bundleURL: Bundle.main.bundleURL)
    /// nil until the login shell's environment is read, and while it cannot be.
    @State private var places: AgentSkillPlaces?
    @State private var isReading = true
    @State private var rows: [AgentSkillPlaces.Row] = []
    @State private var pendingWrite: PendingWrite?
    @State private var isConfirmingWrite = false
    @State private var outcome: String?
    @State private var problem: String?

    /// An Install or Update waiting for its confirmation.
    private struct PendingWrite {
        var action: AgentSkillPlaces.Action
        var target: AgentSkillInstaller.Target
        var destination: AgentSkillInstaller.Destination
    }

    var body: some View {
        Section {
            if AgentCommandLineTools.hasTools(bundle) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The arch-browser skill tells agents how to use Arch, with arch-cli at")
                    AgentPathText(bundle.cliExecutableURL.path)
                }
                .task { await read() }
                .alert(pendingWrite.map { "\($0.action == .update ? "Update" : "Install") the Skill for \($0.target.title)?" } ?? "", isPresented: $isConfirmingWrite, presenting: pendingWrite) { pending in
                    Button(pending.action == .update ? "Update" : "Install") { write(pending) }
                    Button("Cancel", role: .cancel) {}
                } message: { pending in
                    Text(places?.confirmation(for: pending.action, at: pending.destination) ?? "")
                }
                if isReading {
                    Text("Reading your login shell's environment\u{2026}").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.target) { row in
                    AgentSkillRow(row: row) { action, destination in perform(action, for: row.target, at: destination) }
                }
                if AgentCommandLineTools.isTranslocated(bundle) {
                    Text(AgentCommandLineTools.translocatedSentence).foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                } else if let outcome {
                    Text(outcome).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("This copy of Arch does not run from an app bundle, so it has no arch-cli for a skill to name.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Skills")
        } footer: {
            aiFootnote("Install copies Arch's skill into the folder that Claude Code or Codex reads, so that their sessions in a terminal know how to use Arch; new sessions read it. Arch replaces and removes only its own copies that nobody changed. Codex also reads skills under CODEX_HOME, but lists a skill found in both folders twice, so Arch writes only to ~/.agents/skills, and not while a skill of that name is under CODEX_HOME.")
        }
    }

    /// Reads the login shell's environment and each tool's folder. A failed read leaves the rows out and says how to install from a terminal; the next showing of the section reads again.
    private func read() async {
        isReading = true
        problem = nil
        defer { isReading = false }
        guard let home = AgentLinkInstaller.userHomeFolder else {
            problem = "Arch could not read your home folder."
            return
        }
        guard let environment = await AILoginShell.environment() else {
            problem = AgentSkillPlaces.unreadEnvironmentSentence(bundle: bundle)
            return
        }
        places = AgentSkillPlaces(bundle: bundle, accountHomeFolder: home, environment: environment)
        refresh()
    }

    private func refresh() {
        guard let places else { return }
        rows = places.rows()
    }

    /// Install and Update show the file first; Remove removes Arch's unchanged copy at the path the row shows.
    private func perform(_ action: AgentSkillPlaces.Action, for target: AgentSkillInstaller.Target, at destination: AgentSkillInstaller.Destination) {
        outcome = nil
        problem = nil
        switch action {
        case .install, .update:
            pendingWrite = PendingWrite(action: action, target: target, destination: destination)
            isConfirmingWrite = true
        case .remove:
            guard let places else { return }
            do {
                outcome = AgentSkillPlaces.removedSentence(at: destination, removed: try places.remove(at: destination))
            } catch {
                problem = AgentSkillPlaces.sentence(for: error)
            }
            refresh()
        }
    }

    private func write(_ pending: PendingWrite) {
        guard let places else { return }
        do {
            try places.install(at: pending.destination)
            outcome = AgentSkillPlaces.installedSentence(at: pending.destination, for: pending.target)
        } catch {
            problem = AgentSkillPlaces.sentence(for: error)
        }
        refresh()
    }
}

/// One tool's row in the Skills section: the skill's folder, the row's sentence, and the buttons it offers.
struct AgentSkillRow: View {
    let row: AgentSkillPlaces.Row
    let perform: (AgentSkillPlaces.Action, AgentSkillInstaller.Destination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.target.title)
                Spacer()
                if let destination = row.destination {
                    ForEach(row.actions, id: \.self) { action in
                        Button(action.buttonTitle) { perform(action, destination) }
                    }
                }
            }
            if let destination = row.destination {
                AgentPathText(destination.folder.path)
            }
            Text(row.sentence).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A path or command in Settings ▸ AI ▸ Agents: small monospaced text that can be selected and copied.
struct AgentPathText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}
