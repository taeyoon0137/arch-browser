// The tool host applies one table of rules (docs/agents.md, Permissions, approvals, and injection defenses).
// It decides from the mode, client kind, tab, and element facts. The host classifies each call and asks `decide(_:in:)`; this file runs no step.
// P16 checks every agent-written address, main-frame navigation, redirect hop, popup, read, and displayed result title in an agent tab.
// `Browsing` applies P8, P9, and P10 in agent tabs and reports them as events. The word lists live only here and go to the page script with each operation.
import AgentControl
import Foundation

/// A rule of the table, by its number.
public enum AgentRule: String, CaseIterable, Sendable {
    case p1 = "P1", p2 = "P2", p3 = "P3", p4 = "P4", p5 = "P5", p6 = "P6", p7 = "P7", p8 = "P8", p9 = "P9"
    case p10 = "P10", p11 = "P11", p12 = "P12", p13 = "P13", p14 = "P14", p15 = "P15", p16 = "P16", p17 = "P17", p18 = "P18", p19 = "P19"
}

/// What a rule does when its trigger holds.
public enum AgentRuleEffect: Equatable, Sendable {
    /// The step does not run, in any mode.
    case refuses
    /// The user decides on a card. A sensitive card offers only Allow Once, Deny, Deny and Stop, Reply, and Take Over, has no default button, and for outside clients asks for Touch ID on Allow.
    case asks(sensitive: Bool)
    /// Arch says no without asking and tells the agent.
    case denies
    /// The user answers on Arch's own card over the tab; the agent waits.
    case leavesToUser
    /// Arch dismisses it and tells the agent.
    case dismisses
}

public struct AgentRuleEntry: Sendable {
    public var rule: AgentRule
    /// When the rule applies, as the design's table says it.
    public var trigger: String
    public var effect: AgentRuleEffect
    /// What a refusal, a card, or an event says.
    public var sentence: String
}

/// Who calls: an in-app session, which has a site scope, an outside client, which navigates freely in its own agent tabs because it can send data anywhere itself (agent decision 8), or an agent run, which never asks: what would ask is refused with `wouldAsk` (`docs/hooks.md`, Tools).
public enum AgentClientKind: String, CaseIterable, Sendable {
    case inApp
    case outside
    case run
}

/// How the client may use the tab a step acts in.
public enum AgentTabAccess: Equatable, Sendable {
    /// One of the client's own agent tabs.
    case agentTab
    /// A tab the user shared through `request_tab`, for acting or only for reading.
    case shared(acting: Bool)
    /// Another session's or Persona's tab, or one the user took over.
    case notTheClients
}

/// What a step does, as the host classifies it for the policy.
public enum AgentPolicyStep: Equatable, Sendable {
    /// An action tool of class I (`click`, `type`, `press`, `select_option`, `scroll`, `hover`) on an element, or on the page for `press` and `scroll` without a ref.
    case interaction(AgentInteraction)
    /// `open_tab` or `navigate`, or a redirect hop of a navigation the agent started.
    case navigation(AgentNavigationFacts)
    /// `request_approval` (P15).
    case approvalRequest
    /// A download from an agent tab (P6).
    case download
    /// A file input or a file chooser in an agent tab (P7).
    case fileChooser
    /// A permission request from an agent tab (P8).
    case permissionRequest
    /// A `confirm`, `prompt`, or leave-page dialog, or HTTP authentication, in an agent tab (P9).
    case dialog
    /// An `alert` in an agent tab (P10).
    case alert
    /// A link to another app from an agent tab (P11).
    case externalApp
}

public struct AgentInteraction: Equatable, Sendable {
    public var tool: String
    public var tab: AgentTabAccess
    /// For an in-app session, whether the tab's site is in the session's scope. An outside client has no scope, so this stays true.
    public var siteInScope: Bool
    /// The element the step targets, or the focused element for `press` without a ref; nil for `scroll` without a ref.
    public var element: AgentElementFacts?
    /// The text `type` would type, or the keys `press` would press.
    public var text: String?
    /// The step submits the element's form: a click on a submit control, `type` with `submit`, or Enter in a form field.
    public var submits: Bool
    /// The session typed into the element's form before in this document, for P5.
    public var typedIntoForm: Bool
    /// The page's host, for P5's comparison with the form's action.
    public var pageHost: String?

