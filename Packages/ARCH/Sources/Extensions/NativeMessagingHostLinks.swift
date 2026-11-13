// Host discovery and the proof gate (`docs/password-managers.md`, Host discovery and Proof gate). Native app vendors install host manifests only for browsers they know, so Arch reads the folders where they install them for other browsers, without changing anything there, and links each valid manifest into its own `NativeMessagingHosts/` folder, which both engines read: a link follows the vendor's changes. The user's own files in that folder take precedence, and a host whose native app macOS does not start for Arch gets no link. A version of an extension reaches a native app through one of Arch's links only when Arch has proof of its identifier, since a package can copy another extension's public key and the native app trusts the identifier the browser passes it.
import Combine
import Foundation
import Plugins

/// A host manifest that a pass found: for its name, the first valid one in the listed folders.
public struct NativeMessagingHost: Hashable, Sendable {
    /// Why Arch makes no link for a host.
    public enum HeldReason: Hashable, Sendable {
        /// macOS starts the native app's helper only for parents that its launch constraints admit, and Arch meets none of them (`HelperLaunchConstraints`).
        case launchConstraints
    }

    public let name: String
    /// The manifest's `description`, or its name without one, as Settings and the gate's sentence name the native app.
    public let description: String
    /// The manifest's `allowed_origins`, each `chrome-extension://<identifier>/`.
    public let allowedOrigins: [String]
    /// The native app's executable, as the manifest names it.
    public let path: String
    /// The listed folder that holds the manifest.
    public let folder: URL
    /// Why Arch makes no link for the host, whatever its folder holds under the name: a held host keeps its reason while the user's file takes the name, and a host that is not held has nil, also while the user's file keeps Arch from linking it.
    public let held: HeldReason?
}

/// The manifest behind one of Arch's links, as the gate reads it.
public struct NativeMessagingLinkedHost: Hashable, Sendable {
    /// The manifest's `description`, or its name without one.
    public let description: String
    /// The manifest's `allowed_origins`, or nil when the manifest behind the link does not read, as while its vendor writes it, which the gate counts as allowing every caller until a pass reads it.
    public let allowedOrigins: [String]?
}

/// The calling version of an extension, as native messaging and the gate see it.
struct NativeMessagingCaller {
    /// The identifier the engines know the extension by, which its origin carries.
    let extensionID: String
    /// Whether the signatures of the version's `.crx` file proved its identifier (`InstalledPlugin.proof`).
    let isProven: Bool
    /// Whether the version came from a `.crx` file before Arch checked signatures, which a reinstall proves (`InstalledPlugin.predatesProof`).
    let predatesProof: Bool
    /// The version's plugin, under which `NativeMessaging` records what its calls met (`NativeAppOutcomes`); nil records nothing.
    let plugin: PluginID?
    /// The date of the version's install, which a recorded outcome keeps, so that an update starts without one.
    let installedAt: Date?

    init(extensionID: String, isProven: Bool, predatesProof: Bool = false, plugin: PluginID? = nil, installedAt: Date? = nil) {
        self.extensionID = extensionID
        self.isProven = isProven
        self.predatesProof = predatesProof
        self.plugin = plugin
        self.installedAt = installedAt
    }

    init(_ installed: InstalledPlugin) {
        self.init(extensionID: WebExtensionManifest.extensionID(of: installed.manifest.id), isProven: installed.proof != nil, predatesProof: installed.predatesProof,
                  plugin: installed.id, installedAt: installed.installedAt)
    }
}

/// Arch's links to the host manifests that vendors install for other browsers, one for the app, which the session makes with Arch's folder and the folders the app shell lists (`BrowserSource.nativeMessagingHostFolders`). A pass reads the folders off the main thread. The runtimes ask for a pass before their first load of an extension whose grant has `nativeMessaging` in a run and after installing or updating one, staging before reviewing a package that asks for it, and Settings ▸ Plugins as it first shows such an extension's section in a run, on or off (`NativeAppGuide`), so a Mac without such an extension never reads the folders.
@MainActor
public final class NativeMessagingHostLinks: ObservableObject {
    /// The longest host manifest a pass reads.
    nonisolated static let manifestLimit = 64 * 1024

