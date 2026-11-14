// Handles Arch’s local notification responses. A finished download opens in the Finder. An agent alert returns to its waiting conversation.
import Agent
import AppKit
import UserNotifications

/// Asks macOS for notification permission, through the session's `NotificationAuthorization`, when a download finishes while macOS has not asked yet, not at launch. A bare build has no app bundle and therefore no notification center, so it posts nothing. The notifier uses no notification categories: Chromium replaces the app's whole category set with its own while websites' notifications can show.
final class DownloadNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let pathKey = "ARCHDownloadPath"
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    private let authorization: NotificationAuthorization
    var showWaitingAgent: (@MainActor (UUID) -> Void)?

    /// Becoming the delegate at launch, before the session starts an engine, lets a click on a notification from an earlier run still reveal its file. Chromium's notification service, which posts websites' notifications through the same center, makes itself the delegate while it runs, passes the calls for the app's own notifications on to the delegate it replaced, and puts that delegate back when it ends (`docs/plan.md`, engine changes table), so the notifier never takes the role back and passes nothing on.
    init(authorization: NotificationAuthorization) {
        self.authorization = authorization
        super.init()
        center?.delegate = self
    }

    /// Every finished download checks the permission, and the first one before macOS has asked asks. Only a download that finishes while the app is not active posts a notification.
    func downloadDidFinish(_ entry: DownloadEntry) {
        guard let center, let path = entry.targetPath else { return }
        let isInBackground = !NSApp.isActive
        let content = UNMutableNotificationContent()
        content.title = "Download Finished"
        content.body = path.lastPathComponent
        content.userInfo = [Self.pathKey: path.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        authorization.request { granted in
            guard granted, isInBackground else { return }
            center.add(request)
        }
    }

    /// The center can call its delegate off the main thread, so the Finder is asked on the main thread.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let request = response.notification.request
        if let owner = AgentAttention.ownerID(in: request.identifier) {
            DispatchQueue.main.async { [weak self] in self?.showWaitingAgent?(owner) }
        } else if let path = request.content.userInfo[Self.pathKey] as? String {
            // The notification keeps the name the file finished with, so a file a hook renamed since shows in its folder.
            let file = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } else {
                    NSWorkspace.shared.open(file.deletingLastPathComponent())
                }
            }
        }
    }

    /// A download notification that arrives after the app becomes active stays hidden.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
