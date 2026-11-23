// Answers websites' permission requests for the session: from the answers that Settings ▸ Websites remembers for the tab's Persona, or with a card on the tab, whose answer it then remembers in that Persona. It also keeps the answers that each engine profile keeps itself in line with its Persona's remembered ones. A website's notifications also need Arch's own notification permission from macOS, which the card asks for after Allow and names while it is off. The agent-only Persona denies requests without storing an answer.
import ARCHEngine
import Combine
import Foundation

final class SitePermissionAnswers {
    /// The remembered answers, which the session keeps in its folder.
    let store: SitePermissionStore
    /// Arch's notification permission from macOS, which websites' notifications need besides the site's answer.
    let notifications: NotificationAuthorization
    /// The answers waiting for each permission card, keyed by tab, origin, and types, so that a page that asks again before the user answers gets the same card's answer.
    private var waiters: [String: [(Bool) -> Void]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// The agent-only Persona's profiles, which follow their Persona's remembered answers only once it becomes ordinary again.
    private var unfollowed: [(personaID: UUID, context: any EngineBrowserContext)] = []

    /// The Agents Persona while `agent.json` names it, which the session sets when it creates the answers, before any engine starts, and the agents' service keeps in line with the checked seal. A Persona that stops being agent-only, as after `agent.json` lost its seal, has its running profiles follow its remembered answers from then on; a profile that followed them before its Persona became agent-only keeps them until quit.
    var agentOnlyPersonaID: UUID? {
        didSet {
            guard agentOnlyPersonaID != oldValue else { return }
            let released = unfollowed.filter { $0.personaID != agentOnlyPersonaID }
            unfollowed.removeAll { $0.personaID != agentOnlyPersonaID }
            for profile in released { follow(profile.context, of: profile.personaID) }
        }
    }

    init(store: SitePermissionStore, notifications: NotificationAuthorization, agentOnlyPersonaID: UUID? = nil) {
        self.store = store
        self.notifications = notifications
        self.agentOnlyPersonaID = agentOnlyPersonaID
    }

    /// Whether more than one of `personas` keeps remembered answers of its own (Persona rule 6), so that the card and Settings ▸ Websites name the Persona. The Agents Persona takes no remembered answer, so it does not count.
    func holdsInSeveralPersonas(_ personas: [Persona]) -> Bool {
        personas.filter { $0.id != agentOnlyPersonaID }.count > 1
    }

    /// Answers a request of the tab `tabID` in the Persona `personaID` from that Persona's remembered answers, or asks with the card whose maker it passes to `ask`, under `identity`, the site that asks, and remembers the user's answer in the Persona. One remembered Don't Allow denies the whole request, and only a remembered Allow for every type in it grants it without asking. A request that is never remembered, such as one to record the screen or one from a page without a web address, always asks. `context` is the profile of the tab's page. A request in the agent-only Persona is denied at once and not remembered. `persona`, the Persona as a card names it from the tab's place (Persona rule 7), such as "the Persona of “Work / Research”", makes the card's note say where the answer holds; the session passes it only while several Personas keep answers (`holdsInSeveralPersonas(_:)`).
    ///
    /// The card can wait in its tab's queue while Arch's notification permission changes, as when macOS's question for another tab's card is answered, so `ask` makes the card with the maker each time a card shows it, which reads the permission then, and again when the permission changes while a card shows it, and the answer acts on the permission the card showed last.
    func answer(_ request: EnginePermissionRequest, forTab tabID: UUID, personaID: UUID, in context: (any EngineBrowserContext)?, identity: PromptIdentity, persona: String? = nil,
                ask: (@escaping () -> PromptContent, @escaping (PromptResponse) -> Void) -> Void, completion: @escaping (Bool) -> Void) {
        if personaID == agentOnlyPersonaID { return denyWithoutAsking(request, personaID: personaID, in: context, completion: completion) }
        let store = store
        let notifications = notifications
        // Chromium keeps every answer it receives, even the safe answer for a card that ended with its tab, so once it has the answer its kept answers return to the remembered ones.
        let answer = { [weak self] (granted: Bool) in
            completion(granted)
            guard let context else { return }
            DispatchQueue.main.async { self?.restoreRememberedAnswers(for: request, personaID: personaID, in: context) }
        }
        let isRemembered = !request.types.isEmpty && request.types.allSatisfy(SitePermissionStore.remembers)
        let origin = isRemembered ? SitePermissionStore.origin(of: request.origin) : nil
        if let origin {
            let decisions = request.types.map { store.decision(for: $0, origin: origin, in: personaID) }
            if decisions.contains(.deny) { return answer(false) }
            if decisions.allSatisfy({ $0 == .allow }) { return answer(true) }
        }
        let key = "\(tabID) \(request.origin.absoluteString) \(request.types.map(\.rawValue).sorted())"
        guard waiters[key] == nil else {
            waiters[key]?.append(answer)
            return
        }
        waiters[key] = [answer]
        let asksForNotifications = request.types.contains(.notifications)
        var shownStatus: NotificationAuthorization.Status?
        let makeContent = {
            if asksForNotifications { shownStatus = notifications.status }
            return Self.content(for: request, remembersAnswer: origin != nil, identity: identity, persona: persona, notificationStatus: shownStatus)
        }
        ask(makeContent) { [weak self] response in
            let waiters = self?.waiters.removeValue(forKey: key) ?? [answer]
            let granted = response.buttonID == "allow"
            waiters.forEach { $0(granted) }
            // Don't Allow, also through Escape, is an answer to remember. A card that ended without the user, as when its tab closed, leaves nothing to remember. Nor does Open System Settings, so the website can ask again once the user has turned Arch's notifications on.
            if let origin, response.buttonID == "allow" || response.buttonID == "deny" {
                store.set(granted ? .allow : .deny, for: request.types, origin: origin, in: personaID)
            }
            // macOS asks only after the user allowed a website's notifications on a card that said it would, so its question follows the user's own choice. The page already has its answer: Chromium holds a tab's next permission request until this one is answered, and macOS's question can stay on screen for long. A refusal there leaves the website's Allow in place, so it works once the user turns Arch's notifications on.
            if granted, shownStatus == .notDetermined {
                notifications.request { _ in }
            } else if shownStatus == .denied, response.buttonID == "openSystemSettings" {
                notifications.openSystemSettings()
            }
        }
    }

    /// Denies a request that nobody is asked about: one of the agent-only Persona, an agent's tab, or a preview. Chromium keeps every answer it receives, so on the next turn the profile's kept answers for the types return to its Persona's remembered ones, or to none in the agent-only Persona, which remembers nothing.
    func denyWithoutAsking(_ request: EnginePermissionRequest, personaID: UUID, in context: (any EngineBrowserContext)?, completion: (Bool) -> Void) {
        completion(false)
        guard let context else { return }
        let remembersNothing = personaID == agentOnlyPersonaID
        DispatchQueue.main.async { [weak self] in
            if remembersNothing {
                request.types.forEach { context.setRememberedPermission(nil, for: $0, origin: request.origin) }
            } else {
                self?.restoreRememberedAnswers(for: request, personaID: personaID, in: context)
            }
        }
    }

    /// Gives the own kept answers for the request's types of a profile of the Persona `personaID` the Persona's remembered answers, or none.
    func restoreRememberedAnswers(for request: EnginePermissionRequest, personaID: UUID, in context: any EngineBrowserContext) {
        let origin = SitePermissionStore.origin(of: request.origin)
        for type in request.types {
            let decision = origin.flatMap { store.decision(for: type, origin: $0, in: personaID) }
            context.setRememberedPermission(decision.map { $0 == .allow }, for: type, origin: request.origin)
        }
    }

    /// Copies the Persona `personaID`'s remembered answers into the kept answers of a profile of it, now and after every change of the Persona's answers, such as one made in Settings. Now also takes away the answers removed while the profile was not running. A profile of the agent-only Persona takes none, and no profile takes another Persona's answers.
    func follow(_ context: any EngineBrowserContext, of personaID: UUID) {
        guard personaID != agentOnlyPersonaID else {
            unfollowed.append((personaID, context))
            return
        }
        let store = store
        let apply = { (origin: String, types: [EnginePermissionType]) in
            guard let url = URL(string: origin) else { return }
            for type in types {
                context.setRememberedPermission(store.decision(for: type, origin: origin, in: personaID).map { $0 == .allow }, for: type, origin: url)
            }
        }
        for (origin, answers) in store.decisions(in: personaID) { apply(origin, Array(answers.keys)) }
        for (origin, types) in store.removed(in: personaID) { apply(origin, Array(types)) }
        store.didChange
            .filter { $0.personaID == personaID }
            .sink { apply($0.origin, $0.types) }
            .store(in: &cancellables)
    }

    /// The card that asks, under the site that asks, with the symbol of the first of its types in the order screen, camera, microphone, location, notifications, clipboard, and MIDI. The engine asks from inside its own message loop, so the card never blocks, and the answer reaches the engine once. Allow waits for the card to arm. `notificationStatus`, Arch's notification permission for a request for notifications, adds a note on what macOS does with them, and while the permission is off a third button, Open System Settings, apart from the answers at the leading edge, which takes no key, opens it there.
    static func content(for request: EnginePermissionRequest, remembersAnswer: Bool, identity: PromptIdentity, persona: String? = nil, notificationStatus: NotificationAuthorization.Status? = nil) -> PromptContent {
        var notes: [PromptNote] = []
        if remembersAnswer {
            // With several Personas the answer holds only in the tab's (Persona rule 6), which the note names; with one, the note says nothing of Personas (Persona rule 7).
            notes.append(PromptNote(id: "remembers", symbol: "info.circle", text: persona.map { localized("Arch remembers your answer for this website in \($0). You can change it in Settings \u{25B8} Websites.") } ?? localized("Arch remembers your answer for this website. You can change it in Settings \u{25B8} Websites."), tone: .info))
        }
        switch notificationStatus {
        case .notDetermined:
            notes.append(PromptNote(id: "asksMacOS", symbol: "bell", text: localized("After you click Allow, macOS asks whether Arch can send you notifications."), tone: .info))
        case .denied:
            notes.append(PromptNote(id: "notificationsOff", symbol: "bell.slash", text: localized("Notifications for Arch are off in System Settings, so this website\u{2019}s notifications won\u{2019}t show."), tone: .info))
        case .unavailable:
            notes.append(PromptNote(id: "noNotifications", symbol: "bell.slash", text: localized("This copy of Arch runs without its app bundle, so it can\u{2019}t show notifications."), tone: .info))
        case .allowed, nil:
            break
        }
        var buttons = [PromptButton(id: "deny", title: localized("Don\u{2019}t Allow")), PromptButton(id: "allow", title: localized("Allow"), needsArming: true)]
        if notificationStatus == .denied {
            buttons.insert(PromptButton(id: "openSystemSettings", title: localized("Open System Settings"), isAlternative: true), at: 0)
        }
        let asker = request.origin.host?.isEmpty == false ? localized("this website") : localized("this page")
        return PromptContent(kind: .sitePermission, identity: identity, glyph: glyph(for: request.types),
                             title: localized("Allow \(asker) to \(description(of: request.types))?"), notes: notes,
                             buttons: buttons, defaultButtonID: "allow", cancelButtonID: "deny")
    }

    private static func glyph(for types: [EnginePermissionType]) -> PromptGlyph {
        let order: [EnginePermissionType] = [.screenCapture, .camera, .microphone, .geolocation, .notifications, .clipboard, .midi]
        switch order.first(where: types.contains) ?? .camera {
        case .screenCapture: return .symbol("rectangle.dashed.badge.record", tint: .purple, label: localized("Screen Recording"))
        case .camera: return .symbol("video.fill", tint: .green, label: localized("Camera"))
        case .microphone: return .symbol("mic.fill", tint: .orange, label: localized("Microphone"))
        case .geolocation: return .symbol("location.fill", tint: .accent, label: localized("Location"))
        case .notifications: return .symbol("bell.badge.fill", tint: .accent, label: localized("Notifications"))
        case .clipboard: return .symbol("doc.on.clipboard", tint: .accent, label: localized("Clipboard"))
        case .midi: return .symbol("pianokeys", tint: .accent, label: localized("MIDI Devices"))
        }
    }

    /// The request's types as one phrase each, in the order they arrive. The camera and the microphone alone, as a video call asks for them, share one verb; with a third type, each keeps its own, so that the list has one "and".
    private static func description(of types: [EnginePermissionType]) -> String {
        let both = Set(types) == [.camera, .microphone]
        let phrases = types.compactMap { type -> String? in
            switch type {
            case .camera: return both ? localized("use the camera and microphone") : localized("use the camera")
            case .microphone: return both ? nil : localized("use the microphone")
            case .screenCapture: return localized("record the screen")
            case .geolocation: return localized("see your location")
            case .notifications: return localized("send notifications")
            case .clipboard: return localized("read the clipboard")
            case .midi: return localized("use MIDI devices")
            }
        }
        return ListFormatter.localizedString(byJoining: phrases)
    }
}
