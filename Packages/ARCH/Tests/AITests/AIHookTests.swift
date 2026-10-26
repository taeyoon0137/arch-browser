// The hook center: ordering by priority, `stop`, allowed actions, replacement by a newer event for the same subject, `cancel(subject:)`, timeouts, also of a hook that does not stop when cancelled, actions dropped after cancellation, the checks that keep hooks from running, the errors each feature's row shows, and pausing after consecutive failed requests.
import Foundation
import Testing
@testable import AI

@MainActor
@Suite struct HookOrderTests {
    @Test func hooksRunByPriorityThenFeatureAndSeeEarlierActions() async {
        let fixture = HookFixture()
        let log = HookLog()
        for (name, priority) in [("late", 200), ("zeta", 100), ("alpha", 100)] {
            let feature = enableFeature("hook.\(name)", on: fixture.service)
            fixture.center.subscribe(registration(feature, priority: priority) { event, context in
                log.record("\(name):\(context.appliedActions.count)")
                return .actions([.renameTab(event.subject, title: name)], stop: false)
            })
        }
        fixture.center.post(pageLoad())
        #expect(await eventually { fixture.host.applied.count == 3 })
        #expect(log.entries == ["alpha:0", "zeta:1", "late:2"])
        #expect(fixture.host.applied.map(\.title) == ["alpha", "zeta", "late"])
    }

    @Test func stopKeepsLaterHooksFromRunning() async {
        let fixture = HookFixture()
        let log = HookLog()
        let later = enableFeature("hook.later", on: fixture.service)
        fixture.center.subscribe(registration { event, _ in .actions([.renameTab(event.subject, title: "first")], stop: true) })
        fixture.center.subscribe(registration(later, priority: 200) { _, _ in
            log.record("later")
            return .none
        })
        fixture.center.post(pageLoad())
        #expect(await eventually { fixture.host.applied.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.entries.isEmpty)
    }

    @Test func actionsOutsideTheAllowedKindsAndRefusedActionsDoNotCount() async {
        let fixture = HookFixture()
        let log = HookLog()
        let later = enableFeature("hook.later", on: fixture.service)
        fixture.host.refusesTitles = ["refused"]
        fixture.center.subscribe(registration(allowedActions: [.renameDownload]) { event, _ in
            .actions([.renameTab(event.subject, title: "not allowed"), .renameDownload(event.subject, filename: "refused")], stop: false)
        })
        fixture.center.subscribe(registration(later, priority: 200) { _, context in
            log.record("later:\(context.appliedActions.count)")
            return .none
        })
        fixture.center.post(pageLoad())
        #expect(await eventually { log.entries == ["later:0"] })
        #expect(fixture.host.applied.isEmpty)
        #expect(fixture.host.offered.map(\.title) == ["refused"])
    }
}

@MainActor
@Suite struct HookReplacementTests {
    @Test func aNewerEventForTheSameSubjectReplacesTheOlder() async {
        let fixture = HookFixture()
        let log = HookLog()
        fixture.center.subscribe(registration(delay: .milliseconds(100)) { event, _ in
            log.record(event.urls.first?.path ?? "")
            return .none
        })
        let tab = UUID()
        fixture.center.post(pageLoad(tab, path: "/first"))
        fixture.center.post(pageLoad(tab, path: "/second"))
        fixture.center.post(pageLoad(UUID(), path: "/other"))
        #expect(await eventually { log.entries.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.entries.sorted() == ["/other", "/second"])
    }