    public init(tool: String, tab: AgentTabAccess = .agentTab, siteInScope: Bool = true, element: AgentElementFacts? = nil, text: String? = nil, submits: Bool = false,
                typedIntoForm: Bool = false, pageHost: String? = nil) {
        self.tool = tool
        self.tab = tab
        self.siteInScope = siteInScope
        self.element = element
        self.text = text
        self.submits = submits
        self.typedIntoForm = typedIntoForm
        self.pageHost = pageHost
    }

    /// Whether the step types or presses keys into its element.
    var entersText: Bool { tool == "type" || tool == "press" }
}

/// What the host knows of an address an agent navigates to, for in-app sessions' rule P13 (docs/agents.md, Site scope and navigation). The tool host reads them from the session's scope (`AgentSiteScope`); outside clients pass none of this.
public struct AgentNavigationFacts: Equatable, Sendable {
    /// The agent wrote the address (`url`), rather than following a link by ref or going back, forward, or reloading.
    public var isWritten: Bool
    /// The session has seen the address: a tab's committed address, a link ref's address, the user's own words, or an address the user approved.
    public var isSeen: Bool
    /// The search engine's results address with nothing but the search terms.
    public var isSearchResults: Bool
    /// `https://host/` with no path, query, or fragment, on a site in the scope.
    public var isBareOriginInScope: Bool
    public var siteInScope: Bool
    /// A redirect hop of a navigation the agent started by a written address.
    public var isRedirectHop: Bool

    public init(isWritten: Bool, isSeen: Bool = false, isSearchResults: Bool = false, isBareOriginInScope: Bool = false, siteInScope: Bool = true, isRedirectHop: Bool = false) {
        self.isWritten = isWritten
        self.isSeen = isSeen
        self.isSearchResults = isSearchResults
        self.isBareOriginInScope = isBareOriginInScope
        self.siteInScope = siteInScope
        self.isRedirectHop = isRedirectHop
    }
}

/// What the user allowed earlier that covers a step without a new card: Allow on This Page until the document changes, Allow on <site> for This Session, and Allow Downloads from This Site for This Session.
public struct AgentAllowances: Equatable, Sendable {
    public var page = false
    public var site = false
    public var downloads = false

    public init(page: Bool = false, site: Bool = false, downloads: Bool = false) {
        self.page = page
        self.site = site
        self.downloads = downloads
    }
}

/// A card the policy asks for: the rules that ask, none when the mode alone asks, and the allowances it may offer.
public struct AgentAsk: Equatable, Sendable {
    public var rules: [AgentRule]
    public var isSensitive: Bool
    /// Allow on This Page, for the interactions Ask Before Acting asks about.
    public var offersPage: Bool
    /// Allow on <site> for This Session, for interactions that Ask Before Acting asks about and for P14.
    public var offersSite: Bool
    /// Allow Downloads from This Site for This Session (P6).
    public var offersDownloads: Bool

    public init(rules: [AgentRule], isSensitive: Bool, offersPage: Bool = false, offersSite: Bool = false, offersDownloads: Bool = false) {
        self.rules = rules
        self.isSensitive = isSensitive
        self.offersPage = offersPage
        self.offersSite = offersSite
        self.offersDownloads = offersDownloads
    }
}

/// The policy's answer for a step.
public enum AgentDecision: Equatable, Sendable {
    case allow
    case ask(AgentAsk)
    /// The step does not run: a rule's refusal, or nil for the mode's (Read Only).
    case refuse(AgentRule?, String)
    case deny(AgentRule)
    case leaveToUser(AgentRule)
    case dismiss(AgentRule)
}

/// What a rule says about an address or a tab.
enum AgentRuleOutcome: Equatable {
    case allowed
    case refused(AgentRule, String)
}

public enum AgentPolicy {
    // MARK: The table

