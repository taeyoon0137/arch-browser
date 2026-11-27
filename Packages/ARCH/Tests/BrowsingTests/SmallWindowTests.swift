// When a link from another app opens a small window, and where a small window opens without another to cascade from.
import ARCHEngine
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Browsing

@Suite struct SmallWindowTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aLinkWhileArchIsInTheBackgroundOpensASmallWindow() {
        #expect(BrowserSession.opensLinkInSmallWindow(isAppActive: false, becameActiveAt: nil, now: now))
        #expect(BrowserSession.opensLinkInSmallWindow(isAppActive: false, becameActiveAt: now.addingTimeInterval(-60), now: now))
    }

    @Test func aLinkThatCameWithArchsActivationOpensASmallWindow() {
        #expect(BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: now.addingTimeInterval(-0.2), now: now))
    }

    @Test func aLinkWhileArchIsActiveOpensATab() {
        #expect(!BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: now.addingTimeInterval(-BrowserSession.smallWindowActivationGrace), now: now))
        #expect(!BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: now.addingTimeInterval(-60), now: now))
    }

    @Test func aLinkWhileArchHasBeenActiveSinceLaunchOpensATab() {
        #expect(!BrowserSession.opensLinkInSmallWindow(isAppActive: true, becameActiveAt: nil, now: now))
    }

    @Test func identityNamesTheDefaultPersonaEvenWhenItIsTheOnlyPersona() {
        let persona = Persona(id: Persona.defaultID, name: "Default")
        let space = Space(name: "Personal", symbol: "house.fill", tint: .teal, personaID: persona.id)
        let identity = SmallWindowIdentity(space: space, personas: [persona])
        #expect(identity.label == "Default / Personal")
        #expect(identity.personaName == "Default")
        #expect(identity.space.tint == .teal)
        #expect(identity.space.symbol == "house.fill")
    }

    @MainActor @Test func identityAndTintFollowTheSmallWindowsSpaceAndRenames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSmallWindowIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let home = try #require(session.spaces.first)
        let work = session.addPersona(named: "Work")
        let research = try #require(session.spaces(in: work.id).first)
        session.updateSpace(research.id) { $0.name = "Research"; $0.tint = .purple }
        let regular = BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let small = BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: research.id, selectedTabID: nil, isSidebarVisible: false), kind: .small)

        #expect(small.smallWindowIdentity.label == "Work / Research")
        #expect(small.smallWindowIdentity.space.tint == .purple)
        #expect(small.smallWindowIdentity.space.id != regular.currentSpaceID)

        session.renamePersona(work.id, to: "Studio")
        session.updateSpace(research.id) { $0.name = "Writing"; $0.tint = .orange }
        #expect(small.smallWindowIdentity.label == "Studio / Writing")
        #expect(small.smallWindowIdentity.space.tint == .orange)

        small.currentSpaceID = home.id
        #expect(small.smallWindowIdentity.space == home)
        #expect(small.smallWindowIdentity.label == "\(try #require(session.personas.first { $0.id == home.resolvedPersonaID }).name) / \(home.name)")
    }

    @MainActor @Test func aConstructedSmallWindowKeepsItsDefaultSizeAfterInstallingItsContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSmallWindowSize-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        // Without a remembered small-window size, the window uses the default size.
        UserDefaults.standard.removeObject(forKey: "ARCHSmallWindowFrame")
        let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: session.spaces[0].id, selectedTabID: nil, isSidebarVisible: false), kind: .small)
        defer { session.windowWillClose(small) }
        let window = try #require(small.nsWindow)
        let screens = NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        // Centered on the pointer, which may move during the test, so the size and the fit are checked rather than the origin.
        let expected = BrowserWindowController.smallWindowFrame(size: BrowserWindowKind.small.defaultContentSize, pointer: CGPoint(x: window.frame.midX, y: window.frame.midY),
                                                                screens: screens, preferredFrame: window.frame)
        #expect(window.frame == expected)
        if screens.contains(where: { $0.1.width >= 1225 && $0.1.height >= 872 }) {
            #expect(window.frame.size == BrowserWindowKind.small.defaultContentSize)
        }
        #expect(screens.contains { $0.1.insetBy(dx: 20, dy: 20).contains(window.frame) })
        #expect(window.contentMinSize == BrowserWindowKind.small.minimumContentSize)
        #expect(window.frame.width >= BrowserWindowKind.small.minimumContentSize.width)
        #expect(window.frame.height >= BrowserWindowKind.small.minimumContentSize.height)
        #expect(!window.isVisible)
    }

    @MainActor @Test func choosingASpaceKeepsTheLivePageUntilItsPersonaChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSmallWindowDestination-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let home = session.spaces[0]
        let reading = session.makeSpace(in: home.resolvedPersonaID)
        let work = session.addPersona(named: "Work")
        let research = session.makeSpace(in: work.id)
        let main = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: false), kind: .small)
        defer {
            for window in [main, small] where session.windows.contains(where: { $0 === window }) { session.windowWillClose(window) }
        }
        // Keep promotion off screen while exercising the real session routing.
        main.nsWindow = nil
        let address = URL(string: "https://fixture.invalid/destination")!
        let original = session.openTab(url: address, in: home.id, select: false)
        original.isInSmallWindow = true
        small.selectTab(original.id)
        let contents = original.webContents
        let document = original.documentID
        let destinations = SmallWindowMenus.places(session: session, window: small, tab: original)
        let readingLabel = SmallWindowIdentity(space: reading, personas: session.personas).label
        let readingIndex = try #require(destinations.items.firstIndex { $0.title == readingLabel })
        #expect(destinations.items.filter { $0.state == .on }.map(\.title) == [small.smallWindowIdentity.label])
        destinations.performActionForItem(at: readingIndex)
        #expect(small.selectedTab === original && original.webContents === contents && original.documentID == document)
        #expect(original.spaceID == reading.id && small.currentSpaceID == reading.id && original.isInSmallWindow)
        session.moveSmallWindow(small, toSpace: UUID())
        #expect(small.selectedTab === original && small.currentSpaceID == reading.id)

        let otherPersonaDestinations = SmallWindowMenus.places(session: session, window: small, tab: original)
        let researchLabel = SmallWindowIdentity(space: research, personas: session.personas).label
        let researchIndex = try #require(otherPersonaDestinations.items.firstIndex { $0.title == researchLabel })
        #expect(otherPersonaDestinations.items.filter { $0.state == .on }.map(\.title) == [readingLabel])
        otherPersonaDestinations.performActionForItem(at: researchIndex)
        let replacement = try #require(small.selectedTab)
        #expect(replacement !== original && replacement.webContents !== contents)
        #expect(replacement.personaID == work.id && replacement.spaceID == research.id && replacement.url == address)
        #expect(small.currentSpaceID == research.id && replacement.isInSmallWindow)
        #expect(!session.tabs.contains { $0 === original })
        let movedContents = replacement.webContents
        session.moveToMainWindow(small)
        #expect(main.selectedTab === replacement && main.currentSpaceID == research.id)
        #expect(replacement.webContents === movedContents && !replacement.isInSmallWindow)
        #expect(!session.windows.contains { $0 === small })
    }

    private let mainScreen = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let externalScreen = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private let size = CGSize(width: 800, height: 600)

    /// The window's frame centered on the pointer, as a new small window asks for it.
    private func centered(on pointer: CGPoint) -> CGRect {
        CGRect(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2, width: size.width, height: size.height)
    }

    @Test func theWindowOpensOnTheScreenWithThePointer() {
        let pointer = CGPoint(x: 2000, y: 500)
        let frame = BrowserWindowController.smallWindowFrame(size: size, pointer: pointer, screens: [mainScreen, externalScreen], preferredFrame: centered(on: pointer))
        #expect(frame == CGRect(x: 1600, y: 200, width: 800, height: 600))
    }

    @Test func aPointerInTheMenuBarStillPicksItsScreen() {
        let pointer = CGPoint(x: 2000, y: 1070)
        let frame = BrowserWindowController.smallWindowFrame(size: size, pointer: pointer, screens: [mainScreen, externalScreen], preferredFrame: centered(on: pointer))
        // The window stays 20 points below the top of the visible area.
        #expect(frame == CGRect(x: 1600, y: 435, width: 800, height: 600))
    }

    @Test func aPointerOnNoScreenPicksTheMainScreen() {
        let pointer = CGPoint(x: -500, y: 500)
        let frame = BrowserWindowController.smallWindowFrame(size: size, pointer: pointer, screens: [mainScreen, externalScreen], preferredFrame: centered(on: pointer))
        #expect(frame == CGRect(x: 20, y: 200, width: 800, height: 600))
    }

    @Test func theWindowShrinksToASmallScreen() {
        let small = (frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 575))
        let pointer = CGPoint(x: 100, y: 100)
        let frame = BrowserWindowController.smallWindowFrame(size: size, pointer: pointer, screens: [small], preferredFrame: centered(on: pointer))
        #expect(frame == CGRect(x: 20, y: 20, width: 760, height: 535))
    }
}
