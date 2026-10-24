// One shortcut that works while another app is in front, registered with the Carbon Event Manager's `RegisterEventHotKey`, a public API that needs no accessibility permission.
import AppKit
import Carbon.HIToolbox

/// Tells this hot key's presses apart from other hot keys in the process.
private let hotKeySignature: OSType = 0x4152_4348 // "ARCH"

/// Registers at most one hot key at a time and runs `action` when it is pressed. Carbon delivers the press on the main thread, and the key does not reach the app in front.
@MainActor
final class GlobalHotKey {
    /// The status `RegisterEventHotKey` returns when another app holds the shortcut.
    static let inUseStatus = OSStatus(eventHotKeyExistsErr)

    fileprivate let action: () -> Void
    private var hotKey: EventHotKeyRef?
    /// Installed with the first registration and kept for the app's lifetime, like the shared settings that own this object.
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers the key in place of the current hot key and returns the Carbon status.
    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> OSStatus {
        unregister()
        if handler == nil {
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), handleHotKeyEvent, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }
        let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(modifiers), EventHotKeyID(signature: hotKeySignature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
        return status
    }

    func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    private static func carbonModifiers(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}

/// The Carbon event handler; `userData` is the `GlobalHotKey` that installed it.
private func handleHotKeyEvent(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    guard let event, let userData,
          GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
          id.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.action() }
    return noErr
}
