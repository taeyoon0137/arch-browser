// Native app status and guidance (`docs/password-managers.md`, Status and guidance in Settings ▸ Plugins, and Tests): where Arch runs from and how it is signed, from bundles in temporary folders and signing information written for the tests; a plugin's native app lines before the run's first pass, the pass that the section starts for a plugin that is off, the manifests behind Arch's links, the user's files, and other browsers' folders, held hosts, and unreadable folders; the vendors' steps by host name with the launch constraint sentences; and the outcomes that native messaging records per plugin on WebKit, also through the runtime. Shell scripts stand for native apps, and no test reads a real browser's folder or runs `codesign`.
import ARCHEngine
@testable import Extensions
import Foundation
@testable import Plugins
import Security
import Testing

/// Signing information as `SecCodeCopySigningInformation` gives it for a team's signature, with a made-up team.
private let teamSignature: [String: Any] = [kSecCodeInfoIdentifier as String: "xyz.taeyoon.arch", kSecCodeInfoTeamIdentifier as String: "TEAM000001"]
/// Arch in the Applications folder, signed by a team, which meets every condition Arch knows of native apps.
private let installedArch = ArchInstallation(bundleURL: URL(fileURLWithPath: "/Applications/Arch.app"), signingInformation: teamSignature)

@Suite struct ArchInstallationTests {
    private let folder = TemporaryFolder()

    /// Creates a bundle folder at `path` in the test's folder.
    private func bundle(_ path: String) throws -> URL {
        let url = folder.url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        return url
    }

    @Test func tellsWhetherArchRunsInTheApplicationsFolderAndNotThroughALink() throws {
        let applications = folder.url.appendingPathComponent("Applications", isDirectory: true)
        let installed = try bundle("Applications/Arch.app")
        let elsewhere = try bundle("Build/Arch.app")
        let link = applications.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let build = elsewhere.deletingLastPathComponent().resolvingSymlinksInPath().path

        let inApplications = ArchInstallation(bundleURL: installed, signingInformation: teamSignature, applicationsFolder: applications)
        #expect(inApplications.isInApplications && inApplications.folder.path == applications.resolvingSymlinksInPath().path)
        let outside = ArchInstallation(bundleURL: elsewhere, signingInformation: teamSignature, applicationsFolder: applications)
        #expect(!outside.isInApplications && outside.folder.path == build)
        // A link in the Applications folder is not a bundle there, and Arch runs from where it leads.
        let throughLink = ArchInstallation(bundleURL: link, signingInformation: teamSignature, applicationsFolder: applications)
        #expect(!throughLink.isInApplications && throughLink.folder.path == build)
    }

    @Test func tellsATeamsSignatureFromAnAdHocOneAndNone() {
        let bundle = URL(fileURLWithPath: "/Applications/Arch.app")
        #expect(ArchInstallation(bundleURL: bundle, signingInformation: teamSignature).signing == .team)
        let adHoc: [String: Any] = [kSecCodeInfoIdentifier as String: "xyz.taeyoon.arch", kSecCodeInfoFlags as String: 2]
        #expect(ArchInstallation(bundleURL: bundle, signingInformation: adHoc).signing == .adHoc)
        #expect(ArchInstallation(bundleURL: bundle, signingInformation: [:]).signing == .unsigned)
        #expect(ArchInstallation(bundleURL: bundle, signingInformation: nil).signing == .unsigned)
    }
}

/// A web extension plugin of the identifier, installed at a fixed date, whose grant has `permissions`.
private func messenger(_ extensionID: String, permissions: Set<PluginPermission> = [.nativeMessaging], isEnabled: Bool = true) -> InstalledPlugin {
    let manifest = PluginManifest(id: PluginID(rawValue: "extension." + extensionID)!, name: "Messenger", version: "1", summary: "", permissions: permissions,
                                  contributions: PluginContributions())
    return InstalledPlugin(kind: .webExtension, manifest: manifest, grant: PluginGrant(requestedBy: manifest), isEnabled: isEnabled, installedAt: Date(timeIntervalSince1970: 1))
}

