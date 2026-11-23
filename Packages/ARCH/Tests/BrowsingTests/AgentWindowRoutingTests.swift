// A conversation chosen in another Persona stays in its invoking window. Its tab buttons follow the tab's place.
@testable import Agent
import AppKit
import Combine
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct AgentWindowRoutingTests {
    private func withWindows(_ check: (BrowserSession, BrowserWindowModel, BrowserWindowModel, Space, Space) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAgentWindows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let home = try #require(session.spaces.first)
        let work = session.addPersona(named: "Work")
        let research = try #require(session.spaces(in: work.id).first)
        let main = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: research.id, selectedTabID: nil, isSidebarVisible: false), kind: .small)
        defer {
            for window in [main, small] where session.windows.contains(where: { $0 === window }) { session.windowWillClose(window) }
        }
        // Record native window raise requests without bringing a test process to the front.
        let mainWindow = WindowSpy(), smallWindow = WindowSpy()
        mainWindow.isReleasedWhenClosed = false
        smallWindow.isReleasedWhenClosed = false
        main.nsWindow = mainWindow
        small.nsWindow = smallWindow
        let ordinary = session.openTab(url: URL(string: "about:blank#home"), in: home.id, select: false, engine: .webKit)
        main.selectTab(ordinary.id)
        let popup = session.openTab(url: URL(string: "about:blank#popup"), in: research.id, select: false, engine: .webKit)
        popup.isInSmallWindow = true
        small.selectTab(popup.id)
        try withExtendedLifetime((mainWindow, smallWindow)) { try check(session, main, small, home, research) }
    }

    @Test func remoteConversationStaysHereWhileItsTabsRouteToTheRightWindowAndPersona() throws {
        try withWindows { session, main, small, home, research in
            let mainWindow = try #require(main.nsWindow as? WindowSpy), smallWindow = try #require(small.nsWindow as? WindowSpy)
            let homeTab = try #require(main.selectedTab), popup = try #require(small.selectedTab)
            let remoteConversation = UUID()
            // This is the route shared by a palette session row and the running-agents menu.
            main.showAgentSession(remoteConversation)
            #expect(main.agentPanel == .session(remoteConversation) && main.currentSpaceID == home.id && main.selectedTab === homeTab)
            main.showAgentTab(popup.id)
            #expect(smallWindow.raises == 1 && mainWindow.raises == 0)
            #expect(main.selectedTab === homeTab && main.currentSpaceID == home.id && small.selectedTab === popup)
            small.showAgentSession(remoteConversation)
            let favorite = Favorite(url: URL(string: "https://fixture.invalid/research")!, title: "Research", personaID: research.resolvedPersonaID)
            session.addFavorites([favorite], in: research.resolvedPersonaID)
            let favoriteTab = session.openTab(for: favorite)
            small.showAgentTab(favoriteTab.id)
            #expect(mainWindow.raises == 1 && main.selectedTab === favoriteTab)
            #expect(main.currentSpaceID == research.id && main.personaID == favoriteTab.personaID)
            #expect(small.selectedTab === popup && small.agentPanel == .session(remoteConversation))
            main.showAgentTab(homeTab.id)
            #expect(main.selectedTab === homeTab && main.currentSpaceID == home.id)
            main.showAgentTab(favoriteTab.id)
            #expect(main.currentSpaceID == research.id && main.selectedTab === favoriteTab)
            main.showAgentTab(UUID())
            #expect(main.selectedTab === favoriteTab && main.agentPanel == .session(remoteConversation))
        }
    }

    @Test func showingAPageReadInAnotherWindowKeepsBothConversationsAndTheOriginalTab() throws {
        try withWindows { session, main, _, home, research in
            let other = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: research.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            let otherWindow = WindowSpy()
            otherWindow.isReleasedWhenClosed = false
            other.nsWindow = otherWindow
            defer { session.windowWillClose(other) }
            let source = session.openTab(url: URL(string: "about:blank#source"), in: research.id, select: false, engine: .webKit)
            other.selectTab(source.id)
            let sourceConversation = UUID(), invokingConversation = UUID()
            other.showAgentSession(sourceConversation)
            main.showAgentSession(invokingConversation)
            let original = main.selectedTabID, document = source.documentID, count = session.allTabs.count
            main.showReadTab(source.id)
            #expect(otherWindow.raises == 1 && other.selectedTabID == source.id && source.documentID == document)
            #expect(main.currentSpaceID == home.id && main.selectedTabID == original && session.allTabs.count == count)
            #expect(main.agentPanel == .session(invokingConversation) && other.agentPanel == .session(sourceConversation))
            main.showReadTab(UUID())
            #expect(otherWindow.raises == 1 && session.allTabs.count == count)
        }
    }

    @Test func sourceSelectionRevealsOnlyItsDestinationWindow() throws {
        try withWindows { session, main, small, home, _ in
            let source = try #require(main.selectedTab), popup = try #require(small.selectedTab)
            let address = URL(string: "about:blank#preview")!
            let mainConversation = UUID(), smallConversation = UUID()
            main.showAgentSession(mainConversation)
            small.showAgentSession(smallConversation)
            main.showPreview(of: address, engine: .webKit, in: main.personaID)
            small.showPreview(of: address, engine: .webKit, in: small.personaID)
            let original = source.webContents, document = source.documentID, count = session.allTabs.count
            small.submitCommandPalette("flags://")
            small.showCommandPalette(.newTab)
            main.showReadTab(popup.id)
            #expect(small.selectedTab === popup && small.preview == nil && small.internalPage == nil && small.commandPaletteMode == nil)
            #expect(main.preview != nil && main.selectedTab === source)
            main.showCommandPalette(.editCurrent)
            main.showReadTab(source.id)
            #expect(main.preview == nil && main.commandPaletteMode == nil && source.webContents === original && source.documentID == document)
            #expect(main.agentPanel == .session(mainConversation) && small.agentPanel == .session(smallConversation))
            #expect(session.allTabs.count == count)

            let next = session.openTab(url: URL(string: "about:blank#unshown"), in: home.id, select: false, engine: .webKit)
            let nextDocument = next.documentID
            main.showPreview(of: address, engine: .webKit, in: main.personaID)
            small.showReadTab(next.id)
            #expect(main.selectedTab === next && main.preview == nil && next.documentID == nextDocument)
            #expect(main.agentPanel == .session(mainConversation) && small.agentPanel == .session(smallConversation))
        }
    }

    @Test func revealingAnInactiveSplitSourcePreservesBothPanes() throws {
        try withWindows { session, main, small, home, _ in
            let source = try #require(main.selectedTab)
            let other = session.openTab(url: URL(string: "about:blank#split"), in: home.id, select: false, engine: .webKit)
            main.openInSplitView(other)
            let contents = source.webContents, document = source.documentID
            let panes = main.paneTabs.map(\.id), count = session.allTabs.count
            #expect(panes.contains(source.id) && panes.contains(other.id) && main.selectedTab === other)
            main.showPreview(of: URL(string: "about:blank#preview")!, engine: .webKit, in: main.personaID)
            small.showReadTab(source.id)
            #expect(main.selectedTab === source && main.preview == nil && main.paneTabs.map(\.id) == panes)
            #expect(source.webContents === contents && source.documentID == document && session.allTabs.count == count)
        }
    }

    @Test func revealingASourceWhileAPreviewPromotesItsPopupKeepsBothAdoptedPages() throws {
        try withWindows { session, main, _, _, _ in
            let source = try #require(main.selectedTab)
            let contents = source.webContents, document = source.documentID
            main.showPreview(of: URL(string: "about:blank#related")!, engine: .webKit, in: main.personaID)
            let preview = try #require(main.preview)
            let popup = PageStub(engine: .webKit, url: URL(string: "about:blank#popup"))
            preview.webContents(preview.webContents, didCreateNewWebContents: popup, targetURL: popup.url, disposition: .newWindow)
            let opener = try #require(session.tabs.first { $0.webContents === preview.webContents })
            let opened = try #require(main.selectedTab)
            let count = session.allTabs.count
            main.showReadTab(source.id)
            #expect(main.preview == nil && main.selectedTab === source && source.webContents === contents && source.documentID == document)
            #expect(session.tabs.contains { $0 === opener } && opened.webContents === popup && opened.opener === opener.webContents)
            #expect(opener.webContents.uiDelegate === opener && session.allTabs.count == count)
        }
    }

    @Test func tabsCreatedDuringAPersonaEngineOutageRecoverTheirRequestedEngine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ArchEngineFixture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = EngineRegistry(defaults: defaults)
        let chromium = SessionTestEngine(kind: .chromium)
        registry.register(chromium)
        registry.register(SessionTestEngine(kind: .webKit))
        registry.defaultKind = .chromium
        func launch() throws -> BrowserSession {
            try BrowserSession(testRegistry: registry, directory: directory)
        }
        let browser = try launch()
        let persona = browser.addPersona(named: "Work")
        let space = try #require(browser.spaces(in: persona.id).first)
        chromium.unavailableStorageID = persona.id
        let address = URL(string: "https://fixture.invalid/pin")!
        let imported = SidebarImport(profile: .init(source: "fixture", folder: "work"), profileName: "Work", favorites: [],
                                     spaces: [.init(origin: .bookmarks, name: nil, tint: nil, pinnedItems: [.init(sourceID: "pin", url: address, title: "Pin")], folders: [])])
        var record = SidebarImport.Record(directory: directory)
        _ = browser.addImport(imported, to: .persona(persona.id), record: &record)
        let pin = try #require(browser.tabs.first { $0.url == address })
        let main = browser.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { for window in browser.windows { browser.windowWillClose(window) } }
        // Small URL windows request key status after selection. Keep their native windows hidden.
        let offscreen = WindowSpy()
        let observation = browser.$focusedTabID.sink { id in
            guard let id, let window = browser.activeWindow, window.kind == .small, window.selectedTabID == id else { return }
            window.nsWindow = offscreen
        }
        defer { observation.cancel() }
        let external = browser.openSmallWindow(url: URL(string: "about:blank#external")!)
        let externalTab = try #require(external.selectedTab)
        external.openReplyLink(URL(string: "about:blank#agent")!, in: external.personaID)
        let agentLink = try #require(browser.activeWindow?.selectedTab)
        main.selectTab(pin.id)
        _ = browser.pageAssistant.openLink(URL(string: "https://fixture.invalid/reader")!, from: pin)
        let readerLink = try #require(main.selectedTab)
        let research = try #require(browser.openAgentTab(url: address, engine: nil, owner: UUID(), folderName: "Research", in: space.id))
        browser.keepTabs(ofFolder: try #require(research.folderID))
        main.selectTab(pin.id)
        pin.openURLInNewTab?(address)
        let backgroundLink = try #require(browser.tabs.last)
        #expect(backgroundLink.isUnread && main.selectedTab === pin)
        pin.searchInNewTab?("daily browser")
        let search = try #require(main.selectedTab)
        #expect(search !== pin)
        pin.searchInNewTab?("background search")
        let backgroundSearch = try #require(browser.tabs.last)
        #expect(backgroundSearch.isUnread && main.selectedTab === search)
        main.selectTab(pin.id)
        pin.previewLink?(address)
        #expect(main.preview?.requestedEngine == .chromium)
        main.openPreviewInTab()
        let promotedPreview = try #require(main.selectedTab)
        // A popup renders in the engine that created it and saves its opener's engine choice.
        main.selectTab(pin.id)
        let popupContents = browser.makeWebContents(url: address, engine: .webKit, state: nil, in: persona.id)
        pin.openNewTab?(popupContents, address, .newForegroundTab)
        let popup = try #require(main.selectedTab)
        let requested = [pin, externalTab, agentLink, readerLink, research, backgroundLink, search, backgroundSearch, promotedPreview]
        #expect(Set(requested.map(\.id)).count == requested.count)
        #expect(requested.allSatisfy { $0.personaID == persona.id && $0.engineKind == .webKit && $0.preferredEngine == .chromium })
        #expect(popup.engineKind == .webKit && popup.preferredEngine == .chromium && popup.opener === pin.webContents)
        #expect(offscreen.raises == 2 && !offscreen.isVisible)
        try browser.saveNow().get()
        chromium.unavailableStorageID = nil
        let reopened = try launch()
        for tab in requested + [popup] {
            let restored = try #require(reopened.tabs.first { $0.id == tab.id })
            reopened.loadPage(of: restored)
            #expect(restored.engineKind == .chromium)
        }
    }

    @Test func replyLinksFollowTheirWindowAndPersona() throws {
        try withWindows { session, main, small, home, research in
            let homeTab = try #require(main.selectedTab)
            let popup = try #require(small.selectedTab)
            let address = try #require(URL(string: "https://fixture.invalid/reply"))

            // The other Persona's small window was last active.
            #expect(session.activeWindow === small)
            _ = session.pageAssistant.openLink(address, from: homeTab)
            let opened = try #require(main.selectedTab)
            #expect(opened.url == address && opened.spaceID == home.id && opened.personaID == home.resolvedPersonaID)
            #expect(opened.isListedInSidebar && opened.agentOwnerID == nil && opened !== homeTab)
            #expect(session.windows.count == 2 && small.selectedTab === popup)

            main.switchToSpace(research.id)
            main.switchToSpace(home.id)
            session.windowDidBecomeMain(main)
            let mainSelection = main.selectedTabID
            // Redirect the new window's raise once its controller exists, before the open makes it key.
            let destinationWindow = WindowSpy()
            let selection = session.$focusedTabID.sink { id in
                guard let id, let window = session.activeWindow, window !== main, window !== small, window.selectedTabID == id else { return }
                window.nsWindow = destinationWindow
            }
            defer { selection.cancel() }
            _ = session.pageAssistant.openLink(address, from: popup)
            let destination = try #require(session.windows.first { $0 !== main && $0 !== small })
            defer { session.windowWillClose(destination) }
            let linked = try #require(destination.selectedTab)
            #expect(session.windows.count == 3 && destination.kind == .small && destinationWindow.raises == 1)
            #expect(linked.url == address && linked.spaceID == research.id && linked.personaID == research.resolvedPersonaID)
            #expect(linked.isInSmallWindow && !linked.isListedInSidebar && linked.agentOwnerID == nil)
            #expect(main.currentSpaceID == home.id && main.selectedTabID == mainSelection && small.selectedTab === popup)
        }
    }

    @Test(arguments: [false, true]) func movingAPopupKeepsItsReviewedFirstTask(visible: Bool) throws {
        try withWindows { session, main, small, _, _ in
            let tab = try #require(small.selectedTab)
            let page = try #require(tab.webContents as? PageDouble)
            let address = try #require(URL(string: "https://fixture.invalid/terms"))
            page.load(address, in: tab)
            tab.webContents(page, didCommitDocumentAt: address)
            small.showAgentComposer(text: "Check the original terms")
            guard case .composer(let draft) = small.agentPanel else { Issue.record("Expected a source draft"); return }
            let reviewed = try #require(draft.tab)
            draft.attachesTab = false
            if !visible { small.hideAgentPanel() }
            // A reload retains the address but invalidates the reviewed document.
            tab.webContents(page, didCommitDocumentAt: address)
            session.moveToMainWindow(small)
            #expect(main.selectedTab === tab && !tab.isInSmallWindow)
            if !visible {
                #expect(main.agentPanel == nil)
                main.toggleAgentPanel()
            }
            #expect(main.agentPanel == .composer(draft))
            #expect(draft.text == "Check the original terms" && !draft.attachesTab)
            #expect(draft.tab == reviewed && reviewed.id == tab.id && reviewed.documentID != tab.documentID)
        }
    }

    enum DraftPanel: CaseIterable { case hidden, visible, conversation, reader }

    @Test(arguments: DraftPanel.allCases) func movingADraftPreservesTheMainWindowsWorkInAnotherSpace(existing: DraftPanel) throws {
        try withWindows { session, main, small, home, research in
            main.showAgentComposer(text: "Keep the main window's notes")
            guard case .composer(let original) = main.agentPanel else { Issue.record("Expected main draft"); return }
            switch existing {
            case .hidden: main.hideAgentPanel()
            case .conversation: main.showAgentSession(UUID())
            case .reader: main.hideAgentPanel(); main.togglePageReader()
            case .visible: break
            }
            let panel = main.agentPanel
            small.showAgentComposer(text: "Carry the small window's notes")
            guard case .composer(let incoming) = small.agentPanel else { Issue.record("Expected small draft"); return }

            session.moveToMainWindow(small)
            #expect(main.currentSpaceID == research.id)
            if existing == .reader {
                #expect(main.agentPanel == nil && main.isPageReaderVisible)
            } else {
                #expect(main.agentPanel == (panel ?? .composer(incoming)))
            }
            main.hideAgentPanel()
            main.toggleAgentPanel()
            #expect(main.agentPanel == .composer(incoming))
            main.hideAgentPanel()
            main.switchToSpace(home.id)
            main.toggleAgentPanel()
            #expect(main.agentPanel == .composer(original))
        }
    }

    @Test(arguments: [false, true]) func competingDraftsMoveToSeparateMainWindows(reuse: Bool) throws {
        try withWindows { session, main, small, _, research in
            main.switchToSpace(research.id)
            let originalTab = session.openTab(url: URL(string: "https://fixture.invalid/main"), in: research.id, select: false)
            main.selectTab(originalTab.id)
            main.showAgentComposer(text: "Review these notes")
            guard case .composer(let original) = main.agentPanel else { Issue.record("Expected main draft"); return }
            if !reuse { main.hideAgentPanel() } // A hidden same-space draft still owns its slot.
            let panel = main.agentPanel
            let alternative = reuse ? session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: research.id,
                                                                      selectedTabID: nil, isSidebarVisible: true), kind: .main) : nil
            let receiver = WindowSpy()
            alternative?.nsWindow = receiver
            session.windowDidBecomeMain(main)
            let originalWindows = Set(session.windows.map(\.id))
            // A collision can create a main window. Replace its raise target once selection reaches it.
            let observation = session.$focusedTabID.sink { id in
                guard id != nil, let window = session.activeWindow, !originalWindows.contains(window.id) else { return }
                window.nsWindow = receiver
            }
            defer { observation.cancel() }
            small.showAgentComposer(text: "Review these notes")
            guard case .composer(let incoming) = small.agentPanel else { Issue.record("Expected small draft"); return }
            let moved = try #require(small.selectedTab)
            session.moveToMainWindow(small)
            let target = try #require(session.windows.first { $0.kind == .main && $0.selectedTab === moved })
            defer { session.windowWillClose(target) }
            #expect(target !== main && (reuse ? target === alternative : !originalWindows.contains(target.id)))
            #expect(target.agentPanel == .composer(incoming) && main.agentPanel == panel && main.selectedTab === originalTab)
            if panel == nil { main.toggleAgentPanel() }
            #expect(main.agentPanel == .composer(original) && original !== incoming)
            #expect(receiver.raises == 1 && !receiver.isVisible)
        }
    }

    enum MainPanel: CaseIterable { case closed, draft, conversation }

    @Test(arguments: MainPanel.allCases) func movingAPopupCarriesItsSessionIntoAnEmptyPanel(existing: MainPanel) throws {
        try withWindows { session, main, small, _, research in
            let popup = try #require(small.selectedTab)
            switch existing {
            case .closed: break
            case .draft: main.showAgentComposer(text: "An unfinished draft")
            case .conversation: main.showAgentSession(UUID())
            }
            let original = main.agentPanel
            let id = UUID()
            small.showAgentSession(id)
            session.moveToMainWindow(small)
            #expect(main.selectedTab === popup && !popup.isInSmallWindow && main.currentSpaceID == research.id)
            #expect(main.agentPanel == (original ?? .session(id)))
            #expect((main.nsWindow as? WindowSpy)?.raises == 1)
        }
    }

    private final class WindowSpy: NSWindow {
        var raises = 0
        override func makeKeyAndOrderFront(_ sender: Any?) { raises += 1 }
    }
}
