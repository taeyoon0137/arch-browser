// Whether macOS lets Arch show notifications. One permission for the app bundle decides it for the download notifier and for websites' notifications, which Chromium tabs post once Chromium posts through UserNotifications as well (`docs/plan.md`, VI.7). The download notifier asks through this part, so macOS asks the first time a download finishes, not at launch. The status and the System Settings link are for the permission sheet and Settings ▸ Websites, which show them only from VI.7 on: until then a website's notifications do not show whatever the permission is, so neither asks macOS nor points to System Settings.
import AppKit
import Combine
import UserNotifications

/// The app's notification permission as macOS reports it, read at launch, whenever Arch becomes active, as after the user changed it in System Settings, and after each request. It is used on the main thread.
public final class NotificationAuthorization: ObservableObject {
    public enum Status: Equatable {
        /// macOS has not asked the user yet.
        case notDetermined
        /// The user allowed notifications, or macOS allows them provisionally.
        case allowed
        /// The user refused when macOS asked, or turned Arch's notifications off in System Settings.
        case denied
        /// A build that runs without its app bundle, which has no notification center.
        case unavailable
    }

    /// The calls to the system, which tests replace. Each calls back on the main thread.
    struct System {
        var readStatus: (@escaping (Status) -> Void) -> Void
        /// Asks macOS whether Arch may show notifications and calls back with whether it may.
        var requestAuthorization: (@escaping (Bool) -> Void) -> Void
        var open: (URL) -> Void
        var bundleIdentifier: String?
    }

    @Published public private(set) var status: Status
    /// `nil` without an app bundle.
    private let system: System?
    /// The answers that wait for the request that runs, or `nil` while none runs.
    private var waiting: [(Bool) -> Void]?
    private var activationObserver: NSObjectProtocol?

    /// The app's own notification permission.
    public convenience init() {
        self.init(system: Self.appSystem())
    }

    init(system: System?) {
        self.system = system
        status = system == nil ? .unavailable : .notDetermined
        guard system != nil else { return }
        refresh()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Reads the permission again.
    public func refresh() {
        system?.readStatus { [weak self] in self?.status = $0 }
    }

    /// Answers whether Arch may show notifications, from what macOS reports now. Only while macOS has not asked yet does it ask first, so a refusal or a permission turned off in System Settings is never asked about again; System Settings changes it. Requests that overlap share one question. A build without its app bundle answers no.
    public func request(completion: @escaping (Bool) -> Void) {
        guard let system else { return completion(false) }
        guard waiting == nil else {
            waiting?.append(completion)
            return
        }
        waiting = [completion]
        system.readStatus { [weak self] status in
            guard status == .notDetermined else {
                self?.finish(with: status)
                return
            }
            system.requestAuthorization { _ in
                system.readStatus { self?.finish(with: $0) }
            }
        }
    }

    private func finish(with status: Status) {
        self.status = status
        let answers = waiting ?? []
        waiting = nil
        answers.forEach { $0(status == .allowed) }
    }

    /// Opens Arch's entry in System Settings ▸ Notifications, where the user turns its notifications on.
    public func openSystemSettings() {
        guard let system, let url = Self.settingsURL(bundleIdentifier: system.bundleIdentifier) else { return }
        system.open(url)
    }

    /// The address is not documented, as the one Import opens is not (see Open decisions in `docs/import-browsers.md`); it is a URL that `NSWorkspace` opens, not a framework API. If macOS ignores the anchor, System Settings opens at Notifications.
    static func settingsURL(bundleIdentifier: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        if let bundleIdentifier { components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)] }
        return components.url
    }

    /// The system's calls for the app bundle, or `nil` for a bare build, where the notification center is not available.
    private static func appSystem() -> System? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let center = UNUserNotificationCenter.current()
        return System(
            readStatus: { completion in
                center.getNotificationSettings { settings in
                    let status = Status(settings.authorizationStatus)
                    DispatchQueue.main.async { completion(status) }
                }
            },
            requestAuthorization: { completion in
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            },
            open: { NSWorkspace.shared.open($0) },
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
}

extension NotificationAuthorization.Status {
    /// A status that this SDK does not know counts as allowed, so that nothing claims that Arch's notifications are off.
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional: self = .allowed
        @unknown default: self = .allowed
        }
    }
}
