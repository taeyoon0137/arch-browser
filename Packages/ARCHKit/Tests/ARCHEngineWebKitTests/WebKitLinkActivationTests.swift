// Link classification uses WebKit's public navigation metadata without creating a web view.
@testable import ARCHEngineWebKit
import Foundation
import Testing
import WebKit

@MainActor @Suite struct WebKitLinkActivationTests {
    @Test func primaryAndMiddleLinkClicksAreUserInitiated() {
        for button in [1, 4] {
            #expect(WebKitDelegateBridge.isUserInitiatedLink(navigationType: .linkActivated, buttonNumber: button))
        }
    }

    @Test func downloadLinksStayOutsideLinkOpeningPolicy() {
        for button in [1, 4] {
            #expect(!WebKitDelegateBridge.isUserInitiatedLink(navigationType: .linkActivated, buttonNumber: button, shouldPerformDownload: true))
        }
    }

    @Test func explicitOpenerEvidenceMatchesOnlyItsFreshLinkAndSourceFrame() {
        let url = URL(string: "https://login.example/authorize")!
        let frame = URL(string: "https://source.example/account")!
        let evidence = WebKitOpenerLink(url: url, frameURL: frame, time: 10)
        #expect(evidence.matches(url: url, frameURL: frame, time: 10.1))
        #expect(!evidence.matches(url: URL(string: "https://login.example/other"), frameURL: frame, time: 10.1))
        #expect(!evidence.matches(url: url, frameURL: URL(string: "https://source.example/other"), time: 10.1))
        #expect(!evidence.matches(url: url, frameURL: frame, time: 11))
        #expect(!evidence.matches(url: url, frameURL: frame, time: 9))
        #expect(!WebKitDelegateBridge.isUserInitiatedLink(navigationType: .linkActivated, buttonNumber: 1, requiresOpener: true))
    }

    @Test func aScriptActivatedLinkWithoutATrustedMouseButtonIsNotAUserClick() {
        #expect(!WebKitDelegateBridge.isUserInitiatedLink(navigationType: .linkActivated, buttonNumber: 0))
        for button in [-1, 2, 8, 16] {
            #expect(!WebKitDelegateBridge.isUserInitiatedLink(navigationType: .linkActivated, buttonNumber: button))
        }
    }

    @Test func aMouseButtonDoesNotMakeScriptsOrFormsIntoLinks() {
        for type in [WKNavigationType.other, .formSubmitted, .formResubmitted, .backForward, .reload] {
            for button in [0, 1, 4] {
                #expect(!WebKitDelegateBridge.isUserInitiatedLink(navigationType: type, buttonNumber: button))
            }
        }
    }
}