    /// Arch's own folder, `NativeMessagingHosts/` in its Application Support folder, which both engines read.
    public let directory: URL
    /// The folders a pass reads, in order: for each name, the first with a valid manifest wins.
    public let folders: [URL]
    /// The winners of the run's last pass by name, with whether each is held and why.
    @Published public private(set) var hosts: [String: NativeMessagingHost] = [:]
    /// The user's valid manifests in Arch's folder by name, as the run's last pass read them: the files there that are not Arch's links, which both engines read under their names. None is held, and `folder` is Arch's folder.
    @Published public private(set) var userHosts: [String: NativeMessagingHost] = [:]
    /// The listed folders that the run's last pass could not read for a permission error, in their order. A missing folder is not one of them.
    @Published public private(set) var unreadableFolders: [URL] = []
    /// Whether a pass has ended in this run.
    @Published public private(set) var hasLooked = false
    /// Whether Arch's signature meets the parent launch constraints of each helper that a pass asked about in this run, by the helper's path as its manifest names it: nil for constraints that do not read, and no entry for a helper not asked about. Passes ask about the manifests of `HelperLaunchConstraints.constrainedHosts` among the winners, to hold them, and among the user's manifests in Arch's folder, for Settings, at most once per helper and run. Arch's team stays out of it.
    @Published public private(set) var launchConstraintAnswers: [String: Bool?] = [:]
    /// Set by the session: called when the gate comes to refuse more callers, so that every Persona's runtime takes the versions it refuses out of Chromium. A pass calls it before it creates a link or changes a link's destination, once the gate counts the links the pass will make (`gatingHosts`), and changes the links only once it returns; and again after the change, when its reading of the manifests behind Arch's links refuses a caller that the gate did not count, as when a vendor adds an origin to a manifest behind a link that stays or a manifest no longer reads. Removing a link refuses no one more.
    public var gateWidens: (@MainActor () async -> Void)?

    /// Whether Arch's signature meets the parent launch constraints of the helper at a path, or nil when they do not read. Called off the main thread, at most once per helper and run (`launchConstraintAnswers`).
    private let launchConstraintCheck: @Sendable (URL) -> Bool?
    /// The run's last pass, which `update()` waits for instead of starting another.
    private var pass: Task<Void, Never>?
    /// The names under Arch's links with their manifests: as the last pass left them, or as read from Arch's folder before the run's first pass.
    private var linked: [String: NativeMessagingLinkedHost]?
    /// The links a pass is about to make, which the gate counts from before `gateWidens` until they exist.
    private var announced: [String: NativeMessagingLinkedHost] = [:]

    /// Reads a held host's launch constraints with `HelperLaunchConstraints.admitArch(toHelperAt:)`.
    public convenience init(directory: URL, folders: [URL]) {
        self.init(directory: directory, folders: folders) { HelperLaunchConstraints.admitArch(toHelperAt: $0) }
    }

    /// `admitsArch` answers in place of the helpers' launch constraints, for tests.
    init(directory: URL, folders: [URL], admitsArch: @escaping @Sendable (URL) -> Bool?) {
        self.directory = directory
        self.folders = folders
        launchConstraintCheck = admitsArch
    }

    /// The names under Arch's own links, with the manifests behind them, read from Arch's folder and those manifests until the run's first pass ends; a manifest that does not read has no origins. The gate covers only these names: a user's file under a name is what both engines read, so it gates nothing.
    public var linkedHosts: [String: NativeMessagingLinkedHost] {
        if let linked { return linked }
        let read = Self.readLinkedHosts(in: directory, folders: folders)
        linked = read
        return read
    }

    /// What the gate counts: `linkedHosts`, and the links a pass is about to make.
    var gatingHosts: [String: NativeMessagingLinkedHost] {
        linkedHosts.merging(announced) { $1 }
    }

    /// Runs a pass only if none has run in this run, and otherwise waits for the run's last one.
    public func update() async {
        await update(force: false)
    }

