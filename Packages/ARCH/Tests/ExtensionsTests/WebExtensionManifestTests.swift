// Web extension manifests: what Arch reads from `manifest.json` for the plugin list and the install sheet, the identifiers it gives extensions, localized names, a name and action title without spaces at either end, an empty name named by the identifier, the manifests it refuses, and staging and installing web extensions beside script plugins, which may not take the name of the runtime's file.
import Foundation
@testable import Extensions
@testable import Plugins
import Testing

@MainActor
@Suite struct WebExtensionManifestTests {
    private let folder = TemporaryFolder()
    private let manifest = #"{"manifest_version": 3, "name": "A", "version": "1""#

    private func read(_ files: [String: String], named name: String = "package") throws -> PluginManifest {
        let root = try folder.package(name, files)
        return try WebExtensionManifest(packageAt: root, source: root).manifest
    }

    @Test func readsTheSampleExtension() throws {
        let manifest = try WebExtensionManifest(packageAt: sampleExtensionFolder, source: sampleExtensionFolder).manifest
        #expect(manifest.name == "Sample Extension" && manifest.version == "1.0")
        #expect(manifest.summary == "Marks example.org pages and shows the page its popup opens on.")
        #expect(manifest.permissions == [.tabs] && manifest.extensionPermissions == ["storage"])
        #expect(manifest.sites.map(\.description) == ["https://example.org/*"])
        #expect(manifest.contributions.commands.map(\.title) == ["Show Sample Popup"])
        #expect(manifest.extensionPermissionsSummary == "Use the extension APIs storage")
    }

