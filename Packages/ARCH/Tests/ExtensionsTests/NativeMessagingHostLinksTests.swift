// Host discovery and the proof gate (`docs/password-managers.md`, Host discovery, Proof gate, and Tests): the links a pass makes, keeps, replaces, and removes in Arch's folder from manifests in temporary folders that stand for other browsers' host folders, the manifests it skips, the folders it cannot read, the user's files it leaves, one pass per run unless forced, held hosts, the launch constraints in `codesign` output written for the tests, and the gate on WebKit, on Chromium, at a Chromium profile's start, in the review, for pairs, and in the order of a pass that links a native app while another Persona runs an unproven version. Shell scripts stand for native apps, recording engines for the engines' runtimes, and no test reads a real browser's folder or runs `codesign`.
import ARCHEngine
@testable import Extensions
import Foundation
@testable import Plugins
import Testing

/// A native app for the tests: a shell script that writes each message back, in a folder of the test's own.
@discardableResult
private func writeApp(in folder: TemporaryFolder) throws -> URL {
    let script = folder.url.appendingPathComponent("Apps/echo.sh")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexec cat\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

/// Writes the host manifest `<name>.json` into `directory` for the app at `app`, accepting the extensions with `extensionIDs`; `fields` replace or add fields.
@discardableResult
private func writeHostManifest(_ name: String, into directory: URL, app: URL, description: String = "Example App", allowing extensionIDs: [String],
                               fields: [String: Any] = [:]) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["name": name, "description": description, "path": app.path, "type": "stdio",
                                   "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" }]
    let file = directory.appendingPathComponent(name + ".json")
    try JSONSerialization.data(withJSONObject: manifest.merging(fields) { $1 }).write(to: file)
    return file
}

/// The gate's sentence for a version without proof that the app with `description` accepts.
private func gateSentence(_ description: String = "Example App") -> String {
    "Arch cannot prove that this extension is the one that \(description) expects. Install it from the Web Store or from its signed .crx file."
}

/// What a closure that the tests hand out records.
@MainActor
private final class Recorded<Value> {
    var values: [Value] = []
}

/// Counts the questions about a helper's launch constraints and answers each with `answer`. The pass asks off the main thread.
private final class LaunchConstraintAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    let answer: Bool?

    init(_ answer: Bool?) {
        self.answer = answer
    }

    var count: Int { lock.withLock { asked } }

    func ask(_ url: URL) -> Bool? {
        lock.withLock { asked += 1 }
        return answer
    }
}

@MainActor
@Suite struct HostDiscoveryTests {
    private let folder = TemporaryFolder()
    private let extensionID = String(repeating: "a", count: 32)

    /// Arch's folder.
    private var arch: URL { folder.url.appendingPathComponent("Arch/NativeMessagingHosts", isDirectory: true) }

    /// A folder that stands for another browser's host folder, which the test creates when it writes into it.
    private func vendor(_ number: Int) -> URL {
        folder.url.appendingPathComponent("Vendor \(number)/NativeMessagingHosts", isDirectory: true)
    }

    private func links(_ folders: [URL], answers: LaunchConstraintAnswers = LaunchConstraintAnswers(nil)) -> NativeMessagingHostLinks {
        NativeMessagingHostLinks(directory: arch, folders: folders) { answers.ask($0) }
    }

