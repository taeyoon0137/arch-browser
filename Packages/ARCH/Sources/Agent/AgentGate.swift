// A gate that tool calls wait at: closed until something opens it, with each wait bounded. An in-app session holds its calls at one until the model's first output (`ready`) and at another while the user has taken the session over; closing a gate for good, as when the session ends, sends every waiting call on with no.
import Foundation

/// A gate that tool calls wait at, which `AgentSession` and `AgentHookCLIRun` open and close.
@MainActor final class AgentGate {
    private(set) var isOpen: Bool
    /// Set once the gate can never open again.
    private(set) var isShut = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(isOpen: Bool) {
        self.isOpen = isOpen
    }

    func open() {
        guard !isShut else { return }
        isOpen = true
        resumeAll(true)
    }

    func close() {
        guard !isShut else { return }
        isOpen = false
    }

    /// Every waiting call goes on with no; the gate keeps its state.
    func release() {
        resumeAll(false)
    }

    /// Closes the gate for good; every waiting call goes on with no.
    func shut() {
        isShut = true
        isOpen = false
        resumeAll(false)
    }

    /// True once the gate is open, false when it is shut or `timeout` passes first.
    func wait(timeout: Duration) async -> Bool {
        if Task.isCancelled { return false }
        if isOpen { return true }
        if isShut { return false }
        let id = UUID()
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.resume(id, false)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id, false) }
        }
    }

    private func resume(_ id: UUID, _ value: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }

    private func resumeAll(_ value: Bool) {
        let waiting = waiters
        waiters = [:]
        waiting.values.forEach { $0.resume(returning: value) }
    }
}
