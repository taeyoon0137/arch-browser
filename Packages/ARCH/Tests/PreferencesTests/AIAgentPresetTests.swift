// The Claude Code and Codex presets in Settings ▸ AI ▸ Providers: their fields from a login shell PATH that holds the tool, and the version and sign-in read from the tools' own status commands. Shell scripts in temporary folders stand in for `claude` and `codex`.
import AI
import Foundation
import Testing
@testable import Preferences

@Suite struct AIAgentPresetTests {
    @Test(arguments: AIAgentKind.allCases)
    func aPresetFindsItsToolInTheSearchPath(kind: AIAgentKind) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = try script(named: kind.executableName, in: folder, body: "exit 0")
        let draft = await AICommandLineDraft.preset(kind, searchPath: "/nonexistent:\(folder.path)")
        #expect(draft.name == kind.title)
        #expect(draft.agent == kind)
        #expect(draft.executable == tool.path)
        #expect(draft.models == [AIModelConfiguration(name: "")])
        #expect(draft.limits.concurrentRequests == 2)
        let configuration = try #require(draft.configuration)
        guard case .commandLine(let commandLine) = configuration.kind else {
            Issue.record("Expected a command-line provider")
            return
        }
        #expect(commandLine.agent == kind)
        #expect(commandLine.arguments.isEmpty)
        #expect(commandLine.executable == tool)
        #expect(configuration.capabilities(of: configuration.models[0]).contains(.agent))
    }

    @Test func signInTypesThePresetsVariablesBeforeTheCommand() {
        #expect(AICommandLineEditor.signInCommand(program: "codex", arguments: ["login"], environment: [:]) == "codex login")
        #expect(AICommandLineEditor.signInCommand(program: "codex", arguments: ["login"], environment: ["CODEX_HOME": "/Volumes/Data/Codex Home", "A_B": "it's"])
                == #"A_B='it'\''s' CODEX_HOME='/Volumes/Data/Codex Home' codex login"#)
        // A name the shell cannot assign is left out.
        #expect(AICommandLineEditor.signInCommand(program: "'/opt/claude'", arguments: ["auth", "login"], environment: ["NOT VALID": "x", "9X": "y", "CLAUDE_CONFIG_DIR": "/c"])
                == "CLAUDE_CONFIG_DIR='/c' '/opt/claude' auth login")
    }

    @Test func aPresetWithoutItsToolKeepsTheNameForFind() async throws {
        let draft = await AICommandLineDraft.preset(.codex, searchPath: "/nonexistent")
        #expect(draft.executable == "codex")
        #expect(draft.configuration == nil)
    }

    @Test func claudeCodeStatusReadsOnlyLoggedIn() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let signedOut = try script(named: "claude", in: folder, body: """
        case "$*" in
          "--version") echo "2.1.323 (Claude Code)";;
          "auth status --json") echo '{"loggedIn":false,"authMethod":"none"}';;
          *) exit 2;;
        esac
        """)
        #expect(try await AIAgentToolStatus.read(kind: .claudeCode, executable: signedOut, environment: ["PATH": "/usr/bin:/bin"])
                == AIAgentToolStatus(version: "2.1.323", isSignedIn: false))
        let unreadable = try script(named: "claude-old", in: folder, body: """
        case "$*" in
          "--version") echo "Claude Code";;
          *) echo "unknown command"; exit 1;;
        esac
        """)
        #expect(try await AIAgentToolStatus.read(kind: .claudeCode, executable: unreadable, environment: ["PATH": "/usr/bin:/bin"])
                == AIAgentToolStatus(version: nil, isSignedIn: nil))
    }

    @Test(arguments: [(0, true), (1, false)])
    func codexStatusReadsOnlyTheExitStatus(code: Int, signedIn: Bool) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let codex = try script(named: "codex", in: folder, body: """
        case "$*" in
          "--version") echo "codex-cli 0.164.0";;
          "--no-daemon login status") echo "Status text Arch does not read"; exit \(code);;
          *) exit 2;;
        esac
        """)
        #expect(try await AIAgentToolStatus.read(kind: .codex, executable: codex, environment: ["PATH": "/usr/bin:/bin"])
                == AIAgentToolStatus(version: "0.164.0", isSignedIn: signedIn))
    }

    @Test func aToolThatDoesNotStartSaysWhy() async {
        await #expect(throws: (any Error).self) {
            try await AIAgentToolStatus.read(kind: .claudeCode, executable: URL(fileURLWithPath: "/nonexistent/claude"), environment: ["PATH": "/usr/bin:/bin"])
        }
    }
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPreferencesTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func script(named name: String, in folder: URL, body: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
