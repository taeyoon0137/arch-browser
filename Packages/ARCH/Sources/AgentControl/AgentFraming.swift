// Frames on the control socket: a 4-byte big-endian length, then that many bytes of one UTF-8 JSON-RPC message, at most 16 MiB (docs/agents.md, Local control channel ▸ Framing and methods). Length framing keeps page text from splitting messages, and the limit fits a full-page screenshot.
import Foundation

/// Encodes one size-bounded JSON-RPC message for the local socket.
public enum AgentFrame {
    /// The largest message a frame carries: 16 MiB.
    public static let maximumLength = 16 * 1024 * 1024
    static let headerLength = 4

    /// The frame for one message. Throws for a message longer than `maximumLength`.
    public static func encode(_ message: Data) throws -> Data {
        guard message.count <= maximumLength else { throw AgentFrameError.tooLong(message.count) }
        let length = UInt32(message.count)
        var frame = Data(capacity: headerLength + message.count)
        frame.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        frame.append(message)
        return frame
    }
}

/// A frame whose message length exceeds the protocol limit.
public enum AgentFrameError: Error, Equatable {
    /// A message, or a frame's announced length, over `AgentFrame.maximumLength`. The connection closes.
    case tooLong(Int)
}

/// Collects bytes as a connection delivers them and returns each complete message in order.
public struct AgentFrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// The next complete message, or nil until more bytes arrive. Throws as soon as a header announces more than `AgentFrame.maximumLength`, before the rest arrives; the reader is then unusable.
    public mutating func nextMessage() throws -> Data? {
        guard buffer.count >= AgentFrame.headerLength else { return nil }
        let start = buffer.startIndex
        let length = buffer[start ..< start + AgentFrame.headerLength].reduce(0) { $0 << 8 | Int($1) }
        guard length <= AgentFrame.maximumLength else { throw AgentFrameError.tooLong(length) }
        let end = start + AgentFrame.headerLength + length
        guard buffer.count >= AgentFrame.headerLength + length else { return nil }
        let message = Data(buffer[start + AgentFrame.headerLength ..< end])
        buffer = Data(buffer[end...])
        return message
    }
}
