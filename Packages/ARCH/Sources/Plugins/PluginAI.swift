// A plugin's AI (`docs/plugins.md`, AI hooks and plugins that AI writes): its own feature, `plugin.<id>`, which the manager registers while the plugin is enabled with `ai`; the client through which its requests go out under that feature; and its hooks, the event listeners of a plugin with `ai` and events, which run one at a time as steps of the shared hook scheduler under that feature (`docs/hooks.md`, Plugins).
import AI
import Foundation

extension AIFeature {
    /// The plugin's own feature, named after it, whose requests carry text only. It is automatic while the plugin's events run as hooks, so that neither its hooks nor its other requests run before the user gives it a model of its own, and they count toward the daily limit for automatic requests. Otherwise the user starts its requests, which use the default route until the feature has models of its own.
    static func plugin(_ installed: InstalledPlugin) -> AIFeature {
        AIFeature(id: .plugin(installed.id.rawValue), name: installed.manifest.name,
                  summary: installed.runsHooks ? "Sends the text this plugin writes, as you use it and as browser events reach it." : "Sends the text this plugin writes, as you use it.",
                  trigger: installed.runsHooks ? .automatic : .user, data: .textOnly)
    }
}

extension InstalledPlugin {
    /// Whether the plugin's event listeners run as hooks on the shared hook scheduler under its AI feature: its grant has `ai`, and its manifest lists events. Other plugins' listeners get events as they arrive.
    public var runsHooks: Bool {
        grant.permissions.contains(.ai) && !manifest.events.isEmpty
    }
}

/// One run of a plugin's listener as a step of the shared hook scheduler. The scheduler counts the errors of the AI requests that the listener starts meanwhile toward its pause, and stops them with the step.
@MainActor
final class PluginHookStep {
    let requestDidEnd: @MainActor @Sendable ((any Error)?) -> Void

    init(requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) {
        self.requestDidEnd = requestDidEnd
    }
}

/// The AI interface as one plugin instance reaches it (`PluginContext.ai()`). Each request goes out under the plugin's feature and that feature's route, without a route or a model of its own. A request belongs to the hook step that runs when it starts, if any. The instance's stop ends every request.
@MainActor
final class PluginAIClient: AIClient {
    private let service: AIService
    private let feature: AIFeatureID
    /// The hook step whose listener runs now.
    var step: PluginHookStep?
    private var hasEnded = false
    /// The requests that have not ended, each with the step it belongs to.
    private var requests: [UUID: (continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation, step: PluginHookStep?)] = [:]

    init(service: AIService, feature: AIFeatureID) {
        self.service = service
        self.feature = feature
    }

    nonisolated func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let forwarding = Task { @MainActor in await self.forward(request, to: continuation) }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }

    /// Sends the request under the plugin's feature, passes its events on, and reports its end to its step.
    private func forward(_ request: AIRequest, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async {
        guard !hasEnded else { return continuation.finish(throwing: PluginError.stopped) }
        var request = request
        request.feature = feature
        request.route = nil
        request.pinnedModel = nil
        let id = UUID()
        let step = step
        requests[id] = (continuation, step)
        defer { requests[id] = nil }
        do {
            for try await event in service.stream(request) {
                continuation.yield(event)
            }
            // A stream read by a canceled task ends without an error.
            if Task.isCancelled { throw AIError.cancelled }
            step?.requestDidEnd(nil)
            continuation.finish()
        } catch {
            step?.requestDidEnd(error)
            continuation.finish(throwing: error)
        }
    }

    /// Ends every request with `PluginError.stopped` and refuses later ones, as the instance stops.
    func end() {
        hasEnded = true
        for request in requests.values {
            request.continuation.finish(throwing: PluginError.stopped)
        }
    }

    /// Ends the requests that belong to the step with `AIError.cancelled`, as the scheduler stops it.
    func stop(_ step: PluginHookStep) {
        for request in requests.values where request.step === step {
            request.continuation.finish(throwing: AIError.cancelled)
        }
    }
}

/// Runs one plugin's hook steps one at a time, so that the AI requests its listener starts belong to the step that runs. A step canceled while it waits leaves the queue.
@MainActor
final class PluginHookQueue {
    private var isBusy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    /// Runs `body` once the steps before it have ended. Throws `CancellationError` for a step canceled while it waits.
    func run(_ body: () async throws -> Void) async throws {
        if isBusy {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
            } onCancel: {
                Task { @MainActor in self.leave(id) }
            }
        } else {
            isBusy = true
        }
        defer { handOn() }
        try await body()
    }

    /// The next waiting step runs, or the queue is free.
    private func handOn() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    private func leave(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