    /// P1 to P19, in order.
    public static let table: [AgentRuleEntry] = [
        AgentRuleEntry(rule: .p1, trigger: "Typing or pressing keys into a password, credential, one-time-code, or payment field, or a field whose label names a secret", effect: .refuses,
                       sentence: "Agents never type credentials, codes, or card details. Use hand_to_user."),
        AgentRuleEntry(rule: .p2, trigger: "Typing into a personal-data field", effect: .asks(sensitive: true), sentence: "Typing into a field for personal data asks the user, who sees the exact text."),
        AgentRuleEntry(rule: .p3, trigger: "Submitting a form that contains password, one-time-code, payment, or personal fields", effect: .asks(sensitive: true),
                       sentence: "Submitting a form with password, code, payment, or personal fields asks the user."),
        AgentRuleEntry(rule: .p4, trigger: "Clicking a control, or pressing Enter or Space on it, whose name or value reads as an irreversible step, or submitting by Enter a form whose default button reads so", effect: .asks(sensitive: true),
                       sentence: "A control that reads as a step that cannot be undone, such as buying, sending, or deleting, asks the user."),
        AgentRuleEntry(rule: .p5, trigger: "Submitting a form whose action is on a different site from the page, after the session typed into it", effect: .asks(sensitive: true),
                       sentence: "Submitting what the agent typed to another site asks the user."),
        AgentRuleEntry(rule: .p6, trigger: "A download from an agent tab", effect: .asks(sensitive: false), sentence: "A download from an agent tab asks the user."),
        AgentRuleEntry(rule: .p7, trigger: "A file input or a file chooser in an agent tab, whatever started it", effect: .asks(sensitive: false),
                       sentence: "A page's file chooser asks the user, who picks in Arch's panel. Agents never name a file and learn only how many items the page received."),
        AgentRuleEntry(rule: .p8, trigger: "A permission request from an agent tab", effect: .denies,
                       sentence: "Arch denies permission requests in agent tabs. Hand the tab to the user with hand_to_user for a step that needs one."),
        AgentRuleEntry(rule: .p9, trigger: "A confirm, prompt, or leave-page dialog, or HTTP authentication, in an agent tab", effect: .leavesToUser, sentence: "The dialog waits for the user in Arch."),
        AgentRuleEntry(rule: .p10, trigger: "An alert in an agent tab", effect: .dismisses, sentence: "Arch dismissed the alert."),
        AgentRuleEntry(rule: .p11, trigger: "A link to another app from an agent tab", effect: .asks(sensitive: true), sentence: "Opening another app asks the user."),
        AgentRuleEntry(rule: .p12, trigger: "Any interaction in a tab the user shared", effect: .asks(sensitive: true), sentence: "Every action in a tab the user shared asks the user."),
        AgentRuleEntry(rule: .p13, trigger: "In-app navigation by a written address that is not a seen address, the search engine's results address, or the bare origin of a site in scope; a redirect hop of a written address's navigation to a site outside the scope",
                       effect: .asks(sensitive: true), sentence: "An address no page showed asks the user, since it can carry what the agent read elsewhere."),
        AgentRuleEntry(rule: .p14, trigger: "In-app typing on a site outside the scope in Act in Agent Tabs", effect: .asks(sensitive: false), sentence: "Typing on a site outside the session's scope asks the user, who sees the exact text."),
        AgentRuleEntry(rule: .p15, trigger: "request_approval", effect: .asks(sensitive: true), sentence: "The agent asks the user to approve a step."),
        AgentRuleEntry(rule: .p16, trigger: "Navigation, a redirect hop, a page's own navigation, or a popup to a site excluded from AI, an internal page, a file: address, or another scheme; any read of a page on an excluded site",
                       effect: .refuses, sentence: excludedSentence),
        AgentRuleEntry(rule: .p17, trigger: "Closing a tab the session did not open; acting on a tab of another session or Persona", effect: .refuses,
                       sentence: "Agents close and act only in their own agent tabs and the tabs the user shared with them."),
        AgentRuleEntry(rule: .p18, trigger: "A CAPTCHA or bot check", effect: .refuses, sentence: "Hand the tab to the user."),
        AgentRuleEntry(rule: .p19, trigger: "Renaming a tab: the client's own agent tab freely, a tab the user shared after asking once per tab, and no other tab; a run renames its run tabs without asking", effect: .asks(sensitive: false),
                       sentence: "Renaming a tab the user shared asks the user once for that tab."),
    ]

