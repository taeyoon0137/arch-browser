// The terminal view draws scrollback and the current screen inside a scroll view.
// It sends typed keys and pasted text to the program, and lets the user select text to copy.
// Input methods compose text at the cursor, including Hangul and other composed input.
import AppKit

final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {
    /// Bytes for the program, from typed keys and pasted text.
    var onInput: ((Data) -> Void)?
    /// Called when the grid gets a new size because the view's visible area changed.
    var onResize: ((TerminalSize) -> Void)?

    private static let inset: CGFloat = 6

    private let screen: TerminalScreen
    private let fonts = Fonts(size: 12)
    private let cellWidth: CGFloat
    private let lineHeight: CGFloat
    /// Text an input method is composing; it reaches the program once committed.
    private var markedText = NSAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var selection: (anchor: TerminalPosition, head: TerminalPosition)?

    init(screen: TerminalScreen) {
        self.screen = screen
        cellWidth = ("M" as NSString).size(withAttributes: [.font: fonts.regular]).width
        lineHeight = ceil(fonts.regular.ascender - fonts.regular.descender + fonts.regular.leading)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Focus

    /// Whether typing reaches the terminal: its window is key and the view has focus. Otherwise the cursor shows as an outline and the selection in the unemphasized color, as text views show theirs.
    private var isActive: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            guard let window else { continue }
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowDidChange), name: name, object: window)
        }
    }

    @objc private func keyWindowDidChange() {
        needsDisplay = true
    }

    // MARK: Layout

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clipView = superview as? NSClipView else { return }
        clipView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaDidResize), name: NSView.frameDidChangeNotification, object: clipView)
    }

    @objc private func visibleAreaDidResize() {
        let followsOutput = isScrolledToEnd
        updateLayout()
        if followsOutput { scrollToEnd() }
    }

    /// Fits the grid to the visible area and the view's height to every line.
    func updateLayout() {
        guard let visible = enclosingScrollView?.contentView.bounds.size else { return }
        let size = TerminalSize(columns: max(Int((visible.width - 2 * Self.inset) / cellWidth), 1),
                                rows: max(Int((visible.height - 2 * Self.inset) / lineHeight), 1))
        if size != screen.size {
            screen.resize(to: size)
            onResize?(size)
        }
        setFrameSize(NSSize(width: visible.width, height: max(CGFloat(screen.lineCount) * lineHeight + 2 * Self.inset, visible.height)))
        needsDisplay = true
    }

    /// Shows new output, and follows it when the newest lines were in view.
    func screenDidChange() {
        let followsOutput = isScrolledToEnd
        updateLayout()
        if followsOutput { scrollToEnd() }
        inputContext?.invalidateCharacterCoordinates()
    }

    private var isScrolledToEnd: Bool {
        visibleRect.maxY >= frame.height - lineHeight
    }

    private func scrollToEnd() {
        scroll(NSPoint(x: 0, y: max(frame.height - visibleRect.height, 0)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let first = max(Int((dirtyRect.minY - Self.inset) / lineHeight), 0)
        let last = min(Int((dirtyRect.maxY - Self.inset) / lineHeight), screen.lineCount - 1)
        if first <= last {
            for index in first...last { draw(screen.line(at: index), at: index) }
        }
        if markedText.length > 0 {
            drawMarkedText()
        } else if screen.isCursorVisible {
            let color = NSColor.textColor.withAlphaComponent(0.4)
            if isActive {
                color.setFill()
                cursorRect.fill()
            } else {
                color.setStroke()
                NSBezierPath(rect: cursorRect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }

    /// The selection's color, which follows whether typing reaches the terminal.
    private var selectionColor: NSColor {
        isActive ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
    }

    /// Backgrounds and the selection first, then text. Runs of plain ASCII in one style draw as one string, since every such character advances one cell in the monospaced font; any other character draws at its own cell, so fallback fonts with other widths keep the grid.
    private func draw(_ line: TerminalLine, at index: Int) {
        let top = Self.inset + CGFloat(index) * lineHeight
        let selected = selectedColumns(onLine: screen.droppedLineCount + index)
        let selectionColor = self.selectionColor
        for (column, cell) in line.cells.enumerated() where cell.width > 0 {
            let colors = Self.colors(for: cell.style)
            let background = selected?.contains(column) == true ? selectionColor : colors.background
            guard let background else { continue }
            background.setFill()
            cellRect(column: column, top: top, width: cell.width).fill()
        }
        // A scrollback line keeps no blank cells at its end, so the selection covers the rest of the row by itself.
        if let selected, line.cells.count < screen.size.columns {
            let start = max(selected.lowerBound, line.cells.count), end = min(selected.upperBound, screen.size.columns)
            if start < end {
                selectionColor.setFill()
                cellRect(column: start, top: top, width: end - start).fill()
            }
        }
        var run = ""
        var runStart = 0
        var runStyle = TerminalStyle()
        let drawRun = {
            if !run.isEmpty, runStyle.isUnderlined || run.contains(where: { $0 != " " }) {
                self.draw(run, style: runStyle, at: NSPoint(x: Self.inset + CGFloat(runStart) * self.cellWidth, y: top))
            }
            run = ""
        }
        for (column, cell) in line.cells.enumerated() where cell.width > 0 {
            if cell.width == 1, cell.text.utf8.count == 1, cell.text.utf8.first.map({ $0 >= 0x20 && $0 < 0x7F }) == true {
                if run.isEmpty || cell.style != runStyle || runStart + run.count != column {
                    drawRun()
                    runStart = column
                    runStyle = cell.style
                }
                run += cell.text
            } else {
                drawRun()
                draw(cell.text, style: cell.style, at: NSPoint(x: Self.inset + CGFloat(column) * cellWidth, y: top))
            }
        }
        drawRun()
    }

    private func draw(_ text: String, style: TerminalStyle, at point: NSPoint) {
        var attributes: [NSAttributedString.Key: Any] = [.font: fonts.font(for: style), .foregroundColor: Self.colors(for: style).foreground]
        if style.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    /// Composed text covers the cells after the cursor, underlined as input methods show it.
    private func drawMarkedText() {
        let text = markedText.string
        let width = text.unicodeScalars.reduce(0) { $0 + $1.terminalWidth }
        var rect = cursorRect
        rect.size.width = CGFloat(max(width, 1)) * cellWidth
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: fonts.regular, .foregroundColor: NSColor.textColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        (text as NSString).draw(at: rect.origin, withAttributes: attributes)
    }

    private var cursorRect: NSRect {
        let cursor = screen.cursor
        let width = screen.lines[cursor.row].cells[cursor.column].width == 2 ? 2 : 1
        return cellRect(column: cursor.column, top: Self.inset + CGFloat(screen.scrollback.count + cursor.row) * lineHeight, width: width)
    }

    private func cellRect(column: Int, top: CGFloat, width: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(column) * cellWidth, y: top, width: CGFloat(width) * cellWidth, height: lineHeight)
    }

    // MARK: Selection

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let word = screen.word(at: position(at: point, rounding: .down)) {
            selection = (word.start, word.end)
        } else {
            let position = position(at: point, rounding: .toNearestOrAwayFromZero)
            selection = (position, position)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = selection?.anchor else { return }
        autoscroll(with: event)
        selection = (anchor, position(at: convert(event.locationInWindow, from: nil), rounding: .toNearestOrAwayFromZero))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.anchor == selection.head { self.selection = nil }
    }

    /// A cell for `.down`, or the boundary between cells nearest the point otherwise.
    private func position(at point: NSPoint, rounding: FloatingPointRoundingRule) -> TerminalPosition {
        let index = min(max(Int((point.y - Self.inset) / lineHeight), 0), screen.lineCount - 1)
        let column = max(Int(((point.x - Self.inset) / cellWidth).rounded(rounding)), 0)
        return TerminalPosition(line: screen.droppedLineCount + index, column: column)
    }

    private var orderedSelection: (start: TerminalPosition, end: TerminalPosition)? {
        guard let selection, selection.anchor != selection.head else { return nil }
        return selection.anchor < selection.head ? (selection.anchor, selection.head) : (selection.head, selection.anchor)
    }

    private func selectedColumns(onLine line: Int) -> Range<Int>? {
        guard let range = orderedSelection, (range.start.line...range.end.line).contains(line) else { return nil }
        let start = line == range.start.line ? range.start.column : 0
        let end = line == range.end.line ? range.end.column : Int.max
        return start < end ? start..<end : nil
    }

    @objc func copy(_ sender: Any?) {
        guard let range = orderedSelection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(screen.text(from: range.start, to: range.end), forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        let first = screen.droppedLineCount
        selection = (TerminalPosition(line: first, column: 0), TerminalPosition(line: first + screen.lineCount - 1, column: Int.max))
        needsDisplay = true
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        send(Self.pastedText(text, bracketed: screen.usesBracketedPaste))
    }

    /// What a paste sends. Line breaks become carriage returns, as Return types. Bracketed paste marks the text, so a program can tell it from typing and does not run it line by line; inside the marks the text keeps tabs and carriage returns but no other control character, so no escape character in copied text can end the paste early and run what follows.
    static func pastedText(_ text: String, bracketed: Bool) -> String {
        let text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        guard bracketed else { return text }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { $0 == "\t" || $0 == "\r" || !(0x00...0x1F ~= $0.value || 0x7F...0x9F ~= $0.value) })
        return "\u{1B}[200~" + String(kept) + "\u{1B}[201~"
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return orderedSelection != nil
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        default: return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))), ("Select All", #selector(selectAll(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: Keys

    /// Command shortcuts go to the menus. Control with a letter or one of `@[\]^_?` sends its control character, such as Control-C. Other keys go through the input method, which calls `insertText` or `doCommand`.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return super.keyDown(with: event) }
        if modifiers.contains(.control), !hasMarkedText(), let control = Self.controlCharacter(for: event) {
            return send(String(UnicodeScalar(control)))
        }
        interpretKeyEvents([event])
    }

    /// Key codes of the letter keys on an ANSI keyboard, for input sources whose letters are not Latin.
    private static let letterKeyCodes: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
    ]

    private static func controlCharacter(for event: NSEvent) -> UInt8? {
        var key = event.charactersIgnoringModifiers?.lowercased().first
        if key?.isASCII != true { key = letterKeyCodes[event.keyCode] }
        guard let value = key?.asciiValue else { return nil }
        switch value {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return value - UInt8(ascii: "a") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "): return 0
        case UInt8(ascii: "["), UInt8(ascii: "\\"), UInt8(ascii: "]"), UInt8(ascii: "^"), UInt8(ascii: "_"): return value - 0x40
        case UInt8(ascii: "?"): return 0x7F
        default: return nil
        }
    }

    /// The bytes terminals send for editing and movement keys. Arrows use the application form after a program asks for it.
    override func doCommand(by selector: Selector) {
        let cursorKey = screen.usesApplicationCursorKeys ? "\u{1B}O" : "\u{1B}["
        let sequences: [Selector: String] = [
            #selector(insertNewline(_:)): "\r",
            #selector(insertLineBreak(_:)): "\r",
            #selector(insertNewlineIgnoringFieldEditor(_:)): "\r",
            #selector(insertTab(_:)): "\t",
            #selector(insertTabIgnoringFieldEditor(_:)): "\t",
            #selector(insertBacktab(_:)): "\u{1B}[Z",
            #selector(deleteBackward(_:)): "\u{7F}",
            #selector(deleteForward(_:)): "\u{1B}[3~",
            #selector(deleteWordBackward(_:)): "\u{1B}\u{7F}",
            #selector(cancelOperation(_:)): "\u{1B}",
            #selector(moveUp(_:)): cursorKey + "A",
            #selector(moveDown(_:)): cursorKey + "B",
            #selector(moveRight(_:)): cursorKey + "C",
            #selector(moveLeft(_:)): cursorKey + "D",
            #selector(moveWordLeft(_:)): "\u{1B}b",
            #selector(moveWordRight(_:)): "\u{1B}f",
            #selector(scrollToBeginningOfDocument(_:)): cursorKey + "H",
            #selector(scrollToEndOfDocument(_:)): cursorKey + "F",
            #selector(scrollPageUp(_:)): "\u{1B}[5~",
            #selector(scrollPageDown(_:)): "\u{1B}[6~",
        ]
        if let sequence = sequences[selector] { send(sequence) }
    }

    private func send(_ text: String) {
        onInput?(Data(text.utf8))
        scrollToEnd()
    }

    // MARK: Input methods

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = NSAttributedString()
        needsDisplay = true
        send(Self.plainText(string))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = string as? NSAttributedString ?? NSAttributedString(string: Self.plainText(string))
        markedSelection = selectedRange
        needsDisplay = true
    }

    /// Accepts the composed text as if it had been typed.
    func unmarkText() {
        let text = markedText.string
        markedText = NSAttributedString()
        needsDisplay = true
        if !text.isEmpty { send(text) }
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    /// The cursor's cell on screen, where input methods place their candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(cursorRect, to: nil)) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    private static func plainText(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? string as? String ?? ""
    }

    // MARK: Colors and fonts

    /// The foreground and the background to fill, which is nil for the view's own background.
    private static func colors(for style: TerminalStyle) -> (foreground: NSColor, background: NSColor?) {
        var foreground = color(style.foreground) ?? .textColor
        var background = color(style.background)
        if style.isInverse { (foreground, background) = (background ?? .textBackgroundColor, foreground) }
        if style.isFaint { foreground = foreground.withAlphaComponent(0.5) }
        return (foreground, background)
    }

    /// The xterm palette: 16 named colors, a 6×6×6 cube, and 24 grays. nil for the terminal's own color.
    private static func color(_ color: TerminalColor) -> NSColor? {
        switch color {
        case .default:
            return nil
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .indexed(let index) where index < 16:
            return namedColors[Int(index)]
        case .indexed(let index) where index < 232:
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            let cube = Int(index) - 16
            return NSColor(srgbRed: levels[cube / 36] / 255, green: levels[cube / 6 % 6] / 255, blue: levels[cube % 6] / 255, alpha: 1)
        case .indexed(let index):
            return NSColor(white: CGFloat(8 + (Int(index) - 232) * 10) / 255, alpha: 1)
        }
    }

    /// Black, red, green, yellow, blue, magenta, cyan, and white, then their bright forms, each in a lighter and a darker shade for the light and dark appearances.
    private static let namedColors: [NSColor] = {
        let light: [(Int, Int, Int)] = [(0, 0, 0), (153, 0, 0), (0, 128, 0), (128, 104, 0), (0, 0, 178), (160, 0, 160), (0, 128, 140), (160, 160, 160),
                                        (102, 102, 102), (204, 0, 0), (0, 160, 0), (160, 130, 0), (0, 0, 230), (200, 0, 200), (0, 160, 170), (40, 40, 40)]
        let dark: [(Int, Int, Int)] = [(40, 40, 40), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
                                       (118, 118, 118), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)]
        return zip(light, dark).map { light, dark in
            NSColor(name: nil) { appearance in
                let (red, green, blue) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
            }
        }
    }()

    private struct Fonts {
        let regular: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont

        init(size: CGFloat) {
            regular = .monospacedSystemFont(ofSize: size, weight: .regular)
            bold = .monospacedSystemFont(ofSize: size, weight: .bold)
            italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
            boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        }

        func font(for style: TerminalStyle) -> NSFont {
            switch (style.isBold, style.isItalic) {
            case (false, false): return regular
            case (true, false): return bold
            case (false, true): return italic
            case (true, true): return boldItalic
            }
        }
    }
}
