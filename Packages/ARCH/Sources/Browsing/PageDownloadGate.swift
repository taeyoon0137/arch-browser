// When a page may start a download without asking: its first download goes through, and so does one after a click in the page, as when the user clicks a file's link, or one that an address Arch loads for the user starts. Any other download waits until the user answers whether the page may download more files, so that a page cannot fill the downloads folder on its own. An Allow lasts until the tab commits another document. A refusal and the first download last until the gate starts over: at a document the user asked for, by a click in the page or through Arch, or one on another site. A document that the page loads on its own on its site, as by reloading or changing its address, keeps them, so that a page cannot reload itself for another first download.

/// One tab's downloads from its current documents. `BrowserSession` admits each download through it and asks with a card over the tab when it says so. The gate returns the decisions for the caller to run, so that none runs while the gate changes.
struct PageDownloadGate {
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
    /// Whether the user clicked in the page since its last download.
    private var hasUserInput = false
    /// Set when Arch loads an address in the tab for the user, until the next document or download: a download that the load starts is the user's.
    private var isUserLoad = false
    /// The user's answer, or nil before one.
    private var answer: Bool?
    /// The decisions of the downloads that wait for the answer.
    private var waiting: [(Bool) -> Void] = []
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

    /// A click in the page lets it start one more download without asking, and the next document starts over.
    mutating func userDidClick() {
        hasUserInput = true
    }

    /// Arch loads an address in the tab for the user, as one typed in the palette, Back, or Reload: a download that the load starts goes on without asking, even after a refusal, and the document it loads starts over.
    mutating func userDidNavigate() {
        isUserLoad = true
    }

    /// The tab committed a document of `site`, which ends an Allow. The gate starts over when the user asked for the document or it is on another site. Downloads that wait keep waiting for the question already asked.
    mutating func documentDidCommit(site: String?) {
        if answer == true { answer = nil }
        if isUserLoad || hasUserInput || site != self.site {
            start += 1
            hasDownloaded = false
            hasUserInput = false
            answer = nil
        }
        isUserLoad = false
        self.site = site
    }
}
