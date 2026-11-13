// The AI hook center behind the bus: `BrowserHooks` maps page loads, new tabs, and finished downloads to the center's events as before, leaves agent tabs out, and ends a tab's hooks when it commits another document, ignoring the fragment, and when it closes. The service lives in a temporary folder with a provider that no request reaches.
import AI
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite final class BrowserHooksTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchBrowserHooksTests-\(UUID().uuidString)", isDirectory: true)
    private let bus = BrowserEventBus()
    private let hooks = BrowserHooks()
    private let service: AIService
    private let log = LockedLog()
    private let feature = AIFeature(id: AIFeatureID(rawValue: "test.browserHooks"), name: "Browser Hooks Test", summary: "", trigger: .automatic, data: .textOnly)

    init() {
        service = AIService(directory: folder)
        let provider = AIProviderConfiguration(name: "Test", kind: .http(AIHTTPConfiguration(format: .chatCompletions, baseURL: URL(string: "https://models.example.test/v1")!)),
                                               models: [AIModelConfiguration(name: "model-a")])
        service.settings.providers = [provider]
        service.register(feature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: provider.id, model: "model-a")]), for: feature.id)
        hooks.attach(events: bus, service: service)
        // A page at `/wait` holds its hook until the hook is canceled. The hook runs before the built-in ones, so Tab Names' wait does not hold it.
        let log = log
        service.hooks.subscribe(AIHookRegistration(feature: feature.id, events: [.pageLoaded, .tabOpened, .downloadFinished], priority: 50, allowedActions: []) { event, _ in
            switch event {
            case .pageLoaded(let load):
                log.record("load \(load.url.path) restore:\(load.isRestore)")
                guard load.url.path == "/wait" else { break }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    log.record("stop \(load.url.path)")
                    throw error
                }
            case .tabOpened(let open):
                log.record("open \(open.url?.path ?? "")")
            case .downloadFinished(let download):
                log.record("download \(download.info.filename)")
            }
            return .none
        })
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func tab(_ path: String, id: UUID = UUID(), kind: BrowserTabKind = .open) -> BrowserTabRef {
        BrowserTabRef(id: id, personaID: UUID(), spaceID: UUID(), kind: kind, engine: .chromium, url: URL(string: "https://example.org\(path)"))
    }

    @Test func pageLoadsAndNewTabsReachTheCenterButAgentTabsDoNot() async {
        bus.post(.pageLoaded(tab: tab("/restored"), isRestore: true, isFirstLoadAfterOpen: false))
        bus.post(.tabOpened(tab: tab("/new"), openerTabID: nil))
        bus.post(.pageLoaded(tab: tab("/agent", kind: .agent), isRestore: false, isFirstLoadAfterOpen: true))
        bus.post(.tabOpened(tab: tab("/agent", kind: .agent), openerTabID: nil))
        #expect(await eventually { log.entries.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.entries.sorted() == ["load /restored restore:true", "open /new"])
    }

    @Test func anotherDocumentEndsTheTabsHooksButAnotherFragmentDoesNot() async {
        let id = UUID()
        bus.post(.pageLoaded(tab: tab("/wait", id: id), isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { log.entries == ["load /wait restore:false"] })
        bus.post(.addressChanged(tab: tab("/wait#part", id: id), previousURL: URL(string: "https://example.org/wait")))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.entries == ["load /wait restore:false"])
        bus.post(.addressChanged(tab: tab("/next", id: id), previousURL: URL(string: "https://example.org/wait#part")))
        #expect(await eventually { log.entries.last == "stop /wait" })
    }

    @Test func aCloseEndsTheTabsHooks() async {
        let id = UUID()
        bus.post(.pageLoaded(tab: tab("/wait", id: id), isRestore: false, isFirstLoadAfterOpen: true))
        #expect(await eventually { log.entries == ["load /wait restore:false"] })
        bus.post(.tabClosed(tab: tab("/wait", id: id), reason: .user))
        #expect(await eventually { log.entries.last == "stop /wait" })
    }

    @Test func busEventsMapToTheCentersEvents() throws {
        let page = tab("/page")
        guard case .pageLoaded(let load)? = BrowserHooks.hookEvent(for: event(.pageLoaded(tab: page, isRestore: true, isFirstLoadAfterOpen: false)), fileURL: nil) else {
            Issue.record("Expected a page load")
            return
        }
        #expect(load.tabID == page.id && load.url == page.url && load.isRestore)
        guard case .tabOpened(let open)? = BrowserHooks.hookEvent(for: event(.tabOpened(tab: page, openerTabID: nil)), fileURL: nil) else {
            Issue.record("Expected a new tab")
            return
        }
        #expect(open.tabID == page.id && open.url == page.url)
        let download = BrowserDownloadRef(id: UUID(), personaID: UUID(), tabID: nil, filename: "a1b2.pdf", mediaType: "application/pdf", byteCount: 3,
                                          sourceURL: URL(string: "https://files.example.net/a1b2.pdf"), pageURL: URL(string: "https://example.org/files"), isNamedByUser: true)
        let file = URL(fileURLWithPath: "/tmp/a1b2.pdf")
        guard case .downloadFinished(let finished)? = BrowserHooks.hookEvent(for: event(.downloadFinished(download: download)), fileURL: file) else {
            Issue.record("Expected a finished download")
            return
        }
        #expect(finished.downloadID == download.id && finished.fileURL == file && finished.isNamedByUser)
        #expect(finished.info.filename == "a1b2.pdf" && finished.info.mediaType == "application/pdf" && finished.info.byteCount == 3)
        #expect(finished.info.sourceURL == download.sourceURL && finished.info.pageURL == download.pageURL && finished.info.pageTitle == nil)
        // A download whose entry has no file, and the kinds the center does not hear of, map to nothing.
        #expect(BrowserHooks.hookEvent(for: event(.downloadFinished(download: download)), fileURL: nil) == nil)
        #expect(BrowserHooks.hookEvent(for: event(.pageLoaded(tab: tab("/x").withoutAddress, isRestore: false, isFirstLoadAfterOpen: false)), fileURL: nil) == nil)
        #expect(BrowserHooks.hookEvent(for: event(.titleChanged(tab: page, source: .page)), fileURL: nil) == nil)
    }

    private func event(_ payload: BrowserEventPayload) -> BrowserEvent {
        BrowserEvent(id: UUID(), sequence: 1, date: Date(), payload: payload, cause: nil)
    }
}

private extension BrowserTabRef {
    var withoutAddress: BrowserTabRef {
        var ref = self
        ref.url = nil
        return ref
    }
}

/// What a test's hooks did, in order, from any thread.
final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ entry: String) {
        lock.lock()
        recorded.append(entry)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
