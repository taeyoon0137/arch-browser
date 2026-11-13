// Posts a local notification when a download finishes while the app is not active. Clicking the notification reveals the file in the Finder, or opens its folder once a hook has renamed it.
import AppKit
import UserNotifications

/// Asks macOS for notification permission, through the session's `NotificationAuthorization`, when a download finishes while macOS has not asked yet, not at launch. A bare build has no app bundle and therefore no notification center, so it posts nothing.
final class DownloadNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let pathKey = "ARCHDownloadPath"
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    private let authorization: NotificationAuthorization
    /// A notification service that posts through UserNotifications, as Chromium's would after the engine change in Phase VI of `docs/plan.md`, makes itself the center's delegate. The notifier takes the role back before each post and passes responses to other notifications on to the replaced delegate.
    private weak var otherDelegate: UNUserNotificationCenterDelegate?

    /// Becoming the delegate at launch lets a click on a notification from an earlier run still reveal its file.
    init(authorization: NotificationAuthorization) {
        self.authorization = authorization
        super.init()
        claimDelegate()
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
            self.claimDelegate()
            center.add(request)
        }
    }

    private func claimDelegate() {
        guard let center, center.delegate !== self else { return }
        otherDelegate = center.delegate
        center.delegate = self
    }

    /// The center can call its delegate off the main thread, so the Finder is asked on the main thread.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String else {
            if otherDelegate?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) == nil { completionHandler() }
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
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
        completionHandler()
    }

    /// A download notification that arrives after the app becomes active stays hidden.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.userInfo[Self.pathKey] == nil,
           otherDelegate?.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) != nil { return }
        completionHandler([])
    }
}