    /// Where Arch's folder links `<name>.json` to, or nil without a link.
    private func destination(of name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: arch.appendingPathComponent(name + ".json").path)
    }

    private func path(of name: String, in folder: URL) -> String {
        folder.appendingPathComponent(name + ".json").standardizedFileURL.path
    }

    @Test func linksEachValidManifestWithTheFirstFolderWinningPerName() async throws {
        let app = try writeApp(in: folder)
        try writeHostManifest("org.example.app", into: vendor(1), app: app, description: "First", allowing: [extensionID])
        let second = try writeHostManifest("org.example.app", into: vendor(2), app: app, description: "Second", allowing: [extensionID])
        try writeHostManifest("org.example.other", into: vendor(2), app: app, description: "Other", allowing: [])
        let links = links([vendor(1), vendor(2)])
        #expect(!links.hasLooked)
        await links.update()
        #expect(destination(of: "org.example.app") == path(of: "org.example.app", in: vendor(1)))
        #expect(destination(of: "org.example.other") == path(of: "org.example.other", in: vendor(2)))
        #expect(links.hosts["org.example.app"]?.folder == vendor(1) && links.hosts["org.example.app"]?.description == "First")
        #expect(links.linkedHosts == ["org.example.app": NativeMessagingLinkedHost(description: "First", allowedOrigins: ["chrome-extension://\(extensionID)/"]),
                                      "org.example.other": NativeMessagingLinkedHost(description: "Other", allowedOrigins: [])])
        #expect(links.hasLooked && links.unreadableFolders.isEmpty)
        // The other folders stay as they were.
        #expect(try FileManager.default.contentsOfDirectory(atPath: vendor(2).path).sorted() == ["org.example.app.json", "org.example.other.json"])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: second.path)) == nil)
    }

    @Test func skipsManifestsThatDoNotFitAndFoldersThatAreMissing() async throws {
        let app = try writeApp(in: folder)
        let plain = folder.url.appendingPathComponent("Apps/plain.txt")
        try Data("text".utf8).write(to: plain)
        let source = vendor(1)
        try writeHostManifest("org.example.valid", into: source, app: app, allowing: [extensionID])
        try writeHostManifest("org.example.named", into: source, app: app, allowing: [extensionID], fields: ["name": "org.example.other"])
        try writeHostManifest("Org.Example", into: source, app: app, allowing: [extensionID])
        try writeHostManifest("org.example.socket", into: source, app: app, allowing: [extensionID], fields: ["type": "socket"])
        try writeHostManifest("org.example.relative", into: source, app: app, allowing: [extensionID], fields: ["path": "Apps/echo.sh"])
        try writeHostManifest("org.example.plain", into: source, app: plain, allowing: [extensionID])
        try writeHostManifest("org.example.folder", into: source, app: folder.url, allowing: [extensionID])
        try writeHostManifest("org.example.origins", into: source, app: app, allowing: [], fields: ["allowed_origins": "chrome-extension://\(extensionID)/"])
        try writeHostManifest("org.example.large", into: source, app: app, allowing: [extensionID], fields: ["padding": String(repeating: " ", count: 64 * 1024)])
        let links = links([vendor(2), source])
        await links.update()
        #expect(links.hosts.keys.sorted() == ["org.example.valid"])
        #expect(links.linkedHosts.keys.sorted() == ["org.example.valid"] && links.unreadableFolders.isEmpty)
    }

    @Test(.enabled(if: geteuid() != 0, "Root reads every folder")) func listsAFolderItCannotRead() async throws {
        let locked = vendor(1)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let links = links([locked, vendor(2)])
        await links.update()
        #expect(links.unreadableFolders == [locked] && links.hosts.isEmpty)
    }

    @Test func leavesTheUsersFilesAndForeignLinks() async throws {
        let app = try writeApp(in: folder)
        for name in ["org.example.mine", "org.example.foreign", "org.example.free"] {
            try writeHostManifest(name, into: vendor(1), app: app, allowing: [extensionID])
        }
        try writeHostManifest("org.example.mine", into: arch, app: app, description: "Mine", allowing: [extensionID])
        let elsewhere = try writeHostManifest("org.example.foreign", into: folder.url.appendingPathComponent("Elsewhere"), app: app, allowing: [extensionID])
        try FileManager.default.createSymbolicLink(atPath: arch.appendingPathComponent("org.example.foreign.json").path, withDestinationPath: elsewhere.path)
        let links = links([vendor(1)])
        await links.update()
        #expect(destination(of: "org.example.mine") == nil)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: arch.appendingPathComponent("org.example.mine.json"))) as? [String: Any] != nil)
        #expect(destination(of: "org.example.foreign") == elsewhere.path)
        #expect(destination(of: "org.example.free") == path(of: "org.example.free", in: vendor(1)))
        // Only Arch's own links gate.
        #expect(links.linkedHosts.keys.sorted() == ["org.example.free"])
    }

    @Test func replacesAndRemovesItsOwnLinksAsTheFoldersChange() async throws {
        let app = try writeApp(in: folder)
        let first = try writeHostManifest("org.example.app", into: vendor(1), app: app, allowing: [extensionID])
        try writeHostManifest("org.example.app", into: vendor(2), app: app, allowing: [extensionID])
        let gone = try writeHostManifest("org.example.gone", into: vendor(2), app: app, allowing: [extensionID])
        let links = links([vendor(1), vendor(2)])
        await links.update()
        #expect(destination(of: "org.example.app") == path(of: "org.example.app", in: vendor(1)) && destination(of: "org.example.gone") != nil)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: gone)
        await links.update(force: true)
        #expect(destination(of: "org.example.app") == path(of: "org.example.app", in: vendor(2)) && destination(of: "org.example.gone") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: arch.path) == ["org.example.app.json"])
        #expect(links.linkedHosts.keys.sorted() == ["org.example.app"])
    }

    @Test func runsOnePassPerRunUnlessForced() async throws {
        let app = try writeApp(in: folder)
        let links = links([vendor(1)])
        await links.update()
        #expect(links.hasLooked && links.hosts.isEmpty)
        try writeHostManifest("org.example.app", into: vendor(1), app: app, allowing: [extensionID])
        await links.update()
        #expect(links.hosts.isEmpty && destination(of: "org.example.app") == nil)
        await links.update(force: true)
        #expect(links.hosts.keys.sorted() == ["org.example.app"] && destination(of: "org.example.app") != nil)
    }

    @Test func readsArchsLinksBeforeTheRunsFirstPass() throws {
        let app = try writeApp(in: folder)
        let manifest = try writeHostManifest("org.example.app", into: vendor(1), app: app, description: "Linked", allowing: [extensionID])
        try FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: arch.appendingPathComponent("org.example.app.json").path, withDestinationPath: manifest.path)
        let links = links([vendor(1)])
        #expect(!links.hasLooked)
        #expect(links.linkedHosts == ["org.example.app": NativeMessagingLinkedHost(description: "Linked", allowedOrigins: ["chrome-extension://\(extensionID)/"])])
    }

    @Test func holdsAHostWhoseHelperDoesNotStartForArch() async throws {
        let app = try writeApp(in: folder)
        let name = try #require(HelperLaunchConstraints.constrainedHosts.first)
        let manifest = try writeHostManifest(name, into: vendor(1), app: app, description: "Helper", allowing: [extensionID])
        try writeHostManifest("org.example.app", into: vendor(1), app: app, allowing: [extensionID])
        // A link that an earlier run made under the held name goes.
        try FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: arch.appendingPathComponent(name + ".json").path, withDestinationPath: manifest.standardizedFileURL.path)
        let refused = LaunchConstraintAnswers(false)
        let links = links([vendor(1)], answers: refused)
        await links.update()
        #expect(links.hosts[name]?.held == .launchConstraints && destination(of: name) == nil)
        #expect(links.linkedHosts.keys.sorted() == ["org.example.app"] && links.hosts["org.example.app"]?.held == nil)
        // The constraints are read once per run, and only for the helper's host.
        await links.update(force: true)
        #expect(refused.count == 1)
        // Constraints that do not read hold nothing, since the helper enforces them itself.
        let unread = self.links([vendor(1)], answers: LaunchConstraintAnswers(nil))
        await unread.update()
        #expect(unread.hosts[name]?.held == nil && destination(of: name) == path(of: name, in: vendor(1)))
    }

    @Test func removesALinkWithoutAskingTheRuntimes() async throws {
        let app = try writeApp(in: folder)
        let manifest = try writeHostManifest("org.example.app", into: vendor(1), app: app, allowing: [extensionID])
        let links = links([vendor(1)])
        let asked = Recorded<Bool>()
        links.willChangeLinks = { [arch] in
            asked.values.append((try? FileManager.default.destinationOfSymbolicLink(atPath: arch.appendingPathComponent("org.example.app.json").path)) != nil)
        }
        await links.update()
        // Asked before the link existed.
        #expect(asked.values == [false] && destination(of: "org.example.app") != nil)
        await links.update(force: true)
        #expect(asked.values == [false])
        try FileManager.default.removeItem(at: manifest)
        await links.update(force: true)
        #expect(asked.values == [false] && destination(of: "org.example.app") == nil)
    }

    @Test func countsTheLinksAPassIsAboutToMake() async throws {
        let app = try writeApp(in: folder)
        try writeHostManifest("org.example.app", into: vendor(1), app: app, allowing: [extensionID])
        let links = links([vendor(1)])
        let caller = NativeMessagingCaller(extensionID: extensionID, isProven: false)
        let refusals = Recorded<String?>()
        links.willChangeLinks = { [weak links] in refusals.values.append(links?.refusal(of: caller)) }
        #expect(links.refusal(of: caller) == nil)
        await links.update()
        #expect(refusals.values == [gateSentence()] && links.refusal(of: caller) == gateSentence())
        #expect(links.refusal(of: NativeMessagingCaller(extensionID: extensionID, isProven: true)) == nil)
        #expect(links.refusal(of: NativeMessagingCaller(extensionID: String(repeating: "b", count: 32), isProven: false)) == nil)
    }
}

