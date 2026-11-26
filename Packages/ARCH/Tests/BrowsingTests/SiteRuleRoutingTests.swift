import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct SiteRuleRoutingTests {
    private let url = URL(string: "https://mail.example.org/inbox")!

    private func withSession(_ body: (BrowserSession, BrowserWindowModel, SessionTestEngine) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSiteRouting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SessionTestEngine()
        let registry = EngineRegistry()
        registry.register(engine)
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: session.spaces[0].id,
                                                   selectedTabID: nil, isSidebarVisible: true), kind: .main)
        // Routing may request activation; tests never order any native window in.
        window.nsWindow = nil
        defer { session.windowWillClose(window) }
        try await body(session, window, engine)
    }

    private func rule(_ session: BrowserSession, to space: Space, window: SiteRule.Window = .space) throws {
        try session.siteRules.save(SiteRule(host: "mail.example.org", spaceID: space.id, personaID: space.resolvedPersonaID, window: window))
    }

    @Test func externalOpeningStartsInTheDestinationAndUndoRecreatesTheOriginalPersona() async throws {
        try await withSession { session, window, _ in
            let origin = window.currentSpace
            let work = session.addPersona(named: "Work")
            let destination = session.preferredSpace(in: work.id)
            try rule(session, to: destination)
            let opened = session.openExternalTab(url: url)
            #expect(opened.personaID == work.id && opened.spaceID == destination.id && opened.opener == nil)
            #expect(window.selectedTabID == opened.id && window.currentSpaceID == destination.id)
            let toast = try #require(window.siteRuleToast)
            #expect(toast.message.contains("Work /"))
            session.undoSiteRuleOpening(toast, from: window)
            let returned = try #require(window.selectedTab)
            #expect(returned.id != opened.id && returned.webContents !== opened.webContents)
            #expect(returned.spaceID == origin.id && returned.personaID == origin.resolvedPersonaID && returned.url == url)
            #expect(returned.isLoaded && returned.opener == nil && window.siteRuleToast == nil)
            #expect(!session.tabs.contains { $0 === opened })
        }
    }

    @Test func backgroundRouteShowsToastWithoutChangingAnyWindowAndUndoSelectsIt() async throws {
        try await withSession { session, window, _ in
            let origin = window.currentSpace
            let stays = session.openTab(in: origin.id, select: false)
            window.selectTab(stays.id)
            let destination = session.makeSpace(in: origin.resolvedPersonaID, named: "Mail")
            try rule(session, to: destination, window: .newWindow)
            let route = try #require(session.destination(forOpening: origin, url: url))
            let opened = session.openRoutedTab(url: url, destination: route, source: window, background: true)
            #expect(session.windows.count == 1 && window.currentSpaceID == origin.id && window.selectedTabID == stays.id)
            #expect(opened.isUnread && opened.spaceID == destination.id)
            let toast = try #require(window.siteRuleToast)
            session.undoSiteRuleOpening(toast, from: window)
            #expect(window.selectedTabID == opened.id && opened.spaceID == origin.id && !opened.isUnread)
        }
    }

    @Test(arguments: [false, true])
    func smallWindowUndoReturnsToTheSourceAndReleasesItsPage(acrossPersonas: Bool) async throws {
        try await withSession { session, source, _ in
            let origin = source.currentSpace
            let stays = session.openTab(in: origin.id, select: false)
            source.selectTab(stays.id)
            let originalProfile = try #require(session.runtime(for: stays.engineKind, in: origin.resolvedPersonaID))
            let personaID = acrossPersonas ? session.addPersona(named: "Work").id : origin.resolvedPersonaID
            let destination = session.makeSpace(in: personaID, named: "Mail")
            try rule(session, to: destination)
            let route = try #require(session.destination(forOpening: origin, url: url))
            let opened = session.openTab(url: url, in: route.space.id, select: false)
            opened.isInSmallWindow = true
            let page = opened.webContents
            let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: route.space.id,
                                                       selectedTabID: nil, isSidebarVisible: false), kind: .small)
            small.nsWindow = nil
            defer { session.windowWillClose(small) }
            small.selectTab(opened.id)
            session.showSiteRuleToast(for: opened, destination: route, source: source, target: small)
            let toast = try #require(small.siteRuleToast)
            #expect(source.currentSpaceID == origin.id && source.selectedTabID == stays.id)
            #expect(opened.personaID == personaID && opened.spaceID == destination.id)
            #expect(source.siteRuleToast?.id == toast.id && small.shows(opened))

            session.undoSiteRuleOpening(toast, from: small)

            let returned = try #require(source.selectedTab)
            #expect(returned.spaceID == origin.id && returned.personaID == origin.resolvedPersonaID)
            #expect(returned.url == url && returned.isLoaded && !returned.isInSmallWindow && returned.opener == nil)
            #expect(session.runtime(for: returned.engineKind, in: returned.personaID) === originalProfile)
            #expect(source.shows(returned) && !small.shows(returned))
            #expect(source.siteRuleToast == nil && small.siteRuleToast == nil)
            if acrossPersonas {
                #expect(returned.id != opened.id && returned.webContents !== page)
                #expect(!session.tabs.contains { $0 === opened } && small.selectedTab == nil)
            } else {
                #expect(returned === opened && returned.webContents === page)
            }
            // Native closing is disabled in this fixture; the small window has released the page.
        }
    }

    @Test func aNewWindowRuleCarriesItsWindowChoiceWithoutChangingTheSourceDuringMatching() async throws {
        try await withSession { session, source, _ in
            let origin = source.currentSpace
            let selected = session.openTab(in: origin.id, select: false)
            source.selectTab(selected.id)
            let destination = session.makeSpace(in: origin.resolvedPersonaID, named: "Mail")
            try rule(session, to: destination, window: .newWindow)

            let route = try #require(session.destination(forOpening: origin, url: url))

            #expect(route.rule.window == .newWindow && route.space.id == destination.id)
            #expect(route.originSpaceID == origin.id && route.originPersonaID == origin.resolvedPersonaID)
            #expect(session.windows.count == 1 && source.currentSpaceID == origin.id && source.selectedTabID == selected.id)
            #expect(source.siteRuleToast == nil)
        }
    }

    @Test func aRoutedSmallWindowOffersUndoWithoutAnOpenMainWindow() async throws {
        try await withSession { session, source, _ in
            let origin = source.currentSpace
            let work = session.addPersona(named: "Work")
            let destination = session.preferredSpace(in: work.id)
            try rule(session, to: destination)
            let route = try #require(session.destination(forOpening: origin, url: url))
            session.windowWillClose(source)
            let opened = session.openTab(url: url, in: destination.id, select: false)
            opened.isInSmallWindow = true
            let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: destination.id,
                                                       selectedTabID: nil, isSidebarVisible: false), kind: .small)
            small.nsWindow = nil
            defer { session.windowWillClose(small) }
            small.selectTab(opened.id)

            session.showSiteRuleToast(for: opened, destination: route, source: nil, target: small)

            let toast = try #require(small.siteRuleToast)
            #expect(toast.tabID == opened.id && toast.originSpaceID == origin.id)
            #expect(toast.originPersonaID == origin.resolvedPersonaID)
            #expect(toast.message.contains("Work /"))
            // An available main window receives Undo without ordering a native window in.
            let main = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: origin.id,
                                                      selectedTabID: nil, isSidebarVisible: true), kind: .main)
            main.nsWindow = nil
            defer { session.windowWillClose(main) }
            session.undoSiteRuleOpening(toast, from: main)
            #expect(main.selectedTab?.spaceID == origin.id)
            #expect(main.selectedTab?.personaID == origin.resolvedPersonaID)
            #expect(small.siteRuleToast == nil)
        }
    }

    @Test func anOpeningAlreadyInItsDestinationHasNoRouteOrToastEvenWithNewWindow() async throws {
        try await withSession { session, window, _ in
            try rule(session, to: window.currentSpace, window: .newWindow)
            #expect(session.destination(forOpening: window.currentSpace, url: url) == nil)
            let opened = session.openExternalTab(url: url)
            #expect(opened.spaceID == window.currentSpaceID && session.windows.count == 1 && window.siteRuleToast == nil)
        }
    }

    @Test func aDeletedSpaceFallsBackWithinItsPersonaAndDeletingThePersonaRemovesRules() async throws {
        try await withSession { session, window, _ in
            let work = session.addPersona(named: "Work")
            let fallback = session.preferredSpace(in: work.id)
            let missing = SiteRule(host: "mail.example.org", spaceID: UUID(), personaID: work.id)
            try session.siteRules.save(missing)
            #expect(session.siteRuleDestination(missing)?.id == fallback.id)
            #expect(session.openExternalTab(url: url).personaID == work.id)
            session.deletePersona(work.id)
            #expect(session.siteRules.rules.isEmpty && session.siteRuleDestination(missing) == nil)
        }
    }

    @Test func anUnknownPersonaAndAgentDestinationNeverRoute() async throws {
        try await withSession { session, window, _ in
            try session.siteRules.save(SiteRule(host: "mail.example.org", spaceID: UUID(), personaID: UUID()))
            #expect(session.destination(forOpening: window.currentSpace, url: url) == nil)
            let agents = session.addPersona(named: "Agents")
            session.agentOnlyPersonaID = agents.id
            let space = session.preferredSpace(in: agents.id)
            session.siteRules.rules.forEach { session.siteRules.remove(id: $0.id) }
            try rule(session, to: space)
            #expect(session.destination(forOpening: window.currentSpace, url: url) == nil)
            #expect(!session.siteRuleDestinations.contains { $0.id == space.id })
        }
    }

    @Test func aMissingProfileKeepsTheDestinationPersonaAndAddressInAStandIn() async throws {
        try await withSession { session, window, engine in
            let work = session.addPersona(named: "Work")
            engine.unavailableStorageID = work.id
            let space = session.preferredSpace(in: work.id)
            try rule(session, to: space)
            let route = try #require(session.destination(forOpening: window.currentSpace, url: url))
            let opened = session.openRoutedTab(url: url, destination: route, source: window, background: true)
            #expect(opened.personaID == work.id && opened.spaceID == space.id && opened.url == url && !opened.isLoaded)
        }
    }

    @Test func aModifiedClickWithinThePersonaAdoptsTheEnginesPageAndOpener() async throws {
        try await withSession { session, window, _ in
            let source = session.openTab(url: URL(string: "https://example.org"), in: window.currentSpaceID, select: false)
            window.selectTab(source.id)
            let target = session.makeSpace(in: source.personaID, named: "Mail")
            try rule(session, to: target)
            let action = EngineNavigationAction(url: url, disposition: .newBackgroundTab, isUserInitiated: true, opensLinkInNewTab: true)
            #expect(source.webContents(source.webContents, decidePolicyFor: action) == .openLinkInNewTab)
            let popup = PageDouble(url: url)
            source.webContents(source.webContents, didCreateNewWebContents: popup, targetURL: url, disposition: .newBackgroundTab)
            let opened = try #require(session.tabs.first { $0.webContents === popup })
            #expect(opened.spaceID == target.id && opened.opener === source.webContents && opened.isUnread)
            #expect(window.selectedTabID == source.id && window.siteRuleToast != nil)
        }
    }

    @Test func aModifiedClickAcrossPersonasCancelsBeforeTheEngineCreatesAPage() async throws {
        try await withSession { session, window, _ in
            let origin = window.currentSpace
            let source = session.openTab(in: origin.id, select: false)
            window.selectTab(source.id)
            let work = session.addPersona(named: "Work")
            try rule(session, to: session.preferredSpace(in: work.id))
            let action = EngineNavigationAction(url: url, disposition: .newBackgroundTab, isUserInitiated: true, opensLinkInNewTab: true)
            #expect(source.webContents(source.webContents, decidePolicyFor: action) == .cancel)
            #expect(session.tabs.count == 1)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            let opened = try #require(session.tabs.first { $0 !== source })
            #expect(opened.personaID == work.id && opened.opener == nil && opened.url == url && opened.isUnread)
            #expect(window.currentSpaceID == origin.id && window.selectedTabID == source.id && window.siteRuleToast != nil)
        }
    }

    @Test func ordinaryNavigationRedirectsAndPopupsDoNotConsultRules() async throws {
        try await withSession { session, window, _ in
            let source = session.openTab(in: window.currentSpaceID, select: false)
            window.selectTab(source.id)
            let work = session.addPersona(named: "Work")
            try rule(session, to: session.preferredSpace(in: work.id))
            for action in [EngineNavigationAction(url: url, disposition: .currentTab, isUserInitiated: true),
                           EngineNavigationAction(url: url, disposition: .currentTab, isUserInitiated: false, isRedirect: true),
                           EngineNavigationAction(url: url, disposition: .newForegroundTab, isUserInitiated: true),
                           EngineNavigationAction(url: url, disposition: .newPopup, isUserInitiated: false)] {
                #expect(source.webContents(source.webContents, decidePolicyFor: action) == .allow)
            }
            let popup = PageDouble(url: url)
            source.webContents(source.webContents, didCreateNewWebContents: popup, targetURL: url, disposition: .newBackgroundTab)
            #expect(session.tabs.last?.personaID == source.personaID && window.siteRuleToast == nil)
            #expect(source.pendingSiteRuleOpenings.isEmpty)
            // Callers for pins, restores, imports and code retain the explicit, unrouted API.
            #expect(session.openTab(url: url, in: window.currentSpaceID, pinned: true, select: false).personaID == source.personaID)
        }
    }

    @Test func bothPaletteModesRouteButOptionReturnKeepsTheCurrentTab() async throws {
        try await withSession { session, window, _ in
            let origin = window.currentSpace
            let source = session.openTab(in: origin.id, select: false)
            window.selectTab(source.id)
            let work = session.addPersona(named: "Work")
            try rule(session, to: session.preferredSpace(in: work.id))
            #expect(window.siteRuleHint(for: url.absoluteString)?.contains("Work /") == true)
            window.showCommandPalette(.editCurrent)
            window.submitCommandPalette(url.absoluteString, bypassSiteRules: true)
            #expect(session.tabs.count == 1 && window.selectedTabID == source.id && window.siteRuleToast == nil)
            for mode in [CommandPaletteMode.editCurrent, .newTab] {
                window.selectTab(source.id)
                window.showCommandPalette(mode)
                window.submitCommandPalette(url.absoluteString)
                #expect(window.selectedTab?.personaID == work.id && window.selectedTab?.id != source.id)
            }
            #expect(session.tabs.contains { $0 === source })
        }
    }

    @Test func expiredAndClosedTabUndoDoNothing() async throws {
        try await withSession { session, window, _ in
            let origin = window.currentSpace
            let destination = session.makeSpace(in: origin.resolvedPersonaID, named: "Mail")
            try rule(session, to: destination)
            let route = try #require(session.destination(forOpening: origin, url: url))
            let opened = session.openRoutedTab(url: url, destination: route, source: window, background: true)
            let toast = try #require(window.siteRuleToast)
            session.undoSiteRuleOpening(toast, from: window, now: toast.expiresAt)
            #expect(opened.spaceID == destination.id)
            #expect(session.closeTab(opened))
            session.undoSiteRuleOpening(toast, from: window)
            #expect(session.tabs.isEmpty)
        }
    }

    @Test func undoDoesNotChooseAnotherPersonaWhenTheOriginalSpaceIsGone() async throws {
        try await withSession { session, window, _ in
            let origin = window.currentSpace
            let destination = session.makeSpace(in: origin.resolvedPersonaID, named: "Mail")
            try rule(session, to: destination)
            let route = try #require(session.destination(forOpening: origin, url: url))
            let opened = session.openRoutedTab(url: url, destination: route, source: window, background: true)
            let toast = try #require(window.siteRuleToast)
            session.deleteSpace(origin.id)
            session.undoSiteRuleOpening(toast, from: window)
            #expect(opened.spaceID == destination.id && session.tabs.contains { $0 === opened })
            #expect(window.siteRuleToast == nil)
        }
    }

}
