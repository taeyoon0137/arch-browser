// When a page may start a download without asking: its first download goes through, and so does one after a click in the page, as when the user clicks a file's link. Any other download waits until the user answers whether the page may download more files, so that a page cannot fill the downloads folder on its own. The answer lasts until the tab loads another document.

/// One tab's downloads from its current document. `BrowserSession` admits each download through it and asks with a sheet when it says so. The gate returns the decisions for the caller to run, so that none runs while the gate changes.
struct PageDownloadGate {
    enum Admission: Equatable {
        /// The download goes on at once.
        case allow
        /// The user refused this document's downloads.
        case deny
        /// The download waits, and the caller asks the user.
        case ask
        /// The download waits for the question already asked.
        case wait
    }

    /// Whether the document has started a download.
    private var hasDownloaded = false
    /// Whether the user clicked in the page since its last download.
    private var hasUserInput = false
    /// The user's answer for the document, or nil before one.
    private var answer: Bool?
    /// The decisions of the downloads that wait for the answer.
    private var waiting: [(Bool) -> Void] = []
    /// Counts the documents, so that an answer to a question an earlier document raised decides only the downloads that wait for it.
    private var document = 0
    private var askedDocument: Int?

    /// Admits a download at once, or keeps `decide` until `answer(_:)` when the download has to wait.
    mutating func admit(_ decide: @escaping (Bool) -> Void) -> Admission {
        if let answer { return answer ? .allow : .deny }
        if !hasDownloaded || hasUserInput {
            hasDownloaded = true
            hasUserInput = false
            return .allow
        }
        waiting.append(decide)
        guard waiting.count == 1 else { return .wait }
        askedDocument = document
        return .ask
    }

    /// Records the user's answer for the document that asked, which also decides its later downloads, and returns the decisions of the downloads that wait, for the caller to run with the answer.
    mutating func answer(_ allowed: Bool) -> [(Bool) -> Void] {
        if askedDocument == document { answer = allowed }
        askedDocument = nil
        defer { waiting = [] }
        return waiting
    }

    /// A click in the page lets it start one more download without asking.
    mutating func userDidClick() {
        hasUserInput = true
    }

    /// Another document starts over. Downloads that wait keep waiting for the question already asked.
    mutating func documentDidLoad() {
        document += 1
        hasDownloaded = false
        hasUserInput = false
        answer = nil
    }
}
