// A plugin's AI (`docs/plugins.md`, AI hooks and plugins that AI writes): its own feature, `plugin.<id>`, which the manager registers while the plugin is enabled with `ai`; the client through which its requests go out under that feature; and its hooks, the bus event listeners of a plugin with `ai` and bus events, which run one at a time as steps of the shared hook scheduler under that feature (`docs/hooks.md`, Plugins).
import AI
import Foundation

extension AIFeature {
    /// The plugin's own feature, named after it, whose requests carry text and the data kinds that come with the plugin's `ai` (`InstalledPlugin.aiDataKinds`). It is automatic while the plugin's events run as hooks, so that neither its hooks nor its other requests run before the user gives it a model of its own, and they count toward the daily limit for automatic requests. Otherwise the user starts its requests, which use the default route until the feature has models of its own.
    static func plugin(_ installed: InstalledPlugin) -> AIFeature {
        AIFeature(id: .plugin(installed.id.rawValue), name: installed.manifest.name,
                  summary: installed.runsHooks ? "Sends the text this plugin writes, as you use it and as browser events reach it." : "Sends the text this plugin writes, as you use it.",
                  trigger: installed.runsHooks ? .automatic : .user, data: AIDataScope(kinds: installed.aiDataKinds))
    }
}

extension InstalledPlugin {
    /// Whether the plugin's bus event listeners run as hooks on the shared hook scheduler under its AI feature: its grant has `ai`, and its manifest lists bus kinds in `events`. Its `settingChanged` listeners run outside the scheduler, and other plugins' listeners get events as they arrive.
    public var runsHooks: Bool {
        grant.permissions.contains(.ai) && !manifest.events.isEmpty
    }

    /// The data kinds beyond text that the plugin's AI requests may carry: those its manifest lists for `ai` while its grant has `ai`.
    public var aiDataKinds: Set<AIDataKind> {
        grant.permissions.contains(.ai) ? manifest.aiDataKinds : []
    }
}

/// A context whose AI requests and renames can stay out of the plugin's hook steps. A script plugin's panel makes them here, since the user makes them there, while a running step's listener has the plugin's other calls.
@MainActor
protocol PluginPanelContext: PluginContext {
    /// As `ai()`, with a client whose requests belong to no hook step.
    func panelAI() throws -> any AIClient
    /// As `renameTab(_:to:)`, for the document the tab shows when the call arrives, whatever hook step runs.
    func panelRenameTab(_ id: PluginTab.ID, to name: String?) throws -> Bool
}

/// One run of a plugin's listener as a step of the shared hook scheduler. The scheduler counts the errors of the AI requests that belong to the step toward its pause, and stops them with the step.
@MainActor
final class PluginHookStep {
    /// The tab of the step's event, and for a page, address, or title event the address of its document: the step's renames of that tab apply to that document only.
    let tab: UUID?
    let document: URL?
    let requestDidEnd: @MainActor @Sendable ((any Error)?) -> Void
    /// Set once the scheduler stops the step. Its requests have ended by then, and it starts no request and renames no tab after that.
    private(set) var isStopped = false

    init(tab: UUID?, document: URL?, requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) {
        self.tab = tab
        self.document = document
        self.requestDidEnd = requestDidEnd
    }

    func stop() {
        isStopped = true
    }
}

/// The AI requests of one plugin instance. Each `PluginContext.ai()` call gets a client whose requests go out under the plugin's feature and that feature's route, without a route or a model of their own, and belong to the hook step that runs when the call is made, if any. The instance's stop ends every request.
@MainActor
final class PluginAIRequests {
    private let service: AIService
    private let feature: AIFeatureID
    /// The data kinds beyond text that the plugin's requests may carry. Plugins with one identifier in several Personas share the feature, whose scope holds the kinds of each, so each instance holds its requests to its own.
    private let dataKinds: Set<AIDataKind>
    /// The hook step whose listener runs now.
    var step: PluginHookStep?
    private var hasEnded = false
    /// The requests that have not ended, each with the step it belongs to.
    private var requests: [UUID: (continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation, step: PluginHookStep?)] = [:]

    init(service: AIService, feature: AIFeatureID, dataKinds: Set<AIDataKind> = []) {
        self.service = service
        self.feature = feature
        self.dataKinds = dataKinds
    }

    /// A client whose requests belong to the step that runs now, if any, or with `inStep` false to no step.
    func client(inStep: Bool = true) -> PluginAIClient {
        PluginAIClient(requests: self, step: inStep ? step : nil)
    }

    /// Sends the request under the plugin's feature, passes its events on, and reports its end to its step. A stopped step's request never goes out, nor does one with a part of a kind that the plugin does not list, which ends with the error the service gives a part of a kind its feature does not declare. Neither reaches the service, so neither has an entry in its activity, which Settings ▸ AI ▸ Features reads a plugin's last error from.
    fileprivate func forward(_ request: AIRequest, step: PluginHookStep?, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async {
        guard !hasEnded else { return continuation.finish(throwing: PluginError.stopped) }
        guard step?.isStopped != true else { return continuation.finish(throwing: AIError.cancelled) }
        if let kind = Self.dataKinds(of: request.messages.flatMap(\.parts)).first(where: { !dataKinds.contains($0) }) {
            return continuation.finish(throwing: AIError.blockedByPolicy(.dataNotDeclared(kind)))
        }
        var request = request
        request.feature = feature
        request.route = nil
        request.pinnedModel = nil
        let id = UUID()
        requests[id] = (continuation, step)
        defer { requests[id] = nil }
        do {
            for try await event in service.stream(request) {
                continuation.yield(event)
            }
            // A stream read by a canceled task ends without an error. A stopped request reports nothing, as a hook center hook's does.
            guard !Task.isCancelled else { return continuation.finish(throwing: AIError.cancelled) }
            step?.requestDidEnd(nil)
            continuation.finish()
        } catch {
            if !Task.isCancelled { step?.requestDidEnd(error) }
            continuation.finish(throwing: error)
        }
    }

    /// The data kinds of the parts beyond text, those of tool results' parts among them.
    private static func dataKinds(of parts: [AIPart]) -> [AIDataKind] {
        parts.flatMap { part -> [AIDataKind] in
            switch part {
            case .text, .toolCall: return []
            case .page: return [.page]
            case .selection: return [.selection]
            case .file: return [.file]
            case .download: return [.download]
            case let .toolResult(result): return dataKinds(of: result.parts)
            }
        }
    }

    /// Ends every request with `PluginError.stopped` and refuses later ones, as the instance stops.
    func end() {
        hasEnded = true
        for request in requests.values {
            request.continuation.finish(throwing: PluginError.stopped)
        }
    }

    /// Stops the step and ends its requests with `AIError.cancelled`, as the scheduler stops it.
    func stop(_ step: PluginHookStep) {
        step.stop()
        for request in requests.values where request.step === step {
            request.continuation.finish(throwing: AIError.cancelled)
        }
    }
}

/// The AI interface as one `PluginContext.ai()` call gives it: its requests go through the instance's `PluginAIRequests` and belong to the hook step that ran at that call.
struct PluginAIClient: AIClient {
    let requests: PluginAIRequests
    let step: PluginHookStep?

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let forwarding = Task { @MainActor in await requests.forward(request, step: step, to: continuation) }
            continuation.onTermination = { _ in forwarding.cancel() }
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
