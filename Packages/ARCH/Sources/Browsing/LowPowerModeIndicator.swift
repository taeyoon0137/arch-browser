// macOS's Low Power Mode, which can slow page animation on both engines: its state for the whole app, and a sidebar symbol that shows it while it is on.
import AppKit
import SwiftUI

/// Follows macOS's Low Power Mode. Arch never changes the mode and cannot ignore it for itself alone: Chromium never reads it, macOS has no public per-app exception, and WebKit slows its pages by itself with no public setting (see Decisions in docs/plan.md).
@MainActor
final class LowPowerMode: ObservableObject {
    static let shared = LowPowerMode()

    @Published private(set) var isEnabled: Bool

    private var observer: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default, read: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }) {
        isEnabled = read()
        // macOS posts the change on a global queue; the main queue hands it to the main actor.
        observer = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isEnabled = read() }
        }
    }

    static let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    /// Opens Battery settings, where the user turns the mode off for the whole Mac or chooses when it turns on.
    static func openBatterySettings() {
        NSWorkspace.shared.open(batterySettingsURL)
    }
}

/// The trailing end of the sidebar's bottom bar while Low Power Mode is on: a yellow battery symbol whose help says pages may animate more slowly. A click, like the context menu's Battery Settings…, opens Battery settings; Arch itself changes nothing.
struct LowPowerModeIndicator: View {
    @ObservedObject private var mode = LowPowerMode.shared
    @State private var isHovering = false

    var body: some View {
        if mode.isEnabled {
            Button(action: LowPowerMode.openBatterySettings) {
                Image(systemName: "battery.50percent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.yellow)
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Low Power Mode is on, so pages may animate more slowly. Click to open Battery settings.")
            .contextMenu { Button("Battery Settings…", action: LowPowerMode.openBatterySettings) }
            .accessibilityLabel("Low Power Mode")
            .accessibilityValue("On")
            .accessibilityHint("Opens Battery settings")
        }
    }
}
