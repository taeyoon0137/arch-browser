// The Web Store client, staging, and updates (`docs/web-store.md`, Tests): store addresses and pasted identifiers, the Chromium version in a CEF version, the endpoint's requests and answers, the package download's checks, the installer's staging with the origin `webStore`, and its update checks and staged updates. `StoreStub` answers every request of the tests' sessions, so no test reaches the network. Store pages are built from hosts the tests choose and from `WebStore.pageHosts`, so this file names no store host.
import ARCHEngine
import CryptoKit
@testable import Extensions
import Foundation
@testable import Plugins
import Testing

@Suite struct WebStoreAddressTests {
    private let id = WebExtensionManifest.extensionID(ofBytes: Data("store extension".utf8))
    /// Hosts that stand in for the store's current and older page hosts.
    private let testHosts = ["store.example", "older.example"]

    /// The test hosts, and the store's own once `WebStore.pageHosts` lists them.
    private var hostLists: [[String]] {
        WebStore.pageHosts.isEmpty ? [testHosts] : [testHosts, WebStore.pageHosts]
    }

    @Test func readsBothFormsOfAStorePage() throws {
        #expect(WebStore.pageHosts.count <= WebStore.pagePaths.count)
        for hosts in hostLists {
            let (current, older) = (hosts[0], hosts[1])
            let pages = [
                "https://\(current)/detail/sample-name/\(id)", "https://\(current)/detail/\(id)", "https://\(current)/detail/sample-name/\(id)?hl=en",
                "https://\(current)/detail/\(id)#reviews", "https://\(current)/detail/sample-name/\(id)/", "https://\(current.uppercased())/DETAIL/sample-name/\(id.uppercased())",
                "https://\(older)/webstore/detail/sample-name/\(id)", "https://\(older)/webstore/detail/\(id)?hl=en&gl=US", "https://\(older)/webstore/detail/sample-name/\(id)#details",
            ]
            for page in pages {
                #expect(WebStore.extensionID(in: try #require(URL(string: page)), pageHosts: hosts) == id, "\(page)")
            }
            // The store's other pages, each host's other form, other hosts and schemes, extra path components, and identifiers that are not one.
            let others = [
                "https://\(current)/category/extensions", "https://\(current)/search/passwords", "https://\(current)/detail/sample-name", "https://\(current)/detail",
                "https://\(current)/webstore/detail/sample-name/\(id)", "https://\(older)/detail/sample-name/\(id)", "https://\(older)/webstore/category/extensions",
                "http://\(current)/detail/sample-name/\(id)", "https://example.org/detail/sample-name/\(id)", "https://sub.\(current)/detail/sample-name/\(id)",
                "https://\(current)/detail/sample-name/\(id)/reviews", "https://\(current)/detail/a/b/\(id)", "https://\(current)/detail/sample-name/\(id.dropLast())",
                "https://\(current)/detail/sample-name/\(id.dropLast())q",
            ]
            for page in others {
                #expect(WebStore.extensionID(in: try #require(URL(string: page)), pageHosts: hosts) == nil, "\(page)")
            }
        }
        // The public reader uses the store's page hosts, which are never the tests' own.
        #expect(WebStore.extensionID(in: try #require(URL(string: "https://\(testHosts[0])/detail/sample-name/\(id)"))) == nil)
        for host in WebStore.pageHosts {
            #expect(WebStore.extensionID(in: try #require(URL(string: "https://\(host)/\(WebStore.pagePaths[WebStore.pageHosts.firstIndex(of: host)!].joined(separator: "/"))/\(id)"))) == id)
        }
    }

    @Test func readsPastedAddressesAndIdentifiers() {
        for hosts in hostLists {
            let current = hosts[0]
            for text in [id, id.uppercased(), "  \(id)\n", "\t\(id.prefix(16).uppercased())\(id.dropFirst(16)) ", "https://\(current)/detail/sample-name/\(id)",
                         " \(current)/detail/sample-name/\(id)?hl=en ", "HTTPS://\(current.uppercased())/detail/\(id.uppercased())", "https://\(hosts[1])/webstore/detail/\(id)"] {
                #expect(WebStore.extensionID(from: text, pageHosts: hosts) == id, "\(text)")
            }
            // 31 or 33 letters, letters past `p`, a letter with a mark, digits, a space inside, other addresses, and nothing.
            for text in [String(id.dropLast()), id + "a", String(id.dropLast()) + "q", String(id.dropLast()) + "a\u{301}", String(id.dropLast()) + "1",
                         "\(id.prefix(16)) \(id.dropFirst(16))", "https://example.org/detail/sample-name/\(id)", "https://\(current)/search/\(id)", "", "   "] {
                #expect(WebStore.extensionID(from: text, pageHosts: hosts) == nil, "\(text)")
            }
        }
        #expect(WebStore.extensionID(from: " \(id.uppercased()) ") == id)
    }

