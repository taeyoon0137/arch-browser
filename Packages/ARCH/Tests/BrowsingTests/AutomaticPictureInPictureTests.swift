import ARCHEngine
import Foundation
import JavaScriptCore
import Testing
@testable import Browsing

@MainActor @Suite struct AutomaticPictureInPictureTests {
    private func page() -> PageStub { PageStub(engine: .webKit, url: URL(string: "https://example.org/video")!) }

    @Test func settingIsOnByDefaultAndHonorsAnExplicitChoice() throws {
        let suite = "ArchAutomaticPiP-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AutomaticPictureInPictureSetting.isEnabled(in: defaults))
        defaults.set(false, forKey: AutomaticPictureInPictureSetting.defaultsKey)
        #expect(!AutomaticPictureInPictureSetting.isEnabled(in: defaults))
        defaults.set(true, forKey: AutomaticPictureInPictureSetting.defaultsKey)
        #expect(AutomaticPictureInPictureSetting.isEnabled(in: defaults))
    }

    @Test func everyFocusLossConditionHidesInlineVideo() {
        let focused = PictureInPictureFocus(appIsActive: true, windowIsKey: true, windowIsMain: true, windowIsMinimized: false)
        #expect(focused.showsInline)
        var inactive = focused; inactive.appIsActive = false
        var notKey = focused; notKey.windowIsKey = false
        var notMain = focused; notMain.windowIsMain = false
        var minimized = focused; minimized.windowIsMinimized = true
        #expect(!inactive.showsInline && !notKey.showsInline && !notMain.showsInline && !minimized.showsInline)
    }

