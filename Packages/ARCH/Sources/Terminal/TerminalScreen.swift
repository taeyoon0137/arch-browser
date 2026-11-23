// The terminal's character grid: the visible lines, the scrollback above them, the cursor, and the modes programs set. It applies the parser's actions as VT-style terminals with xterm's common extensions do, which covers shells, installers that redraw progress lines, and full-screen programs such as command-line AI tools. It does not reflow lines when the size changes.
import Foundation

/// The grid's size in character columns and rows.
struct TerminalSize: Equatable {
    var columns: Int
    var rows: Int
}

/// A cell's foreground or background color, as SGR sets it.
enum TerminalColor: Equatable {
    /// The terminal's own foreground or background color.
    case `default`
    /// One of the 256 colors of the xterm palette.
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// The SGR attributes a cell is drawn with.
struct TerminalStyle: Equatable {
    var foreground = TerminalColor.default
    var background = TerminalColor.default
    var isBold = false
    var isFaint = false
    var isItalic = false
    var isUnderlined = false
    var isInverse = false
}

/// One column of a line: its text, style, and width.
struct TerminalCell: Equatable {
    /// A grapheme, or empty for the second column of a wide character.
    var text: String
    var style: TerminalStyle
    /// 2 for a wide character such as a Hangul syllable, 0 for the column after one, else 1.
    var width: Int

    /// A space in `background`, as erasing leaves it.
    static func blank(_ background: TerminalColor = .default) -> TerminalCell {
        TerminalCell(text: " ", style: TerminalStyle(background: background), width: 1)
    }
}

/// One row of cells, visible or in the scrollback.
struct TerminalLine: Equatable {
    var cells: [TerminalCell]
    /// The text continues on the next line because it reached the right margin.
    var isWrapped = false

    init(columns: Int, background: TerminalColor = .default) {
        cells = Array(repeating: .blank(background), count: columns)
    }

    /// The line cut or padded to `columns`, without half of a wide character at its end.
    func fitted(to columns: Int) -> TerminalLine {
        var line = self
        if cells.count > columns {
            line.cells.removeLast(cells.count - columns)
            if line.cells.last?.width == 2 { line.cells[columns - 1] = .blank(line.cells[columns - 1].style.background) }
        } else {
            line.cells += Array(repeating: .blank(), count: columns - cells.count)
        }
        return line
    }
}

/// A character position across the scrollback and the visible lines. `line` counts from the first line the terminal ever kept, so it names the same line while output scrolls.
struct TerminalPosition: Comparable {
    var line: Int
    var column: Int

    static func < (lhs: TerminalPosition, rhs: TerminalPosition) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

/// Applies the parser's actions to the grid, the scrollback, the cursor, and the modes.
final class TerminalScreen {
    struct Cursor: Equatable {
        var row = 0
        var column = 0
        var style = TerminalStyle()
        /// Set once a character fills the last column; the next character wraps to a new line first.
        var pendingWrap = false
    }

    static let scrollbackLimit = 10_000
    /// The scrollback is trimmed in batches, so scrolling does not move the whole scrollback for each line.
    private static let scrollbackTrimBatch = 1_000
    private static let tabWidth = 8
    /// The most scalars one cell holds, so a flood of combining marks cannot grow one cell's text, which each redraw lays out, without bound. Real graphemes, such as emoji sequences, have far fewer.
    private static let maximumCellScalars = 32

    private(set) var size: TerminalSize
    /// Lines that scrolled off the top of the main screen, oldest first. They keep the width they had, less the blank cells at the end of a line that did not wrap.
    private(set) var scrollback: [TerminalLine] = []
    /// Lines removed from the scrollback's start because of its limit or a clear.
    private(set) var droppedLineCount = 0
    /// The visible lines, top first.
    private(set) var lines: [TerminalLine]
    private(set) var cursor = Cursor()
    private(set) var isCursorVisible = true
    private(set) var usesApplicationCursorKeys = false
    private(set) var usesBracketedPaste = false
    /// The title a program set, or empty.
    private(set) var title = ""
    /// Answers to a program's queries, such as for the cursor position, to write back to the program.
    var onReply: ((Data) -> Void)?