@Suite struct HelperLaunchConstraintsTests {
    private static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// `codesign -d -vvvv` output of a helper with self and parent launch constraints, written for the test with made-up identifiers and teams.
    private static func output(parentMembers: [String]) -> String {
        let members = parentMembers.map { member in member.split(separator: "\n").map { "\t\t\t\t\t" + $0 }.joined(separator: "\n") }.joined(separator: "\n")
        return """
        Executable=/System/Example/Helper.app/Contents/MacOS/Helper
        Identifier=org.example.helper
        Launch Constraints:
        \tHas Self Launch Constraints
        \tHas Parent Launch Constraints
        CDHash=0000
        TeamIdentifier=not set
        \t[Dict]
        \t\t[Key] reqs
        \t\t[Value]
        \t\t\t[Dict]
        \t\t\t\t[Key] on-system-volume
        \t\t\t\t[Value]
        \t\t\t\t\t[Bool] true
        \t[Dict]
        \t\t[Key] ccat
        \t\t[Value]
        \t\t\t[Int] 0
        \t\t[Key] reqs
        \t\t[Value]
        \t\t\t[Dict]
        \t\t\t\t[Key] $or-array
        \t\t\t\t[Value]
        \t\t\t\t\t[Array]
        \(members)
        \t\t[Key] vers
        \t\t[Value]
        \t\t\t[Int] 1

        """
    }

