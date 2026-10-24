// The terminal's parser and screen: wrapping, cursor movement and erasing, wide and combining characters, colors, scroll regions and the scrollback, the alternate screen, replies to queries, titles, UTF-8 across reads, resizing, and the text a selection copies.
import Foundation
import Testing
@testable import Terminal

@Suite struct TerminalScreenTests {
    @Test func textWrapsAtTheRightMarginAndCopiesAsOneLine() {
        let screen = screen(columns: 5, rows: 3)
        screen.feed("abcdefg\r\nxy")
        #expect(rows(screen) == ["abcde", "fg", "xy"])
        #expect(screen.lines[0].isWrapped)
        #expect(screen.text(from: position(screen, 0, 0), to: position(screen, 2, 5)) == "abcdefg\nxy")
    }

    @Test func controlCharactersMoveTheCursor() {
        let screen = screen(columns: 20, rows: 2)
        screen.feed("abc\rX\tY\u{8}Z")
        #expect(rows(screen)[0] == "Xbc     Z")
    }

    @Test func cursorMovesAndErasing() {
        let screen = screen(columns: 10, rows: 3)
        screen.feed("1111111111\r\n2222222222\r\n3333333333")
        screen.feed("\u{1B}[2;4H\u{1B}[K")
        #expect(rows(screen) == ["1111111111", "222", "3333333333"])
        screen.feed("\u{1B}[1;3H\u{1B}[1K\u{1B}[3;5H\u{1B}[2X")
        #expect(rows(screen) == ["   1111111", "222", "3333  3333"])
        screen.feed("\u{1B}[2J")
        #expect(rows(screen) == ["", "", ""])
    }

    @Test func insertingAndDeletingCharactersAndLines() {
        let screen = screen(columns: 6, rows: 3)
        screen.feed("abcdef\r\nghijkl\r\nmnopqr\u{1B}[1;2H\u{1B}[2P")
        #expect(rows(screen)[0] == "adef")
        screen.feed("\u{1B}[1@")
        #expect(rows(screen)[0] == "a def")
        screen.feed("\u{1B}[2;1H\u{1B}[L")
        #expect(rows(screen) == ["a def", "", "ghijkl"])
        screen.feed("\u{1B}[M")
        #expect(rows(screen) == ["a def", "ghijkl", ""])
    }

    @Test func wideCharactersTakeTwoColumnsAndNeverSplit() {
        let screen = screen(columns: 5, rows: 2)
        screen.feed("ab\u{D55C}\u{AE00}")
        #expect(rows(screen) == ["ab\u{D55C}", "\u{AE00}"])
        #expect(screen.lines[0].cells[2].width == 2)
        #expect(screen.lines[0].cells[3].width == 0)
        // Overwriting the second half of a wide character clears its first half.
        screen.feed("\u{1B}[1;4Hx")
        #expect(rows(screen)[0] == "ab x")
    }

    @Test func combiningMarksJoinTheCharacterBefore() {
        let screen = screen(columns: 10, rows: 1)
        // An accented letter and a Hangul syllable in decomposed form.
        screen.feed("e\u{301}\u{1112}\u{1161}\u{11AB}!")
        #expect(screen.lines[0].cells[0].text == "e\u{301}")
        #expect(screen.lines[0].cells[1].text == "\u{1112}\u{1161}\u{11AB}")
        #expect(screen.lines[0].cells[3].text == "!")
    }

    @Test func graphicRenditionSetsColorsAndAttributes() {
        let screen = screen(columns: 10, rows: 1)
        screen.feed("\u{1B}[1;31ma\u{1B}[38;5;200;48;2;1;2;3mb\u{1B}[0mc\u{1B}[7;94md")
        let cells = screen.lines[0].cells
        #expect(cells[0].style == TerminalStyle(foreground: .indexed(1), isBold: true))
        #expect(cells[1].style == TerminalStyle(foreground: .indexed(200), background: .rgb(1, 2, 3), isBold: true))
        #expect(cells[2].style == TerminalStyle())
        #expect(cells[3].style == TerminalStyle(foreground: .indexed(12), isInverse: true))
    }

