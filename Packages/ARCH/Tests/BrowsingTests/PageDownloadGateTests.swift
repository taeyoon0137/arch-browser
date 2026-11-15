// When a page's downloads wait for the user: the first goes through, and so does one after a click in the page or one that an address Arch loads for the user starts; the others ask once, and the answer decides them all and the page's later ones. An Allow ends with the document, and the gate starts over at a document the user asked for or one on another site, but not at one the page loads on its own on its site. A tab that a plugin opened has no first download on any site until the user clicks in it or loads an address there.
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
        gate.userDidClick()
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

    /// A page that downloads a file and then reloads itself, or changes its address on its site, without a click gets no new first download, and a refusal holds through its reloads.
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
        gate.userDidClick()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        gate.userDidNavigate()
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// An address that the user loads in the tab and that turns out to be a file downloads even after a refusal, once.
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

    /// A load the user started that commits a document leaves no pass, so the page's own downloads there count as usual: a click before its first download lets no second one through.
    @Test func aUserLoadThatCommitsADocumentLeavesNoPass() {
        var gate = PageDownloadGate()
        gate.userDidNavigate()
        gate.documentDidCommit(site: "files.example")
        gate.userDidClick()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// A tab that a plugin opened asks before each download of its pages, its first included, on every site it moves to on its own, until the user clicks in it or loads an address there.
    @Test func aTabThatAPluginOpenedHasNoFirstDownloadUntilTheUserActs() {
        var gate = PageDownloadGate()
        gate.pluginDidOpen()
        #expect(gate.isOpenedByPlugin)
        gate.documentDidCommit(site: "files.example")
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(true).count == 1)
        #expect(gate.admit { _ in } == .allow)
        gate.documentDidCommit(site: "other.example")
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        gate.userDidClick()
        #expect(!gate.isOpenedByPlugin)
        gate.documentDidCommit(site: "other.example")
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)

        var loaded = PageDownloadGate()
        loaded.pluginDidOpen()
        loaded.userDidNavigate()
        #expect(!loaded.isOpenedByPlugin)
        loaded.documentDidCommit(site: "files.example")
        #expect(loaded.admit { _ in } == .allow)
    }
}