    @Test func readsTheChromiumVersionInACEFVersion() {
        #expect(WebStoreClient.chromiumVersion(inCEFVersion: "156.0.49-arch-8078.3694+gc51d2f8+chromium-156.0.8078.48") == "156.0.8078.48")
        #expect(WebStoreClient.chromiumVersion(inCEFVersion: "140.1.2+g1234567+chromium-140.0.7339.80+extra") == "140.0.7339.80")
        for version in ["156.0.49-arch-8078.3694+gc51d2f8", "+chromium-156.0.8078", "+chromium-156.0.8078.48a", "+chromium-156..8078.48", "+chromium-", ""] {
            #expect(WebStoreClient.chromiumVersion(inCEFVersion: version) == nil, "\(version)")
        }
    }
}

/// The tests that answer through `StoreStub`, which keeps one answer at a time, so they run one after another.
@MainActor
@Suite(.serialized) struct WebStoreTests {
    private let folder = TemporaryFolder()
    private let host = RecordingHost()
    private let persona = UUID()
    private let productVersion = "156.0.8078.48"
    /// The developer key's identifier, which the tests' packages have.
    private let extensionID = WebExtensionManifest.extensionID(ofBytes: CRXFile.developer.publicKey)

    init() {
        host.engines = [.webKit: RecordingEngine(), .chromium: RecordingEngine()]
    }

    private func client(packageSizeLimit: Int = WebStoreClient.maximumPackageSize) -> WebStoreClient {
        WebStoreClient(productVersion: productVersion, session: StoreStub.session(), packageSizeLimit: packageSizeLimit)
    }

    // MARK: Requests and answers

