// A key with its modifiers, read from a menu item or a key press, and the symbols menus show for it.
import AppKit

/// A shortcut as a menu item's key equivalent holds it: one character, lowercase for letters, with Shift among the modifiers. A recorded shortcut also keeps its key code, which the global shortcut registers.
public struct KeyShortcut {
    /// The character, or an `NSEvent` function key character such as `NSUpArrowFunctionKey`.
    public let key: String
    public let modifiers: NSEvent.ModifierFlags
    public let keyCode: UInt16?

    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// An uppercase letter stands for the letter with Shift, as in menu items.
    init(key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16? = nil) {
        let lowercased = key.lowercased()
        self.key = lowercased
        self.modifiers = modifiers.intersection(Self.modifierMask).union(lowercased == key ? [] : .shift)
        self.keyCode = keyCode
    }

    /// The item's key equivalent, or `nil` when it has none.
    public init?(menuItem: NSMenuItem) {
        guard !menuItem.keyEquivalent.isEmpty else { return nil }
        self.init(key: menuItem.keyEquivalent, modifiers: menuItem.keyEquivalentModifierMask)
    }

    /// The pressed key. Function keys keep their `NSEvent` characters. Other keys read as the keyboard layout maps them with Command, as menus match them; layouts for other scripts map letters there.
    init?(event: NSEvent) {
        let ignoringModifiers = event.charactersIgnoringModifiers ?? ""
        let key = Self.isFunctionKey(ignoringModifiers) ? ignoringModifiers : event.characters(byApplyingModifiers: .command) ?? ""
        guard key.count == 1 else { return nil }
        self.init(key: key, modifiers: event.modifierFlags, keyCode: event.keyCode)
    }

    /// The key equivalent for a menu item. A letter with Shift is uppercase, as the menu bar's own items write it.
    var menuKeyEquivalent: String {
        let uppercased = key.uppercased()
        return modifiers.contains(.shift) && uppercased.count == 1 ? uppercased : key
    }

    /// Menu commands need Command or Control so that typing never runs one; F1 to F35 work alone.
    var suitsMenu: Bool {
        !modifiers.isDisjoint(with: [.command, .control]) || key.unicodeScalars.first.map { (0xF704...0xF726).contains($0.value) } == true
    }

    /// The global shortcut takes its key in every app, so it needs Command, Option, or Control, and a key code to register.
    var suitsGlobal: Bool {
        !modifiers.isDisjoint(with: [.command, .option, .control]) && keyCode != nil
    }

    /// The shortcut as menus show it, such as ⇧⌘T.
    public var displayName: String {
        Self.symbols(for: modifiers) + Self.keyName(key)
    }

    /// Modifier symbols in the order menus show them.
    static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "\u{2303}"), (.option, "\u{2325}"), (.shift, "\u{21E7}"), (.command, "\u{2318}")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
    }

    private static func isFunctionKey(_ characters: String) -> Bool {
        characters.unicodeScalars.count == 1 && characters.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } == true
    }

    private static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first?.value else { return key }
        switch scalar {
        case 0x20: return "Space"
        case 0x09: return "\u{21E5}"
        case 0x0D: return "\u{21A9}"
        case 0x03: return "\u{2324}"
        case 0x08, 0x7F: return "\u{232B}"
        case 0x1B: return "\u{238B}"
        case 0xF700: return "\u{2191}"
        case 0xF701: return "\u{2193}"
        case 0xF702: return "\u{2190}"
        case 0xF703: return "\u{2192}"
        case 0xF704...0xF726: return "F\(scalar - 0xF704 + 1)"
        case 0xF728: return "\u{2326}"
        case 0xF729: return "\u{2196}"
        case 0xF72B: return "\u{2198}"
        case 0xF72C: return "\u{21DE}"
        case 0xF72D: return "\u{21DF}"
        default: return key.uppercased()
        }
    }

    /// The form saved in `UserDefaults`.
    var propertyList: [String: Any] {
        var list: [String: Any] = ["key": key, "modifiers": Int(modifiers.rawValue)]
        if let keyCode { list["keyCode"] = Int(keyCode) }
        return list
    }

    init?(propertyList list: [String: Any]) {
        guard let key = list["key"] as? String, !key.isEmpty, let modifiers = (list["modifiers"] as? Int).flatMap(UInt.init(exactly:)) else { return nil }
        self.init(key: key, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), keyCode: (list["keyCode"] as? Int).flatMap(UInt16.init(exactly:)))
    }
}

extension KeyShortcut: Equatable {
    /// Shortcuts match when they press the same key with the same modifiers; the key code only registers the global shortcut.
    public static func == (lhs: KeyShortcut, rhs: KeyShortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }
}