    private var parser = TerminalParser()
    /// The main screen's lines while the alternate screen shows.
    private var mainLines: [TerminalLine]?
    /// The main screen's cursor, saved while the alternate screen shows.
    private var mainCursor: Cursor?
    private var savedCursor: Cursor?
    private var scrollTop = 0
    /// The last row of the scroll region.
    private var scrollBottom: Int
    private var autowraps = true
    /// For the repeat sequence, which prints the last character again.
    private var lastPrinted: Unicode.Scalar?

    init(size: TerminalSize) {
        self.size = size
        lines = Array(repeating: TerminalLine(columns: size.columns), count: size.rows)
        scrollBottom = size.rows - 1
    }

    var isAlternateScreen: Bool { mainLines != nil }

    /// The scrollback and the visible lines together.
    var lineCount: Int { scrollback.count + lines.count }

    /// A line of the scrollback and the visible lines together, by index from the scrollback's start.
    func line(at index: Int) -> TerminalLine {
        index < scrollback.count ? scrollback[index] : lines[index - scrollback.count]
    }

    func feed(_ data: Data) {
        parser.parse(data) { perform($0) }
    }

    /// Fits the lines to a new size. When the screen gets shorter, lines above the cursor move to the scrollback so the cursor's line stays in view; when it gets taller, blank lines are added below.
    func resize(to newSize: TerminalSize) {
        guard newSize != size, newSize.columns > 0, newSize.rows > 0 else { return }
        if let main = mainLines {
            // The main screen's cursor is its own only when mode 1049 saved it.
            let mainShift = max(0, (mainCursor ?? cursor).row - (newSize.rows - 1))
            mainLines = fitted(main, removingTop: mainShift, to: newSize, keepsRemovedLines: true)
            mainCursor?.row -= mainShift
            mainCursor = mainCursor.map { Self.clamped($0, to: newSize) }
        }
        let shift = max(0, cursor.row - (newSize.rows - 1))
        lines = fitted(lines, removingTop: shift, to: newSize, keepsRemovedLines: !isAlternateScreen)
        cursor.row -= shift
        size = newSize
        cursor = Self.clamped(cursor, to: newSize)
        savedCursor = savedCursor.map { Self.clamped($0, to: newSize) }
        scrollTop = 0
        scrollBottom = newSize.rows - 1
    }

    // MARK: Selection text

    /// The text between two positions, with each line's trailing spaces removed and lines that wrapped joined.
    func text(from start: TerminalPosition, to end: TerminalPosition) -> String {
        let firstLine = max(start.line, droppedLineCount)
        guard firstLine <= end.line else { return "" }
        var text = ""
        for absolute in firstLine...end.line {
            let index = absolute - droppedLineCount
            guard index < lineCount else { break }
            let line = line(at: index)
            let first = absolute == start.line ? start.column : 0
            let last = absolute == end.line ? min(end.column, line.cells.count) : line.cells.count
            guard first < last else {
                if absolute != end.line, !line.isWrapped { text += "\n" }
                continue
            }
            var segment = line.cells[first..<last].map(\.text).joined()
            if !line.isWrapped || absolute == end.line {
                while segment.last == " " { segment.removeLast() }
            }
            text += segment
            if absolute != end.line, !line.isWrapped { text += "\n" }
        }
        return text
    }

    /// The run of characters other than spaces around `position`, such as an address or a code, as a range of positions; the end is exclusive.
    func word(at position: TerminalPosition) -> (start: TerminalPosition, end: TerminalPosition)? {
        let index = position.line - droppedLineCount
        guard index >= 0, index < lineCount else { return nil }
        let cells = line(at: index).cells
        guard position.column < cells.count, cells[position.column].text != " " else { return nil }
        let isWordCell = { (column: Int) in cells[column].text != " " }
        var first = position.column
        while first > 0, isWordCell(first - 1) { first -= 1 }
        var last = position.column + 1
        while last < cells.count, isWordCell(last) { last += 1 }
        return (TerminalPosition(line: position.line, column: first), TerminalPosition(line: position.line, column: last))
    }

