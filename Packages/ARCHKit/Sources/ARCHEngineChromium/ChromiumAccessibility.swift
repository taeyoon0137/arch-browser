// Builds Chromium's accessibility tree only while an assistive app needs it, since the tree costs memory and time on every page.
import AppKit
import ARCHPrivateAPI
import CEFBridge
import Combine

/// Turns the accessibility tree of Chromium pages on while VoiceOver runs or while an assistive app asks for it. VoiceOver is detected through `NSWorkspace`; other assistive apps ask through undocumented attributes on the application, a private API behind its flags.
@MainActor
final class ChromiumAccessibility {
    static let apiID = "macos.enhancedUserInterfaceAttributes"
    static let featureID = "chromium.assistiveAppAccessibility"
    /// The attributes assistive apps set on an application to ask for its accessibility tree.
    private static let attributes: Set<String> = ["AXEnhancedUserInterface", "AXManualAccessibility"]

    private var isRequestedByAssistiveApp = false
    private var voiceOverObservation: NSKeyValueObservation?
    private var flagsObservation: AnyCancellable?

    func start() {
        let flags = PrivateAPIFlags.shared
        // The attributes arrive from the assistive app, so there is nothing to look up.
        flags.register(PrivateAPI(id: Self.apiID, name: "AXEnhancedUserInterface, AXManualAccessibility", framework: "macOS accessibility", check: { true }))
        flags.register(PrivateAPIFeature(id: Self.featureID, name: "Chromium pages for assistive apps that ask through undocumented attributes", apiIDs: [Self.apiID]))
        (NSApp as? ARCHCEFApplication)?.accessibilityAttributeHandler = { [weak self] attribute, value in
            guard Self.attributes.contains(attribute) else { return }
            self?.isRequestedByAssistiveApp = (value as? NSNumber)?.boolValue ?? false
            self?.update()
        }
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            DispatchQueue.main.async { self?.update() }
        }
        // A flag switched on the flags page applies at once.
        flagsObservation = flags.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        update()
    }

    private func update() {
        let isRequested = isRequestedByAssistiveApp && PrivateAPIFlags.shared.allows(Self.featureID)
        ARCHCEFRuntime.setAccessibilityEnabled(NSWorkspace.shared.isVoiceOverEnabled || isRequested)
    }
}
