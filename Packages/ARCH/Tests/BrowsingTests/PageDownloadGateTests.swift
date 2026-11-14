// When a page's downloads wait for the user: the first goes through, and so does one after a click in the page; the others ask once, the answer decides them all and the document's later ones, and another document starts over.
import Testing
@testable import Browsing

@Suite struct PageDownloadGateTests {
    @Test func aPageDownloadsOnceWithoutAskingThenAsksOnceForTheRest() {
        var gate = PageDownloadGate()
        var decided: [Bool] = []
        #expect(gate.admit { decided.append($0) } == .allow)
        #expect(gate.admit { decided.append($0) } == .ask)
        #expect(gate.admit { decided.append($0) } == .wait)
        let waiting = gate.answer(true)
        waiting.forEach { $0(true) }
        #expect(waiting.count == 2 && decided == [true, true])
        #expect(gate.admit { _ in } == .allow)
    }

    @Test func aRefusalEndsTheDocumentsDownloadsUntilAnotherDocumentLoads() {
        var gate = PageDownloadGate()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        #expect(gate.answer(false).count == 1)
        #expect(gate.admit { _ in } == .deny)
        gate.documentDidLoad()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    @Test func aClickInThePageAllowsOneMoreDownload() {
        var gate = PageDownloadGate()
        #expect(gate.admit { _ in } == .allow)
        gate.userDidClick()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }

    /// An answer to a question that an earlier document raised decides the downloads that waited for it, not those of the next document.
    @Test func anAnswerForAnEarlierDocumentLeavesTheNextOneToAskAgain() {
        var gate = PageDownloadGate()
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
        gate.documentDidLoad()
        #expect(gate.answer(true).count == 1)
        #expect(gate.admit { _ in } == .allow)
        #expect(gate.admit { _ in } == .ask)
    }
}
