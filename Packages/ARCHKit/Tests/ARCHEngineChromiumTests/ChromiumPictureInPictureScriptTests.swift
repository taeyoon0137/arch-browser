// Exercises page measurements without a renderer, video frames, or a system window.
import JavaScriptCore
import Testing
@testable import ARCHEngineChromium

@MainActor @Suite struct ChromiumPictureInPictureScriptTests {
    private func context(_ setup: String, tracking: Bool = true) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        const reports = [], resizeObservers = [];
        const work = { queries: 0, styles: 0, rectangles: 0 };
        const crypto = { getRandomValues: array => { array.set([1, 2, 3, 4]); return array; } };
        class ResizeObserver {
          constructor(callback) { this.callback = callback; this.targets = new Set(); resizeObservers.push(this); }
          observe(target) { this.targets.add(target); }
          unobserve(target) { this.targets.delete(target); }
          disconnect() { this.targets.clear(); }
        }
        const eventTarget = object => Object.assign(object, {
          listeners: new Map(),
          addEventListener(name, handler) { this.listeners.set(name, handler); },
          dispatch(name, event) { this.listeners.get(name)?.(event); }
        });
        const window = globalThis;
        eventTarget(window);
        window.top = window; window.parent = window;
        window.innerWidth = 1000; window.innerHeight = 800; window.devicePixelRatio = 2;
        window.visualViewport = eventTarget({ offsetLeft: 0, offsetTop: 0, width: 1000, height: 800, scale: 1 });
        window.getComputedStyle = element => { work.styles++; return element.style ?? { display: 'block', visibility: 'visible' }; };
        function documentWith(win = window) {
          const doc = eventTarget({ defaultView: win, hidden: false, videos: [], frames: [], pictureInPictureElement: null,
            querySelectorAll(query) { work.queries++; return query === 'video' ? this.videos : this.frames; } });
          return doc;
        }
        function video(doc, box = { x: 100, y: 120, width: 320, height: 180 }, options = {}) {
          const value = Object.assign({ ownerDocument: doc, isConnected: true, box, style: { display: 'block', visibility: 'visible' },
            readyState: 2, paused: false, ended: false, muted: false, volume: 1, videoWidth: 1920, videoHeight: 1080,
            disablePictureInPicture: false, requestPictureInPicture() {}, getBoundingClientRect() { work.rectangles++; return this.box; } }, options);
          doc.videos.push(value); return value;
        }
        const document = documentWith();
        window.document = document;
        const channel = { send(value) { reports.push(value); return Promise.resolve(); }, onMessage(listener) { this.refresh = listener; } };
        """#)
        context.evaluateScript(setup)
        context.evaluateScript("(\(ChromiumPictureInPictureScript.source))(channel)")
        if tracking { context.evaluateScript("channel.refresh()") }
        try #require(context.exception == nil, "Geometry script failed")
        return context
    }

    private func json(_ context: JSContext, _ expression: String) -> String? {
        context.evaluateScript("JSON.stringify(\(expression))")?.toString()
    }

    @Test func inlineStartupAndPlaybackEventsDoNoGeometryWork() throws {
        let context = try context("const movie = video(document);", tracking: false)
        context.evaluateScript("""
        for (let count = 0; count < 3; count++) {
          for (const event of ['loadedmetadata', 'loadeddata', 'playing', 'pause', 'ended', 'volumechange',
                               'emptied', 'scroll', 'load', 'DOMContentLoaded', 'visibilitychange'])
            document.dispatch(event);
          window.dispatch('resize'); window.visualViewport.dispatch('scroll'); window.visualViewport.dispatch('resize');
        }
        """)
        #expect(json(context, "work") == #"{"queries":0,"styles":0,"rectangles":0}"#)
        #expect(context.evaluateScript("resizeObservers.length").toInt32() == 0)
        #expect(context.evaluateScript("reports.length").toInt32() == 0)
        #expect(context.exception == nil)
    }

    @Test func anActualRequestMeasuresTheLatestVideoEvenAfterItsTabHides() throws {
        let context = try context("const movie = video(document);", tracking: false)
        context.evaluateScript("movie.box.y = 240; document.hidden = true")
        let value = context.evaluateScript("(\(ChromiumPictureInPictureScript.refresh))(channel)")?.toString()
        #expect(value?.contains(#""y":240"#) == true)
        #expect(context.evaluateScript("reports.at(-1).videos[0].visible").toBool())
        #expect(context.evaluateScript("resizeObservers.length").toInt32() == 1)
        #expect(context.evaluateScript("work.rectangles").toInt32() == 1)
        #expect(context.exception == nil)
    }

    @Test func pageOwnedEntryBeginsTrackingAndCompletionReturnsToIdle() throws {
        let context = try context("const movie = video(document);", tracking: false)
        context.evaluateScript("document.pictureInPictureElement = movie; document.dispatch('enterpictureinpicture')")
        #expect(context.evaluateScript("reports.at(-1).activeID === reports.at(-1).videos[0].id").toBool())
        #expect(context.evaluateScript("resizeObservers[0].targets.has(movie)").toBool())
        context.evaluateScript("channel.refresh(\(ChromiumPictureInPictureScript.stop)); work.queries = work.styles = work.rectangles = 0")
        let reportCount = context.evaluateScript("reports.length").toInt32()
        context.evaluateScript("document.pictureInPictureElement = null; document.dispatch('leavepictureinpicture'); document.dispatch('playing'); window.dispatch('resize')")
        #expect(!context.evaluateScript("resizeObservers[0].targets.has(movie)").toBool())
        #expect(json(context, "work") == #"{"queries":0,"styles":0,"rectangles":0}"#)
        #expect(context.evaluateScript("reports.length").toInt32() == reportCount)
        context.evaluateScript("movie.box.y = 300; channel.refresh()")
        #expect(context.evaluateScript("reports.at(-1).videos[0].rect.y").toInt32() == 300)
        #expect(context.evaluateScript("resizeObservers.length").toInt32() == 2)
        #expect(context.exception == nil)
    }

    @Test func lateCrossOriginReportsCannotRearmACompletedPresentation() throws {
        let context = try context(crossOriginSetup, tracking: false)
        context.evaluateScript("relay()")
        #expect(context.evaluateScript("resizeObservers.length").toInt32() == 0)
        #expect(context.evaluateScript("reports.length").toInt32() == 0)
        context.evaluateScript("channel.refresh(); relay()")
        #expect(context.evaluateScript("reports.at(-1).activeID").toString() == "child:1")
        #expect(context.evaluateScript("resizeObservers.length").toInt32() == 1)
        context.evaluateScript("channel.refresh(\(ChromiumPictureInPictureScript.stop)); work.queries = work.styles = work.rectangles = 0; relay()")
        #expect(context.evaluateScript("resizeObservers.length").toInt32() == 1)
        #expect(context.evaluateScript("resizeObservers[0].targets.size").toInt32() == 0)
        #expect(json(context, "work") == #"{"queries":0,"styles":0,"rectangles":0}"#)
        #expect(context.exception == nil)
    }

    @Test func aFreshMeasurementUsesViewportCoordinatesWithoutSubtractingScrollAgain() throws {
        let context = try context("const movie = video(document); window.scrollX = 300; window.scrollY = 900;")
        #expect(json(context, "reports.at(-1).videos[0].rect") == #"{"x":100,"y":120,"width":320,"height":180}"#)
        context.evaluateScript("movie.box.y = 20; document.dispatch('scroll')")
        #expect(context.evaluateScript("reports.at(-1).videos[0].rect.y").toInt32() == 20)
    }

    @Test func viewportOffsetsScaleAndDevicePixelsRemainSeparateFromCSSGeometry() throws {
        let context = try context("""
        window.visualViewport.offsetLeft = 25; window.visualViewport.offsetTop = 40;
        window.visualViewport.scale = 1.5; window.devicePixelRatio = 3;
        const movie = video(document);
        """)
        #expect(json(context, "reports.at(-1).videos[0].viewportOffset") == #"{"x":25,"y":40}"#)
        #expect(context.evaluateScript("reports.at(-1).videos[0].viewportScale").toDouble() == 1.5)
        #expect(context.evaluateScript("reports.at(-1).videos[0].devicePixelRatio").toDouble() == 3)
        #expect(context.evaluateScript("reports.at(-1).videos[0].rect.width").toInt32() == 320)
    }

    @Test func sameOriginFramesAddTheirBordersAndScaleIntoTheTopViewport() throws {
        let context = try context("""
        const childWindow = eventTarget({ getComputedStyle: window.getComputedStyle });
        const child = documentWith(childWindow);
        const frame = { ownerDocument: document, isConnected: true, contentDocument: child,
          clientLeft: 3, clientTop: 4, offsetWidth: 400, offsetHeight: 300,
          getBoundingClientRect: () => ({ x: 100, y: 60, width: 800, height: 600 }) };
        childWindow.frameElement = frame; document.frames.push(frame);
        const movie = video(child, { x: 10, y: 20, width: 160, height: 90 });
        """)
        #expect(json(context, "reports.at(-1).videos[0].rect") == #"{"x":126,"y":108,"width":320,"height":180}"#)
        context.evaluateScript("movie.box.y = 5; child.dispatch('scroll')")
        #expect(context.evaluateScript("reports.at(-1).videos[0].rect.y").toInt32() == 78)
    }

    @Test func hiddenAndUnmeasuredVideosKeepOnlyTheirOwnLastVisibleGeometry() throws {
        let context = try context("const movie = video(document);")
        context.evaluateScript("movie.box = { x: 0, y: 0, width: 0, height: 0 }; document.hidden = true; document.dispatch('visibilitychange')")
        #expect(json(context, "reports.at(-1).videos[0].rect") == #"{"x":100,"y":120,"width":320,"height":180}"#)
        #expect(!context.evaluateScript("reports.at(-1).videos[0].visible").toBool())
        context.evaluateScript("const second = video(document, { x: 0, y: 0, width: 0, height: 0 }); channel.refresh()")
        #expect(context.evaluateScript("reports.at(-1).videos.length").toInt32() == 1)
        context.evaluateScript("document.hidden = false; second.box = { x: 400, y: 200, width: 200, height: 100 }; channel.refresh()")
        #expect(context.evaluateScript("reports.at(-1).videos.length").toInt32() == 2)
        #expect(context.evaluateScript("reports.at(-1).videos[0].id !== reports.at(-1).videos[1].id").toBool())
    }

    @Test func anOffscreenOrNonfiniteMeasurementCannotReplaceTheVisibleCache() throws {
        let context = try context("const movie = video(document);")
        for box in ["{ x: 0, y: 900, width: 320, height: 180 }", "{ x: NaN, y: 20, width: 320, height: 180 }"] {
            context.evaluateScript("movie.box = \(box); channel.refresh()")
            #expect(json(context, "reports.at(-1).videos[0].rect") == #"{"x":100,"y":120,"width":320,"height":180}"#)
            #expect(!context.evaluateScript("reports.at(-1).videos[0].visible").toBool())
        }
    }

    @Test func aVideoWithoutGeometryNeverBorrowsAnotherVideosRectangle() throws {
        let context = try context("""
        const missing = video(document, { x: 0, y: 0, width: 0, height: 0 });
        const measured = video(document, undefined, { paused: true });
        """)
        context.evaluateScript("document.pictureInPictureElement = missing; channel.refresh()")
        #expect(context.evaluateScript("reports.at(-1).activeID !== reports.at(-1).videos[0].id").toBool())
    }

    @Test func documentIdentifiersDoNotRequireASecureContext() throws {
        let context = try context("const movie = video(document); globalThis.isSecureContext = false;")
        #expect(context.evaluateScript("typeof crypto.randomUUID").toString() == "undefined")
        #expect(context.evaluateScript("reports.at(-1).documentID").toString() == "1-2-3-4")
    }

    @Test func refreshAndLayoutChangesMeasureAgainWithoutFrameCallbacksOrPolling() throws {
        let context = try context("const movie = video(document);")
        let initialCount = context.evaluateScript("reports.length").toInt32()
        context.evaluateScript("channel.refresh()")
        #expect(context.evaluateScript("reports.length").toInt32() == initialCount)
        context.evaluateScript("movie.box.x = 75; resizeObservers[0].callback()")
        #expect(context.evaluateScript("reports.at(-1).videos[0].rect.x").toInt32() == 75)
        context.evaluateScript("movie.box.y = 80")
        let value = context.evaluateScript("(\(ChromiumPictureInPictureScript.refresh))(channel)")?.toString()
        #expect(value?.contains(#""y":80"#) == true)
        #expect(context.exception == nil)
    }

    @Test func crossOriginFramesAreSkippedAndRemovedVideosAreNotRetainedByTheObserver() throws {
        let context = try context("""
        const movie = video(document);
        document.frames.push({ get contentDocument() { throw new Error('cross origin'); } });
        """)
        #expect(context.evaluateScript("reports.at(-1).videos.length").toInt32() == 1)
        context.evaluateScript("document.videos = []; channel.refresh()")
        #expect(!context.evaluateScript("resizeObservers[0].targets.has(movie)").toBool())
        #expect(context.evaluateScript("reports.at(-1).activeID === null").toBool())
    }

    private let crossOriginSetup = """
    const requests = [], childWindow = { postMessage: packet => requests.push(packet) };
    const frame = { ownerDocument: document, isConnected: true, contentWindow: childWindow, contentDocument: null,
      clientLeft: 3, clientTop: 4, offsetWidth: 400, offsetHeight: 300,
      getBoundingClientRect: () => ({ x: 100, y: 60, width: 800, height: 600 }) };
    document.frames.push(frame);
    const childReport = { documentID: 'child', activeID: 'child:1', activeIsCrossOrigin: false,
      videos: [{ id: 'child:1', rect: { x: 10, y: 20, width: 160, height: 90 },
        viewportOffset: { x: 0, y: 0 }, viewportScale: 1, devicePixelRatio: 2,
        visible: true }] };
    function relay(source = childWindow, report = childReport) {
      window.dispatch('message', { source, data: { type: '__archPictureInPictureGeometry', report } });
    }
    """

    @Test func crossOriginPagePictureInPictureUsesTheActualChildFrameGeometry() throws {
        let context = try context(crossOriginSetup + "const inline = video(document);")
        context.evaluateScript("relay()")
        #expect(json(context, "reports.at(-1).videos[1].rect") == #"{"x":126,"y":108,"width":320,"height":180}"#)
        #expect(context.evaluateScript("reports.at(-1).activeID").toString() == "child:1")
        context.evaluateScript("frame.isConnected = false; childReport.videos[0].rect.x = 0; relay()")
        #expect(context.evaluateScript("reports.at(-1).videos[1].rect.x").toInt32() == 126)
        #expect(!context.evaluateScript("reports.at(-1).videos[1].visible").toBool())
    }

    @Test func relaysRequireAnActualChildAndBoundedFiniteGeometry() throws {
        let context = try context(crossOriginSetup)
        context.evaluateScript("relay({})")
        #expect(context.evaluateScript("reports.at(-1).videos.length").toInt32() == 0)
        context.evaluateScript("relay(childWindow, { ...childReport, videos: Array(257).fill(childReport.videos[0]) })")
        #expect(context.evaluateScript("reports.at(-1).activeID === null").toBool())
        context.evaluateScript("childReport.videos[0].rect.x = NaN; relay()")
        #expect(context.evaluateScript("reports.at(-1).videos.length").toInt32() == 0)
    }

    @Test func crossOriginFrameResizesUpdateTheMappedVideoWithoutANewChildReport() throws {
        let context = try context(crossOriginSetup)
        context.evaluateScript("relay()")
        #expect(context.evaluateScript("resizeObservers[0].targets.has(frame)").toBool())
        context.evaluateScript("frame.getBoundingClientRect = () => ({ x: 100, y: 60, width: 400, height: 300 }); resizeObservers[0].callback()")
        #expect(json(context, "reports.at(-1).videos[0].rect") == #"{"x":113,"y":84,"width":160,"height":90}"#)
    }

    @Test func relayRecordsContainOnlyValidatedGeometryAndBooleanVisibility() throws {
        let context = try context(crossOriginSetup)
        context.evaluateScript("relay(); childReport.videos[0].visible = 'true'; childReport.videos[0].unexpected = 'discard'; relay()")
        #expect(context.evaluateScript("typeof reports.at(-1).videos[0].visible").toString() == "boolean")
        #expect(!context.evaluateScript("reports.at(-1).videos[0].visible").toBool())
        #expect(context.evaluateScript("reports.at(-1).videos[0].unexpected === undefined").toBool())
    }

    @Test func crossOriginDescendantsRelayThroughSameOriginFramesWithoutDuplicatingLocalVideos() throws {
        let context = try context(crossOriginSetup + """
        const sameOriginWindow = eventTarget({ getComputedStyle: window.getComputedStyle, frameElement: frame });
        frame.contentDocument = documentWith(sameOriginWindow);
        const local = video(frame.contentDocument);
        childReport.activeIsCrossOrigin = true; childReport.videos[0].crossOrigin = true;
        """)
        context.evaluateScript("relay()")
        #expect(context.evaluateScript("reports.at(-1).videos.length").toInt32() == 2)
        #expect(context.evaluateScript("reports.at(-1).activeID").toString() == "child:1")
        context.evaluateScript("childReport.activeID = null; childReport.activeIsCrossOrigin = false; childReport.videos[0].crossOrigin = false; relay()")
        #expect(context.evaluateScript("reports.at(-1).videos.length").toInt32() == 1)
        #expect(context.evaluateScript("reports.at(-1).activeID === null").toBool())
    }

    @Test func aFreshRequestAsksChildFramesToMeasureWithoutPolling() throws {
        let context = try context(crossOriginSetup)
        let count = context.evaluateScript("requests.length").toInt32()
        context.evaluateScript("channel.refresh()")
        #expect(context.evaluateScript("requests.length").toInt32() == count + 1)
        #expect(context.evaluateScript("requests.at(-1).refresh").toBool())
    }

    @Test func refreshingAChildKeepsItsRectButWaitsForItsCurrentActiveVideo() throws {
        let context = try context(crossOriginSetup)
        context.evaluateScript("relay(); channel.refresh()")
        #expect(context.evaluateScript("reports.at(-1).activeID === null").toBool())
        #expect(context.evaluateScript("reports.at(-1).videos[0].id").toString() == "child:1")
        context.evaluateScript("childReport.activeID = 'child:2'; childReport.videos[0].id = 'child:2'; relay()")
        #expect(context.evaluateScript("reports.at(-1).activeID").toString() == "child:2")
    }

    @Test func childFramesRelayAndResendUnchangedGeometryAfterAParentLoads() throws {
        let context = try context("""
        const forwarded = [];
        window.top = {}; window.parent = { postMessage: packet => forwarded.push(packet) };
        const movie = video(document); document.pictureInPictureElement = movie;
        """)
        #expect(context.evaluateScript("reports.length").toInt32() == 0)
        #expect(context.evaluateScript("forwarded.length").toInt32() == 1)
        context.evaluateScript("window.dispatch('message', { source: window.parent, data: { type: '__archPictureInPictureGeometry', refresh: true } })")
        #expect(context.evaluateScript("forwarded.length").toInt32() == 2)
        #expect(context.evaluateScript("forwarded.at(-1).report.activeID === forwarded.at(-1).report.videos[0].id").toBool())
    }
}
