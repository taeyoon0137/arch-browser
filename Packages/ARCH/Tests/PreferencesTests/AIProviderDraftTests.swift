// The key an HTTP provider's editor sends with Refresh and stores with Save.
import Testing
@testable import Preferences

@Suite struct AIProviderDraftTests {
    @Test func theEnteredKeyLosesTheSpacesAndLineBreaksACopyCarries() {
        var draft = AIProviderDraft()
        draft.newKey = "  sk-test\n"
        #expect(draft.enteredKey == "sk-test")
        draft.newKey = " \n"
        #expect(draft.enteredKey.isEmpty)
    }
}
