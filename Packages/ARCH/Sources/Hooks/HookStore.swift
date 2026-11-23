// `hooks.json` and the hooks' script folders (`docs/hooks.md`, Storage; hook decision 8). The file is sealed like `agent.json`, under its own Keychain item, and versioned: an earlier version is migrated in memory, and a later one is read as far as this build knows it and written back with the members and hooks this build does not know unchanged; a later version's hook with a member this build would not write back, inside one of its values, is one this build cannot read. Each script lives in `Hooks/<hook id>/` and runs only while its bytes match the digest the sealed file holds.
import Agent
import AgentControl
import AI
import CryptoKit
import Foundation

/// What `hooks.json` holds besides the scripts.
public struct HookSettings: Sendable {
    /// Settings ▸ AI ▸ Hooks ▸ Run Hooks; on by default.
    public var runsHooks = true
    /// Allow Shell Scripts; off by default.
    public var allowsShellScripts = false
    /// The providers Arch saw the user set up (`docs/hooks.md`, Known providers).
    public var knownProviders: [HookKnownProvider] = []
    /// In run order. A hook this build cannot read is listed paused with `needsNewerArch`, and the store writes it back as it read it.
    public var hooks: [Hook] = []

    public init() {}
}

/// A provider the user set up while Arch ran: its identifier and destination, an HTTP provider's base address or a command-line tool's executable path with the digest of its preset, arguments, and environment (`AIProviderConfiguration.hookDestination`).
public struct HookKnownProvider: Codable, Hashable, Sendable {
    public var id: AIProviderID
    public var destination: String

    public init(id: AIProviderID, destination: String) {
        self.id = id
        self.destination = destination
    }

    /// The provider as `hooks.json` records it.
    public init(_ provider: AIProviderConfiguration) {
        self.init(id: provider.id, destination: provider.hookDestination)
    }
}

/// What Settings ▸ AI ▸ Hooks says about the file.
public enum HookStoreNotice: Equatable, Sendable {
    /// `hooks.json` did not open: its seal did not match, it did not read, its key is gone, or it is an earlier copy put back. It is now `hooks.json.unreadable`, and Arch started with no hooks.
    case setAside
    /// The Keychain did not give the key, for this reason. The file stays as it was, and no hook runs until Try Again reads it.
    case keyUnavailable(String)
    /// The file is from a newer Arch, at this version. Hooks this build cannot read are listed and do not run.
    case newerVersion(Int)
    /// The last change was not written, for this reason.
    case notSaved(String)
}

/// A refusal to change hooks before their sealed settings are ready.
public enum HookStoreError: LocalizedError {
    /// The file has not been read, or the Keychain did not give its key, so a write would replace hooks Arch has not seen.
    case notReady

    public var errorDescription: String? {
        localized("Arch has not read its hooks yet, so it cannot change them.")
    }
}

@MainActor
/// Reads and writes sealed hook settings while preserving fields from newer versions.
public final class HookStore {
    public static let fileName = "hooks.json"
    public static let scriptsFolderName = "Hooks"
    public nonisolated static let currentVersion = 1
    /// One step per later version: the step at key `n` turns version `n`'s settings into version `n + 1`'s.
    public typealias Migration = @Sendable (AgentJSON) throws -> AgentJSON
    nonisolated static let migrations: [Int: Migration] = [:]

    /// The folder of `hooks.json`, the scripts' folder, and the run log.
    public let directory: URL
    /// What Settings says about the file, from its last read or write.
    public private(set) var notice: HookStoreNotice?
    /// Whether the file was read, or found missing, and may be written.
    public private(set) var isReady = false
    /// Whether the file exists, read at launch or written since.
    public private(set) var hasFile = false
    /// Whether the launch found no file, rather than one set aside.
    private var readWasNone = false

    private let file: SealedSettingsFile<AgentJSON>
    private let version: Int
    private let migrations: [Int: Migration]
    /// The settings' members as read, to keep those this build does not know.
    private var members: [String: AgentJSON] = [:]
    /// Each hook's members as read, by its identifier: written back unchanged for a hook this build cannot read, and merged for one it can.
    private var storedHooks: [UUID: AgentJSON] = [:]
    private var unreadableHooks: Set<UUID> = []
    /// The version the next write gives the file: this build's, or a later file's own.
    private var writtenVersion: Int

    /// The store for the app: `hooks.json` in `directory`, its key under the Keychain service `xyz.taeyoon.arch.hooks`.
    public convenience init(directory: URL) {
        self.init(directory: directory, keys: AgentKeychainSealKey(service: "xyz.taeyoon.arch.hooks", account: "hooks.json seal", label: "Arch hooks seal"))
    }

