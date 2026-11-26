// The View and tab row commands give user activation only after the requested page is shown in their window. Engines are stand-ins and no video or picture in picture window opens.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct PictureInPictureRoutingTests {
    private func withSession(_ engine: EngineKind, _ check: (BrowserSession, BrowserWindowModel, Space) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPictureInPicture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine(kind: engine))
        registry.register(SessionTestEngine(kind: engine == .webKit ? .chromium : .webKit))
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        defer { for window in session.windows { session.windowWillClose(window) } }
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        try check(session, window, space)
    }

    private func makeTab(in session: BrowserSession, space: Space, engine: EngineKind, address: String = "https://example.org/video") -> (Tab, PageStub) {
        let url = URL(string: address)!
        let tab = session.openTab(url: url, in: space.id, select: false, engine: engine)
        let page = PageStub(engine: engine, url: url)
        tab.replaceWebContents(with: page)
        tab.webContents(page, didCommitDocumentAt: url)
        return (tab, page)
    }

    @Test(arguments: [EngineKind.webKit, .chromium])
    func aSelectedPageGetsOneRequest(_ engine: EngineKind) throws {
        try withSession(engine) { session, window, space in
            let (tab, page) = makeTab(in: session, space: space, engine: engine)
            window.selectTab(tab.id)
            page.pictureInPictureRequested = {
                #expect(window.selectedTab === tab && window.shows(tab))
                return true
            }
            #expect(window.canTogglePictureInPicture(tab))
            window.togglePictureInPicture(tab)
            #expect(page.pictureInPictureRequests == 1)
        }
    }

    @Test(arguments: [EngineKind.webKit, .chromium])
    func aBackgroundTabIsShownBeforeItsRequest(_ engine: EngineKind) throws {
        try withSession(engine) { session, window, space in
            let (first, firstPage) = makeTab(in: session, space: space, engine: engine)
            let (video, page) = makeTab(in: session, space: space, engine: engine)
            window.selectTab(first.id)
            page.pictureInPictureRequested = {
                #expect(window.selectedTab === video && window.shows(video))
                #expect(!window.shows(first))
                return true
            }
            window.togglePictureInPicture(video)
            #expect(page.pictureInPictureRequests == 1)
            #expect(firstPage.pictureInPictureRequests == 0)
        }
    }

    @Test(arguments: [EngineKind.webKit, .chromium])
    func aSelectedPageTakenByAnotherWindowComesBackBeforeItsRequest(_ engine: EngineKind) throws {
        try withSession(engine) { session, first, space in
            let second = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            let (tab, page) = makeTab(in: session, space: space, engine: engine)
            first.selectTab(tab.id)
            second.selectTab(tab.id)
            #expect(first.selectedTab === tab && !first.shows(tab) && second.shows(tab))
            page.pictureInPictureRequested = {
                #expect(first.shows(tab) && !second.shows(tab))
                return true
            }
            first.togglePictureInPicture(tab)
            #expect(page.pictureInPictureRequests == 1)
        }
    }

    @Test(arguments: [EngineKind.webKit, .chromium])
    func coveredUnloadedAndNonWebPagesAreUnavailable(_ engine: EngineKind) throws {
        try withSession(engine) { session, window, space in
            let (video, page) = makeTab(in: session, space: space, engine: engine)
            window.selectTab(video.id)
            window.submitCommandPalette("flags://")
            #expect(!window.canTogglePictureInPicture(video))
            window.togglePictureInPicture(video)
            #expect(page.pictureInPictureRequests == 0)
            window.closeInternalPage()
            #expect(window.canTogglePictureInPicture(video))

            let (internalTab, internalPage) = makeTab(in: session, space: space, engine: engine, address: "about:blank")
            #expect(!window.canTogglePictureInPicture(internalTab))
            window.togglePictureInPicture(internalTab)
            #expect(internalPage.pictureInPictureRequests == 0)

            let unloaded = Tab(id: UUID(), webContents: UnloadedWebContents(url: URL(string: "https://example.org/restored"), title: "", engine: engine, state: nil), spaceID: space.id, isPinned: true, personaID: space.resolvedPersonaID)
            #expect(!window.canTogglePictureInPicture(unloaded))
            window.togglePictureInPicture(unloaded)
            #expect(!unloaded.isLoaded && window.selectedTab === video)
        }
    }

    @Test(arguments: [EngineKind.webKit, .chromium])
    func aRefusedRequestDoesNotRetryOrChangeTheSelection(_ engine: EngineKind) throws {
        try withSession(engine) { session, window, space in
            let (video, page) = makeTab(in: session, space: space, engine: engine)
            window.selectTab(video.id)
            page.pictureInPictureRequested = { false }
            window.togglePictureInPicture(video)
            #expect(page.pictureInPictureRequests == 1)
            #expect(window.selectedTab === video && window.shows(video))
        }
    }

    @Test(arguments: [EngineKind.webKit, .chromium])
    func closingABackgroundAutomaticPresentationReleasesItsPage(_ engine: EngineKind) throws {
        try withSession(engine) { session, window, space in
            let (selected, selectedPage) = makeTab(in: session, space: space, engine: engine)
            window.selectTab(selected.id)
            weak var retiredPage: PageStub?
            do {
                let (video, page) = makeTab(in: session, space: space, engine: engine)
                retiredPage = page
                session.automaticPictureInPicture.update(selected: page, isFocused: true, enabled: true, hasPictureInPicture: false)
                session.automaticPictureInPicture.update(selected: selectedPage, isFocused: true, enabled: true, hasPictureInPicture: false)
                #expect(page.automaticPictureInPictureRequests == [true])
                #expect(session.closeTab(video))
            }
            let released = retiredPage == nil
            #expect(released)
            session.automaticPictureInPicture.update(selected: selectedPage, isFocused: false, enabled: true, hasPictureInPicture: false)
            #expect(selectedPage.automaticPictureInPictureRequests == [true])
        }
    }

    @Test(arguments: [EngineKind.webKit, .chromium])
    func replacingTheSelectedEngineKeepsTheFirstAutomaticDeparture(_ engine: EngineKind) throws {
        try withSession(engine) { session, window, space in
            let (tab, old) = makeTab(in: session, space: space, engine: engine)
            let (_, next) = makeTab(in: session, space: space, engine: engine)
            window.selectTab(tab.id)
            let controller = session.automaticPictureInPicture
            controller.update(selected: old, isFocused: true, enabled: true, hasPictureInPicture: false)
            let replacement = PageStub(engine: engine == .webKit ? .chromium : .webKit, url: old.url)
            // Engine replacement uses the same session path as switching a tab's engine.
            tab.webContents(old, didCreateReplacement: replacement)
            #expect(tab.webContents === replacement)
            #expect(old.automaticPictureInPictureRequests.isEmpty)
            #expect(replacement.automaticPictureInPictureRequests.isEmpty)
            controller.update(selected: next, isFocused: true, enabled: true, hasPictureInPicture: false)
            #expect(replacement.automaticPictureInPictureRequests == [true])
            controller.update(selected: replacement, isFocused: true, enabled: true, hasPictureInPicture: true)
            #expect(replacement.automaticPictureInPictureRequests == [true, false])
        }
    }

    @Test func closingAPageWaitingForAnotherPresentationToStopReleasesIt() throws {
        try withSession(.webKit) { session, window, space in
            let (_, first) = makeTab(in: session, space: space, engine: .webKit)
            let (selected, selectedPage) = makeTab(in: session, space: space, engine: .webKit)
            window.selectTab(selected.id)
            var finishStop: ((Bool) -> Void)?
            first.automaticPictureInPictureRequested = { [weak first] enabled, completion in
                if enabled { first?.isInPictureInPicture = true; completion(true) }
                else { finishStop = completion }
            }
            let controller = session.automaticPictureInPicture
            controller.update(selected: first, isFocused: true, enabled: true, hasPictureInPicture: false)
            controller.update(selected: selectedPage, isFocused: true, enabled: true, hasPictureInPicture: false)
            controller.update(selected: first, isFocused: true, enabled: true, hasPictureInPicture: true)
            weak var retiredPage: PageStub?
            do {
                let (tab, page) = makeTab(in: session, space: space, engine: .webKit)
                retiredPage = page
                controller.update(selected: page, isFocused: true, enabled: true, hasPictureInPicture: true)
                controller.update(selected: selectedPage, isFocused: true, enabled: true, hasPictureInPicture: true)
                #expect(page.automaticPictureInPictureRequests.isEmpty)
                #expect(session.closeTab(tab))
            }
            let released = retiredPage == nil
            #expect(released)
            first.isInPictureInPicture = false
            let complete = try #require(finishStop)
            complete(true)
            #expect(selectedPage.automaticPictureInPictureRequests.isEmpty)
        }
    }
}
