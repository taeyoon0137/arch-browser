// What each kind of tab prompt says and offers, and what each answer means for the code that asked: page dialogs keep the page's words apart, a login keeps its fields and notes, Open and Allow wait to arm, Clear is destructive, a page's downloads question names its host or file, and a prompt that ended without the user gives the safe answer.
import AppKit
import ARCHEngine
import Extensions
import Foundation
import Testing
@testable import Browsing

@Suite struct TabPromptContentTests {
    private static let site = PromptIdentity(icon: .symbol("globe"), name: "example.com", isSecure: true)

    private static func answered(_ id: String, _ values: [String: String] = [:]) -> PromptResponse {
        .answered(PromptAnswer(buttonID: id, fieldValues: values))
    }

    @Test func pageDialogsKeepThePagesWordsUnderItsSite() {
        let alert = TabPromptContent.alert(message: "Saved", identity: Self.site)
        #expect(alert.kind == .pageAlert && alert.kind.isPageDialog)
        #expect(alert.title == nil && alert.glyph == nil && alert.pageText == PageAuthoredText(text: "Saved"))
        #expect(alert.buttons.map(\.id) == ["ok"] && alert.defaultButtonID == "ok" && alert.cancelButtonID == "ok")
        #expect(TabPromptContent.alert(message: "", identity: Self.site).pageText == nil)

        let confirm = TabPromptContent.confirm(message: "Delete?", identity: Self.site)
        #expect(confirm.buttons.map(\.title) == ["Cancel", "OK"] && confirm.defaultButtonID == "ok" && confirm.cancelButtonID == "cancel")
        #expect(TabPromptContent.confirmResult(Self.answered("ok")))
        #expect(!TabPromptContent.confirmResult(Self.answered("cancel")))
        #expect(!TabPromptContent.confirmResult(.dismissed))

        let input = TabPromptContent.textInput(message: "Name?", defaultText: "Ada", identity: Self.site)
        #expect(input.kind == .pageTextInput)
        #expect(input.fields == [PromptField(id: "text", kind: .text, label: "Answer", initialValue: "Ada")])
        #expect(input.focusedFieldID == "text")
        #expect(TabPromptContent.textInputResult(Self.answered("ok", ["text": "Grace"])) == "Grace")
        #expect(TabPromptContent.textInputResult(Self.answered("cancel", ["text": "Grace"])) == nil)
        #expect(TabPromptContent.textInputResult(.dismissed) == nil)
        #expect(!input.buttons.contains { $0.needsArming })
    }

    @Test func onlyStayKeepsAPageThatAsksBeforeItIsLeft() {
        let content = TabPromptContent.leavePage(identity: Self.site)
        #expect(!content.kind.isPageDialog)
        #expect(content.title == "Leave this page?" && content.message == "Changes you made may not be saved.")
        #expect(content.buttons.map(\.title) == ["Stay", "Leave"] && content.defaultButtonID == "leave" && content.cancelButtonID == "stay")
        #expect(!TabPromptContent.leavePageResult(Self.answered("stay")))
        #expect(TabPromptContent.leavePageResult(Self.answered("leave")))
        #expect(TabPromptContent.leavePageResult(.dismissed))
    }

