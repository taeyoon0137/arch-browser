// macOS's Low Power Mode, which can slow page animation on both engines: its state for the whole app, and a symbol in the address bar that shows it while it is on.
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

    /// The System Settings pane that holds the mode, named Battery on a Mac with a battery and Energy on one without. Its identifier is undocumented (see Decisions in docs/plan.md); if macOS renames it, System Settings opens at its last pane.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    /// Opens the mode's settings, where the user turns it off for the whole Mac or chooses when it turns on.
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

/// A button in the address bar while Low Power Mode is on, before the share button of the sidebar's address pill and of a small window's top row: a battery symbol with a yellow level, as macOS marks the mode, sized like the bar's other buttons, whose help says pages may animate more slowly. A click, like the context menu's Low Power Mode Settings…, opens the mode's settings; Arch itself changes nothing.
struct LowPowerModeIndicator: View {
    @ObservedObject private var mode = LowPowerMode.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        if mode.isEnabled {
            Button(action: LowPowerMode.openSettings) {
                // The outline takes the bar's secondary color, which keeps its contrast in light and dark sidebars; only the level is yellow.
                Image(systemName: "battery.50percent")
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.secondary, Color.yellow)
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? SidebarFill.buttonHover.color(in: colorScheme) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(localized("Low Power Mode is on, so pages may animate more slowly. Click to open its settings."))
            .contextMenu { Button(localized("Low Power Mode Settings…"), action: LowPowerMode.openSettings) }
            .accessibilityLabel(localized("Low Power Mode"))
            .accessibilityValue(localized("On"))
            .accessibilityHint(localized("Opens Low Power Mode settings"))
        }
    }
}