    // MARK: Actions

    private func perform(_ action: TerminalAction) {
        switch action {
        case .print(let scalar):
            put(scalar)
        case .control(let byte):
            control(byte)
        case .escape(let intermediates, let final):
            escape(intermediates: intermediates, final: final)
        case .controlSequence(let parameters, let privateMarker, let intermediates, let final):
            controlSequence(Parameters(values: parameters), privateMarker: privateMarker, intermediates: intermediates, final: final)
        case .operatingSystemCommand(let command):
            operatingSystemCommand(command)
        }
    }

    private func put(_ scalar: Unicode.Scalar) {
        var width = scalar.terminalWidth
        guard width > 0 else { return combine(scalar) }
        if width > size.columns { width = 1 }
        lastPrinted = scalar
        if cursor.pendingWrap, autowraps { wrapLine() }
        // A wide character never splits across lines.
        if width == 2, cursor.column == size.columns - 1 {
            guard autowraps else { return }
            lines[cursor.row].cells[cursor.column] = .blank(cursor.style.background)
            wrapLine()
        }
        let column = cursor.column
        separateWideCharacters(row: cursor.row, columns: column..<(column + width))
        lines[cursor.row].cells[column] = TerminalCell(text: String(scalar), style: cursor.style, width: width)
        if width == 2 { lines[cursor.row].cells[column + 1] = TerminalCell(text: "", style: cursor.style, width: 0) }
        if column + width >= size.columns {
            cursor.column = size.columns - 1
            cursor.pendingWrap = true
        } else {
            cursor.column = column + width
            cursor.pendingWrap = false
        }
    }

    /// A combining mark or other zero-width character joins the character before the cursor.
    private func combine(_ scalar: Unicode.Scalar) {
        var column = cursor.pendingWrap ? cursor.column : cursor.column - 1
        while column > 0, lines[cursor.row].cells[column].width == 0 { column -= 1 }
        guard column >= 0, lines[cursor.row].cells[column].text.unicodeScalars.count < Self.maximumCellScalars else { return }
        lines[cursor.row].cells[column].text.unicodeScalars.append(scalar)
    }

    private func control(_ byte: UInt8) {
        switch byte {
        case 0x08:
            moveCursor(column: cursor.column - 1)
        case 0x09:
            moveCursor(column: nextTabStop(after: cursor.column))
        case 0x0A, 0x0B, 0x0C:
            index()
        case 0x0D:
            moveCursor(column: 0)
        default:
            break
        }
    }

    private func escape(intermediates: [UInt8], final: UInt8) {
        guard intermediates.isEmpty else { return }
        switch final {
        case UInt8(ascii: "7"): savedCursor = cursor
        case UInt8(ascii: "8"): restoreCursor()
        case UInt8(ascii: "D"): index()
        case UInt8(ascii: "E"):
            moveCursor(column: 0)
            index()
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "c"): reset()
        default: break
        }
    }

    private func controlSequence(_ parameters: Parameters, privateMarker: UInt8?, intermediates: [UInt8], final: UInt8) {
        guard intermediates.isEmpty else { return }
        switch (privateMarker, final) {
        case (UInt8(ascii: "?"), UInt8(ascii: "h")), (UInt8(ascii: "?"), UInt8(ascii: "l")):
            parameters.values.forEach { setPrivateMode($0, to: final == UInt8(ascii: "h")) }
        case (UInt8(ascii: ">"), UInt8(ascii: "c")):
            reply("\u{1B}[>0;0;0c")
        case (nil, _), (UInt8(ascii: "?"), UInt8(ascii: "J")), (UInt8(ascii: "?"), UInt8(ascii: "K")):
            standardControlSequence(parameters, final: final)
        default:
            break
        }
    }

