// Checks for and installs app updates with Sparkle, from the appcast and archives of the project's GitHub Releases (`docs/updates.md`).
// The app menu's Check for Updates… and Settings ▸ General's update controls connect to it.
import Foundation
import Preferences
import Sparkle

/// Sparkle's standard updater and the controls Settings ▸ General shows for it. Info.plist turns automatic checks on, sets the check interval, and turns off Sparkle's system profile, which the updater also turns off at start, so that a check sends no data about the Mac.
@MainActor final class AppUpdates {
    /// The target of the app menu's Check for Updates…, which it validates.
    let controller: SPUStandardUpdaterController
    let controls: AppUpdateControls
    private var observations: [NSKeyValueObservation] = []

    /// Only an app bundle whose Info.plist names the feed and the public key that the archives' signatures are checked with has an updater. A build run outside a bundle, or a bundle made without the key, has none, so Sparkle shows no error that it cannot start.
    init?(bundle: Bundle = .main) {
        guard bundle.bundleURL.pathExtension == "app",
              (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false,
              (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false else { return nil }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        updater.sendsSystemProfile = false
        let controls = AppUpdateControls(automaticallyChecks: updater.automaticallyChecksForUpdates, canCheckNow: updater.canCheckForUpdates,
                                         lastCheck: updater.lastUpdateCheckDate)
        controls.setAutomaticallyChecks = { updater.automaticallyChecksForUpdates = $0 }
        controls.checkNow = { controller.checkForUpdates(nil) }
        self.controller = controller
        self.controls = controls
        // Sparkle changes both on the main thread. A check that ends makes checking possible again, and it has then set the last check's date, which is not observable itself.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { updater, _ in
                MainActor.assumeIsolated {
                    controls.canCheckNow = updater.canCheckForUpdates
                    controls.lastCheck = updater.lastUpdateCheckDate
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { updater, _ in
                MainActor.assumeIsolated { controls.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
        ]
    }
}
