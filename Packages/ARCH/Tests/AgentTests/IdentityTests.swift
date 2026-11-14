// Who an outside client is (docs/agents.md, Outside clients: identity, grants, revocation), over a process table in memory: the walk passes over Arch's tools by their code and shells, `env`, `login`, and `sudo` by their paths; a team-signed client is its identifier and team; an ad hoc signed or unsigned one is its path and code directory hash; the client's name is the one it was started with; a client reached through a shell is marked as such; a chain that reaches launchd or Arch binds the process just below them; a program named like a shell elsewhere is the client; and a process that changes while it is read is no client. The system's own reader is checked against this test process and a process started through a link.
import Darwin
import Foundation
import Testing
@testable import Agent

private struct TableInspector: AgentProcessInspector {
    var records: [pid_t: AgentProcessRecord]
    var codes: [pid_t: AgentProcessCode]
    /// Start times that the second read of a process returns, as for one that ended and whose ID another took.
    var laterStarts = Shared<[pid_t: AgentProcessStart]>([:])
    var reads = Shared<[pid_t: Int]>([:])
    /// The paths processes were started with; a process missing here has none to read, as launchd for another user.
    var launchPaths: [pid_t: String] = [:]

    func record(of processID: pid_t) -> AgentProcessRecord? {
        reads.value[processID, default: 0] += 1
        guard var record = records[processID] else { return nil }
        if reads.value[processID]! > 1, let later = laterStarts.value[processID] { record.start = later }
        return record
    }

    func code(of processID: pid_t) -> AgentProcessCode? { codes[processID] }

    func launchPath(of processID: pid_t) -> String? { launchPaths[processID] }
}

@Suite struct IdentityTests {
    private static let toolHash = Data([0xA1, 0xC1])
    private static let archID: pid_t = 500

    /// arch-cli (10), under zsh (11) and login (12), under `client` (13), under launchd.
    private func chain(client: AgentProcessCode, clientParent: pid_t = 1) -> TableInspector {
        func record(_ id: pid_t, parent: pid_t) -> AgentProcessRecord { AgentProcessRecord(processID: id, parentID: parent, start: AgentProcessStart(seconds: Int(id) * 100, microseconds: 7)) }
        return TableInspector(records: [10: record(10, parent: 11), 11: record(11, parent: 12), 12: record(12, parent: 13), 13: record(13, parent: clientParent)],
                              codes: [10: AgentProcessCode(path: "/Applications/Arch.app/Contents/Helpers/arch-cli", codeHash: Self.toolHash, signingIdentifier: "arch-cli", verifiedTeam: nil),
                                      11: AgentProcessCode(path: "/bin/zsh", codeHash: Data([1]), signingIdentifier: "com.apple.zsh", verifiedTeam: nil),
                                      12: AgentProcessCode(path: "/usr/bin/login", codeHash: Data([2]), signingIdentifier: "com.apple.login", verifiedTeam: nil),
                                      13: client])
    }

    private func identifier(_ inspector: TableInspector) -> AgentClientIdentifier {
        AgentClientIdentifier(inspector: inspector, archProcessID: Self.archID, toolHash: Self.toolHash, passedOverPaths: ["/bin/zsh", "/bin/bash", "/usr/bin/login", "/usr/bin/env", "/usr/bin/sudo"])
    }

    /// Claude Code runs from `~/.local/bin/claude`, a link to a file named after its version, which Security reports.
    @Test func aTeamSignedClientIsItsIdentifierAndTeamNamedAsItWasStarted() throws {
        var inspector = chain(client: AgentProcessCode(path: "/Users/someone/.local/share/claude/versions/2.1.323", codeHash: Data([0xEE]), signingIdentifier: "com.anthropic.claude-code", verifiedTeam: "Q6L2SF6YDW"))
        inspector.launchPaths[13] = "/Users/someone/.local/bin/claude"
        let identity = try identifier(inspector).identify(peer: 10)
        #expect(identity.key == .signed(identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW"))
        #expect(identity.name == "claude")
        #expect(identity.executablePath == "/Users/someone/.local/share/claude/versions/2.1.323")
        #expect(!identity.isBoundToProcess)
        // Without the path it was started with, the file's name stands.
        inspector.launchPaths[13] = nil
        #expect(try identifier(inspector).identify(peer: 10).name == "2.1.323")
    }

