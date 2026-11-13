// The parent launch constraints of a native app's helper, which macOS signs into the helper and enforces when a process starts it: Arch reads them from `codesign -d -vvvv` output and checks whether its own signature meets one of them, so that it makes no link for a host whose helper macOS would not start for Arch (`docs/password-managers.md`, Host discovery ▸ Held hosts, and Status and guidance). Arch's team identifier stays in memory: nothing here prints, shows, or stores it.
import Foundation
import Security

/// The conditions on the process that starts a helper, as its parent launch constraints give them: an `$or-array` whose members are a listed browser's signing identifiers with its team identifier, or an entitlement that the parent's signature must set.
struct HelperLaunchConstraints: Equatable {
    /// One member of the constraints.
    enum Condition: Equatable {
        /// A parent signed with one of the identifiers by the team.
        case signature(identifiers: Set<String>, team: String)
        /// A parent whose entitlements set the key to the value, such as `com.apple.developer.web-browser.public-key-credential` to true.
        case entitlement(String, Bool)
        /// A member that Arch does not read, which it can neither meet nor rule out.
        case unknown
    }

    /// The host names whose native app is a helper with such constraints: the iCloud Passwords helper's.
    static let constrainedHosts: Set<String> = ["com.apple.passwordmanager"]

    let conditions: [Condition]

    /// The parent launch constraints in the output of `codesign -d -vvvv`, its standard error and then its standard output: the first lists the kinds of constraints the code has under `Launch Constraints:`, and the second prints each kind, in that order, as a tree of `[Dict]`, `[Key]`, `[Value]`, `[Array]`, `[String]`, `[Int]`, and `[Bool]` lines indented by tabs, whose top is a `[Dict]` one tab in. Nil for output without parent constraints or whose trees do not read.
    init?(codesignOutput output: String) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let start = lines.firstIndex(of: "Launch Constraints:") else { return nil }
        let kinds = lines[(start + 1)...].prefix { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let parentIndex = kinds.firstIndex(where: { $0.contains("Parent") }) else { return nil }
        // Each kind's tree starts with a `[Dict]` one tab in, after the lines above.
        let trees = lines.indices.filter { $0 > start + kinds.count && lines[$0] == "\t[Dict]" }
        guard trees.count == kinds.count else { return nil }
        let first = trees[parentIndex]
        let end = parentIndex + 1 < trees.count ? trees[parentIndex + 1] : lines.count
        let tree = ([lines[first]] + lines[(first + 1)..<end].prefix { $0.hasPrefix("\t\t") }).map { line in
            (depth: line.prefix { $0 == "\t" }.count, text: line.trimmingCharacters(in: .whitespaces))
        }
        var parser = ConstraintTreeParser(lines: tree)
        guard case let .dictionary(constraint)? = parser.node(), case let .dictionary(requirements)? = constraint["reqs"] else { return nil }
        conditions = Self.conditions(in: requirements)
        guard !conditions.isEmpty else { return nil }
    }

    init(conditions: [Condition]) {
        self.conditions = conditions
    }

    /// The members of the requirements: each of an `$or-array`, or the requirements as one member.
    private static func conditions(in requirements: [String: ConstraintNode]) -> [Condition] {
        guard requirements.keys.contains("$or-array") else { return [condition(requirements)] }
        guard requirements.count == 1, case let .array(members)? = requirements["$or-array"] else { return [.unknown] }
        return members.map { member in
            switch member {
            case let .array(parts) where parts.count == 2 && parts[0] == .string("$and"):
                guard case let .dictionary(fields) = parts[1] else { return .unknown }
                return condition(fields)
            case let .dictionary(fields):
                return condition(fields)
            default:
                return .unknown
            }
        }
    }

    /// A member whose fields all hold: a signing identifier, alone or `$in` a list, with a team identifier; or an entitlement query, a key and the value it must have.
    private static func condition(_ fields: [String: ConstraintNode]) -> Condition {
        if Set(fields.keys) == ["signing-identifier", "team-identifier"], case let .string(team)? = fields["team-identifier"] {
            switch fields["signing-identifier"] {
            case let .string(identifier)?:
                return .signature(identifiers: [identifier], team: team)
            case let .dictionary(match)? where match.count == 1:
                guard case let .array(listed)? = match["$in"] else { return .unknown }
                let identifiers = listed.compactMap { node -> String? in
                    guard case let .string(identifier) = node else { return nil }
                    return identifier
                }
                return identifiers.count == listed.count ? .signature(identifiers: Set(identifiers), team: team) : .unknown
            default:
                return .unknown
            }
        }
        // `codesign` prints an entitlement query as two steps: the key, then the value it must equal.
        if fields.count == 1, case let .dictionary(entitlements)? = fields["entitlements"], entitlements.count == 1,
           case let .array(steps)? = entitlements["$query"], steps.count == 2,
           case let .array(keyStep) = steps[0], case let .array(valueStep) = steps[1] {
            let key = keyStep.lazy.compactMap { node -> String? in
                guard case let .string(key) = node else { return nil }
                return key
            }.first
            let value = valueStep.lazy.compactMap { node -> Bool? in
                guard case let .bool(value) = node else { return nil }
                return value
            }.first
            if let key, let value { return .entitlement(key, value) }
        }
        return .unknown
    }