    @Test func namesExtensionsAsChromiumDoes() throws {
        // Chromium's identifier of the bytes of "test", whose SHA-256 digest starts with 9f86d081884c7d65.
        #expect(WebExtensionManifest.extensionID(ofBytes: Data("test".utf8)) == "jpignaibiiemhngfjkcpokkamffknabf")
        #expect(try WebExtensionManifest.extensionID(key: Data("test".utf8).base64EncodedString(), source: folder.url) == "jpignaibiiemhngfjkcpokkamffknabf")
        let fromKey = try read(["manifest.json": manifest + #", "key": "dGVzdA=="}"#])
        #expect(fromKey.id.rawValue == "extension.jpignaibiiemhngfjkcpokkamffknabf")
        #expect(WebExtensionManifest.extensionID(of: fromKey.id) == "jpignaibiiemhngfjkcpokkamffknabf")
    }

    @Test func namesExtensionsWithoutAKeyByWhereTheyCameFrom() throws {
        let first = try read(["manifest.json": manifest + "}"], named: "first")
        let again = try read(["manifest.json": manifest + #", "version": "2"}"#], named: "first")
        let elsewhere = try read(["manifest.json": manifest + "}"], named: "second")
        #expect(first.id == again.id && first.id != elsewhere.id)
        #expect(WebExtensionManifest.extensionID(of: first.id).allSatisfy { ("a"..."p").contains($0) })
    }

    @Test func localizesWhatTheManifestNamesAsMessages() throws {
        let localized = try read([
            "manifest.json": #"{"manifest_version": 3, "name": "__MSG_appName__", "version": "1", "description": "__MSG_about__", "default_locale": "zz", "action": {"default_title": "__MSG_APPNAME__"}}"#,
            "_locales/zz/messages.json": #"{"appName": {"message": "Localized"}, "about": {"message": "Says hello."}}"#,
        ])
        #expect(localized.name == "Localized" && localized.summary == "Says hello.")
        #expect(localized.contributions.commands.map(\.title) == ["Localized"])
    }

    /// A name of nothing but spaces, as a localized name whose message is empty, would show as no name, so the extension goes by its identifier, and an action title of nothing but spaces by the name. Any other name and title lose the spaces at either end.
    @Test func namesAnExtensionWithoutANameByItsIdentifier() throws {
        let spaces = try read(["manifest.json": #"{"manifest_version": 3, "name": "  ", "version": "1", "key": "dGVzdA==", "action": {}}"#], named: "spaces")
        #expect(spaces.name == "jpignaibiiemhngfjkcpokkamffknabf" && spaces.contributions.commands.map(\.title) == ["jpignaibiiemhngfjkcpokkamffknabf"])
        let emptyMessage = try read([
            "manifest.json": #"{"manifest_version": 3, "name": "__MSG_appName__", "version": "1", "default_locale": "zz", "action": {"default_title": " "}}"#,
            "_locales/zz/messages.json": #"{"appName": {"message": ""}}"#,
        ], named: "empty message")
        let identifier = WebExtensionManifest.extensionID(of: emptyMessage.id)
        #expect(emptyMessage.name == identifier && emptyMessage.contributions.commands.map(\.title) == [identifier])
        let padded = try read(["manifest.json": #"{"manifest_version": 3, "name": " Reader ", "version": "1", "action": {"default_title": " Read "}}"#], named: "padded")
        #expect(padded.name == "Reader" && padded.contributions.commands.map(\.title) == ["Read"])
    }

    @Test func readsTheSitesOfWebPagesOnly() throws {
        let manifest = try read(["manifest.json": manifest + #", "host_permissions": ["<all_urls>", "file:///*", "http://localhost:8080/*"], "content_scripts": [{"matches": ["https://example.org/*", "*://*/*"], "js": ["a.js"]}]}"#])
        #expect(manifest.sites.map(\.description) == ["*://*/*", "https://example.org/*"])
    }

    /// Chromium reads an object with one key as a permission with arguments, so such an entry neither hides the list nor goes unread.
    @Test func readsPermissionsAsChromiumDoes() throws {
        let manifest = try read(["manifest.json": manifest + #", "permissions": ["nativeMessaging", "cookies", "tabs", {"fileSystem": ["write"]}], "optional_permissions": [{"usb": []}]}"#])
        #expect(manifest.permissions == [.nativeMessaging, .tabs] && manifest.extensionPermissions == ["cookies", "fileSystem"])
    }

    @Test func refusesManifestsArchCannotInstall() throws {
        let listProblem = { (key: String) in PluginError.invalidPackage("manifest.json: \(key) must be a list of permissions, each a name or an object with one key.") }
        let cases: [(String, [String: String], PluginError)] = [
            ("not JSON", ["manifest.json": "{"], .invalidPackage("manifest.json is not valid JSON.")),
            ("Manifest V2", ["manifest.json": #"{"manifest_version": 2, "name": "A", "version": "1"}"#],
             .invalidPackage("manifest.json: manifest_version must be 3, as Arch runs Manifest V3 extensions only.")),
            ("no name", ["manifest.json": #"{"manifest_version": 3, "version": "1"}"#], .invalidPackage("manifest.json: name is missing.")),
            ("not a key", ["manifest.json": manifest + #", "key": "not base64!"}"#], .invalidPackage("manifest.json: key must be a public key as Base64 text.")),
            ("missing message", ["manifest.json": #"{"manifest_version": 3, "name": "__MSG_gone__", "version": "1", "default_locale": "zz"}"#,
                                 "_locales/zz/messages.json": "{}"],
             .invalidPackage("manifest.json: name names the message “gone”, which _locales/zz/messages.json does not have.")),
            // Chromium refuses these lists too.
            ("number permission", ["manifest.json": manifest + #", "permissions": ["tabs", 1]}"#], listProblem("permissions")),
            ("object of two keys", ["manifest.json": manifest + #", "permissions": [{"a": 1, "b": 2}]}"#], listProblem("permissions")),
            ("permissions not a list", ["manifest.json": manifest + #", "permissions": "tabs"}"#], listProblem("permissions")),
            ("optional number", ["manifest.json": manifest + #", "optional_permissions": ["nativeMessaging", 1]}"#], listProblem("optional_permissions")),
        ]
        for (name, files, expected) in cases {
            #expect(throws: expected, "\(name)") { try read(files, named: name) }
        }
    }

    @Test func stagesAndInstallsWebExtensionsBesideScriptPlugins() async throws {
        let manager = PluginManager.withWebExtensions(WebExtensionRuntime(persona: UUID(), host: RecordingHost(), nativeMessagingHosts: folder.url), in: folder)
        let package = try await manager.stage(sampleExtensionFolder)
        #expect(package.kind == .webExtension)
        #expect(package.files == ["background.js", "content.js", "manifest.json", "popup.html", "popup.js"])
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let installed = try #require(manager.plugins.first)
        #expect(installed.kind == .webExtension)
        #expect(installed.accessSummaries == ["Read the titles and addresses of your tabs", "Run scripts on pages from example.org", "Use the extension APIs storage"])
        let archive = folder.url.appendingPathComponent("Sample.zip")
        let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", sampleExtensionFolder.path, archive.path])
        ditto.waitUntilExit()
        #expect(try await manager.stage(archive).manifest.name == "Sample Extension")
        await #expect(throws: PluginError.invalidPackage("The package has no plugin.json or manifest.json at its top level.")) {
            try await manager.stage(folder.package("empty", ["notes.txt": ""]))
        }
    }

    @Test func refusesTheNameOfTheRuntimesFileAsAnIdentifier() async throws {
        let manager = PluginManager.withWebExtensions(WebExtensionRuntime(persona: UUID(), host: RecordingHost(), nativeMessagingHosts: folder.url), in: folder)
        // The plugin's folder would take the name of `webExtension.json`, which macOS compares without case.
        let script = try folder.package("script", ["plugin.json": #"{"id": "webExtension.json", "name": "S", "version": "1", "apiVersion": 1, "summary": "S."}"#])
        await #expect(throws: PluginError.invalidPackage("Arch keeps a file named webextension.json beside the installed plugins, so no plugin can have it as its identifier.")) {
            try await manager.stage(script)
        }
    }

    @Test func refusesAnUpdateOfAnotherKind() async throws {
        let manager = PluginManager.withWebExtensions(WebExtensionRuntime(persona: UUID(), host: RecordingHost(), nativeMessagingHosts: folder.url), in: folder)
        let installed = try await manager.installEverything(from: sampleExtensionFolder)
        let script = try folder.package("script", ["plugin.json": #"{"id": "\#(installed.id.rawValue)", "name": "S", "version": "1", "apiVersion": 1, "summary": "S."}"#])
        await #expect(throws: PluginError.invalidPackage("An installed plugin of another kind has the identifier \(installed.id.rawValue).")) { try await manager.stage(script) }
    }
}
