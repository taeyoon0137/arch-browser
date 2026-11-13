// The shared hook scheduler: steps of one event from several owners in one chain in order, another event replacing the chain once its running step stops, a close keeping its own chain, a new document ending only other documents' chains, canceling an owner, the per-owner pause after three authentication or provider errors with its resume when one of the step's routes changes, and the feature checks for steps with a feature and none for steps without. Every step ends exactly once.
import Foundation
import Testing
@testable import AI

@MainActor
@Suite struct AIHookSchedulerTests {
    private let service: AIService
    private var scheduler: AIHookScheduler { service.hooks.scheduler }
    private let tab = UUID()
    private let log = HookLog()

    init() {
        service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: [:])
        enable(automaticFeature, on: service)
    }

    @Test func stepsOfOneEventFromEveryOwnerRunInOneChainInOrder() async {
        let event = UUID()
        scheduler.post([step("registry")], kind: "pageLoaded", subject: tab, event: event, document: page("/a"))
        scheduler.post([step("center", owner: automaticFeature.id.rawValue, order: 100)], kind: "pageLoaded", subject: tab, event: event, document: page("/a"))
        scheduler.post([step("plugin", owner: "plugin.sample", order: 200), step("registry second", order: 1_000)], kind: "pageLoaded", subject: tab, event: event, document: page("/a"))
        #expect(await eventually { log.entries.count == 8 })
        #expect(log.entries == ["start center", "center finished", "start plugin", "plugin finished", "start registry", "registry finished", "start registry second", "registry second finished"])
    }

    @Test func anotherEventReplacesTheChainOnceItsRunningStepStops() async {
        scheduler.post([step("first", work: untilCanceled("first")), step("waiting", order: 2_000)], kind: "pageLoaded", subject: tab, event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries == ["start first"] })
        scheduler.post([step("second")], kind: "pageLoaded", subject: tab, event: UUID(), document: page("/b"))
        #expect(await eventually { log.entries.contains("second finished") })
        #expect(log.entries == ["start first", "waiting skipped canceled", "stop first", "first stopped", "start second", "second finished"])
    }

    @Test func aDeclinedStepSkipsAndTheNextRuns() async {
        scheduler.post([step("declined", mayRun: false), step("next", order: 2_000)], kind: "tabOpened", subject: tab, event: UUID(), document: nil)
        #expect(await eventually { log.entries.count == 3 })
        #expect(log.entries == ["declined skipped declinedByOwner", "start next", "next finished"])
    }

    @Test func aCloseEndsTheTabsOtherChainsAndRunsItsOwn() async {
        scheduler.post([step("load", work: untilCanceled("load"))], kind: "pageLoaded", subject: tab, event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries == ["start load"] })
        let close = UUID()
        scheduler.post([step("close", delay: .milliseconds(100))], kind: "tabClosed", subject: tab, event: close, document: nil)
        scheduler.cancel(subject: tab, except: close)
        #expect(await eventually { log.entries.contains("close finished") })
        #expect(log.entries.contains("load stopped"))
        #expect(!log.entries.contains("close skipped canceled"))
    }

    @Test func aNewDocumentEndsOnlyTheChainsOfOtherDocuments() async {
        scheduler.post([step("old", work: untilCanceled("old"))], kind: "pageLoaded", subject: tab, event: UUID(), document: page("/a"))
        scheduler.post([step("same", work: untilCanceled("same"))], kind: "titleChanged", subject: tab, event: UUID(), document: page("/b#top"))
        scheduler.post([step("none", work: untilCanceled("none"))], kind: "tabOpened", subject: tab, event: UUID(), document: nil)
        let other = UUID()
        scheduler.post([step("elsewhere", work: untilCanceled("elsewhere"))], kind: "pageLoaded", subject: other, event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries.filter { $0.hasPrefix("start") }.count == 4 })
        scheduler.cancel(subject: tab, otherThan: page("/b#part"))
        #expect(await eventually { log.entries.contains("old stopped") })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!log.entries.contains("same stopped"))
        #expect(!log.entries.contains("none stopped"))
        #expect(!log.entries.contains("elsewhere stopped"))
        scheduler.cancel(subject: tab)
        scheduler.cancel(subject: other)
        #expect(await eventually { ["same stopped", "none stopped", "elsewhere stopped"].allSatisfy(log.entries.contains) })
    }

    @Test func cancelingAnOwnerStopsItsRunningStepAndSkipsItsWaitingOnes() async {
        scheduler.post([step("running", work: untilCanceled("running")), step("other", owner: "hook.b", order: 2_000), step("waiting", order: 3_000)],
                       kind: "pageLoaded", subject: tab, event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries == ["start running"] })
        scheduler.cancel(owner: "hook.a")
        #expect(await eventually { log.entries.contains("other finished") })
        #expect(log.entries == ["start running", "waiting skipped canceled", "stop running", "running stopped", "start other", "other finished"])
    }

    @Test func threeAuthenticationOrProviderErrorsPauseTheOwnerUntilARouteOfItsStepsChanges() async {
        let owner = "hook.paused"
        let failing: Work = { requestDidEnd in await requestDidEnd(AIError.authentication(AIProviderID())) }
        for index in 1...AIHookScheduler.failuresBeforePause {
            let error: AIError = index == 2 ? .providerUnavailable(AIProviderID(), detail: "down") : .authentication(AIProviderID())
            scheduler.post([step("run \(index)", owner: owner, feature: automaticFeature.id, routes: ["tier.fast"]) { requestDidEnd in await requestDidEnd(error) }],
                           kind: "pageLoaded", subject: UUID(), event: UUID(), document: page("/a"))
            #expect(await eventually { log.entries.contains("run \(index) finished") })
        }
        #expect(scheduler.pausedOwners == [owner])
        // The center's paused features read the scheduler's owners.
        #expect(service.hooks.pausedFeatures == [AIFeatureID(rawValue: owner)])
        scheduler.post([step("paused", owner: owner, feature: automaticFeature.id, routes: ["tier.fast"], work: failing)], kind: "pageLoaded", subject: UUID(), event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries.contains("paused skipped paused") })
        // A step without a feature does not wait for the pause.
        scheduler.post([step("script", owner: owner)], kind: "pageLoaded", subject: UUID(), event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries.contains("script finished") })

        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: service.settings.providers[0].id, model: "model-a")]), for: AIFeatureID(rawValue: "tier.fast"))
        #expect(scheduler.pausedOwners.isEmpty)
        scheduler.post([step("resumed", owner: owner, feature: automaticFeature.id, routes: ["tier.fast"])], kind: "pageLoaded", subject: UUID(), event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries.contains("resumed finished") })
    }

    @Test func aReplyBetweenErrorsStartsTheCountAgainAndResumeClearsAPause() async {
        let owner = "hook.counted"
        let outcomes: [AIError?] = [.authentication(AIProviderID()), .authentication(AIProviderID()), nil, .authentication(AIProviderID()), .authentication(AIProviderID())]
        for (index, outcome) in outcomes.enumerated() {
            scheduler.post([step("run \(index)", owner: owner, feature: automaticFeature.id) { requestDidEnd in await requestDidEnd(outcome) }],
                           kind: "pageLoaded", subject: UUID(), event: UUID(), document: page("/a"))
            #expect(await eventually { log.entries.contains("run \(index) finished") })
        }
        #expect(scheduler.pausedOwners.isEmpty)
        scheduler.post([step("third", owner: owner, feature: automaticFeature.id) { requestDidEnd in await requestDidEnd(AIError.authentication(AIProviderID())) }],
                       kind: "pageLoaded", subject: UUID(), event: UUID(), document: page("/a"))
        #expect(await eventually { scheduler.pausedOwners == [owner] })
        scheduler.resume(owner: owner)
        #expect(scheduler.pausedOwners.isEmpty)
        scheduler.post([step("after resume", owner: owner, feature: automaticFeature.id)], kind: "pageLoaded", subject: UUID(), event: UUID(), document: page("/a"))
        #expect(await eventually { log.entries.contains("after resume finished") })
    }

    @Test func aChangedRouteStopsTheRunningStepsThatUseIt() async {
        scheduler.post([step("tiered", feature: automaticFeature.id, routes: [automaticFeature.id.rawValue], work: untilCanceled("tiered"))],
                       kind: "pageLoaded", subject: tab, event: UUID(), document: page("/a"))
        scheduler.post([step("untouched", owner: "hook.b", routes: ["tier.deep"], work: untilCanceled("untouched"))], kind: "tabOpened", subject: tab, event: UUID(), document: nil)
        #expect(await eventually { log.entries.filter { $0.hasPrefix("start") }.count == 2 })
        service.settings.setRoute(AIRoute(isEnabled: false), for: automaticFeature.id)
        #expect(await eventually { log.entries.contains("tiered stopped") })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!log.entries.contains("untouched stopped"))
        scheduler.cancel(subject: tab)
        #expect(await eventually { log.entries.contains("untouched stopped") })
    }

    @Test func featureChecksApplyOnlyToStepsWithAFeature() async {
        service.settings.excludedSites.append(AISitePattern("example.org"))
        let unregistered = AIFeatureID(rawValue: "hook.unregistered")
        scheduler.post([step("excluded", feature: automaticFeature.id), step("script", order: 2_000)], kind: "pageLoaded", subject: tab, event: UUID(), document: page("/a"), urls: [page("/a")])
        #expect(await eventually { log.entries.contains("script finished") })
        #expect(log.entries.first == "excluded skipped excludedSite")
        // A post whose every step skips at once leaves the tab's chain alone.
        scheduler.post([step("running", work: untilCanceled("running"))], kind: "tabOpened", subject: tab, event: UUID(), document: nil)
        #expect(await eventually { log.entries.contains("start running") })
        scheduler.post([step("dropped", feature: automaticFeature.id)], kind: "tabOpened", subject: tab, event: UUID(), document: nil, urls: [page("/b")])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!log.entries.contains("running stopped"))
        scheduler.cancel(subject: tab)

        let elsewhere = URL(string: "https://example.com/")!
        scheduler.post([step("unregistered", feature: unregistered), step("unregistered script", order: 2_000)], kind: "pageLoaded", subject: UUID(), event: UUID(), document: elsewhere, urls: [elsewhere])
        #expect(await eventually { log.entries.contains("unregistered script finished") })
        #expect(log.entries.contains("unregistered skipped unavailable"))
        #expect(!log.entries.contains("start unregistered"))

        service.settings.limits.automaticRequestsPerDay = 0
        scheduler.post([step("over budget", feature: automaticFeature.id), step("budget script", order: 2_000)], kind: "pageLoaded", subject: UUID(), event: UUID(), document: elsewhere, urls: [elsewhere])
        #expect(await eventually { log.entries.contains("budget script finished") })
        #expect(log.entries.contains("over budget skipped budgetReached"))
    }

    // MARK: Helpers

    typealias Work = @Sendable (_ requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) async throws -> Void

    private func page(_ path: String) -> URL {
        URL(string: "https://example.org\(path)")!
    }

    /// A step that logs its start and its end.
    private func step(_ name: String, owner: String = "hook.a", order: Int = 1_000, feature: AIFeatureID? = nil, routes: Set<String> = [], delay: Duration = .zero,
                      mayRun: Bool = true, work: @escaping Work = { _ in }) -> AIHookStep {
        let log = log
        return AIHookStep(owner: owner, order: order, feature: feature, routes: routes, delay: delay, timeout: .seconds(30), mayRun: { mayRun },
                          run: { requestDidEnd in
                              log.record("start \(name)")
                              try await work(requestDidEnd)
                          },
                          didEnd: { log.record("\(name) \(Self.describe($0))") })
    }

    /// Work that runs until it is canceled, logging its stop.
    private func untilCanceled(_ name: String) -> Work {
        let log = log
        return { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                log.record("stop \(name)")
                throw error
            }
        }
    }

    private static func describe(_ outcome: AIHookStepOutcome) -> String {
        switch outcome {
        case .finished: return "finished"
        case .failed: return "failed"
        case .timedOut: return "timedOut"
        case .stopped: return "stopped"
        case .skipped(let reason):
            switch reason {
            case .canceled: return "skipped canceled"
            case .declinedByOwner: return "skipped declinedByOwner"
            case .paused: return "skipped paused"
            case .excludedSite: return "skipped excludedSite"
            case .unavailable: return "skipped unavailable"
            case .budgetReached: return "skipped budgetReached"
            }
        }
    }
}