/// Writes a native app for the tests named `name`, a shell script with `body`, into the test's folder.
private func writeScript(_ name: String, _ body: String, in folder: TemporaryFolder) throws -> URL {
    let script = folder.url.appendingPathComponent("Apps/\(name).sh")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

@MainActor
@Suite struct NativeAppLinesTests {
    private let folder = TemporaryFolder()
    private let extensionID = String(repeating: "a", count: 32)
    private let other = String(repeating: "b", count: 32)
    private let looking = "Looking for native apps\u{2026}"
    private let noApp = "No native app on this Mac accepts this extension."
    private var helper: String { HelperLaunchConstraints.constrainedHosts.first! }
    private var arch: URL { folder.url.appendingPathComponent("Arch/NativeMessagingHosts", isDirectory: true) }
    private var vendor: URL { folder.url.appendingPathComponent("Vendor/NativeMessagingHosts", isDirectory: true) }

    /// A run's links, whose helpers' launch constraints answer `admitsArch`.
    private func links(_ folders: [URL]? = nil, admitsArch: Bool? = nil) -> NativeMessagingHostLinks {
        NativeMessagingHostLinks(directory: arch, folders: folders ?? [vendor]) { _ in admitsArch }
    }

    private func lines(_ plugin: InstalledPlugin, _ links: NativeMessagingHostLinks, installation: ArchInstallation = installedArch, outcomes: NativeAppOutcomes? = nil) -> [String] {
        NativeAppGuide.lines(for: [plugin], links: links, installation: installation, outcomes: outcomes)
    }

    @Test func looksForNativeAppsAsTheSectionFirstShowsAPluginThatMayReachThem() async throws {
        let links = links()
        // Off, so that no runtime looks for it.
        let off = messenger(extensionID, isEnabled: false)
        #expect(NativeAppGuide.applies(to: [off]) && lines(off, links) == [looking])
        let plain = messenger(other, permissions: [])
        #expect(!NativeAppGuide.applies(to: [plain]) && lines(plain, links).isEmpty)
        await NativeAppGuide.look(for: [plain], in: links)
        #expect(!links.hasLooked)
        await NativeAppGuide.look(for: [off], in: links)
        #expect(links.hasLooked && lines(off, links) == [noApp])
    }

    @Test func listsTheManifestsThatAcceptTheExtensionByWhereTheyAre() async throws {
        let app = try writeApp(in: folder)
        try writeHostManifest("org.example.linked", into: vendor, app: app, description: "Linked App", allowing: [extensionID])
        // The user's file takes the name and does not accept the extension, which another browser's manifest accepts.
        try writeHostManifest("org.example.taken", into: vendor, app: app, description: "Taken App", allowing: [extensionID])
        try writeHostManifest("org.example.taken", into: arch, app: app, description: "Mine", allowing: [other])
        try writeHostManifest("org.example.own", into: arch, app: app, description: "Own App", allowing: [extensionID])
        try writeHostManifest("org.example.other", into: vendor, app: app, description: "Other App", allowing: [other])
        let links = links()
        await links.update()
        #expect(links.userHosts.keys.sorted() == ["org.example.own", "org.example.taken"] && links.userHosts["org.example.own"]?.folder == arch)
        #expect(lines(messenger(extensionID), links) == ["Linked App, set up for Arch.", "Own App, set up for Arch.", "Taken App, set up for another browser."])
        #expect(lines(messenger(other), links) == ["Other App, set up for Arch.", "Mine, set up for Arch."])
    }

    @Test(.enabled(if: geteuid() != 0, "Root reads every folder")) func addsArchsConditionsOnlyWhileANativeAppAcceptsTheExtension() async throws {
        let locked = folder.url.appendingPathComponent("Locked/NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let built = ArchInstallation(bundleURL: folder.url.appendingPathComponent("Build/Arch.app"), signingInformation: [kSecCodeInfoIdentifier as String: "xyz.taeyoon.arch"])
        let links = links([locked, vendor])
        let plugin = messenger(extensionID)
        await links.update()
        #expect(lines(plugin, links, installation: built) == [noApp, "macOS kept Arch from reading another browser\u{2019}s native app setup."])
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [extensionID])
        await links.update(force: true)
        let place = (built.folder.path as NSString).abbreviatingWithTildeInPath
        #expect(lines(plugin, links, installation: built) == ["Example App, set up for Arch.",
                                                              "Arch runs from \(place); some native apps accept only browsers in the Applications folder.",
                                                              "Arch is not signed by a developer team; some native apps accept only signed browsers."])
        #expect(lines(plugin, links) == ["Example App, set up for Arch."])
    }

    @Test func guidesByHostNameWithTheHelpersLaunchConstraints() async throws {
        let app = try writeApp(in: folder)
        try writeHostManifest("com.1password.1password", into: vendor, app: app, description: "1Password BrowserSupport", allowing: [extensionID])
        try writeHostManifest(helper, into: vendor, app: app, description: "Helper", allowing: [extensionID])
        let onePassword = try #require(NativeAppGuide.guidance["com.1password.1password"])
        let iCloud = try #require(NativeAppGuide.guidance[helper])
        let plugin = messenger(extensionID)
        let among = links(admitsArch: true)
        await among.update()
        #expect(lines(plugin, among) == ["1Password BrowserSupport, set up for Arch.", "Helper, set up for Arch.", onePassword, iCloud, "Arch is among them on this Mac."])
        let notAmong = links(admitsArch: false)
        await notAmong.update()
        #expect(lines(plugin, notAmong) == ["1Password BrowserSupport, set up for Arch.", "Helper, which macOS does not start for Arch on this Mac.", onePassword, iCloud,
                                            "Arch is not among them on this Mac."])
        // Constraints that do not read give neither sentence.
        let unread = links(admitsArch: nil)
        await unread.update()
        #expect(lines(plugin, unread) == ["1Password BrowserSupport, set up for Arch.", "Helper, set up for Arch.", onePassword, iCloud])
    }

    @Test func asksAboutTheHelperThatTheUsersManifestNames() async throws {
        let script = try writeApp(in: folder)
        try writeHostManifest(helper, into: arch, app: script, description: "Helper", allowing: [extensionID])
        let links = links(admitsArch: false)
        await links.update()
        let iCloud = try #require(NativeAppGuide.guidance[helper])
        #expect(links.launchConstraintAnswers == [script.path: .some(false)] && links.hosts.isEmpty)
        #expect(lines(messenger(extensionID), links) == ["Helper, set up for Arch.", iCloud, "Arch is not among them on this Mac."])
    }
}

