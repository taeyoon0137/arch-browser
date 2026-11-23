// A page's first download goes through. So does one after a click in the page or one started by an address Arch loads for the user. The other downloads ask once. The answer decides them all and the page's later downloads. An Allow ends with the document. The gate resets at a document the user requested or one on another site. It does not reset when the page loads a document on its own site without the user. A tab that a plugin opened has no first download on any site until the user clicks in it or loads an address there.
import Testing
@testable import Browsing

@Suite struct PageDownloadGateTests {
    @Test func aPageDownloadsOnceWithoutAskingThenAsksOnceForTheRest() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        var decided: [Bool] = []
        #expect(gate.admit { decided.append($0) } == .allow)
        #expect(gate.admit { decided.append($0) } == .ask)
        #expect(gate.admit { decided.append($0) } == .wait)
        let waiting = gate.answer(true)
        waiting.forEach { $0(true) }
        #expect(waiting.count == 2 && decided == [true, true])
        #expect(gate.admit { _ in } == .allow)
    }

    @Test func aRefusalEndsThePagesDownloadsUntilTheTabMovesToAnotherSite() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        #expect(gate.admit { _ in } == .deny)
        gate.documentDidCommit(site: "other.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    @Test func aClickInThePageAllowsOneMoreDownload() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        gate.userDidAct()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// An answer to a question asked before the gate started over decides the downloads that waited for it, not those of the next document.
    @Test func anAnswerForAnEarlierSiteLeavesTheNextDocumentToAskAgain() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        gate.documentDidCommit(site: "other.example")
        #expect(gate.answer(true).count == 1)
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// An Allow on one page does not carry over to the next, whether the page's link or script leads to another site or to its own.
    @Test func anAllowEndsWithTheDocument() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        _ = gate.answer(true)
        #expect(gate.admit { _ in } == .allow)
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .ask)
        _ = gate.answer(true)
        gate.documentDidCommit(site: "other.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// A page gets no new first download if it downloads a file, then reloads itself or changes its address on its site without a click. A refusal holds through its reloads.
    @Test func aPageThatReloadsItselfKeepsItsDownloadsAndRefusal() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        for _ in 0..<3 {
            gate.documentDidCommit(site: "files.example")
            #expect(gate.admit { _ in } == .ask)
            #expect(gate.answer(true).count == 1)
        }
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        for _ in 0..<3 {
            gate.documentDidCommit(site: "files.example")
            #expect(gate.admit { _ in } == .deny)
        }
    }

    /// A click in the page before the next document, as on a link, or a load Arch starts for the user starts the gate over on the same site.
    @Test func aDocumentTheUserAskedForStartsOver() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        gate.userDidAct()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        gate.userDidNavigate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// An address the user loads in the tab may point to a file. That file downloads once, even after a refusal.
    @Test func aDownloadThatTheUserLoadsGoesOnAfterARefusal() {
        var gate = PageDownloadGate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        gate.userDidNavigate()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .deny)
    }

    /// A load the user started leaves no pass once it commits a document. The page's downloads then count as usual. A click before its first download lets no second one through.
    @Test func aUserLoadThatCommitsADocumentLeavesNoPass() {
        var gate = PageDownloadGate()
        gate.userDidNavigate()
        gate.documentDidCommit(site: "files.example")
        gate.userDidAct()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// A tab that a plugin opened asks before each page download, including the first. This applies on every site it moves to on its own until the user clicks in it or loads an address there.
    @Test func aTabThatAPluginOpenedHasNoFirstDownloadUntilTheUserActs() {
        var gate = PageDownloadGate()
        gate.holdUntilUserActs()
        #expect(gate.isHeldUntilUserActs)
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(true).count == 1)
        #expect(gate.admit { _ in } == .allow)
        gate.documentDidCommit(site: "other.example")
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        gate.userDidAct()
        #expect(!gate.isHeldUntilUserActs)
        gate.documentDidCommit(site: "other.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)

        var loaded = PageDownloadGate()
        loaded.holdUntilUserActs()
        loaded.userDidNavigate()
        #expect(!loaded.isHeldUntilUserActs)
        loaded.documentDidCommit(site: "files.example")
        #expect(loaded.admit { _ in } == .allow)
    }
}