    @Test func aLoginKeepsItsFieldsNotesAndCredentialForTheSession() throws {
        let space = URLProtectionSpace(host: "intranet.example", port: 80, protocol: "http", realm: "Staff", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let first = TabPromptContent.signIn(space, proposedUser: nil, failed: false, identity: Self.site)
        #expect(first.title == "Log In to This Website")
        #expect(first.pageText == PageAuthoredText(caption: "The website says", text: "Staff"))
        #expect(first.fields.map(\.kind) == [.userName, .password])
        #expect(first.focusedFieldID == "user")
        #expect(first.notes.map(\.id) == ["unencrypted"])
        #expect(!first.shakesOnArrival && !first.buttons.contains { $0.needsArming })
        #expect(first.defaultButtonID == "logIn" && first.cancelButtonID == "cancel")

        let again = TabPromptContent.signIn(space, proposedUser: "ada", failed: true, identity: Self.site)
        #expect(again.focusedFieldID == "password")
        #expect(again.fields.first?.initialValue == "ada")
        #expect(again.notes.map(\.tone) == [.error, .warning])
        #expect(again.shakesOnArrival)

        let proxy = URLProtectionSpace(proxyHost: "proxy.example", port: 8080, type: NSURLProtectionSpaceHTTPSProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        let proxyContent = TabPromptContent.signIn(proxy, proposedUser: nil, failed: false, identity: Self.site)
        #expect(proxyContent.title == "Log In to This Proxy" && proxyContent.pageText == nil)
        #expect(proxyContent.focusedFieldID == "user")

        // A server other than the tab's site, as for an image from another site, gets no keys meant for the page: the card itself takes the focus.
        var otherSite = Self.site
        otherSite.context = "in example.com"
        #expect(TabPromptContent.signIn(space, proposedUser: nil, failed: false, identity: otherSite).focusedFieldID == nil)
        #expect(TabPromptContent.signIn(space, proposedUser: "ada", failed: false, identity: otherSite).focusedFieldID == nil)

        let credential = try #require(TabPromptContent.signInCredential(Self.answered("logIn", ["user": "ada", "password": "pw"])))
        #expect(credential.user == "ada" && credential.password == "pw" && credential.persistence == .forSession)
        #expect(TabPromptContent.signInCredential(Self.answered("cancel", ["user": "ada"])) == nil)
        #expect(TabPromptContent.signInCredential(.dismissed) == nil)
    }

    @Test func openingAnotherAppWaitsToArmAndOnlyCancelIsADecline() {
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let content = TabPromptContent.openInApp(appName: "Mail", appIcon: icon, hasHost: true, identity: Self.site)
        #expect(content.title == "Open \u{201C}Mail\u{201D}?")
        #expect(content.message == "This website wants to open a link in Mail.")
        #expect(content.glyph == .appIcon(icon, label: "Mail"))
        #expect(content.buttons.first { $0.id == "open" }?.needsArming == true)
        #expect(TabPromptContent.openInApp(appName: "Mail", appIcon: icon, hasHost: false, identity: Self.site).message == "This page wants to open a link in Mail.")
        #expect(TabPromptContent.openInAppResult(Self.answered("open")) == .open)
        #expect(TabPromptContent.openInAppResult(Self.answered("cancel")) == .decline)
        #expect(TabPromptContent.openInAppResult(.dismissed) == .none)
    }

    @Test func clearSiteDataNamesThePersonaOnlyWithSeveralPersonas() {
        let alone = TabPromptContent.clearSiteData(persona: nil, identity: Self.site)
        #expect(alone.identity == Self.site)
        #expect(alone.message == "Its cookies and other website data are removed from both engines, which signs you out of the website. Its open tabs load again.")
        let several = TabPromptContent.clearSiteData(persona: "the Persona of \u{201C}Work / Research\u{201D}", identity: Self.site)
        #expect(several.identity == Self.site)
        #expect(several.message == "Its cookies and other website data are removed from both engines in the Persona of \u{201C}Work / Research\u{201D}, which signs you out of the website. Its open tabs load again.")
        #expect(several.buttons.map(\.title) == ["Clear", "Cancel"])
        #expect(several.glyph == .symbol("trash.fill", tint: .red, label: "Clear Site Data"))
    }

    @Test func aNoticeShowsAPathWholeOnlyInItsTooltip() {
        let notice = TabPromptContent.notice(title: "The PDF could not be saved.", detail: "/Users/a/b.pdf", detailIsPath: true, identity: Self.site)
        #expect(notice.messageStyle == .path && notice.message == "/Users/a/b.pdf")
        #expect(notice.buttons.map(\.id) == ["ok"] && notice.defaultButtonID == "ok" && notice.cancelButtonID == "ok")
        #expect(TabPromptContent.notice(title: "The page could not be captured.", detail: nil, identity: Self.site).messageStyle == .text)
    }

    @Test func aPagesDownloadsQuestionNamesItsHostOrFileAndWaitsToArm() throws {
        let page = TabPromptContent.pageDownloads(identity: Self.site)
        #expect(page.kind == .pageDownloads && page.identity == Self.site)
        #expect(page.title == "Allow this page to download multiple files?")
        #expect(page.message == "This page started another download on its own. If you allow it, it can download files until it loads another page.")
        #expect(page.buttons.map(\.title) == ["Don\u{2019}t Allow", "Allow"] && page.buttons.last?.needsArming == true)
        #expect(page.defaultButtonID == "allow" && page.cancelButtonID == "deny")
        #expect(TabPromptContent.pageDownloadsResult(Self.answered("allow")))
        #expect(!TabPromptContent.pageDownloadsResult(Self.answered("deny")))
        #expect(!TabPromptContent.pageDownloadsResult(.dismissed))

        let file = try #require(URL(string: "file:///Users/a/Report.html"))
        let filePage = TabPromptContent.pageDownloads(identity: PromptSiteIdentity.make(for: file, tabURL: file, favicon: nil))
        #expect(filePage.identity.name == "Report.html" && filePage.title == "Allow this page to download multiple files?")
        let blank = TabPromptContent.pageDownloads(identity: PromptSiteIdentity.make(for: nil, tabURL: nil, favicon: nil))
        #expect(blank.identity.name == "This page")
    }

    @Test func extensionsQuestionsNameTheExtensionAndWaitToArm() {
        let access = WebExtensionQuestion(kind: .access, extensionName: "Reader", version: .chromium, items: ["Read your browsing history"],
                                          keeps: "Only the Chromium version gets this access.", confirmsNext: true)
        let content = TabPromptContent.extensionQuestion(access, icon: nil, identity: Self.site)
        #expect(content.kind == .extensionAccess)
        #expect(content.identity == PromptIdentity(icon: .symbol("puzzlepiece.extension"), name: "Reader", isSecure: false, tag: "Chromium version"))
        #expect(content.title == "Allow this extension more access?" && content.items == ["Read your browsing history"])
        #expect(content.notes.map(\.symbol) == ["clock", "touchid"])
        #expect(content.buttons.map(\.title) == ["Don\u{2019}t Allow", "Allow"] && content.buttons.last?.needsArming == true)
        #expect(TabPromptContent.extensionAnswer(Self.answered("allow")))
        #expect(!TabPromptContent.extensionAnswer(Self.answered("deny")))
        #expect(!TabPromptContent.extensionAnswer(.dismissed))

        let reload = TabPromptContent.extensionQuestion(WebExtensionQuestion(kind: .reload, extensionName: "", message: "\u{201C}A\u{201D} can run on this page once it loads again."),
                                                        icon: nil, identity: Self.site)
        #expect(reload.kind == .extensionReload && reload.identity == Self.site)
        #expect(reload.title == "Reload this page?" && reload.message == "\u{201C}A\u{201D} can run on this page once it loads again.")
        #expect(TabPromptContent.extensionAnswer(Self.answered("reload")))
        #expect(!TabPromptContent.extensionAnswer(Self.answered("cancel")))
    }
}
