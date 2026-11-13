// The key events that the Chromium adapter's input sends through the bridge for a press and for text, which need no engine: a key's down and up with the character it types between them, text as a character event per character with its key's code, and the presses and text it refuses. Delivery to a page needs the engine and the app (`docs/agents.md`, check 69).
import ARCHEngine
import CEFBridge
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumInputTests {
    private typealias KeyEvent = ChromiumInput.KeyEvent

    @Test func aPressSendsTheKeysDownAndUpWithTheCharacterItTypesBetween() throws {
        let enter = try ChromiumInput.keyEvents(for: .enter, modifiers: [])
        #expect(enter == [.down, .character, .up].map { KeyEvent(kind: $0, keyCode: 0x24, character: 0x0D, unmodifiedCharacter: 0x0D) })
        let escape = try ChromiumInput.keyEvents(for: .escape, modifiers: [.shift])
        #expect(escape == [.down, .up].map { KeyEvent(kind: $0, keyCode: 0x35, character: 0x1B, unmodifiedCharacter: 0x1B) })
        let shifted = try ChromiumInput.keyEvents(for: .character("a"), modifiers: [.shift])
        #expect(shifted == [.down, .character, .up].map { KeyEvent(kind: $0, keyCode: 0x00, character: 0x41, unmodifiedCharacter: 0x41) })
    }

    @Test func aPressWithCommandOrControlTypesNoCharacter() throws {
        let command = try ChromiumInput.keyEvents(for: .character("a"), modifiers: [.command])
        #expect(command == [.down, .up].map { KeyEvent(kind: $0, keyCode: 0x00, character: 0x61, unmodifiedCharacter: 0x61) })
        let control = try ChromiumInput.keyEvents(for: .character("a"), modifiers: [.control])
        #expect(control.map(\.kind) == [.down, .up] && control.allSatisfy { $0.character == 0x01 && $0.unmodifiedCharacter == 0x61 })
    }

    @Test func aCharacterWithoutAKeyCannotBePressed() {
        #expect(throws: EngineInputError.unsupported) { try ChromiumInput.keyEvents(for: .character("é"), modifiers: []) }
    }

    @Test func textGoesAsACharacterEventPerCharacterWithItsKeysCode() throws {
        let events = try ChromiumInput.textEvents(for: "Hé! 가")
        #expect(events == [
            KeyEvent(kind: .character, keyCode: 0x04, character: 0x48, unmodifiedCharacter: 0x48),
            KeyEvent(kind: .character, keyCode: ChromiumInput.noKeyCode, character: 0xE9, unmodifiedCharacter: 0xE9),
            KeyEvent(kind: .character, keyCode: 0x12, character: 0x21, unmodifiedCharacter: 0x21),
            KeyEvent(kind: .character, keyCode: ChromiumInput.noKeyCode, character: 0x20, unmodifiedCharacter: 0x20),
            KeyEvent(kind: .character, keyCode: ChromiumInput.noKeyCode, character: 0xAC00, unmodifiedCharacter: 0xAC00),
        ])
    }

    /// A line break would submit a single-line field's form, and a character event carries one UTF-16 unit.
    @Test func textWithALineBreakOrOutsideTheBasicPlaneIsRefused() {
        #expect(throws: EngineInputError.unsupported) { try ChromiumInput.textEvents(for: "a\nb") }
        #expect(throws: EngineInputError.unsupported) { try ChromiumInput.textEvents(for: "a\r\nb") }
        #expect(throws: EngineInputError.unsupported) { try ChromiumInput.textEvents(for: "ok 👍") }
    }
}
