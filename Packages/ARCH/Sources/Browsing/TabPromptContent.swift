// The content of each kind of tab prompt except site permissions (`SitePermissionAnswers`), and what each answer means for the code that asked. Pages' own words go in `pageText`, apart from Arch's.
import AppKit
import ARCHEngine
import Extensions
import Foundation

enum TabPromptContent {
    // MARK: Page dialogs

    /// A page's `alert`: its words under the page's site, with OK.
    static func alert(message: String, identity: PromptIdentity) -> PromptContent {
        PromptContent(kind: .pageAlert, identity: identity, pageText: pageText(message),
                      buttons: [PromptButton(id: "ok", title: "OK")], defaultButtonID: "ok", cancelButtonID: "ok")
    }

    /// A page's `confirm`: OK answers true, anything else false.
    static func confirm(message: String, identity: PromptIdentity) -> PromptContent {
        PromptContent(kind: .pageConfirm, identity: identity, pageText: pageText(message),
                      buttons: [PromptButton(id: "cancel", title: "Cancel"), PromptButton(id: "ok", title: "OK")], defaultButtonID: "ok", cancelButtonID: "cancel")
    }

    /// A page's `prompt`: a field that starts with the page's default text, which OK returns. The text is selected as the field takes the focus.
    static func textInput(message: String, defaultText: String?, identity: PromptIdentity) -> PromptContent {
        var content = confirm(message: message, identity: identity)
        content.kind = .pageTextInput
        content.fields = [PromptField(id: "text", kind: .text, label: "Answer", initialValue: defaultText ?? "")]
        content.focusedFieldID = "text"
        return content
    }

    /// Arch's question before a page is left. The page cannot choose its words.
    static func leavePage(identity: PromptIdentity) -> PromptContent {
        PromptContent(kind: .leavePage, identity: identity, glyph: .symbol("rectangle.portrait.and.arrow.right", tint: .neutral, label: "Leave Page"),
                      title: "Leave this page?", message: "Changes you made may not be saved.",
                      buttons: [PromptButton(id: "stay", title: "Stay"), PromptButton(id: "leave", title: "Leave")], defaultButtonID: "leave", cancelButtonID: "stay")
    }

    static func confirmResult(_ response: PromptResponse) -> Bool {
        response.buttonID == "ok"
    }

    static func textInputResult(_ response: PromptResponse) -> String? {
        guard case let .answered(answer) = response, answer.buttonID == "ok" else { return nil }
        return answer.fieldValues["text"] ?? ""
    }

    /// Only Stay keeps the page. A question that ended without the user, as when Arch quits or the user closes the tab, leaves it.
    static func leavePageResult(_ response: PromptResponse) -> Bool {
        response.buttonID != "stay"
    }

    // MARK: Logins

    /// HTTP authentication for a site or a proxy: the server's realm as its own words, a user name that starts with the proposed one, a password field, and notes for a failed attempt and an unencrypted connection. Focus starts in the user name while it is empty, else in the password. For a server other than the tab's site, which `identity` names with where it is, as for an image from another site, focus starts on the card itself, so that keys the user meant for the page never reach a field whose text goes to that server. After a failed attempt the card shakes as it shows.
    static func signIn(_ space: URLProtectionSpace, proposedUser: String?, failed: Bool, identity: PromptIdentity) -> PromptContent {
        let isProxy = space.isProxy()
        let user = proposedUser ?? ""
        var notes: [PromptNote] = []
        if failed {
            notes.append(PromptNote(id: "failed", symbol: "xmark.octagon.fill", text: "The user name or password was incorrect.", tone: .error))
        }
        if !space.receivesCredentialSecurely {
            notes.append(PromptNote(id: "unencrypted", symbol: "exclamationmark.triangle.fill", text: "Your login information will be sent without encryption.", tone: .warning))
        }
        return PromptContent(kind: .signIn, identity: identity, glyph: .symbol("person.badge.key.fill", tint: .accent, label: "Log In"),
                             title: isProxy ? "Log In to This Proxy" : "Log In to This Website",
                             pageText: space.realm.flatMap { $0.isEmpty ? nil : PageAuthoredText(caption: isProxy ? "The proxy says" : "The site says", text: $0) },
                             fields: [PromptField(id: "user", kind: .userName, label: "User Name", initialValue: user),
                                      PromptField(id: "password", kind: .password, label: "Password", initialValue: "")],
                             focusedFieldID: identity.context != nil ? nil : user.isEmpty ? "user" : "password", notes: notes,
                             buttons: [PromptButton(id: "cancel", title: "Cancel"), PromptButton(id: "logIn", title: "Log In")],
                             defaultButtonID: "logIn", cancelButtonID: "cancel", shakesOnArrival: failed)
    }

