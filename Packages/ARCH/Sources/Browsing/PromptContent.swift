// What a tab's prompt says and offers, apart from how a card draws it: who asks, what it asks, the words a page or server wrote, the fields, notes, and buttons, and which buttons Return and Escape press. `TabPromptContent` and `SitePermissionAnswers` build it, `TabPromptQueue` keeps it until the user answers, and `PromptCard` draws it.
import AppKit

/// What a prompt asks. VoiceOver names the card by it.
enum PromptKind: Equatable {
    case sitePermission, pageAlert, pageConfirm, pageTextInput, leavePage, signIn, openInApp, extensionAccess, extensionReload, clearSiteData, pageDownloads, notice
    /// A page's file chooser, which waits in the tab's queue as the others do, and which Arch's open or save panel answers as a sheet on the window instead of a card (`PromptState.panel`).
    case fileChooser

    /// A page's own `alert`, `confirm`, or `prompt`, which the engine cancels when a navigation the user starts goes ahead.
    var isPageDialog: Bool {
        switch self {
        case .pageAlert, .pageConfirm, .pageTextInput: true
        default: false
        }
    }

    /// A permission or file request belongs to the document that asked, including when its address reloads.
    var endsWithDocument: Bool { self == .sitePermission || self == .fileChooser }

    /// The first words VoiceOver reads for the card.
    var accessibilityName: String {
        switch self {
        case .sitePermission: localized("Website Permission")
        case .pageAlert, .pageConfirm, .pageTextInput: localized("Page Message")
        case .leavePage: localized("Leave Page")
        case .signIn: localized("Log In")
        case .openInApp: localized("Open in Another App")
        case .extensionAccess: localized("Extension Access")
        case .extensionReload: localized("Reload Page")
        case .clearSiteData: localized("Clear Site Data")
        case .pageDownloads: localized("Multiple Downloads")
        case .notice: localized("Notice")
        case .fileChooser: localized("Choose Files")
        }
    }
}

/// The small picture at the start of the identity row.
enum PromptIcon: Equatable {
    case image(NSImage)
    case symbol(String)
}

/// Who asks. Arch writes it from the tab's address, the protection space, or the extension, never from page text.
struct PromptIdentity: Equatable {
    var icon: PromptIcon
    var name: String
    /// Whether the asker's connection is encrypted, which a lock shows.
    var isSecure: Bool
    /// A short label after the name, such as "Proxy" or "Chromium version".
    var tag: String? = nil
    /// Where the asker is, when that is not the tab's own site, such as "in example.com" for a frame from another site.
    var context: String? = nil
}

/// The color of a prompt's symbol and its tile.
enum PromptTint: Equatable {
    case accent, green, orange, purple, red, yellow, neutral
}

/// The picture beside the title: a symbol on a tinted tile, or another app's icon.
enum PromptGlyph: Equatable {
    case symbol(String, tint: PromptTint, label: String)
    case appIcon(NSImage, label: String)
}

/// Words that a page or server wrote, which the card keeps apart from Arch's own and shows verbatim. A very long text ends at `maximumLength` characters with an ellipsis.
struct PageAuthoredText: Equatable {
    static let maximumLength = 10_000

    /// Arch's words before the text, such as "The website says".
    var caption: String?
    var text: String
    /// Who wrote the text when it is not the asker that the identity row names, as an embedded page of another site, which VoiceOver names instead.
    var author: String?

    init(caption: String? = nil, text: String, author: String? = nil) {
        self.caption = caption
        self.text = text.count > Self.maximumLength ? String(text.prefix(Self.maximumLength)) + "\u{2026}" : text
        self.author = author
    }
}

/// A line below the fields that says what follows from the answer or what went wrong.
struct PromptNote: Equatable, Identifiable {
    /// Whether the note informs, warns, or reports an error, which sets its symbol's color.
    enum Tone: Equatable {
        case info, warning, error
    }

    var id: String
    var symbol: String
    var text: String
    var tone: Tone
}

/// A text field the user fills in before answering.
struct PromptField: Equatable, Identifiable {
    /// The kind of field, which picks a plain or secure text field and the content type that password managers read.
    enum Kind: Equatable {
        case text, userName, password
    }

    var id: String
    var kind: Kind
    /// The placeholder and the name VoiceOver reads.
    var label: String
    /// The text the field starts with, which AppKit selects as the field takes the focus, so that typing replaces it.
    var initialValue: String
}

/// One button of a prompt card; the prompt's answer names it by `id`.
struct PromptButton: Equatable, Identifiable {
    var id: String
    var title: String
    /// Drawn in the system's destructive style; Return never presses it.
    var isDestructive = false
    /// Stays dimmed for `PromptArming.delay` after the card shows, so that a key pressed for the page does not grant anything.
    var needsArming = false
    /// Does something other than answer the question, such as Open System Settings, so the card sets it apart at the leading edge.
    var isAlternative = false
}

/// One prompt as a card shows it. Buttons go left to right, the default one last; an alternative one goes first.
struct PromptContent: Equatable {
    /// How the card shows `message`: as sentences, or as a file path that truncates in the middle and shows whole in its tooltip.
    enum MessageStyle: Equatable {
        case text, path
    }

    var kind: PromptKind
    var identity: PromptIdentity
    var glyph: PromptGlyph?
    /// Arch's question. A page's own dialog has none, and its identity row heads the card instead.
    var title: String?
    var message: String?
    var messageStyle = MessageStyle.text
    var pageText: PageAuthoredText?
    var items: [String] = []
    var fields: [PromptField] = []
    /// The field that takes focus when the card does, or nil for the card itself, from which the user clicks or tabs into a field.
    var focusedFieldID: String?
    var notes: [PromptNote] = []
    var buttons: [PromptButton]
    var defaultButtonID: String?
    var cancelButtonID: String?
    /// Shakes once as it shows, as after a failed login.
    var shakesOnArrival = false
}

/// The button the user chose and what the fields held.
struct PromptAnswer: Equatable {
    var buttonID: String
    var fieldValues: [String: String] = [:]
}

/// How a prompt ended. `.dismissed` means without the user: its tab closed or switched engines, a navigation ended a page dialog, the user closed the tab, or Arch quit.
enum PromptResponse: Equatable {
    case answered(PromptAnswer)
    case dismissed

    /// The button the user chose, or nil for a prompt that ended without the user.
    var buttonID: String? {
        if case let .answered(answer) = self { return answer.buttonID }
        return nil
    }
}