    private func standardControlSequence(_ parameters: Parameters, final: UInt8) {
        let count = parameters.count(at: 0)
        switch final {
        case UInt8(ascii: "@"): insertCharacters(count)
        case UInt8(ascii: "A"): moveCursor(row: max(cursor.row - count, cursor.row >= scrollTop ? scrollTop : 0))
        case UInt8(ascii: "B"), UInt8(ascii: "e"): moveCursor(row: min(cursor.row + count, cursor.row <= scrollBottom ? scrollBottom : size.rows - 1))
        case UInt8(ascii: "C"), UInt8(ascii: "a"): moveCursor(column: cursor.column + count)
        case UInt8(ascii: "D"): moveCursor(column: cursor.column - count)
        case UInt8(ascii: "E"): moveCursor(row: cursor.row + count, column: 0)
        case UInt8(ascii: "F"): moveCursor(row: cursor.row - count, column: 0)
        case UInt8(ascii: "G"), UInt8(ascii: "`"): moveCursor(column: count - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"): moveCursor(row: parameters.count(at: 0) - 1, column: parameters.count(at: 1) - 1)
        case UInt8(ascii: "I"): (0..<count).forEach { _ in moveCursor(column: nextTabStop(after: cursor.column)) }
        case UInt8(ascii: "J"): eraseInDisplay(parameters.value(at: 0))
        case UInt8(ascii: "K"): eraseInLine(parameters.value(at: 0))
        case UInt8(ascii: "L"): insertLines(count)
        case UInt8(ascii: "M"): deleteLines(count)
        case UInt8(ascii: "P"): deleteCharacters(count)
        case UInt8(ascii: "S"): scrollUp(count)
        case UInt8(ascii: "T"): scrollDown(count)
        case UInt8(ascii: "X"): eraseCharacters(count)
        case UInt8(ascii: "Z"): (0..<count).forEach { _ in moveCursor(column: previousTabStop(before: cursor.column)) }
        case UInt8(ascii: "b"): if let lastPrinted { (0..<min(count, size.columns * size.rows)).forEach { _ in put(lastPrinted) } }
        case UInt8(ascii: "c"): if parameters.value(at: 0) == 0 { reply("\u{1B}[?1;2c") }
        case UInt8(ascii: "d"): moveCursor(row: count - 1)
        case UInt8(ascii: "m"): selectGraphicRendition(parameters.values)
        case UInt8(ascii: "n"): reportStatus(parameters.value(at: 0))
        case UInt8(ascii: "r"): setScrollRegion(top: parameters.count(at: 0) - 1, bottom: (parameters.values.count > 1 && parameters.values[1] > 0 ? parameters.values[1] : size.rows) - 1)
        case UInt8(ascii: "s"): if parameters.values.isEmpty { savedCursor = cursor }
        case UInt8(ascii: "u"): if parameters.values.isEmpty { restoreCursor() }
        default: break
        }
    }

    private func operatingSystemCommand(_ command: String) {
        guard let separator = command.firstIndex(of: ";") else { return }
        switch command[..<separator] {
        case "0", "2": title = String(command[command.index(after: separator)...])
        default: break
        }
    }

    // MARK: Cursor

    /// Moves the cursor within the screen. Any move ends a pending wrap.
    private func moveCursor(row: Int? = nil, column: Int? = nil) {
        cursor.row = min(max(row ?? cursor.row, 0), size.rows - 1)
        cursor.column = min(max(column ?? cursor.column, 0), size.columns - 1)
        cursor.pendingWrap = false
    }

    private func restoreCursor() {
        cursor = Self.clamped(savedCursor ?? Cursor(), to: size)
    }

    private static func clamped(_ cursor: Cursor, to size: TerminalSize) -> Cursor {
        var cursor = cursor
        cursor.row = min(max(cursor.row, 0), size.rows - 1)
        cursor.column = min(max(cursor.column, 0), size.columns - 1)
        return cursor
    }

    private func nextTabStop(after column: Int) -> Int {
        min((column / Self.tabWidth + 1) * Self.tabWidth, size.columns - 1)
    }

    private func previousTabStop(before column: Int) -> Int {
        max(((column - 1) / Self.tabWidth) * Self.tabWidth, 0)
    }

    /// Moves the cursor down a line, scrolling the region up at its bottom margin.
    private func index() {
        if cursor.row == scrollBottom {
            scrollUp(1)
        } else if cursor.row < size.rows - 1 {
            cursor.row += 1
        }
        cursor.pendingWrap = false
    }

    private func reverseIndex() {
        if cursor.row == scrollTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
        cursor.pendingWrap = false
    }

    private func wrapLine() {
        lines[cursor.row].isWrapped = true
        cursor.column = 0
        index()
    }

    // MARK: Editing

    private func blankLine() -> TerminalLine {
        TerminalLine(columns: size.columns, background: cursor.style.background)
    }

    /// Lines that leave the top of the whole main screen go to the scrollback.
    private func scrollUp(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            let removed = lines.remove(at: scrollTop)
            if scrollTop == 0, !isAlternateScreen { appendToScrollback(removed) }
            lines.insert(blankLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: scrollTop)
        }
    }