    /// `version` and `migrations` default to this build's; tests give their own.
    init(directory: URL, keys: any AgentSealKeyStore, version: Int = HookStore.currentVersion, migrations: [Int: Migration] = HookStore.migrations) {
        self.directory = directory
        self.version = version
        self.migrations = migrations
        writtenVersion = version
        file = SealedSettingsFile(fileURL: directory.appendingPathComponent(Self.fileName), keys: keys)
    }

    public var fileURL: URL { file.fileURL }

    // MARK: Reading

    /// Reads and checks the file, reading the key once. Returns nil when the Keychain did not give the key, which leaves the file unchanged; otherwise the settings, which are the defaults for a missing file or one set aside.
    public func load() async -> HookSettings? {
        let reading = await file.read()
        if case .none = reading { readWasNone = true } else { readWasNone = false }
        switch reading {
        case .none:
            return ready(notice: nil, hasFile: false)
        case .replaced:
            return ready(notice: .setAside, hasFile: false)
        case .keyUnavailable(let reason):
            isReady = false
            notice = .keyUnavailable(reason)
            return nil
        case .verified(let contents):
            do {
                let settings = try read(contents)
                isReady = true
                hasFile = true
                return settings
            } catch {
                // A sealed file this build cannot read at all, as one whose migration fails, is set aside like one whose seal fails.
                file.setAside()
                readWasNone = false
                return ready(notice: .setAside, hasFile: false)
            }
        }
    }

    /// Resets the store to default settings after a missing or set-aside file.
    private func ready(notice: HookStoreNotice?, hasFile: Bool) -> HookSettings {
        self.notice = notice
        isReady = true
        self.hasFile = hasFile
        members = [:]
        storedHooks = [:]
        unreadableHooks = []
        writtenVersion = version
        return HookSettings()
    }

    /// The settings of a verified file, migrated to this build's version or read as far as this build knows a later one.
    private func read(_ contents: AgentJSON) throws -> HookSettings {
        guard var members = contents.objectValue else { throw HookStoreReadError() }
        let fileVersion = try members["version"].map { try $0.decode(as: Int.self) } ?? version
        notice = nil
        if fileVersion < version {
            var migrated = AgentJSON.object(members)
            for step in fileVersion..<version {
                guard let migration = migrations[step] else { throw HookStoreReadError() }
                migrated = try migration(migrated)
            }
            guard let object = migrated.objectValue else { throw HookStoreReadError() }
            members = object
        } else if fileVersion > version {
            notice = .newerVersion(fileVersion)
        }
        writtenVersion = max(fileVersion, version)
        members["version"] = .number(Double(writtenVersion))

        var settings = HookSettings()
        settings.runsHooks = (try? members["runsHooks"]?.decode(as: Bool.self)) ?? true
        settings.allowsShellScripts = (try? members["allowsShellScripts"]?.decode(as: Bool.self)) ?? false
        settings.knownProviders = (try? members["knownProviders"]?.decode(as: [HookKnownProvider].self)) ?? []
        storedHooks = [:]
        unreadableHooks = []
        for stored in members["hooks"]?.arrayValue ?? [] {
            var readable = try? stored.decode(as: Hook.self)
            // A later version's member inside a value, such as one that narrows a filter or a grant, would be lost at this build's next write.
            if let decoded = readable, fileVersion > version, !Self.writesBack(stored, as: decoded) { readable = nil }
            let hook = readable ?? Self.placeholder(for: stored)
            guard storedHooks[hook.id] == nil else { continue }
            if readable == nil { unreadableHooks.insert(hook.id) }
            storedHooks[hook.id] = stored
            settings.hooks.append(hook)
        }
        self.members = members
        return settings
    }