    /// With `force`, runs a pass after any that runs now; without, as `update()`.
    public func update(force: Bool) async {
        if !force, let pass { return await pass.value }
        let previous = pass
        let next = Task {
            await previous?.value
            await self.runPass()
        }
        pass = next
        await next.value
    }

    /// Reads the listed folders, holds the hosts whose helpers macOS does not start for Arch, and brings Arch's links in line with the winners: it creates a link for each winner whose name has nothing in Arch's folder, replaces its own link when the winner moved, and removes its own links whose names have no winner or a held one. A link that would be created or change first waits for `gateWidens`, which the pass calls again once the gate reads the manifests behind the links, when they refuse a caller that it did not count. It also reads the user's manifests in Arch's folder, and asks about the launch constraints of a helper that one of them names, for Settings.
    private func runPass() async {
        let (directory, folders) = (self.directory, self.folders)
        let found = await Task.detached { Self.discover(in: folders) }.value
        var hosts: [String: NativeMessagingHost] = [:]
        for (name, manifest) in found.winners {
            var held: NativeMessagingHost.HeldReason?
            if HelperLaunchConstraints.constrainedHosts.contains(name), await admitsArch(manifest.path) == false { held = .launchConstraints }
            hosts[name] = NativeMessagingHost(name: name, description: manifest.description, allowedOrigins: manifest.allowedOrigins, path: manifest.path,
                                              folder: manifest.folder, held: held)
        }
        let (current, userManifests) = await Task.detached {
            let current = Self.readFolder(directory, folders: folders)
            return (current, Self.validManifests(named: current.userNames, in: directory))
        }.value
        var userHosts: [String: NativeMessagingHost] = [:]
        for (name, manifest) in userManifests {
            if HelperLaunchConstraints.constrainedHosts.contains(name) { _ = await admitsArch(manifest.path) }
            userHosts[name] = NativeMessagingHost(name: name, description: manifest.description, allowedOrigins: manifest.allowedOrigins, path: manifest.path,
                                                  folder: directory, held: nil)
        }
        var wanted: [String: String] = [:]
        for (name, host) in hosts where host.held == nil && !current.userNames.contains(name) {
            wanted[name] = host.folder.appendingPathComponent(name + ".json").standardizedFileURL.path
        }
        let removals = current.links.keys.filter { wanted[$0] == nil }
        let changes = wanted.filter { current.links[$0.key] != $0.value }
        if !changes.isEmpty {
            announced = hosts.filter { wanted[$0.key] != nil }.mapValues { NativeMessagingLinkedHost(description: $0.description, allowedOrigins: $0.allowedOrigins) }
            await gateWidens?()
        }
        let linked = await Task.detached {
            Self.change(directory, removing: removals, linking: changes)
            return Self.readLinkedHosts(in: directory, folders: folders)
        }.value
        // What the gate counted until now; before anything read the links, the gate counted nothing that the new reading could widen.
        let counted = (self.linked ?? linked).merging(announced) { $1 }
        self.linked = linked
        announced = [:]
        self.hosts = hosts
        self.userHosts = userHosts
        unreadableFolders = found.unreadable
        hasLooked = true
        if Self.widens(linked, beyond: counted) { await gateWidens?() }
    }

    /// Whether the gate under `new` refuses a caller that it did not under `old`: under a name that `old` lacks, a manifest that allows an origin it did not, or one that no longer reads.
    private static func widens(_ new: [String: NativeMessagingLinkedHost], beyond old: [String: NativeMessagingLinkedHost]) -> Bool {
        new.contains { name, host in
            guard let previous = old[name] else { return true }
            guard let origins = host.allowedOrigins else { return previous.allowedOrigins != nil }
            guard let previousOrigins = previous.allowedOrigins else { return false }
            return !Set(origins).isSubset(of: previousOrigins)
        }
    }

