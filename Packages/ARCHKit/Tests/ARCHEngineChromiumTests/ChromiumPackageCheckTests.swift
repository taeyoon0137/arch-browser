// What the Chromium adapter's check of a package refuses without loading it: what keeps Chromium's loader from running a Manifest V3 package. Loading and running extensions needs the engine and the app.
import Foundation
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumPackageCheckTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchChromiumPackageCheckTests-\(UUID().uuidString)", isDirectory: true)

    /// Writes the files of a package, by package path, over the folder's earlier ones.
    private func package(_ files: [String: String]) throws -> URL {
        try? FileManager.default.removeItem(at: root)
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        return root
    }

    private func refusal(_ files: [String: String]) throws -> String? {
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try ChromiumPackageCheck.check(package(files))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func runsAPackageWhoseFilesAreThere() throws {
        #expect(try refusal([
            "manifest.json": #"{"manifest_version": 3, "name": "S", "version": "1", "background": {"service_worker": "background.js"}, "icons": {"16": "/icon.png"}, "action": {"default_icon": "icon.png"}, "content_scripts": [{"matches": ["https://example.org/*"], "js": ["content.js"], "css": ["page.css"]}], "default_locale": "en"}"#,
            "background.js": "", "content.js": "", "page.css": "", "icon.png": "", "_locales/en/messages.json": "{}",
        ]) == nil)
    }

    @Test func refusesABackgroundThatChromiumRunsForManifestV2Only() throws {
        #expect(try refusal(["manifest.json": #"{"manifest_version": 3, "name": "S", "version": "1", "background": {"scripts": ["background.js"]}}"#, "background.js": ""])
            == "Its background runs as background.scripts or background.page, which Chromium runs for Manifest V2 only; Chromium needs background.service_worker.")
        // A package for both engines names both, and Chromium runs its service worker.
        #expect(try refusal(["manifest.json": #"{"manifest_version": 3, "name": "S", "version": "1", "background": {"scripts": ["b.js"], "service_worker": "b.js"}}"#, "b.js": ""]) == nil)
    }

    @Test func refusesFilesThatThePackageLacks() throws {
        #expect(try refusal(["manifest.json": #"{"manifest_version": 3, "name": "S", "version": "1", "background": {"service_worker": "missing.js"}}"#])
            == "It names missing.js as the background service worker, which is not in the package.")
        #expect(try refusal(["manifest.json": #"{"manifest_version": 3, "name": "S", "version": "1", "content_scripts": [{"matches": ["<all_urls>"], "js": ["../outside.js"]}]}"#])
            == "It names ../outside.js as a content script, which is not in the package.")
        #expect(try refusal(["manifest.json": #"{"manifest_version": 3, "name": "S", "version": "1", "action": {"default_icon": {"16": "icon.png"}}}"#])
            == "It names icon.png as the action\u{2019}s icon, which is not in the package.")
        #expect(try refusal(["manifest.json": #"{"manifest_version": 3, "name": "S", "version": "1", "default_locale": "en"}"#])
            == "It names _locales/en/messages.json as the default locale, which is not in the package.")
    }

    @Test func refusesManifestsThatDoNotRead() throws {
        #expect(try refusal(["manifest.json": "["]) == "Its manifest.json is missing or is not a JSON object.")
        #expect(try refusal(["manifest.json": #"{"manifest_version": 2, "name": "S", "version": "1"}"#]) == "Arch runs Manifest V3 extensions only.")
    }

    @Test func readsTheHostsThatTheManifestAsksFor() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(ChromiumManifest(packageAt: package([
            "manifest.json": #"{"manifest_version": 3, "name": "S", "version": "2", "host_permissions": ["https://a.example/*"], "content_scripts": [{"matches": ["https://b.example/*"], "js": []}]}"#,
        ])))
        #expect(manifest.hostPatterns == ["https://a.example/*", "https://b.example/*"] && manifest.version == "2")
    }
}
