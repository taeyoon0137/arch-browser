// Exercises PiP routing without a browser, a media decoder, or a system window.
import JavaScriptCore
import Testing
@testable import ARCHEngine

@MainActor @Suite struct EnginePictureInPictureScriptTests {
    private func context(_ setup: String) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        let timers = new Map(), nextTimer = 0, calls = [];
        function setTimeout(callback) { timers.set(++nextTimer, callback); return nextTimer; }
        function clearTimeout(id) { timers.delete(id); }
        function documentWith(videos = [], frames = []) {
          const doc = { pictureInPictureElement: null,
            querySelectorAll: query => query === 'video' ? videos : frames };
          videos.forEach(video => video.ownerDocument = doc);
          return doc;
        }
        function video(name, options = {}) {
          const listeners = new Map();
          return Object.assign({ name, readyState: 4, paused: true, ended: false,
            disablePictureInPicture: false, webkitPresentationMode: 'inline',
            getBoundingClientRect: () => ({ width: 100, height: 100 }),
            addEventListener: (name, handler) => listeners.set(name, handler),
            removeEventListener: name => listeners.delete(name),
            changeMode(mode) { this.webkitPresentationMode = mode; listeners.get('webkitpresentationmodechanged')?.(); },
            listenerCount: () => listeners.size,
            requestPictureInPicture() { calls.push(this.name); return Promise.resolve(); }
          }, options);
        }
        \(setup)
        """)
        try #require(context.exception == nil, "JavaScript fixture failed")
        return context
    }

    private func run(_ context: JSContext) throws {
        context.evaluateScript("\(EnginePictureInPictureScript.toggle).then(value => globalThis.result = value)")
        try #require(context.exception == nil, "PiP script failed")
    }

    private func result(_ context: JSContext) -> Bool? {
        let value = context.objectForKeyedSubscript("result")!
        return value.isUndefined ? nil : value.toBool()
    }

    @Test func aPlayingVideoInASameOriginFrameWinsOverALargerPausedVideo() throws {
        let context = try context("""
        const large = video('large', { getBoundingClientRect: () => ({ width: 1920, height: 1080 }) });
        const playing = video('playing', { paused: false });
        const blockedFrame = { get contentDocument() { throw new Error('cross origin'); } };
        const document = documentWith([large], [blockedFrame, { contentDocument: documentWith([playing]) }]);
        """)
        try run(context)
        #expect(result(context) == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"playing\"]")
        #expect(context.evaluateScript("timers.size").toInt32() == 0)
    }

    @Test func anActiveVideoExitsEvenWhenThePageNowDisablesEntry() throws {
        let context = try context("""
        const active = video('active', { readyState: 0, disablePictureInPicture: true });
        const document = documentWith([active]);
        document.pictureInPictureElement = active;
        document.exitPictureInPicture = () => { calls.push('exit'); return Promise.resolve(); };
        """)
        try run(context)
        #expect(result(context) == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"exit\"]")
    }

    @Test func webKitPresentationWaitsForItsEventAndRemovesTheListener() throws {
        let context = try context("""
        const legacy = video('legacy', { requestPictureInPicture: undefined,
          webkitSupportsPresentationMode: mode => mode === 'picture-in-picture',
          webkitSetPresentationMode: mode => calls.push(mode) });
        const document = documentWith([legacy]);
        """)
        try run(context)
        #expect(result(context) == nil)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"picture-in-picture\"]")
        context.evaluateScript("legacy.changeMode('picture-in-picture')")
        #expect(result(context) == true)
        #expect(context.evaluateScript("legacy.listenerCount() + timers.size").toInt32() == 0)
    }

    @Test func webKitPresentationExitsWithoutAStandardPictureInPictureElement() throws {
        let context = try context("""
        const active = video('active', { disablePictureInPicture: true, webkitPresentationMode: 'picture-in-picture',
          webkitSetPresentationMode(mode) { calls.push(mode); this.changeMode(mode); } });
        const document = documentWith([active]);
        """)
        try run(context)
        #expect(result(context) == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"inline\"]")
    }

    @Test func aRefusedStandardRequestDoesNotBypassTheRefusalWithAnotherAPI() throws {
        let context = try context("""
        const document = documentWith([video('refused', {
          requestPictureInPicture: () => Promise.reject(new Error('not allowed')),
          webkitSupportsPresentationMode: () => true, webkitSetPresentationMode: mode => calls.push(mode) })]);
        """)
        try run(context)
        #expect(result(context) == false)
        #expect(context.evaluateScript("calls.length + timers.size").toInt32() == 0)
    }

    @Test(arguments: [false, true]) func anUnansweredRequestTimesOut(prefixed: Bool) throws {
        let context = try context("""
        const pending = video('pending', \(prefixed ? "{ requestPictureInPicture: undefined, webkitSupportsPresentationMode: () => true, webkitSetPresentationMode: () => {} }" : "{ requestPictureInPicture: () => new Promise(() => {}) }"));
        const document = documentWith([pending]);
        """)
        try run(context)
        #expect(result(context) == nil)
        context.evaluateScript("for (const callback of [...timers.values()]) callback();")
        #expect(result(context) == false)
        #expect(context.evaluateScript("pending.listenerCount()").toInt32() == 0)
    }

    @Test func anUnsupportedPlayingVideoDoesNotHideAnEligiblePausedVideo() throws {
        let context = try context("""
        const unsupported = video('unsupported', { paused: false, requestPictureInPicture: undefined });
        const disabled = video('disabled', { paused: false, disablePictureInPicture: true });
        const document = documentWith([unsupported, disabled, video('eligible')]);
        """)
        try run(context)
        #expect(result(context) == true)
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"eligible\"]")
    }

    @Test(arguments: ["[]", "[video('empty', { readyState: 0 })]", "[video('throwing', { requestPictureInPicture() { throw new Error('gone'); } })]"])
    func missingUnreadyAndThrowingVideosFailQuietly(videos: String) throws {
        let context = try context("const document = documentWith(\(videos));")
        try run(context)
        #expect(result(context) == false)
    }
}
