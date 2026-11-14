// The hook registry (`docs/hooks.md`, Running and the sections after it): triggers and filters with the run's tabs; list order after the center's hooks in one chain of the shared scheduler; the delay and its replacement; a newer event canceling a run; a new document ending a run for the earlier one, with a `firstAfterOpen` hook so ended running once for the next load; a close hook running after its tab is gone, with the closed tab's last name and address in memory only; a close ending the tab's other runs; the concurrency caps and the dropped oldest run; loop protection, with one skip logged a minute; pausing after three failures, after the scheduler's pause, also across a relaunch, and Resume; an update that keeps the state; Stop All Agents; a deleted place; a changed script; the daily count, also for runs that waited for a slot together; the run log without content, with nothing at Keep Nothing, no file without a change, and its latest entries; agent hooks' features and site exclusions; known providers; Run Hooks; and tests that report without applying and stay within the filter. A fake runner stands in for the script runners.
import Agent
import AgentControl
import AI
import Events
import Foundation
import Testing
@testable import Hooks

@MainActor @Suite struct HookRegistryTests {
    private let harness = RegistryHarness()

    private var registry: HookRegistry { harness.registry }
    private var runner: FakeScriptRunner { harness.javaScript }

    // MARK: Matching

    @Test func triggersMatchTheirOptions() {
        let tab = harness.tab("/a")
        let other = harness.tab("/a#part", id: tab.id)
        func event(_ payload: BrowserEventPayload) -> BrowserEvent {
            BrowserEvent(id: UUID(), sequence: 1, date: Date(), payload: payload, cause: nil)
        }
        let first = event(.pageLoaded(tab: tab, isRestore: false, isFirstLoadAfterOpen: true))
        let later = event(.pageLoaded(tab: other, isRestore: false, isFirstLoadAfterOpen: false))
        let restored = event(.pageLoaded(tab: tab, isRestore: true, isFirstLoadAfterOpen: false))
        let firstLoads = HookTrigger.pageLoaded(loads: .firstAfterOpen, includesRestoredTabs: false)
        #expect(firstLoads.matches(first))
        #expect(!firstLoads.matches(later))
        #expect(firstLoads.matches(later, carriesFirstLoad: true))
        #expect(!firstLoads.matches(restored))
        #expect(!HookTrigger.pageLoaded(loads: .every, includesRestoredTabs: false).matches(restored))
        #expect(HookTrigger.pageLoaded(loads: .every, includesRestoredTabs: true).matches(restored))
        let newAddress = HookTrigger.pageLoaded(loads: .newAddress, includesRestoredTabs: false)
        #expect(!newAddress.matches(later, previousDocument: tab.url))
        #expect(newAddress.matches(later, previousDocument: URL(string: "https://example.org/b")))
        #expect(newAddress.matches(later))

        let sameHost = event(.addressChanged(tab: harness.tab("/b"), previousURL: URL(string: "https://EXAMPLE.org/a")))
        let newHost = event(.addressChanged(tab: harness.tab("/b"), previousURL: URL(string: "https://example.com/a")))
        #expect(!HookTrigger.addressChanged(changes: .newHost).matches(sameHost))
        #expect(HookTrigger.addressChanged(changes: .newHost).matches(newHost))
        #expect(HookTrigger.addressChanged(changes: .any).matches(sameHost))

        #expect(HookTrigger.titleChanged(sources: [.page]).matches(event(.titleChanged(tab: tab, source: .page))))
        #expect(!HookTrigger.titleChanged(sources: [.page]).matches(event(.titleChanged(tab: tab, source: .suggested))))
        #expect(HookTrigger.tabClosed(reasons: []).matches(event(.tabClosed(tab: tab, reason: .crash))))
        #expect(!HookTrigger.tabClosed(reasons: [.user]).matches(event(.tabClosed(tab: tab, reason: .page))))
        let samePersona = event(.spaceSwitched(windowID: UUID(), spaceID: HookIDs.home, personaID: HookIDs.persona, previousSpaceID: HookIDs.work, previousPersonaID: HookIDs.persona))
        #expect(!HookTrigger.spaceSwitched(personaChangesOnly: true).matches(samePersona))
        #expect(HookTrigger.spaceSwitched(personaChangesOnly: false).matches(samePersona))
        #expect(!HookTrigger.tabOpened.matches(first))
    }

