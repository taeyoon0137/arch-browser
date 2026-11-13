// `arch-cli`'s side of the control channel without a socket: the `argv[0]` dispatch to `arch-mcp`, the command table's parsing and usage errors, the exit codes and the statuses and client errors they report, and the first harness with its `cli` topic generated from the command table and the exit codes.
import AgentControl
import Foundation
import Testing

@Suite struct CommandLineTests {
    @Test func argv0TellsArchMCPFromArchCLI() {
        #expect(AgentCommandLine.invocation(arguments: ["arch-mcp"]) == .mcp([]))
        #expect(AgentCommandLine.invocation(arguments: ["/Applications/Arch.app/Contents/Helpers/arch-mcp", "--session"]) == .mcp(["--session"]))
        #expect(AgentCommandLine.invocation(arguments: ["/Users/someone/.local/bin/arch-mcp"]) == .mcp([]))
        #expect(AgentCommandLine.invocation(arguments: ["arch-cli", "mcp", "--session"]) == .mcp(["--session"]))
        #expect(AgentCommandLine.invocation(arguments: ["/Applications/Arch.app/Contents/Helpers/arch-cli", "status"]) == .cli(["status"]))
        // SwiftPM's build folder and any other name run as arch-cli.
        #expect(AgentCommandLine.invocation(arguments: [".build/debug/arch-cli", "guide", "cli"]) == .cli(["guide", "cli"]))
        #expect(AgentCommandLine.invocation(arguments: ["arch-mcp-old"]) == .cli([]))
        #expect(AgentCommandLine.invocation(arguments: ["arch-cli", "status", "mcp"]) == .cli(["status", "mcp"]))
        #expect(AgentCommandLine.invocation(arguments: []) == .cli([]))
    }

    @Test func commandsParse() throws {
        #expect(try AgentCommandLine.parse(["status"]) == AgentCLIRequest(command: .status, json: false))
        #expect(try AgentCommandLine.parse(["--json", "status"]) == AgentCLIRequest(command: .status, json: true))
        #expect(try AgentCommandLine.parse(["tools", "--json"]) == AgentCLIRequest(command: .tools, json: true))
        #expect(try AgentCommandLine.parse(["guide"]) == AgentCLIRequest(command: .guide(nil), json: false))
        #expect(try AgentCommandLine.parse(["guide", "cli"]) == AgentCLIRequest(command: .guide(.cli), json: false))
        #expect(try AgentCommandLine.parse(["--help"]).command == .help)
        #expect(try AgentCommandLine.parse(["help"]).command == .help)
        #expect(try AgentCommandLine.parse(["status", "-h"]).command == .help)
        #expect(try AgentCommandLine.parse(["spaces"]) == AgentCLIRequest(command: .spaces, json: false))
        #expect(try AgentCommandLine.parse(["tabs"]) == AgentCLIRequest(command: .tabs(shared: false), json: false))
        #expect(try AgentCommandLine.parse(["tabs", "--shared", "--json"]) == AgentCLIRequest(command: .tabs(shared: true), json: true))
        #expect(try AgentCommandLine.parse(["release"]) == AgentCLIRequest(command: .release, json: false))
        #expect(try AgentCommandLine.parse(["mcp-config"]).command == .mcpConfig(nil))
        #expect(try AgentCommandLine.parse(["mcp-config", "codex"]).command == .mcpConfig(.codex))
        #expect(try AgentCommandLine.parse(["setup", "claude"]).command == .setup(.claude))
        #expect(try AgentCommandLine.parse(["links", "install"]).command == .links(.install, folder: nil))
        #expect(try AgentCommandLine.parse(["links", "install", "--dir", "/Users/someone/bin"]).command == .links(.install, folder: "/Users/someone/bin"))
        #expect(try AgentCommandLine.parse(["--dir", "bin", "links", "remove"]).command == .links(.remove, folder: "bin"))
        #expect(try AgentCommandLine.parse(["guide", "purchases-and-messages"]).command == .guide(.purchasesAndMessages))
        #expect(try AgentCommandLine.parse(["skills", "list"]).command == .skills(.list, places: []))
        #expect(try AgentCommandLine.parse(["skills", "install", "--target", "claude", "--target", "codex", "--target", "claude"]).command == .skills(.install, places: [.target(.claude), .target(.codex)]))
        #expect(try AgentCommandLine.parse(["--path", "/Users/someone/skills", "skills", "remove", "--target", "codex-home"]).command == .skills(.remove, places: [.path("/Users/someone/skills"), .target(.codexHome)]))
        #expect(try AgentCommandLine.parse(["skills", "list", "--target", "codex"]).command == .skills(.list, places: [.target(.codex)]))
    }