    /// A line that did not wrap loses its blank cells at the end, which hold nothing to draw or copy, so the scrollback does not keep a full row of cells for each short line. A wrapped line keeps them, since they are part of the text it continues.
    private func appendToScrollback(_ line: TerminalLine) {
        var line = line
        if !line.isWrapped {
            let kept = (line.cells.lastIndex { $0 != .blank() } ?? -1) + 1
            // A new array, since removing elements keeps the old storage.
            if kept < line.cells.count { line.cells = Array(line.cells[..<kept]) }
        }
        scrollback.append(line)
        guard scrollback.count >= Self.scrollbackLimit + Self.scrollbackTrimBatch else { return }
        let excess = scrollback.count - Self.scrollbackLimit
        scrollback.removeFirst(excess)
        droppedLineCount += excess
    }

    private func insertLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursor.row) else { return }
        for _ in 0..<min(count, scrollBottom - cursor.row + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: cursor.row)
        }
        moveCursor(column: 0)
    }

    private func deleteLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursor.row) else { return }
        for _ in 0..<min(count, scrollBottom - cursor.row + 1) {
            lines.remove(at: cursor.row)
            lines.insert(blankLine(), at: scrollBottom)
        }
        moveCursor(column: 0)
    }

    private func insertCharacters(_ count: Int) {
        let row = cursor.row, column = cursor.column
        let count = min(count, size.columns - column)
        separateWideCharacters(row: row, columns: column..<size.columns)
        lines[row].cells.insert(contentsOf: Array(repeating: .blank(cursor.style.background), count: count), at: column)
        lines[row].cells.removeLast(count)
        // A wide character pushed to the last column lost its second half.
        if lines[row].cells[size.columns - 1].width == 2 { lines[row].cells[size.columns - 1] = .blank(cursor.style.background) }
        cursor.pendingWrap = false
    }

    private func deleteCharacters(_ count: Int) {
        let row = cursor.row, column = cursor.column
        let count = min(count, size.columns - column)
        separateWideCharacters(row: row, columns: column..<(column + count))
        lines[row].cells.removeSubrange(column..<(column + count))
        lines[row].cells += Array(repeating: .blank(cursor.style.background), count: count)
        cursor.pendingWrap = false
    }

    private func eraseCharacters(_ count: Int) {
        erase(row: cursor.row, columns: cursor.column..<min(cursor.column + count, size.columns))
        cursor.pendingWrap = false
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: erase(row: cursor.row, columns: cursor.column..<size.columns)
        case 1: erase(row: cursor.row, columns: 0..<(cursor.column + 1))
        case 2: erase(row: cursor.row, columns: 0..<size.columns)
        default: return
        }
        if mode != 1 { lines[cursor.row].isWrapped = false }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursor.row + 1)..<size.rows { lines[row] = blankLine() }
        case 1:
            for row in 0..<cursor.row { lines[row] = blankLine() }
            eraseInLine(1)
        case 2:
            for row in 0..<size.rows { lines[row] = blankLine() }
        case 3:
            droppedLineCount += scrollback.count
            scrollback.removeAll()
        default:
            break
        }
    }

    private func erase(row: Int, columns: Range<Int>) {
        guard !columns.isEmpty else { return }
        separateWideCharacters(row: row, columns: columns)
        for column in columns { lines[row].cells[column] = .blank(cursor.style.background) }
    }

    /// Clears the other half of any wide character that `columns` cut through, so no half is left behind.
    private func separateWideCharacters(row: Int, columns: Range<Int>) {
        let cells = lines[row].cells
        if columns.lowerBound > 0, columns.lowerBound < cells.count, cells[columns.lowerBound].width == 0 {
            lines[row].cells[columns.lowerBound - 1] = .blank(cells[columns.lowerBound - 1].style.background)
        }
        if columns.upperBound < cells.count, cells[columns.upperBound].width == 0 {
            lines[row].cells[columns.upperBound] = .blank(cells[columns.upperBound].style.background)
        }
    }

    private func fitted(_ lines: [TerminalLine], removingTop count: Int, to newSize: TerminalSize, keepsRemovedLines: Bool) -> [TerminalLine] {
        if keepsRemovedLines { lines.prefix(count).forEach(appendToScrollback) }
        var fitted = lines.dropFirst(count).prefix(newSize.rows).map { $0.fitted(to: newSize.columns) }
        while fitted.count < newSize.rows { fitted.append(TerminalLine(columns: newSize.columns)) }
        return fitted
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let top = max(top, 0), bottom = min(bottom, size.rows - 1)
        guard top < bottom else { return }
        scrollTop = top
        scrollBottom = bottom
        moveCursor(row: 0, column: 0)
    }

    // MARK: Modes

    private func setPrivateMode(_ mode: Int, to isOn: Bool) {
        switch mode {
        case 1: usesApplicationCursorKeys = isOn
        case 7: autowraps = isOn
        case 25: isCursorVisible = isOn
        case 47, 1047: showAlternateScreen(isOn)
        case 1049:
            if isOn {
                guard !isAlternateScreen else { return }
                mainCursor = cursor
                showAlternateScreen(true)
            } else {
                showAlternateScreen(false)
                if let mainCursor { cursor = mainCursor }
                mainCursor = nil
            }
        case 2004: usesBracketedPaste = isOn
        default: break
        }
    }

    /// The alternate screen starts blank and keeps no scrollback; leaving it shows the main screen as it was.
    private func showAlternateScreen(_ isOn: Bool) {
        if isOn, mainLines == nil {
            mainLines = lines
            lines = Array(repeating: TerminalLine(columns: size.columns), count: size.rows)
        } else if !isOn, let main = mainLines {
            lines = main
            mainLines = nil
        }
    }

    /// Clears the screen and returns every mode to its default; the scrollback stays.
    private func reset() {
        showAlternateScreen(false)
        mainCursor = nil
        lines = Array(repeating: TerminalLine(columns: size.columns), count: size.rows)
        cursor = Cursor()
        savedCursor = nil
        scrollTop = 0
        scrollBottom = size.rows - 1
        autowraps = true
        isCursorVisible = true
        usesApplicationCursorKeys = false
        usesBracketedPaste = false
    }

    // MARK: Graphic rendition

    private func selectGraphicRendition(_ values: [Int]) {
        var values = ArraySlice(values.isEmpty ? [0] : values)
        while let value = values.popFirst() {
            switch value {
            case 0: cursor.style = TerminalStyle()
            case 1: cursor.style.isBold = true
            case 2: cursor.style.isFaint = true
            case 3: cursor.style.isItalic = true
            case 4, 21: cursor.style.isUnderlined = true
            case 7: cursor.style.isInverse = true
            case 22:
                cursor.style.isBold = false
                cursor.style.isFaint = false
            case 23: cursor.style.isItalic = false
            case 24: cursor.style.isUnderlined = false
            case 27: cursor.style.isInverse = false
            case 30...37: cursor.style.foreground = .indexed(UInt8(value - 30))
            case 38: cursor.style.foreground = Self.extendedColor(&values) ?? cursor.style.foreground
            case 39: cursor.style.foreground = .default
            case 40...47: cursor.style.background = .indexed(UInt8(value - 40))
            case 48: cursor.style.background = Self.extendedColor(&values) ?? cursor.style.background
            case 49: cursor.style.background = .default
            case 90...97: cursor.style.foreground = .indexed(UInt8(value - 90 + 8))
            case 100...107: cursor.style.background = .indexed(UInt8(value - 100 + 8))
            default: break
            }
        }
    }

    /// `5;n` for a palette color or `2;r;g;b` for a direct one, taken from the values that follow 38 or 48.
    private static func extendedColor(_ values: inout ArraySlice<Int>) -> TerminalColor? {
        switch values.popFirst() {
        case 5:
            return values.popFirst().map { .indexed(UInt8(clamping: $0)) }
        case 2:
            guard values.count >= 3 else { return nil }
            let red = values.popFirst()!, green = values.popFirst()!, blue = values.popFirst()!
            return .rgb(UInt8(clamping: red), UInt8(clamping: green), UInt8(clamping: blue))
        default:
            return nil
        }
    }

    // MARK: Reports

    private func reportStatus(_ request: Int) {
        switch request {
        case 5: reply("\u{1B}[0n")
        case 6: reply("\u{1B}[\(cursor.row + 1);\(cursor.column + 1)R")
        default: break
        }
    }

    private func reply(_ text: String) {
        onReply?(Data(text.utf8))
    }
}