    /// Whether Arch's signature meets the launch constraints of the helper at `path`, asked at most once per run. Only passes ask, one after another.
    private func admitsArch(_ path: String) async -> Bool? {
        if let answer = launchConstraintAnswers[path] { return answer }
        let check = launchConstraintCheck
        let answer = await Task.detached { check(URL(fileURLWithPath: path)) }.value
        launchConstraintAnswers[path] = .some(answer)
        return answer
    }

    // MARK: The gate

    /// The gate's sentence for the caller under the first of Arch's links by name whose manifest allows it, else under the first whose manifest does not read: nil for a caller with proof, and for one that every such manifest reads and refuses.
    func refusal(of caller: NativeMessagingCaller) -> String? {
        guard !caller.isProven else { return nil }
        let origin = NativeMessaging.origin(of: caller.extensionID)
        let hosts = gatingHosts.sorted { $0.key < $1.key }.map(\.value)
        guard let host = hosts.first(where: { $0.allowedOrigins?.contains(origin) == true }) ?? hosts.first(where: { $0.allowedOrigins == nil }) else { return nil }
        return Self.gateSentence(naming: host.description, predatesProof: caller.predatesProof)
    }

    /// Whether the gate covers the name for WebKit, which reads the manifest under it only as it starts the native app: while Arch's folder has one of Arch's links under the name, or a pass is about to make one. `NativeMessaging` asks before that read, so that a link that a pass makes meanwhile counts, and then gates by the manifest it reads.
    func coversLink(named name: String) -> Bool {
        announced[name] != nil || Self.linkDestination(of: name + ".json", in: directory, folderPaths: Set(folders.map(\.standardizedFileURL.path))) != nil
    }

    /// "Arch cannot prove that this extension is the one that 1Password BrowserSupport expects. …", ending with how to give it a proof.
    static func gateSentence(naming description: String, predatesProof: Bool) -> String {
        let lead = "Arch cannot prove that this extension is the one that \(description) expects."
        guard predatesProof else { return lead + " Install it from the Web Store or from its signed .crx file." }
        return lead + " It was installed before Arch checked signatures; install it again from its .crx file or from the Web Store."
    }

    // MARK: Files

    /// A valid manifest in a listed folder.
    private struct FoundManifest: Sendable {
        let description: String
        let allowedOrigins: [String]
        let path: String
        let folder: URL
    }

    /// The winners of the listed folders by name, and the folders that a permission error kept from being read. A folder's `*.json` files count when they are valid manifests for their names without `.json` (`validManifest(named:in:)`).
    private nonisolated static func discover(in folders: [URL]) -> (winners: [String: FoundManifest], unreadable: [URL]) {
        var winners: [String: FoundManifest] = [:]
        var unreadable: [URL] = []
        for folder in folders {
            let files: [String]
            do {
                files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            } catch {
                if isPermissionDenial(error) { unreadable.append(folder) }
                continue
            }
            for file in files.sorted() where file.hasSuffix(".json") {
                let name = String(file.dropLast(".json".count))
                guard winners[name] == nil, let manifest = validManifest(named: name, in: folder) else { continue }
                winners[name] = manifest
            }
        }
        return (winners, unreadable)
    }

    /// The valid manifests `<name>.json` in `folder` for `names`, by name, by the rule of `discover(in:)`.
    private nonisolated static func validManifests(named names: Set<String>, in folder: URL) -> [String: FoundManifest] {
        var manifests: [String: FoundManifest] = [:]
        for name in names {
            manifests[name] = validManifest(named: name, in: folder)
        }
        return manifests
    }

    /// The manifest `<name>.json` in `folder` when it is valid: a regular file of up to 64 KB, followed through links, whose `name` is `name` and follows the naming rule, whose `type` is `stdio`, whose `path` names an executable file by its absolute path, and whose `allowed_origins` read as a list of text.
    private nonisolated static func validManifest(named name: String, in folder: URL) -> FoundManifest? {
        guard NativeMessaging.isValidName(name), let manifest = readManifest(folder.appendingPathComponent(name + ".json")),
              manifest.name == name, manifest.type == "stdio", manifest.path.hasPrefix("/"), isExecutableFile(manifest.path) else { return nil }
        return FoundManifest(description: manifest.description ?? name, allowedOrigins: manifest.allowedOrigins, path: manifest.path, folder: folder)
    }