    @Test func tabOrSpaceSwitchStartsOnceAndReturningStops() {
        let controller = AutomaticPictureInPicture(), video = page(), next = page()
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        #expect(video.automaticPictureInPictureRequests.isEmpty)
        controller.update(selected: next, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: next, isFocused: false, enabled: true, hasPictureInPicture: true)
        #expect(video.automaticPictureInPictureRequests == [true])
        #expect(next.automaticPictureInPictureRequests.isEmpty)
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: true)
        #expect(video.automaticPictureInPictureRequests == [true, false])
    }

    @Test func repeatedFocusLossDoesNotRestartAndFocusReturnStops() {
        let controller = AutomaticPictureInPicture(), video = page()
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        for _ in 0..<4 { controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false) }
        #expect(video.automaticPictureInPictureRequests == [true])
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: true)
        #expect(video.automaticPictureInPictureRequests == [true, false])
    }

    @Test func disabledAndExistingPagePictureInPictureNeverStart() {
        for existing in [false, true] {
            let controller = AutomaticPictureInPicture(), video = page()
            controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: existing)
            controller.update(selected: nil, isFocused: false, enabled: existing, hasPictureInPicture: existing)
            #expect(video.automaticPictureInPictureRequests.isEmpty)
        }
    }

    @Test func disablingWhileAwayStopsOnlyTheAutomaticRequest() {
        let controller = AutomaticPictureInPicture(), video = page()
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: false, hasPictureInPicture: true)
        #expect(video.automaticPictureInPictureRequests == [true, false])
    }

    @Test func aFailedStopCanBeRetriedWhenAutomaticPictureInPictureIsDisabled() {
        let controller = AutomaticPictureInPicture(), video = page()
        video.automaticPictureInPictureRequested = { enabled, completion in
            if enabled { video.isInPictureInPicture = true }
            completion(enabled)
        }
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: true)
        controller.update(selected: video, isFocused: true, enabled: false, hasPictureInPicture: true)
        #expect(video.automaticPictureInPictureRequests == [true, false, false])
    }

    @Test func returningBeforeStartCompletesClosesTheLatePresentation() throws {
        let controller = AutomaticPictureInPicture(), video = page()
        var finish: ((Bool) -> Void)?
        video.automaticPictureInPictureRequested = { enabled, completion in
            if enabled { finish = completion } else { completion(true) }
        }
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        #expect(video.automaticPictureInPictureRequests == [true, false])
        let complete = try #require(finish)
        complete(true)
        #expect(video.automaticPictureInPictureRequests == [true, false, false])
    }

    @Test func failedEntryWaitsForAnotherFocusTransition() {
        let controller = AutomaticPictureInPicture(), video = page()
        video.automaticPictureInPictureRequested = { _, completion in completion(false) }
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        #expect(video.automaticPictureInPictureRequests == [true])
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        #expect(video.automaticPictureInPictureRequests == [true, true])
    }

    @Test func returningStopsEvenBeforeTheEngineReportsTheStartedPresentation() {
        let controller = AutomaticPictureInPicture(), video = page()
        video.automaticPictureInPictureRequested = { _, completion in completion(true) }
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        #expect(video.automaticPictureInPictureRequests == [true, false])
    }

    @Test func closingTheSystemWindowAllowsTheNextVideoToStart() {
        let controller = AutomaticPictureInPicture(), first = page(), second = page()
        controller.update(selected: first, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: second, isFocused: true, enabled: true, hasPictureInPicture: false)
        first.isInPictureInPicture = false
        controller.update(selected: second, isFocused: false, enabled: true, hasPictureInPicture: false)
        #expect(first.automaticPictureInPictureRequests == [true])
        #expect(second.automaticPictureInPictureRequests == [true])
    }

    @Test func aPendingStopCannotCloseANewAutomaticPresentation() throws {
        let controller = AutomaticPictureInPicture(), first = page(), second = page()
        var finishStop: ((Bool) -> Void)?
        first.automaticPictureInPictureRequested = { enabled, completion in
            if enabled { first.isInPictureInPicture = true; completion(true) }
            else { finishStop = completion }
        }
        controller.update(selected: first, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: first, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: first, isFocused: true, enabled: true, hasPictureInPicture: true)
        controller.update(selected: second, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: second, isFocused: false, enabled: true, hasPictureInPicture: false)
        #expect(second.automaticPictureInPictureRequests.isEmpty)
        first.isInPictureInPicture = false
        let complete = try #require(finishStop)
        complete(true)
        #expect(second.automaticPictureInPictureRequests == [true])
    }

    @Test func returningAndLeavingDuringStartupStartsTheLatestDeparture() throws {
        let controller = AutomaticPictureInPicture(), video = page()
        var finishes: [(Bool) -> Void] = []
        video.automaticPictureInPictureRequested = { enabled, completion in
            if enabled { finishes.append(completion) } else { completion(true) }
        }
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        #expect(video.automaticPictureInPictureRequests == [true, false])
        let complete = try #require(finishes.first)
        complete(true)
        #expect(video.automaticPictureInPictureRequests == [true, false, false, true])
        #expect(finishes.count == 2)
    }

    @Test func returningAgainCancelsTheDepartureWaitingForAStop() throws {
        let controller = AutomaticPictureInPicture(), video = page()
        var finish: ((Bool) -> Void)?
        video.automaticPictureInPictureRequested = { enabled, completion in
            if enabled { finish = completion } else { completion(true) }
        }
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: false, enabled: true, hasPictureInPicture: false)
        controller.update(selected: video, isFocused: true, enabled: true, hasPictureInPicture: false)
        let complete = try #require(finish)
        complete(true)
        #expect(video.automaticPictureInPictureRequests == [true, false, false])
    }

    @Test func closingBeforeAnyNativeReportStillAllowsTheNextDeparture() {
        let controller = AutomaticPictureInPicture(), first = page(), second = page()
        first.automaticPictureInPictureRequested = { _, completion in completion(true) }
        controller.update(selected: first, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: second, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: second, isFocused: false, enabled: true, hasPictureInPicture: false)
        #expect(first.automaticPictureInPictureRequests == [true, false])
        #expect(second.automaticPictureInPictureRequests == [true])
    }

    private func scriptContext(_ setup: String = "") throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        let timers = new Map(), nextTimer = 0, calls = [];
        function setTimeout(callback) { timers.set(++nextTimer, callback); return nextTimer; }
        function clearTimeout(id) { timers.delete(id); }
        const listeners = new Map();
        const video = {
          readyState: 4, paused: false, ended: false, muted: false, volume: 1,
          videoWidth: 1920, videoHeight: 1080, disablePictureInPicture: false,
          webkitPresentationMode: 'inline',
          getBoundingClientRect: () => ({ width: 640, height: 360 }),
          addEventListener(name, fn) { if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name).add(fn); },
          removeEventListener(name, fn) { listeners.get(name)?.delete(fn); },
          dispatch(name) { for (const fn of [...(listeners.get(name) || [])]) fn(); },
          requestPictureInPicture() { calls.push('start'); document.pictureInPictureElement = this; this.dispatch('enterpictureinpicture'); return Promise.resolve(); }
        };
        const document = { pictureInPictureElement: null, querySelectorAll: query => query === 'video' ? [video] : [],
          exitPictureInPicture() { calls.push('stop'); this.pictureInPictureElement = null; video.dispatch('leavepictureinpicture'); return Promise.resolve(); } };
        video.ownerDocument = document;
        \(setup)
        """)
        try #require(context.exception == nil)
        return context
    }

    private func run(_ context: JSContext, starting: Bool = true) throws -> Bool? {
        context.evaluateScript("globalThis.result = undefined; \(EnginePictureInPictureScript.automatic(starting: starting)).then(value => globalThis.result = value)")
        try #require(context.exception == nil)
        let result = context.objectForKeyedSubscript("result")!
        return result.isUndefined ? nil : result.toBool()
    }

    @Test(arguments: ["video.paused = true", "video.ended = true", "video.muted = true", "video.volume = 0", "video.readyState = 1",
                      "video.disablePictureInPicture = true", "video.videoWidth = 0", "video.videoHeight = NaN", "video.videoWidth = Infinity",
                      "video.getBoundingClientRect = () => ({ width: 159, height: 90 })",
                      "video.getBoundingClientRect = () => ({ width: 160, height: 89 })",
                      "video.getBoundingClientRect = () => ({ width: Infinity, height: 100 })",
                      "document.pictureInPictureElement = {}", "video.webkitPresentationMode = 'picture-in-picture'"])
    func ineligibleMediaDoesNotStart(_ setup: String) throws {
        let context = try scriptContext(setup)
        #expect(try run(context) == false)
        #expect(context.evaluateScript("calls.length").toInt32() == 0)
    }

    @Test func eligibleVideoStartsAndOnlyItsAutomaticPresentationStops() throws {
        let context = try scriptContext("video.getBoundingClientRect = () => ({ width: 160, height: 90 })")
        #expect(try run(context) == true)
        #expect(try run(context) == false)
        #expect(try run(context, starting: false) == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"start\",\"stop\"]")
    }

    @Test func prefixedPresentationUsesTheSameAutomaticOwnership() throws {
        let context = try scriptContext("""
        video.requestPictureInPicture = undefined;
        video.webkitSupportsPresentationMode = () => true;
        video.webkitSetPresentationMode = function(mode) {
          calls.push(mode); this.webkitPresentationMode = mode; this.dispatch('webkitpresentationmodechanged');
        };
        """)
        #expect(try run(context) == true)
        #expect(try run(context, starting: false) == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"picture-in-picture\",\"inline\"]")
    }

    @Test func manualReentryOfTheSameVideoIsNotClosedOnReturn() throws {
        let context = try scriptContext()
        #expect(try run(context) == true)
        context.evaluateScript("document.exitPictureInPicture(); video.requestPictureInPicture(); calls = []")
        #expect(try run(context, starting: false) == false)
        #expect(context.evaluateScript("calls.length").toInt32() == 0)
        #expect(context.evaluateScript("document.pictureInPictureElement === video").toBool() == true)
    }

    @Test func aRefusedExitKeepsAutomaticOwnershipForTheNextStop() throws {
        let context = try scriptContext()
        #expect(try run(context) == true)
        context.evaluateScript("const exit = document.exitPictureInPicture; document.exitPictureInPicture = () => Promise.reject(new Error('busy'))")
        #expect(try run(context, starting: false) == false)
        #expect(context.evaluateScript("document.pictureInPictureElement === video").toBool() == true)
        context.evaluateScript("document.exitPictureInPicture = exit")
        #expect(try run(context, starting: false) == true)
        #expect(context.evaluateScript("document.pictureInPictureElement === null").toBool() == true)
    }

    @Test func anOutstandingScriptStartIsCancelledWhenTheTabReturns() throws {
        let context = try scriptContext("video.requestPictureInPicture = () => new Promise(resolve => globalThis.finish = () => { document.pictureInPictureElement = video; video.dispatch('enterpictureinpicture'); resolve(); })")
        #expect(try run(context) == nil)
        #expect(try run(context, starting: false) == false)
        context.evaluateScript("finish()")
        #expect(context.evaluateScript("document.pictureInPictureElement === null").toBool() == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"stop\"]")
    }

    @Test(arguments: [false, true])
    func aTimedOutEntryIsClosedWhenTheEngineEventuallyStarts(prefixed: Bool) throws {
        let context = try scriptContext()
        if prefixed {
            context.evaluateScript("""
            video.requestPictureInPicture = undefined;
            video.webkitSupportsPresentationMode = () => true;
            video.webkitSetPresentationMode = function(mode) {
              if (mode === 'picture-in-picture') {
                calls.push('start');
                globalThis.finish = () => { this.webkitPresentationMode = mode; this.dispatch('webkitpresentationmodechanged'); };
              } else {
                calls.push('stop'); this.webkitPresentationMode = mode; this.dispatch('webkitpresentationmodechanged');
              }
            };
            """)
        } else {
            context.evaluateScript("""
            video.requestPictureInPicture = () => {
              calls.push('start');
              return new Promise(resolve => globalThis.finish = () => {
                document.pictureInPictureElement = video; video.dispatch('enterpictureinpicture'); resolve();
              });
            };
            """)
        }
        #expect(try run(context) == nil)
        context.evaluateScript("const expired = [...timers.values()]; timers.clear(); expired.forEach(callback => callback())")
        #expect(context.objectForKeyedSubscript("result").toBool() == false)
        #expect(try run(context, starting: false) == false)
        context.evaluateScript("finish()")
        #expect(context.evaluateScript("document.pictureInPictureElement === null && video.webkitPresentationMode === 'inline'").toBool() == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"start\",\"stop\"]")
        #expect(context.evaluateScript("globalThis.__archAutomaticPictureInPicture === undefined").toBool() == true)
        #expect(context.evaluateScript("[...listeners.values()].every(value => value.size === 0) && timers.size === 0").toBool() == true)
    }

    @Test(arguments: [false, true])
    func returningRetriesARefusedExitAfterATimedOutEntry(disabling: Bool) throws {
        let context = try scriptContext("""
        video.requestPictureInPicture = () => new Promise(resolve => globalThis.finish = () => {
          document.pictureInPictureElement = video; video.dispatch('enterpictureinpicture'); resolve();
        });
        const exit = document.exitPictureInPicture;
        document.exitPictureInPicture = () => Promise.reject(new Error('busy'));
        """)
        let controller = AutomaticPictureInPicture(), page = page()
        var completeStart: ((Bool) -> Void)?
        page.automaticPictureInPictureRequested = { [weak page] enabled, completion in
            do {
                if let result = try run(context, starting: enabled) {
                    page?.isInPictureInPicture = context.evaluateScript("document.pictureInPictureElement !== null").toBool()
                    completion(result)
                } else { completeStart = completion }
            } catch { Issue.record(error); completion(false) }
        }
        controller.update(selected: page, isFocused: true, enabled: true, hasPictureInPicture: false)
        controller.update(selected: page, isFocused: false, enabled: true, hasPictureInPicture: false)
        context.evaluateScript("const expired = [...timers.values()]; timers.clear(); expired.forEach(callback => callback())")
        let complete = try #require(completeStart)
        complete(false)
        context.evaluateScript("finish()")
        #expect(context.evaluateScript("document.pictureInPictureElement === video").toBool() == true)
        page.isInPictureInPicture = true
        context.evaluateScript("document.exitPictureInPicture = exit")
        controller.update(selected: disabling ? nil : page, isFocused: true, enabled: !disabling, hasPictureInPicture: true,
                          activePresentations: [page])
        #expect(context.evaluateScript("document.pictureInPictureElement === null").toBool() == true)
        #expect(page.automaticPictureInPictureRequests == [true, false])
    }

    @Test(arguments: [false, true])
    func reconcilingAnUntrackedPresentationNeverStopsManualPictureInPicture(disabling: Bool) throws {
        let context = try scriptContext()
        context.evaluateScript("video.requestPictureInPicture()")
        let controller = AutomaticPictureInPicture(), page = page()
        page.isInPictureInPicture = true
        page.automaticPictureInPictureRequested = { enabled, completion in
            do { completion(try run(context, starting: enabled) == true) }
            catch { Issue.record(error); completion(false) }
        }
        controller.update(selected: disabling ? nil : page, isFocused: true, enabled: !disabling, hasPictureInPicture: true,
                          activePresentations: [page])
        #expect(page.automaticPictureInPictureRequests == [false])
        #expect(context.evaluateScript("document.pictureInPictureElement === video").toBool() == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"start\"]")
    }
}
