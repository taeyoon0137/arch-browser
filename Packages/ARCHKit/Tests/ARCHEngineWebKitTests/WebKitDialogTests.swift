// How a WebKit page dialog is answered: once, by the sheet or by a navigation the user starts, whichever comes first. A navigation gives a waiting dialog its safe answer, sets a hold on the page's further dialogs that ends when loading stops, and tells the UI delegate once that the dialog no longer applies. The tests use a private profile, which keeps nothing on disk, and load no page.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing

@MainActor @Suite struct WebKitDialogTests {
    private let tab: WebKitWebContents

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
        let browser = application.createBrowser(context: application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent()))
        tab = try #require(browser.createWebContents(EngineWebContentsConfiguration()) as? WebKitWebContents)
    }

    @Test func aDialogTakesOnlyTheSheetsFirstAnswer() {
        let recorder = DialogRecorder()
        tab.uiDelegate = recorder
        var answers: [Bool] = []
        let answer = tab.trackDialog(safeAnswer: false) { answers.append($0) }
        answer(true)
        answer(false)
        tab.dismissDialogBeforeNavigation()
        #expect(answers == [true])
        #expect(!tab.suppressesDialogs)
        #expect(recorder.cancellations == 0)
    }

    @Test func aNavigationGivesTheWaitingDialogItsSafeAnswer() {
        let recorder = DialogRecorder()
        tab.uiDelegate = recorder
        var answers: [String?] = []
        let answer = tab.trackDialog(safeAnswer: nil as String?) { answers.append($0) }
        tab.dismissDialogBeforeNavigation()
        answer("typed")
        #expect(answers == [nil])
        #expect(tab.suppressesDialogs)
        #expect(recorder.cancellations == 1)
        tab.dismissDialogBeforeNavigation()
        #expect(recorder.cancellations == 1)
        tab.loadingStateDidChange()
        #expect(!tab.suppressesDialogs)
    }

    private final class DialogRecorder: EngineWebContentsUIDelegate {
        private(set) var cancellations = 0

        func webContentsDidCancelDialogs(_ webContents: any EngineWebContents) {
            cancellations += 1
        }
    }
}
