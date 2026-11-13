// Settings ▸ AI ▸ Agents, its first part (docs/agents.md, Settings ▸ AI ▸ Agents): Allow Outside Clients with what it lets programs do, the grants with Revoke and Revoke All, and the activity log by day with filters by client and site and Clear Activity. It also says when `agent.json` was set aside or its key could not be read, and when the agent socket cannot listen.
import Agent
import AgentControl
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