/// A control sequence's parameters, where 0 or a missing value means the sequence's default.
private struct Parameters {
    var values: [Int]

    func value(at index: Int) -> Int {
        index < values.count ? values[index] : 0
    }

    /// A count or position, which defaults to 1.
    func count(at index: Int) -> Int {
        max(value(at: index), 1)
    }
}

extension Unicode.Scalar {
    /// The columns a character takes: 2 for East Asian wide and fullwidth characters and emoji, 0 for combining marks, controls, and Hangul vowel and final consonant jamo, which join the character before them, else 1.
    var terminalWidth: Int {
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: return 0
        default: break
        }
        if Self.combiningJamo.contains(where: { $0.contains(value) }) { return 0 }
        if properties.isEmojiPresentation || Self.wideRanges.contains(where: { $0.contains(value) }) { return 2 }
        return 1
    }

    private static let combiningJamo: [ClosedRange<UInt32>] = [0x1160...0x11FF, 0xD7B0...0xD7FF]

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, // Hangul initial consonant jamo
        0x2E80...0x303E, // CJK radicals, symbols, and punctuation
        0x3041...0x33FF, // Hiragana, Katakana, Bopomofo, and CJK compatibility
        0x3400...0x4DBF, // CJK unified ideographs extension A
        0x4E00...0x9FFF, // CJK unified ideographs
        0xA000...0xA4CF, // Yi
        0xA960...0xA97F, // Hangul jamo extended A
        0xAC00...0xD7A3, // Hangul syllables
        0xF900...0xFAFF, // CJK compatibility ideographs
        0xFE10...0xFE19, // Vertical forms
        0xFE30...0xFE6F, // CJK compatibility and small forms
        0xFF00...0xFF60, // Fullwidth forms
        0xFFE0...0xFFE6, // Fullwidth signs
        0x20000...0x2FFFD, // CJK unified ideographs extensions
        0x30000...0x3FFFD,
    ]
}