    /// A program that `exec`s `arch-cli`, or a shell that runs it, takes the place of a process below the client, so the client's access reaches every program in its shell.
    @Test func aClientReachedThroughAShellIsMarked() throws {
        var inspector = chain(client: AgentProcessCode(path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", codeHash: Data([0x0F]), signingIdentifier: "com.apple.Terminal", verifiedTeam: nil))
        #expect(try identifier(inspector).identify(peer: 10).reachedThroughShell)
        // arch-cli started by the client itself, with no shell between them.
        inspector.records[10]?.parentID = 13
        let direct = try identifier(inspector).identify(peer: 10)
        #expect(direct.key == .unsigned(path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", codeHash: "0f"))
        #expect(!direct.reachedThroughShell)
        // A shell that Arch started is the client, and every program in it shares the access.
        inspector.records[10]?.parentID = 11
        inspector.records[11]?.parentID = Self.archID
        #expect(try identifier(inspector).identify(peer: 10).reachedThroughShell)
    }

    @Test func anAdHocOrUnsignedClientIsItsPathAndHash() throws {
        // An ad hoc signature chooses its identifier freely and has no verified team.
        let identity = try identifier(chain(client: AgentProcessCode(path: "/Applications/Terminal.app/Contents/MacOS/Terminal", codeHash: Data([0x0F, 0xA0]), signingIdentifier: "com.anthropic.claude-code", verifiedTeam: nil))).identify(peer: 10)
        #expect(identity.key == .unsigned(path: "/Applications/Terminal.app/Contents/MacOS/Terminal", codeHash: "0fa0"))
        #expect(identity.displayName == "Terminal")
    }

    @Test func aChainThatReachesLaunchdOrArchBindsTheProcessBelowThem() throws {
        var inspector = chain(client: AgentProcessCode(path: "/bin/bash", codeHash: Data([0x03]), signingIdentifier: "com.apple.bash", verifiedTeam: nil))
        let below = try identifier(inspector).identify(peer: 10)
        #expect(below.key == .process(path: "/bin/bash", codeHash: "03", processID: 13, start: AgentProcessStart(seconds: 1_300, microseconds: 7)))
        #expect(below.host == nil)
        // arch-cli in Arch's built-in terminal: zsh's parent is Arch, which is never the client.
        inspector.records[11]?.parentID = Self.archID
        let terminal = try identifier(inspector).identify(peer: 10)
        #expect(terminal.key == .process(path: "/bin/zsh", codeHash: "01", processID: 11, start: AgentProcessStart(seconds: 1_100, microseconds: 7)))
        #expect(terminal.displayName == "zsh in Arch\u{2019}s terminal")
        #expect(terminal.isBoundToProcess)
    }

    @Test func aProgramNamedLikeAShellElsewhereIsTheClient() throws {
        var inspector = chain(client: AgentProcessCode(path: "/Applications/Terminal.app/Contents/MacOS/Terminal", codeHash: Data([4]), signingIdentifier: "com.apple.Terminal", verifiedTeam: nil))
        inspector.codes[11] = AgentProcessCode(path: "/tmp/zsh", codeHash: Data([5]), signingIdentifier: "zsh", verifiedTeam: nil)
        let identity = try identifier(inspector).identify(peer: 10)
        #expect(identity.key == .unsigned(path: "/tmp/zsh", codeHash: "05"))
        #expect(identity.displayName == "zsh in Terminal")
    }

    @Test func aProcessThatChangesWhileItIsReadIsNoClient() {
        let inspector = chain(client: AgentProcessCode(path: "/opt/tools/agent", codeHash: Data([6]), signingIdentifier: "agent", verifiedTeam: nil))
        inspector.laterStarts.value = [13: AgentProcessStart(seconds: 9_999, microseconds: 0)]
        #expect(throws: AgentClientIdentificationError.processChanged) { try identifier(inspector).identify(peer: 10) }
        var gone = chain(client: AgentProcessCode(path: "/opt/tools/agent", codeHash: Data([6]), signingIdentifier: "agent", verifiedTeam: nil))
        gone.records[12] = nil
        #expect(throws: AgentClientIdentificationError.processChanged) { try identifier(gone).identify(peer: 10) }
    }

    @Test func interpretersAndHostApps() {
        #expect(AgentClientIdentifier.isInterpreter("node"))
        #expect(AgentClientIdentifier.isInterpreter("python3.12"))
        #expect(!AgentClientIdentifier.isInterpreter("nodemon"))
        #expect(!AgentClientIdentifier.isInterpreter("claude"))
        #expect(AgentClientIdentifier.appName(around: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == "Terminal")
        #expect(AgentClientIdentifier.appName(around: "/usr/local/bin/codex") == nil)
    }

    /// `sysctl` and Security report this process: its parent, its start time, and its own code's path and hash.
    @Test func theSystemsReaderReadsThisProcess() throws {
        let inspector = AgentSystemProcessInspector()
        let record = try #require(inspector.record(of: getpid()))
        #expect(record.parentID == getppid())
        #expect(record.start.seconds > 0)
        #expect(inspector.record(of: getpid())?.start == record.start)
        let code = try #require(inspector.code(of: getpid()))
        #expect(code.codeHash == (try ownCodeHash()))
        #expect(code.path.hasPrefix("/"))
        #expect(inspector.launchPath(of: getpid())?.isEmpty == false)
    }

    /// A process started through a link: Security reports the file, and `KERN_PROCARGS2` the link it was started with.
    @Test func theSystemsReaderNamesAProcessByThePathItWasStartedWith() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("nap")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        let process = Process()
        process.executableURL = link
        process.arguments = ["10"]
        try process.run()
        defer { process.terminate() }
        let inspector = AgentSystemProcessInspector()
        #expect(inspector.code(of: process.processIdentifier)?.path == "/bin/sleep")
        #expect(inspector.launchPath(of: process.processIdentifier).map { URL(fileURLWithPath: $0).lastPathComponent } == "nap")
    }
}