    @Test func theNewerEventStartsOnceTheOlderHasStopped() async {
        let fixture = HookFixture()
        let log = HookLog()
        fixture.center.subscribe(registration(timeout: .seconds(60)) { event, _ in
            let path = event.urls.first?.path ?? ""
            log.record("start \(path)")
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                log.record("stop \(path)")
                throw error
            }
            return .none
        })
        let tab = UUID()
        fixture.center.post(pageLoad(tab, path: "/first"))
        #expect(await eventually { log.entries == ["start /first"] })
        fixture.center.post(pageLoad(tab, path: "/second"))
        #expect(await eventually { log.entries == ["start /first", "stop /first", "start /second"] })
        fixture.center.cancel(subject: tab)
        #expect(await eventually { log.entries.last == "stop /second" })
        #expect(fixture.center.lastErrors.isEmpty)
    }

    @Test func cancellingTheSubjectDropsTheActions() async {
        let fixture = HookFixture()
        let log = HookLog()
        // The hook returns its action even when it is cancelled.
        fixture.center.subscribe(registration { event, _ in
            log.record("start")
            try? await Task.sleep(for: .milliseconds(200))
            return .actions([.renameTab(event.subject, title: "late")], stop: false)
        })
        let event = pageLoad()
        fixture.center.post(event)
        #expect(await eventually { log.entries == ["start"] })
        fixture.center.cancel(subject: event.subject)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(fixture.host.applied.isEmpty)
        #expect(fixture.center.lastErrors.isEmpty)
    }

    @Test func aHookThatRunsTooLongTimesOut() async {
        let fixture = HookFixture()
        fixture.center.subscribe(registration(timeout: .milliseconds(100)) { event, _ in
            try await Task.sleep(for: .seconds(30))
            return .actions([.renameTab(event.subject, title: "never")], stop: false)
        })
        fixture.center.post(pageLoad())
        #expect(await eventually { fixture.center.lastErrors[automaticFeature.id] != nil })
        #expect(fixture.center.lastErrors[automaticFeature.id] as? AIHookError == .timedOut)
        #expect(fixture.host.applied.isEmpty)
    }

    /// A hook that does not stop when cancelled, as one waiting for a page that does not answer, times out at its timeout and holds its tab's next event no longer; what it returns later counts for nothing.
    @Test func aHookThatIgnoresCancellationTimesOutWithoutHoldingItsChain() async {
        let fixture = HookFixture()
        let log = HookLog()
        fixture.center.subscribe(registration(timeout: .milliseconds(100)) { event, _ in
            let path = event.urls.first?.path ?? ""
            if path == "/first" {
                // A wait that cancellation does not end.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume() }
                }
                log.record("returned \(path)")
            }
            return .actions([.renameTab(event.subject, title: path)], stop: false)
        })
        let tab = UUID()
        fixture.center.post(pageLoad(tab, path: "/first"))
        #expect(await eventually { fixture.center.lastErrors[automaticFeature.id] != nil })
        #expect(fixture.center.lastErrors[automaticFeature.id] as? AIHookError == .timedOut)
        fixture.center.post(pageLoad(tab, path: "/second"))
        #expect(await eventually { fixture.host.applied.map(\.title) == ["/second"] })
        #expect(log.entries.isEmpty)
        #expect(await eventually { log.entries == ["returned /first"] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.host.applied.map(\.title) == ["/second"])
    }

    @Test func switchingTheFeatureOffStopsItsRunningHook() async {
        let fixture = HookFixture()
        let log = HookLog()
        fixture.center.subscribe(longRunningRegistration(log: log))
        fixture.center.post(pageLoad())
        #expect(await eventually { log.entries == ["start"] })
        fixture.service.settings.setRoute(AIRoute(isEnabled: false), for: automaticFeature.id)
        #expect(await eventually { log.entries == ["start", "stop"] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.host.applied.isEmpty)
        #expect(fixture.center.lastErrors.isEmpty)
    }

    @Test func cancellingTheSubscriptionStopsItsHook() async {
        let fixture = HookFixture()
        let log = HookLog()
        let subscription = fixture.center.subscribe(longRunningRegistration(log: log))
        fixture.center.post(pageLoad())
        #expect(await eventually { log.entries == ["start"] })
        subscription.cancel()
        #expect(await eventually { log.entries == ["start", "stop"] })
        fixture.center.post(pageLoad())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.entries == ["start", "stop"])
        #expect(fixture.host.applied.isEmpty)
    }
}

