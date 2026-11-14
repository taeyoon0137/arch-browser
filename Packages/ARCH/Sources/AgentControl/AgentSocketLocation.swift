// Where the control socket lives, by the rule both ends follow (docs/agents.md, Local control channel ▸ Transport): `~/Library/Application Support/Arch/Agent/control.sock`, with the home folder from the account database, never `$HOME`, so that an environment cannot move it. A path too long for `sun_path` moves to the per-user temporary folder. A client outside an app bundle, whose check of any listener fails, follows `ARCH_AGENT_TEST_SOCKET` when it is set, so that tests of the built `arch-cli` reach no running Arch.
import Darwin
import Foundation

public struct AgentSocketLocation: Equatable, Sendable {
    public var path: String
    /// Whether the home folder's path was too long and the socket is in the per-user temporary folder instead.
    public var isInTemporaryFolder: Bool

    /// A location at a given path, as tests use; `resolve` and `current()` apply the rule.
    public init(path: String, isInTemporaryFolder: Bool) {
        self.path = path
        self.isInTemporaryFolder = isInTemporaryFolder
    }

    /// The folder that holds the socket, which Arch creates with mode 0700.
    public var folder: String { (path as NSString).deletingLastPathComponent }

    static let fileName = "control.sock"
    static let temporaryFolderName = "xyz.taeyoon.arch"

    /// `sun_path`'s size: 104 bytes on macOS, the terminating NUL included.
    public static let addressCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// The location for a home folder and a per-user temporary folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), or nil when neither path fits `sun_path`.
    public static func resolve(homeFolder: String, temporaryFolder: String) -> AgentSocketLocation? {
        let primary = ((homeFolder as NSString).appendingPathComponent("Library/Application Support/Arch/Agent") as NSString).appendingPathComponent(fileName)
        if fits(primary) { return AgentSocketLocation(path: primary, isInTemporaryFolder: false) }
        let fallback = ((temporaryFolder as NSString).appendingPathComponent(temporaryFolderName) as NSString).appendingPathComponent(fileName)
        if fits(fallback) { return AgentSocketLocation(path: fallback, isInTemporaryFolder: true) }
        return nil
    }

    /// The location for the user this process runs as.
    public static func current() -> AgentSocketLocation? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        return resolve(homeFolder: String(cString: home), temporaryFolder: String(cString: buffer))
    }

    /// The variable that names the socket for a client outside an app bundle, such as `.build/debug/arch-cli` in the tests. A bundled client ignores it.
    public static let unbundledClientVariable = "ARCH_AGENT_TEST_SOCKET"

    /// The location a client connects to: `current()`, or for a client outside an app bundle the path `unbundledClientVariable` names, when set. Such a client fails its check of any listener and sends nothing (docs/agents.md, Client checks of Arch), so the variable changes only which socket it reaches, never what reaches Arch. Nil when the named path does not fit `sun_path`.
    public static func forClient(at executable: URL? = AgentBundleLayout.currentExecutable(), environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentSocketLocation? {
        guard executable.flatMap(AgentBundleLayout.containing(helper:)) == nil, let path = environment[unbundledClientVariable], !path.isEmpty else { return current() }
        return fits(path) ? AgentSocketLocation(path: path, isInTemporaryFolder: false) : nil
    }

    /// Whether the path and its terminating NUL fit `sun_path`.
    static func fits(_ path: String) -> Bool {
        path.utf8.count < addressCapacity
    }

    /// The socket address for `connect` and `bind`.
    public func address() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