    public static func entry(_ rule: AgentRule) -> AgentRuleEntry {
        table.first { $0.rule == rule }!
    }

    /// The rules whose cards are sensitive (P2 to P5, P11 to P13, and P15).
    public static var sensitiveRules: [AgentRule] {
        table.filter { $0.effect == .asks(sensitive: true) }.map(\.rule)
    }

    /// Read Only's refusal of interactions and sensitive steps, which no rule number names.
    public static let readOnlySentence = "This client has Read Only access, so Arch refuses actions other than scroll and hover, and steps that ask for approval."
    public static let readOnlyCode = "readOnly"

    // MARK: Decisions

    /// The decision for a step: refusals first, then sensitive cards, which no allowance covers, then the cards the mode asks for, which earlier allowances cover. No mode, grant, or setting turns a rule into an automatic approval.
    public static func decide(_ step: AgentPolicyStep, client: AgentClientKind, mode: AgentAccessLevel, allowances: AgentAllowances = AgentAllowances()) -> AgentDecision {
        if client == .run { return runDecision(decide(step, client: .outside, mode: mode, allowances: allowances)) }
        switch step {
        case .interaction(let interaction): return decide(interaction, client: client, mode: mode, allowances: allowances)
        case .navigation(let facts):
            guard client == .inApp else { return .allow }
            let unseen = facts.isWritten && !(facts.isSeen || facts.isSearchResults || facts.isBareOriginInScope)
            if (facts.isRedirectHop && facts.isWritten && !facts.siteInScope) || (!facts.isRedirectHop && unseen) { return .ask(AgentAsk(rules: [.p13], isSensitive: true)) }
            return .allow
        case .approvalRequest:
            if mode == .readOnly { return .refuse(nil, readOnlySentence) }
            return .ask(AgentAsk(rules: [.p15], isSensitive: true))
        case .download:
            return allowances.downloads ? .allow : .ask(AgentAsk(rules: [.p6], isSensitive: false, offersDownloads: true))
        case .fileChooser: return .ask(AgentAsk(rules: [.p7], isSensitive: false))
        case .permissionRequest: return .deny(.p8)
        case .dialog: return .leaveToUser(.p9)
        case .alert: return .dismiss(.p10)
        case .externalApp: return .ask(AgentAsk(rules: [.p11], isSensitive: true))
        }
    }