@MainActor
@Suite struct HookAvailabilityTests {
    /// Hooks that cannot run come first; the last one shows that the event has been handled.
    @Test func hooksOfFeaturesThatCannotRunSkipWithoutARequest() async {
        let log = ProviderLog()
        let fixture = HookFixture(log: log)
        let hookLog = HookLog()
        let switchedOff = enableFeature("hook.off", on: fixture.service)
        fixture.service.settings.setRoute(AIRoute(isEnabled: false, models: fixture.service.settings.route(for: automaticFeature.id).models), for: switchedOff.id)
        let withoutModel = AIFeature(id: AIFeatureID(rawValue: "hook.none"), name: "No Model", summary: "", trigger: .automatic, data: .textOnly)
        fixture.service.register(withoutModel)
        fixture.service.settings.setRoute(AIRoute(isEnabled: true), for: withoutModel.id)
        // A feature the user starts would use the default route, which hooks never do.
        fixture.service.register(userFeature)
        let unregistered = AIFeature(id: AIFeatureID(rawValue: "hook.unregistered"), name: "", summary: "", trigger: .automatic, data: .textOnly)
        for feature in [switchedOff, withoutModel, userFeature, unregistered] {
            fixture.center.subscribe(registration(feature, priority: 1) { _, context in
                hookLog.record(feature.id.rawValue)
                _ = try await context.client.reply(textRequest(feature))
                return .none
            })
        }
        fixture.center.subscribe(registration(priority: 2) { _, _ in
            hookLog.record("ready")
            return .none
        })
        fixture.center.post(pageLoad())
        #expect(await eventually { hookLog.entries == ["ready"] })
        #expect(log.requests.isEmpty)
        #expect(fixture.center.lastErrors.isEmpty)
    }

    @Test func anEventFromASiteWhereAIIsOffReachesNoHook() async {
        let fixture = HookFixture()
        let log = HookLog()
        fixture.center.subscribe(registration { event, _ in
            log.record(event.urls.first?.absoluteString ?? "")
            return .none
        })
        fixture.service.settings.excludedSites.append(AISitePattern("example.org"))
        fixture.center.post(pageLoad(path: "/excluded"))
        fixture.center.post(.pageLoaded(AIPageLoad(tabID: UUID(), url: URL(string: "flags://")!, isRestore: false)))
        fixture.center.post(.pageLoaded(AIPageLoad(tabID: UUID(), url: URL(string: "https://example.com/")!, isRestore: false)))
        #expect(await eventually { log.entries == ["https://example.com/"] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.entries == ["https://example.com/"])
    }

