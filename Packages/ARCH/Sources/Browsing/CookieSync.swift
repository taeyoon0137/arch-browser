// Keeps the engines' cookie stores in step so that a site stays signed in whichever engine shows it. Copies add and update cookies; a cookie that one engine deletes stays in the other until it expires or the site replaces it, unless `removeCookies` deletes it from every engine at once. Local storage and IndexedDB stay with each engine.
import ARCHEngine
import Foundation

final class CookieSync {
    /// The running engines, supplied by the session.
    var runtimes: () -> [EngineRuntime] = { [] }
    private var pendingCopies: [EngineKind: DispatchWorkItem] = [:]
    /// Engines the sync is writing to. Their change reports during a write are the sync's own.
    private var writingEngines: Set<EngineKind> = []
    /// Copies that started and have not finished. A removal starts only once there are none.
    private var runningCopies = 0
    /// Set while a removal runs. Nothing else starts until it finishes.
    private var isRemoving = false
    /// Work waiting for its turn, oldest first: removals, and the copies asked for after them.
    private var queue: [(isRemoval: Bool, start: () -> Void)] = []

    /// Copies the cookies of `source` that `target` lacks or holds with other contents into `target`, then calls `completion` once they are stored.
    func copy(from source: EngineRuntime, to target: EngineRuntime, completion: @escaping () -> Void) {
        enqueue(isRemoval: false) { [weak self] in
            guard let self else { return completion() }
            self.runningCopies += 1
            source.browser.allCookies { [weak self] cookies in
                target.browser.allCookies { [weak self] held in
                    guard let self else { return completion() }
                    self.writingEngines.insert(target.kind)
                    target.browser.setCookies(Self.cookies(cookies, changedFrom: held)) { [weak self] in
                        // The store reports its own writes shortly after they finish.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.writingEngines.remove(target.kind) }
                        completion()
                        self?.runningCopies -= 1
                        self?.startQueued()
                    }
                }
            }
        }
    }

    /// The cookies of `source` that `target` lacks or holds with other contents. A cookie the target holds already keeps the target's `SameSite` policy, which the source store may not have kept: WebKit reads a Chromium cookie without a policy as `SameSite=None`, and writing it back would widen it.
    static func cookies(_ source: [EngineCookie], changedFrom target: [EngineCookie]) -> [EngineCookie] {
        let held = Dictionary(grouping: target, by: \.name)
        return source.filter { cookie in !(held[cookie.name] ?? []).contains { $0.hasSameContents(as: cookie) } }
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

    /// Deletes the cookies `shouldRemove` accepts from every running engine, then calls `completion`. It runs alone: copies already running finish first, and copies asked for meanwhile wait, so that no copy writes back a cookie it read before the deletion.
    func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) {
        enqueue(isRemoval: true) { [weak self] in
            guard let self else { return completion() }
            let group = DispatchGroup()
            for runtime in self.runtimes() {
                group.enter()
                runtime.browser.removeCookies(where: shouldRemove) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                self?.isRemoving = false
                completion()
                self?.startQueued()
            }
        }
    }

    private func enqueue(isRemoval: Bool, _ start: @escaping () -> Void) {
        queue.append((isRemoval, start))
        startQueued()
    }

    /// Starts waiting work in order: copies alongside each other, and a removal alone once the copies before it finish.
    private func startQueued() {
        while let next = queue.first, !isRemoving, !next.isRemoval || runningCopies == 0 {
            queue.removeFirst()
            isRemoving = next.isRemoval
            next.start()
        }
    }
}