    /// A member that needs the entitlement set to true.
    private static let entitlementMember = """
    \t[Array]
    \t\t[String] $and
    \t\t[Dict]
    \t\t\t[Key] entitlements
    \t\t\t[Value]
    \t\t\t\t[Dict]
    \t\t\t\t\t[Key] $query
    \t\t\t\t\t[Value]
    \t\t\t\t\t\t[Array]
    \t\t\t\t\t\t\t[Array]
    \t\t\t\t\t\t\t\t[Int] 1
    \t\t\t\t\t\t\t\t[String] \(entitlement)
    \t\t\t\t\t\t\t[Array]
    \t\t\t\t\t\t\t\t[Int] 5
    \t\t\t\t\t\t\t\t[Bool] true
    """

    /// A member that needs one of two signing identifiers with a team.
    private static let listMember = """
    \t[Array]
    \t\t[String] $and
    \t\t[Dict]
    \t\t\t[Key] signing-identifier
    \t\t\t[Value]
    \t\t\t\t[Dict]
    \t\t\t\t\t[Key] $in
    \t\t\t\t\t[Value]
    \t\t\t\t\t\t[Array]
    \t\t\t\t\t\t\t[String] org.example.browser
    \t\t\t\t\t\t\t[String] org.example.browser.beta
    \t\t\t[Key] team-identifier
    \t\t\t[Value]
    \t\t\t\t[String] TEAM000001
    """

    /// A member that needs one signing identifier with a team.
    private static let singleMember = """
    \t[Array]
    \t\t[String] $and
    \t\t[Dict]
    \t\t\t[Key] signing-identifier
    \t\t\t[Value]
    \t\t\t\t[String] org.example.other
    \t\t\t[Key] team-identifier
    \t\t\t[Value]
    \t\t\t\t[String] TEAM000002
    """