    @Test(arguments: [
        ([], "Name a command."),
        (["open", "https://example.org"], "Unknown command open."),
        (["status", "now"], "status takes no arguments."),
        (["tools", "all"], "tools takes no arguments."),
        (["guide", "cli", "browsing"], "guide takes at most one topic."),
        (["guide", "secrets"], "There is no guide topic named secrets. Topics: browsing, forms, research, downloads, purchases-and-messages, troubleshooting, cli."),
        (["--verbose", "status"], "Unknown option --verbose."),
        (["spaces", "--shared"], "Only tabs takes --shared."),
        (["tabs", "t1"], "tabs takes no arguments."),
        (["release", "now"], "release takes no arguments."),
        (["--json", "mcp"], "mcp must be the first argument, as in arch-cli mcp."),
        (["mcp-config", "cursor"], "mcp-config takes claude, codex, or json."),
        (["mcp-config", "claude", "codex"], "mcp-config takes at most one of claude, codex, or json."),
        (["setup"], "setup takes claude or codex."),
        (["setup", "json"], "setup takes claude or codex."),
        (["links"], "links takes install or remove."),
        (["links", "install", "--dir"], "--dir needs a folder."),
        (["status", "--dir", "bin"], "--dir belongs to links."),
        (["skills"], "skills takes list, install, or remove."),
        (["skills", "update"], "skills takes list, install, or remove."),
        (["skills", "install"], "skills install needs --target claude, codex, or codex-home, or --path with a folder."),
        (["skills", "remove"], "skills remove needs --target claude, codex, or codex-home, or --path with a folder."),
        (["skills", "install", "--target", "cursor"], "--target takes claude, codex, or codex-home."),
        (["skills", "install", "--target"], "--target needs claude, codex, or codex-home."),
        (["skills", "install", "--path"], "--path needs a folder."),
        (["skills", "list", "--dir", "bin"], "--dir belongs to links."),
        (["links", "install", "--target", "claude"], "--target and --path belong to skills."),
        (["guide", "--path", "/tmp"], "--target and --path belong to skills."),
    ])
    func usageErrors(arguments: [String], message: String) {
        #expect(throws: AgentUsageError(message: message)) { try AgentCommandLine.parse(arguments) }
    }

    @Test func exitCodesFollowTheDesign() {
        let expected: [(AgentExitCode, Int32)] = [
            (.done, 0), (.toolError, 1), (.usage, 2), (.denied, 3), (.refused, 4), (.timedOut, 5), (.noGrant, 6),
            (.unavailable, 69), (.internalError, 70), (.protocolMismatch, 75), (.notArch, 77),
        ]
        #expect(AgentExitCode.allCases.map(\.rawValue) == expected.map(\.1))
        for (code, value) in expected { #expect(code.rawValue == value) }
    }

    @Test func resultStatusesMapToExitCodes() {
        #expect(AgentExitCode(status: .ok) == .done)
        #expect(AgentExitCode(status: .error) == .toolError)
        #expect(AgentExitCode(status: .stale) == .toolError)
        #expect(AgentExitCode(status: .denied) == .denied)
        #expect(AgentExitCode(status: .refused) == .refused)
        #expect(AgentExitCode(status: .timeout) == .timedOut)
        #expect(AgentExitCode(status: .approvalPending) == .timedOut)
    }

    @Test func clientErrorsMapToExitCodes() {
        #expect(AgentClientError.notRunning.exitCode == .unavailable)
        #expect(AgentClientError.refused(AgentRefusal(reason: .outsideAccessOff, message: "Outside access is off.")).exitCode == .unavailable)
        #expect(AgentClientError.notArch(.otherCode).exitCode == .notArch)
        #expect(AgentClientError.notArch(.noExpectedCode).exitCode == .notArch)
        #expect(AgentClientError.protocolMismatch(arch: 2).exitCode == .protocolMismatch)
        #expect(AgentClientError.refused(AgentRefusal(reason: .protocolMismatch, message: "")).exitCode == .protocolMismatch)
        #expect(AgentClientError.refused(AgentRefusal(reason: .ticket, message: "")).exitCode == .noGrant)
        #expect(AgentClientError.refused(AgentRefusal(reason: AgentRefusal.Reason(rawValue: "later"), message: "")).exitCode == .noGrant)
        #expect(AgentClientError.closedBeforeAnswer.exitCode == .noGrant)
        #expect(AgentClientError.closed.exitCode == .unavailable)
        #expect(AgentClientError.timedOut.exitCode == .internalError)
        #expect(AgentClientError.noSocketLocation.exitCode == .internalError)
        #expect(AgentClientError.noGrant("You did not allow it.").exitCode == .noGrant)
        #expect(AgentClientError.revoked("Revoked.").exitCode == .noGrant)
        #expect(AgentClientError.failed(.methodNotFound("task/start")).exitCode == .internalError)
        #expect(AgentClientError.protocolMismatch(arch: 2).message.contains("version 2") && AgentClientError.protocolMismatch(arch: 2).message.contains("version 1"))
    }

    @Test func theGuideAndItsCLITopic() {
        #expect(AgentHarness.text(for: nil) == AgentHarness.instructions)
        #expect(AgentHarness.instructions.contains("session_info"))
        #expect(AgentHarness.instructions.contains("<untrusted source=\"page\""))
        for topic in AgentGuideTopic.allCases {
            #expect(AgentHarness.instructions.contains(topic.rawValue))
            #expect(!AgentHarness.text(for: topic).isEmpty)
        }
        let cli = AgentHarness.text(for: .cli)
        for command in AgentCommandLine.commands {
            #expect(cli.contains("  \(command.name)"), "\(command.name)")
            #expect(cli.contains(command.summary), "\(command.name)")
        }
        for code in AgentExitCode.allCases {
            #expect(cli.contains("  \(code.rawValue)"), "\(code.rawValue)")
            #expect(cli.contains(code.meaning), "\(code.rawValue)")
        }
        #expect(cli.contains("guide, tools, mcp-config, setup, links, and skills work without Arch running."))
        #expect(!cli.contains("\n\n\n"))
    }
}