    @Test func onlyLinesLeavingTheWholeScreenGoToTheScrollback() {
        let screen = screen(columns: 4, rows: 3)
        screen.feed("1\r\n2\r\n3\r\n4")
        #expect(screen.scrollback.count == 1)
        #expect(rows(screen) == ["2", "3", "4"])
        // A region of the last two rows scrolls without adding to the scrollback.
        screen.feed("\u{1B}[2;3r\u{1B}[3;1H\n5")
        #expect(rows(screen) == ["2", "4", "5"])
        #expect(screen.scrollback.count == 1)
    }

    @Test func theAlternateScreenRestoresTheMainScreen() {
        let screen = screen(columns: 6, rows: 2)
        screen.feed("shell\u{1B}[?1049h")
        #expect(screen.isAlternateScreen)
        #expect(rows(screen) == ["", ""])
        screen.feed("full\r\nscreen\r\nmore")
        #expect(screen.scrollback.isEmpty)
        screen.feed("\u{1B}[?1049l")
        #expect(!screen.isAlternateScreen)
        #expect(rows(screen) == ["shell", ""])
        #expect(screen.cursor.column == 5)
    }

    @Test func repliesToPositionAndDeviceQueries() {
        let screen = screen(columns: 10, rows: 5)
        var replies: [String] = []
        screen.onReply = { replies.append(String(decoding: $0, as: UTF8.self)) }
        screen.feed("\u{1B}[3;4H\u{1B}[6n\u{1B}[c\u{1B}[5n")
        #expect(replies == ["\u{1B}[3;4R", "\u{1B}[?1;2c", "\u{1B}[0n"])
    }

    @Test func modesAndTitles() {
        let screen = screen(columns: 10, rows: 2)
        screen.feed("\u{1B}[?1h\u{1B}[?2004h\u{1B}[?25l\u{1B}]2;Signing in\u{7}")
        #expect(screen.usesApplicationCursorKeys)
        #expect(screen.usesBracketedPaste)
        #expect(!screen.isCursorVisible)
        #expect(screen.title == "Signing in")
        screen.feed("\u{1B}]0;Done\u{1B}\\ok")
        #expect(screen.title == "Done")
        #expect(rows(screen)[0] == "ok")
    }

    @Test func utf8SplitBetweenReadsStaysWhole() {
        let screen = screen(columns: 10, rows: 1)
        let bytes = Array("\u{D55C}a".utf8)
        screen.feed(Data(bytes[..<2]))
        screen.feed(Data(bytes[2...]))
        screen.feed(Data([0xFF]))
        #expect(rows(screen)[0] == "\u{D55C}a\u{FFFD}")
    }

    @Test func shrinkingKeepsTheCursorLineInView() {
        let screen = screen(columns: 6, rows: 4)
        screen.feed("1\r\n2\r\n3\r\n4")
        screen.resize(to: TerminalSize(columns: 3, rows: 2))
        #expect(rows(screen) == ["3", "4"])
        #expect(screen.scrollback.count == 2)
        #expect(screen.cursor.row == 1)
        screen.resize(to: TerminalSize(columns: 3, rows: 3))
        #expect(rows(screen) == ["3", "4", ""])
    }

    @Test func aWordIsTheRunAroundAPosition() {
        let screen = screen(columns: 40, rows: 1)
        screen.feed("open https://example.org/login now")
        let word = screen.word(at: position(screen, 0, 10))
        #expect(word.map { screen.text(from: $0.start, to: $0.end) } == "https://example.org/login")
        #expect(screen.word(at: position(screen, 0, 4)) == nil)
    }
}

// MARK: - Helpers

private func screen(columns: Int, rows: Int) -> TerminalScreen {
    TerminalScreen(size: TerminalSize(columns: columns, rows: rows))
}

private extension TerminalScreen {
    func feed(_ text: String) {
        feed(Data(text.utf8))
    }
}

/// The visible lines as text without trailing spaces.
private func rows(_ screen: TerminalScreen) -> [String] {
    screen.lines.map { line in
        var text = line.cells.map(\.text).joined()
        while text.last == " " { text.removeLast() }
        return text
    }
}

/// A position on a visible row.
private func position(_ screen: TerminalScreen, _ row: Int, _ column: Int) -> TerminalPosition {
    TerminalPosition(line: screen.droppedLineCount + screen.scrollback.count + row, column: column)
}
