// The hook registry and plugin hooks in one chain (`docs/hooks.md`, Plugins): a change that a plugin's call caused, such as a plugin hook's rename, names the plugin's owner when the registry posts its steps, so they join the running plugin step's chain instead of stopping it.
import AI
import Events
import Foundation
import Testing
@testable import Hooks

/// How the plugin's step ended.
@MainActor
private final class StepEnd {
    var outcome: AIHookStepOutcome?
}

@MainActor @Suite struct PluginCauseTests {
    private let harness = RegistryHarness()

    @Test func aPluginStepsOwnEffectJoinsItsChainWithoutStoppingIt() async throws {
        defer { harness.cleanUp() }
        try await harness.start()
        let hook = try harness.add(instantHook("Titles", .titleChanged(sources: [.page, .suggested])))
        let tab = harness.tab()
        harness.host.show(tab)
        let plugin = "org.example.sample"
        let end = StepEnd()
        let bus = harness.bus
        // The plugin's step for the page's title change renames the tab, whose title change the registry's hook answers.
        harness.service.hooks.scheduler.post([AIHookStep(owner: AIFeatureID.plugin(plugin).rawValue, order: 200, feature: nil,
                                                         run: { _ in
                                                             await MainActor.run { bus.post(.titleChanged(tab: tab, source: .suggested), cause: BrowserEventCause(origin: .plugin(id: plugin))) }
                                                             try await Task.sleep(for: .milliseconds(300))
                                                         },
                                                         didEnd: { end.outcome = $0 })],
                                             kind: BrowserEventKind.titleChanged.rawValue, subject: tab.id, event: UUID(), document: tab.url)
        #expect(await eventually { harness.javaScript.invocations(of: hook.id).count == 1 })
        guard case .finished? = end.outcome else {
            Issue.record("The plugin's step ended with \(String(describing: end.outcome))")
            return
        }
    }
}
