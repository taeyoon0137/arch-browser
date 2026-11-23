// The outside-client grant sheet opens on the front main window (docs/agents.md, Outside clients).
// It names the client and executable, explains when programs in its shell share access, and describes what the grant lets them read.
// Persona, space, access, extra scopes, and duration start at their safe defaults. No button is the default: Return and Space do nothing.
// Allow requires a pointer click that no other program posted (`AgentPointerCheck`). A background notification contains no page content.
// An unanswered sheet closes as Don't Allow after the outside-client approval window.
import AgentControl
import AppKit
import SwiftUI
import UserNotifications

@MainActor final class AgentGrantSheetPresenter: AgentGrantPrompting {
    private weak var host: (any AgentBrowserHost)?
    /// Each open sheet's way to close as an answer.
    private var openSheets: [UUID: (AgentGrantChoice?) -> Void] = [:]

    init(host: any AgentBrowserHost) {
        self.host = host
    }

    func ask(_ request: AgentGrantRequest) async -> AgentGrantChoice? {
        guard let parent = host?.windowForSheet() else { return nil }
        if !NSApp.isActive { Self.postNotification() }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            var sheet: NSWindow?
            let finish: (AgentGrantChoice?) -> Void = { [weak self] choice in
                guard let self, self.openSheets.removeValue(forKey: id) != nil else { return }
                if let sheet { parent.endSheet(sheet) }
                continuation.resume(returning: choice)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: AgentGrantSheetView(request: request, finish: finish)))
            sheet = window
            openSheets[id] = finish
            parent.beginSheet(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(AgentLimits.outsideApprovalDefaultMinutes * 60)) {
                MainActor.assumeIsolated { finish(nil) }
            }
        }
    }

    func cancelAll() {
        for finish in Array(openSheets.values) { finish(nil) }
    }

    /// Says only that a program asks, since notifications show on the lock screen. A bare build has no notification center.
    private static func postNotification() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "A program is asking to use Arch"
            content.body = "Open Arch to allow or deny it."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

struct AgentGrantSheetView: View {
    let request: AgentGrantRequest
    let finish: (AgentGrantChoice?) -> Void
    @State private var choice = AgentGrantChoice()

    private var personaName: String {
        switch choice.persona {
        case .agents: return "Agents"
        case .existing(let id): return request.personas.first { $0.id == id }?.name ?? ""
        }
    }

    private var spaces: [AgentSpaceInfo] { request.spaces(of: choice.persona) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow \u{201C}\(request.client.displayName)\u{201D} to use Arch?")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.client.executablePath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if request.client.isInterpreter {
                    Text("\(request.client.name) runs scripts, and this access covers every script it runs.")
                }
                if request.client.reachedThroughShell {
                    Text(AgentClientIdentity.shellNote)
                }
                if request.client.isBoundToProcess {
                    Text("This access ends when this \(request.client.name) process ends.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Form {
                Picker("Persona", selection: $choice.persona) {
                    Text("Agents (no sign-ins)").tag(AgentGrantChoice.PersonaChoice.agents)
                    ForEach(request.personas) { persona in
                        Text(persona.name).tag(AgentGrantChoice.PersonaChoice.existing(persona.id))
                    }
                }
                if spaces.isEmpty {
                    LabeledContent("Space", value: "A new space")
                } else {
                    Picker("Space", selection: Binding(get: { choice.spaceID ?? spaces.first?.id }, set: { choice.spaceID = $0 })) {
                        ForEach(spaces) { space in Text(space.name).tag(Optional(space.id)) }
                    }
                }
                Picker("Access", selection: $choice.level) {
                    ForEach(AgentAccessLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Search history", isOn: $choice.scopes.searchHistory)
                Toggle(isOn: $choice.scopes.startTasks) {
                    labeled("Start agent tasks on your AI subscription",
                            detail: "Up to \(AgentGrant.defaultRunsPerDay) agent runs a day, which Settings \u{25B8} AI \u{25B8} Agents can change.")
                }
                Toggle(isOn: $choice.scopes.watchEvents) {
                    labeled("Watch browser events", detail: Self.watchSentence(persona: personaName))
                }
                Picker("Duration", selection: $choice.duration) {
                    ForEach(AgentGrantChoice.Duration.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.columns)
            Text(explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                AgentPointerButton(title: "Don\u{2019}t Allow", keyEquivalent: "\u{1B}", requiresPointer: false) { finish(nil) }
                AgentPointerButton(title: choice.needsAuthentication ? "Allow\u{2026}" : "Allow", requiresPointer: true) { finish(normalized) }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: choice.persona) { choice.spaceID = nil }
    }

    /// A toggle's title with its sentence below it, shown whether or not the toggle is on, as the sheet's other captions show.
    private func labeled(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What Watch Browser Events shows the client (`docs/hooks.md`, Grants).
    static func watchSentence(persona: String) -> String {
        "See when tabs open, load, change, and close in \(persona), with their sites. Never their titles or pages."
    }

    /// The choice with the space the picker shows.
    private var normalized: AgentGrantChoice {
        var result = choice
        if result.spaceID == nil { result.spaceID = spaces.first?.id }
        return result
    }

    private var explanation: String {
        var sentences: [String] = []
        if choice.persona == .agents {
            sentences.append("The client reads pages in the Agents Persona, which has no sign-ins until you sign in there.")
        } else {
            sentences.append("The client can read pages with your sign-ins in the \(personaName) Persona.")
        }
        if choice.scopes.searchHistory { sentences.append("It can search your browsing history, which every Persona shares.") }
        if choice.scopes.watchEvents { sentences.append("It can follow which sites your tabs in the \(personaName) Persona visit, as they visit them.") }
        sentences.append("Pages it reads may contain text aimed at it. If it can run commands on your Mac, a page could try to make it do so, and Arch cannot prevent that.")
        sentences.append("Steps that need you still ask in Arch.")
        if choice.needsAuthentication { sentences.append("Allowing asks for Touch ID or your login password.") }
        return sentences.joined(separator: " ")
    }
}
