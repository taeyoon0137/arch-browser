// `arch-cli`, and `arch-mcp` when started under that name or as `arch-cli mcp`: one executable, told apart by `argv[0]`, so that Arch checks one code directory hash (docs/agents.md, agent decision 2). Parsing, the protocol, and the checks are in `AgentControl`; this target runs the commands and writes their output.
import AgentControl
import Darwin

switch AgentCommandLine.invocation(arguments: CommandLine.arguments) {
case .cli(let arguments):
    exit(CLICommands.run(arguments).rawValue)
case .mcp:
    // The MCP server comes with plan task VII.14.
    CLICommands.printError("arch-mcp is not available in this build of Arch.")
    exit(AgentExitCode.internalError.rawValue)
}
