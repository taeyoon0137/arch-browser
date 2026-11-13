// Answers websites' permission requests for the session: from the answers that Settings ▸ Websites remembers, or with a card on the tab, whose answer it then remembers. It also keeps the answers that each engine profile keeps itself in line with the remembered ones.
import ARCHEngine
import Combine
import Foundation

final class SitePermissionAnswers {
    /// The remembered answers, which the session keeps in its folder.
    let store: SitePermissionStore
    /// The answers waiting for each permission card, keyed by tab, origin, and types, so that a page that asks again before the user answers gets the same card's answer.
    private var waiters: [String: [(Bool) -> Void]] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(store: SitePermissionStore) {
        self.store = store
    }

    /// Answers a request of the tab `tabID` from the remembered answers, or asks with the card it passes to `ask`, under `identity`, the site that asks, and remembers the user's answer. One remembered Don't Allow denies the whole request, and only a remembered Allow for every type in it grants it without asking. A request that is never remembered, such as one to record the screen or one from a page without a web address, always asks. `context` is the profile of the tab's page.
    func answer(_ request: EnginePermissionRequest, forTab tabID: UUID, in context: (any EngineBrowserContext)?, identity: PromptIdentity,
                ask: (PromptContent, @escaping (PromptResponse) -> Void) -> Void, completion: @escaping (Bool) -> Void) {
        let store = store
        // Chromium keeps every answer it receives, even the safe answer for a card that ended with its tab, so once it has the answer its kept answers return to the remembered ones.
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
        ask(Self.content(for: request, remembersAnswer: origin != nil, identity: identity)) { [weak self] response in
            let waiters = self?.waiters.removeValue(forKey: key) ?? [answer]
            let granted = response.buttonID == "allow"
            waiters.forEach { $0(granted) }
            // Don't Allow, also through Escape, is an answer to remember. A card that ended without the user, as when its tab closed, leaves nothing to remember.
            if let origin, response.buttonID != nil {
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

    /// Copies the remembered answers into a profile's own kept answers, now and after every change, such as one made in Settings. Now also takes away the answers removed while the profile was not running.
    func follow(_ context: any EngineBrowserContext) {
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

    /// The card that asks, under the site that asks, with the symbol of the first of its types in the order screen, camera, microphone, location, notifications, clipboard, and MIDI. The engine asks from inside its own message loop, so the card never blocks, and the answer reaches the engine once. Allow waits for the card to arm. A request for notifications says that they don't show as banners yet: the pinned engine posts them through `NSUserNotificationCenter`, which macOS refuses for Arch whatever Arch's notification permission is, so the card neither asks macOS nor points to System Settings (`docs/plan.md`, VI.7).
    static func content(for request: EnginePermissionRequest, remembersAnswer: Bool, identity: PromptIdentity) -> PromptContent {
        var notes: [PromptNote] = []
        if remembersAnswer {
            notes.append(PromptNote(id: "remembers", symbol: "info.circle", text: "Arch remembers your answer for this website. You can change it in Settings > Websites.", tone: .info))
        }
        if request.types.contains(.notifications) {
            notes.append(PromptNote(id: "banners", symbol: "bell.slash", text: "Websites\u{2019} notifications don\u{2019}t show as banners yet.", tone: .info))
        }
        let asker = request.origin.host?.isEmpty == false ? "this website" : "this page"
        return PromptContent(kind: .sitePermission, identity: identity, glyph: glyph(for: request.types),
                             title: "Allow \(asker) to \(description(of: request.types))?", notes: notes,
                             buttons: [PromptButton(id: "deny", title: "Don\u{2019}t Allow"), PromptButton(id: "allow", title: "Allow", needsArming: true)],
                             defaultButtonID: "allow", cancelButtonID: "deny")
    }

    private static func glyph(for types: [EnginePermissionType]) -> PromptGlyph {
        let order: [EnginePermissionType] = [.screenCapture, .camera, .microphone, .geolocation, .notifications, .clipboard, .midi]
        switch order.first(where: types.contains) ?? .camera {
        case .screenCapture: return .symbol("rectangle.dashed.badge.record", tint: .purple, label: "Screen Recording")
        case .camera: return .symbol("video.fill", tint: .green, label: "Camera")
        case .microphone: return .symbol("mic.fill", tint: .orange, label: "Microphone")
        case .geolocation: return .symbol("location.fill", tint: .accent, label: "Location")
        case .notifications: return .symbol("bell.badge.fill", tint: .accent, label: "Notifications")
        case .clipboard: return .symbol("doc.on.clipboard", tint: .accent, label: "Clipboard")
        case .midi: return .symbol("pianokeys", tint: .accent, label: "MIDI Devices")
        }
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