    @Test func aFilterChoosesTheEventsAndTheRunsTabs() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let filter = BrowserEventFilter(scope: .places([.space(HookIDs.work)]), sites: [AISitePattern("example.org")])
        let hook = try harness.add(instantHook("Work", .tabOpened, filter: filter))
        #expect(hook.filter.kinds == [.tabOpened])
        #expect(throws: HookRegistryError.namesAgentTabs) {
            try registry.add(instantHook("Agents", .tabOpened, filter: BrowserEventFilter(tabKinds: [.agent])), script: Data())
        }

        let covered = harness.tab("/covered")
        let home = harness.tab("/home", space: HookIDs.home)
        let elsewhere = harness.tab("/", host: "example.com")
        let otherPersona = harness.tab("/", persona: HookIDs.otherPersona, space: HookIDs.other)
        let agent = harness.tab("/agent", kind: .agent)
        [covered, home, elsewhere, otherPersona, agent].forEach(harness.host.show)
        let opened = harness.tab("/opened")
        harness.host.show(opened)
        for tab in [home, elsewhere, otherPersona, opened] {
            harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        }
        #expect(await eventually { runner.invocations.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        let invocation = try #require(runner.invocations.first)
        #expect(runner.invocations.count == 1)
        #expect(invocation.eventTab == opened.id)
        #expect(invocation.tabs == [covered.id, opened.id])
        // The event's address is the event tab's document only for page, address, and title events.
        #expect(invocation.documents.isEmpty)
        #expect(invocation.cause.origin == .hookRun(hook: hook.id, run: invocation.run))
        #expect(invocation.cause.hookChain == [hook.id])
        #expect(invocation.appliesActions)
    }

    @Test func registryStepsRunAfterTheCentersInOneChainInListOrder() async throws {
        defer { harness.cleanUp() }
        let order = OrderLog()
        let scheduler = harness.service.hooks.scheduler
        // The center's hooks hear the bus first, as `BrowserHooks` subscribes before the registry.
        harness.bus.subscribe(.everything) { event in
            scheduler.post([AIHookStep(owner: "test.center", order: 100, feature: nil, run: { _ in }, didEnd: { _ in order.record("center") })],
                           kind: event.kind.rawValue, subject: event.subject, event: event.id, document: nil)
        }
        try await harness.start()
        let first = try harness.add(instantHook("First", .tabOpened))
        let second = try harness.add(instantHook("Second", .tabOpened))
        runner.onRun = { order.record($0.hook.name) }
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { order.entries.count == 3 })
        #expect(order.entries == ["center", "First", "Second"])

        registry.move(second.id, to: 0)
        #expect(registry.hooks.map(\.id) == [second.id, first.id])
        order.entries = []
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { order.entries.count == 3 })
        #expect(order.entries == ["center", "Second", "First"])
    }

    // MARK: Waiting, replacement, documents, and closes

    @Test func aNewerEventDuringTheDelayReplacesTheWaitingRun() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        var hook = instantHook("Delayed", .pageLoaded(loads: .every, includesRestoredTabs: false))
        hook.timing.delay = .milliseconds(200)
        try harness.add(hook)
        let id = UUID()
        harness.load(harness.tab("/a", id: id))
        harness.load(harness.tab("/b", id: id), first: false)
        #expect(await eventually { runner.invocations.count == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations[0].documents == [id: URL(string: "https://example.org/b")!])
        // A replaced waiting run is no run, so the log does not name it.
        #expect(await eventually { harness.entries(of: hook.id).map(\.outcome) == [.completed] })
    }

    @Test func aNewerEventCancelsARunningRun() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Held", .tabSelected))
        runner.behaviors[hook.id] = .hold
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        #expect(await eventually { runner.invocations.count == 1 })
        harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        #expect(await eventually { runner.invocations.count == 2 })
        #expect(runner.cancelled == [runner.invocations[0].run])
        runner.releaseAll()
        #expect(await eventually { harness.entries(of: hook.id).map(\.outcome) == [.cancelled, .completed] })
        #expect(registry.hooks[0].state == .active)
    }

    @Test func aNewDocumentEndsTheRunForTheEarlierOneAndAFirstLoadHookRunsForTheNext() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("First Load", .pageLoaded(loads: .firstAfterOpen, includesRestoredTabs: false)))
        runner.behaviors[hook.id] = .hold
        let id = UUID()
        harness.load(harness.tab("/a", id: id))
        #expect(await eventually { runner.invocations.count == 1 })
        // Another fragment is the same document.
        harness.host.show(harness.tab("/a#part", id: id))
        harness.bus.post(.addressChanged(tab: harness.tab("/a#part", id: id), previousURL: URL(string: "https://example.org/a")))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.cancelled.isEmpty)
        harness.host.show(harness.tab("/b", id: id))
        harness.bus.post(.addressChanged(tab: harness.tab("/b", id: id), previousURL: URL(string: "https://example.org/a#part")))
        #expect(await eventually { runner.cancelled.count == 1 })

        harness.load(harness.tab("/b", id: id), first: false)
        #expect(await eventually { runner.invocations.count == 2 })
        #expect(runner.invocations[1].documents == [id: URL(string: "https://example.org/b")!])
        runner.releaseAll()
        #expect(await eventually { harness.entries(of: hook.id).map(\.outcome) == [.cancelled, .completed] })
        // Once a run for the tab completed, its later loads are not its first.
        harness.load(harness.tab("/c", id: id), first: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.invocations.count == 2)
    }

    @Test func aCloseHookRunsAfterItsTabIsGoneWithItsLastNameAndAddress() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Closed", .tabClosed(reasons: [])))
        let left = harness.tab("/left")
        harness.host.show(left)
        let closing = harness.tab("/private/path?q=secret")
        harness.host.show(closing)
        harness.host.names[closing.id] = "Secret Title"
        harness.close(closing)
        #expect(await eventually { runner.invocations.count == 1 })
        let invocation = runner.invocations[0]
        #expect(invocation.closedTab == AgentRunClosedTab(name: "Secret Title", url: closing.url))
        #expect(invocation.eventTab == nil)
        #expect(invocation.tabs == [left.id])
        #expect(await eventually { harness.entries(of: hook.id).count == 1 })
        let entry = harness.entries(of: hook.id)[0]
        #expect(entry.site == "example.org")
        #expect(entry.subject == "open")
        registry.log.saveNow()
        let file = try String(contentsOf: registry.log.fileURL, encoding: .utf8)
        for content in ["Secret", "private", "secret", "q="] {
            #expect(!file.contains(content))
        }
    }

    @Test func aCloseEndsTheTabsOtherRuns() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let load = try harness.add(instantHook("Load", .pageLoaded(loads: .every, includesRestoredTabs: false)))
        let close = try harness.add(instantHook("Close", .tabClosed(reasons: [.user])))
        runner.behaviors[load.id] = .hold
        let tab = harness.tab("/a")
        harness.load(tab)
        #expect(await eventually { runner.invocations.count == 1 })
        harness.close(tab)
        #expect(await eventually { runner.invocations(of: close.id).count == 1 })
        #expect(runner.cancelled == [runner.invocations[0].run])
        #expect(await eventually { harness.entries(of: load.id).map(\.outcome) == [.cancelled] })
    }

    // MARK: Concurrency

    @Test func runsWaitForASlotAndTheOldestWaitingRunIsDropped() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let opened = try harness.add(instantHook("Opened", .tabOpened))
        let selected = try harness.add(instantHook("Selected", .tabSelected))
        runner.behaviors[opened.id] = .hold
        runner.behaviors[selected.id] = .hold
        // 110 chains of their own: 4 run, 100 wait, and the 6 oldest waiting are dropped.
        let tabs = (0..<55).map { harness.tab("/\($0)") }
        tabs.forEach(harness.host.show)
        for tab in tabs {
            harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
            harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        }
        #expect(await eventually { registry.log.entries.filter { $0.reason == .dropped }.count == 6 })
        #expect(runner.invocations.count == HookRegistry.maximumRunning)
        #expect(runner.mostRunningPerHook.values.allSatisfy { $0 <= HookRegistry.maximumRunningPerHook })
        while runner.invocations.count < 104 || runner.heldCount > 0 {
            runner.releaseAll()
            guard await eventually({ runner.heldCount > 0 || runner.invocations.count == 104 }) else { break }
        }
        #expect(await eventually { registry.log.entries.filter { $0.outcome == .completed }.count == 104 })
        #expect(runner.mostRunning == HookRegistry.maximumRunning)
        #expect(runner.mostRunningPerHook.values.allSatisfy { $0 <= HookRegistry.maximumRunningPerHook })
    }

    @Test func slotsStartWaitingRunsInArrivalOrderWithinTheCaps() async throws {
        let slots = HookRunSlots(total: 2, perHook: 1, waiting: 2)
        let first = UUID(), second = UUID()
        let started = OrderLog()
        func acquire(_ name: String, hook: UUID) {
            Task {
                do {
                    try await slots.acquire(run: UUID(), hook: hook)
                    started.record(name)
                } catch {
                    started.record("\(name) dropped")
                }
            }
        }
        try await slots.acquire(run: UUID(), hook: first)
        // `a` waits for its hook's slot, and `b` takes the other.
        acquire("a", hook: first)
        #expect(await eventually { slots.waitingCount == 1 })
        let b = UUID()
        try await slots.acquire(run: b, hook: second)
        acquire("late", hook: second)
        #expect(await eventually { slots.waitingCount == 2 })
        // A third waiting run makes the wait too long, so the oldest, `a`, is dropped.
        acquire("c", hook: first)
        #expect(await eventually { started.entries == ["a dropped"] })
        #expect(slots.waitingCount == 2)
        // `late` came before `c`, and `c`'s hook still runs.
        slots.release(run: b)
        #expect(await eventually { started.entries == ["a dropped", "late"] })
        #expect(slots.runningCount == 2)
        #expect(slots.waitingCount == 1)
    }

    // MARK: Loop protection

    @Test func aHookNeverRunsForItsOwnEffectsNorThreeHooksDeep() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Loop", .tabOpened))
        let tab = harness.tab()
        harness.host.show(tab)
        let other = UUID()
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil), cause: BrowserEventCause(origin: .hookRun(hook: hook.id, run: UUID()), hookChain: [hook.id]))
        harness.bus.post(.tabOpened(tab: harness.tab(), openerTabID: nil), cause: BrowserEventCause(origin: .hookRun(hook: other, run: UUID()), hookChain: [UUID(), UUID(), other]))
        #expect(await eventually { harness.entries(of: hook.id).count == 2 })
        #expect(harness.entries(of: hook.id).map(\.reason) == [.loop, .loop])
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil), cause: BrowserEventCause(origin: .plugin(id: "sample"), hookChain: [other]))
        #expect(await eventually { runner.invocations.count == 1 })
        #expect(runner.invocations[0].cause.hookChain == [other, hook.id])
    }

    @Test func runsPastTheRateCapsAreSkippedWithoutAPauseAndLoggedOnceAMinute() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Selections", .tabSelected))
        let tab = harness.tab()
        harness.host.show(tab)
        func skips() -> Int {
            harness.entries(of: hook.id).filter { $0.reason == .rateLimit }.count
        }
        // 10 for one tab within a minute: the 2 past them are skipped, and the first of them is logged.
        for _ in 0..<12 {
            harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        }
        #expect(await eventually { skips() == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(skips() == 1)
        #expect(registry.hooks[0].state == .active)
        // A minute later, 60 in all: the 61st other tab is skipped and logged.
        harness.clock.now += 61
        for _ in 0..<61 {
            harness.bus.post(.tabSelected(tab: harness.tab(), windowID: UUID()))
        }
        #expect(await eventually { skips() == 2 })
        #expect(registry.hooks[0].state == .active)
        harness.clock.now += 61
        harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(skips() == 2)
    }

    @Test func aTitleHookThatKeepsRunningForOneTabPausesUntilResumed() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Titles", .titleChanged(sources: [.page])))
        let tab = harness.tab()
        harness.host.show(tab)
        for _ in 0...HookRateLimiter.runsPerSubject {
            harness.bus.post(.titleChanged(tab: tab, source: .page))
        }
        #expect(registry.hooks[0].state == .paused(.ranTooOften))
        #expect(await eventually { harness.entries(of: hook.id).contains { $0.reason == .rateLimit } })
        registry.resume(hook.id)
        #expect(registry.hooks[0].state == .active)
        let before = runner.invocations.count
        harness.bus.post(.titleChanged(tab: tab, source: .page))
        #expect(await eventually { runner.invocations.count == before + 1 })
    }

    // MARK: Pausing

    @Test func threeFailuresInARowPauseTheHookAndResumeStartsTheCountAgain() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Failing", .tabOpened))
        func open(expecting count: Int) async {
            let tab = harness.tab()
            harness.host.show(tab)
            harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
            #expect(await eventually { harness.entries(of: hook.id).count == count })
        }
        runner.behaviors[hook.id] = .fail("Boom")
        await open(expecting: 1)
        await open(expecting: 2)
        runner.behaviors[hook.id] = .complete([])
        await open(expecting: 3)
        runner.behaviors[hook.id] = .fail("Boom")
        await open(expecting: 4)
        await open(expecting: 5)
        #expect(registry.hooks[0].state == .active)
        await open(expecting: 6)
        #expect(registry.hooks[0].state == .paused(.failures))
        #expect(registry.lastRuns[hook.id]?.last?.message == "Boom")
        #expect(registry.dayCounts[hook.id]?.failures == 5)
        registry.resume(hook.id)
        await open(expecting: 7)
        #expect(registry.hooks[0].state == .active)
    }

    @Test func theSchedulersPauseFollowsTheHookAndItsTiersRouteChangeResumesItAlsoAfterARelaunch() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(agentHook("Agent", .tabOpened))
        runner.behaviors[hook.id] = .requests(Array(repeating: AIError.authentication(harness.provider.id), count: AIHookScheduler.failuresBeforePause))
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { registry.hooks[0].state == .paused(.providerErrors) })
        let twoModels = AIRoute(isEnabled: true, models: [AIModelRef(provider: harness.provider.id, model: "model-a"), AIModelRef(provider: harness.provider.id, model: "model-b")])
        harness.service.settings.setRoute(twoModels, for: .tier(.fast))
        #expect(await eventually { registry.hooks[0].state == .active })
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { runner.invocations.count == 2 })
        #expect(await eventually { registry.hooks[0].state == .paused(.providerErrors) })
        let url = harness.folder.appendingPathComponent("hooks.json")
        #expect(await eventually {
            (try? AgentJSON.decode(Data(contentsOf: url))["settings"]?["hooks"]?.arrayValue?.first?["state"]) == ["paused": "providerErrors"]
        })

        // After a relaunch the scheduler holds no pause, and a change to the tier's route still resumes the hook.
        let next = RegistryHarness(folder: harness.folder, keys: harness.keys)
        let relaunched = try await next.start()
        #expect(relaunched.hooks[0].state == .paused(.providerErrors))
        next.service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: next.provider.id, model: "model-a"), AIModelRef(provider: next.provider.id, model: "model-b")]),
                                       for: .tier(.fast))
        #expect(await eventually { relaunched.hooks[0].state == .active })
        next.host.show(tab)
        next.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { next.javaScript.invocations.count == 1 })
    }

    @Test func anUpdateKeepsTheHooksStateForPauseAndResumeToChange() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(agentHook("Agent", .tabOpened))
        registry.stopAgentHooks()
        var edited = registry.hooks[0]
        edited.name = "Renamed"
        edited.state = .active
        try registry.update(edited, script: nil)
        #expect(registry.hooks[0].name == "Renamed")
        #expect(registry.hooks[0].state == .paused(.stopAllAgents))
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.invocations.isEmpty)
        registry.resume(hook.id)
        #expect(registry.hooks[0].state == .active)
    }

    @Test func stopAllAgentsStopsAgentHooksRunsAndPausesThem() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let agent = try harness.add(agentHook("Agent", .tabOpened))
        let script = try harness.add(instantHook("Script", .tabSelected))
        runner.behaviors[agent.id] = .hold
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { runner.invocations.count == 1 })
        registry.stopAgentHooks()
        #expect(await eventually { runner.cancelled.count == 1 })
        #expect(registry.hooks.map(\.state) == [.paused(.stopAllAgents), .active])
        harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        #expect(await eventually { runner.invocations(of: script.id).count == 1 })
        registry.resume(agent.id)
        #expect(registry.hooks[0].state == .active)
    }

    @Test func aDeletedPlaceLeavesEveryFilterAndPausesAHookLeftWithoutOne() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let both = try harness.add(instantHook("Both", .tabOpened, filter: BrowserEventFilter(scope: .places([.space(HookIDs.work), .space(HookIDs.home)]))))
        let home = try harness.add(instantHook("Home", .tabOpened, filter: BrowserEventFilter(scope: .places([.space(HookIDs.home)]))))
        harness.host.places[0].spaces.removeAll { $0.id == HookIDs.home }
        harness.host.placesDidChange?()
        #expect(registry.hooks[0].filter.scope == .places([.space(HookIDs.work)]))
        #expect(registry.hooks[0].state == .active)
        #expect(registry.hooks[1].filter.scope == .places([]))
        #expect(registry.hooks[1].state == .paused(.placeDeleted))
        registry.resume(home.id)
        #expect(registry.hooks[1].state == .paused(.placeDeleted))
        #expect(both.id == registry.hooks[0].id)
        let url = harness.folder.appendingPathComponent("hooks.json")
        #expect(await eventually {
            (try? AgentJSON.decode(Data(contentsOf: url))["settings"]?["hooks"]?.arrayValue?.last?["state"]) == ["paused": "placeDeleted"]
        })
    }

    @Test func aScriptChangedOutsideArchPausesItsHookUntilItMatchesAgain() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Edited", .tabOpened))
        try Data("changed".utf8).write(to: harness.store.scriptURL(of: hook))
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { registry.hooks[0].state == .paused(.scriptChanged) })
        #expect(runner.invocations.isEmpty)
        registry.resume(hook.id)
        #expect(registry.hooks[0].state == .paused(.scriptChanged))

        // At the next launch the hook stays paused.
        let next = RegistryHarness(folder: harness.folder, keys: harness.keys)
        let relaunched = try await next.start()
        #expect(relaunched.hooks[0].state == .paused(.scriptChanged))
        // Reviewing it in the editor writes the script again, after which it resumes.
        try relaunched.update(relaunched.hooks[0], script: Data("reviewed".utf8))
        relaunched.resume(hook.id)
        #expect(relaunched.hooks[0].state == .active)
    }

    @Test func theDailyCountSkipsRunsPastItUntilTheNextDay() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Daily", .tabOpened, runsPerDay: 2))
        func open() {
            let tab = harness.tab()
            harness.host.show(tab)
            harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        }
        for count in 1...3 {
            open()
            #expect(await eventually { harness.entries(of: hook.id).count == count })
        }
        #expect(harness.entries(of: hook.id).map(\.outcome) == [.completed, .completed, .skipped])
        #expect(harness.entries(of: hook.id).last?.reason == .dailyLimit)
        #expect(registry.dayCounts[hook.id]?.runs == 2)
        harness.clock.now += 24 * 60 * 60
        open()
        #expect(await eventually { harness.entries(of: hook.id).last?.outcome == .completed })
    }

    @Test func runsThatWaitedForASlotTogetherStayWithinTheDailyCount() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let opened = try harness.add(instantHook("Opened", .tabOpened))
        let selected = try harness.add(instantHook("Selected", .tabSelected))
        let daily = try harness.add(instantHook("Daily", .pageLoaded(loads: .every, includesRestoredTabs: false), runsPerDay: 1))
        runner.behaviors[opened.id] = .hold
        runner.behaviors[selected.id] = .hold
        // The other hooks' runs hold every slot.
        for index in 0..<2 {
            let tab = harness.tab("/held\(index)")
            harness.host.show(tab)
            harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
            harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        }
        #expect(await eventually { runner.heldCount == HookRegistry.maximumRunning })
        // Each load passes the daily count after its delay, before any of them has run, and waits for a slot.
        for index in 0..<3 {
            harness.load(harness.tab("/load\(index)"))
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(runner.invocations(of: daily.id).isEmpty)
        runner.releaseAll()
        #expect(await eventually { harness.entries(of: daily.id).count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(runner.invocations(of: daily.id).count == 1)
        #expect(registry.dayCounts[daily.id]?.runs == 1)
        let entries = harness.entries(of: daily.id)
        #expect(entries.filter { $0.outcome == .completed }.count == 1)
        #expect(entries.filter { $0.reason == .dailyLimit }.count == 1)
    }

    // MARK: The run log

    @Test func theRunLogKeepsNoContentAndKeepNothingKeepsNoEntry() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let kept = try harness.add(instantHook("Kept", .pageLoaded(loads: .every, includesRestoredTabs: false)))
        let nothing = try harness.add(instantHook("Nothing", .pageLoaded(loads: .every, includesRestoredTabs: false), record: .none))
        let tab = harness.tab("/account/settings?token=abc")
        runner.behaviors[kept.id] = .complete([.renamedTab(tab: tab.id, name: "Secret Name")])
        runner.behaviors[nothing.id] = .complete([.renamedTab(tab: tab.id, name: "Secret Name")])
        harness.load(tab)
        #expect(await eventually { registry.lastRuns[nothing.id] != nil })
        let entries = harness.entries(of: kept.id)
        #expect(entries.count == 1)
        #expect(entries.first?.actions == ["renameTab": 1])
        #expect(entries.first?.site == "example.org")
        #expect(entries.first?.event == .pageLoaded)
        #expect(entries.first?.persona == HookIDs.persona)
        #expect(harness.entries(of: nothing.id).isEmpty)
        // Keep Nothing keeps only the last run's time and outcome in memory.
        let last = try #require(registry.lastRuns[nothing.id]?.first)
        #expect(last.outcome == .completed && last.actions == nil && last.duration == nil)
        #expect(registry.lastRuns[kept.id]?.first?.actions == ["renameTab": 1])
        registry.log.saveNow()
        let file = try String(contentsOf: registry.log.fileURL, encoding: .utf8)
        for content in ["Secret", "account", "token", "abc", nothing.id.uuidString] {
            #expect(!file.contains(content))
        }
    }

    @Test func aRegistryWithoutHooksWritesNothing() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        harness.load(tab)
        harness.close(tab)
        harness.service.settings.providers.append(AIProviderConfiguration(name: "Added", kind: .http(AIHTTPConfiguration(format: .chatCompletions, baseURL: URL(string: "https://added.example.test/v1")!))))
        harness.host.places[0].spaces.removeAll { $0.id == HookIDs.home }
        harness.host.placesDidChange?()
        try? await Task.sleep(for: .milliseconds(100))
        // What the log does at quit.
        registry.log.saveNow()
        registry.log.clear()
        for name in [HookStore.fileName, "hooks-activity.json", HookStore.scriptsFolderName] {
            #expect(!FileManager.default.fileExists(atPath: harness.folder.appendingPathComponent(name).path))
        }
    }

    @Test func theRunLogKeepsItsLatestEntries() async throws {
        let url = harness.folder.appendingPathComponent("hooks-activity.json")
        defer { harness.cleanUp() }
        let log = HookRunLog(fileURL: url, now: Date.init, keptEntries: 10)
        let entries = (0..<15).map { _ in
            HookRunEntry(date: Date(), hook: UUID(), event: .tabOpened, subject: "open", site: nil, persona: HookIDs.persona, outcome: .completed)
        }
        entries.forEach(log.record)
        #expect(log.entries.map(\.id) == entries.suffix(10).map(\.id))
        log.saveNow()
        let reread = HookRunLog(fileURL: url, now: Date.init, keptEntries: 10)
        #expect(reread.entries.map(\.id) == log.entries.map(\.id))
        // Reading the file changes nothing, so it is not written again.
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try? await Task.sleep(for: .milliseconds(20))
        reread.saveNow()
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == written)
    }

    // MARK: Agent hooks

    @Test func anAgentHookHasItsFeatureAndGetsNoEventFromAnExcludedSite() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let agent = try harness.add(agentHook("Tidy", .tabOpened))
        let script = try harness.add(instantHook("Script", .tabOpened))
        let feature = try #require(harness.service.features.first { $0.id == .agentHook(agent.id) })
        #expect(feature.name == "Tidy")
        #expect(feature.trigger == .automatic)
        #expect(feature.routing == .perRequest)
        #expect(feature.requirements == [.agent])
        #expect(!harness.service.features.contains { $0.id == .agentHook(script.id) })

        harness.service.settings.excludedSites.append(AISitePattern("example.org"))
        let excluded = harness.tab()
        harness.host.show(excluded)
        harness.bus.post(.tabOpened(tab: excluded, openerTabID: nil))
        #expect(await eventually { runner.invocations(of: script.id).count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.invocations(of: agent.id).isEmpty)
        #expect(harness.entries(of: agent.id).isEmpty)
        let allowed = harness.tab(host: "example.com")
        harness.host.show(allowed)
        harness.bus.post(.tabOpened(tab: allowed, openerTabID: nil))
        #expect(await eventually { runner.invocations(of: agent.id).count == 1 })

        registry.remove(agent.id)
        #expect(!harness.service.features.contains { $0.id == .agentHook(agent.id) })
        #expect(!FileManager.default.fileExists(atPath: harness.store.scriptFolder(of: agent.id).path))
    }

    @Test func anAgentHookWithAnEmptyTierFailsWithItsSentenceButDoesNotPause() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(agentHook("Deep", .tabOpened, tier: .deep))
        for count in 1...3 {
            let tab = harness.tab()
            harness.host.show(tab)
            harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
            #expect(await eventually { harness.entries(of: hook.id).count == count })
        }
        #expect(runner.invocations.isEmpty)
        #expect(harness.entries(of: hook.id).allSatisfy { $0.outcome == .failed && $0.code == "notConfigured" })
        #expect(registry.lastRuns[hook.id]?.last?.message == "Assign a model to the Deep tier in Settings ▸ AI.")
        #expect(registry.hooks[0].state == .active)
    }

    @Test func knownProvidersAreTheOnesTheUserSetUpWhileArchRan() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Providers", .tabOpened))
        let url = harness.folder.appendingPathComponent("hooks.json")
        func recorded() -> [String] {
            ((try? AgentJSON.decode(Data(contentsOf: url))["settings"]?["knownProviders"]?.decode(as: [HookKnownProvider].self)) ?? []).map(\.id.rawValue)
        }
        // The first write records the providers `ai.json` holds.
        #expect(await eventually { recorded() == [harness.provider.id.rawValue] })
        let added = AIProviderConfiguration(name: "Added", kind: .http(AIHTTPConfiguration(format: .chatCompletions, baseURL: URL(string: "https://added.example.test/v1")!)), models: [])
        harness.service.settings.providers.append(added)
        #expect(await eventually { recorded() == [harness.provider.id.rawValue, added.id.rawValue] })
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { runner.invocations.count == 1 })
        #expect(runner.invocations[0].knownProviders == [harness.provider.id: "https://models.example.test/v1", added.id: "https://added.example.test/v1"])

        // A provider that is in `ai.json` at the next launch but that Arch did not see the user set up stays unknown.
        let next = RegistryHarness(folder: harness.folder, keys: harness.keys)
        let outside = AIProviderConfiguration(name: "Outside", kind: .http(AIHTTPConfiguration(format: .chatCompletions, baseURL: URL(string: "https://outside.example.test/v1")!)), models: [])
        next.service.settings.providers = [harness.provider, added, outside]
        let relaunched = try await next.start()
        relaunched.pause(hook.id)
        #expect(await eventually {
            (try? AgentJSON.decode(Data(contentsOf: url))["settings"]?["hooks"]?.arrayValue?.first?["state"]) == ["paused": "user"]
        })
        #expect(recorded() == [harness.provider.id.rawValue, added.id.rawValue])
    }

    // MARK: Run Hooks and tests

    @Test func runHooksOffKeepsEveryEventFromTheHooks() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Off", .tabSelected))
        runner.behaviors[hook.id] = .hold
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        #expect(await eventually { runner.invocations.count == 1 })
        registry.runsHooks = false
        #expect(await eventually { runner.cancelled.count == 1 })
        harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runner.invocations.count == 1)
        #expect(registry.hooks[0].state == .active)
        registry.runsHooks = true
        harness.bus.post(.tabSelected(tab: tab, windowID: UUID()))
        #expect(await eventually { runner.invocations.count == 2 })
    }

    @Test func aTestReportsWithoutApplyingAndTreatsTheTabAsClosedForACloseHook() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Close", .tabClosed(reasons: [])))
        let left = harness.tab("/left")
        let selected = harness.tab("/selected")
        [left, selected].forEach(harness.host.show)
        harness.host.names[selected.id] = "Selected"
        runner.behaviors[hook.id] = .complete([.renamedTab(tab: left.id, name: "Proposed")])
        let result = await registry.test(hook.id, onTab: selected.id, applying: false)
        guard case .finished(.completed(let actions, _)) = result else {
            Issue.record("The test did not complete: \(result)")
            return
        }
        #expect(actions == [.renamedTab(tab: left.id, name: "Proposed")])
        let invocation = try #require(runner.invocations.first)
        #expect(!invocation.appliesActions)
        #expect(invocation.closedTab == AgentRunClosedTab(name: "Selected", url: selected.url))
        #expect(invocation.tabs == [left.id])
        #expect(harness.host.tab(selected.id) != nil)
        #expect(registry.dayCounts[hook.id] == nil)
        #expect(harness.entries(of: hook.id).map(\.test) == [true])
        guard case .notRun = await registry.test(hook.id, onTab: UUID(), applying: false) else {
            Issue.record("A test on a tab that is gone ran.")
            return
        }
    }

    @Test func aTestRunsOnlyOnATabTheHooksFilterCovers() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Work", .tabClosed(reasons: []), filter: BrowserEventFilter(scope: .places([.space(HookIDs.work)]))))
        let agent = harness.tab("/agent", kind: .agent)
        let home = harness.tab("/home", space: HookIDs.home)
        let work = harness.tab("/work")
        [agent, home, work].forEach(harness.host.show)
        for tab in [agent, home] {
            guard case .notRun = await registry.test(hook.id, onTab: tab.id, applying: false) else {
                Issue.record("A test ran on a tab outside the hook's filter.")
                continue
            }
        }
        #expect(runner.invocations.isEmpty)
        guard case .finished = await registry.test(hook.id, onTab: work.id, applying: false) else {
            Issue.record("A test on a covered tab did not run.")
            return
        }
        #expect(runner.invocations.count == 1)
    }

    // MARK: Helpers

    /// A hook whose script runs an agent on a tier, as the editor writes it.
    private func agentHook(_ name: String, _ trigger: HookTrigger, tier: AIModelTier = .fast) -> Hook {
        let grant = AgentRunGrant(tools: ["rename_tab"], maximumRecord: .none, runsPerDay: 300, limits: AgentRunLimits(timeout: .seconds(20), rounds: 1, toolCalls: 2))
        let options = AgentRunOptions(prompt: "Name the tab.", model: .tier(tier), tools: ["rename_tab"], limits: AgentRunLimits(timeout: .seconds(20), rounds: 1, toolCalls: 2))
        return instantHook(name, trigger, grant: HookGrant(permissions: [.agent], agent: grant), agent: options)
    }
}