    /// The entry Settings lists for a hook this build cannot read: its identifier and name when they read, paused with `needsNewerArch`.
    private static func placeholder(for stored: AgentJSON) -> Hook {
        let id = stored["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        let created = (try? stored["created"]?.decode(as: Date.self)) ?? Date()
        return Hook(id: id, name: stored["name"]?.stringValue ?? localized("Hook from a newer Arch"), trigger: .tabOpened, state: .paused(.needsNewerArch), created: created)
    }

    /// Whether the store writes this hook back as it read it, since this build cannot read it.
    public func isUnreadable(_ id: UUID) -> Bool {
        unreadableHooks.contains(id)
    }

    // MARK: Writing

    /// Reads or makes the key, which every write needs and which the Keychain may first ask the user for.
    public func prepareKey() async throws {
        try await file.prepareKey()
    }

    public var hasKey: Bool { file.hasKey }

    /// Whether the providers `ai.json` holds now may be taken as the user's: only when no `hooks.json` was ever sealed with the key, as for a user who adds a first hook. A file deleted or set aside leaves the Keychain at a later generation, so a program that removes `hooks.json` and edits `ai.json` gains no known provider. Needs the key, which `prepareKey()` reads.
    public var trustsCurrentProviders: Bool { readWasNone && file.hasKey && file.keyGeneration == 0 }

    /// Writes the settings sealed: the members this build knows from `settings`, the others as read; each hook merged over its members as read, and a hook this build cannot read as read. Returns the Keychain's record of the write's generation.
    @discardableResult
    public func save(_ settings: HookSettings) throws -> Task<Void, any Error> {
        guard isReady else { throw HookStoreError.notReady }
        var written = members
        written["version"] = .number(Double(writtenVersion))
        written["runsHooks"] = .bool(settings.runsHooks)
        written["allowsShellScripts"] = .bool(settings.allowsShellScripts)
        written["knownProviders"] = try AgentJSON(encoding: settings.knownProviders)
        written["hooks"] = .array(try settings.hooks.map { hook in
            if unreadableHooks.contains(hook.id), let stored = storedHooks[hook.id] { return stored }
            return try Self.merge(AgentJSON(encoding: hook), over: storedHooks[hook.id])
        })
        let record = try file.write(.object(written))
        hasFile = true
        members = written
        storedHooks = Dictionary(zip(settings.hooks.map(\.id), written["hooks"]?.arrayValue ?? []), uniquingKeysWith: { first, _ in first })
        unreadableHooks.formIntersection(settings.hooks.map(\.id))
        if case .notSaved = notice { notice = nil }
        return record
    }

    /// Records why a change was not written, for Settings.
    func didNotSave(_ reason: String) {
        notice = .notSaved(reason)
    }

    /// A hook's members: the encoded ones, then those of `stored` that `Hook` does not know.
    private static func merge(_ encoded: AgentJSON, over stored: AgentJSON?) -> AgentJSON {
        guard var members = encoded.objectValue else { return encoded }
        let known = Set(Hook.CodingKeys.allCases.map(\.rawValue))
        for (name, value) in stored?.objectValue ?? [:] where !known.contains(name) {
            members[name] = value
        }
        return .object(members)
    }

    /// Whether this build would write the hook back with every member of `stored`, at every depth.
    private static func writesBack(_ stored: AgentJSON, as hook: Hook) -> Bool {
        guard let encoded = try? AgentJSON(encoding: hook) else { return false }
        return memberPaths(of: stored).isSubset(of: memberPaths(of: merge(encoded, over: stored)))
    }

    /// The paths of the value's members, such as `filter.scope.[].space`, with the elements of an array under one path and a member whose value is null left out.
    private static func memberPaths(of value: AgentJSON, at path: String = "") -> Set<String> {
        switch value {
        case .object(let members):
            return members.reduce(into: []) { paths, member in
                guard member.value != .null else { return }
                let memberPath = path.isEmpty ? member.key : "\(path).\(member.key)"
                paths.insert(memberPath)
                paths.formUnion(memberPaths(of: member.value, at: memberPath))
            }
        case .array(let elements):
            return elements.reduce(into: []) { paths, element in paths.formUnion(memberPaths(of: element, at: "\(path).[]")) }
        case .null, .bool, .number, .string:
            return []
        }
    }

    // MARK: Scripts

    /// The hook's script folder, `Hooks/<hook id>/`.
    public func scriptFolder(of id: UUID) -> URL {
        directory.appendingPathComponent(Self.scriptsFolderName, isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// `hook.js`, or `hook.sh` for a shell script.
    public func scriptURL(of hook: Hook) -> URL {
        scriptFolder(of: hook.id).appendingPathComponent(hook.script.isShell ? "hook.sh" : "hook.js")
    }

    /// Writes the script into the hook's folder, mode 0600 in folders of mode 0700, and returns the hook's script with the bytes' digest.
    public func writeScript(_ data: Data, for hook: Hook) throws -> HookScript {
        let fileManager = FileManager.default
        let scripts = directory.appendingPathComponent(Self.scriptsFolderName, isDirectory: true)
        for folder in [scripts, scriptFolder(of: hook.id)] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        let url = scriptURL(of: hook)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // A hook that changes kind keeps no script of the other kind.
        let other = scriptFolder(of: hook.id).appendingPathComponent(hook.script.isShell ? "hook.js" : "hook.sh")
        try? fileManager.removeItem(at: other)
        return hook.script.withDigest(Self.digest(of: data))
    }

    /// The script's bytes while they match the digest the sealed file holds; nil for a script that is missing or changed outside Arch.
    public func script(for hook: Hook) -> Data? {
        guard let data = try? Data(contentsOf: scriptURL(of: hook)), Self.digest(of: data) == hook.script.digest else { return nil }
        return data
    }

    /// Removes the hook's folder with its script.
    public func removeScripts(of id: UUID) {
        try? FileManager.default.removeItem(at: scriptFolder(of: id))
    }

    /// `sha256:` and the bytes' SHA-256 in lowercase hexadecimal.
    public static func digest(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Thrown for a hook file whose contents are not an object or that this build cannot migrate.
private struct HookStoreReadError: Error {}

extension AgentJSON {
    var arrayValue: [AgentJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }
}
