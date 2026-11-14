// How a key that `EngineInput` presses reads as macOS describes it, which both adapters build their events from: the US layout's key codes, AppKit's characters with Shift and Control, which presses type a character, and the keys DOM names.
import ARCHEngine
import Testing

@Suite struct EngineKeyTests {
    @Test func namedKeysHaveTheirKeyCodesAndCharacters() throws {
        #expect(EngineKey.enter.stroke(with: []) == EngineKeyStroke(keyCode: 0x24, characters: "\r", charactersIgnoringModifiers: "\r", typesCharacter: true))
        #expect(EngineKey.escape.stroke(with: []) == EngineKeyStroke(keyCode: 0x35, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", typesCharacter: false))
        #expect(EngineKey.backspace.stroke(with: [])?.characters == "\u{7F}")
        #expect(EngineKey.arrowUp.stroke(with: [.shift]) == EngineKeyStroke(keyCode: 0x7E, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", typesCharacter: false))
        #expect(EngineKey.tab.stroke(with: [])?.typesCharacter == false)
    }

    @Test func characterKeysFollowTheUSLayout() throws {
        #expect(EngineKey.character("a").stroke(with: []) == EngineKeyStroke(keyCode: 0x00, characters: "a", charactersIgnoringModifiers: "a", typesCharacter: true))
        #expect(EngineKey.character("a").stroke(with: [.shift]) == EngineKeyStroke(keyCode: 0x00, characters: "A", charactersIgnoringModifiers: "A", typesCharacter: true))
        #expect(EngineKey.character("1").stroke(with: [.shift])?.characters == "!")
        #expect(EngineKey.character("/").stroke(with: [.shift])?.keyCode == 0x2C)
        #expect(EngineKey.character("é").stroke(with: []) == nil)
        #expect(EngineKey.character("A").stroke(with: []) == nil)
    }

    @Test func commandAndControlTypeNoCharacter() throws {
        #expect(EngineKey.character("a").stroke(with: [.command]) == EngineKeyStroke(keyCode: 0x00, characters: "a", charactersIgnoringModifiers: "a", typesCharacter: false))
        #expect(EngineKey.character("a").stroke(with: [.control]) == EngineKeyStroke(keyCode: 0x00, characters: "\u{01}", charactersIgnoringModifiers: "a", typesCharacter: false))
        #expect(EngineKey.enter.stroke(with: [.command])?.typesCharacter == false)
        #expect(EngineKey.space.stroke(with: [.option])?.typesCharacter == true)
    }

    @Test func aCharacterTypedWithOrWithoutShiftHasItsKeysCode() {
        #expect(EngineKey.keyCode(typing: "h") == 0x04)
        #expect(EngineKey.keyCode(typing: "H") == 0x04)
        #expect(EngineKey.keyCode(typing: "?") == 0x2C)
        #expect(EngineKey.keyCode(typing: " ") == nil)
        #expect(EngineKey.keyCode(typing: "\n") == nil)
        #expect(EngineKey.keyCode(typing: "é") == nil)
    }

    @Test func domKeyNamesMapToKeys() {
        #expect(EngineKey(domKey: "Enter") == .enter)
        #expect(EngineKey(domKey: "ArrowLeft") == .arrowLeft)
        #expect(EngineKey(domKey: " ") == .space)
        #expect(EngineKey(domKey: "A") == .character("a"))
        #expect(EngineKey(domKey: "]") == .character("]"))
        #expect(EngineKey(domKey: "!") == nil)
        #expect(EngineKey(domKey: "F1") == nil)
        #expect(EngineKey(domKey: "") == nil)
    }
}
