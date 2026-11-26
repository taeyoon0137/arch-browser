// Media menu state and actions without opening a browser, a menu, or a media window.
import AppKit
import ARCHEngine
import JavaScriptCore
import Testing
@testable import Browsing

@MainActor @Suite struct PageContextMenuMediaTests {
    private func menu(_ element: EngineContextMenuElement, perform: @escaping (EngineContextMenuMediaAction) -> Void = { _ in }) -> (Tab, NSMenu) {
        let contents = UnloadedWebContents(url: URL(string: "https://example.org/"), title: "", engine: .webKit, state: nil)
        let tab = Tab(id: UUID(), webContents: contents, spaceID: nil, isPinned: false, personaID: UUID())
        let menu = NSMenu()
        element.media?.items(perform: perform).forEach(menu.addItem)
        tab.webContents(contents, willShowContextMenuFor: element, menu: menu)
        return (tab, menu)
    }

    @Test func aVideoStreamKeepsItsControlsWithoutASourceAddress() throws {
        let media = EngineContextMenuMedia(kind: .video, isPaused: true, isLooping: true, showsControls: true, canPictureInPicture: true)
        var actions: [EngineContextMenuMediaAction] = []
        let (_, menu) = menu(EngineContextMenuElement(media: media)) { actions.append($0) }
        #expect(menu.items.map(\.title) == ["Play", "Loop", "Show Controls", "Picture in Picture", "Enter Full Screen"])
        #expect(menu.items[1].state == .on)
        #expect(menu.items[2].state == .on)
        #expect(menu.items.allSatisfy { $0.isEnabled })
        for item in menu.items { _ = (item.target as AnyObject).perform(try #require(item.action), with: item) }
        #expect(actions == EngineContextMenuMediaAction.allCases)
    }

    @Test func nativeFlagsControlLabelsAndAvailability() throws {
        let media = try #require(EngineContextMenuMedia(report: ["kind": "video", "paused": false, "loop": false,
            "controls": false, "pip": true, "canLoop": false, "canControls": false, "canPip": false, "error": true]))
        let (_, menu) = menu(EngineContextMenuElement(media: media))
        #expect(menu.items.map(\.title) == ["Pause", "Loop", "Show Controls", "Exit Picture in Picture", "Enter Full Screen"])
        #expect(menu.items.map(\.isEnabled) == [false, false, false, true, false])
        #expect(EngineContextMenuMedia(report: ["kind": "image"]) == nil)
    }

    @Test func saveVideoUsesTheClickedAddressAndAsksForADestination() throws {
        let address = URL(string: "https://example.org/clip.mp4")!
        let (tab, menu) = menu(EngineContextMenuElement(mediaURL: address, media: .init(kind: .video, canSave: true)))
        let save = try #require(menu.items.first { $0.title == "Save Video As…" })
        _ = (save.target as AnyObject).perform(try #require(save.action), with: save)
        #expect(tab.takeUserDownloadRequest(for: MediaMenuDownload(contents: tab.webContents, url: address)) == true)
        #expect(menu.items.last?.title == "Copy Video Address")
    }

    @Test func blobStreamsDoNotOfferAnUnusableSave() {
        let (_, menu) = menu(EngineContextMenuElement(mediaURL: URL(string: "blob:https://example.org/stream"), media: .init(kind: .video, canSave: true)))
        #expect(!menu.items.contains { $0.title == "Save Video As…" })
        #expect(menu.items.last?.title == "Copy Video Address")
    }

    @Test func audioGetsPlaybackAndAddressItemsWithoutVideoPresentation() {
        let (_, menu) = menu(EngineContextMenuElement(mediaURL: URL(string: "https://example.org/clip.mp3"), media: .init(kind: .audio, canSave: true)))
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["Pause", "Loop", "—", "Save Audio As…", "Copy Audio Address"])
    }

    @Test func previewKeepsTheSameMediaActionsWithoutDownloadItems() {
        let contents = UnloadedWebContents(url: URL(string: "https://example.org/"), title: "", engine: .webKit, state: nil)
        let preview = PagePreview(webContents: contents, personaID: UUID(), requestedEngine: .webKit, openedURL: contents.url!)
        let element = EngineContextMenuElement(media: .init(kind: .video, canPictureInPicture: true))
        let menu = NSMenu()
        element.media?.items { _ in }.forEach(menu.addItem)
        preview.webContents(contents, willShowContextMenuFor: element, menu: menu)
        #expect(menu.items.map(\.title) == ["Pause", "Loop", "Show Controls", "Picture in Picture", "Enter Full Screen"])
    }

    private func hitTestContext() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        class Element {
          constructor(parent = null) { this.parentElement = parent; this.isConnected = true; this.ownerDocument = doc; }
          getRootNode() { return doc; }
          getBoundingClientRect() { return this.box || { width: 640, height: 360 }; }
          matches() { return !!this.blocked; }
          contains(node) { for (; node; node = node.parentElement) if (node === this) return true; return false; }
        }
        class HTMLMediaElement extends Element {}
        class HTMLVideoElement extends HTMLMediaElement {}
        const doc = { pictureInPictureEnabled: true };
        doc.documentElement = new Element();
        doc.body = new Element(doc.documentElement);
        const player = new Element(doc.body), overlay = new Element(player), video = new HTMLVideoElement(player);
        const other = new HTMLVideoElement(doc.body), unrelated = new Element(doc.body);
        doc.elementsFromPoint = () => [overlay, video, player, doc.body];
        video.currentSrc = 'blob:https://example.org/stream'; video.paused = false; video.loop = true; video.controls = true;
        video.readyState = 4; video.requestPictureInPicture = () => {};
        const hitTest = \(EngineContextMenuMedia.hitTestFunction);
        """)
        try #require(context.exception == nil)
        return context
    }

    @Test func playerOverlayResolvesTheUnderlyingVideoWithoutReplacingNativeTargets() throws {
        let context = try hitTestContext()
        #expect(context.evaluateScript("hitTest.call(overlay, 20, 30, true, false) === video").toBool())
        #expect(context.evaluateScript("hitTest.call(video, 20, 30, false, false) === video").toBool())
        #expect(context.evaluateScript("hitTest.call(overlay, 20, 30, false, false) === null").toBool())
        context.evaluateScript("doc.elementsFromPoint = () => [overlay, other]")
        #expect(context.evaluateScript("hitTest.call(overlay, 20, 30, true, false) === null").toBool())
    }

    @Test func anUnrelatedOverlayLinkOrInvalidPointDoesNotBecomeAVideoMenu() throws {
        let context = try hitTestContext()
        #expect(context.evaluateScript("hitTest.call(unrelated, 20, 30, true, false) === null").toBool())
        #expect(context.evaluateScript("hitTest.call(overlay, NaN, 30, true, false) === null").toBool())
        context.evaluateScript("player.box = { width: 1600, height: 1200 }")
        #expect(context.evaluateScript("hitTest.call(overlay, 20, 30, true, false) === null").toBool())
        context.evaluateScript("player.box = null; overlay.blocked = true")
        #expect(context.evaluateScript("hitTest.call(overlay, 20, 30, true, false) === null").toBool())
        context.evaluateScript("video.isConnected = false")
        #expect(context.evaluateScript("hitTest.call(video, 20, 30, true, false) === null").toBool())
    }

    @Test func overlayReportsCarryPlaybackStateEvenForAnUnsavableStream() throws {
        let context = try hitTestContext()
        let report = context.evaluateScript("hitTest.call(overlay, 20, 30, true, true)").toDictionary()
        let media = try #require(EngineContextMenuMedia(report: report))
        #expect(media.kind == .video && !media.isPaused && media.isLooping && media.showsControls)
        #expect(media.canPictureInPicture && !media.canSave)
        #expect(report?["source"] as? String == "blob:https://example.org/stream")
        context.evaluateScript("doc.pictureInPictureElement = video")
        #expect(context.evaluateScript("hitTest.call(video, 0, 0, false, true).pip").toBool())
    }

    @Test func aStreamWithoutAnAddressDoesNotExposeStaleTextActions() {
        let element = EngineContextMenuElement(selectedText: "previous selection", media: .init(kind: .video))
        #expect(EngineTextMenuItems.selection(of: element) == nil)
        let copy = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copy.identifier = EngineContextMenuItem.copy
        let menu = NSMenu(); menu.addItem(copy)
        #expect(PageContextMenuSections(takingItemsOf: menu, for: element).editing.isEmpty)
    }

    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        let calls = [];
        function setTimeout() { return 1; } function clearTimeout() {}
        class HTMLMediaElement {
          constructor(name) { this.name = name; this.isConnected = true; this.paused = true; this.loop = false; this.controls = false;
            this.readyState = 4; this.ownerDocument = {}; }
          async play() { calls.push(this.name + ':play'); this.paused = false; }
          pause() { calls.push(this.name + ':pause'); this.paused = true; }
          async requestPictureInPicture() { calls.push(this.name + ':pip'); }
          async requestFullscreen() { calls.push(this.name + ':fullscreen'); }
        }
        const first = new HTMLMediaElement('first'), clicked = new HTMLMediaElement('clicked');
        const control = { parentElement: null, getRootNode: () => ({ host: clicked }) };
        """)
        try #require(context.exception == nil)
        return context
    }

    @Test func actionsUseTheClickedVideoIncludingANativeControlsChild() throws {
        let context = try context()
        for action in EngineContextMenuMediaAction.allCases {
            context.evaluateScript("(" + action.function + ").call(control)")
            try #require(context.exception == nil)
        }
        #expect(context.evaluateScript("JSON.stringify(calls)").toString() == "[\"clicked:play\",\"clicked:pip\",\"clicked:fullscreen\"]")
        #expect(context.evaluateScript("clicked.loop && clicked.controls && !first.loop && !first.controls").toBool())
        context.evaluateScript("(" + EngineContextMenuMediaAction.playPause.function + ").call(clicked)")
        #expect(context.evaluateScript("calls.at(-1)").toString() == "clicked:pause")
    }

    @Test func aRemovedMediaNodeNeverTargetsAnotherVideo() throws {
        let context = try context()
        context.evaluateScript("clicked.isConnected = false")
        for action in EngineContextMenuMediaAction.allCases {
            context.evaluateScript("(" + action.function + ").call(clicked)")
            try #require(context.exception == nil)
        }
        #expect(context.evaluateScript("calls.length").toInt32() == 0)
        #expect(context.evaluateScript("!first.loop && !first.controls").toBool())
    }
}

private final class MediaMenuDownload: EngineDownloadItem {
    let sourceURL: URL
    let webContents: (any EngineWebContents)?
    let pageURL: URL? = nil
    var targetPath: URL?
    let state: EngineDownloadState = .inProgress
    let completedBytes: Int64 = 0
    let totalBytes: Int64 = 0
    init(contents: any EngineWebContents, url: URL) { webContents = contents; sourceURL = url }
    func pause() {}
    func resume() {}
    func cancel() {}
    func remove() {}
}