    /// The manifest in the regular file at `url`, followed through links, when it has at most `manifestLimit` bytes and decodes.
    private nonisolated static func readManifest(_ url: URL) -> NativeMessagingHostManifest? {
        var info = stat()
        // A check before opening, so that a pipe with a manifest's name cannot keep the pass waiting.
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= manifestLimit,
              let data = try? Data(contentsOf: url), data.count <= manifestLimit else { return nil }
        return try? JSONDecoder().decode(NativeMessagingHostManifest.self, from: data)
    }

    /// Whether `path` names a regular file, followed through links, that Arch may run.
    private nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    /// Whether `error`, or an error under it, says that permissions or macOS privacy protection keep the folder from being read.
    private nonisolated static func isPermissionDenial(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Arch's links in its folder by name, with their destinations, and the names of the user's files there. Arch's links are the symbolic links named `<name>.json` whose destination is a file directly in a listed folder; a regular file or another link is the user's.
    private nonisolated static func readFolder(_ directory: URL, folders: [URL]) -> (links: [String: String], userNames: Set<String>) {
        let folderPaths = Set(folders.map(\.standardizedFileURL.path))
        var links: [String: String] = [:]
        var userNames: Set<String> = []
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".json") && !file.hasPrefix(".") {
            let name = String(file.dropLast(".json".count))
            if let destination = linkDestination(of: file, in: directory, folderPaths: folderPaths) {
                links[name] = destination
            } else {
                userNames.insert(name)
            }
        }
        return (links, userNames)
    }

    /// The destination of `file` in Arch's folder while it is one of Arch's links: a symbolic link whose destination is a file directly in one of the folders at `folderPaths`.
    private nonisolated static func linkDestination(of file: String, in directory: URL, folderPaths: Set<String>) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(file).path) else { return nil }
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : directory.appendingPathComponent(destination)
        return folderPaths.contains(target.deletingLastPathComponent().standardizedFileURL.path) ? target.standardizedFileURL.path : nil
    }

    /// The manifests behind Arch's links by name. A manifest that does not read, as while its vendor writes it or after it is gone, gets no origins, so that the gate refuses every caller without proof under it rather than none while an engine may read it a moment later.
    private nonisolated static func readLinkedHosts(in directory: URL, folders: [URL]) -> [String: NativeMessagingLinkedHost] {
        var hosts: [String: NativeMessagingLinkedHost] = [:]
        for (name, destination) in readFolder(directory, folders: folders).links {
            let manifest = readManifest(URL(fileURLWithPath: destination))
            hosts[name] = NativeMessagingLinkedHost(description: manifest?.description ?? name, allowedOrigins: manifest?.allowedOrigins)
        }
        return hosts
    }

    /// Removes Arch's links under `removing` and points the names of `linking` at their destinations, each through a new link that replaces the name at once. Creates Arch's folder when it has a link to make. A change that fails leaves that name as it was.
    private nonisolated static func change(_ directory: URL, removing: [String], linking: [String: String]) {
        let fileManager = FileManager.default
        for name in removing {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name + ".json"))
        }
        guard !linking.isEmpty, (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        for (name, destination) in linking {
            let temporary = directory.appendingPathComponent(".\(name).json.\(UUID().uuidString)")
            guard (try? fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)) != nil else { continue }
            if rename(temporary.path, directory.appendingPathComponent(name + ".json").path) != 0 { try? fileManager.removeItem(at: temporary) }
        }
    }
}

/// The gate as the plugin manager asks it, for staging, the review, and joins.
extension NativeMessagingHostLinks: PluginNativeAppGate {
    public func refusal(of manifest: PluginManifest, proof: PluginProof?, predatesProof: Bool) -> String? {
        refusal(of: NativeMessagingCaller(extensionID: WebExtensionManifest.extensionID(of: manifest.id), isProven: proof != nil, predatesProof: predatesProof))
    }
}
