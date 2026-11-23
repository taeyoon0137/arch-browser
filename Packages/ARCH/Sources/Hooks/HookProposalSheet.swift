// The hook proposal sheet shows an outside program's `arch-cli hooks add` request in Arch's front main window (`docs/hooks.md`, Hooks from outside programs).
// A background notification has no content. The sheet names the client and path, hook name, situation with Persona / Space entries, permissions, agent options, and tab-name rule.
// It shows the agent's instructions and full script read-only. No button is the default; Escape means Don't Allow.
// Allow needs a pointer click no other program posted, then the registry asks for Touch ID or the login password.
// An unanswered sheet closes as Don't Allow after the approval window. A canceled asking task, as when the program leaves, closes it the same way.
import Agent
import AgentControl
import AI
import AppKit
import Events
import SwiftUI
import UserNotifications

/// What the proposal sheet shows of a hook, made by the registry from the hook it would add.
public struct HookProposalReview: Sendable {
    public var clientName: String
    public var clientPath: String
    public var name: String
    /// The situation, such as "When a new tab loads its first page", with its places and sites.
    public var situation: String
    public var permissions: [String]
    /// The agent run's model, record, actions, and limits, one line each; empty without `agent`.
    public var agent: [String]
    /// The agent run's instructions, which the program wrote; nil without `agent`.
    public var prompt: String?
    public var script: String

    /// What the sheet says about the names a hook gives (`docs/hooks.md`, Hooks from outside programs).
    public static let tabNamesSentence = localized("Names this hook gives your tabs are saved in Arch's session file, which other programs on this Mac can read.")
}

/// Shows the proposal sheet. `ask` returns true only for Allow, and false for Don't Allow, a sheet that closed unanswered, one that `cancelAll()` closed, and one whose asking task was cancelled.
@MainActor
public protocol HookProposalPrompting: AnyObject {
    func ask(_ review: HookProposalReview) async -> Bool
    /// Closes every sheet as Don't Allow, as at quit.
    func cancelAll()
}

/// The sheet in the window `window` gives, the front main window, as the grant sheet's.
@MainActor
public final class HookProposalSheetPresenter: HookProposalPrompting {
    private let window: () -> NSWindow?
    private var openSheets: [UUID: (Bool) -> Void] = [:]

    public init(window: @escaping () -> NSWindow?) {
        self.window = window
    }

    public func ask(_ review: HookProposalReview) async -> Bool {
        guard let parent = window(), !Task.isCancelled else { return false }
        if !NSApp.isActive { Self.postNotification() }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var sheet: NSWindow?
                let finish: (Bool) -> Void = { [weak self] allowed in
                    guard let self, self.openSheets.removeValue(forKey: id) != nil else { return }
                    if let sheet { parent.endSheet(sheet) }
                    continuation.resume(returning: allowed)
                }
                let window = NSWindow(contentViewController: NSHostingController(rootView: HookProposalSheetView(review: review, finish: finish)))
                sheet = window
                openSheets[id] = finish
                parent.beginSheet(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(AgentLimits.outsideApprovalDefaultMinutes * 60)) {
                    MainActor.assumeIsolated { finish(false) }
                }
            }
        } onCancel: {
            // The sheet opens on the main actor before this runs there.
            Task { @MainActor [weak self] in self?.openSheets[id]?(false) }
        }
    }

    public func cancelAll() {
        for finish in Array(openSheets.values) { finish(false) }
    }

    /// Says only that a program asks, since notifications show on the lock screen. A bare build has no notification center.
    private static func postNotification() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = localized("A program is asking to add a hook in Arch")
            content.body = localized("Open Arch to allow or deny it.")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

struct HookProposalSheetView: View {
    let review: HookProposalReview
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow \u{201C}\(review.clientName)\u{201D} to add the hook \u{201C}\(review.name)\u{201D}?", bundle: .module)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(review.clientPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(review.clientPath)
            VStack(alignment: .leading, spacing: 6) {
                Text(review.situation)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(review.permissions, id: \.self) { Text($0) }
                if !review.agent.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(review.agent, id: \.self) { Text($0) }
                    }
                    .foregroundStyle(.secondary)
                }
                Text(HookProposalReview.tabNamesSentence)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            if let prompt = review.prompt {
                Text("Agent Instructions", bundle: .module)
                    .font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(prompt)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 80)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            }
            Text("Script", bundle: .module)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(review.script)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            Text("Allowing asks for Touch ID or your login password. The hook pauses when this program's access ends.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                AgentApprovalButton(title: localized("Don\u{2019}t Allow"), keyEquivalent: "\u{1B}", requiresPointer: false) { finish(false) }
                AgentApprovalButton(title: localized("Allow\u{2026}"), requiresPointer: true) { finish(true) }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

extension HookTrigger {
    /// The situation in words, as Settings ▸ AI ▸ Hooks words a row's.
    var situationSentence: String {
        switch self {
        case .tabOpened: return "When a new tab opens"
        case .tabClosed(let reasons): return reasons == [.user] ? "When you close a tab" : "When a tab closes"
        case .pageLoaded(let loads, _):
            switch loads {
            case .firstAfterOpen: return "When a new tab loads its first page"
            case .newAddress: return "When a tab loads a new address"
            case .every: return "When a tab loads a page"
            }
        case .addressChanged(let changes): return changes == .newHost ? "When a tab moves to another site" : "When a tab's address changes"
        case .titleChanged: return "When a tab's title changes"
        case .tabSelected: return "When you select a tab"
        case .downloadFinished: return "When a download finishes"
        case .spaceSwitched(let personaChangesOnly): return personaChangesOnly ? "When you switch to another Persona" : "When you switch spaces"
        }
    }

    /// The situation in the words of the language Arch runs in, for the proposal sheet; `situationSentence` stays English for the programs that list their hooks.
    var localizedSituationSentence: String {
        switch self {
        case .tabOpened: return localized("When a new tab opens")
        case .tabClosed(let reasons): return reasons == [.user] ? localized("When you close a tab") : localized("When a tab closes")
        case .pageLoaded(let loads, _):
            switch loads {
            case .firstAfterOpen: return localized("When a new tab loads its first page")
            case .newAddress: return localized("When a tab loads a new address")
            case .every: return localized("When a tab loads a page")
            }
        case .addressChanged(let changes): return changes == .newHost ? localized("When a tab moves to another site") : localized("When a tab's address changes")
        case .titleChanged: return localized("When a tab's title changes")
        case .tabSelected: return localized("When you select a tab")
        case .downloadFinished: return localized("When a download finishes")
        case .spaceSwitched(let personaChangesOnly): return personaChangesOnly ? localized("When you switch to another Persona") : localized("When you switch spaces")
        }
    }
}
