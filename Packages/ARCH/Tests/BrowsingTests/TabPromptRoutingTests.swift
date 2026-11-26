// A tab asks its prompts through the session's card callback: a page's own dialogs under the site of the document the main frame last committed with the answer the card gives, a frame's on another host captioned with that host and those of a frame without a host as an embedded page's, a login under its server with a credential for the session, a link for another app whose Cancel the site keeps and whose dismissal it does not, and the safe answer when no card can show. The tab's page is a stand-in, so no engine starts, and no test answers Open, so no app opens.
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct TabPromptRoutingTests {
    private static func tab() -> Tab {
        Tab(id: UUID(), webContents: UnloadedWebContents(url: URL(string: "https://example.com/form"), title: "Form", engine: .chromium, state: nil),
            spaceID: UUID(), isPinned: false, personaID: UUID())
    }

    /// Keeps the prompts the tab asked for and answers the oldest one still waiting.
    @MainActor private final class PromptRecorder {
        private(set) var contents: [PromptContent] = []
        private var waiting: [(PromptResponse) -> Void] = []

        func attach(to tab: Tab) {
            tab.presentPrompt = { [weak self] content, completion in
                self?.contents.append(content)
                self?.waiting.append(completion)
            }
        }

        func respond(_ response: PromptResponse) {
            waiting.removeFirst()(response)
        }
    }

    @Test func committedDocumentsGetDistinctIdentitiesEvenAtTheSameAddress() {
        let tab = Self.tab()
        let page = URL(string: "https://example.com/form")
        tab.webContents(tab.webContents, didCommitDocumentAt: page)
        let first = BrowserAgentHost.info(of: tab)
        tab.webContentsDidChangeTitle(tab.webContents)
        #expect(BrowserAgentHost.info(of: tab).documentID == first.documentID)
        tab.webContents(tab.webContents, didCommitDocumentAt: page)
        #expect(BrowserAgentHost.info(of: tab).documentID != first.documentID)
    }

    @Test func outstandingSitePermissionEndsWithTheDocumentAndAnOldCardCannotRememberAnAnswer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let site = try #require(URL(string: "https://example.org/page"))
        let origin = try #require(SitePermissionStore.origin(of: site))
        let tab = session.openTab(url: site, in: session.spaces[0].id, select: false)
        let page = tab.webContents
        tab.webContents(page, didCommitDocumentAt: site)
        let request = EnginePermissionRequest(origin: site, types: [.clipboard])
        var answers: [Bool] = []
        func requestClipboard() {
            tab.webContents(page, requestPermission: request) { answers.append($0) }
        }
        requestClipboard()
        requestClipboard()
        let old = try #require(session.prompts.current(for: tab.id))
        #expect(session.prompts.waiting[tab.id]?.count == 1)

        // A move within the Persona keeps the same page. Reloading the same address ends it.
        let destination = session.makeSpace(in: tab.personaID, named: "Later")
        session.moveTab(tab.id, toSpace: destination.id)
        #expect(session.prompts.current(for: tab.id)?.id == old.id)
        let notice = TabPromptContent.notice(title: "Download finished", detail: nil, identity: old.content.identity)
        session.enqueuePrompt(notice, for: tab) { _ in }
        tab.webContents(page, didCommitDocumentAt: site)
        #expect(answers == [false, false])
        #expect(!session.prompts.contains(old.id))
        let kept = try #require(session.prompts.current(for: tab.id))
        #expect(kept.content.kind == .notice)
        session.prompts.answer(kept.id, with: PromptAnswer(buttonID: "ok"))
        session.prompts.answer(old.id, with: PromptAnswer(buttonID: "allow"))
        #expect(session.sitePermissions.decision(for: .clipboard, origin: origin, in: Persona.defaultID) == nil)

        requestClipboard()
        let fresh = try #require(session.prompts.current(for: tab.id))
        #expect(fresh.id != old.id)
        session.prompts.answer(fresh.id, with: PromptAnswer(buttonID: "deny"))
        #expect(answers == [false, false, false])
        #expect(session.sitePermissions.decision(for: .clipboard, origin: origin, in: Persona.defaultID) == .deny)
    }

    /// A web or file link clicked with Command or the middle button goes back to the engine on both engines, which opens it in a new web contents with the page's referrer and reports it as the page's new tab. A tab without the session's callback lets the engine load it in place, and an agent's tab opens none.
    @Test func modifiedLinksGoBackToTheEngineOnBothEngines() throws {
        let link = try #require(URL(string: "https://example.org/next"))
        let file = URL(fileURLWithPath: "/private/tmp/next.html")
        for engine in [EngineKind.chromium, .webKit] {
            let page = UnloadedWebContents(url: link, title: "", engine: engine, state: nil)
            let tab = Tab(id: UUID(), webContents: page, spaceID: UUID(), isPinned: false, personaID: UUID())
            let actions = [EngineNavigationDisposition.newBackgroundTab, .newForegroundTab].flatMap { disposition in
                [link, file].map { EngineNavigationAction(url: $0, disposition: disposition, isUserInitiated: true, opensLinkInNewTab: true) }
            }
            #expect(actions.allSatisfy { tab.webContents(page, decidePolicyFor: $0) == .allow })
            tab.openNewTab = { _, _, _, _ in Issue.record("The engine reports the new tab") }
            #expect(actions.allSatisfy { tab.webContents(page, decidePolicyFor: $0) == .openLinkInNewTab })
            // An ordinary target=_blank link is adopted as the engine's popup, with its opener intact.
            let popup = EngineNavigationAction(url: link, disposition: .newForegroundTab, isUserInitiated: true)
            #expect(tab.webContents(page, decidePolicyFor: popup) == .allow)
            tab.folderID = UUID()
            tab.agentOwnerOfFolder = { _ in UUID() }
            #expect(actions.allSatisfy { tab.webContents(page, decidePolicyFor: $0) == .cancel })
        }
    }

    /// The tab that the engine reports for such a link opens alike on both engines: behind the page, unread, in its space, with the page as its opener, or with Shift as well in front in the window that shows the page.
    @Test func aModifiedLinksTabOpensAlikeOnBothEngines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine(kind: .chromium))
        registry.register(SessionTestEngine(kind: .webKit))
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { for window in session.windows { session.windowWillClose(window) } }
        let link = try #require(URL(string: "https://example.org/next"))
        for engine in [EngineKind.chromium, .webKit] {
            let source = session.openTab(url: URL(string: "https://example.org/"), in: space.id, select: false, engine: engine)
            window.selectTab(source.id)
            let click = EngineNavigationAction(url: link, disposition: .newBackgroundTab, isUserInitiated: true, opensLinkInNewTab: true)
            #expect(source.webContents(source.webContents, decidePolicyFor: click) == .openLinkInNewTab)

            let behind = PageDouble(url: link, engine: engine)
            source.webContents(source.webContents, didCreateNewWebContents: behind, targetURL: link, disposition: .newBackgroundTab)
            let behindTab = try #require(session.tabs.first { $0.webContents === behind })
            #expect(behindTab.opener === source.webContents && behindTab.isUnread && behindTab.spaceID == space.id && behindTab.personaID == source.personaID)
            #expect(session.tabs.last === behindTab && window.selectedTabID == source.id)

            let front = PageDouble(url: link, engine: engine)
            source.webContents(source.webContents, didCreateNewWebContents: front, targetURL: link, disposition: .newForegroundTab)
            let frontTab = try #require(session.tabs.first { $0.webContents === front })
            #expect(frontTab.opener === source.webContents && !frontTab.isUnread && frontTab.spaceID == space.id)
            #expect(session.tabs.last === frontTab && window.selectedTabID == frontTab.id)
        }
    }

    @Test func aPagesDialogsAskUnderThePagesSiteAndTakeTheCardsAnswer() {
        let tab = Self.tab()
        let prompts = PromptRecorder()
        prompts.attach(to: tab)
        var log: [String] = []

        let page = URL(string: "https://example.com")
        tab.webContents(tab.webContents, didCommitDocumentAt: URL(string: "https://example.com/form"))
        tab.webContents(tab.webContents, runJavaScriptAlert: "Saved", frameOrigin: page) { log.append("alert") }
        tab.webContents(tab.webContents, runJavaScriptConfirm: "Delete?", frameOrigin: URL(string: "https://example.com:443")) { log.append("confirm \($0)") }
        tab.webContents(tab.webContents, runJavaScriptPrompt: "Name?", defaultText: "Ada", frameOrigin: URL(string: "https://EXAMPLE.com")) { log.append("prompt \($0 ?? "nil")") }
        #expect(prompts.contents.map(\.kind) == [.pageAlert, .pageConfirm, .pageTextInput])
        #expect(prompts.contents.allSatisfy { $0.pageText?.caption == nil && $0.pageText?.author == nil })
        #expect(prompts.contents.allSatisfy { $0.identity.name == "example.com" && $0.identity.isSecure && $0.title == nil })
        #expect(prompts.contents.map { $0.pageText?.text } == ["Saved", "Delete?", "Name?"])
        #expect(prompts.contents.last?.fields.first?.initialValue == "Ada")

        prompts.respond(.answered(PromptAnswer(buttonID: "ok")))
        prompts.respond(.dismissed)
        prompts.respond(.answered(PromptAnswer(buttonID: "ok", fieldValues: ["text": "Grace"])))
        #expect(log == ["alert", "confirm false", "prompt Grace"])
    }

    /// Words from a frame on another host carry that host above them, and words from a frame whose origin the engine does not name, as an `about:blank` frame on Chromium, say they are an embedded page's, so an embedded page cannot pass them off as the page's; the card still names the page's site.
    @Test func aFrameOfAnotherHostIsNamedAboveItsWords() {
        let tab = Self.tab()
        let prompts = PromptRecorder()
        prompts.attach(to: tab)
        tab.webContents(tab.webContents, didCommitDocumentAt: URL(string: "https://example.com/form"))
        let widget = URL(string: "https://widget.example")
        tab.webContents(tab.webContents, runJavaScriptAlert: "You won", frameOrigin: widget) {}
        tab.webContents(tab.webContents, runJavaScriptConfirm: "Pay now?", frameOrigin: URL(string: "https://shop.example.com")) { _ in }
        tab.webContents(tab.webContents, runJavaScriptPrompt: "Card number?", defaultText: nil, frameOrigin: widget) { _ in }
        tab.webContents(tab.webContents, runJavaScriptAlert: "Session expired", frameOrigin: nil) {}
        #expect(prompts.contents.allSatisfy { $0.identity.name == "example.com" })
        #expect(prompts.contents.map { $0.pageText?.caption } == ["An embedded page on \u{201C}widget.example\u{201D} says", "An embedded page on \u{201C}shop.example.com\u{201D} says",
                                                                  "An embedded page on \u{201C}widget.example\u{201D} says", "An embedded page says"])
        #expect(prompts.contents.map { $0.pageText?.author } == ["widget.example", "shop.example.com", "widget.example", "an embedded page"])
    }

    /// A dialog names the document the main frame last committed, not the address the tab already has for a navigation the page started, as WebKit gives it; before the first document, the frame's own site.
    @Test func aDialogNamesTheCommittedPageNotAnAddressThePageLoads() {
        let tab = Tab(id: UUID(), webContents: UnloadedWebContents(url: URL(string: "https://bank.example/slow"), title: "", engine: .webKit, state: nil),
                      spaceID: UUID(), isPinned: false, personaID: UUID())
        let prompts = PromptRecorder()
        prompts.attach(to: tab)
        let evil = URL(string: "https://evil.example")
        tab.webContents(tab.webContents, runJavaScriptPrompt: "Password?", defaultText: nil, frameOrigin: evil) { _ in }
        tab.webContents(tab.webContents, didCommitDocumentAt: URL(string: "https://evil.example/start"))
        tab.webContents(tab.webContents, runJavaScriptPrompt: "Password?", defaultText: nil, frameOrigin: evil) { _ in }
        #expect(tab.url?.host == "bank.example")
        #expect(prompts.contents.map(\.identity.name) == ["evil.example", "evil.example"])
        #expect(prompts.contents.allSatisfy { $0.pageText?.caption == nil })
    }

    @Test func aLeavePageCheckLeavesUnlessTheUserStays() {
        let tab = Self.tab()
        let prompts = PromptRecorder()
        prompts.attach(to: tab)
        var selections = 0
        tab.requestSelection = { selections += 1 }
        var answers: [Bool] = []

        tab.webContents(tab.webContents, runBeforeUnloadPanel: "Ignored") { answers.append($0) }
        tab.webContents(tab.webContents, runBeforeUnloadPanel: "Ignored") { answers.append($0) }
        #expect(selections == 2)
        #expect(prompts.contents.first?.kind == .leavePage && prompts.contents.first?.pageText == nil)
        prompts.respond(.answered(PromptAnswer(buttonID: "stay")))
        prompts.respond(.dismissed)
        #expect(answers == [false, true])
    }

    @Test func withoutACardAPageGetsTheSafeAnswer() {
        let tab = Self.tab()
        var log: [String] = []
        tab.webContents(tab.webContents, runJavaScriptConfirm: "Delete?", frameOrigin: nil) { log.append("confirm \($0)") }
        tab.webContents(tab.webContents, runJavaScriptPrompt: "Name?", defaultText: nil, frameOrigin: nil) { log.append("prompt \($0 ?? "nil")") }
        tab.webContents(tab.webContents, runBeforeUnloadPanel: "") { log.append("leave \($0)") }
        #expect(log == ["confirm false", "prompt nil", "leave true"])
    }

    /// A challenge's sender, which the tab never calls: it answers through its completion.
    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    @Test func aLoginAsksUnderItsServerAndGivesACredentialForTheSession() throws {
        let tab = Self.tab()
        let prompts = PromptRecorder()
        prompts.attach(to: tab)
        let space = URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: "Staff", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: URLCredential(user: "ada", password: "", persistence: .none),
                                                   previousFailureCount: 1, failureResponse: nil, error: nil, sender: ChallengeSender())
        var credentials: [URLCredential?] = []
        tab.webContents(tab.webContents, didReceiveAuthenticationChallenge: challenge) { credentials.append($0) }
        tab.webContents(tab.webContents, didReceiveAuthenticationChallenge: challenge) { credentials.append($0) }

        let content = try #require(prompts.contents.first)
        #expect(content.kind == .signIn && content.identity.name == "example.com" && content.identity.isSecure)
        #expect(content.fields.map(\.initialValue) == ["ada", ""] && content.focusedFieldID == "password")
        #expect(content.notes.map(\.id) == ["failed"] && content.shakesOnArrival)
        prompts.respond(.answered(PromptAnswer(buttonID: "logIn", fieldValues: ["user": "ada", "password": "pw"])))
        prompts.respond(.dismissed)
        #expect(credentials.count == 2)
        #expect(credentials.first??.password == "pw" && credentials.first??.persistence == .forSession)
        #expect(credentials.last! == nil)
    }

    @Test func aLinkForAnotherAppAsksOnceAndOnlyCancelSilencesTheSite() throws {
        let link = URL(string: "mailto:someone@example.com")!
        // A Mac without an app for mail links asks nothing.
        guard NSWorkspace.shared.urlForApplication(toOpen: link) != nil else { return }
        let tab = Self.tab()
        let prompts = PromptRecorder()
        prompts.attach(to: tab)

        tab.webContents(tab.webContents, openExternally: link, isUserInitiated: false)
        tab.webContents(tab.webContents, openExternally: link, isUserInitiated: false)
        let content = try #require(prompts.contents.first)
        #expect(prompts.contents.count == 1)
        #expect(content.kind == .openInApp && content.message?.hasPrefix("This website wants to open a link in ") == true)
        #expect(content.buttons.first { $0.id == "open" }?.needsArming == true)

        // A card that ended without the user leaves the site free to ask again.
        prompts.respond(.dismissed)
        tab.webContents(tab.webContents, openExternally: link, isUserInitiated: false)
        #expect(prompts.contents.count == 2)

        // Cancel silences the site's own requests, but not a link the user clicks.
        prompts.respond(.answered(PromptAnswer(buttonID: "cancel")))
        tab.webContents(tab.webContents, openExternally: link, isUserInitiated: false)
        #expect(prompts.contents.count == 2)
        tab.webContents(tab.webContents, openExternally: link, isUserInitiated: true)
        #expect(prompts.contents.count == 3)
        prompts.respond(.dismissed)
    }
}
