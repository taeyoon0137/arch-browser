// The rules a prompt card follows apart from its views: which buttons Return and Escape press, when Escape waits, when the buttons that grant something arm, how wide a card is in its pane and when it is compact, and where a page's long text ends.
import Foundation
import Testing
@testable import Browsing

@Suite struct PromptKeysTests {
    private static func content(_ buttons: [PromptButton], defaultID: String?, cancelID: String?) -> PromptContent {
        PromptContent(kind: .notice, identity: PromptIdentity(icon: .symbol("globe"), name: "example.com", isSecure: false),
                      buttons: buttons, defaultButtonID: defaultID, cancelButtonID: cancelID)
    }

    @Test func returnPressesTheDefaultButtonAndEscapeTheCancelButton() {
        let content = Self.content([PromptButton(id: "deny", title: "Don\u{2019}t Allow"), PromptButton(id: "allow", title: "Allow", needsArming: true)], defaultID: "allow", cancelID: "deny")
        #expect(PromptKeys.returnButton(in: content) == "allow")
        #expect(PromptKeys.escapeButton(in: content) == "deny")
    }

    @Test func aLoneButtonTakesBothKeys() {
        let content = Self.content([PromptButton(id: "ok", title: "OK")], defaultID: nil, cancelID: nil)
        #expect(PromptKeys.returnButton(in: content) == "ok")
        #expect(PromptKeys.escapeButton(in: content) == "ok")
    }

    @Test func returnNeverPressesADestructiveButton() {
        let content = Self.content([PromptButton(id: "cancel", title: "Cancel"), PromptButton(id: "delete", title: "Delete", isDestructive: true)], defaultID: "delete", cancelID: "cancel")
        #expect(PromptKeys.returnButton(in: content) == nil)
        #expect(PromptKeys.escapeButton(in: content) == "cancel")
    }

    @Test func escapeWaitsWithTheButtonsThatGrantSomething() {
        let permission = [PromptButton(id: "deny", title: "Don\u{2019}t Allow"), PromptButton(id: "allow", title: "Allow", needsArming: true)]
        #expect(PromptKeys.escapeWaits(for: permission, isArmed: false))
        #expect(!PromptKeys.escapeWaits(for: permission, isArmed: true))
        // A card that grants nothing, as a page's confirm, takes Escape at once.
        let confirm = [PromptButton(id: "cancel", title: "Cancel"), PromptButton(id: "ok", title: "OK")]
        #expect(!PromptKeys.escapeWaits(for: confirm, isArmed: false))
    }

    @Test func clearSiteDataGivesBothKeysToCancel() {
        let content = TabPromptContent.clearSiteData(siteName: "example.com", personaSpace: nil, identity: PromptIdentity(icon: .symbol("globe"), name: "", isSecure: true))
        #expect(PromptKeys.returnButton(in: content) == "cancel")
        #expect(PromptKeys.escapeButton(in: content) == "cancel")
        #expect(content.buttons.first { $0.id == "clear" }?.isDestructive == true)
    }
}

@Suite struct PromptArmingTests {
    @Test func buttonsArmHalfASecondAfterTheCardShowsAndAgainAfterARestart() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var arming = PromptArming(shownAt: start)
        #expect(!arming.isArmed(at: start))
        #expect(!arming.isArmed(at: start.addingTimeInterval(0.49)))
        #expect(arming.isArmed(at: start.addingTimeInterval(0.5)))
        #expect(arming.armedAt == start.addingTimeInterval(0.5))

        let back = start.addingTimeInterval(10)
        arming.restart(at: back)
        #expect(!arming.isArmed(at: back.addingTimeInterval(0.2)))
        #expect(arming.isArmed(at: back.addingTimeInterval(0.6)))
    }
}

@Suite struct PromptLayoutTests {
    @Test func aCardIsAtMost420PointsAndLeavesTheEdgesOfItsPane() {
        #expect(PromptLayout.cardWidth(inPaneWidth: 1_200) == 420)
        #expect(PromptLayout.cardWidth(inPaneWidth: 444) == 420)
        #expect(PromptLayout.cardWidth(inPaneWidth: 400) == 376)
        #expect(PromptLayout.cardWidth(inPaneWidth: 224) == 200)
        // Less than 200 left: the pane less 4 points a side.
        #expect(PromptLayout.cardWidth(inPaneWidth: 210) == 202)
        #expect(PromptLayout.cardWidth(inPaneWidth: 127) == 119)
        #expect(PromptLayout.cardWidth(inPaneWidth: 4) == 0)
        #expect(PromptLayout.maximumHeight(inPaneHeight: 500) == 484)
    }

    @Test func aCardNarrowerThan320PointsIsCompact() {
        #expect(PromptLayout.layout(forCardWidth: 420) == .regular)
        #expect(PromptLayout.layout(forCardWidth: 320) == .regular)
        #expect(PromptLayout.layout(forCardWidth: 319) == .compact)
        #expect(PromptLayout.compact.spacing(12) == 9)
        #expect(PromptLayout.regular.spacing(12) == 12)
    }
}

@Suite struct PageAuthoredTextTests {
    @Test func aPagesTextEndsAtTenThousandCharacters() {
        let long = PageAuthoredText(text: String(repeating: "a", count: 10_001))
        #expect(long.text.count == 10_001)
        #expect(long.text.hasSuffix("a\u{2026}"))
        let exact = PageAuthoredText(caption: "The site says", text: String(repeating: "b", count: 10_000))
        #expect(exact.text.count == 10_000 && !exact.text.hasSuffix("\u{2026}"))
        #expect(exact.caption == "The site says")
    }
}
