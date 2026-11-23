// Who an outside client is (docs/agents.md, Outside clients: identity, grants, revocation): the nearest ancestor of the connecting `arch-cli` that is not a shell, `env`, `login`, `sudo`, or one of Arch's tools, found by walking the parent chain through `sysctl`, with its path and signature from Security and its name from the path it was started with. A team signature identifies the client by signing identifier and team; any other, ad hoc ones included, by path and code directory hash. The walk never takes launchd or Arch, which every process below them would share: the client is then the process just below them, bound to its process ID and start time. A client reached through a shell is marked, since every program that runs in that shell can take `arch-cli`'s place on the chain with `exec`.
import Darwin
import Foundation
import Security

/// A process as `sysctl` (`KERN_PROC_PID`) reports it.
struct AgentProcessRecord: Equatable, Sendable {
    var processID: pid_t
    var parentID: pid_t
    var start: AgentProcessStart
}

/// A process's running code as Security reports it.
struct AgentProcessCode: Equatable, Sendable {
    var path: String
    var codeHash: Data?
    var signingIdentifier: String?
    /// Set only when the code is valid and its leaf certificate, issued under Apple's anchor, names this team, which an ad hoc signature never does.
    var verifiedTeam: String?
}

/// The sources the walk reads, which tests replace.
protocol AgentProcessInspector: Sendable {
    func record(of processID: pid_t) -> AgentProcessRecord?
    func code(of processID: pid_t) -> AgentProcessCode?
    /// The path the process was started with, as `execve` received it, which keeps a link's name where Security reports the file the link points to.
    func launchPath(of processID: pid_t) -> String?
}

