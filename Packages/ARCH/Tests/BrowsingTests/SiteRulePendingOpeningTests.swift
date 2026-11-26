import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct SiteRulePendingOpeningTests {
    private let url = URL(string: "https://mail.example.org/inbox")!

    private func withSession(_ body: (BrowserSession, BrowserWindowModel, Tab) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSiteRulePending-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: session.spaces[0].id,
                                                   selectedTabID: nil, isSidebarVisible: true), kind: .main)
        window.nsWindow = nil
        defer { session.windowWillClose(window) }
        let source = session.openTab(in: window.currentSpaceID, select: false)
        window.selectTab(source.id)
        try await body(session, window, source)
    }

    private func rule(_ session: BrowserSession, to space: Space, window: SiteRule.Window = .space) throws {
        try session.siteRules.save(SiteRule(host: "mail.example.org", spaceID: space.id, personaID: space.resolvedPersonaID, window: window))
    }

    private func action(_ disposition: EngineNavigationDisposition = .newBackgroundTab) -> EngineNavigationAction {
        EngineNavigationAction(url: url, disposition: disposition, isUserInitiated: true, opensLinkInNewTab: true)
    }

    @Test func replacingContentsDropsPendingRoutesAndRejectsTheOldPagesCallbacks() async throws {
        try await withSession { session, window, source in
            let origin = window.currentSpace
            let destination = session.makeSpace(in: source.personaID, named: "Mail")
            try rule(session, to: destination)
            let oldPage = source.webContents
            #expect(source.webContents(oldPage, decidePolicyFor: action()) == .openLinkInNewTab)
            #expect(source.pendingSiteRuleOpenings.count == 1)
            source.replaceWebContents(with: PageDouble(url: nil))
            #expect(source.pendingSiteRuleOpenings.isEmpty)
            #expect(source.webContents(oldPage, decidePolicyFor: action()) == .cancel)
            let stalePopup = PageDouble(url: url)
            source.webContents(oldPage, didCreateNewWebContents: stalePopup, targetURL: url, disposition: .newBackgroundTab)
            #expect(!session.tabs.contains { $0.webContents === stalePopup })

            let ordinaryPopup = PageDouble(url: url)
            source.webContents(source.webContents, didCreateNewWebContents: ordinaryPopup, targetURL: url, disposition: .newBackgroundTab)
            let opened = try #require(session.tabs.first { $0.webContents === ordinaryPopup })
            #expect(opened.spaceID == origin.id && opened.personaID == source.personaID)
            #expect(window.siteRuleToast == nil)
        }
    }

    @Test func aDeletedDestinationThatFallsBackToTheOriginShowsNoToastOrNewWindow() async throws {
        try await withSession { session, window, source in
            let origin = window.currentSpace
            let destination = session.makeSpace(in: source.personaID, named: "Mail")
            try rule(session, to: destination, window: .newWindow)
            #expect(source.webContents(source.webContents, decidePolicyFor: action(.newForegroundTab)) == .openLinkInNewTab)
            session.deleteSpace(destination.id)
            let popup = PageDouble(url: url)
            source.webContents(source.webContents, didCreateNewWebContents: popup, targetURL: url, disposition: .newForegroundTab)
            let opened = try #require(session.tabs.first { $0.webContents === popup })
            #expect(opened.spaceID == origin.id && opened.opener === source.webContents)
            #expect(window.selectedTabID == opened.id && window.siteRuleToast == nil && session.windows.count == 1)
        }
    }

    @Test func delayedBackgroundOpeningKeepsItsSourceWindowAndShowsTheActualFallbackPlace() async throws {
        try await withSession { session, window, source in
            let origin = window.currentSpace
            let destination = session.makeSpace(in: source.personaID, named: "Mail")
            let other = session.makeSpace(in: source.personaID, named: "Other")
            try rule(session, to: destination)
            #expect(source.webContents(source.webContents, decidePolicyFor: action()) == .openLinkInNewTab)
            window.switchToSpace(other.id)
            session.deleteSpace(destination.id)
            let popup = PageDouble(url: url)
            source.webContents(source.webContents, didCreateNewWebContents: popup, targetURL: url, disposition: .newBackgroundTab)
            let opened = try #require(session.tabs.first { $0.webContents === popup })
            #expect(opened.spaceID == other.id && opened.isUnread)
            #expect(window.currentSpaceID == other.id && window.selectedTabID != opened.id)
            let toast = try #require(window.siteRuleToast)
            #expect(toast.originWindowID == window.id && toast.originSpaceID == origin.id)
            #expect(toast.message.contains("Other") && !toast.message.contains("Mail"))
            session.undoSiteRuleOpening(toast, from: window)
            #expect(window.currentSpaceID == origin.id && window.selectedTabID == opened.id && opened.spaceID == origin.id)
        }
    }

    @Test func aClosedSourceCannotAdoptALatePopup() async throws {
        try await withSession { session, _, source in
            let destination = session.makeSpace(in: source.personaID, named: "Mail")
            try rule(session, to: destination)
            #expect(source.webContents(source.webContents, decidePolicyFor: action()) == .openLinkInNewTab)
            #expect(session.closeTab(source))
            let popup = PageDouble(url: url)
            source.webContents(source.webContents, didCreateNewWebContents: popup, targetURL: url, disposition: .newBackgroundTab)
            #expect(!session.tabs.contains { $0.webContents === popup })
        }
    }

    @Test func contextMenuRoutingKeepsTheOpenerOnlyWithinItsPersona() async throws {
        try await withSession { session, window, source in
            let destination = session.makeSpace(in: source.personaID, named: "Mail")
            try rule(session, to: destination)
            source.openURLInNewTab?(url)
            let samePersona = try #require(session.tabs.last)
            #expect(samePersona !== source && samePersona.personaID == source.personaID)
            #expect(samePersona.opener === source.webContents && samePersona.isUnread)
            #expect(window.selectedTabID == source.id)

            let work = session.addPersona(named: "Work")
            session.siteRules.rules.forEach { session.siteRules.remove(id: $0.id) }
            try rule(session, to: session.preferredSpace(in: work.id))
            source.openURLInNewTab?(url)
            let otherPersona = try #require(session.tabs.last)
            #expect(otherPersona.personaID == work.id && otherPersona.opener == nil && otherPersona.isUnread)
        }
    }

    @Test func aDeferredCrossPersonaOpeningUsesThatPersonasFallbackAndKeepsTheUndoOrigin() async throws {
        try await withSession { session, window, source in
            let origin = window.currentSpace
            let other = session.makeSpace(in: source.personaID, named: "Other")
            let work = session.addPersona(named: "Work")
            let fallback = session.preferredSpace(in: work.id)
            let destination = session.makeSpace(in: work.id, named: "Mail")
            try rule(session, to: destination)
            #expect(source.webContents(source.webContents, decidePolicyFor: action()) == .cancel)
            window.switchToSpace(other.id)
            session.deleteSpace(destination.id)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            let opened = try #require(session.tabs.first { $0 !== source })
            #expect(opened.personaID == work.id && opened.spaceID == fallback.id && opened.opener == nil)
            #expect(opened.isUnread && window.currentSpaceID == other.id)
            let toast = try #require(window.siteRuleToast)
            #expect(toast.originSpaceID == origin.id && toast.originPersonaID == source.personaID)
            #expect(toast.message.contains("Work / \(fallback.name)"))
            // This checks an available Undo, independent of other suites holding the main actor.
            session.undoSiteRuleOpening(toast, from: window, now: toast.expiresAt.addingTimeInterval(-1))
            let returned = try #require(window.selectedTab)
            #expect(returned.personaID == source.personaID && returned.spaceID == origin.id && returned.url == url)
            #expect(returned !== opened && !session.tabs.contains { $0 === opened })
        }
    }

    @Test func aDeferredOpeningStopsWhenItsDestinationPersonaWasDeleted() async throws {
        try await withSession { session, window, source in
            let work = session.addPersona(named: "Work")
            try rule(session, to: session.preferredSpace(in: work.id))
            #expect(source.webContents(source.webContents, decidePolicyFor: action()) == .cancel)
            session.deletePersona(work.id)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            #expect(session.tabs.count == 1 && session.tabs.first === source)
            #expect(window.siteRuleToast == nil && window.selectedTabID == source.id)
        }
    }
}
