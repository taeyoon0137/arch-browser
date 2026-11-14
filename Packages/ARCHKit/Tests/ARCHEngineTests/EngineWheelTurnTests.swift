// The whole-point deltas that both adapters send for a wheel turn: rounded, clamped to the stated range either way, and refused when not finite.
import ARCHEngine
import Testing

@Suite struct EngineWheelTurnTests {
    @Test func deltasAreRoundedToWholePoints() throws {
        let turn = try EngineWheelTurn(deltaX: -2.5, deltaY: 120.4)
        #expect(turn.deltaX == -3 && turn.deltaY == 120)
    }

    @Test func deltasBeyondTheRangeAreClamped() throws {
        let turn = try EngineWheelTurn(deltaX: -1e10, deltaY: 3e9)
        #expect(turn.deltaX == -EngineWheelTurn.maximumDelta && turn.deltaY == EngineWheelTurn.maximumDelta)
        #expect(EngineWheelTurn.maximumDelta < Int(Int32.max))
    }

    @Test func aDeltaThatIsNotFiniteIsRefused() {
        for delta in [Double.nan, .infinity, -.infinity] {
            #expect(throws: EngineInputError.unsupported) { try EngineWheelTurn(deltaX: delta, deltaY: 0) }
            #expect(throws: EngineInputError.unsupported) { try EngineWheelTurn(deltaX: 0, deltaY: delta) }
        }
    }
}
