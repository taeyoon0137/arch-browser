// Integration checks use fake pages and never order a native window onto the screen.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct PrivateLinkRoutingTests {
    private let destinationURL = URL(string: "https://destination.example/path")!

    private func fixture(_ body: (BrowserSession, BrowserWindowModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPrivateRouting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let regular = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: session.spaces[0].id,
                                                     selectedTabID: nil, isSidebarVisible: true), kind: .main)
        regular.nsWindow = nil
        defer { for window in session.windows { session.windowWillClose(window) } }
        let savedPeek = UserDefaults.standard.object(forKey: PeekPolicy.automaticPeekKey)
        UserDefaults.standard.set(true, forKey: PeekPolicy.automaticPeekKey)
        defer { UserDefaults.standard.set(savedPeek, forKey: PeekPolicy.automaticPeekKey) }
        try body(session, regular)
    }

    private func rule(_ session: BrowserSession, to space: Space) throws {
        try session.siteRules.save(SiteRule(host: "destination.example", spaceID: space.id, personaID: space.resolvedPersonaID))
    }

    @Test func privateTypedAddressesIgnoreRulesAndExposeNoRuleCommandsOrHints() throws {
        try fixture { session, regular in
            let work = session.addPersona(named: "Work")
            try rule(session, to: session.preferredSpace(in: work.id))
            let window = session.makePrivateWindow()
            window.showCommandPalette(.newTab)
            window.submitCommandPalette(destinationURL.absoluteString)
            let tab = try #require(window.selectedTab)
            #expect(tab.isPrivate && tab.spaceID == nil && tab.url == destinationURL)
            #expect(session.tabs.count == 1 && regular.selectedTab == nil)
            #expect(window.siteRuleHint(for: destinationURL.absoluteString) == nil)
            #expect(session.siteRuleCommands(matching: "always open this site in", forTab: tab).isEmpty)
            #expect(session.windows.allSatisfy { $0.siteRuleToast == nil })
        }
    }

    @Test(arguments: [false, true]) func privateSameTabLinksStayInTheirSessionWithoutPeek(hasMatchingRule: Bool) throws {
        try fixture { session, regular in
            if hasMatchingRule { try rule(session, to: regular.currentSpace) }
            let window = session.makePrivateWindow()
            let tab = try #require(session.openPrivateTab(url: URL(string: "https://source.example/"), in: window))
            let action = EngineNavigationAction(url: destinationURL, disposition: .currentTab,
                                                isUserInitiated: true, isLinkActivation: true)
            #expect(tab.isPrivate && tab.spaceID == nil && window.selectedTab === tab)
            #expect(tab.webContents(tab.webContents, decidePolicyFor: action) == .allow)
            #expect(tab.pendingSiteRuleOpenings.isEmpty)
            #expect(window.privateTabs.count == 1 && session.tabs.count == 1)
            #expect(window.selectedTab === tab && regular.selectedTab == nil)
            #expect(session.windows.allSatisfy { $0.preview == nil && $0.siteRuleToast == nil })
        }
    }

    @Test func privateModifiedAndContextLinksStayPrivateBeforeRulesAndAutomaticPeek() throws {
        try fixture { session, regular in
            try rule(session, to: session.makeSpace(in: regular.personaID, named: "Destination"))
            let window = session.makePrivateWindow()
            let tab = try #require(session.openPrivateTab(url: URL(string: "https://source.example/"), in: window))
            let action = EngineNavigationAction(url: destinationURL, disposition: .newBackgroundTab,
                                                isUserInitiated: true, isLinkActivation: true, opensLinkInNewTab: true)
            #expect(tab.webContents(tab.webContents, decidePolicyFor: action) == .openLinkInNewTab)
            #expect(tab.pendingSiteRuleOpenings.isEmpty)
            let popup = PageDouble(url: destinationURL)
            tab.webContents(tab.webContents, didCreateNewWebContents: popup, targetURL: destinationURL,
                            disposition: .newBackgroundTab, isUserInitiatedLink: true)
            tab.openURLInNewTab?(destinationURL)
            #expect(window.privateTabs.count == 3)
            #expect(session.tabs.allSatisfy { $0.isPrivate && $0.spaceID == nil && !$0.isInSmallWindow })
            #expect(window.preview == nil && regular.preview == nil && regular.selectedTab == nil)
            #expect(session.windows.allSatisfy { $0.siteRuleToast == nil })
        }
    }

    @Test func privatePagesCannotEnterEitherPeekEntryPointOrItsContextMenu() throws {
        try fixture { session, regular in
            let window = session.makePrivateWindow()
            let tab = try #require(session.openPrivateTab(url: destinationURL, in: window))
            window.showPreview(of: destinationURL, engine: tab.engineKind, in: tab.personaID)
            window.showPreview(tab.webContents, openedURL: destinationURL, in: tab.personaID, requestedEngine: tab.engineKind)
            regular.showPreview(of: destinationURL, engine: tab.engineKind, in: tab.personaID)
            regular.showPreview(tab.webContents, openedURL: destinationURL, in: tab.personaID, requestedEngine: tab.engineKind)
            tab.previewLink?(destinationURL)
            window.openPreviewInTab()
            window.openPreviewInNewWindow()
            #expect(window.preview == nil && regular.preview == nil && session.tabs.count == 1)
            let menu = NSMenu()
            tab.webContents(tab.webContents, willShowContextMenuFor: .init(linkURL: destinationURL), menu: menu)
            #expect(!menu.items.contains { $0.title == "Open in Peek" })
            let shiftLink = EngineNavigationAction(url: destinationURL, disposition: .newWindow, isUserInitiated: true, isLinkActivation: true)
            #expect(tab.webContents(tab.webContents, decidePolicyFor: shiftLink) == .allow)
        }
    }

    @Test func aPrivatePageCannotBecomeASmallWindow() throws {
        try fixture { session, regular in
            let window = session.makePrivateWindow()
            let tab = try #require(session.openPrivateTab(url: destinationURL, in: window))
            let popup = PageDouble(url: destinationURL)
            let opened = session.openSmallWindow(popup, spaceID: regular.currentSpaceID, personaID: tab.personaID, opener: tab.webContents)
            #expect(opened === window && session.windows.count == 2)
            #expect(window.privateTabs.count == 2)
            #expect(session.tabs.allSatisfy { $0.isPrivate && !$0.isInSmallWindow && $0.spaceID == nil })
            #expect(session.sidebarSyncState.pinnedTabs.isEmpty)
        }
    }

    @Test func regularAndRoutedOpeningsNeverTargetAPrivateWindow() throws {
        try fixture { session, regular in
            let destination = session.makeSpace(in: regular.personaID, named: "Destination")
            try rule(session, to: destination)
            let window = session.makePrivateWindow()
            // Even a stale space selection cannot turn a private window into a route target.
            window.currentSpaceID = destination.id
            #expect(session.regularWindow(in: destination.id) === regular)
            let opened = session.openExternalLink(destinationURL, prefersSmallWindow: true)
            #expect(opened === regular && regular.selectedTab?.spaceID == destination.id)
            #expect(window.selectedTab == nil && window.siteRuleToast == nil && window.preview == nil)
            #expect(session.tabs.count == 1 && session.tabs.allSatisfy { !$0.isPrivate && !$0.isInSmallWindow })
            #expect(regular.siteRuleToast != nil)
        }
    }

    @Test func externalLinksResolveRulesAcrossPersonasBeforeSmallWindowPreferences() throws {
        try fixture { session, regular in
            let work = session.addPersona(named: "Work")
            let destination = session.preferredSpace(in: work.id)
            try rule(session, to: destination)
            let opened = session.openExternalLink(destinationURL, prefersSmallWindow: true)
            #expect(opened === regular && opened.selectedTab?.personaID == work.id)
            #expect(opened.selectedTab?.spaceID == destination.id && opened.selectedTab?.isInSmallWindow == false)
            #expect(opened.siteRuleToast != nil && session.windows.count == 1)
        }
    }

    @Test(arguments: [false, true]) func matchingRulesLeavePinnedSameTabLinksInPlaceWithoutPeek(crossPersona: Bool) throws {
        try fixture { session, window in
            let origin = window.currentSpace
            let destination = crossPersona
                ? session.preferredSpace(in: session.addPersona(named: "Work").id)
                : session.makeSpace(in: window.personaID, named: "Destination")
            try rule(session, to: destination)
            let tab = session.openTab(url: URL(string: "https://source.example/"), in: origin.id, pinned: true, select: false)
            window.selectTab(tab.id)
            let action = EngineNavigationAction(url: destinationURL, disposition: .currentTab,
                                                isUserInitiated: true, isLinkActivation: true)
            #expect(tab.webContents(tab.webContents, decidePolicyFor: action) == .allow)
            #expect(tab.pendingSiteRuleOpenings.isEmpty)
            #expect(session.tabs.count == 1 && window.selectedTab === tab)
            #expect(tab.spaceID == origin.id && tab.personaID == origin.resolvedPersonaID && window.currentSpaceID == origin.id)
            #expect(session.windows.allSatisfy { $0.preview == nil && $0.siteRuleToast == nil })
        }
    }

    @Test(arguments: [false, true]) func automaticPeekYieldsToSamePersonaRules(alreadyInDestination: Bool) throws {
        try fixture { session, window in
            let destination = alreadyInDestination ? window.currentSpace : session.makeSpace(in: window.personaID, named: "Destination")
            try rule(session, to: destination)
            let tab = session.openTab(url: URL(string: "https://source.example/"), in: window.currentSpaceID, pinned: true, select: false)
            window.selectTab(tab.id)
            let action = EngineNavigationAction(url: destinationURL, disposition: .newBackgroundTab,
                                                isUserInitiated: true, isLinkActivation: true, opensLinkInNewTab: true)
            #expect(tab.webContents(tab.webContents, decidePolicyFor: action) == .openLinkInNewTab)
            let popup = PageDouble(url: destinationURL)
            tab.webContents(tab.webContents, didCreateNewWebContents: popup, targetURL: destinationURL,
                            disposition: .newBackgroundTab, isUserInitiatedLink: true)
            let opened = try #require(session.tabs.first { $0.webContents === popup })
            #expect(opened.spaceID == destination.id && opened.opener === tab.webContents && opened.isUnread)
            #expect(window.preview == nil)
            tab.openURLInNewTab?(destinationURL)
            #expect(session.tabs.count == 3 && window.preview == nil)
            #expect(session.tabs.filter { $0 !== tab }.allSatisfy { $0.spaceID == destination.id })
        }
    }

    @Test(arguments: [false, true]) func explicitPeekYieldsToRules(alreadyInDestination: Bool) throws {
        try fixture { session, window in
            let destination = alreadyInDestination ? window.currentSpace : session.makeSpace(in: window.personaID, named: "Destination")
            try rule(session, to: destination)
            let tab = session.openTab(url: URL(string: "https://source.example/"), in: window.currentSpaceID, select: false)
            window.selectTab(tab.id)
            tab.previewLink?(destinationURL)
            #expect(window.preview == nil && session.tabs.count == 2)
            #expect(window.selectedTab?.url == destinationURL && window.selectedTab?.spaceID == destination.id)
            #expect(window.selectedTab?.opener === tab.webContents)
            #expect((window.siteRuleToast == nil) == alreadyInDestination)
        }
    }

    @Test func aRuleForTheCurrentSpaceKeepsExternalLinksInARegularWindow() throws {
        try fixture { session, window in
            try rule(session, to: window.currentSpace)
            let opened = session.openExternalLink(destinationURL, prefersSmallWindow: true)
            #expect(opened === window && session.windows.count == 1)
            #expect(window.selectedTab?.url == destinationURL && window.selectedTab?.isInSmallWindow == false)
            #expect(window.siteRuleToast == nil)
        }
    }
}
