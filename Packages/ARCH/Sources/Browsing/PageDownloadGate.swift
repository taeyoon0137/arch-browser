// A page's first download proceeds without asking. A download also proceeds after the user clicks the page, presses Return, Enter, or Space while it has focus, or asks Arch to load the address.
// Actions on a card or another overlay do not count as page actions (`BrowserWindowModel.tabOnScreen(at:)` and `tabOnScreen(activatedBy:)`).
// Later downloads wait for approval, so a page cannot fill the downloads folder on its own. Allow lasts until the tab commits another document.
// A denial and first-download state reset only for a user-requested document or a different site. Same-site automatic loads keep them, so a page cannot reload for another first download.
// A tab opened by a script plugin, or by that tab's page before user action, gets no first download until the user acts in it or asks Arch to load an address there.
// A tab opened straight onto a file uses its opener's gate (`BrowserSession`), so opening files in new tabs cannot bypass approval.

/// One tab's downloads from its current documents. `BrowserSession` admits each download through it and asks with a card over the tab when it says so. The gate returns the decisions for the caller to run, so that none runs while the gate changes.
struct PageDownloadGate {
    /// What the gate says of one download.
    enum Admission: Equatable {
        /// The download goes on at once.
        case allow
        /// The user refused the page's downloads.
        case deny
        /// The download waits, and the caller asks the user.
        case ask
        /// The download waits for the question already asked.
        case wait
    }

    /// The site of the tab's document: its host, or its scheme for a page without one. Nil before the first document.
    private var site: String?
    /// Whether the page has started a download since the gate started over.
    private var hasDownloaded = false
    /// Whether the user acted in the page since its last download.
    private var hasUserInput = false
    /// Set when Arch loads an address in the tab for the user, until the next document or download: a download that the load starts is the user's.
    private var isUserLoad = false
    /// The user's answer, or nil before one.
    private var answer: Bool?
    /// The decisions of the downloads that wait for the answer.
    private var waiting: [(Bool) -> Void] = []
    /// Set when a script plugin opened the tab with `tabs.manage`, or a page of such a tab opened it, until the user acts in its page or Arch loads an address in it for the user: each document starts over with its first download used, and an address that only points at a file downloads nothing (`Tab.webContents(_:shouldDownload:hasPage:)`).
    private(set) var isHeldUntilUserActs = false
    /// Counts the times the gate started over, so that an answer to a question asked before decides only the downloads that wait for it.
    private var start = 0
    private var askedStart: Int?

    /// Admits a download at once, or keeps `decide` until `answer(_:)` when the download has to wait.
    mutating func admit(_ decide: @escaping (Bool) -> Void) -> Admission {
        if isUserLoad {
            isUserLoad = false
            hasDownloaded = true
            return .allow
        }
        if let answer { return answer ? .allow : .deny }
        if !hasDownloaded || hasUserInput {
            hasDownloaded = true
            hasUserInput = false
            return .allow
        }
        waiting.append(decide)
        guard waiting.count == 1 else { return .wait }
        askedStart = start
        return .ask
    }

    /// Records the user's answer unless the gate started over since the question, which also decides the page's later downloads, and returns the decisions of the downloads that wait, for the caller to run with the answer.
    mutating func answer(_ allowed: Bool) -> [(Bool) -> Void] {
        if askedStart == start { answer = allowed }
        askedStart = nil
        defer { waiting = [] }
        return waiting
    }

    /// The user acted in the page, as with a click, which lets it start one more download without asking, and the next document starts over, also in a tab that a plugin opened.
    mutating func userDidAct() {
        hasUserInput = true
        isHeldUntilUserActs = false
    }

    /// Arch loads an address in the tab for the user, as one typed in the palette, Back, or Reload: a download that the load starts goes on without asking, even after a refusal, and the document it loads starts over, also in a tab that a plugin opened.
    mutating func userDidNavigate() {
        isUserLoad = true
        isHeldUntilUserActs = false
    }

    /// A script plugin opened the tab, which a web extension's `tabs.create` and `windows.create` do not hold (`SessionWebExtensionHost`), or a page of a tab that one opened did before the user acted in it, so every download of its pages asks until the user acts in a page of the tab or loads an address in it.
    mutating func holdUntilUserActs() {
        isHeldUntilUserActs = true
        hasDownloaded = true
    }

    /// The tab committed a document of `site`, which ends an Allow. The gate starts over when the user asked for the document or it is on another site, without a first download in a tab that a plugin opened. Downloads that wait keep waiting for the question already asked.
    mutating func documentDidCommit(site: String?) {
        if answer == true { answer = nil }
        if isUserLoad || hasUserInput || site != self.site {
            start += 1
            hasDownloaded = isHeldUntilUserActs
            hasUserInput = false
            answer = nil
        }
        isUserLoad = false
        self.site = site
    }
}
