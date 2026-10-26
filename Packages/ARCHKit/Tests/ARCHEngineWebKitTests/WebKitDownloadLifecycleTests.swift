// How a WebKit download answers pause, resume, and cancel while WebKit's reports arrive late: a pause that meets the download's finish, a resume while the pause still stops the download, a second resume before WebKit restarts the download, a cancel before the restarted download arrives, and a failed download with and without resume data. A test cannot make a `WKDownload`, so the tests drive `WebKitDownloadLifecycle`, whose decisions the adapter's download item carries out. `#expect` cannot hold a mutating call, so each test takes the lifecycle's answers first.
@testable import ARCHEngineWebKit
import Foundation
import Testing

@Suite struct WebKitDownloadLifecycleTests {
    private let data = Data("resume".utf8)

    @Test func aPauseThatMeetsTheFinishCompletes() {
        var lifecycle = WebKitDownloadLifecycle()
        let stops = lifecycle.pause()
        lifecycle.didFinish()
        let restart = lifecycle.didStop(resumeData: nil)
        let resume = lifecycle.resume()
        #expect(stops)
        #expect(restart == nil)
        #expect(resume == nil)
        #expect(lifecycle.state == .completed)
    }

    @Test func aFinishAfterThePauseStoppedWithoutResumeDataCompletes() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        let restart = lifecycle.didStop(resumeData: nil)
        #expect(restart == nil)
        #expect(lifecycle.state == .cancelled)
        lifecycle.didFinish()
        #expect(lifecycle.state == .completed)
    }

    @Test func aPauseIgnoresTheInterruptionItCauses() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        lifecycle.didFail(resumeData: data)
        #expect(lifecycle.state == .paused)
        let restart = lifecycle.didStop(resumeData: data)
        #expect(restart == nil)
        #expect(lifecycle.state == .paused)
        #expect(lifecycle.resumeData == data)
        #expect(!lifecycle.isStopping)
    }

    @Test func onlyADownloadInProgressPauses() {
        var lifecycle = WebKitDownloadLifecycle()
        let first = lifecycle.pause()
        let second = lifecycle.pause()
        lifecycle.didFinish()
        let afterFinish = lifecycle.pause()
        #expect(first)
        #expect(!second)
        #expect(!afterFinish)
    }

    @Test func aSecondResumeBeforeWebKitRestartsTheDownloadDoesNothing() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        _ = lifecycle.didStop(resumeData: data)
        let first = lifecycle.resume()
        let second = lifecycle.resume()
        #expect(first == .resumeData(data))
        #expect(second == nil)
        #expect(lifecycle.state == .paused)
        #expect(lifecycle.isRestarting)
        let takes = lifecycle.didRestart()
        #expect(takes)
        #expect(lifecycle.state == .inProgress)
        #expect(lifecycle.resumeData == nil)
        #expect(!lifecycle.isRestarting)
    }

    @Test func aResumeWhileThePauseStopsTheDownloadWaitsForTheResumeData() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        let early = lifecycle.resume()
        let again = lifecycle.resume()
        let restart = lifecycle.didStop(resumeData: data)
        let afterRestart = lifecycle.resume()
        let takes = lifecycle.didRestart()
        #expect(early == nil)
        #expect(again == nil)
        #expect(restart == .resumeData(data))
        #expect(afterRestart == nil)
        #expect(takes)
        #expect(lifecycle.state == .inProgress)
    }

    @Test func aResumeThatWaitsRestartsFromTheStartWithoutResumeData() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        _ = lifecycle.resume()
        let restart = lifecycle.didStop(resumeData: nil)
        #expect(restart == .start)
        #expect(lifecycle.state == .paused)
    }

    @Test func aCancelWhileThePauseStopsTheDownloadDropsTheWaitingResume() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        _ = lifecycle.resume()
        let stops = lifecycle.cancel()
        let restart = lifecycle.didStop(resumeData: data)
        #expect(!stops)
        #expect(restart == nil)
        #expect(lifecycle.state == .cancelled)
        #expect(lifecycle.resumeData == nil)
    }

    @Test func aPauseWithoutResumeDataCancels() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        let restart = lifecycle.didStop(resumeData: nil)
        let resume = lifecycle.resume()
        #expect(restart == nil)
        #expect(resume == nil)
        #expect(lifecycle.state == .cancelled)
    }

    @Test func aDownloadCancelledBeforeWebKitRestartsItRefusesTheNewDownload() {
        var lifecycle = WebKitDownloadLifecycle()
        _ = lifecycle.pause()
        _ = lifecycle.didStop(resumeData: data)
        _ = lifecycle.resume()
        let stops = lifecycle.cancel()
        let takes = lifecycle.didRestart()
        #expect(!stops)
        #expect(!takes)
        #expect(lifecycle.state == .cancelled)
    }

    @Test func aFailedDownloadWithoutResumeDataRestartsFromTheStart() {
        var lifecycle = WebKitDownloadLifecycle()
        lifecycle.didFail(resumeData: nil)
        #expect(lifecycle.state == .failed)
        let restart = lifecycle.resume()
        #expect(restart == .start)
        #expect(lifecycle.state == .failed)
        let takes = lifecycle.didRestart()
        #expect(takes)
        #expect(lifecycle.state == .inProgress)
    }

    @Test func aFailedDownloadWithResumeDataResumesFromIt() {
        var lifecycle = WebKitDownloadLifecycle()
        lifecycle.didFail(resumeData: data)
        let restart = lifecycle.resume()
        #expect(restart == .resumeData(data))
    }

    @Test func cancellingAFailedDownloadGivesUpItsResumeData() {
        var lifecycle = WebKitDownloadLifecycle()
        lifecycle.didFail(resumeData: data)
        let stops = lifecycle.cancel()
        let resume = lifecycle.resume()
        #expect(!stops)
        #expect(resume == nil)
        #expect(lifecycle.state == .cancelled)
        #expect(lifecycle.resumeData == nil)
    }

    @Test func cancellingStopsOnlyADownloadInProgress() {
        var running = WebKitDownloadLifecycle()
        let stops = running.cancel()
        let again = running.cancel()
        running.didFail(resumeData: data)
        #expect(stops)
        #expect(!again)
        #expect(running.state == .cancelled)

        var finished = WebKitDownloadLifecycle()
        finished.didFinish()
        let stopsFinished = finished.cancel()
        #expect(!stopsFinished)
        #expect(finished.state == .completed)
    }
}