    private static func decide(_ step: AgentInteraction, client: AgentClientKind, mode: AgentAccessLevel, allowances: AgentAllowances) -> AgentDecision {
        let tool = AgentToolCatalog.tool(named: step.tool)
        let changesNoData = tool?.traits.contains(.allowedInReadOnly) ?? false
        // Refusals, in any mode.
        switch step.tab {
        case .notTheClients: return .refuse(.p17, entry(.p17).sentence)
        case .shared(acting: false): return .refuse(.p17, "The user shared this tab for reading only, so agents do not act in it.")
        case .agentTab, .shared(acting: true): break
        }
        if let element = step.element {
            // No tool writes a file input's value. In an agent tab, a click on one runs as other clicks do, and a chooser it opens asks under P7; in a tab the user shared, a chooser would open the user's own panel without a P7 card, so a click or a press that activates one is refused.
            if element.isFileInput {
                if step.tool == "type" { return .refuse(.p7, fileInputSentence) }
                if case .shared = step.tab, step.tool == "click" || (step.tool == "press" && pressActivates(step.text, on: element)) { return .refuse(.p7, sharedFileInputSentence) }
            }
            if isChallenge(element) { return .refuse(.p18, entry(.p18).sentence) }
            if step.entersText, element.valueClass == .hidden { return .refuse(.p1, entry(.p1).sentence) }
        }
        if mode == .readOnly, !changesNoData { return .refuse(nil, readOnlySentence) }
        // Sensitive cards, which no allowance covers.
        var rules: [AgentRule] = []
        if let element = step.element {
            // Enter or Space on a control is a click on it, and a submit control's click submits its form.
            let clicks = step.tool == "click" || (step.tool == "press" && pressActivates(step.text, on: element))
            let submits = step.submits || (clicks && element.submitsForm)
            if step.tool == "type", element.valueClass == .personal { rules.append(.p2) }
            if submits, !Set(element.formFields).isDisjoint(with: [.password, .oneTimeCode, .payment, .personal]) { rules.append(.p3) }
            let control = clicks && (readsAsIrreversible(element.name) || readsAsIrreversible(element.value ?? ""))
            // Enter, by `type` with `submit` or by `press` in a field, submits with the form's default button, as a click on it would.
            let submitter = step.tool != "click" && step.submits && (readsAsIrreversible(element.submitterName ?? "") || readsAsIrreversible(element.submitterValue ?? ""))
            if control || submitter { rules.append(.p4) }
            if submits, step.typedIntoForm, let action = element.formActionHost, let page = step.pageHost, site(ofHost: action) != site(ofHost: page) { rules.append(.p5) }
        }
        if case .shared = step.tab { rules.append(.p12) }
        if !rules.isEmpty { return .ask(AgentAsk(rules: rules, isSensitive: true)) }
        if changesNoData { return .allow }
        // The mode's cards, which an earlier allowance covers.
        switch mode {
        case .readOnly:
            return .refuse(nil, readOnlySentence)
        case .askBeforeActing:
            return allowances.page || allowances.site ? .allow : .ask(AgentAsk(rules: [], isSensitive: false, offersPage: true, offersSite: true))
        case .actInAgentTabs:
            guard client == .inApp, !step.siteInScope else { return .allow }
            return allowances.site ? .allow : .ask(AgentAsk(rules: step.tool == "type" ? [.p14] : [], isSensitive: false, offersSite: true))
        }
    }

    /// Rule P19 for `rename_tab`, in every mode, since a name changes no page: a session's or an outside client's own agent tab renames freely, a tab the user shared asks once per tab on a card that is not sensitive, after which `allowedOnce` holds for the tab, and any other tab is refused with P17. A run renames its run tabs without asking, which for an outside client's run are its own agent tabs and the tabs shared with it, so a shared tab not yet allowed once is refused with `wouldAsk`.
    public static func renameDecision(client: AgentClientKind, tab: AgentTabAccess, allowedOnce: Bool) -> AgentDecision {
        switch tab {
        case .notTheClients: return .refuse(.p17, entry(.p17).sentence)
        case .agentTab: return .allow
        case .shared:
            let decision: AgentDecision = allowedOnce ? .allow : .ask(AgentAsk(rules: [.p19], isSensitive: false))
            return client == .run ? runDecision(decision) : decision
        }
    }

    /// Whether `press` presses Enter or Space, with or without modifiers, on an element other than a text field or a select: a page's own key handlers can act on such a key as on a click, untrusted events too, on any element, such as a menu item or a tab, so the step counts as a click on it for P3, P4, and P5, and on a file input as a click, whose chooser P7 asks about in an agent tab and which P7 refuses in a tab the user shared. P4 reads a generic element's name only when it is labeled, since the script names only some roles by their text.
    static func pressActivates(_ keys: String?, on element: AgentElementFacts) -> Bool {
        guard let key = keys?.split(separator: "+", omittingEmptySubsequences: false).last, ["Enter", "Space", " "].contains(String(key)) else { return false }
        return !element.isEditable && !element.isSelect && !["textbox", "searchbox", "combobox", "listbox", "spinbutton", "slider"].contains(element.role)
    }

    // MARK: Addresses

    /// The schemes of addresses agents open and pages they read.
    static let webSchemes: Set<String> = ["http", "https"]

    static let excludedSentence = "The user excluded this site from AI in Settings \u{25B8} AI, so agents neither open nor read it."
    static let schemeSentence = "Agents open and read only http and https pages: never internal pages, files, or other apps' links."