    /// Log In gives a credential for this session only, which is never saved.
    static func signInCredential(_ response: PromptResponse) -> URLCredential? {
        guard case let .answered(answer) = response, answer.buttonID == "logIn" else { return nil }
        return URLCredential(user: answer.fieldValues["user"] ?? "", password: answer.fieldValues["password"] ?? "", persistence: .forSession)
    }

    // MARK: Links for other apps

    /// A page's link for another app, with the app's icon. Open waits for the card to arm.
    static func openInApp(appName: String, appIcon: NSImage, scheme: String, hasHost: Bool, identity: PromptIdentity) -> PromptContent {
        PromptContent(kind: .openInApp, identity: identity, glyph: .appIcon(appIcon, label: appName),
                      title: "Open \u{201C}\(appName)\u{201D}?", message: "\(hasHost ? "This website" : "This page") wants to open a \(scheme) link in \(appName).",
                      buttons: [PromptButton(id: "cancel", title: "Cancel"), PromptButton(id: "open", title: "Open", needsArming: true)],
                      defaultButtonID: "open", cancelButtonID: "cancel")
    }

    enum OpenInAppAnswer: Equatable {
        case open
        /// The user said no, which the tab remembers for the site.
        case decline
        /// The question ended without the user, which leaves nothing to remember.
        case none
    }

    static func openInAppResult(_ response: PromptResponse) -> OpenInAppAnswer {
        switch response.buttonID {
        case "open": .open
        case nil: .none
        default: .decline
        }
    }

    // MARK: Site data

    /// Clear Site Data for the site of the tab's page. With several Personas, `personaSpace` names the Persona and space of the tab's place, as "Work / Research", or the Persona alone for a tab shown outside every space of its Persona (Persona rule 7), and the message says the data goes for every space of that Persona. Clear is destructive, so Return and Escape both press Cancel.
    static func clearSiteData(siteName: String, personaSpace: String?, identity: PromptIdentity) -> PromptContent {
        var identity = identity
        identity.name = siteName
        identity.context = personaSpace
        let scope = personaSpace == nil ? "" : " for every space of this Persona"
        return PromptContent(kind: .clearSiteData, identity: identity, glyph: .symbol("trash.fill", tint: .red, label: "Clear Website Data"),
                             title: "Clear the data stored by this website?",
                             message: "Its cookies and other website data are removed from both engines\(scope), which signs you out of the site. Its open tabs load again.",
                             buttons: [PromptButton(id: "clear", title: "Clear", isDestructive: true), PromptButton(id: "cancel", title: "Cancel")],
                             defaultButtonID: "cancel", cancelButtonID: "cancel")
    }

    // MARK: Downloads