@MainActor
@Suite struct NativeAppOutcomeTests {
    private let folder = TemporaryFolder()
    private let first = messenger(String(repeating: "a", count: 32))
    private let second = messenger(String(repeating: "b", count: 32))
    private var arch: URL { folder.url.appendingPathComponent("NativeMessagingHosts", isDirectory: true) }
    private var vendor: URL { folder.url.appendingPathComponent("Vendor/NativeMessagingHosts", isDirectory: true) }
    private var identifiers: [String] { [first, second].map { WebExtensionManifest.extensionID(of: $0.manifest.id) } }

    /// The reply to one message from the plugin to the app.
    private func reply(from plugin: InstalledPlugin, to application: String, through messaging: NativeMessaging) async throws -> Result<Data, any Error> {
        var result: Result<Data, any Error>?
        messaging.send(Data("1".utf8), to: application, from: NativeMessagingCaller(plugin)) { result = $0 }
        _ = await eventually { result != nil }
        return try #require(result)
    }

    @Test func recordsEachPluginsLastOutcomeForItsInstall() async throws {
        try writeHostManifest("org.example.echo", into: arch, app: writeApp(in: folder), description: "Echo App", allowing: identifiers)
        // The app closes its output and reads until its input closes.
        try writeHostManifest("org.example.quiet", into: arch, app: writeScript("quiet", "exec cat > /dev/null", in: folder), description: "Quiet App", allowing: identifiers)
        let messaging = NativeMessaging(directory: arch)
        let outcomes = messaging.outcomes
        _ = try await reply(from: first, to: "org.example.echo", through: messaging).get()
        #expect(outcomes.outcome(of: first) == .answered("Echo App") && outcomes.outcome(of: first)?.sentence == "On WebKit tabs, Echo App answered.")
        _ = try await reply(from: second, to: "org.example.quiet", through: messaging)
        #expect(outcomes.outcome(of: second)?.sentence == "On WebKit tabs, Quiet App ended without answering, as a native app does when it does not accept the browser.")
        // The plugin's last outcome counts, and only for the install that met it.
        _ = try await reply(from: first, to: "org.example.missing", through: messaging)
        #expect(outcomes.outcome(of: first) == .failed("No native app named org.example.missing is set up for Arch."))
        #expect(outcomes.outcome(of: first)?.sentence == "No native app named org.example.missing is set up for Arch.")
        var updated = second
        updated.installedAt = Date(timeIntervalSince1970: 2)
        #expect(outcomes.outcome(of: updated) == nil && outcomes.outcome(of: second) == .endedWithoutAnswer("Quiet App"))
        // A port: the app's first message is its answer, and an end without one is not.
        let echo = OutcomePort(application: "org.example.echo")
        try messaging.connect(echo, from: NativeMessagingCaller(second))
        echo.onMessage?(Data("1".utf8))
        #expect(await eventually { outcomes.outcome(of: second) == .answered("Echo App") })
        echo.onDisconnect?()
        let quiet = OutcomePort(application: "org.example.quiet")
        try messaging.connect(quiet, from: NativeMessagingCaller(first))
        #expect(await eventually { quiet.isDisconnected })
        #expect(outcomes.outcome(of: first) == .endedWithoutAnswer("Quiet App") && outcomes.outcome(of: second) == .answered("Echo App"))
    }

