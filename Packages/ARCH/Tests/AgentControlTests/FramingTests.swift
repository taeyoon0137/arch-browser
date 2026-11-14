// Frames on the control socket: a 4-byte big-endian length and the message, at most 16 MiB, read back whole however the bytes arrive, with an oversized header refused before its payload.
import AgentControl
import Foundation
import Testing

@Suite struct FramingTests {
    @Test func aFrameIsABigEndianLengthAndTheMessage() throws {
        let message = Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8)
        let frame = try AgentFrame.encode(message)
        #expect(Array(frame.prefix(4)) == [0, 0, 0, UInt8(message.count)])
        #expect(frame.dropFirst(4) == message)

        let long = Data(repeating: 0x61, count: 0x01_02_03)
        #expect(Array(try AgentFrame.encode(long).prefix(4)) == [0x00, 0x01, 0x02, 0x03])
    }

    @Test func messagesComeBackWholeWhateverTheChunks() throws {
        let messages = [Data("first".utf8), Data(), Data(repeating: 0x7A, count: 70_000), Data("last".utf8)]
        let stream = try messages.reduce(into: Data()) { $0.append(try AgentFrame.encode($1)) }

        for chunkSize in [1, 3, 4, 5, 4096, stream.count] {
            var reader = AgentFrameReader()
            var received: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                reader.append(stream[offset ..< end])
                offset = end
                while let message = try reader.nextMessage() { received.append(message) }
            }
            #expect(received == messages, "chunks of \(chunkSize) bytes")
        }
    }

    @Test func aMessageOfSixteenMebibytesFitsAndOneByteMoreDoesNot() throws {
        #expect(AgentFrame.maximumLength == 16_777_216)
        let largest = Data(count: AgentFrame.maximumLength)
        var reader = AgentFrameReader()
        reader.append(try AgentFrame.encode(largest))
        #expect(try reader.nextMessage()?.count == AgentFrame.maximumLength)

        #expect(throws: AgentFrameError.tooLong(AgentFrame.maximumLength + 1)) {
            try AgentFrame.encode(Data(count: AgentFrame.maximumLength + 1))
        }
    }

    @Test func aHeaderOverTheLimitThrowsBeforeItsPayloadArrives() {
        var reader = AgentFrameReader()
        let length = UInt32(AgentFrame.maximumLength + 1)
        reader.append(Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]))
        #expect(throws: AgentFrameError.tooLong(Int(length))) { try reader.nextMessage() }
    }
}
