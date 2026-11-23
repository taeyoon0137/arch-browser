// Cards in the agent panel show the host's facts before the agent's own words (docs/agents.md, Approval interface).
// The facts name the step, tab, site, marked viewport element, and exact text, address, or tab name to send.
// A card warns first when the agent's words name a secret. The P19 card explains what Allow for This Tab permits.
// No card has a default button, so Return and Space answer none.
// Sensitive Allow, Share, and Done require a pointer click on their button that no other program posted (`AgentPointerCheck`).
// For outside clients, sensitive Allow and Share also require Touch ID or the login password (`AgentApprovals.answer(_:with:)`).
import AgentControl
import AppKit
import Darwin
import Security
import SwiftUI

struct AgentApprovalCard: View {
    let approval: AgentApproval
    @ObservedObject var approvals: AgentApprovals
    let showTab: () -> Void
    @State private var reply = ""
    @State private var isReplying = false
    @State private var written = ""
    @State private var chosenTab: UUID?
    /// Kept here, since the facts are drawn twice: as they are, and in a scroll view.
    @State private var showsRules = false
    @State private var showsLargeCapture = false

    var body: some View {
        AgentSectionBox {
            VStack(alignment: .leading, spacing: 8) {
                // Facts that do not fit scroll inside the card, so the decision below always stays in view.
                ViewThatFits(in: .vertical) {
                    facts
                    ScrollView { facts }
                }
                decision
            }
        }
        .overlay(RoundedRectangle(cornerRadius: AgentPanelMetrics.boxRadius).strokeBorder(approval.isSensitive ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1)))
    }

    /// The host's facts, then the agent's own words.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            if approval.namesSecret {
                Text(AgentPolicy.secretWarning)
                    .font(.system(size: AgentPanelMetrics.bodySize, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(approval.action)
                .font(.system(size: AgentPanelMetrics.bodySize, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            AgentDetailRow(title: "Requested by") {
                Text(approval.clientName).lineLimit(1).truncationMode(.tail).help(approval.clientName)
                if let handle = approval.tabHandle, approval.tabID != nil {
                    Button(localized("Show \(handle)"), action: showTab).buttonStyle(.link)
                }
            }
            if !approval.rules.isEmpty {
                DisclosureGroup(isExpanded: $showsRules) {
                    Text(approval.rules.map { AgentPolicy.entry($0).sentence }.joined(separator: " "))
                        .font(.system(size: AgentPanelMetrics.detailSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Why Arch asks", bundle: .module)
                        .font(.system(size: AgentPanelMetrics.detailSize))
                        .foregroundStyle(.secondary)
                }
            }
            if let capture = approval.capture {
                Button { showsLargeCapture = true } label: {
                    Image(nsImage: capture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: AgentPanelMetrics.captureMaxHeight)
                }
                .buttonStyle(.plain)
                .help(localized("Show Larger"))
                .accessibilityLabel(localized("The page, with the element marked"))
                .accessibilityHint(localized("Shows the capture larger"))
                .popover(isPresented: $showsLargeCapture) {
                    Image(nsImage: capture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(capture.size.width, AgentPanelMetrics.largeCaptureMaxSide),
                               maxHeight: min(capture.size.height, AgentPanelMetrics.largeCaptureMaxSide))
                        .padding(AgentPanelMetrics.boxPadding)
                }
            }
            if let exactText = approval.exactText {
                exactTextView(exactText)
                    .font(.system(size: AgentPanelMetrics.supportingSize).monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(AgentPanelFill.exactText))
            }
            if let note = approval.exactTextNote {
                Text(note)
                    .font(.system(size: AgentPanelMetrics.detailSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let says = approval.agentSays, !says.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The agent says:", bundle: .module)
                        .font(.system(size: AgentPanelMetrics.detailSize))
                        .foregroundStyle(.secondary)
                    Text(says)
                        .font(.system(size: AgentPanelMetrics.bodySize))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .question(let choices) = approval.kind, !choices.isEmpty {
                FlowButtons(titles: choices) { answer(.answer($0)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the user answers with: what the answer permits, its fields, and its buttons.
    private var decision: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputs
            buttons
        }
    }

    /// The exact text, and for an address the session has not seen (P13), the parts no page or the user showed, marked.
    private func exactTextView(_ text: String) -> Text {
        guard let question = approval.addressQuestion else { return Text(verbatim: text) }
        let marked = question.markedAddress
        var address = AttributedString(marked.text)
        for part in marked.unseen {
            guard let range = Range(part, in: address) else { continue }
            address[range].backgroundColor = Color.orange.opacity(0.3)
        }
        return Text(address)
    }

    private var questionAnswer: Binding<String> {
        Binding(get: { approvals.draftAnswer(to: approval.id) }, set: { approvals.setDraftAnswer($0, to: approval.id) })
    }

    @ViewBuilder private var inputs: some View {
        switch approval.kind {
        case .question:
            // The offered answers sit with the facts above, which scroll when they are many.
            TextField(localized("Your answer"), text: questionAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        case .handToUser:
            Text("Do the step in the tab, then choose Done.", bundle: .module)
                .font(.system(size: AgentPanelMetrics.detailSize))
                .foregroundStyle(.secondary)
            TextField(localized("A note for the agent (optional)"), text: $written, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        case .renameSharedTab:
            Text(verbatim: "Allow for This Tab lets \(approval.clientName) rename this tab again without asking. A name you give the tab yourself always stays.")
                .font(.system(size: AgentPanelMetrics.detailSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .shareSessionTab(let tabs), .requestTab(let tabs, _):
            if tabs.isEmpty {
                Text("No eligible tabs to share in this Persona.", bundle: .module)
                    .font(.system(size: AgentPanelMetrics.detailSize))
                    .foregroundStyle(.secondary)
            } else {
                let labels = AgentTabInfo.attachmentLabels(for: tabs)
                Picker(localized("Tab to share"), selection: $chosenTab) {
                    Text("Choose a tab", bundle: .module).tag(UUID?.none)
                    ForEach(tabs) { tab in
                        Text(verbatim: labels[tab.id] ?? tab.attachmentLabel).tag(Optional(tab.id))
                    }
                }
                // The chosen tab's full address, which the user reviews before Share.
                if let selected = tabs.first(where: { $0.id == chosenTab }) {
                    Text(verbatim: selected.attachmentAddress ?? selected.attachmentLabel)
                        .font(.system(size: AgentPanelMetrics.supportingSize).monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(AgentPanelFill.exactText))
                }
            }
        default:
            EmptyView()
        }
        if isReplying {
            TextField(localized("Tell the agent what to do instead"), text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// One row of buttons at the trailing edge, or a column of them when one row does not fit the column.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                buttonList
            }
            VStack(alignment: .trailing, spacing: 4) {
                buttonList
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .controlSize(.small)
    }

    @ViewBuilder private var buttonList: some View {
        switch approval.kind {
        case .question:
            AgentPointerButton(title: "Cancel", requiresPointer: false) { answer(.cancel("")) }
            AgentPointerButton(title: "Answer", requiresPointer: false) { answer(.answer(questionAnswer.wrappedValue)) }
                .disabled(questionAnswer.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .handToUser:
            AgentPointerButton(title: "Cancel", requiresPointer: false) { answer(.cancel(written)) }
            AgentPointerButton(title: "Done", requiresPointer: true) { answer(.done(written)) }
        case .shareSessionTab, .requestTab:
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
                    AgentPointerButton(title: offer.title(site: approval.site), requiresPointer: offer.allows && approval.isSensitive, inWindow: { answer(offer, in: $0) })
                }
            }
        }
    }

    /// Answers in the card's window, where a file chooser's Allow opens Arch's panel (P7).
    private func answer(_ answer: AgentApprovalAnswer, in window: NSWindow? = nil) {
        Task { await approvals.answer(approval.id, with: answer, in: window) }
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

/// A button that never takes the keyboard focus and has no key equivalent unless given one, so that Return and Space cannot press it. With `requiresPointer`, it also refuses anything but the pointer click it is tracking, when no other program posted it: an accessibility press, `performClick`, or a click a script posted (`AgentPointerCheck`).
struct AgentPointerButton: NSViewRepresentable {
    let title: String
    var keyEquivalent = ""
    let requiresPointer: Bool
    /// What the press does, with the window of the pressed button.
    let action: (NSWindow?) -> Void

    init(title: String, keyEquivalent: String = "", requiresPointer: Bool, action: @escaping () -> Void) {
        self.init(title: title, keyEquivalent: keyEquivalent, requiresPointer: requiresPointer, inWindow: { _ in action() })
    }

    /// A button whose action receives the window it was pressed in.
    init(title: String, keyEquivalent: String = "", requiresPointer: Bool, inWindow action: @escaping (NSWindow?) -> Void) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.requiresPointer = requiresPointer
        self.action = action
    }

    func makeNSView(context: Context) -> NSButton {
        let button = AgentPointerNSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press(_:)))
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

        @objc func press(_ sender: Any?) {
            if parent.requiresPointer, (sender as? AgentPointerNSButton)?.isPressedByPointer != true { return }
            parent.action((sender as? NSView)?.window)
        }
    }
}

/// The button behind `AgentPointerButton`. It keeps the mouse-down that AppKit's tracking loop runs for, which only a click on the button starts, so that an action sent without one, as by an accessibility press or `performClick`, reads as no pointer click whatever event came last.
final class AgentPointerNSButton: NSButton {
    private var trackedMouseDown: NSEvent?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        trackedMouseDown = event
        defer { trackedMouseDown = nil }
        super.mouseDown(with: event)
    }

    /// Whether the action comes from a pointer click on this button that no other program posted: the mouse-down being tracked, in the button's window and within its bounds, and the mouse-up that ends it.
    var isPressedByPointer: Bool {
        AgentPointerCheck.isPointerClick(down: trackedMouseDown, up: NSApp.currentEvent, in: self)
    }
}

/// Whether a click is a person's pointer click, and not one another program posted (docs/agents.md, Approval interface). A click a program posts with Quartz events names that program as its source (`CGEventField.eventSourceUnixProcessID`). Arch reads that process by its running code, never by the path it was started with, which the starter chooses: it takes a click whose source is none, Arch, or a process of another user, such as the window server, and from a process of this user only when Security finds its code valid, signed by Apple, and one of the system's own programs that move the pointer for a person (`systemPointerPrograms`). It refuses every other program of this user, `osascript`, System Events, and Script Editor among them, and a source it cannot read, as one that exited after it posted.
enum AgentPointerCheck {
    /// The signing identifiers of the system's programs that post a person's clicks: Universal Control, VoiceOver, Dwell Control, the accessibility interface server, and Screen Sharing's agent.
    static let systemPointerPrograms: Set<String> = ["com.apple.universalcontrol", "com.apple.VoiceOver", "com.apple.DwellControl", "com.apple.AccessibilityUIServer", "com.apple.screensharing.agent"]

    /// What Arch reads of the process an event names as its source.
    struct Source: Equatable, Sendable {
        var userID: uid_t
        /// The signing identifier of its running code when Security finds the code valid and signed by Apple (`anchor apple`), else nil.
        var appleIdentifier: String?
    }

    /// Whether `down` is a left mouse-down in the button's window and within its bounds, and neither it nor the mouse-up that ends it came from another program.
    static func isPointerClick(down: NSEvent?, up: NSEvent?, in button: NSView, read: (pid_t) -> Source? = readSource) -> Bool {
        guard let down, down.type == .leftMouseDown, let window = button.window, down.window === window,
              button.bounds.contains(button.convert(down.locationInWindow, from: nil)) else { return false }
        for event in [down, up].compactMap({ $0 }) where event.type == .leftMouseDown || event.type == .leftMouseUp {
            guard let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) else { continue }
            if isPostedByAnotherProgram(source: pid_t(truncatingIfNeeded: source), read: read) { return false }
        }
        return true
    }

    /// Whether a click whose source is this process came from a program whose posted clicks Arch refuses.
    static func isPostedByAnotherProgram(source: pid_t, read: (pid_t) -> Source? = readSource) -> Bool {
        guard source > 0, source != getpid() else { return false }
        guard let process = read(source) else { return true }
        guard process.userID == getuid() else { return false }
        return !(process.appleIdentifier.map(systemPointerPrograms.contains) ?? false)
    }

    /// The process's owner from `sysctl` (`KERN_PROC_PID`), and for a process of this user, its running code from Security; nil when the process is gone.
    static func readSource(_ processID: pid_t) -> Source? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == processID else { return nil }
        let userID = info.kp_eproc.e_ucred.cr_uid
        guard userID == getuid() else { return Source(userID: userID, appleIdentifier: nil) }
        var code: SecCode?
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: processID] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess else { return Source(userID: userID, appleIdentifier: nil) }
        return Source(userID: userID, appleIdentifier: (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String)
    }
}
