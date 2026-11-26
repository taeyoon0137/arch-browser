import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@Suite struct RegularWindowSitesTests {
    private func withSites(_ body: (inout RegularWindowSites, UserDefaults) throws -> Void) throws {
        let suite = "ArchRegularWindowSites-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var sites = RegularWindowSites(defaults: defaults)
        try body(&sites, defaults)
    }

    @Test func normalizesDeduplicatesAndPersistsOnlyHosts() throws {
        try withSites { sites, defaults in
            let added = sites.add(" https://EXAMPLE.org.:8443/path?query#fragment ")
            #expect(added)
            let duplicate = sites.add("*.example.org")
            #expect(!duplicate)
            #expect(sites.hosts == ["example.org"])
            sites.save(in: defaults)
            #expect(RegularWindowSites(defaults: defaults).hosts == ["example.org"])
            sites.remove("example.org")
            sites.save(in: defaults)
            #expect(RegularWindowSites(defaults: defaults).hosts.isEmpty)
        }
    }

    @Test func matchesSubdomainsAtHostBoundariesAndIgnoresPorts() throws {
        try withSites { sites, _ in
            let added = sites.add("example.org")
            #expect(added)
            for address in ["https://example.org", "http://EXAMPLE.org.:8080/a", "https://one.two.example.org/path", "https://user:password@example.org/path"] {
                #expect(sites.contains(URL(string: address)!))
            }
            for address in ["https://notexample.org", "https://example.org.evil.test", "https://example.net", "file://example.org/path", "ftp://example.org/path"] {
                #expect(!sites.contains(URL(string: address)!))
            }
        }
    }

    @Test func localHostsAndIPAddressesMatchExactly() throws {
        try withSites { sites, defaults in
            for text in ["localhost", "127.0.0.1", "https://[::1]:8080/path"] {
                let added = sites.add(text)
                #expect(added)
            }
            sites.save(in: defaults)
            sites = RegularWindowSites(defaults: defaults)
            #expect(sites.hosts == ["localhost", "127.0.0.1", "::1"])
            for address in ["http://localhost:3000", "http://127.0.0.1", "https://[::1]:9000"] {
                #expect(sites.contains(URL(string: address)!))
            }
            for address in ["http://sub.localhost", "https://sub.127.0.0.1", "http://127.0.0.2", "https://[::2]"] {
                #expect(!sites.contains(URL(string: address)!))
            }
        }
    }

    @Test(arguments: ["", " ", "https://", "https://user:secret@example.org", "file:///tmp/page", "ftp://example.org", "exam*ple.org", "example org"])
    func refusesInvalidOrCredentialedEntries(_ text: String) {
        #expect(RegularWindowSites.host(parsing: text) == nil)
    }

    @Test func aSiteRuleDestinationAndTheListBothOverrideSmallWindows() throws {
        try withSites { sites, _ in
            let added = sites.add("example.org")
            #expect(added)
            let listed = URL(string: "https://sub.example.org")!
            let other = URL(string: "https://example.net")!
            #expect(!sites.opensInSmallWindow(listed, prefersSmallWindow: true, hasSiteRuleDestination: false))
            #expect(sites.opensInSmallWindow(other, prefersSmallWindow: true, hasSiteRuleDestination: false))
            #expect(!sites.opensInSmallWindow(other, prefersSmallWindow: true, hasSiteRuleDestination: true))
            #expect(!sites.opensInSmallWindow(other, prefersSmallWindow: false, hasSiteRuleDestination: false))
        }
    }

    @MainActor @Test func regularWindowSelectionPrefersTheSpaceThenItsPersona() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchRegularWindow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let firstSpace = session.spaces[0]
        let otherSpace = session.makeSpace(in: firstSpace.resolvedPersonaID)
        let work = session.addPersona(named: "Work")
        let workSpace = try #require(session.spaces.first { $0.resolvedPersonaID == work.id })
        func window(_ space: Space) -> BrowserWindowModel {
            session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        }
        let first = window(firstSpace)
        let frontmost = window(firstSpace)
        let other = window(otherSpace)
        let workWindow = window(workSpace)
        defer { [first, frontmost, other, workWindow].forEach(session.windowWillClose) }
        #expect(session.regularWindow(in: firstSpace.id) === frontmost)
        #expect(session.regularWindow(in: workSpace.id) === workWindow)
        let emptySpace = session.makeSpace(in: firstSpace.resolvedPersonaID)
        #expect(session.regularWindow(in: emptySpace.id) === other)
        #expect(session.windows.allSatisfy { $0.nsWindow?.isVisible == false })

        // A supplied destination must choose its Persona before creating the page. Keep the target off screen.
        workWindow.nsWindow = nil
        let url = URL(string: "https://destination.example/path")!
        let destination = session.openExternalLink(url, prefersSmallWindow: true, destinationSpaceID: workSpace.id)
        #expect(destination === workWindow && destination.kind == .main)
        let tab = try #require(destination.selectedTab)
        #expect(tab.personaID == work.id && tab.spaceID == workSpace.id && tab.url == url)
        #expect(!tab.isInSmallWindow && session.windows.count == 4)
    }
}