    /// A page's download after its first that no click in the page or load for the user started (`PageDownloadGate`). The identity row names the page's host, a file's name for a page without one, or else this page, never the page's own title. Allow waits for the card to arm.
    static func pageDownloads(pageURL: URL?, identity: PromptIdentity) -> PromptContent {
        var identity = identity
        let hasHost = pageURL?.host?.isEmpty == false
        if !hasHost, let pageURL, pageURL.isFileURL, !pageURL.lastPathComponent.isEmpty { identity.name = pageURL.lastPathComponent }
        return PromptContent(kind: .pageDownloads, identity: identity, glyph: .symbol("arrow.down.circle.fill", tint: .accent, label: "Downloads"),
                             title: "Allow \(hasHost ? "this website" : "this page") to download multiple files?",
                             message: "The page started another download without a click in it. If you allow it, it can download files until it loads another page.",
                             buttons: [PromptButton(id: "deny", title: "Don\u{2019}t Allow"), PromptButton(id: "allow", title: "Allow", needsArming: true)],
                             defaultButtonID: "allow", cancelButtonID: "deny")
    }

    /// Only Allow lets the page download more files; Don't Allow and a question that ended without the user refuse.
    static func pageDownloadsResult(_ response: PromptResponse) -> Bool {
        response.buttonID == "allow"
    }

    // MARK: Notices

    /// Arch's notice about the tab's page, such as a capture that failed. A detail that is a file path truncates in the middle and shows whole in its tooltip.
    static func notice(title: String, detail: String?, detailIsPath: Bool = false, identity: PromptIdentity) -> PromptContent {
        PromptContent(kind: .notice, identity: identity, glyph: .symbol("exclamationmark.triangle.fill", tint: .yellow, label: "Warning"),
                      title: title, message: detail, messageStyle: detailIsPath ? .path : .text,
                      buttons: [PromptButton(id: "ok", title: "OK")], defaultButtonID: "ok", cancelButtonID: "ok")
    }

    // MARK: Web extensions

    /// An extension's question. More access names the extension, with the version of a pair as a tag, and its icon when the host has one; a reload is about the tab's page, under `identity`. Allow waits for the card to arm.
    static func extensionQuestion(_ question: WebExtensionQuestion, icon: NSImage?, identity: PromptIdentity) -> PromptContent {
        switch question.kind {
        case .reload:
            return PromptContent(kind: .extensionReload, identity: identity, glyph: .symbol("arrow.clockwise", tint: .neutral, label: "Reload"),
                                 title: "Reload This Page?", message: question.message,
                                 buttons: [PromptButton(id: "cancel", title: "Cancel"), PromptButton(id: "reload", title: "Reload")],
                                 defaultButtonID: "reload", cancelButtonID: "cancel")
        case .access, .enginePermissions:
            var notes: [PromptNote] = []
            if let keeps = question.keeps { notes.append(PromptNote(id: "keeps", symbol: "clock", text: keeps, tone: .info)) }
            if question.confirmsNext { notes.append(PromptNote(id: "confirms", symbol: "touchid", text: "Arch asks for Touch ID or your password next.", tone: .info)) }
            let extensionIdentity = PromptIdentity(icon: icon.map(PromptIcon.image) ?? .symbol("puzzlepiece.extension"), name: question.extensionName, isSecure: false,
                                                   tag: question.version.map { "\($0.displayName) version" })
            return PromptContent(kind: .extensionAccess, identity: extensionIdentity, glyph: .symbol("puzzlepiece.extension.fill", tint: .accent, label: "Extension"),
                                 title: "Allow this extension more access?", message: question.message, items: question.items, notes: notes,
                                 buttons: [PromptButton(id: "deny", title: "Don\u{2019}t Allow"), PromptButton(id: "allow", title: "Allow", needsArming: true)],
                                 defaultButtonID: "allow", cancelButtonID: "deny")
        }
    }

    /// Allow and Reload agree; Don't Allow, Cancel, and a question that ended without the user do not.
    static func extensionAnswer(_ response: PromptResponse) -> Bool {
        response.buttonID == "allow" || response.buttonID == "reload"
    }

    // MARK: Helpers

    /// A page's words, or nothing for an empty message.
    private static func pageText(_ message: String) -> PageAuthoredText? {
        message.isEmpty ? nil : PageAuthoredText(text: message)
    }
}
