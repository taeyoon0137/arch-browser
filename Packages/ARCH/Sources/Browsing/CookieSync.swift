// Keeps the engines' cookie stores in step so that a site stays signed in whichever engine shows it. Copies add and update cookies; a cookie that one engine deletes stays in the other until it expires or the site replaces it. Local storage and IndexedDB stay with each engine.
import ARCHEngine
import Foundation

final class CookieSync {
    /// The running engines, supplied by the session.
    var runtimes: () -> [EngineRuntime] = { [] }
    private var pendingCopies: [EngineKind: DispatchWorkItem] = [:]
    /// Engines the sync is writing to. Their change reports during a write are the sync's own.
    private var writingEngines: Set<EngineKind> = []

    /// Copies every cookie of `source` into `target`, then calls `completion` once they are stored.
    func copy(from source: EngineRuntime, to target: EngineRuntime, completion: @escaping () -> Void) {
        source.browser.allCookies { [weak self] cookies in
            guard let self else { return completion() }
            self.writingEngines.insert(target.kind)
            target.browser.setCookies(cookies) { [weak self] in
                // The store reports its own writes shortly after they finish.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.writingEngines.remove(target.kind) }
                completion()
            }
        }
    }

    /// Copies the cookies of `source` to every other running engine once its changes settle.
    func scheduleCopy(from source: EngineKind) {
        guard !writingEngines.contains(source), runtimes().count > 1 else { return }
        pendingCopies[source]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let from = self.runtimes().first(where: { $0.kind == source }) else { return }
            for target in self.runtimes() where target.kind != source {
                self.copy(from: from, to: target) {}
            }
        }
        pendingCopies[source] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
