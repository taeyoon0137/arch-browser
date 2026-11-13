// The rules the tool host applies (docs/agents.md, Permissions, approvals, and injection defenses ▸ Rules), each with the sentence a refusal or an event gives the agent. This build applies the rules of agent tabs and reading: P16 at every address an agent writes, at each main frame navigation, redirect hop, and popup in an agent tab, and at every read and every title it shows; P17 for tabs a client did not open; and P6, P8, P9, P10, and P11, which `Browsing` applies in agent tabs and reports as events. Plan task VII.13 adds the rules of actions and approvals, and asks about downloads (P6) and links to other apps (P11) instead of refusing them.
import AgentControl
import Foundation

/// A rule of the table, by its number.
public enum AgentRule: String, Sendable {
    /// A download from an agent tab: refused until plan task VII.13 asks about it.
    case p6 = "P6"
    /// A permission request from an agent tab: denied without asking.
    case p8 = "P8"
    /// A `confirm`, `prompt`, or leave-page dialog, or HTTP authentication, in an agent tab: the user answers in Arch's sheet.
    case p9 = "P9"
    /// An `alert` in an agent tab: dismissed.
    case p10 = "P10"
    /// A link to another app from an agent tab: refused until plan task VII.13 asks about it.
    case p11 = "P11"
    /// A site excluded from AI, an internal page, a `file:` address, or another scheme.
    case p16 = "P16"
    /// A tab that is not the client's.
    case p17 = "P17"
}

/// What a rule says about an address or a tab.
enum AgentRuleOutcome: Equatable {
    case allowed
    case refused(AgentRule, String)
}

enum AgentPolicy {
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

    /// A page the agent reads, or whose title a result shows, by the address the tab committed (P16), checked at each call against the exclusions then in force.
    static func mayRead(_ url: URL?, allowsAI: (URL) -> Bool) -> AgentRuleOutcome {
        guard let url else { return .refused(.p16, schemeSentence) }
        return mayOpen(url, allowsAI: allowsAI)
    }

    /// Whether a title may show for a page at `url`: not on an excluded site, an internal page, or another scheme.
    static func showsTitle(of url: URL?, allowsAI: (URL) -> Bool) -> Bool {
        mayRead(url, allowsAI: allowsAI) == .allowed
    }

    /// P17's sentence for a tab the user took over or never gave the client.
    static func notTheClientsSentence(_ handle: String) -> String {
        "\(handle) is not one of this client's agent tabs: the user took it over, or it was never the client's. Agents close and navigate only their own agent tabs."
    }

    /// P8's sentence for the event.
    static let permissionSentence = "Arch denies permission requests in agent tabs. Hand the tab to the user with hand_to_user for a step that needs one."
    /// P6's sentence until plan task VII.13 asks about downloads.
    static let downloadSentence = "Arch does not let agents download files yet."
    /// P11's sentence until plan task VII.13 asks about links to other apps.
    static let externalAppSentence = "Arch does not let agents open other apps."
}
