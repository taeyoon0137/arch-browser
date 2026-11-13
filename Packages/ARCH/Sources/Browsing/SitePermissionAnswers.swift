// Answers websites' permission requests for the session: from the answers that Settings ▸ Websites remembers, or with a sheet on the tab, whose answer it then remembers. It also keeps the answers that each engine profile keeps itself in line with the remembered ones. The Persona that only agents use is the exception (agent decision 9; Persona rule 6): its profiles get no remembered answers, and its requests are denied without a sheet and not remembered.
import AppKit
import ARCHEngine
import Combine
import Foundation

final class SitePermissionAnswers {
    /// The remembered answers, which the session keeps in its folder.
    let store: SitePermissionStore
    /// The answers waiting for each permission sheet, keyed by tab, origin, and types, so that a page that asks again before the user answers gets the same sheet's answer.
    private var waiters: [String: [(Bool) -> Void]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// The agent-only Persona's profiles, which follow the remembered answers only once their Persona becomes ordinary again.
    private var unfollowed: [(personaID: UUID, context: any EngineBrowserContext)] = []

    /// The Agents Persona while `agent.json` names it, which the agents' service sets before any of its profiles starts. A Persona that stops being agent-only, as after `agent.json` lost its seal, has its running profiles follow the remembered answers from then on; a profile that followed them before its Persona became agent-only keeps them until quit.
    var agentOnlyPersonaID: UUID? {
        didSet {
            guard agentOnlyPersonaID != oldValue else { return }
            let released = unfollowed.filter { $0.personaID != agentOnlyPersonaID }
            unfollowed.removeAll { $0.personaID != agentOnlyPersonaID }
            for profile in released { follow(profile.context, of: profile.personaID) }
        }
    }

    init(store: SitePermissionStore) {
        self.store = store
    }

    /// Answers a request of the tab `tabID` in the Persona `personaID` from the remembered answers, or asks with the sheet it passes to `ask` and remembers the user's answer. One remembered Don't Allow denies the whole request, and only a remembered Allow for every type in it grants it without asking. A request that is never remembered, such as one to record the screen or one from a page without a web address, always asks. A request in the agent-only Persona is denied at once. `context` is the profile of the tab's page.
    func answer(_ request: EnginePermissionRequest, forTab tabID: UUID, personaID: UUID, in context: (any EngineBrowserContext)?,
                ask: (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void, completion: @escaping (Bool) -> Void) {
        if personaID == agentOnlyPersonaID {
            completion(false)
            // Chromium keeps every answer it receives, so its profile forgets the denial again: this Persona remembers nothing.
            if let context {
                DispatchQueue.main.async { request.types.forEach { context.setRememberedPermission(nil, for: $0, origin: request.origin) } }
            }
            return
        }
        let store = store
        // Chromium keeps every answer it receives, even the safe answer for a sheet that closed with its tab, so once it has the answer its kept answers return to the remembered ones.
        let answer = { [weak self] (granted: Bool) in
            completion(granted)
            guard let context else { return }
            DispatchQueue.main.async { self?.restoreRememberedAnswers(for: request, in: context) }
        }
        let isRemembered = !request.types.isEmpty && request.types.allSatisfy(SitePermissionStore.remembers)
        let origin = isRemembered ? SitePermissionStore.origin(of: request.origin) : nil
        if let origin {
            let decisions = request.types.map { store.decision(for: $0, origin: origin) }
            if decisions.contains(.deny) { return answer(false) }
            if decisions.allSatisfy({ $0 == .allow }) { return answer(true) }
        }
        let key = "\(tabID) \(request.origin.absoluteString) \(request.types.map(\.rawValue).sorted())"
        guard waiters[key] == nil else {
            waiters[key]?.append(answer)
            return
        }
        waiters[key] = [answer]
        ask(Self.alert(for: request, remembersAnswer: origin != nil)) { [weak self] response in
            let waiters = self?.waiters.removeValue(forKey: key) ?? [answer]
            let granted = response == .alertFirstButtonReturn
            waiters.forEach { $0(granted) }
            // A sheet that closed without an answer, as when its tab closed, leaves nothing to remember.
            if let origin, response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
                store.set(granted ? .allow : .deny, for: request.types, origin: origin)
            }
        }
    }

    /// Gives a profile's own kept answers for the request's types the remembered answers, or none.
    func restoreRememberedAnswers(for request: EnginePermissionRequest, in context: any EngineBrowserContext) {
        let origin = SitePermissionStore.origin(of: request.origin)
        for type in request.types {
            let decision = origin.flatMap { store.decision(for: type, origin: $0) }
            context.setRememberedPermission(decision.map { $0 == .allow }, for: type, origin: request.origin)
        }
    }

    /// Copies the remembered answers into the kept answers of a profile of the Persona `personaID`, now and after every change, such as one made in Settings. Now also takes away the answers removed while the profile was not running. A profile of the agent-only Persona takes none.
    func follow(_ context: any EngineBrowserContext, of personaID: UUID) {
        guard personaID != agentOnlyPersonaID else {
            unfollowed.append((personaID, context))
            return
        }
        let store = store
        let apply = { (origin: String, types: [EnginePermissionType]) in
            guard let url = URL(string: origin) else { return }
            for type in types {
                context.setRememberedPermission(store.decision(for: type, origin: origin).map { $0 == .allow }, for: type, origin: url)
            }
        }
        for (origin, answers) in store.decisions { apply(origin, Array(answers.keys)) }
        for (origin, types) in store.removed { apply(origin, Array(types)) }
        store.didChange
            .sink { apply($0.origin, $0.types) }
            .store(in: &cancellables)
    }

    /// The sheet that asks. The engine asks from inside its own message loop, so the sheet never blocks, and the answer reaches the engine once.
    private static func alert(for request: EnginePermissionRequest, remembersAnswer: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Allow \u{201C}\(request.origin.host ?? request.origin.absoluteString)\u{201D} to \(description(of: request.types))?"
        if remembersAnswer {
            alert.informativeText = "Arch remembers your answer for this website. You can change it in Settings > Websites."
        }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        return alert
    }

    private static func description(of types: [EnginePermissionType]) -> String {
        let phrases = types.map { type -> String in
            switch type {
            case .camera: return "use the camera"
            case .microphone: return "use the microphone"
            case .screenCapture: return "record the screen"
            case .geolocation: return "see your location"
            case .notifications: return "send notifications"
            case .clipboard: return "read the clipboard"
            case .midi: return "use MIDI devices"
            }
        }
        return ListFormatter.localizedString(byJoining: phrases)
    }
}