/// The process table through `sysctl` and running code through Security. `libproc` is not used: its header calls its interfaces private.
struct AgentSystemProcessInspector: AgentProcessInspector {
    func record(of processID: pid_t) -> AgentProcessRecord? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == processID else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return AgentProcessRecord(processID: processID, parentID: info.kp_eproc.e_ppid, start: AgentProcessStart(seconds: start.tv_sec, microseconds: start.tv_usec))
    }

    /// `KERN_PROCARGS2` begins with the argument count and then the path `execve` received.
    func launchPath(of processID: pid_t) -> String? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let path = buffer[MemoryLayout<Int32>.size ..< size].prefix { $0 != 0 }
        return path.isEmpty ? nil : String(decoding: path, as: UTF8.self)
    }

    func code(of processID: pid_t) -> AgentProcessCode? {
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: processID] as CFDictionary, [], &guest) == errSecSuccess, let guest else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let path = (url as URL?)?.path else { return nil }
        var information: CFDictionary?
        _ = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let info = information as? [String: Any] ?? [:]
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return AgentProcessCode(path: path, codeHash: info[kSecCodeInfoUnique as String] as? Data, signingIdentifier: info[kSecCodeInfoIdentifier as String] as? String,
                                verifiedTeam: team.flatMap { Self.isValid(guest, signedByTeam: $0) ? $0 : nil })
    }

    /// Whether the running code is valid and signed with a certificate of `team` under Apple's anchor, which an ad hoc signature, whose identifier the signer chooses, cannot meet.
    private static func isValid(_ code: SecCode, signedByTeam team: String) -> Bool {
        guard team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

enum AgentClientIdentificationError: Error, Equatable {
    /// A process on the chain could not be read, or ended while the walk read it.
    case processChanged
    /// The chain is longer than any real one.
    case chainTooLong
}

struct AgentClientIdentifier: Sendable {
    let inspector: any AgentProcessInspector
    /// Arch's own process, which the walk never takes.
    let archProcessID: pid_t
    /// The bundled `arch-cli`'s code directory hash: a process with it is one of Arch's tools.
    let toolHash: Data?
    /// Shells, `env`, `login`, and `sudo`, by path: the shells `/etc/shells` lists and the system's tools, so that a program cannot pass itself off as a shell by its name.
    let passedOverPaths: Set<String>

    static let maximumDepth = 64

    static func systemPassedOverPaths() -> Set<String> {
        let shells = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8))?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") } ?? []
        return Set(shells + ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh", "/bin/ksh", "/usr/bin/env", "/usr/bin/login", "/usr/bin/sudo"])
    }

    /// Executable names that run scripts, each one identity for every script it runs.
    static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl", "php", "deno", "bun", "osascript", "java", "lua", "pwsh", "tclsh", "Rscript"]

    /// The client of the connection whose peer is `peerID`.
    func identify(peer peerID: pid_t) throws -> AgentClientIdentity {
        var processID = peerID
        // Set once the walk passes a shell, `env`, `login`, or `sudo`, or takes one as the client.
        var throughShell = false
        for _ in 0 ..< Self.maximumDepth {
            guard let record = inspector.record(of: processID), let code = inspector.code(of: processID) else { throw AgentClientIdentificationError.processChanged }
            let parent = record.parentID
            if !isPassedOver(code) {
                return try identity(of: record, code, boundToProcess: false, reachedThroughShell: throughShell)
            }
            throughShell = throughShell || passedOverPaths.contains(code.path)
            if parent <= 1 || parent == archProcessID {
                return try identity(of: record, code, boundToProcess: true, reachedThroughShell: throughShell)
            }
            processID = parent
        }
        throw AgentClientIdentificationError.chainTooLong
    }

    private func isPassedOver(_ code: AgentProcessCode) -> Bool {
        if let toolHash, code.codeHash == toolHash { return true }
        return passedOverPaths.contains(code.path)
    }

    private func identity(of record: AgentProcessRecord, _ code: AgentProcessCode, boundToProcess: Bool, reachedThroughShell: Bool) throws -> AgentClientIdentity {
        let hash = code.codeHash.map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
        let key: AgentClientIdentity.Key
        if boundToProcess {
            key = .process(path: code.path, codeHash: hash, processID: record.processID, start: record.start)
        } else if let team = code.verifiedTeam, let identifier = code.signingIdentifier {
            key = .signed(identifier: identifier, team: team)
        } else {
            key = .unsigned(path: code.path, codeHash: hash)
        }
        // The name it was started with, such as `claude` for a link to `…/claude/versions/2.1.323`; the key and the path stay the file's.
        let fileName = URL(fileURLWithPath: code.path).lastPathComponent
        let launchName = inspector.launchPath(of: record.processID).map { URL(fileURLWithPath: $0).lastPathComponent }
        let name = launchName.flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        let identity = AgentClientIdentity(key: key, name: name, executablePath: code.path, host: host(of: record, code),
                                           isInterpreter: Self.isInterpreter(name) || Self.isInterpreter(fileName), reachedThroughShell: reachedThroughShell)
        // A process that ended while Security read it may have handed its ID to another.
        guard inspector.record(of: record.processID)?.start == record.start else { throw AgentClientIdentificationError.processChanged }
        return identity
    }

    /// The app that shows the client: the `.app` around it, unless the client is that app, else the nearest ancestor's, or Arch's terminal when the chain reaches Arch first.
    private func host(of record: AgentProcessRecord, _ code: AgentProcessCode) -> String? {
        if let app = Self.appName(around: code.path) {
            return app.caseInsensitiveCompare(URL(fileURLWithPath: code.path).lastPathComponent) == .orderedSame ? nil : app
        }
        var parent = record.parentID
        for _ in 0 ..< Self.maximumDepth {
            if parent == archProcessID { return localized("Arch\u{2019}s terminal") }
            guard parent > 1, let ancestor = inspector.record(of: parent), let ancestorCode = inspector.code(of: parent) else { return nil }
            if let app = Self.appName(around: ancestorCode.path) { return app }
            parent = ancestor.parentID
        }
        return nil
    }

    /// The name of the outermost `.app` folder on the path, such as Terminal for `/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal`.
    static func appName(around path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    static func isInterpreter(_ name: String) -> Bool {
        if interpreters.contains(name) { return true }
        // Versioned names such as python3.12 or node22.
        return interpreters.contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." } }
    }
}