    /// Whether a parent with the signature meets one of the conditions: true when one matches, false when every condition is one Arch reads and none matches, and nil when none matches but some are unknown.
    func admit(_ signature: CodeSignature) -> Bool? {
        var hasUnknown = false
        for condition in conditions {
            switch condition {
            case let .signature(identifiers, team):
                if let identifier = signature.identifier, identifiers.contains(identifier), signature.team == team { return true }
            case let .entitlement(key, value):
                if signature.booleanEntitlements[key] == value { return true }
            case .unknown:
                hasUnknown = true
            }
        }
        return hasUnknown ? nil : false
    }

    /// Whether Arch's own signature meets the parent launch constraints of the helper at `url`, read with `codesign -d -vvvv`: nil when the output or Arch's signature does not read. Runs `codesign` and waits for it, so it belongs off the main thread.
    static func admitArch(toHelperAt url: URL) -> Bool? {
        guard let output = codesignOutput(for: url), let constraints = HelperLaunchConstraints(codesignOutput: output), let own = CodeSignature.own() else { return nil }
        return constraints.admit(own)
    }

    /// What `codesign -d -vvvv` prints about the code at `url`, or nil when it fails: its standard error, which lists the kinds of launch constraints the code has, then its standard output, which prints their trees.
    private static func codesignOutput(for url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-vvvv", url.path]
        let (output, errors) = (Pipe(), Pipe())
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Both pipes drain at once, so that neither fills while `codesign` writes to the other.
        let errorDrain = PipeDrain(errors.fileHandleForReading)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorDrain.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: errorData, as: UTF8.self) + String(decoding: outputData, as: UTF8.self)
    }
}

/// Reads a pipe to its end on a thread of its own.
private final class PipeDrain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    /// The pipe's data once it ends.
    func wait() -> Data {
        done.wait()
        return data
    }
}

/// The parts of a code signature that launch constraints name: the signing identifier, the team identifier, kept only in memory, and the entitlements whose values are true or false.
struct CodeSignature: Equatable {
    var identifier: String?
    var team: String?
    var booleanEntitlements: [String: Bool] = [:]

    /// Arch's own signature, from `SecCodeCopySigningInformation`, or nil when it does not read. An ad hoc or missing signature has no team.
    static func own() -> CodeSignature? {
        guard let information = ownSigningInformation() else { return nil }
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return CodeSignature(identifier: information[kSecCodeInfoIdentifier as String] as? String, team: information[kSecCodeInfoTeamIdentifier as String] as? String,
                             booleanEntitlements: entitlements.compactMapValues { $0 as? Bool })
    }

    /// What `SecCodeCopySigningInformation` gives for Arch's own code, with its signing and requirement information, or nil when it does not read. Its team is for the caller's question only, never to show or keep.
    static func ownSigningInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation | kSecCSRequirementInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
}

/// A node of a tree that `codesign` prints.
private indirect enum ConstraintNode: Equatable {
    case dictionary([String: ConstraintNode])
    case array([ConstraintNode])
    case string(String)
    case integer(Int)
    case bool(Bool)
    /// A kind of line Arch does not read, such as `[Data]`.
    case other
}

/// Reads a tree from its lines, each with its depth in tabs: a `[Dict]` holds `[Key] <name>` and `[Value]` lines one deeper, each value one deeper still, and an `[Array]` holds its members one deeper.
private struct ConstraintTreeParser {
    let lines: [(depth: Int, text: String)]
    private var index = 0

    init(lines: [(depth: Int, text: String)]) {
        self.lines = lines
    }

    /// The node at the current line and its children, or nil at the end or for a tree that does not read.
    mutating func node() -> ConstraintNode? {
        guard index < lines.count else { return nil }
        let (depth, text) = lines[index]
        index += 1
        switch text {
        case "[Dict]":
            var fields: [String: ConstraintNode] = [:]
            while index < lines.count, lines[index].depth > depth {
                guard lines[index].depth == depth + 1, lines[index].text.hasPrefix("[Key] "), index + 1 < lines.count,
                      lines[index + 1].depth == depth + 1, lines[index + 1].text == "[Value]" else { return nil }
                let key = String(lines[index].text.dropFirst("[Key] ".count))
                index += 2
                guard index < lines.count, lines[index].depth == depth + 2, let value = node() else { return nil }
                fields[key] = value
            }
            return .dictionary(fields)
        case "[Array]":
            var members: [ConstraintNode] = []
            while index < lines.count, lines[index].depth > depth {
                guard lines[index].depth == depth + 1, let member = node() else { return nil }
                members.append(member)
            }
            return .array(members)
        default:
            if text.hasPrefix("[String] ") { return .string(String(text.dropFirst("[String] ".count))) }
            if text.hasPrefix("[Int] ") { return Int(text.dropFirst("[Int] ".count)).map(ConstraintNode.integer) }
            if text == "[Bool] true" { return .bool(true) }
            if text == "[Bool] false" { return .bool(false) }
            // Skip what an unknown line holds.
            while index < lines.count, lines[index].depth > depth { index += 1 }
            return .other
        }
    }
}
