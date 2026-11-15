// A native window's session-folder actions use its current Persona, space and the live folder owner.
import AppKit
import AgentControl
@testable import AI
import ARCHEngine
import Foundation
import SwiftUI
import Testing
@testable import Agent
@testable import Browsing

@MainActor @Suite(.serialized) struct SessionFolderControlsTests {
    private func fixture(in directory: URL, client: any AIClient, models: @escaping @MainActor () -> [AIModelRef] = { [] }) throws -> (BrowserSession, BrowserAgentHost, AgentService) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let browser = try BrowserSession(testRegistry: registry, directory: directory)
        let host = BrowserAgentHost(session: browser)
        let service = AgentService(directory: directory, host: host, version: "test", dependencies: .init(
            location: nil, keys: UnusedFolderKeys(), peerChecks: .init(read: { _ in throw CancellationError() }, verify: { _ in throw CancellationError() }),
            identify: { _ in throw CancellationError() }, processStart: { _ in nil }, prompt: AgentGrantSheetPresenter(host: host),
            authenticator: AgentDeviceOwnerAuthentication(), allowsAI: { _ in true }, now: Date.init, processRecord: { _ in nil },
            startRunner: { _ in throw CancellationError() }, sessionRoute: { .http(pinnedModel: $0) }, apiClient: client,
            mcpExecutable: directory, sessionFolder: { _ in directory }, agentModels: models, subscriptionToolName: { _ in nil }, attention: { _ in }))
        browser.agents = service
        return (browser, host, service)
    }

    @Test func paletteStartsOnlyWithTheDocumentAndPlaceItsRowOffered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var models = [QuestionClient.model]
        let (browser, _, service) = try fixture(in: directory, client: WaitingFolderClient(), models: { models })
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: home.id,
                                                                      selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: AIKeychain())
        let task = "Compare these plans"
        let address = try #require(URL(string: "https://fixture.invalid/plans"))
        let page = browser.openTab(url: address, in: home.id, select: false)
        window.renameTab(page.id, to: "Product plans")
        func offer() throws -> AskAgentOffer { try #require(window.askAgentOffer(for: task, settings: settings)) }
        func expectDraft(_ reviewed: AskAgentOffer) {
            let count = service.sessions.count
            window.askAgent(reviewed, settings: settings)
            guard case .composer(let draft) = window.agentPanel else { Issue.record("Expected an unsent draft"); return }
            #expect(service.sessions.count == count && draft.text == task && draft.tab == nil && draft.problem != nil)
            #expect(draft.spaceID == window.currentSpaceID && draft.personaID == window.personaID)
        }
        let blank = try offer()
        #expect(blank.sharingDetail == "No page shared")
        window.selectTab(page.id)
        expectDraft(blank)
        var reviewed = try offer()
        #expect(reviewed.sharingDetail == "Shares Product plans")
        models = []
        #expect(window.askAgentOffer(for: task, settings: settings) == nil)
        window.askAgent(reviewed, settings: settings)
        guard case .composer(let setup) = window.agentPanel else { Issue.record("Expected local model setup"); return }
        #expect(service.sessions.isEmpty && setup.text == task && setup.tab?.documentID == page.documentID)
        models = [QuestionClient.model]
        window.askAgent(reviewed, settings: settings)
        let attached = try #require(service.sessions.first)
        #expect(attached.handles.sharedTabIDs == [page.id] && window.agentPanel == .session(attached.id))

        settings.setAllowsAI(false, on: address)
        expectDraft(reviewed)
        reviewed = try offer()
        #expect(reviewed.sharingDetail == "No page shared")
        window.askAgent(reviewed, settings: settings)
        let detached = try #require(service.sessions.first { $0 !== attached })
        #expect(detached.handles.sharedTabIDs.isEmpty && window.agentPanel == .session(detached.id))
        settings.setAllowsAI(true, on: address)
        expectDraft(reviewed)

        reviewed = try offer()
        let engine = try #require(page.webContents as? PageDouble)
        engine.load(address.appendingPathComponent("other"), in: page)
        expectDraft(reviewed)
        reviewed = try offer()
        page.webContents(page.webContents, didCommitDocumentAt: page.url)
        expectDraft(reviewed)
        reviewed = try offer()
        window.submitCommandPalette("flags://")
        expectDraft(reviewed)
        let covered = try offer()
        #expect(covered.sharingDetail == "No page shared")
        window.closeInternalPage()
        expectDraft(covered)
        reviewed = try offer()
        window.showPreview(of: address, engine: .webKit, in: window.personaID)
        expectDraft(reviewed)
        window.closePreview()

        let favorite = Favorite(url: address, title: "Saved plans", personaID: home.resolvedPersonaID)
        browser.addFavorites([favorite], in: home.resolvedPersonaID)
        let favoriteTab = browser.openTab(for: favorite)
        window.selectTab(favoriteTab.id)
        reviewed = try offer()
        let other = browser.makeSpace(in: home.resolvedPersonaID)
        window.switchToSpace(other.id)
        window.selectTab(favoriteTab.id)
        expectDraft(reviewed)
        reviewed = try offer()
        let elsewhere = browser.addPersona(named: "Elsewhere")
        window.switchToSpace(try #require(browser.spaces(in: elsewhere.id).first).id)
        expectDraft(reviewed)
        #expect(service.sessions.count == 2)
        await service.endSessionsForQuit()
    }

    @Test func aSidebarTabCanOpenALocalDraftBeforeConnectingAModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFirstDraft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let space = try #require(browser.spaces.first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let selected = browser.openTab(url: URL(string: "https://fixture.invalid/selected"), in: space.id, select: false)
        let requested = browser.openTab(url: URL(string: "https://fixture.invalid/background"), in: space.id, select: false)
        window.selectTab(selected.id)
        #expect(!window.canStartAgentTask && !window.canToggleAgentPanel && service.agentModels().isEmpty)
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: AIKeychain())
        let reviewed = try #require(window.sidebarAgentDraft(for: requested, settings: settings))
        window.askAgentAboutSidebarTab(requested, reviewed: reviewed, settings: settings)
        guard case .composer(let draft) = window.agentPanel else { Issue.record("Expected a local task draft"); return }
        #expect(draft.text.isEmpty && draft.tab?.id == requested.id && draft.tab?.documentID == reviewed.tab?.documentID)
        #expect(window.selectedTab === selected && service.sessions.isEmpty)
        #expect(window.canToggleAgentPanel)
        draft.text = "Compare these notes"
        window.toggleAgentPanel()
        #expect(window.agentPanel == nil && window.canToggleAgentPanel)
        window.switchToSpace(browser.makeSpace(in: window.personaID).id)
        #expect(!window.canToggleAgentPanel)
        window.switchToSpace(space.id)
        #expect(window.canToggleAgentPanel)
        window.toggleAgentPanel()
        #expect(window.agentPanel == .composer(draft) && draft.text == "Compare these notes" && service.sessions.isEmpty)
        // Switching Agent Tasks off hides the command.
        var switchedOff = settings.route(for: .agent)
        switchedOff.isEnabled = false
        settings.setRoute(switchedOff, for: .agent)
        #expect(window.sidebarAgentDraft(for: requested, settings: settings) == nil)
    }

    @Test func aMountedSidebarMenuFollowsSiteExclusionsInBothDirections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let space = try #require(browser.spaces.first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let url = try #require(URL(string: "https://fixture.invalid/note"))
        let tab = browser.openTab(url: url, in: space.id, select: false)
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: AIKeychain())
        let host = NSHostingController(rootView: Text("Fixture tab").frame(width: 200, height: 50).contentShape(Rectangle()).contextMenu {
            SidebarAgentMenuItem(windowModel: window, tab: tab, settings: settings)
            Button("Copy Address") {}
        })
        let native = NSWindow(contentViewController: host)
        native.setContentSize(NSSize(width: 200, height: 50))
        host.view.layoutSubtreeIfNeeded()
        for allowed in [true, false, true] {
            settings.setAllowsAI(allowed, on: url)
            var matched = false
            for _ in 0..<100 {
                host.view.layoutSubtreeIfNeeded()
                let point = NSPoint(x: host.view.bounds.midX, y: host.view.bounds.midY)
                let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: host.view.convert(point, to: nil),
                                                           modifierFlags: [], timestamp: 0, windowNumber: native.windowNumber,
                                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5))
                var hit = host.view.hitTest(point)
                while let view = hit {
                    if let menu = view.menu(for: event) {
                        menu.delegate?.menuNeedsUpdate?(menu)
                        menu.update()
                        if menu.item(withTitle: "Copy Address") != nil {
                            matched = (menu.item(withTitle: "Ask Agent About This Tab…") != nil) == allowed
                            break
                        }
                    }
                    hit = view.superview
                }
                if matched { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(matched, "The same sidebar menu should reflect the current site choice.")
        }
        #expect(!native.isVisible && window.agentPanel == nil && service.sessions.isEmpty)
    }

    @Test func aSidebarTabWhosePageChangedOpensItsDraftWithoutThePage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let space = try #require(browser.spaces.first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let tab = browser.openTab(url: URL(string: "https://fixture.invalid/page"), in: space.id, select: false)
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: AIKeychain())
        let reviewed = try #require(window.sidebarAgentDraft(for: tab, settings: settings))
        // The page commits another document while the menu shows.
        tab.webContents(tab.webContents, didCommitDocumentAt: tab.url)
        window.askAgentAboutSidebarTab(tab, reviewed: reviewed, settings: settings)
        guard case .composer(let draft) = window.agentPanel else { Issue.record("Expected a draft without the page"); return }
        #expect(draft.tab == nil && draft.problem != nil && service.sessions.isEmpty)
    }

    @Test func renamingTheDestinationWhileItsDraftIsOpenOrHiddenKeepsTheReviewedTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let persona = browser.addPersona(named: "Work")
        let space = try #require(browser.spaces.first { $0.resolvedPersonaID == persona.id })
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let tab = browser.openTab(url: URL(string: "https://fixture.invalid/reviewed"), in: space.id, select: false)
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: AIKeychain())
        let draft = try #require(window.sidebarAgentDraft(for: tab, settings: settings))
        window.askAgentAboutSidebarTab(tab, reviewed: draft, settings: settings)
        guard case .composer(let context) = window.agentPanel else { Issue.record("Expected the reviewed draft"); return }
        context.text = "Compare this report"
        context.attachesTab = false
        let reviewed = try #require(context.tab)
        #expect(service.agentModels().isEmpty && service.place(of: context) == "Work / \(space.name)")
        window.renameSpace(space.id, to: "Archive")
        #expect(service.place(of: context) == "Work / Archive")
        window.hideAgentPanel()
        browser.renamePersona(persona.id, to: "Research")
        window.toggleAgentPanel()
        #expect(window.agentPanel == .composer(context) && service.place(of: context) == "Research / Archive")
        #expect(context.text == "Compare this report" && context.tab == reviewed && !context.attachesTab)
        #expect(context.personaID == persona.id && context.spaceID == space.id && service.sessions.isEmpty)
        context.usesAgentsPersona = true
        #expect(service.place(of: context) == service.agentsPersonaPlace)
        context.usesAgentsPersona = false
        _ = browser.makeSpace(in: persona.id, named: "Other")
        browser.deleteSpace(space.id)
        #expect(window.agentPanel == nil && !window.canToggleAgentPanel)
        #expect(service.place(of: context) == context.place)
    }

    @Test func anOpenFavoritesDraftUsesTheReviewedDocumentAndSpace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let otherSpace = browser.makeSpace(in: home.resolvedPersonaID)
        let elsewhere = browser.addPersona(named: "Elsewhere")
        let away = try #require(browser.spaces(in: elsewhere.id).first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let favorite = Favorite(url: URL(string: "https://fixture.invalid/favorite")!, title: "Notes", personaID: home.resolvedPersonaID)
        browser.addFavorites([favorite], in: home.resolvedPersonaID)
        #expect(browser.favoriteTabs[favorite.id] == nil)
        let page = browser.openTab(for: favorite)
        let selected = browser.openTab(url: URL(string: "https://fixture.invalid/selected"), in: home.id, select: false)
        window.selectTab(selected.id)
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: AIKeychain())
        let reviewed = try #require(window.sidebarAgentDraft(for: page, settings: settings))
        window.switchToSpace(otherSpace.id)
        window.askAgentAboutSidebarTab(page, reviewed: reviewed, settings: settings)
        #expect(window.agentPanel == nil)
        window.switchToSpace(away.id)
        #expect(window.sidebarAgentDraft(for: page, settings: settings) == nil)
        window.switchToSpace(home.id)
        window.askAgentAboutSidebarTab(page, reviewed: reviewed, settings: settings)
        guard case .composer(let draft) = window.agentPanel else { Issue.record("Expected a draft for the open favorite"); return }
        #expect(draft.spaceID == home.id && draft.tab?.id == page.id && draft.tab?.documentID == reviewed.tab?.documentID)
        #expect(window.selectedTab === selected && service.sessions.isEmpty)
        window.hideAgentPanel()
        browser.closeFavorite(favorite)
        window.askAgentAboutSidebarTab(page, reviewed: reviewed, settings: settings)
        #expect(window.agentPanel == nil && browser.favoriteTabs[favorite.id] == nil)
    }

    @Test func reopeningThePanelKeepsItsUnsentDraftAndReviewedTabInTheSameWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let space = try #require(browser.spaces.first)
        let record = SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true)
        let window = BrowserWindowModel(session: browser, record: record, kind: .main)
        let tab = browser.openTab(url: URL(string: "https://fixture.invalid/reviewed"), in: space.id, select: false)
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: AIKeychain())
        let reviewed = try #require(window.sidebarAgentDraft(for: tab, settings: settings))
        window.askAgentAboutSidebarTab(tab, reviewed: reviewed, settings: settings)
        guard case .composer(let draft) = window.agentPanel else { Issue.record("Expected a reviewed draft"); return }
        draft.text = "Compare this with the earlier report"
        draft.attachesTab = false
        draft.mode = .readOnly
        window.hideAgentPanel()
        let other = BrowserWindowModel(session: browser, record: record, kind: .main)
        other.toggleAgentPanel()
        guard case .composer(let otherDraft) = other.agentPanel else { Issue.record("Expected the other window's composer"); return }
        #expect(otherDraft !== draft && otherDraft.text.isEmpty)
        window.toggleAgentPanel()
        guard case .composer(let resumed) = window.agentPanel else { Issue.record("Expected the draft to reopen"); return }
        #expect(resumed === draft && resumed.text == "Compare this with the earlier report")
        #expect(resumed.tab?.documentID == reviewed.tab?.documentID && !resumed.attachesTab && resumed.mode == .readOnly)
        #expect(service.sessions.isEmpty)

        window.hideAgentPanel()
        let anotherSpace = browser.makeSpace(in: space.resolvedPersonaID, named: "Separate")
        window.currentSpaceID = anotherSpace.id
        window.toggleAgentPanel()
        guard case .composer(let fresh) = window.agentPanel else { Issue.record("Expected a draft for the new space"); return }
        #expect(fresh.spaceID == anotherSpace.id && fresh.text.isEmpty)
        window.showAgentComposer(text: "New task")
        guard case .composer(let replacement) = window.agentPanel else { Issue.record("Expected a new draft"); return }
        #expect(replacement !== fresh && replacement.text == "New task")
        window.agentTaskDidStart(UUID(), from: replacement)
        window.hideAgentPanel()
        window.toggleAgentPanel()
        guard case .composer(let afterStart) = window.agentPanel else { Issue.record("Expected an empty composer"); return }
        #expect(afterStart !== replacement && afterStart.text.isEmpty)
        window.hideAgentPanel()
        window.currentSpaceID = space.id
        window.toggleAgentPanel()
        guard case .composer(let originalSpace) = window.agentPanel else { Issue.record("Expected the first space's draft"); return }
        #expect(originalSpace === draft && !originalSpace.attachesTab)
        browser.deleteSpace(space.id)
        #expect(window.agentPanel == nil)
        window.switchToSpace(anotherSpace.id)
        window.toggleAgentPanel()
        guard case .composer(let remaining) = window.agentPanel else { Issue.record("Expected a new composer in the surviving space"); return }
        #expect(remaining !== afterStart && remaining.text.isEmpty)
    }

    @Test func folderCommandsFollowOnlyTheReviewedSessionAndKeepUserTabs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFolderTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, host, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let other = browser.addPersona(named: "Elsewhere")
        let away = try #require(browser.spaces(in: other.id).first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        func start(_ task: String, in space: Space) throws -> AgentSession {
            try service.startSession(.init(task: task, personaID: space.resolvedPersonaID, spaceID: space.id, attachedTabIDs: [], mode: .readOnly,
                                           model: AIModelRef(provider: .init(rawValue: "local-fixture"), model: "folder"), effort: nil))
        }
        let url = try #require(URL(string: "https://fixture.invalid/research"))
        func open(for session: AgentSession) throws -> (AgentTabInfo, TabFolder) {
            let tab = try #require(host.openAgentTab(at: url, engine: .webKit, for: .init(id: session.id, spaceID: session.spaceID, folderName: session.title)))
            return (tab, try #require(browser.folders.first { $0.agentSessionID == session.id }))
        }
        let first = try start("Research home", in: home), second = try start("Research elsewhere", in: away)
        let (kept, oldFolder) = try open(for: first), (unrelated, otherFolder) = try open(for: second)
        #expect(first.isTurnRunning && second.isTurnRunning)
        await window.perform(.show, on: oldFolder, reviewed: first)
        #expect(window.agentPanel == .session(first.id))
        #expect(window.agentSession(of: otherFolder) == nil)
        await window.perform(.show, on: otherFolder, reviewed: second)
        #expect(window.agentPanel == .session(first.id))

        // An open menu or delete confirmation becomes stale after switching Persona or handing the folder back.
        window.switchToSpace(away.id)
        await window.perform(.stop, on: oldFolder, reviewed: first)
        await window.perform(.deleteSession, on: oldFolder, reviewed: first)
        #expect(service.session(withID: first.id) === first && first.isTurnRunning)
        window.switchToSpace(home.id)
        await window.perform(.stop, on: oldFolder, reviewed: first)
        try #require(await eventually { first.state == .stopped })
        #expect(first.statusText == "Stopped" && second.isTurnRunning)
        await window.perform(.keepTabs, on: oldFolder, reviewed: first)
        #expect(window.agentSession(of: oldFolder) == nil)
        #expect(browser.tabs.first { $0.id == kept.id }?.agentOwnerID == nil)
        let (toClose, replacement) = try open(for: first)
        await window.perform(.deleteSession, on: oldFolder, reviewed: first)
        await window.perform(.deleteSession, on: replacement, reviewed: second)
        #expect(service.session(withID: first.id) === first && replacement.id != oldFolder.id)
        await window.perform(.deleteSession, on: replacement, reviewed: first)
        #expect(service.session(withID: first.id) == nil && first.hasEnded)
        #expect(!browser.tabs.contains { $0.id == toClose.id } && !browser.folders.contains { $0.id == replacement.id })
        #expect(browser.tabs.contains { $0.id == kept.id && $0.agentOwnerID == nil })
        #expect(browser.folders.contains { $0.id == oldFolder.id && !$0.isAgentFolder })
        #expect(browser.tabs.contains { $0.id == unrelated.id && $0.agentOwnerID == second.id })
        #expect(!browser.hasClosedTabs && browser.undoableCloseCount == 0)
        await service.endSessionsForQuit()
        #expect(!browser.tabs.contains { $0.id == unrelated.id })
        #expect(browser.tabs.contains { $0.id == kept.id })
    }

    @Test func aSessionsToolsOpenItsFolderWhoseStepLineNamesTheWaitingCardAndADraggedOutTabIsTheUsers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSessionFolder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: StartedFolderClient())
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let page = browser.openTab(url: URL(string: "https://fixture.invalid/plans"), in: home.id, select: false)
        let session = try service.startSession(.init(task: "Research the plans", personaID: home.resolvedPersonaID, spaceID: home.id, attachedTabIDs: [page.id],
                                                     mode: .readOnly, model: StartedFolderClient.model, effort: nil))
        try #require(await eventually { session.model != nil })
        let tools = service.sessionTools(for: session)

        // open_tab, through the browser's host, opens the tab in the background in a folder named after the session in its space.
        let opening = Task { await tools.run(AgentToolCall(name: "open_tab", arguments: ["url": "https://fixture.invalid/"])) }
        try #require(await eventually { browser.tabs.contains { $0.agentOwnerID == session.id } })
        let tab = try #require(browser.tabs.first { $0.agentOwnerID == session.id })
        tab.webContentsDidFinishLoadingDocument(tab.webContents)
        let opened = await opening.value
        #expect(opened.status == .ok && window.selectedTabID != tab.id)
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let folder = try #require(browser.folders.first { $0.agentSessionID == session.id })
        #expect(folder.name == session.title && folder.spaceID == home.id && tab.folderID == folder.id)
        #expect(window.agentSession(of: folder) === session)

        // A written address no page showed waits on a card, whose step the line under the folder's row names.
        let navigation = Task { await tools.run(AgentToolCall(name: "navigate", arguments: ["tab": .string(handle), "url": "https://fixture.invalid/plans?d=1"])) }
        try #require(await eventually { service.approvals.pending.contains { $0.ownerID == session.id } })
        let card = try #require(service.approvals.pending.first { $0.ownerID == session.id })
        #expect(card.tabID == tab.id && card.action == "Open an address in \(handle)" && session.state == .waitingForUser)
        let step = try #require(SessionFolderStepLine.waitingStep(in: service.approvals, of: session.id))
        #expect(step.sentence == card.action && step.count == 1)

        // Dragging the tab out of the folder makes it the user's: the card is withdrawn, the folder goes with its last tab, and the handle is refused (P17).
        browser.moveOutOfFolder(tab)
        #expect(await navigation.value.status == .stale)
        #expect(tab.agentOwnerID == nil && !browser.folders.contains { $0.id == folder.id })
        #expect(!service.approvals.isPending(card.id) && session.state == .running)
        #expect(SessionFolderStepLine.waitingStep(in: service.approvals, of: session.id) == nil)
        let refused = await tools.run(AgentToolCall(name: "navigate", arguments: ["tab": .string(handle), "action": "reload"]))
        #expect(refused.code == "P17")
        await service.endSessionsForQuit()
        #expect(browser.tabs.contains { $0.id == tab.id })
    }

    @Test func panelKeepsOnlyTheReviewedFolderOfTheConversationStillShowing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, host, service) = try fixture(in: directory, client: WaitingFolderClient())
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        let selected = browser.openTab(url: URL(string: "about:blank#selected"), in: home.id, select: false)
        window.selectTab(selected.id)
        func start(_ name: String) throws -> AgentSession {
            try service.startSession(.init(task: name, personaID: home.resolvedPersonaID, spaceID: home.id, attachedTabIDs: [],
                                           mode: .readOnly, model: QuestionClient.model, effort: nil))
        }
        let researchURL = try #require(URL(string: "https://fixture.invalid/research"))
        func open(for owner: AgentSession) throws -> AgentTabInfo {
            try #require(host.openAgentTab(at: researchURL, engine: .webKit,
                                           for: .init(id: owner.id, spaceID: owner.spaceID, folderName: owner.title)))
        }
        let first = try start("First"), other = try start("Other")
        window.showAgentSession(first.id)
        #expect(window.panelKeepTabsAction == nil)
        let original = try open(for: first), unrelated = try open(for: other)
        let oldAction = try #require(window.panelKeepTabsAction)
        window.showAgentSession(other.id)
        oldAction()
        #expect(host.agentTabs(of: first.id).contains { $0.id == original.id })
        #expect(host.agentTabs(of: other.id).contains { $0.id == unrelated.id })

        window.showAgentSession(first.id)
        let keepOriginal = try #require(window.panelKeepTabsAction)
        keepOriginal()
        #expect(window.panelKeepTabsAction == nil && window.selectedTab === selected && window.agentPanel == .session(first.id))
        let replacement = try open(for: first)
        oldAction()
        #expect(host.agentTabs(of: first.id).contains { $0.id == replacement.id })
        let fresh = try #require(window.panelKeepTabsAction)
        fresh()
        #expect(host.agentTabs(of: first.id).isEmpty && host.agentTabs(of: other.id).contains { $0.id == unrelated.id })
        #expect(browser.tabs.contains { $0.id == replacement.id && $0.agentOwnerID == nil })
        #expect(window.panelKeepTabsAction == nil && window.selectedTab === selected && window.agentPanel == .session(first.id))
        await service.endSessionsForQuit()
    }

    @Test func spaceDotsTrackUnansweredCardsAcrossWindowsAndPersonas() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSpaceDots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: QuestionClient())
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let work = browser.addPersona(named: "Work")
        let office = try #require(browser.spaces(in: work.id).first)
        func start(in space: Space) throws -> AgentSession {
            try service.startSession(.init(task: "Review this", personaID: space.resolvedPersonaID, spaceID: space.id,
                                           attachedTabIDs: [], mode: .readOnly, model: QuestionClient.model, effort: nil))
        }
        let first = try start(in: home), second = try start(in: home), third = try start(in: office)
        // A space's dot shows while one of its sessions waits for an answer and the window is not on that space.
        #expect(service.spacesWaitingForUser.isEmpty)
        try #require(await eventually { service.approvals.pending.count == 3 })
        #expect(await eventually { service.spacesWaitingForUser == [home.id, office.id] })
        func answer(_ session: AgentSession) async throws {
            let card = try #require(service.approvals.pending.first { $0.ownerID == session.id })
            try #require(await service.approvals.answer(card.id, with: .answer("Continue")))
            try #require(await eventually { session.state == .running })
        }
        try await answer(third)
        #expect(await eventually { service.spacesWaitingForUser == [home.id] })
        try await answer(first)
        #expect(service.spacesWaitingForUser == [home.id])
        second.stop()
        #expect(await eventually { service.spacesWaitingForUser.isEmpty })
        #expect(service.approvals.pending.isEmpty && first.isTurnRunning && third.isTurnRunning)
        #expect(service.sessions.map(\.id) == [first.id, second.id, third.id])
        await service.endSessionsForQuit()
    }

    @Test func notificationsRaiseTheWaitingOwnerWithoutNavigatingOtherWindows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchNotificationWindows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, host, service) = try fixture(in: directory, client: QuestionClient())
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let work = browser.addPersona(named: "Work")
        let office = try #require(browser.spaces(in: work.id).first)
        func window(in space: Space, kind: BrowserWindowKind) -> BrowserWindowModel {
            browser.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: kind == .main), kind: kind)
        }
        let main = window(in: home, kind: .main), small = window(in: office, kind: .small)
        defer {
            for window in [small, main] where browser.windows.contains(where: { $0 === window }) { browser.windowWillClose(window) }
        }
        let front = RaisingWindow(), popup = RaisingWindow()
        main.nsWindow = front
        small.nsWindow = popup
        let mainTab = browser.openTab(url: URL(string: "about:blank#home"), in: home.id, select: false, engine: .webKit)
        let smallTab = browser.openTab(url: URL(string: "about:blank#work"), in: office.id, select: false, engine: .webKit)
        smallTab.isInSmallWindow = true
        main.selectTab(mainTab.id)
        small.selectTab(smallTab.id)
        browser.windowDidBecomeMain(main)
        main.showAgentComposer(text: "Unsent research draft")
        let draft = main.agentPanel

        let session = try service.startSession(.init(task: "Ask a question", personaID: home.resolvedPersonaID, spaceID: home.id,
                                                     attachedTabIDs: [], mode: .readOnly, model: QuestionClient.model, effort: nil))
        try #require(await eventually { session.state == .waitingForUser })
        // The Home session opens in the Home main window, whose draft stays kept, and the Work small window keeps its page.
        browser.showWaitingAgent(session.id)
        #expect(front.raises == 1 && popup.raises == 0 && main.agentPanel == .session(session.id) && draft != nil)
        #expect(small.agentPanel == nil && small.selectedTab === smallTab && small.currentSpaceID == office.id)
        main.hideAgentPanel()
        browser.showWaitingAgent(session.id)
        #expect(front.raises == 2 && popup.raises == 0 && main.agentPanel == .session(session.id))
        let question = try #require(service.approvals.pending.first { $0.ownerID == session.id })
        try #require(await service.approvals.answer(question.id, with: .answer("Continue")))
        main.hideAgentPanel()
        browser.showWaitingAgent(session.id)
        #expect(small.agentPanel == nil && main.agentPanel == nil && popup.raises == 0 && front.raises == 2)

        // A previous client owns the selected tab. The notification must show the client whose card is pending.
        let previous = UUID(), waiting = UUID()
        for (id, name) in [(previous, "Previous client"), (waiting, "Waiting client")] {
            service.panel.describe(.init(name: name, access: "Read Only", place: "Home"), for: id)
        }
        let owned = try #require(host.openAgentTab(at: URL(string: "https://fixture.invalid/previous")!, engine: .webKit,
                                                  for: .init(id: previous, spaceID: home.id, folderName: "Previous client")))
        main.selectTab(owned.id)
        main.showAgentComposer(text: "Keep while a client asks")
        let clientDraft = main.agentPanel
        let card = AgentApproval(ownerID: waiting, clientName: "Waiting client", isOutsideClient: true, kind: .question([]), isSensitive: false,
                                 offers: [.deny], action: "Question", createdAt: .now, deadline: .now.addingTimeInterval(60))
        service.approvals.open(card) { _ in }
        #expect(main.agentPanel == clientDraft)
        browser.showWaitingAgent(waiting)
        #expect(small.agentPanel == .client(waiting) && main.agentPanel == clientDraft && popup.raises == 1 && front.raises == 2)
        small.showAgentSession(session.id)
        // Both panels are occupied, so the explicit click opens the waiting client in the active window.
        browser.showWaitingAgent(waiting)
        #expect(front.raises == 3 && popup.raises == 1 && main.agentPanel == .client(waiting))
        #expect(main.selectedTabID == owned.id && main.currentSpaceID == home.id && small.agentPanel == .session(session.id))
        main.selectTab(owned.id)
        #expect(main.agentPanel == .client(waiting))
        main.selectTab(mainTab.id)
        main.selectTab(owned.id)
        #expect(main.agentPanel == .client(previous))
        service.approvals.end(card.id, because: "Client left")
        browser.showWaitingAgent(waiting)
        #expect(main.agentPanel == .client(previous) && front.raises == 3 && popup.raises == 1)
        await service.endSessionsForQuit()
    }
}

