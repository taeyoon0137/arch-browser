// Where Arch's agent executables sit in its app bundle (docs/agents.md, Parts and modules; arch-cli): the app at `Contents/MacOS/Arch`, and `arch-cli` in `Contents/Helpers` with `arch-mcp` as a relative link to it. Each end of the control socket reads the other's expected code from this layout.
import Darwin
import Foundation

public struct AgentBundleLayout: Equatable, Sendable {
    public var bundleURL: URL

    public static let cliName = "arch-cli"
    public static let mcpName = "arch-mcp"

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    /// The app's executable, whose code the client expects at the other end of the socket.
    public var archExecutableURL: URL { bundleURL.appendingPathComponent("Contents/MacOS/Arch") }
    /// The bundled `arch-cli`, whose code Arch expects at the other end of the socket.
    public var cliExecutableURL: URL { helpersURL.appendingPathComponent(Self.cliName) }
    /// The bundled `arch-mcp` link, the path an MCP client's configuration names.
    public var mcpExecutableURL: URL { helpersURL.appendingPathComponent(Self.mcpName) }
    public var helpersURL: URL { bundleURL.appendingPathComponent("Contents/Helpers") }

    /// The bundle around an executable in its `Contents/Helpers` folder, or nil for an executable anywhere else.
    public static func containing(helper executable: URL) -> AgentBundleLayout? {
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else { return nil }
        return AgentBundleLayout(bundleURL: bundle)
    }

    /// This process's executable with every symbolic link resolved (`_NSGetExecutablePath`, then `realpath`), so that a link on PATH or the `arch-mcp` link leads to the bundled `arch-cli`.
    public static func currentExecutable() -> URL? {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        }
        guard let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// The version in the bundle's `Info.plist`.
    public var version: String? {
        Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
