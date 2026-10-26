// Which match a WebKit search reports as active: the selected match where the find script places it, otherwise one step from the same search's last match, wrapping around at either end, and the first or last match for a new search. WebKit found a match the script may not see, so a search counts at least one. The tests start no web view.
import ARCHEngine
@testable import ARCHEngineWebKit
import Testing

@Suite struct WebKitFindResultTests {
    private func result(counted: Int, selected: Int? = nil, previous: Int? = nil, forward: Bool = true) -> EngineFindResult {
        WebKitWebContents.findResult(countedMatches: counted, selectedMatch: selected, previousOrdinal: previous, forward: forward)
    }

    @Test func theSelectedMatchIsActive() {
        #expect(result(counted: 5, selected: 3, previous: 1) == EngineFindResult(activeMatchOrdinal: 3, numberOfMatches: 5))
        #expect(result(counted: 5, selected: 3, previous: 4, forward: false) == EngineFindResult(activeMatchOrdinal: 3, numberOfMatches: 5))
    }

    @Test func aRepeatedSearchStepsFromItsLastMatchAndWrapsAround() {
        #expect(result(counted: 5, previous: 2).activeMatchOrdinal == 3)
        #expect(result(counted: 5, previous: 5).activeMatchOrdinal == 1)
        #expect(result(counted: 5, previous: 3, forward: false).activeMatchOrdinal == 2)
        #expect(result(counted: 5, previous: 1, forward: false).activeMatchOrdinal == 5)
    }

    @Test func aNewSearchStartsAtTheFirstMatchForwardAndTheLastBackward() {
        #expect(result(counted: 4) == EngineFindResult(activeMatchOrdinal: 1, numberOfMatches: 4))
        #expect(result(counted: 4, forward: false) == EngineFindResult(activeMatchOrdinal: 4, numberOfMatches: 4))
    }

    @Test func aMatchTheScriptCannotSeeCountsAsOne() {
        #expect(result(counted: 0) == EngineFindResult(activeMatchOrdinal: 1, numberOfMatches: 1))
        #expect(result(counted: 0, previous: 1, forward: false) == EngineFindResult(activeMatchOrdinal: 1, numberOfMatches: 1))
    }
}