    @Test func recordsThatArchDidNotStartAHeldHostsApp() async throws {
        let helper = try #require(HelperLaunchConstraints.constrainedHosts.first)
        try writeHostManifest(helper, into: vendor, app: writeApp(in: folder), description: "Helper", allowing: identifiers)
        let links = NativeMessagingHostLinks(directory: arch, folders: [vendor]) { _ in false }
        await links.update()
        let messaging = NativeMessaging(links: links)
        let result = try await reply(from: first, to: helper, through: messaging)
        #expect(throws: NativeMessagingError.held("Helper")) { try result.get() }
        #expect(NativeMessagingError.held("Helper").localizedDescription == "Arch did not start Helper, which macOS does not start for Arch.")
        #expect(messaging.outcomes.outcome(of: first) == .held("Helper"))
        let iCloud = try #require(NativeAppGuide.guidance[helper])
        #expect(NativeAppGuide.lines(for: [first], links: links, installation: installedArch, outcomes: messaging.outcomes)
            == ["Helper, which macOS does not start for Arch on this Mac.", iCloud, "Arch is not among them on this Mac.",
                "On WebKit tabs, Arch did not start Helper, which macOS does not start for Arch."])
    }
}

@MainActor
@Suite(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
struct NativeAppOutcomeRuntimeTests {
    private let folder = TemporaryFolder()

    @Test func keepsTheGatesRefusalAsTheVersionsOutcome() async throws {
        let vendor = folder.url.appendingPathComponent("Vendor/NativeMessagingHosts", isDirectory: true)
        let links = NativeMessagingHostLinks(directory: folder.url.appendingPathComponent("NativeMessagingHosts", isDirectory: true), folders: [vendor]) { _ in nil }
        let host = RecordingHost()
        let engine = RecordingEngine()
        host.engines = [.webKit: engine]
        let persona = UUID()
        let runtime = WebExtensionRuntime(persona: persona, host: host, hostLinks: links)
        let manager = PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets())
        manager.nativeAppGate = links
        defer { manager.close() }
        let package = try folder.package("Messenger", ["manifest.json": #"{"manifest_version": 3, "name": "Messenger", "version": "1", "permissions": ["nativeMessaging"]}"#])
        let id = try WebExtensionManifest.extensionID(key: nil, source: package)
        try writeHostManifest("org.example.app", into: vendor, app: writeApp(in: folder), allowing: [id])
        let installed = try await manager.installEverything(from: package)
        #expect(await eventually { engine.loaded[id] != nil })
        var result: Result<Data, any Error>?
        runtime.extensions(engine, extension: id, sendNativeMessage: Data("1".utf8), toApplication: "org.example.app") { result = $0 }
        #expect(await eventually { result != nil })
        #expect(runtime.nativeAppOutcomes.outcome(of: installed) == .failed(gateSentence()))
        #expect(NativeAppGuide.lines(for: [installed], links: links, installation: installedArch, outcomes: runtime.nativeAppOutcomes)
            == ["Example App, set up for Arch.", gateSentence()])
    }
}

/// A port that records whether the app ended the connection.
private final class OutcomePort: EngineNativeMessagingPort {
    let application: String?
    var onMessage: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var isDisconnected = false

    init(application: String) {
        self.application = application
    }

    func send(_ message: Data) {}

    func disconnect(_ error: (any Error)?) {
        isDisconnected = true
    }
}
