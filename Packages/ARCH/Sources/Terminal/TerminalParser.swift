// Splits a program's output into printable characters, control characters, and escape sequences, following the state machine of DEC-compatible terminals. UTF-8 is decoded across reads. Device control, privacy message, and application program command strings are skipped.
import Foundation

enum TerminalAction: Equatable {
    case print(Unicode.Scalar)
    /// A C0 control character such as line feed or backspace.
    case control(UInt8)
    /// `ESC` followed by optional intermediate bytes and a final byte, such as `ESC 7`.
    case escape(intermediates: [UInt8], final: UInt8)
    /// A control sequence such as `ESC [ 1 ; 2 H`. A parameter left out is 0; `:` separates parameters like `;`.
    case controlSequence(parameters: [Int], privateMarker: UInt8?, intermediates: [UInt8], final: UInt8)
    /// An operating system command such as `ESC ] 2 ; title BEL`, without its terminator.
    case operatingSystemCommand(String)
}

struct TerminalParser {
    private enum State {
        case ground
        case escape
        case controlSequence
        case operatingSystemCommand
        /// Inside a string to skip, until its terminator.
        case ignoredString
    }

    private static let maximumParameters = 32
    private static let maximumCommandLength = 4_096

    private var state = State.ground
    /// After `ESC` inside a string, which `\` ends.
    private var isStringEscape = false
    private var parameters: [Int] = []
    /// The digits read so far of the parameter being read.
    private var currentParameter: Int?
    private var privateMarker: UInt8?
    private var intermediates: [UInt8] = []
    private var command: [UInt8] = []
    private var utf8Sequence: [UInt8] = []
    private var utf8Length = 0

    mutating func parse(_ data: Data, perform: (TerminalAction) -> Void) {
        for byte in data { parse(byte, perform: perform) }
    }

    private mutating func parse(_ byte: UInt8, perform: (TerminalAction) -> Void) {
        // Cancel and substitute abort any sequence.
        if byte == 0x18 || byte == 0x1A {
            state = .ground
            return
        }
        switch state {
        case .ground:
            parseGround(byte, perform: perform)
        case .escape:
            parseEscape(byte, perform: perform)
        case .controlSequence:
            parseControlSequence(byte, perform: perform)
        case .operatingSystemCommand, .ignoredString:
            parseString(byte, perform: perform)
        }
    }

    private mutating func parseGround(_ byte: UInt8, perform: (TerminalAction) -> Void) {
        if byte >= 0x80 {
            decodeUTF8(byte, perform: perform)
            return
        }
        flushIncompleteUTF8(perform: perform)
        switch byte {
        case 0x1B: enter(.escape)
        case 0x7F: break
        case ..<0x20: perform(.control(byte))
        default: perform(.print(Unicode.Scalar(byte)))
        }
    }

    private mutating func parseEscape(_ byte: UInt8, perform: (TerminalAction) -> Void) {
        switch byte {
        case 0x1B:
            enter(.escape)
        case ..<0x20:
            perform(.control(byte))
        case 0x20...0x2F:
            intermediates.append(byte)
        case UInt8(ascii: "[") where intermediates.isEmpty:
            enter(.controlSequence)
        case UInt8(ascii: "]") where intermediates.isEmpty:
            enter(.operatingSystemCommand)
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            enter(.ignoredString)
        case 0x30...0x7E:
            perform(.escape(intermediates: intermediates, final: byte))
            state = .ground
        default:
            state = .ground
        }
    }

    private mutating func parseControlSequence(_ byte: UInt8, perform: (TerminalAction) -> Void) {
        switch byte {
        case 0x1B:
            enter(.escape)
        case ..<0x20:
            perform(.control(byte))
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            currentParameter = min((currentParameter ?? 0) * 10 + Int(byte - UInt8(ascii: "0")), 65_535)
        case UInt8(ascii: ";"), UInt8(ascii: ":"):
            endParameter()
        case 0x3C...0x3F:
            // A private marker counts only before any parameter.
            if parameters.isEmpty, currentParameter == nil, privateMarker == nil { privateMarker = byte }
        case 0x20...0x2F:
            intermediates.append(byte)
        case 0x40...0x7E:
            if currentParameter != nil || !parameters.isEmpty { endParameter() }
            perform(.controlSequence(parameters: parameters, privateMarker: privateMarker, intermediates: intermediates, final: byte))
            state = .ground
        default:
            state = .ground
        }
    }

    /// A parameter left out is 0. Parameters past the limit are dropped.
    private mutating func endParameter() {
        if parameters.count < Self.maximumParameters { parameters.append(currentParameter ?? 0) }
        currentParameter = nil
    }

    /// Strings end with BEL or with `ESC \`. Only operating system commands are kept.
    private mutating func parseString(_ byte: UInt8, perform: (TerminalAction) -> Void) {
        if isStringEscape {
            isStringEscape = false
            finishString(perform: perform)
            // `ESC \` ends the string; any other byte after ESC starts a new escape sequence.
            if byte != UInt8(ascii: "\\") {
                enter(.escape)
                parseEscape(byte, perform: perform)
            }
            return
        }
        switch byte {
        case 0x07: finishString(perform: perform)
        case 0x1B: isStringEscape = true
        default: if state == .operatingSystemCommand, command.count < Self.maximumCommandLength { command.append(byte) }
        }
    }

    private mutating func finishString(perform: (TerminalAction) -> Void) {
        if state == .operatingSystemCommand { perform(.operatingSystemCommand(String(decoding: command, as: UTF8.self))) }
        state = .ground
    }

    private mutating func enter(_ newState: State) {
        state = newState
        parameters.removeAll(keepingCapacity: true)
        currentParameter = nil
        privateMarker = nil
        intermediates.removeAll(keepingCapacity: true)
        command.removeAll(keepingCapacity: true)
        isStringEscape = false
    }

    // MARK: UTF-8

    private mutating func decodeUTF8(_ byte: UInt8, perform: (TerminalAction) -> Void) {
        if byte & 0xC0 == 0x80, utf8Length > 0 {
            utf8Sequence.append(byte)
            guard utf8Sequence.count == utf8Length else { return }
            let scalar = Self.scalar(from: utf8Sequence)
            utf8Sequence.removeAll(keepingCapacity: true)
            utf8Length = 0
            perform(.print(scalar))
            return
        }
        flushIncompleteUTF8(perform: perform)
        switch byte {
        case 0xC2...0xDF: utf8Length = 2
        case 0xE0...0xEF: utf8Length = 3
        case 0xF0...0xF4: utf8Length = 4
        default:
            perform(.print(Self.replacement))
            return
        }
        utf8Sequence = [byte]
    }

    /// A sequence cut short by another byte shows as a replacement character.
    private mutating func flushIncompleteUTF8(perform: (TerminalAction) -> Void) {
        guard utf8Length > 0 else { return }
        utf8Sequence.removeAll(keepingCapacity: true)
        utf8Length = 0
        perform(.print(Self.replacement))
    }

    private static let replacement = Unicode.Scalar(0xFFFD)!

    private static func scalar(from bytes: [UInt8]) -> Unicode.Scalar {
        let leadBits = UInt32(bytes[0]) & (0xFF >> (bytes.count + 1))
        let value = bytes.dropFirst().reduce(leadBits) { $0 << 6 | UInt32($1 & 0x3F) }
        return Unicode.Scalar(value) ?? replacement
    }
}
