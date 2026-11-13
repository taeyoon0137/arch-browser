// Settings ▸ AI ▸ Agents (docs/agents.md, Settings ▸ AI ▸ Agents): Allow Outside Clients with what it lets programs do, the command-line tools with their PATH links and MCP configurations, the grants with Revoke and Revoke All, and the activity log by day with filters by client and site and Clear Activity. It also says when `agent.json` was set aside or its key could not be read, and when the agent socket cannot listen.
import Agent
import AgentControl
import AI
import AppKit
import SwiftUI

struct AgentSettingsPage: View {
    @ObservedObject var service: AgentService
    @ObservedObject var activity: AgentActivityLog
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
        grantsSection
        activitySection
    }

    private var settingsNotice: String? {
        switch service.state {
        case .ready: return nil
        case .reading: return "Checking agent.json\u{2026}"
        case .replacedUnreadable: return "agent.json could not be verified, so Arch renamed it agent.json.unreadable and started with outside access off and no grants."
        case .keyUnavailable(let reason): return "Arch could not read the key that protects its agent settings from the Keychain: \(reason) Until it can, outside access is off and no grant is used."
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
        var parts = [grant.level.title, "\(persona) Persona"]
        if let space { parts.append("space \(space)") }
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
                        Text(entry.clientName)
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
                ForEach(Self.configurations, id: \.self) { format in
                    configurationRow(format)
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
            Button("Install Command-Line Tools\u{2026}") { Task { await prepareInstall() } }
                .disabled(isReadingPath)
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