@MainActor private final class RaisingWindow: NSWindow {
    var raises = 0
    override func makeKeyAndOrderFront(_ sender: Any?) { raises += 1 }
}

private actor UnusedFolderKeys: AgentSealKeyStore {
    func key() throws -> AgentSealKey? { throw CancellationError() }
    func keyCreatingIfNeeded() throws -> AgentSealKey { throw CancellationError() }
    func record(_ key: AgentSealKey) throws { throw CancellationError() }
}

private struct WaitingFolderClient: AIClient {
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { _ in }
    }
}

/// The model starts its reply and keeps the turn open, so that the session's calls run.
private struct StartedFolderClient: AIClient {
    static let model = AIModelRef(provider: .init(rawValue: "local-fixture"), model: "folder")

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(Self.model))
            continuation.yield(.text("Working"))
        }
    }
}

/// Each session's first round asks once. Its reply stays open after the answer so the dot must clear within the same turn.
private struct QuestionClient: AIClient {
    static let model = AIModelRef(provider: .init(rawValue: "local-fixture"), model: "question")

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(Self.model))
            if request.messages.count == 1 {
                let call = AIToolCall(id: "ask", name: "ask_user", arguments: Data(#"{"question":"Continue?"}"#.utf8))
                continuation.yield(.toolCall(call))
                continuation.yield(.finished(.toolUse))
                continuation.finish()
            } else {
                continuation.yield(.text("Continuing"))
            }
        }
    }
}
