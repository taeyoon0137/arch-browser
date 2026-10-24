// Posts a local notification when a download finishes while the app is not active. Clicking the notification reveals the file in the Finder.
import AppKit
import UserNotifications

/// Asks for notification permission the first time a download finishes, not at launch. A bare build has no app bundle and therefore no notification center, so it posts nothing.
final class DownloadNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let pathKey = "ARCHDownloadPath"
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    /// Chromium's notification service may make itself the center's delegate when it shows a page's notification. The notifier takes the role back before each post and passes responses to other notifications on to the replaced delegate.
    private weak var otherDelegate: UNUserNotificationCenterDelegate?

    /// Becoming the delegate at launch lets a click on a notification from an earlier run still reveal its file.
    override init() {
        super.init()
        claimDelegate()
    }

    /// Every finished download asks for permission, which the system shows only the first time. Only a download that finishes while the app is not active posts a notification.
    func downloadDidFinish(_ entry: DownloadEntry) {
        guard let center, let path = entry.targetPath else { return }
        let isInBackground = !NSApp.isActive
        let content = UNMutableNotificationContent()
        content.title = "Download Finished"
        content.body = path.lastPathComponent
        content.userInfo = [Self.pathKey: path.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted, isInBackground else { return }
            DispatchQueue.main.async {
                self.claimDelegate()
                center.add(request)
            }
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
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
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
