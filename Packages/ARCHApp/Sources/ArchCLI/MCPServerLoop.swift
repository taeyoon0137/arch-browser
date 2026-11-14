// arch-mcp on standard input and output (docs/agents.md, arch-mcp). `AgentMCPServer` holds the protocol; this loop reads standard input and the control socket on threads of their own, hands each message to the server on one queue, and performs the effects it returns. Standard output carries only MCP messages; sentences for people go to standard error.
import AgentControl
import Darwin
import Foundation

final class MCPServerLoop: @unchecked Sendable {
    /// Parses arch-mcp's arguments and runs the server until standard input closes, or for a session's server until its connection ends.
    static func run(_ arguments: [String]) -> Never {
        let mode: AgentMCPServer.Mode
        do {
            mode = try AgentCommandLine.mcpMode(arguments, ticket: ProcessInfo.processInfo.environment[AgentMCPServer.ticketVariable])
        } catch {
            CLICommands.printError("arch-mcp: \((error as? AgentUsageError)?.message ?? "\(error)")")
            exit(AgentExitCode.usage.rawValue)
        }
        MCPServerLoop(server: AgentMCPServer(mode: mode, version: CLICommands.clientVersion, instructions: AgentHarness.mcpInstructions)).run()
    }

    /// The queue that owns the server and the connection.
    private let queue = DispatchQueue(label: "xyz.taeyoon.arch.mcp")
    private var server: AgentMCPServer
    private var connection: AgentControlConnection?
    /// Counts connections, so that a report from a closed one's reader is dropped.
    private var generation = 0

    private init(server: AgentMCPServer) {
        self.server = server
    }

    private func run() -> Never {
        // A client that closes its end makes writes fail instead of ending the process.
        signal(SIGPIPE, SIG_IGN)
        queue.async { self.perform(self.server.start()) }
        Thread { self.readInput() }.start()
        dispatchMain()
    }

    private func readInput() {
        var reader = AgentLineReader()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            reader.append(Data(chunk[0 ..< count]))
            do {
                while let line = try reader.nextLine() {
                    queue.async { self.perform(self.server.receive(line: line)) }
                }
            } catch {
                queue.async { self.perform([.log("A message on standard input is longer than 16 MiB."), .exit(.internalError)]) }
                return
            }
        }
        if let line = reader.finish() {
            queue.async { self.perform(self.server.receive(line: line)) }
        }
        queue.async { self.perform(self.server.inputEnded()) }
    }

    private func perform(_ effects: [AgentMCPServer.Effect]) {
        for effect in effects {
            switch effect {
            case .reply(let message): write(message)
            case .send(let message): send(message)
            case .connect(let hello): connect(hello)
            case .log(let text): CLICommands.printError("arch-mcp: \(text)")
            case .exit(let code): exit(code.rawValue)
            }
        }
    }

    /// Writes one message as one line on standard output. A client that stopped reading has ended the session.
    private func write(_ message: AgentRPCMessage) {
        guard var line = try? message.encoded() else {
            CLICommands.printError("arch-mcp: A message could not be written as JSON.")
            return
        }
        line.append(0x0A)
        let written = line.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        if !written { exit(AgentExitCode.done.rawValue) }
    }

    private func send(_ message: AgentRPCMessage) {
        guard let connection else { return }
        do {
            try connection.send(message)
        } catch {
            lost(generation, error)
        }
    }

    /// Connects on the queue, so that the client's later messages, and the end of its input, are handled after the outcome. Without a listener this fails at once; otherwise the check and `hello` take at most 10 seconds.
    private func connect(_ hello: AgentHello) {
        let answer: AgentHelloAnswer
        let connection: AgentControlConnection
        do {
            guard let location = AgentSocketLocation.forClient() else { throw AgentClientError.noSocketLocation }
            connection = try AgentControlConnection(location: location, check: AgentControlConnection.archCheck())
            answer = try connection.hello(hello)
        } catch {
            perform(server.connectionFailed(Self.clientError(error)))
            return
        }
        generation += 1
        self.connection = connection
        read(connection, generation: generation)
        perform(server.connected(answer))
    }

    /// Reads Arch's messages until the connection ends.
    private func read(_ connection: AgentControlConnection, generation: Int) {
        Thread {
            while true {
                do {
                    let message = try connection.receive()
                    self.queue.async {
                        guard self.generation == generation else { return }
                        self.perform(self.server.receive(control: message))
                    }
                } catch {
                    self.queue.async { self.lost(generation, error) }
                    return
                }
            }
        }.start()
    }

    private func lost(_ generation: Int, _ error: Error) {
        guard self.generation == generation, connection != nil else { return }
        connection = nil
        self.generation += 1
        perform(server.connectionFailed(Self.clientError(error)))
    }

    private static func clientError(_ error: Error) -> AgentClientError {
        error as? AgentClientError ?? .system("\(error)")
    }
}
