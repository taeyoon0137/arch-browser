// The first agent panel, for outside clients (docs/agents.md, In the browser ▸ The agent panel): in a window's trailing column in place of the page reader, it shows one client's steps as the host describes them, each naming its tab with a button that shows it, and the client's cards, grouped by page, which the user answers there and nowhere over the page. A step whose page text speaks to AI agents says so. The service opens the panel on the front main window when a card waits and, while Arch is in the background, posts a notification without content. In-app sessions have a panel of their own, `AgentSessionPanel` in `AgentPanel.swift`, whose cards come with plan task VII.17.1.
import AgentControl
import AppKit
import SwiftUI
import UserNotifications

/// One step of a client, as the panel shows it to the user.
public struct AgentStepRecord: Identifiable, Equatable {
    public let id: UUID
    public var date: Date
    public var sentence: String
    public var tabID: UUID?
    public var tabHandle: String?
    public var status: AgentResultStatus
    /// The result's page text has phrases addressed to AI agents.
    public var addressesAgents: Bool

    public init(id: UUID = UUID(), date: Date, sentence: String, tabID: UUID? = nil, tabHandle: String? = nil, status: AgentResultStatus, addressesAgents: Bool = false) {
        self.id = id
        self.date = date
        self.sentence = sentence
        self.tabID = tabID
        self.tabHandle = tabHandle
        self.status = status
        self.addressesAgents = addressesAgents
    }
}

/// Who a panel is about: the client's name, its access, and its place as "Persona / Space".
public struct AgentPanelOwner: Equatable {
    public var name: String
    public var access: String
    public var place: String

    public init(name: String, access: String, place: String) {
        self.name = name
        self.access = access
        self.place = place
    }
}

/// What the agent panel shows, which the service keeps and the browser host places in the windows.
@MainActor public final class AgentPanelModel: ObservableObject {
    @Published public private(set) var steps: [UUID: [AgentStepRecord]] = [:]
    @Published public private(set) var owners: [UUID: AgentPanelOwner] = [:]
    public let approvals: AgentApprovals
    /// Set by the service: shows a step's tab, and Stop, which disconnects the client.
    var showTab: (UUID) -> Void = { _ in }
    var stop: (UUID) -> Void = { _ in }
    /// The steps kept per client, in memory only.
    static let keptSteps = 300

    public init(approvals: AgentApprovals) {
        self.approvals = approvals
    }

    func record(_ step: AgentStepRecord, for ownerID: UUID) {
        var list = steps[ownerID] ?? []
        list.append(step)
        if list.count > Self.keptSteps { list.removeFirst(list.count - Self.keptSteps) }
        steps[ownerID] = list
    }

    func describe(_ owner: AgentPanelOwner, for ownerID: UUID) {
        if owners[ownerID] != owner { owners[ownerID] = owner }
    }

    /// The client whose agent folder holds a tab, or whose card is about it, for a window that selects that tab.
    public func owner(ofTab tabID: UUID) -> UUID? {
        approvals.pending.first { $0.tabID == tabID }?.ownerID ?? steps.first { $0.value.contains { $0.tabID == tabID } }?.key
    }

    /// The client whose card waited first, which a window opening the panel shows.
    public var firstWaitingOwner: UUID? { approvals.pending.first?.ownerID }
}

/// Says only that an agent waits, since notifications show on the lock screen. A bare build has no notification center.
enum AgentAttention {
    static func notify() {
        guard Bundle.main.bundleURL.pathExtension == "app", !NSApp.isActive else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "An agent is waiting for you in Arch"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

public struct AgentPanel: View {
    @ObservedObject var model: AgentPanelModel
    @ObservedObject var approvals: AgentApprovals
    let ownerID: UUID
    let close: () -> Void

    public init(model: AgentPanelModel, ownerID: UUID, close: @escaping () -> Void) {
        self.model = model
        approvals = model.approvals
        self.ownerID = ownerID
        self.close = close
    }

    private var owner: AgentPanelOwner? { model.owners[ownerID] }
    private var steps: [AgentStepRecord] { model.steps[ownerID] ?? [] }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(owner?.name ?? "Agent")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let owner {
                        Text("\(owner.access) \u{2014} \(owner.place)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Stop") { model.stop(ownerID) }
                    .controlSize(.small)
                    .help("Disconnect this client and deny its waiting requests. Its access stays.")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close Agent Panel")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 44)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if steps.isEmpty, approvals.groups(of: ownerID).isEmpty {
                            Text("The steps of this client show here, with what Arch asks you.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(steps) { step in
                            AgentStepRow(step: step) { if let tabID = step.tabID { model.showTab(tabID) } }
                        }
                        ForEach(Array(approvals.groups(of: ownerID).enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(group) { approval in
                                    AgentApprovalCard(approval: approval, approvals: approvals) { if let tabID = approval.tabID { model.showTab(tabID) } }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .onChange(of: approvals.pending.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: steps.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

private struct AgentStepRow: View {
    let step: AgentStepRecord
    let show: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(step.status == .ok ? Color.secondary : Color.orange)
                    .font(.caption)
                Text(step.sentence)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let handle = step.tabHandle, step.tabID != nil {
                    Button(handle, action: show)
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Show this tab")
                }
            }
            if step.addressesAgents {
                Text("This page contains text addressed to AI agents.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var symbol: String {
        switch step.status {
        case .ok: return "checkmark.circle"
        case .denied: return "hand.raised"
        case .refused: return "nosign"
        case .timeout, .approvalPending: return "clock"
        case .stale, .error: return "exclamationmark.triangle"
        }
    }
}
