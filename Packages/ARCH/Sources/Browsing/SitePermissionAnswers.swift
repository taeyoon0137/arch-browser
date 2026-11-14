// Answers websites' permission requests for the session: from the answers that Settings ▸ Websites remembers, or with a sheet on the tab, whose answer it then remembers. It also keeps the answers that each engine profile keeps itself in line with the remembered ones. A website's notifications also need Arch's own notification permission from macOS, which the sheet asks for after Allow and names while it is off.
import AppKit
import ARCHEngine
import Combine
import Foundation

final class SitePermissionAnswers {
    /// The remembered answers, which the session keeps in its folder.
    let store: SitePermissionStore
    /// Arch's notification permission from macOS, which websites' notifications need besides the site's answer.
    let notifications: NotificationAuthorization
    /// The answers waiting for each permission sheet, keyed by tab, origin, and types, so that a page that asks again before the user answers gets the same sheet's answer.
    private var waiters: [String: [(Bool) -> Void]] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(store: SitePermissionStore, notifications: NotificationAuthorization) {
        self.store = store
        self.notifications = notifications
    }

    /// Answers a request of the tab `tabID` from the remembered answers, or asks with the sheet whose maker it passes to `ask` and remembers the user's answer. One remembered Don't Allow denies the whole request, and only a remembered Allow for every type in it grants it without asking. A request that is never remembered, such as one to record the screen or one from a page without a web address, always asks. `context` is the profile of the tab's page.
    ///
    /// The sheet can wait in its tab's queue while Arch's notification permission changes, as when macOS's question for another tab's sheet is answered, so `ask` makes the sheet with the maker each time it shows, which reads the permission then, and the answer acts on the permission the sheet showed last.
    func answer(_ request: EnginePermissionRequest, forTab tabID: UUID, in context: (any EngineBrowserContext)?,
                ask: (@escaping () -> NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void, completion: @escaping (Bool) -> Void) {
        let store = store
        let notifications = notifications
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
        let asksForNotifications = request.types.contains(.notifications)
        var shownStatus: NotificationAuthorization.Status?
        let makeAlert = {
            if asksForNotifications { shownStatus = notifications.status }
            return Self.alert(for: request, remembersAnswer: origin != nil, notificationStatus: shownStatus)
        }
        ask(makeAlert) { [weak self] response in
            let waiters = self?.waiters.removeValue(forKey: key) ?? [answer]
            let granted = response == .alertFirstButtonReturn
            waiters.forEach { $0(granted) }
            // A sheet that closed without an answer, as when its tab closed, leaves nothing to remember. Nor does Open System Settings, so the website can ask again once the user has turned Arch's notifications on.
            if let origin, response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
                store.set(granted ? .allow : .deny, for: request.types, origin: origin)
            }
            // macOS asks only after the user allowed a website's notifications on a sheet that said it would, so its question follows the user's own choice. The page already has its answer: Chromium holds a tab's next permission request until this one is answered, and macOS's question can stay on screen for long. A refusal there leaves the website's Allow in place, so it works once the user turns Arch's notifications on.
            if granted, shownStatus == .notDetermined {
                notifications.request { _ in }
            } else if shownStatus == .denied, response == .alertThirdButtonReturn {
                notifications.openSystemSettings()
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

    /// The sheet that asks. The engine asks from inside its own message loop, so the sheet never blocks, and the answer reaches the engine once. `notificationStatus`, Arch's notification permission for a request for notifications, adds what macOS does with them, and while the permission is off a third button opens it in System Settings.
    private static func alert(for request: EnginePermissionRequest, remembersAnswer: Bool, notificationStatus: NotificationAuthorization.Status?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Allow \u{201C}\(request.origin.host ?? request.origin.absoluteString)\u{201D} to \(description(of: request.types))?"
        var notes: [String] = []
        if remembersAnswer {
            notes.append("Arch remembers your answer for this website. You can change it in Settings > Websites.")
        }
        switch notificationStatus {
        case .notDetermined: notes.append("After you allow, macOS asks whether Arch may show notifications.")
        case .denied: notes.append("Notifications for Arch are off in System Settings, so this website\u{2019}s notifications won\u{2019}t show until you turn them on.")
        case .unavailable: notes.append("This copy of Arch runs without its app bundle, so it can\u{2019}t show notifications.")
        case .allowed, nil: break
        }
        alert.informativeText = notes.joined(separator: " ")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        if notificationStatus == .denied {
            alert.addButton(withTitle: "Open System Settings")
        }
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
