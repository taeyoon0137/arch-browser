import AppKit
import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@MainActor @Suite struct PagePreviewTests {
    private func withSession(registered: Bool = false, _ body: (BrowserSession, SessionTestEngine, BrowserWindowModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = EngineRegistry(defaults: defaults)
        let chromium = SessionTestEngine(kind: .chromium)
        registry.register(chromium)
        registry.register(SessionTestEngine(kind: .webKit))
        registry.defaultKind = .chromium
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let record = SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true)
        let window = registered ? session.makeWindow(from: record, kind: .main) : BrowserWindowModel(session: session, record: record, kind: .main)
        // Keep registered windows off screen even when a command requests focus.
        if registered { window.nsWindow = nil }
        defer { if registered { session.windowWillClose(window) } }
        try body(session, chromium, window)
        #expect(session.windows.count == (registered ? 1 : 0))
    }

    @Test func aPreviewIsReusedOnlyForTheSameAddressPersonaAndRequestedEngine() throws {
        try withSession { session, chromium, window in
            let url = URL(string: "about:blank#shared")!
            let favorite = Favorite(url: url, title: "Shared", personaID: window.personaID)
            window.previewFavorite(favorite)
            let first = try #require(window.preview)
            window.previewFavorite(favorite)
            #expect(window.preview === first)

            let other = session.addPersona(named: "Work")
            let space = try #require(session.spaces.first { $0.resolvedPersonaID == other.id })
            let selected = session.openTab(url: URL(string: "about:blank#selected"), in: space.id, select: false, engine: .webKit)
            window.switchToSpace(space.id)
            #expect(window.selectedTab === selected)
            chromium.unavailableStorageID = other.id
            let otherFavorite = Favorite(url: url, title: "Shared", personaID: other.id)
            window.previewFavorite(otherFavorite)
            let second = try #require(window.preview)
            #expect(second !== first && second.personaID == other.id)
            #expect(second.webContents.engineKind == .webKit)
            window.previewFavorite(otherFavorite)
            #expect(window.preview === second)
            window.showPreview(of: url, engine: .webKit, in: other.id)
            #expect(window.preview !== second)
            #expect(window.selectedTab === selected && session.tabs.count == 1)
        }
    }

    @Test(arguments: [false, true]) func aFavoritePreviewOpenedAsATabKeepsItsLivePageAndRequestedEngine(recovered: Bool) throws {
        try withSession { session, chromium, window in
            let persona = session.addPersona(named: "Work")
            let space = try #require(session.spaces.first { $0.resolvedPersonaID == persona.id })
            window.switchToSpace(space.id)
            chromium.unavailableStorageID = persona.id
            let url = URL(string: "about:blank#favorite")!
            window.previewFavorite(Favorite(url: url, title: "Saved", personaID: persona.id))
            let preview = try #require(window.preview)
            #expect(preview.webContents.engineKind == .webKit)
            if recovered { chromium.unavailableStorageID = nil }
            window.openPreviewInTab()
            let tab = try #require(window.selectedTab)
            #expect(window.preview == nil && tab.url == url && tab.personaID == persona.id)
            #expect(tab.webContents === preview.webContents)
            #expect(tab.engineKind == .webKit)
            #expect(tab.preferredEngine == .chromium)
            try session.saveNow().get()
            #expect(SessionStore(directory: session.userDataDirectory, seal: .fixture).load()?.tabs.first?.engine == .chromium)
        }
    }

    @Test func openAsTabKeepsTheLivePageStateAndNativeOpenerInTheCurrentSpace() throws {
        try withSession { session, _, window in
            let openedURL = URL(string: "https://other.example/start")!
            let page = PageStub(engine: .chromium, url: openedURL)
            let opener = PageStub(engine: .chromium, url: URL(string: "https://source.example/"))
            window.showPreview(page, openedURL: openedURL, in: window.personaID, requestedEngine: .chromium, opener: opener)
            page.report(url: URL(string: "https://other.example/form"), title: "Edited page")
            page.restorableState = Data([1, 2, 3])
            page.zoomFactor = 1.5
            #expect(session.tabs.isEmpty)

            window.openPreviewInTab()

            let tab = try #require(window.selectedTab)
            #expect(window.preview == nil)
            #expect(tab.webContents === page && tab.opener === opener)
            #expect(page.uiDelegate === tab && page.navigationDelegate === tab)
            #expect(tab.spaceID == window.currentSpaceID && tab.personaID == window.personaID)
            #expect(tab.url == page.url && tab.title == "Edited page")
            #expect(page.restorableState == Data([1, 2, 3]) && page.zoomFactor == 1.5)
            #expect(page.loadedURLs.isEmpty)
            window.closePreview()
            #expect(session.tabs.count == 1 && tab.webContents === page)
        }
    }

    @Test func automaticPeekUsesOutgoingLinksAndNewTabsFromPinnedTabsOrFavorites() {
        let source = URL(string: "https://Example.COM./saved")!
        func peeks(_ destination: String, pinned: Bool = true, enabled: Bool = true, isUserInitiatedLink: Bool = true,
                   disposition: EngineNavigationDisposition = .newForegroundTab) -> Bool {
            PeekPolicy.shouldPeek(from: source, to: URL(string: destination), isPinnedOrFavorite: pinned,
                                  disposition: disposition, isUserInitiatedLink: isUserInitiatedLink, enabled: enabled)
        }
        #expect(PeekPolicy.automaticPeekByDefault)
        #expect(peeks("https://other.example/path"))
        #expect(peeks("https://other.example/path", disposition: .newBackgroundTab))
        #expect(peeks("http://example.com:8080/next"))
        #expect(!peeks("http://example.com:8080/next", disposition: .currentTab))
        #expect(!peeks("https://other.example/path", pinned: false))
        #expect(!peeks("https://other.example/path", enabled: false))
        #expect(!peeks("https://other.example/path", isUserInitiatedLink: false))
        #expect(!peeks("https://other.example/path", isUserInitiatedLink: false, disposition: .newBackgroundTab))
        #expect(peeks("https://other.example/path", disposition: .currentTab))
        #expect(!peeks("https://other.example/path", disposition: .newPopup))
        #expect(!peeks("https://other.example/path", disposition: .newWindow))
        #expect(!peeks("file:///tmp/page.html"))
        #expect(!peeks("mailto:person@example.com"))
        #expect(!PeekPolicy.shouldPeek(from: nil, to: URL(string: "https://other.example"), isPinnedOrFavorite: true,
                                       disposition: .newForegroundTab, isUserInitiatedLink: true, enabled: true))
        #expect(!PeekPolicy.shouldPeek(from: URL(string: "about:blank"), to: URL(string: "https://other.example"), isPinnedOrFavorite: true,
                                       disposition: .newForegroundTab, isUserInitiatedLink: true, enabled: true))
    }

    @Test func openInPeekContextItemUsesTheLinkAndExcludesNonWebAddresses() throws {
        let page = PageStub(engine: .chromium, url: URL(string: "https://example.com"))
        let tab = Tab(id: UUID(), webContents: page, spaceID: nil, isPinned: false, personaID: UUID())
        var opened: URL?
        tab.previewLink = { opened = $0 }
        let link = URL(string: "https://example.com/next")!
        let menu = NSMenu()
        tab.webContents(page, willShowContextMenuFor: .init(linkURL: link), menu: menu)
        let item = try #require(menu.items.first { $0.title == "Open in Peek" })
        let action = try #require(item.action)
        _ = (item.target as AnyObject).perform(action, with: item)
        #expect(opened == link)
        tab.webContents(page, willShowContextMenuFor: .init(linkURL: URL(string: "mailto:person@example.com")), menu: menu)
        #expect(!menu.items.contains { $0.title == "Open in Peek" })
    }

    @Test(arguments: [EngineKind.chromium, .webKit]) func automaticPeekAdoptsTheEnginesPageFromPinnedTabsAndFavorites(engine: EngineKind) throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PeekPolicy.automaticPeekKey)
        defaults.set(true, forKey: PeekPolicy.automaticPeekKey)
        defer { defaults.set(saved, forKey: PeekPolicy.automaticPeekKey) }
        try withSession(registered: true) { session, _, window in
            session.defaultEngine = engine
            for favorite in [false, true] {
                let sourceURL = URL(string: "https://source.example/saved")!
                let source: Tab
                if favorite {
                    let item = Favorite(url: sourceURL, title: "Saved", personaID: window.personaID)
                    session.addFavorites([item], in: window.personaID)
                    source = session.openTab(for: item)
                } else {
                    source = session.openTab(url: sourceURL, in: window.currentSpaceID, select: false)
                    source.isPinned = true
                }
                for disposition in [EngineNavigationDisposition.newForegroundTab, .newBackgroundTab] {
                    window.selectTab(source.id)
                    let count = session.allTabs.count
                    let page = PageStub(engine: engine, url: URL(string: "https://other.example/next"))
                    page.restorableState = Data([1, 2, 3])
                    source.webContents(source.webContents, didCreateNewWebContents: page, targetURL: page.url,
                                       disposition: disposition, isUserInitiatedLink: true)
                    let preview = try #require(window.preview)
                    #expect(preview.webContents === page && preview.opener === source.webContents)
                    #expect(window.selectedTab === source && session.allTabs.count == count)
                    window.openPreviewInTab()
                    #expect(window.selectedTab?.webContents === page && session.allTabs.count == count + 1)
                    #expect(window.selectedTab?.opener === source.webContents)
                    #expect(page.restorableState == Data([1, 2, 3]) && page.loadedURLs.isEmpty)
                }
                window.selectTab(source.id)
                let sameSite = PageStub(engine: engine, url: URL(string: "https://source.example/another"))
                source.webContents(source.webContents, didCreateNewWebContents: sameSite, targetURL: sameSite.url,
                                   disposition: .newBackgroundTab, isUserInitiatedLink: true)
                #expect(window.preview?.webContents === sameSite && window.selectedTab === source)
                #expect(!session.allTabs.contains { $0.webContents === sameSite })
                window.closePreview()
            }
        }
    }

    @Test(arguments: [EngineKind.chromium, .webKit]) func sameTabPeekRequiresVisiblePinnedOrFavoriteLinkWithoutRedirect(engine: EngineKind) throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PeekPolicy.automaticPeekKey)
        defaults.set(true, forKey: PeekPolicy.automaticPeekKey)
        defer { defaults.set(saved, forKey: PeekPolicy.automaticPeekKey) }
        try withSession(registered: true) { session, _, window in
            for favorite in [false, true] {
                let sourceURL = URL(string: "https://source.example/saved")!
                let source: Tab
                if favorite {
                    let item = Favorite(url: sourceURL, title: "Saved", personaID: window.personaID)
                    session.addFavorites([item], in: window.personaID)
                    source = session.openTab(for: item)
                } else {
                    source = session.openTab(url: sourceURL, in: window.currentSpaceID, select: false, engine: engine)
                    source.isPinned = true
                }
                window.selectTab(source.id)
                @MainActor func decision(_ destination: String, gesture: Bool = true, link: Bool = true, redirect: Bool = false) -> EngineNavigationPolicy {
                    source.webContents(source.webContents, decidePolicyFor: .init(url: URL(string: destination)!, disposition: .currentTab,
                                                                                isUserInitiated: gesture, isLinkActivation: link, isRedirect: redirect))
                }
                #expect(decision("https://other.example/next") == .openLinkInNewTab)
                #expect(decision("http://source.example:8712/next") == .allow)
                #expect(decision("https://other.example/next", gesture: false) == .allow)
                #expect(decision("https://other.example/next", link: false) == .allow)
                #expect(decision("https://other.example/next", redirect: true) == .allow)
                defaults.set(false, forKey: PeekPolicy.automaticPeekKey)
                #expect(decision("https://other.example/next") == .allow)
                defaults.set(true, forKey: PeekPolicy.automaticPeekKey)
                let other = session.openTab(url: sourceURL, in: window.currentSpaceID, select: false, engine: engine)
                window.selectTab(other.id)
                #expect(decision("https://other.example/next") == .allow)
                window.selectTab(source.id)
                source.pageDownloads.holdUntilUserActs()
                #expect(decision("https://other.example/next") == .allow)
            }
        }
    }

    @Test func disabledAutomaticPeekAndOrdinaryTabsKeepTheRequestedTabDisposition() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PeekPolicy.automaticPeekKey)
        defer { defaults.set(saved, forKey: PeekPolicy.automaticPeekKey) }
        try withSession(registered: true) { session, _, window in
            for engine in [EngineKind.chromium, .webKit] {
                let source = session.openTab(url: URL(string: "https://source.example/saved"), in: window.currentSpaceID,
                                             select: false, engine: engine)
                for (enabled, pinned) in [(false, true), (true, false)] {
                    defaults.set(enabled, forKey: PeekPolicy.automaticPeekKey)
                    source.isPinned = pinned
                    for disposition in [EngineNavigationDisposition.newForegroundTab, .newBackgroundTab] {
                        window.selectTab(source.id)
                        let page = PageStub(engine: engine, url: URL(string: "https://other.example/next"))
                        source.webContents(source.webContents, didCreateNewWebContents: page, targetURL: page.url,
                                           disposition: disposition, isUserInitiatedLink: true)
                        let opened = try #require(session.allTabs.first { $0.webContents === page })
                        #expect(window.preview == nil && opened.opener === source.webContents)
                        #expect(window.selectedTab === (disposition == .newBackgroundTab ? source : opened))
                        #expect(opened.isUnread == (disposition == .newBackgroundTab))
                        #expect(opened.engineKind == engine && page.loadedURLs.isEmpty)
                    }
                }
            }
        }
    }

    @Test func scriptAndUnknownOpeningsKeepTheirLivePagesAndOpenersOutsidePeek() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PeekPolicy.automaticPeekKey)
        defaults.set(true, forKey: PeekPolicy.automaticPeekKey)
        defer { defaults.set(saved, forKey: PeekPolicy.automaticPeekKey) }
        try withSession(registered: true) { session, _, window in
            for favorite in [false, true] {
                let sourceURL = URL(string: "https://source.example/saved")!
                let source: Tab
                if favorite {
                    let item = Favorite(url: sourceURL, title: "Saved", personaID: window.personaID)
                    session.addFavorites([item], in: window.personaID)
                    source = session.openTab(for: item)
                } else {
                    source = session.openTab(url: sourceURL, in: window.currentSpaceID, select: false)
                    source.isPinned = true
                }
                for engine in [EngineKind.chromium, .webKit] {
                    for disposition in [EngineNavigationDisposition.newForegroundTab, .newBackgroundTab, .newWindow, .newPopup] {
                        window.selectTab(source.id)
                        let count = session.allTabs.count
                        let page = PageStub(engine: engine, url: URL(string: "https://login.example/authorize"))
                        page.restorableState = Data([1, 2, 3])
                        // No link evidence is the default, including a popup whose target URL is unknown.
                        source.webContents(source.webContents, didCreateNewWebContents: page, targetURL: nil, disposition: disposition)
                        let opened = try #require(session.allTabs.first { $0.webContents === page })
                        #expect(window.preview == nil && session.allTabs.count == count + 1)
                        #expect(opened.opener === source.webContents && opened.personaID == source.personaID)
                        #expect(opened.engineKind == engine && page.uiDelegate === opened && page.navigationDelegate === opened)
                        #expect(page.restorableState == Data([1, 2, 3]) && page.loadedURLs.isEmpty)
                        #expect(window.selectedTab === (disposition == .newBackgroundTab ? source : opened))
                        #expect(opened.isUnread == (disposition == .newBackgroundTab))
                    }
                }
            }
        }
    }

    @Test func shiftPeekRequiresBothAUserGestureAndLinkActivation() async throws {
        let link = URL(string: "https://other.example/next")!
        for engine in [EngineKind.chromium, .webKit] {
            let page = PageStub(engine: engine, url: URL(string: "https://source.example"))
            let tab = Tab(id: UUID(), webContents: page, spaceID: UUID(), isPinned: false, personaID: UUID())
            var previews: [URL] = []
            tab.previewLink = { previews.append($0) }
            for gesture in [false, true] {
                for linkActivation in [false, true] {
                    let action = EngineNavigationAction(url: link, disposition: .newWindow, isUserInitiated: gesture,
                                                        isLinkActivation: linkActivation)
                    #expect(tab.webContents(page, decidePolicyFor: action) == (gesture && linkActivation ? .cancel : .allow))
                }
            }
            // A user gesture alone, as with a button that calls window.open, is not a Shift-clicked link.
            let unknown = EngineNavigationAction(url: link, disposition: .newWindow, isUserInitiated: true)
            #expect(tab.webContents(page, decidePolicyFor: unknown) == .allow)
            for disposition in [EngineNavigationDisposition.currentTab, .newPopup] {
                let action = EngineNavigationAction(url: link, disposition: disposition, isUserInitiated: true, isLinkActivation: true)
                #expect(tab.webContents(page, decidePolicyFor: action) == .allow)
            }
            // Command or middle-button clicks, also with Shift, use the tab-opening path rather than explicit Peek.
            tab.openNewTab = { _, _, _, _ in }
            for disposition in [EngineNavigationDisposition.newBackgroundTab, .newForegroundTab] {
                let action = EngineNavigationAction(url: link, disposition: disposition, isUserInitiated: true,
                                                    isLinkActivation: true, opensLinkInNewTab: true)
                #expect(tab.webContents(page, decidePolicyFor: action) == .openLinkInNewTab)
            }
            for url in [URL(string: "file:///tmp/page.html")!, URL(string: "mailto:person@example.com")!] {
                let action = EngineNavigationAction(url: url, disposition: .newWindow, isUserInitiated: true, isLinkActivation: true)
                #expect(tab.webContents(page, decidePolicyFor: action) == .allow)
            }
            #expect(previews.isEmpty)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            #expect(previews == [link])
        }
    }

    @Test func openAsTabFromSmallWindowUsesARegularWindowWithoutReloading() throws {
        try withSession(registered: true) { session, _, regular in
            let small = BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: regular.currentSpaceID,
                                                                          selectedTabID: nil, isSidebarVisible: false), kind: .small)
            let page = PageStub(engine: .chromium, url: URL(string: "https://example.com/form"))
            small.showPreview(page, openedURL: page.url!, in: small.personaID, requestedEngine: .chromium)
            small.openPreviewInTab()
            let tab = try #require(regular.selectedTab)
            #expect(tab.webContents === page && tab.spaceID == small.currentSpaceID)
            #expect(!tab.isInSmallWindow && small.preview == nil)
            #expect(session.windows.count == 1 && page.loadedURLs.isEmpty)
        }
    }

    @Test func retiringPreviewHostCannotReclaimOrDetachThePromotedPage() {
        let preview = WebContentsHostView.ContainerView(frame: .init(x: 0, y: 0, width: 320, height: 200))
        let tab = WebContentsHostView.ContainerView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        let page = NSView()
        preview.setContentView(page)
        tab.setContentView(page)
        // The outgoing SwiftUI subtree may receive one last update after the destination mounts.
        preview.setContentView(page)
        #expect(page.superview === tab && page.frame == tab.bounds)
        WebContentsHostView.dismantleNSView(preview, coordinator: ())
        #expect(page.superview === tab)
        let replacement = NSView()
        tab.setContentView(replacement)
        #expect(page.superview == nil && replacement.superview === tab)
    }

    @Test func escapeWaitsForThePageToFinishComposingText() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let monitor = PreviewDismissal.MonitorView()
        let page = ComposingPageView()
        window.contentView?.addSubview(monitor)
        window.contentView?.addSubview(page)
        #expect(window.makeFirstResponder(page) && !window.isVisible)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(monitor.closesOnEscape(escape))
        page.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!monitor.closesOnEscape(escape))
        page.unmarkText()
        #expect(monitor.closesOnEscape(escape))
        monitor.ignoresEscape = { true }
        #expect(!monitor.closesOnEscape(escape))
    }

    @Test func dismissalClicksStayInThePreviewWindowAndOutsideItsPanel() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let monitor = PreviewDismissal.MonitorView(frame: .init(x: 32, y: 32, width: 256, height: 136))
        window.contentView?.addSubview(monitor)
        func click(_ point: NSPoint, number: Int? = nil) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: number ?? window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        #expect(monitor.closesOnClick(try click(.init(x: 10, y: 10))))
        #expect(!monitor.closesOnClick(try click(.init(x: 100, y: 100))))
        #expect(!monitor.closesOnClick(try click(.init(x: 10, y: 10), number: 0)))
        #expect(!window.isVisible)
    }

    @Test func peekTakesKeyboardFocusFromTheCoveredPageAfterItsViewAttaches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine(kind: .webKit))
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let model = BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id,
                                                                      selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let source = session.openTab(url: URL(string: "about:blank#source"), in: space.id, select: false, engine: .webKit)
        model.selectTab(source.id)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        model.nsWindow = window
        let sourceField = ComposingPageView(), previewField = ComposingPageView()
        source.webContents.view.addSubview(sourceField)
        window.contentView?.addSubview(source.webContents.view)
        #expect(window.makeFirstResponder(sourceField))
        let page = PageStub(engine: .webKit, url: URL(string: "https://example.com"))
        page.view.addSubview(previewField)
        model.showPreview(page, openedURL: page.url!, in: model.personaID, requestedEngine: .webKit)
        #expect(window.firstResponder !== sourceField)
        window.contentView?.addSubview(page.view)
        model.focusPage()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(window.firstResponder === previewField && !window.isVisible)
        model.closePreview()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(window.firstResponder === sourceField && !window.isVisible)
    }

    @Test func promotingAPreviewForItsPopupKeepsTheNativeOpenerAndPopupEngines() throws {
        try withSession { session, chromium, window in
            let persona = session.addPersona(named: "Work")
            let space = try #require(session.spaces.first { $0.resolvedPersonaID == persona.id })
            window.switchToSpace(space.id)
            chromium.unavailableStorageID = persona.id
            window.previewFavorite(Favorite(url: URL(string: "about:blank#opener")!, title: "Opener", personaID: persona.id))
            let preview = try #require(window.preview)
            let popup = PageStub(engine: .webKit, url: URL(string: "about:blank#popup"))
            chromium.unavailableStorageID = nil
            preview.webContents(preview.webContents, didCreateNewWebContents: popup, targetURL: popup.url, disposition: .newWindow)
            let opener = try #require(session.tabs.first { $0.webContents === preview.webContents })
            let opened = try #require(window.selectedTab)
            #expect(opener.engineKind == .webKit && opener.preferredEngine == .chromium)
            #expect(opened.webContents === popup && opened.opener === preview.webContents)
            #expect(opened.engineKind == .webKit && opened.preferredEngine == .chromium)
            #expect(opened.personaID == persona.id && opener.personaID == persona.id)
        }
    }
}

/// The field editor in an engine view adopts the input client protocol without being an NSTextView.
private final class ComposingPageView: NSView, NSTextInputClient {
    override var acceptsFirstResponder: Bool { true }
    private var markedText = ""
    func setMarkedText(_ text: Any, selectedRange: NSRange, replacementRange: NSRange) { markedText = text as? String ?? "" }
    func unmarkText() { markedText = "" }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange { NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: markedText.utf16.count) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func insertText(_ text: Any, replacementRange: NSRange) { unmarkText() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