    @Test func asksAboutTwentyFiveIdentifiersARequestWithoutCookiesOrLanguage() async throws {
        let ids = (0..<30).map { WebExtensionManifest.extensionID(ofBytes: Data("extension \($0)".utf8)) }
        let queries: [(id: String, version: String?)] = ids.enumerated().map { ($0.element, $0.offset == 3 ? "1.2.3" : nil) }
        let requests = client().requests(for: queries)
        #expect(requests.count == 2)
        for (index, request) in requests.enumerated() {
            let url = try #require(request.url)
            #expect(url.scheme == "https" && url.host == WebStore.updateEndpoint.host && url.path == WebStore.updateEndpoint.path)
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let fixed = items.filter { $0.name != "x" }.map { "\($0.name)=\($0.value ?? "")" }
            #expect(fixed == ["response=updatecheck", "os=mac", "arch=\(WebStoreClient.architecture)", "prodversion=\(productVersion)", "acceptformat=crx3"])
            let batch = index == 0 ? ids.prefix(25) : ids.suffix(5)
            #expect(items.filter { $0.name == "x" }.map(\.value) == batch.map { "id=\($0)&v=\($0 == ids[3] ? "1.2.3" : "0.0.0.0")&installsource=ondemand&uc" })
            // The `x` values keep their `&` and `=` encoded in the query, as the endpoint reads them.
            #expect(url.query?.contains("x=id%3D\(batch.first!)%26v%3D") == true)
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "")
        }
        // The answers of both requests come back together, for the identifiers asked about.
        StoreStub.answer { request in
            let asked = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "x" }.compactMap { $0.value?.dropFirst(3).prefix(32) } ?? []
            return StoreStub.Reply(body: updateResponse(asked.map { #"<app appid="\#($0)" status="ok"><updatecheck status="noupdate"/></app>"# } + [#"<app appid="\#(String(repeating: "a", count: 32))" status="error-unknownApplication"/>"#]))
        }
        let answers = try await client().releases(of: queries)
        #expect(answers.count == 30 && answers.values.allSatisfy { $0 == .noUpdate })
        let sent = StoreStub.requests
        #expect(sent.count == 2 && sent.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Language") == "" })
        // Through a `URLProtocol`, URLSession neither stores nor sends cookies, also with cookie storage, so the session's configuration is what keeps them out; a check of the cookies themselves would need a listener on the loopback address.
        let configuration = StoreStub.session().configuration
        #expect(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies && configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil && configuration.urlCredentialStorage == nil)
    }

    @Test func mapsTheAnswersStatuses() async throws {
        let ids = (0..<6).map { WebExtensionManifest.extensionID(ofBytes: Data("answer \($0)".utf8)) }
        let digest = Data(SHA256.hash(data: Data("package".utf8)))
        let answers = try WebStoreClient.answers(in: updateResponse([
            #"<app appid="\#(ids[0])" cohort="1::" status="ok"><updatecheck _esbAllowlist="true" codebase="https://packages.example.test/a.crx" fp="1.\#(hex(digest))" hash_sha256="\#(hex(digest).uppercased())" protected="0" size="7" status="ok" version="8.12.44.33"/></app>"#,
            #"<app appid="\#(ids[1])" status="ok"><updatecheck status="noupdate"/></app>"#,
            #"<app appid="\#(ids[2].uppercased())" status="error-unknownApplication"/>"#,
            #"<app appid="\#(ids[3])" status="ok"><updatecheck status="error-osnotsupported"/></app>"#,
            #"<app appid="\#(ids[4])" status="ok"/>"#,
            #"<app appid="\#(ids[5])" status="restricted"/>"#,
        ]))
        #expect(answers[ids[0]] == .release(WebStoreRelease(id: ids[0], version: "8.12.44.33", package: URL(string: "https://packages.example.test/a.crx")!, sha256: digest, size: 7)))
        #expect(answers[ids[1]] == .noUpdate && answers[ids[2]] == .unknown && answers[ids[3]] == .refused("error-osnotsupported"))
        #expect(answers[ids[4]] == .noUpdate && answers[ids[5]] == .refused("restricted") && answers.count == 6)
        // An offer without its address or version, or with a digest that is not one, and anything but the update protocol's XML, does not read.
        for apps in [#"<app appid="\#(ids[0])" status="ok"><updatecheck status="ok" version="1"/></app>"#,
                     #"<app appid="\#(ids[0])" status="ok"><updatecheck codebase="https://packages.example.test/a.crx" status="ok"/></app>"#,
                     #"<app appid="\#(ids[0])" status="ok"><updatecheck codebase="https://packages.example.test/a.crx" hash_sha256="00ff" status="ok" version="1"/></app>"#,
                     #"<app appid="\#(ids[0])" status="ok"><updatecheck codebase="https://packages.example.test/a.crx" hash_sha256="\#(String(repeating: "g", count: 64))" status="ok" version="1"/></app>"#,
                     #"<app status="ok"/>"#, #"<app appid="\#(ids[0])"/>"#, #"<app appid="\#(ids[0])" status="ok"><updatecheck version="1"/></app>"#] {
            #expect(throws: WebStoreError.unreadableAnswer) { try WebStoreClient.answers(in: updateResponse([apps])) }
        }
        for body in ["<html><body>Not found</body></html>", "not XML", ""] {
            #expect(throws: WebStoreError.unreadableAnswer) { try WebStoreClient.answers(in: Data(body.utf8)) }
        }
        // A status other than 200, and a client without a Chromium version, which asks nothing.
        StoreStub.answer { _ in StoreStub.Reply(status: 503) }
        await #expect(throws: WebStoreError.httpStatus(503)) { try await client().releases(of: [(ids[0], nil)]) }
        let unversioned = WebStoreClient(productVersion: "", session: StoreStub.session())
        await #expect(throws: WebStoreError.noEngineVersion) { try await unversioned.releases(of: [(ids[0], nil)]) }
        #expect(StoreStub.requests.count == 1)
    }

    // MARK: Downloads

    @Test func downloadsOnlyAPackageThatMatchesTheAnswer() async throws {
        let body = Data(repeating: 7, count: 3000)
        let digest = Data(SHA256.hash(data: body))
        let file = folder.url.appendingPathComponent("download.crx")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        func release(_ address: String, sha256: Data? = digest, size: Int? = body.count) -> WebStoreRelease {
            WebStoreRelease(id: extensionID, version: "1", package: URL(string: address)!, sha256: sha256, size: size)
        }
        StoreStub.answer { request in
            switch request.url!.path {
            case "/package.crx": return StoreStub.Reply(body: body)
            case "/insecure-redirect.crx": return StoreStub.Reply(redirect: URL(string: "http://packages.example.test/package.crx"))
            case "/secure-redirect.crx": return StoreStub.Reply(redirect: URL(string: "https://mirror.example.test/package.crx"))
            default: return StoreStub.Reply(status: 404)
            }
        }
        // A package that matches, also after a redirect to another HTTPS address, and one without a size or digest in the answer.
        for address in ["https://packages.example.test/package.crx", "https://packages.example.test/secure-redirect.crx"] {
            try await client().download(release(address), to: file)
            #expect(try Data(contentsOf: file) == body)
            try FileManager.default.removeItem(at: file)
        }
        try await client().download(release("https://packages.example.test/package.crx", sha256: nil, size: nil), to: file)
        try FileManager.default.removeItem(at: file)
        let requestCount = StoreStub.requests.count
        // An address without HTTPS, or a size in the answer past the limit, asks nothing.
        await #expect(throws: WebStoreError.insecurePackage) { try await client().download(release("http://packages.example.test/package.crx"), to: file) }
        await #expect(throws: WebStoreError.packageTooLarge) { try await client(packageSizeLimit: 2999).download(release("https://packages.example.test/package.crx"), to: file) }
        #expect(StoreStub.requests.count == requestCount)
        // A body past the limit, a different digest or size, another status, and a redirect to an address without HTTPS leave no file.
        await #expect(throws: WebStoreError.packageTooLarge) {
            try await client(packageSizeLimit: 2999).download(release("https://packages.example.test/package.crx", sha256: nil, size: nil), to: file)
        }
        await #expect(throws: WebStoreError.damagedDownload) {
            try await client().download(release("https://packages.example.test/package.crx", sha256: Data(SHA256.hash(data: Data("other".utf8)))), to: file)
        }
        await #expect(throws: WebStoreError.damagedDownload) { try await client().download(release("https://packages.example.test/package.crx", sha256: nil, size: 3001), to: file) }
        await #expect(throws: WebStoreError.httpStatus(404)) { try await client().download(release("https://packages.example.test/missing.crx"), to: file) }
        await #expect(throws: WebStoreError.insecurePackage) { try await client().download(release("https://packages.example.test/insecure-redirect.crx"), to: file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!StoreStub.requests.contains { $0.url?.scheme == "http" })
    }

    // MARK: Staging

    /// A manager of the test's Persona, which takes the test publisher key for the Web Store's.
    private func launch() -> PluginManager {
        let runtime = WebExtensionRuntime(persona: persona, host: host, nativeMessagingHosts: folder.url)
        return PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: [runtime], secretStore: NoSecrets(), publisherKeyDigest: CRXFile.publisher.digest)
    }

    private var stagingURL: URL { folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/Staging") }

    /// The files in `Staging/` that are downloads rather than staged packages.
    private var downloadsInStaging: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stagingURL.path)) ?? []).filter { $0.hasSuffix(".crx") }
    }

    /// The `.crx` file of an extension with the manifest's fields, signed by the keys.
    private func crx(_ name: String, _ fields: String = #""manifest_version": 3, "name": "Packed", "version": "2""#, signedBy keys: [CRXFile.Key]) throws -> Data {
        let package = try folder.package(name, ["manifest.json": "{\(fields)}"])
        let archive = folder.url.appendingPathComponent("\(name).zip")
        try compress(package, to: archive)
        return CRXFile.data(archive: try Data(contentsOf: archive), signedBy: keys)
    }

    /// Has the stub offer `package` as the current version of `id` at an address of its own, as the endpoint and the package's host answer.
    private func offer(_ package: Data, version: String = "2", for id: String? = nil, digest: Data? = nil) {
        let id = id ?? extensionID
        StoreStub.answer { request in
            guard request.url?.host == WebStore.updateEndpoint.host else { return StoreStub.Reply(body: package) }
            return StoreStub.Reply(body: updateResponse([#"<app appid="\#(id)" status="ok"><updatecheck codebase="https://packages.example.test/\#(id).crx" hash_sha256="\#(hex(digest ?? Data(SHA256.hash(data: package))))" size="\#(package.count)" status="ok" version="\#(version)"/></app>"#]))
        }
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func stagesTheStoresPackageAndInstallsItWithTheStoreAsItsOrigin() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let published = try crx("published", signedBy: [CRXFile.developer, CRXFile.publisher])
        offer(published)
        let package = try await installer.stage(extensionID.uppercased(), in: manager)
        #expect(package.origin == .webStore(extensionID) && package.proof == .webStore && package.manifest.id.rawValue == "extension." + extensionID)
        #expect(downloadsInStaging.isEmpty && StoreStub.requests.map { $0.url?.host } == [WebStore.updateEndpoint.host, "packages.example.test"])
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/plugins.json"))) as? [String: Any])
        let entry = try #require((list["installed"] as? [[String: Any]])?.first)
        #expect(entry["webStore"] as? String == extensionID && entry["proof"] as? String == "webStore" && entry["source"] == nil)
        // With the store's current version installed from the store, nothing downloads.
        offer(published)
        await #expect(throws: WebStoreError.alreadyInstalled(name: "Packed", version: "2")) { try await installer.stage(extensionID, in: manager) }
        #expect(WebStoreError.alreadyInstalled(name: "Packed", version: "2").localizedDescription == "\u{201C}Packed\u{201D} 2 is installed, the Web Store's current version.")
        #expect(StoreStub.requests.count == 1)
        // A newer version stages as an update of the installed plugin.
        offer(try crx("newer", #""manifest_version": 3, "name": "Packed", "version": "3""#, signedBy: [CRXFile.developer, CRXFile.publisher]), version: "3")
        let update = try await installer.stage(extensionID, in: manager)
        #expect(update.updates == package.manifest.id && update.origin == .webStore(extensionID))
        manager.discard(update)
        manager.close()
    }

    /// The plugin that a store page's row in the site settings popover names as installed: the Persona's plugin of the page's extension, from a file as from the store.
    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func findsThePersonasPluginOfAStoreExtensionWhateverItsOrigin() async throws {
        let manager = launch()
        #expect(WebStoreInstaller.installedPlugin(of: extensionID, among: manager.plugins) == nil)
        let file = folder.url.appendingPathComponent("Packed.crx")
        try crx("signed", signedBy: [CRXFile.developer]).write(to: file)
        let package = try await manager.stage(file)
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: false)
        let installed = WebStoreInstaller.installedPlugin(of: extensionID.uppercased(), among: manager.plugins)
        #expect(installed?.id == package.manifest.id && installed?.origin == package.origin && package.origin != .webStore(extensionID))
        // Another identifier, and text that is not one, name no plugin.
        for text in [String(repeating: "a", count: 32), "Packed", "extension.\(extensionID)"] {
            #expect(WebStoreInstaller.installedPlugin(of: text, among: manager.plugins) == nil, "\(text)")
        }
        manager.close()
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func refusesWhatTheStoreDoesNotOffer() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let cases: [(app: String, message: String)] = [
            (#"<app appid="\#(extensionID)" status="error-unknownApplication"/>"#, "The Web Store has no extension with the identifier \u{201C}\(extensionID)\u{201D}."),
            (#"<app appid="\#(extensionID)" status="ok"><updatecheck status="noupdate"/></app>"#, "The Web Store did not offer \u{201C}\(extensionID)\u{201D}: noupdate."),
            (#"<app appid="\#(extensionID)" status="ok"><updatecheck status="error-osnotsupported"/></app>"#, "The Web Store did not offer \u{201C}\(extensionID)\u{201D}: error-osnotsupported."),
            ("", "The Web Store's answer does not read."),
        ]
        for (app, message) in cases {
            StoreStub.answer { _ in StoreStub.Reply(body: updateResponse([app])) }
            do {
                _ = try await installer.stage(extensionID, in: manager)
                Issue.record("Staged although the store answered \(app)")
            } catch {
                #expect(error.localizedDescription == message)
            }
        }
        await #expect(throws: WebStoreError.unknownExtension("not an identifier")) { try await installer.stage("not an identifier", in: manager) }
        #expect(StoreStub.requests.count == 1 && downloadsInStaging.isEmpty && manager.plugins.isEmpty)
        manager.close()
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func refusesPackagesThatAreNotTheStoresOwnForTheIdentifier() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let published = try crx("published", signedBy: [CRXFile.developer, CRXFile.publisher])
        let cases: [(package: Data, id: String?, digest: Data?, message: String)] = try [
            (crx("unpublished", signedBy: [CRXFile.developer]), nil, nil, "The package is not signed by the Web Store."),
            (published, String(repeating: "a", count: 32), nil, "The Web Store sent the package of another extension."),
            (crx("theme", #""manifest_version": 3, "name": "Dusk", "version": "2", "theme": {"colors": {"frame": [0, 0, 0]}}"#, signedBy: [CRXFile.developer, CRXFile.publisher]),
             nil, nil, "\u{201C}Dusk\u{201D} is a theme, which Arch does not use."),
            (published, nil, Data(SHA256.hash(data: Data("other".utf8))), "The download from the Web Store is damaged. Try again."),
        ]
        for (package, id, digest, message) in cases {
            offer(package, for: id, digest: digest)
            do {
                _ = try await installer.stage(id ?? extensionID, in: manager)
                Issue.record("Staged although it should say: \(message)")
            } catch {
                #expect(error.localizedDescription == message)
            }
            #expect(downloadsInStaging.isEmpty)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: stagingURL.path)) ?? []).isEmpty && manager.plugins.isEmpty)
        manager.close()
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func cancellingThrowsCancellationErrorAtEveryStepAndLeavesNothing() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let package = try crx("published", signedBy: [CRXFile.developer, CRXFile.publisher])
        // While the endpoint has not answered, which URLSession ends with its own error for a cancelled request.
        StoreStub.answer { _ in StoreStub.Reply(staysOpen: true) }
        let asking = StagingRun { try await installer.stage(extensionID, in: manager) }
        #expect(await eventually { StoreStub.requests.count == 1 })
        asking.task.cancel()
        await asking.expectCancellation()
        #expect(StoreStub.requests.count == 1 && !FileManager.default.fileExists(atPath: stagingURL.path))
        // During the download, which stops and leaves no file.
        StoreStub.answer { [extensionID] request in
            guard request.url?.host == WebStore.updateEndpoint.host else { return StoreStub.Reply(body: package.prefix(100), staysOpen: true) }
            return StoreStub.Reply(body: updateResponse([#"<app appid="\#(extensionID)" status="ok"><updatecheck codebase="https://packages.example.test/p.crx" size="\#(package.count)" status="ok" version="2"/></app>"#]))
        }
        let downloading = StagingRun { try await installer.stage(extensionID, in: manager) }
        #expect(await eventually { StoreStub.requests.count == 2 && !downloadsInStaging.isEmpty })
        downloading.task.cancel()
        await downloading.expectCancellation()
        #expect(downloadsInStaging.isEmpty && manager.plugins.isEmpty)
        // While the engines check the downloaded package, which staging finishes and the installer then discards.
        let engine = try #require(host.engines[.webKit] as? RecordingEngine)
        offer(package)
        let staging = StagingRun { try await installer.stage(extensionID, in: manager) }
        // The task starts once the test waits, so the engine's first check of the package cancels it.
        engine.onCheck = { staging.task.cancel() }
        await staging.expectCancellation()
        #expect(engine.checkCount > 0 && StoreStub.requests.count == 2)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: stagingURL.path)) ?? []).isEmpty && manager.plugins.isEmpty)
        manager.close()
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func asksAndDownloadsNothingForADeletedPersona() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let package = try crx("published", signedBy: [CRXFile.developer, CRXFile.publisher])
        // Deleting the Persona while the endpoint answers downloads nothing.
        StoreStub.answer { [extensionID] request in
            guard request.url?.host == WebStore.updateEndpoint.host else { return StoreStub.Reply(body: package) }
            DispatchQueue.main.sync { MainActor.assumeIsolated { manager.close() } }
            return StoreStub.Reply(body: updateResponse([#"<app appid="\#(extensionID)" status="ok"><updatecheck codebase="https://packages.example.test/p.crx" status="ok" version="2"/></app>"#]))
        }
        await #expect(throws: PluginError.closed) { try await installer.stage(extensionID, in: manager) }
        #expect(manager.isClosed && StoreStub.requests.count == 1 && !FileManager.default.fileExists(atPath: stagingURL.path))
        // Once the Persona is deleted, nothing is asked.
        offer(package)
        await #expect(throws: PluginError.closed) { try await installer.stage(extensionID, in: manager) }
        #expect(StoreStub.requests.isEmpty && !FileManager.default.fileExists(atPath: stagingURL.path))
    }

    // MARK: Updates

    @Test func comparesVersionsInChromiumsOrder() {
        for (version, installed) in [("1.10", "1.9"), ("2", "1.9.9.9"), ("1.2.3.5", "1.2.3.4"), ("1.0.0.1", "1"), ("8.12.44.33", "8.11.2")] {
            #expect(WebStoreInstaller.version(version, isNewerThan: installed), "\(version) after \(installed)")
            #expect(!WebStoreInstaller.version(installed, isNewerThan: version), "\(installed) before \(version)")
        }
        // Missing numbers count as 0, and text that is not one to four numbers is never newer.
        for (version, installed) in [("1.0", "1"), ("1", "1.0.0.0"), ("1.2", "1.2")] {
            #expect(!WebStoreInstaller.version(version, isNewerThan: installed) && !WebStoreInstaller.version(installed, isNewerThan: version))
        }
        for version in ["1.2.3.4.5", "1..2", "", "1.", "2.a", "-3", " 3", "3 ", "1.+2", "4294967296", "²"] {
            #expect(!WebStoreInstaller.version(version, isNewerThan: "1") && !WebStoreInstaller.version("1", isNewerThan: version), "\(version)")
        }
    }

    /// Installs the store's package of the extension at `version`, as its review does, after which the stub offers it.
    private func installFromStore(_ installer: WebStoreInstaller, in manager: PluginManager, version: String) async throws -> InstalledPlugin {
        offer(try crx("v\(version)", #""manifest_version": 3, "name": "Packed", "version": "\#(version)""#, signedBy: [CRXFile.developer, CRXFile.publisher]), version: version)
        let package = try await installer.stage(extensionID, in: manager)
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: true)
        return try #require(manager.plugins.first { $0.origin == .webStore(extensionID) })
    }

    /// The `x` values of a request to the endpoint.
    private func askedExtensions(in request: URLRequest) -> [String] {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.filter { $0.name == "x" }.compactMap(\.value) ?? []
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func checksTheStoreInstallsOnceAPersonaPerRunAndOnEveryClick() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        // A Persona with file installs alone asks nothing and records no check.
        let unpacked = try await manager.installEverything(from: try folder.package("unpacked", ["manifest.json": #"{"manifest_version": 3, "name": "Unpacked", "version": "1"}"#]))
        StoreStub.answer { _ in StoreStub.Reply(status: 500) }
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: true)
        #expect(StoreStub.requests.isEmpty && installer.updateChecks[persona] == nil && !WebStoreInstaller.hasStoreInstalls(among: manager.plugins))
        let installed = try await installFromStore(installer, in: manager, version: "2")
        #expect(WebStoreInstaller.hasStoreInstalls(among: manager.plugins))
        // One request asks about the store install with its version, and none about the file install.
        offer(Data("package".utf8), version: "3")
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: true)
        #expect(StoreStub.requests.count == 1 && StoreStub.requests.first?.url?.host == WebStore.updateEndpoint.host)
        #expect(StoreStub.requests.first.map(askedExtensions(in:)) == ["id=\(extensionID)&v=2&installsource=ondemand&uc"])
        #expect(installer.update(of: installed, in: manager)?.version == "3" && installer.update(of: unpacked, in: manager) == nil)
        #expect(installer.updates[persona]?.keys.sorted { $0.rawValue < $1.rawValue } == [installed.id])
        guard case .checked? = installer.updateChecks[persona] else {
            Issue.record("The check is not recorded: \(String(describing: installer.updateChecks[persona]))")
            return
        }
        // The automatic check runs once per Persona per run, and Check for Updates every time.
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: true)
        #expect(StoreStub.requests.count == 1)
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: false)
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: false)
        #expect(StoreStub.requests.count == 3)
        manager.close()
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func offersOnlyNewerVersionsAndKeepsThemAfterAFailedCheck() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let installed = try await installFromStore(installer, in: manager, version: "2.1")
        // The same version, an older one, and `noupdate` show nothing.
        for version in ["2.1", "2.1.0", "2.0.9", "1"] {
            offer(Data("package".utf8), version: version)
            try await installer.checkForUpdates(in: manager, onlyOncePerRun: false)
            #expect(installer.update(of: installed, in: manager) == nil, "\(version)")
        }
        StoreStub.answer { [extensionID] _ in StoreStub.Reply(body: updateResponse([#"<app appid="\#(extensionID)" status="ok"><updatecheck status="noupdate"/></app>"#])) }
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: false)
        #expect(installer.update(of: installed, in: manager) == nil)
        // A newer one does, compared as numbers.
        offer(Data("package".utf8), version: "2.10")
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: false)
        #expect(installer.update(of: installed, in: manager)?.version == "2.10")
        // A failed check shows why, and keeps the version found before.
        StoreStub.answer { _ in StoreStub.Reply(status: 503) }
        await #expect(throws: WebStoreError.httpStatus(503)) { try await installer.checkForUpdates(in: manager, onlyOncePerRun: false) }
        #expect(installer.updateChecks[persona] == .failed("The Web Store answered with HTTP status 503."))
        #expect(installer.update(of: installed, in: manager)?.version == "2.10")
        manager.close()
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func reviewUpdateStagesTheVersionFoundAsAnUpdateOfThePlugin() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let installed = try await installFromStore(installer, in: manager, version: "2")
        // Without a newer version found, nothing is asked or downloaded.
        let requestCount = StoreStub.requests.count
        await #expect(throws: WebStoreError.alreadyInstalled(name: "Packed", version: "2")) { try await installer.stageUpdate(of: installed.id, in: manager) }
        #expect(StoreStub.requests.count == requestCount)
        offer(try crx("v3", #""manifest_version": 3, "name": "Packed", "version": "3""#, signedBy: [CRXFile.developer, CRXFile.publisher]), version: "3")
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: true)
        let update = try await installer.stageUpdate(of: installed.id, in: manager)
        #expect(update.updates == installed.id && update.origin == .webStore(extensionID) && update.proof == .webStore && update.manifest.version == "3")
        // It downloads the version that the check found without asking the store again, and leaves no download behind.
        #expect(StoreStub.requests.map { $0.url?.host } == [WebStore.updateEndpoint.host, "packages.example.test"] && downloadsInStaging.isEmpty)
        try manager.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true)
        let updated = try #require(manager.plugins.first { $0.id == installed.id })
        #expect(updated.manifest.version == "3" && manager.plugins.count == 1)
        // Once it is installed, the update shows no more.
        #expect(installer.update(of: updated, in: manager) == nil)
        await #expect(throws: WebStoreError.alreadyInstalled(name: "Packed", version: "3")) { try await installer.stageUpdate(of: installed.id, in: manager) }
        manager.close()
    }

    /// In a pair whose versions share the identifier, the rule of `PluginManager` sends a package that both engines run to the version whose answers it equals; Review Update… sends it to the version it was clicked for.
    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func reviewUpdateStagesAnUpdateOfTheClickedVersionOfAPairThatSharesTheIdentifier() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let webKit = try #require(host.engines[.webKit] as? RecordingEngine)
        webKit.refusedNames = ["Packed for Chromium"]
        // A developer's folder with the store's identifier, which both engines run, then the store's package, which WebKit refuses, as its Chromium version.
        let key = CRXFile.developer.publicKey.base64EncodedString()
        let folderVersion = try await manager.installEverything(from: try folder.package("developer", ["manifest.json": #"{"manifest_version": 3, "name": "Packed", "version": "2", "key": "\#(key)"}"#]))
        offer(try crx("chromium", #""manifest_version": 3, "name": "Packed for Chromium", "version": "2""#, signedBy: [CRXFile.developer, CRXFile.publisher]), version: "2")
        let staged = try await installer.stage(extensionID, in: manager)
        #expect(staged.counterpart == folderVersion.id && staged.joinableEngines == [.chromium])
        let storeVersion = try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true, asVersionOf: folderVersion.id, for: .chromium)
        // The store offers a version that both engines run, whose answers equal the folder version's.
        offer(try crx("v3", #""manifest_version": 3, "name": "Packed", "version": "3""#, signedBy: [CRXFile.developer, CRXFile.publisher]), version: "3")
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: false)
        let found = try #require(manager.plugins.first { $0.id == storeVersion })
        #expect(installer.update(of: found, in: manager)?.version == "3" && installer.update(of: folderVersion, in: manager) == nil)
        let update = try await installer.stageUpdate(of: storeVersion, in: manager)
        #expect(update.updates == storeVersion && update.updateChoices.isEmpty)
        try manager.install(update, grant: PluginGrant(requestedBy: update.manifest), isEnabled: true)
        #expect(manager.plugins.first { $0.id == storeVersion }?.manifest.version == "3")
        let other = try #require(manager.plugins.first { $0.id == folderVersion.id })
        #expect(other.manifest.version == "2" && other.origin == folderVersion.origin)
        manager.close()
    }

    @Test(.enabled(if: systemRunsWebExtensions, "Web extensions run from macOS 15.4"))
    func deletingAPersonaDropsItsResultsAndACancelledCheckRecordsNothing() async throws {
        let manager = launch()
        let installer = WebStoreInstaller(client: client())
        let installed = try await installFromStore(installer, in: manager, version: "2")
        offer(Data("package".utf8), version: "3")
        try await installer.checkForUpdates(in: manager, onlyOncePerRun: true)
        #expect(installer.update(of: installed, in: manager) != nil)
        installer.forget(persona)
        #expect(installer.updates[persona] == nil && installer.updateChecks[persona] == nil && installer.update(of: installed, in: manager) == nil)
        // A cancelled check leaves the Persona as it was, here unchecked.
        StoreStub.answer { _ in StoreStub.Reply(staysOpen: true) }
        let check = Task { try await installer.checkForUpdates(in: manager, onlyOncePerRun: true) }
        #expect(await eventually { StoreStub.requests.count == 1 && installer.updateChecks[persona] == .checking })
        check.cancel()
        guard await eventually({ installer.updateChecks[persona] != .checking }) else {
            Issue.record("The check did not end after its task was cancelled.")
            return
        }
        await #expect(throws: CancellationError.self) { try await check.value }
        #expect(installer.updateChecks[persona] == nil)
        // A Persona deleted while the store answers records nothing.
        StoreStub.answer { [extensionID] _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { manager.close() } }
            return StoreStub.Reply(body: updateResponse([#"<app appid="\#(extensionID)" status="ok"><updatecheck codebase="https://packages.example.test/p.crx" status="ok" version="3"/></app>"#]))
        }
        await #expect(throws: PluginError.closed) { try await installer.checkForUpdates(in: manager, onlyOncePerRun: false) }
        #expect(installer.updates[persona] == nil && installer.updateChecks[persona] == nil && StoreStub.requests.count == 1)
        // Once it is deleted, nothing is asked.
        await #expect(throws: PluginError.closed) { try await installer.checkForUpdates(in: manager, onlyOncePerRun: true) }
        #expect(StoreStub.requests.count == 1)
    }
}

/// A staging task that notes when it ends, so that a test waits for it with a limit and reads its value only then.
@MainActor
final class StagingRun {
    private(set) var task: Task<PluginPackage, any Error>!
    private var hasEnded = false

    init(_ stage: @escaping @MainActor () async throws -> PluginPackage) {
        task = Task {
            defer { self.hasEnded = true }
            return try await stage()
        }
    }

    /// Expects the task to end with `CancellationError` within ten seconds, reading its value only once it has ended, so that a cancellation that never arrives fails the test instead of stopping the run.
    func expectCancellation() async {
        guard await eventually({ hasEnded }) else {
            Issue.record("Staging did not end after its task was cancelled.")
            return
        }
        await #expect(throws: CancellationError.self) { try await self.task.value }
    }
}

/// Answers every request of the sessions it makes in place of the network, with the reply that the running test chose, and records the requests. It keeps one answer at a time, so the tests that use it run one after another.
final class StoreStub: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Answers with a redirect to this address instead.
        var redirect: URL?
        /// Leaves the load open after the body, as a slow download, until the task is cancelled.
        var staysOpen = false
    }

    private static let lock = NSLock()
    private static var reply: (@Sendable (URLRequest) -> Reply)?
    private static var log: [URLRequest] = []

    /// Answers each later request with `reply`, and forgets the requests so far.
    static func answer(_ reply: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock {
            self.reply = reply
            log = []
        }
    }

    /// The requests since the last `answer(_:)`, in order.
    static var requests: [URLRequest] { lock.withLock { log } }

    /// A session as the client makes it, whose requests reach only this stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreStub.self]
        return WebStoreClient.makeSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = Self.lock.withLock {
            Self.log.append(request)
            return Self.reply
        }
        let reply = answer?(request) ?? Reply(status: 599)
        if let redirect = reply.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if !reply.staysOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

/// An update protocol 2.0 answer with the `app` elements, as the endpoint writes it.
func updateResponse(_ apps: [String]) -> Data {
    Data((#"<?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod"><daystart elapsed_days="7256" elapsed_seconds="24168"/>"# + apps.joined() + "</gupdate>").utf8)
}

/// Lowercase hexadecimal digits of the bytes.
func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
