// A plugin command's shortcut as a manifest writes it, such as `ctrl+opt+r`, and the key equivalent of the command's item in the Plugins menu.
import AppKit

/// Modifiers and a key joined by `+`. The modifiers are `ctrl`, `opt`, `shift`, and `cmd`, each at most once and in any order. The key comes last: one printable ASCII character other than `+`, such as `r` or `/`, or `plus`, `space`, `up`, `down`, `left`, `right`, or `f1` to `f20`. Case does not matter, so `R` names the same key as `r`; Shift counts only as `shift`.
///
/// A shortcut needs `cmd` or `ctrl` unless its key is a function key, so that typing never runs a command, as the app's own menu commands require.
public struct PluginShortcut: Hashable, Sendable, CustomStringConvertible {
    /// In the order menus show them.
    public enum Modifier: String, CaseIterable, Sendable {
        case ctrl, opt, shift, cmd
    }

    public let modifiers: Set<Modifier>
    /// The key in lowercase: a character, or one of the key names above.
    public let key: String

    /// Throws `PluginError.invalidShortcut` for text that breaks the rules above.
    public init(_ text: String) throws {
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let key = parts.removeLast()
        let modifiers = parts.compactMap(Modifier.init(rawValue:))
        guard modifiers.count == parts.count, Set(modifiers).count == modifiers.count, let character = Self.character(for: key),
              !Set(modifiers).isDisjoint(with: [.cmd, .ctrl]) || Self.isFunctionKey(character) else {
            throw PluginError.invalidShortcut(text)
        }
        self.modifiers = Set(modifiers)
        self.key = key
    }

    /// The shortcut as a manifest writes it, with the modifiers in menu order.
    public var description: String {
        (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+")
    }

    /// The key equivalent of a menu item: the character, uppercase for a letter with Shift as the menu bar's own items write it, or the `NSEvent` character of a named key.
    public var keyEquivalent: String {
        // The initializer accepted only keys that have a character.
        let character = Self.character(for: key)!
        return modifiers.contains(.shift) ? character.uppercased() : character
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        let flags: [Modifier: NSEvent.ModifierFlags] = [.ctrl: .control, .opt: .option, .shift: .shift, .cmd: .command]
        return modifiers.reduce(into: []) { $0.formUnion(flags[$1]!) }
    }

    /// The character a menu item's key equivalent uses for `key`, or nil for a key the rules do not name.
    private static func character(for key: String) -> String? {
        switch key {
        case "plus": return "+"
        case "space": return " "
        case "up": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "left": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default:
            if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...20).contains(number), key == "f\(number)" {
                return String(UnicodeScalar(NSF1FunctionKey + number - 1)!)
            }
            guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first, (0x21...0x7E).contains(scalar.value), key != "+" else { return nil }
            return key
        }
    }

    private static func isFunctionKey(_ character: String) -> Bool {
        character.unicodeScalars.first.map { (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains($0.value) } == true
    }
}
