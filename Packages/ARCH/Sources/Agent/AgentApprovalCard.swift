// A card in the agent panel (docs/agents.md, Approval interface): it leads with the facts the host computed (the step in a sentence, the tab and site, the element marked on a capture of the viewport, and the exact text or address that would be sent), then the agent's own words under "The agent says:". A card whose agent text names a secret leads with Arch's warning. No card has a default button, so Return and Space answer none; on a sensitive card, Allow takes only a pointer click that no other program posted, and for outside clients Touch ID or the login password as well (`AgentApprovals.answer(_:with:)`).
import AgentControl
import AppKit
import SwiftUI

struct AgentApprovalCard: View {
    let approval: AgentApproval
    let approvals: AgentApprovals
    let showTab: () -> Void
    @State private var reply = ""
    @State private var isReplying = false
    @State private var written = ""
    @State private var chosenTab: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if approval.namesSecret {
                Text(AgentPolicy.secretWarning)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(approval.action)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(approval.clientName)
                if let handle = approval.tabHandle, approval.tabID != nil {
                    Button("Show \(handle)", action: showTab).buttonStyle(.link)
                }
                if !approval.rules.isEmpty {
                    Text(approval.rules.map(\.rawValue).joined(separator: ", "))
                        .help(approval.rules.map { AgentPolicy.entry($0).sentence }.joined(separator: " "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let capture = approval.capture {
                Image(nsImage: capture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("The page, with the element marked")
            }
            if let exact = approval.exactText {
                Text(exact)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            if let says = approval.agentSays, !says.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The agent says:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(says)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            inputs
            buttons
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(approval.isSensitive ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1)))
    }

    @ViewBuilder private var inputs: some View {
        switch approval.kind {
        case .question(let choices):
            if !choices.isEmpty {
                FlowButtons(titles: choices) { answer(.answer($0)) }
            }
            TextField("Your answer", text: $written, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        case .handToUser:
            Text("Do the step in the tab, then choose Done.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("A note for the agent (optional)", text: $written, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        case .requestTab(let tabs, _):
            if tabs.isEmpty {
                Text("You have no open tab in this Persona.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Tab", selection: $chosenTab) {
                    Text("Choose a tab").tag(UUID?.none)
                    ForEach(tabs) { tab in Text([tab.title, tab.host].compactMap { $0 }.joined(separator: " \u{2014} ")).tag(Optional(tab.id)) }
                }
                .labelsHidden()
            }
        default:
            EmptyView()
        }
        if isReplying {
            TextField("Tell the agent what to do instead", text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            switch approval.kind {
            case .question:
                AgentPointerButton(title: "Cancel", requiresPointer: false) { answer(.cancel("")) }
                AgentPointerButton(title: "Answer", requiresPointer: false) { answer(.answer(written)) }
                    .disabled(written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .handToUser:
                AgentPointerButton(title: "Cancel", requiresPointer: false) { answer(.cancel(written)) }
                AgentPointerButton(title: "Done", requiresPointer: true) { answer(.done(written)) }
            case .requestTab:
                AgentPointerButton(title: "Don\u{2019}t Share", requiresPointer: false) { answer(.deny) }
                AgentPointerButton(title: "Share", requiresPointer: true) { if let chosenTab { answer(.tab(chosenTab)) } }
                    .disabled(chosenTab == nil)
            default:
                ForEach(Array(approval.offers.enumerated()), id: \.offset) { _, offer in
                    if case .reply = offer {
                        AgentPointerButton(title: isReplying ? "Send Reply" : offer.title(site: approval.site), requiresPointer: false) {
                            if isReplying, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer(.reply(reply)) } else { isReplying = true }
                        }
                    } else {
                        AgentPointerButton(title: offer.title(site: approval.site), requiresPointer: offer.allows && approval.isSensitive) { answer(offer) }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func answer(_ answer: AgentApprovalAnswer) {
        Task { await approvals.answer(approval.id, with: answer) }
    }
}

/// Answers as buttons, wrapping to more rows when they do not fit.
private struct FlowButtons: View {
    let titles: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(titles, id: \.self) { title in
                AgentPointerButton(title: title, requiresPointer: false) { action(title) }
            }
        }
    }
}

/// A button that never takes the keyboard focus and has no key equivalent unless given one, so that Return and Space cannot press it. With `requiresPointer`, it also refuses anything but a pointer click that no other program posted, such as an accessibility press or a click a script posted (`AgentPointerCheck`).
struct AgentPointerButton: NSViewRepresentable {
    let title: String
    var keyEquivalent = ""
    let requiresPointer: Bool
    let action: () -> Void

    init(title: String, keyEquivalent: String = "", requiresPointer: Bool, action: @escaping () -> Void) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.requiresPointer = requiresPointer
        self.action = action
    }

    func makeNSView(context: Context) -> NSButton {
        let button = PointerButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .push
        button.keyEquivalent = keyEquivalent
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = context.environment.isEnabled
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject {
        var parent: AgentPointerButton

        init(parent: AgentPointerButton) {
            self.parent = parent
        }

        @objc func press() {
            if parent.requiresPointer, !AgentPointerCheck.isPointerClick(NSApp.currentEvent) { return }
            parent.action()
        }
    }

    private final class PointerButton: NSButton {
        override var acceptsFirstResponder: Bool { false }
    }
}

/// Whether the event that pressed a button is a pointer click, and not one another program posted (docs/agents.md, Approval interface). A click a program posts with Quartz events names that program as its source (`CGEventField.eventSourceUnixProcessID`); Arch refuses one from a program of this user outside the system's folders, and from `osascript` and System Events, while it takes clicks whose source is the system: none, WindowServer, a process of another user, or the system's own apps, such as Universal Control and VoiceOver.
enum AgentPointerCheck {
    static func isPointerClick(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseUp || event.type == .leftMouseDown else { return false }
        guard let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) else { return true }
        return !isPostedByAnotherProgram(source: pid_t(truncatingIfNeeded: source))
    }

    /// The programs whose posted clicks Arch refuses, by the path of their source process.
    static func isPostedByAnotherProgram(source: pid_t, path: (pid_t) -> String? = { AgentSystemProcessInspector().launchPath(of: $0) }) -> Bool {
        guard source > 0, source != getpid(), let path = path(source) else { return false }
        if path == "/usr/bin/osascript" || path.hasSuffix("/System Events.app/Contents/MacOS/System Events") { return true }
        return !["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}