    @Test func aDownloadFromAPageWhereAIIsOffReachesNoHook() async {
        let fixture = HookFixture()
        let log = HookLog()
        fixture.center.subscribe(AIHookRegistration(feature: automaticFeature.id, events: [.downloadFinished], allowedActions: []) { event, _ in
            log.record(event.urls.map(\.absoluteString).joined(separator: " "))
            return .none
        })
        fixture.service.settings.excludedSites.append(AISitePattern("mail.example.org"))
        for page in ["https://mail.example.org/inbox", "https://example.com/files"] {
            let info = AIDownloadInfo(filename: "a.pdf", sourceURL: URL(string: "https://attachments.example.net/a.pdf")!, pageURL: URL(string: page)!)
            fixture.center.post(.downloadFinished(AIDownloadFinish(downloadID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/a.pdf"), info: info, isNamedByUser: false)))
        }
        #expect(await eventually { log.entries.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.entries == ["https://attachments.example.net/a.pdf https://example.com/files"])
    }

    @Test func requestsGoOutUnderTheHooksOwnFeature() async throws {
        let fixture = HookFixture(script: ["model-a": [.event(.text("Name")), .event(.finished(.completed))]])
        fixture.service.register(userFeature)
        fixture.center.subscribe(registration { _, context in
            // The request names a feature the user starts, whose route would fall back to the default one.
            _ = try await context.client.reply(textRequest(userFeature))
            return .none
        })
        fixture.center.post(pageLoad())
        #expect(await eventually { !fixture.service.activity.isEmpty })
        let entry = try #require(fixture.service.activity.last)
        #expect(entry.feature == automaticFeature.id)
        #expect(entry.model?.model == "model-a")
    }

    @Test func theDailyLimitSkipsHooksAndSaysWhy() async {
        let log = ProviderLog()
        let fixture = HookFixture(script: ["model-a": [.event(.text("Name")), .event(.finished(.completed))]], log: log)
        fixture.service.settings.limits.automaticRequestsPerDay = 1
        // The day's one automatic request goes out before any hook runs.
        #expect(await collect(fixture.service.stream(textRequest(automaticFeature))).error == nil)
        let hookLog = HookLog()
        fixture.center.subscribe(requestingRegistration(log: hookLog))
        fixture.center.post(pageLoad())
        #expect(await eventually { fixture.center.lastErrors[automaticFeature.id] != nil })
        guard case .budgetReached(.automaticRequestsPerDay) = fixture.center.lastErrors[automaticFeature.id] as? AIError else {
            Issue.record("Expected the daily limit")
            return
        }
        #expect(hookLog.entries.isEmpty)
        #expect(log.requests.count == 1)
    }

    @Test func consecutiveProviderErrorsPauseTheHookUntilResumed() async {
        let fixture = HookFixture(script: ["model-a": [.fail(.providerUnavailable(AIProviderID(), detail: "down"))]])
        let hookLog = HookLog()
        fixture.center.subscribe(requestingRegistration(log: hookLog))
        for count in 1...AIHookCenter.failuresBeforePause {
            fixture.center.post(pageLoad())
            #expect(await eventually { hookLog.entries.filter { $0 == "failed" }.count == count })
            if count < AIHookCenter.failuresBeforePause {
                try? await Task.sleep(for: .milliseconds(50))
                #expect(fixture.center.pausedFeatures.isEmpty)
            }
        }
        #expect(await eventually { fixture.center.pausedFeatures == [automaticFeature.id] })
        guard case .providerUnavailable = fixture.center.lastErrors[automaticFeature.id] as? AIError else {
            Issue.record("Expected providerUnavailable")
            return
        }
        fixture.center.post(pageLoad())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hookLog.entries.filter { $0 == "request" }.count == AIHookCenter.failuresBeforePause)

        fixture.center.resume(automaticFeature.id)
        fixture.center.post(pageLoad())
        #expect(await eventually { hookLog.entries.filter { $0 == "request" }.count == AIHookCenter.failuresBeforePause + 1 })
    }

    @Test func aHookThatSendsNoRequestLeavesTheErrorAndTheCount() async {
        let fixture = HookFixture(script: ["model-a": [.fail(.authentication(AIProviderID()))]])
        let log = HookLog()
        fixture.center.subscribe(pathRegistration(log: log))
        for (index, path) in ["/request", "/skip", "/request", "/skip", "/request"].enumerated() {
            fixture.center.post(pageLoad(path: path))
            #expect(await eventually { log.entries.count == index + 1 })
            if path == "/skip" {
                try? await Task.sleep(for: .milliseconds(50))
                #expect(fixture.center.lastErrors[automaticFeature.id] != nil)
            }
        }
        #expect(await eventually { fixture.center.pausedFeatures == [automaticFeature.id] })
    }

    @Test func aHooksOwnErrorShowsWithoutStartingTheCountAgain() async {
        let fixture = HookFixture(script: ["model-a": [.fail(.authentication(AIProviderID()))]])
        let log = HookLog()
        fixture.center.subscribe(pathRegistration(log: log))
        for (index, path) in ["/request", "/request", "/throw"].enumerated() {
            fixture.center.post(pageLoad(path: path))
            #expect(await eventually { log.entries.count == index + 1 })
        }
        #expect(await eventually { fixture.center.lastErrors[automaticFeature.id] is HookTestError })
        #expect(fixture.center.pausedFeatures.isEmpty)
        fixture.center.post(pageLoad(path: "/request"))
        #expect(await eventually { fixture.center.pausedFeatures == [automaticFeature.id] })
    }

    @Test func aRequestThatSucceedsClearsTheError() async {
        let fixture = HookFixture(script: ["model-a": [.event(.text("Name")), .event(.finished(.completed))]])
        fixture.center.subscribe(pathRegistration(log: HookLog()))
        fixture.center.post(pageLoad(path: "/throw"))
        #expect(await eventually { fixture.center.lastErrors[automaticFeature.id] is HookTestError })
        fixture.center.post(pageLoad(path: "/request"))
        #expect(await eventually { fixture.center.lastErrors.isEmpty })
    }

    @Test func changingTheRouteResumesAPausedHookAndClearsItsError() async {
        let fixture = HookFixture(script: ["model-a": [.fail(.authentication(AIProviderID()))]])
        fixture.center.subscribe(requestingRegistration(log: HookLog()))
        for _ in 1...AIHookCenter.failuresBeforePause { fixture.center.post(pageLoad()) }
        #expect(await eventually { fixture.center.pausedFeatures.contains(automaticFeature.id) })
        var route = fixture.service.settings.route(for: automaticFeature.id)
        route.isEnabled = false
        fixture.service.settings.setRoute(route, for: automaticFeature.id)
        #expect(fixture.center.pausedFeatures.isEmpty)
        #expect(fixture.center.lastErrors.isEmpty)
    }
}

// MARK: - Helpers

/// What a test's hooks did, in order.
final class HookLog: @unchecked Sendable {
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

/// A host that applies every action except tab names it refuses, and reads one fixed page for every tab.
@MainActor
final class TestHookHost: AIHookHost {
    let pages: any AIPageSource = FixedPages()
    var refusesTitles: Set<String> = []
    private(set) var offered: [AIHookAction] = []
    private(set) var applied: [AIHookAction] = []

    func apply(_ action: AIHookAction, for event: AIHookEvent) -> Bool {
        offered.append(action)
        guard !refusesTitles.contains(action.title) else { return false }
        applied.append(action)
        return true
    }
}

struct FixedPages: AIPageSource {
    func content(ofTab id: UUID, limit: Int) async throws -> AIPageContent {
        AIPageContent(url: URL(string: "https://example.org/page")!, title: "Page", text: "Text")
    }

    func selection(ofTab id: UUID) async throws -> AISelection? { nil }
}

extension AIHookAction {
    /// The name the action gives.
    var title: String {
        switch self {
        case .renameTab(_, let title): return title
        case .renameDownload(_, let filename): return filename
        }
    }
}

/// A service whose automatic test feature has a model of its own, and a host for its hooks, which the center holds weakly.
@MainActor
final class HookFixture {
    let service: AIService
    let host = TestHookHost()
    var center: AIHookCenter { service.hooks }

    init(script: [String: [Step]] = [:], log: ProviderLog = ProviderLog()) {
        service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: script, log: log)
        service.hooks.host = host
        enable(automaticFeature, on: service)
    }
}

/// Registers the automatic feature and gives it the service's first model.
@MainActor
func enable(_ feature: AIFeature, on service: AIService) {
    service.register(feature)
    let model = AIModelRef(provider: service.settings.providers[0].id, model: "model-a")
    service.settings.setRoute(AIRoute(isEnabled: true, models: [model]), for: feature.id)
}

@MainActor
func enableFeature(_ id: String, on service: AIService) -> AIFeature {
    let feature = AIFeature(id: AIFeatureID(rawValue: id), name: id, summary: "", trigger: .automatic, data: .textOnly)
    enable(feature, on: service)
    return feature
}

func registration(_ feature: AIFeature = automaticFeature, priority: Int = 100, delay: Duration = .zero, timeout: Duration = .seconds(30),
                  allowedActions: Set<AIHookActionKind> = [.renameTab, .renameDownload],
                  handler: @escaping @Sendable (AIHookEvent, AIHookContext) async throws -> AIHookResult) -> AIHookRegistration {
    AIHookRegistration(feature: feature.id, events: [.pageLoaded], priority: priority, delay: delay, timeout: timeout, allowedActions: allowedActions, handler: handler)
}

/// A hook that runs until it is cancelled, logging its start and its stop.
func longRunningRegistration(log: HookLog) -> AIHookRegistration {
    registration { event, _ in
        log.record("start")
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            log.record("stop")
            throw error
        }
        return .actions([.renameTab(event.subject, title: "never")], stop: false)
    }
}

/// A hook that sends one text request through its context, logging the request and its failure.
func requestingRegistration(log: HookLog) -> AIHookRegistration {
    registration { _, context in
        log.record("request")
        do {
            _ = try await context.client.reply(textRequest(automaticFeature))
        } catch {
            log.record("failed")
            throw error
        }
        return .none
    }
}

/// A hook that sends one text request for a page at `/request`, throws an error of its own at `/throw`, and sends nothing elsewhere, logging the path once it is done.
func pathRegistration(log: HookLog) -> AIHookRegistration {
    registration { event, context in
        let path = event.urls.first?.path ?? ""
        defer { log.record(path) }
        switch path {
        case "/request": _ = try await context.client.reply(textRequest(automaticFeature))
        case "/throw": throw HookTestError()
        default: break
        }
        return .none
    }
}

/// An error a test's hook throws outside its requests.
struct HookTestError: Error {}

func pageLoad(_ tabID: UUID = UUID(), path: String = "/page") -> AIHookEvent {
    .pageLoaded(AIPageLoad(tabID: tabID, url: URL(string: "https://example.org\(path)")!, isRestore: false))
}

/// Waits up to two seconds for the condition, and reports whether it held.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