    /// An address the agent writes, for `open_tab` and `navigate` (P16): an http or https address on a site not excluded from AI.
    static func mayOpen(_ url: URL, allowsAI: (URL) -> Bool) -> AgentRuleOutcome {
        guard let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme), url.host?.isEmpty == false else { return .refused(.p16, schemeSentence) }
        return allowsAI(url) ? .allowed : .refused(.p16, excludedSentence)
    }

    /// A main frame navigation, redirect hop, or popup in an agent tab, whoever started it (P16). An empty document (`about:blank` or `about:srcdoc`) loads, since it shows nothing of another site and a page's popup often starts there; reading one is refused.
    static func mayLoad(_ url: URL, allowsAI: (URL) -> Bool) -> AgentRuleOutcome {
        if url.scheme?.lowercased() == "about", ["blank", "srcdoc"].contains(url.absoluteString.dropFirst("about:".count).lowercased()) { return .allowed }
        return mayOpen(url, allowsAI: allowsAI)
    }

    /// A page the agent reads or acts in, or whose title a result shows, by the address the tab committed (P16), checked at each call against the exclusions then in force.
    static func mayRead(_ url: URL?, allowsAI: (URL) -> Bool) -> AgentRuleOutcome {
        guard let url else { return .refused(.p16, schemeSentence) }
        return mayOpen(url, allowsAI: allowsAI)
    }

    /// Whether a title may show for a page at `url`: not on an excluded site, an internal page, or another scheme.
    static func showsTitle(of url: URL?, allowsAI: (URL) -> Bool) -> Bool {
        mayRead(url, allowsAI: allowsAI) == .allowed
    }

    /// A host's site for comparisons: its registrable domain as the site scope counts it (`AgentSite`), in lower case without IPv6 brackets or a trailing dot, so that two customers of a hosting platform, such as `alice.github.io` and `bob.github.io`, and two IP addresses are different sites.
    public static func site(ofHost host: String) -> String {
        AgentSite.registrableDomain(of: host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")))
    }

    // MARK: Words

    /// Words that name a secret in a field's label, name, or ID (P1), and in the text of the user's cards. A value of such a field never leaves the page.
    public static let secretWords = [
        "password", "passwords", "passwd", "pwd", "passcode", "passphrase", "pin", "pin code", "cvv", "cvc", "cvv2", "csc", "security code", "verification code", "one time code",
        "one time password", "otp", "2fa", "token", "api key", "secret", "social security number", "ssn", "card number", "credit card", "card no",
        "비밀번호", "암호", "패스워드", "인증번호", "인증 번호", "인증코드", "보안코드", "보안 코드", "주민등록번호", "주민번호", "카드번호", "카드 번호",
    ]

    /// `autocomplete` tokens of fields whose values never leave the page: credentials, one-time codes, and payment details.
    static let hiddenAutocomplete = ["current-password", "new-password", "one-time-code"]
    static let hiddenAutocompletePrefix = "cc-"
    /// `autocomplete` tokens of personal data, whose values show as `<personal>`.
    static let personalAutocomplete = ["email", "tel", "tel-national", "tel-local", "tel-country-code", "tel-area-code", "tel-local-prefix", "tel-local-suffix", "tel-extension",
                                       "street-address", "address-line1", "address-line2", "address-line3", "postal-code", "bday", "bday-day", "bday-month", "bday-year"]

    /// Words in a control's name or value that read as a step that cannot be undone or that others see (P4). They can only add cards, never remove one.
    public static let irreversibleWords = [
        "buy", "purchase", "order", "place order", "checkout", "check out", "pay", "subscribe", "donate", "transfer", "send", "post", "publish", "share", "reply", "comment",
        "submit", "delete", "remove", "cancel subscription", "unsubscribe", "confirm", "agree", "accept", "sign",
        "구매", "결제", "주문", "구독", "송금", "보내기", "전송", "게시", "공유", "댓글", "제출", "삭제", "탈퇴", "확인", "동의", "수락", "서명",
    ]

    /// Words that name a CAPTCHA or bot check (P18), and the hosts of known challenge services, whose frames a snapshot marks.
    static let challengeWords = ["captcha", "recaptcha", "hcaptcha", "turnstile", "bot check", "are you a robot", "i'm not a robot", "i am not a robot", "verify you are human",
                                 "보안문자", "자동입력 방지", "자동 입력 방지"]
    static let challengeHosts = ["recaptcha.net", "hcaptcha.com", "challenges.cloudflare.com", "arkoselabs.com", "funcaptcha.com", "geetest.com", "captcha-delivery.com"]

    /// Whether `text` names one of `words`: whole words for those in ASCII, after camel case, digits, and punctuation are split, and anywhere for the others, such as Korean ones.
    static func names(_ text: String, oneOf words: [String]) -> Bool {
        let normalized = " " + normalizedWords(text) + " "
        return words.contains { word in
            let word = word.lowercased()
            return word.allSatisfy(\.isASCII) ? normalized.contains(" \(word) ") : normalized.contains(word)
        }
    }

    /// Lowercase words separated by single spaces, the way the page script splits labels, names, and IDs.
    static func normalizedWords(_ text: String) -> String {
        var split = ""
        var previous: Character?
        for character in text {
            if let previous, (previous.isLowercase && character.isUppercase) || (previous.isLetter && character.isNumber) || (previous.isNumber && character.isLetter) { split.append(" ") }
            split.append(character)
            previous = character
        }
        let separated = split.lowercased().map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        return String(separated).split(separator: " ").joined(separator: " ")
    }

    static func readsAsIrreversible(_ text: String) -> Bool {
        names(text, oneOf: irreversibleWords)
    }

    /// An element named as a CAPTCHA or bot check. Elements inside a challenge service's frame are another site's, which agents neither read nor target.
    static func isChallenge(_ element: AgentElementFacts) -> Bool {
        names(element.name, oneOf: challengeWords)
    }

    /// Whether a frame's address is a challenge service's, Google's reCAPTCHA paths included.
    static func isChallengeFrame(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "google.com" || host.hasSuffix(".google.com") || host.hasSuffix("gstatic.com") { return url.path.lowercased().contains("recaptcha") }
        return challengeHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The line an Arch card leads with when the agent's text on an `ask_user`, `hand_to_user`, or `request_approval` card names a secret (P1's words).
    public static let secretWarning = "Agents never need your passwords or codes. Type them only into the page after Take Over."

    public static func cardTextNamesSecret(_ text: String) -> Bool {
        names(text, oneOf: secretWords)
    }

    /// Phrases addressed to AI models, in English and Korean, which the panel warns about on a step. A warning, not a boundary.
    static let phrasesToAgents = ["ignore previous instructions", "ignore all previous instructions", "ignore the above", "disregard previous instructions", "system prompt",
                                  "you are an ai", "as an ai agent", "ai agents must", "new instructions", "이전 지시", "이전 명령", "시스템 프롬프트", "지시를 무시", "명령을 무시"]

    /// Whether untrusted text in a result speaks to AI agents.
    static func addressesAgents(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return phrasesToAgents.contains { lowered.contains($0) }
    }

    // MARK: Sentences

    /// P17's sentence for a tab the user took over or never gave the client.
    static func notTheClientsSentence(_ handle: String) -> String {
        "\(handle) is not one of this client's agent tabs: the user took it over, or it was never the client's. Agents close and navigate only their own agent tabs."
    }

    /// P8's sentence for the event.
    static let permissionSentence = entry(.p8).sentence

    /// P7's refusal of `type` into a file input, whose value would name a file. The agents' DOM click on a file input opens no chooser while the page script runs without a user gesture (docs/agents.md, Actions), so the sentence sends the step to the user.
    static let fileInputSentence = "Agents never name a file for a file input. Hand the tab to the user with hand_to_user; a file chooser the page opens asks the user, who picks in Arch's panel."

    /// P7's refusal of a click on a file input in a tab the user shared.
    static let sharedFileInputSentence = "In a tab the user shared, the user picks files. Hand the step to the user with hand_to_user."
}