    @Test func matchesArchsSignatureAgainstTheParentConstraints() throws {
        let constraints = try #require(HelperLaunchConstraints(codesignOutput: Self.output(parentMembers: [Self.entitlementMember, Self.listMember, Self.singleMember])))
        #expect(constraints.conditions == [.entitlement(Self.entitlement, true), .signature(identifiers: ["org.example.browser", "org.example.browser.beta"], team: "TEAM000001"),
                                           .signature(identifiers: ["org.example.other"], team: "TEAM000002")])
        // A listed identifier with its team, then with another team.
        #expect(constraints.admit(CodeSignature(identifier: "org.example.browser.beta", team: "TEAM000001")) == true)
        #expect(constraints.admit(CodeSignature(identifier: "org.example.browser", team: "TEAM000009")) == false)
        // The entitlement condition, with and without the entitlement.
        #expect(constraints.admit(CodeSignature(identifier: "org.example.arch", team: "TEAM000003", booleanEntitlements: [Self.entitlement: true])) == true)
        #expect(constraints.admit(CodeSignature(identifier: "org.example.arch", team: "TEAM000003", booleanEntitlements: [Self.entitlement: false])) == false)
        // None: an ad hoc signature without a team.
        #expect(constraints.admit(CodeSignature(identifier: "org.example.arch", team: nil)) == false)
    }

    @Test func readsNothingFromOutputThatDoesNotRead() {
        // No launch constraints, no parent constraints, a tree without its value, and trees that the list of kinds does not account for.
        #expect(HelperLaunchConstraints(codesignOutput: "Identifier=org.example.helper\n") == nil)
        let output = Self.output(parentMembers: [Self.singleMember])
        #expect(HelperLaunchConstraints(codesignOutput: output.replacingOccurrences(of: "\tHas Parent Launch Constraints\n", with: "")) == nil)
        #expect(HelperLaunchConstraints(codesignOutput: output.replacingOccurrences(of: "\t\t[Key] reqs\n\t\t[Value]\n\t\t\t[Dict]\n\t\t\t\t[Key] $or-array", with: "\t\t[Key] reqs\n\t\t\t[Dict]\n\t\t\t\t[Key] $or-array")) == nil)
        #expect(HelperLaunchConstraints(codesignOutput: output + "\t[Dict]\n") == nil)
        #expect(HelperLaunchConstraints(codesignOutput: "Launch Constraints:\n\tHas Parent Launch Constraints\nunreadable\n") == nil)
    }

    @Test func cannotRuleOutAMemberItDoesNotRead() throws {
        let unknown = "\t[Array]\n\t\t[String] $and\n\t\t[Dict]\n\t\t\t[Key] validation-category\n\t\t\t[Value]\n\t\t\t\t[Int] 1"
        let constraints = try #require(HelperLaunchConstraints(codesignOutput: Self.output(parentMembers: [unknown, Self.singleMember])))
        #expect(constraints.conditions == [.unknown, .signature(identifiers: ["org.example.other"], team: "TEAM000002")])
        #expect(constraints.admit(CodeSignature(identifier: "org.example.arch", team: "TEAM000003")) == nil)
        #expect(constraints.admit(CodeSignature(identifier: "org.example.other", team: "TEAM000002")) == true)
    }
}

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct ProofGateTests {
    private let folder = TemporaryFolder()
    /// One Persona's runtime and manager with a recording engine for each of its engines.
    private struct Launch {
        let runtime: WebExtensionRuntime
        let manager: PluginManager
        let engines: [EngineKind: RecordingEngine]
        private let host: RecordingHost

        init(runtime: WebExtensionRuntime, manager: PluginManager, engines: [EngineKind: RecordingEngine], host: RecordingHost) {
            self.runtime = runtime
            self.manager = manager
            self.engines = engines
            self.host = host
        }

        var webKit: RecordingEngine { engines[.webKit]! }
        var chromium: RecordingEngine { engines[.chromium]! }
    }

    private var arch: URL { folder.url.appendingPathComponent("NativeMessagingHosts", isDirectory: true) }
    private var vendor: URL { folder.url.appendingPathComponent("Vendor/NativeMessagingHosts", isDirectory: true) }
    private var link: URL { arch.appendingPathComponent("org.example.app.json") }

    /// The links of a run, which every Persona of the run shares.
    private func run() -> NativeMessagingHostLinks {
        NativeMessagingHostLinks(directory: arch, folders: [vendor]) { _ in nil }
    }

    /// A launch of the Persona with recording engines, or the engines given, whose manager asks the run's gate, as the session sets them up.
    private func launch(_ kinds: [EngineKind], persona: UUID = UUID(), links: NativeMessagingHostLinks, engines given: [EngineKind: RecordingEngine] = [:]) -> Launch {
        let host = RecordingHost()
        let engines = Dictionary(uniqueKeysWithValues: kinds.map { ($0, given[$0] ?? RecordingEngine()) })
        host.engines = engines
        let runtime = WebExtensionRuntime(persona: persona, host: host, hostLinks: links)
        let manager = PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets())
        manager.nativeAppGate = links
        return Launch(runtime: runtime, manager: manager, engines: engines, host: host)
    }

    /// Has the run's passes ask every launch's runtime to take what the new links gate out of Chromium, as the session does.
    private func follow(_ launches: [Launch], in links: NativeMessagingHostLinks) {
        let runtimes = launches.map(\.runtime)
        links.willChangeLinks = {
            for runtime in runtimes { await runtime.takeGatedVersionsOutOfChromium() }
        }
    }

    /// A folder package of an extension that asks for native messaging, and its identifier, from its path.
    private func messenger(_ name: String = "Messenger", key: String? = nil) throws -> (package: URL, id: String) {
        let keyField = key.map { #", "key": "\#($0)""# } ?? ""
        let package = try folder.package(name, ["manifest.json": #"{"manifest_version": 3, "name": "\#(name)", "version": "1", "permissions": ["nativeMessaging"]\#(keyField)}"#])
        return (package, try WebExtensionManifest.extensionID(key: key, source: package))
    }

    /// A `.crx` file of an extension named `name` that asks for native messaging, signed by the test's developer key, and the identifier it proves.
    private func signed(_ name: String) throws -> (file: URL, id: String) {
        let package = try folder.package(name, ["manifest.json": #"{"manifest_version": 3, "name": "\#(name)", "version": "1", "permissions": ["nativeMessaging"]}"#])
        let archive = folder.url.appendingPathComponent("\(name).zip")
        try compress(package, to: archive)
        let file = folder.url.appendingPathComponent("\(name).crx")
        try CRXFile.data(archive: Data(contentsOf: archive), signedBy: [CRXFile.developer]).write(to: file)
        return (file, WebExtensionManifest.extensionID(ofBytes: CRXFile.developer.publicKey))
    }

    /// The reply to one message from the extension `id` to the app, through the runtime as the engine asks it.
    private func reply(from id: String, to application: String, in launch: Launch) async throws -> Result<Data, any Error> {
        var result: Result<Data, any Error>?
        launch.runtime.extensions(launch.webKit, extension: id, sendNativeMessage: Data("1".utf8), toApplication: application) { result = $0 }
        _ = await eventually { result != nil }
        return try #require(result)
    }

    private var linkExists: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil }

    @Test func looksForNativeAppsOnlyForExtensionsThatMayReachThem() async throws {
        let links = run()
        let launch = launch([.webKit], links: links)
        let plain = try folder.package("Plain", ["manifest.json": #"{"manifest_version": 3, "name": "Plain", "version": "1"}"#])
        try await launch.manager.installEverything(from: plain)
        #expect(await eventually { launch.webKit.loaded.count == 1 })
        #expect(!links.hasLooked)
        try await launch.manager.installEverything(from: messenger().package)
        #expect(await eventually { links.hasLooked })
        launch.manager.close()
    }

    @Test func refusesAnUnprovenVersionOnWebKitOnlyUnderArchsLinks() async throws {
        let links = run()
        let launch = launch([.webKit], links: links)
        let unproven = try messenger()
        let proven = try signed("Signed")
        try await launch.manager.installEverything(from: unproven.package)
        try await launch.manager.installEverything(from: proven.file)
        let app = try writeApp(in: folder)
        try writeHostManifest("org.example.app", into: vendor, app: app, allowing: [unproven.id, proven.id])
        // The user's own manifest in Arch's folder, which a discovered manifest elsewhere also names, is what both engines read.
        try writeHostManifest("org.example.mine", into: vendor, app: app, allowing: [unproven.id])
        try writeHostManifest("org.example.mine", into: arch, app: app, description: "Mine", allowing: [unproven.id])
        await links.update(force: true)
        #expect(await eventually { launch.webKit.loaded[unproven.id] != nil && launch.webKit.loaded[proven.id] != nil })
        await #expect(throws: NativeMessagingError.unproven(gateSentence())) { try await reply(from: unproven.id, to: "org.example.app", in: launch).get() }
        #expect(String(decoding: try await reply(from: proven.id, to: "org.example.app", in: launch).get(), as: UTF8.self) == "1")
        #expect(String(decoding: try await reply(from: unproven.id, to: "org.example.mine", in: launch).get(), as: UTF8.self) == "1")
        // The version keeps running on WebKit tabs.
        #expect(launch.manager.plugins.allSatisfy { $0.isEnabled && $0.engineFailures.isEmpty })
        launch.manager.close()
    }

    @Test func keepsAnUnprovenVersionOutOfChromiumAsAFailureToStartThere() async throws {
        let links = run()
        let unproven = try messenger()
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [unproven.id])
        let both = launch([.webKit, .chromium], links: links)
        try await both.manager.installEverything(from: unproven.package)
        #expect(await eventually { both.manager.plugins.first?.engineFailures[.chromium] == gateSentence() })
        #expect(await eventually { both.webKit.loaded[unproven.id] != nil })
        #expect(both.chromium.loaded[unproven.id] == nil && both.manager.plugins.first?.isEnabled == true)
        // On Chromium alone, it goes off with the sentence, as one that failed on every engine does.
        let alone = launch([.chromium], links: links)
        try await alone.manager.installEverything(from: unproven.package)
        #expect(await eventually { alone.manager.plugins.first?.isEnabled == false })
        #expect(alone.manager.plugins.first?.failure == gateSentence() && alone.chromium.loaded.isEmpty)
        both.manager.close()
        alone.manager.close()
    }

    @Test func stopsAnUnprovenVersionAsAChromiumProfileStarts() async throws {
        let unproven = try messenger()
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [unproven.id])
        let persona = UUID()
        let earlier = launch([.webKit, .chromium], persona: persona, links: run())
        try await earlier.manager.installEverything(from: unproven.package)
        #expect(await eventually { earlier.manager.plugins.first?.engineFailures[.chromium] != nil && linkExists })
        earlier.manager.close()
        // The next launch: Chromium starts the Persona's profile with the copy it kept, before any pass of loads.
        let kept = RecordingEngine()
        try await kept.load(EngineExtension(id: unproven.id, packageURL: unproven.package, permissions: [], sites: []))
        let next = launch([.webKit, .chromium], persona: persona, links: run(), engines: [.chromium: kept])
        next.runtime.profileDidStart(with: kept, of: .chromium)
        #expect(kept.unloads == [unproven.id] && kept.loaded.isEmpty)
        #expect(await eventually { next.manager.plugins.first?.engineFailures[.chromium] == gateSentence() })
        #expect(kept.loadCounts[unproven.id] == 1)
        next.manager.close()
    }

    @Test func showsTheGatesSentenceInTheReviewsChromiumLine() async throws {
        let links = run()
        let launch = launch([.webKit, .chromium], links: links)
        let unproven = try messenger()
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [unproven.id])
        // Staging looks for native apps first.
        let staged = try await launch.manager.stage(unproven.package)
        #expect(links.hasLooked && linkExists)
        #expect(staged.engineNotes == ["Runs on WebKit and Chromium tabs."])
        #expect(launch.manager.engineNotes(of: staged) == ["Runs on WebKit tabs.", gateSentence()])
        launch.manager.discard(staged)
        let proven = try await launch.manager.stage(signed("Signed").file)
        #expect(launch.manager.engineNotes(of: proven) == ["Runs on WebKit and Chromium tabs."])
        launch.manager.discard(proven)
        launch.manager.close()
    }

    @Test func asksToReinstallAVersionFromACRXFileInstalledBeforeProofs() async throws {
        let links = run()
        let persona = UUID()
        let proven = try signed("Signed")
        let first = launch([.webKit], persona: persona, links: links)
        try await first.manager.installEverything(from: proven.file)
        first.manager.close()
        // The entry names the file with `source`, as builds before proofs wrote it.
        let list = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json")
        var file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: list)) as? [String: Any])
        var entries = try #require(file["installed"] as? [[String: Any]])
        entries[0]["source"] = entries[0].removeValue(forKey: "signedSource")
        file["installed"] = entries
        try JSONSerialization.data(withJSONObject: file).write(to: list)
        let next = launch([.webKit], persona: persona, links: links)
        let plugin = try #require(next.manager.plugins.first)
        #expect(plugin.proof == nil && plugin.predatesProof)
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [proven.id])
        await links.update(force: true)
        #expect(links.refusal(of: NativeMessagingCaller(plugin)) == "Arch cannot prove that this extension is the one that Example App expects. It was installed before Arch checked signatures; install it again from its .crx file or from the Web Store.")
        next.manager.close()
    }

    @Test func keepsAnUnprovenVersionFromJoiningAProvenOneUnderAGatedIdentifier() async throws {
        let links = run()
        let launch = launch([.webKit, .chromium], links: links)
        follow([launch], in: links)
        launch.chromium.refusedNames = ["Packed"]
        launch.webKit.refusedNames = ["Packed for Chromium"]
        let packed = try signed("Packed")
        let proven = try await launch.manager.installEverything(from: packed.file)
        #expect(await eventually { launch.webKit.loaded[packed.id] != nil })
        // A folder whose manifest carries the developer's key claims the proven identifier without proof.
        let claim = try messenger("Packed for Chromium", key: CRXFile.developer.publicKey.base64EncodedString())
        var staged = try await launch.manager.stage(claim.package)
        #expect(staged.counterpart == proven.id && staged.joinableEngines == [.chromium])
        // Each version of a pair is gated on its own: once a linked app accepts the identifier, the unproven Chromium version leaves Chromium and the proven version keeps WebKit.
        let version = try launch.manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true, asVersionOf: proven.id, for: .chromium)
        #expect(await eventually { launch.chromium.loaded[claim.id] != nil })
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [claim.id])
        await links.update(force: true)
        #expect(await eventually { launch.manager.plugins.first { $0.id == version }?.failure == gateSentence() })
        #expect(launch.chromium.loaded[claim.id] == nil && launch.webKit.loaded[claim.id] != nil && launch.manager.plugins.first { $0.id == proven.id }?.isEnabled == true)
        // While the gate covers the identifier, an unproven package cannot join the proven plugin.
        try launch.manager.remove(version)
        staged = try await launch.manager.stage(claim.package)
        #expect(staged.counterpart == proven.id && staged.joinableEngines.isEmpty)
        let refusal = "Arch can prove the identifier of only one of the two, and a native app on this Mac accepts the other's, so they cannot be one plugin."
        #expect(launch.manager.versionRefusal(for: staged, joining: proven.id, for: .chromium) == refusal)
        launch.manager.discard(staged)
        // Join With… refuses the same for an unproven plugin of its own whose identifier a linked app accepts.
        let separate = try messenger("Unproven Packed")
        let unproven = try await launch.manager.installEverything(from: separate.package)
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [claim.id, separate.id])
        await links.update(force: true)
        #expect(throws: PluginError.invalidVersions(refusal)) { try launch.manager.join(PluginEngineVersions([.webKit: proven.id, .chromium: unproven.id])) }
        launch.manager.close()
    }

    @Test func takesAnUnprovenVersionOutOfChromiumBeforeALinkThatAppearsDuringTheRun() async throws {
        let links = run()
        let installer = launch([.webKit, .chromium], links: links)
        let other = launch([.webKit, .chromium], links: links)
        follow([installer, other], in: links)
        let unproven = try messenger()
        try await other.manager.installEverything(from: unproven.package)
        #expect(await eventually { other.chromium.loaded[unproven.id] != nil && other.webKit.loaded[unproven.id] != nil })
        #expect(links.hasLooked && !linkExists)
        // The vendor's manifest appears; then the other Persona installs an extension that asks for native messaging, which looks for native apps again.
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [unproven.id])
        var linkExistedAtUnload: [Bool] = []
        other.chromium.onUnload = { [link] id in
            guard id == unproven.id else { return }
            linkExistedAtUnload.append((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        }
        try await installer.manager.installEverything(from: messenger("Other").package)
        #expect(await eventually { linkExists })
        #expect(linkExistedAtUnload.first == false)
        #expect(await eventually { other.manager.plugins.first?.engineFailures[.chromium] == gateSentence() })
        #expect(other.chromium.loaded[unproven.id] == nil && other.webKit.loaded[unproven.id] != nil)
        installer.manager.close()
        other.manager.close()
    }

    @Test func takesAKeptCopyOutOfChromiumBeforeTheRunsFirstPassLinksIt() async throws {
        let unproven = try messenger()
        let persona = UUID()
        // An earlier launch, which found no native app, installed the extension.
        let earlier = launch([.webKit], persona: persona, links: run())
        try await earlier.manager.installEverything(from: unproven.package)
        earlier.manager.close()
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [unproven.id])
        // In this run, Chromium starts the Persona's profile with the copy it kept, before Arch has looked for native apps.
        let kept = RecordingEngine()
        try await kept.load(EngineExtension(id: unproven.id, packageURL: unproven.package, permissions: [], sites: []))
        var linkExistedAtUnload: [Bool] = []
        kept.onUnload = { [link] _ in linkExistedAtUnload.append((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil) }
        let links = run()
        let next = launch([.webKit, .chromium], persona: persona, links: links, engines: [.chromium: kept])
        follow([next], in: links)
        next.runtime.profileDidStart(with: kept, of: .chromium)
        #expect(kept.unloads.isEmpty)
        #expect(await eventually { next.manager.plugins.first?.engineFailures[.chromium] == gateSentence() })
        #expect(linkExists && linkExistedAtUnload.first == false && kept.loaded.isEmpty)
        #expect(await eventually { next.webKit.loaded[unproven.id] != nil })
        next.manager.close()
    }
}
