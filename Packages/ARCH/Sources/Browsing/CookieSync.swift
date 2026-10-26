// Keeps the cookie stores of one Persona's engines in step so that a site stays signed in, and signed out, whichever engine shows it. A copy carries what the source changed since the two stores last agreed: the cookies it added or changed, and the deletion of those it removed. A cookie that only the target changed stays, and the copy the other way carries it. When both changed one cookie, the source's version wins, but a deletion leaves a cookie the target changed, which may be a new sign-in after the old cookie expired. The record of what the stores agreed on lives in memory, so the first copy between two engines in a launch has none: it writes the source's cookies that the target lacks or holds with other contents and deletes nothing, and a cookie that one engine deleted while the other engine was not running can come back from the other. Local storage and IndexedDB stay with each engine.
import ARCHEngine
import Foundation

final class CookieSync {
    /// A cookie's identity in a store: its name, domain, and path.
    struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: EngineCookie) {
            name = cookie.name
            domain = cookie.domain.lowercased()
            path = cookie.path
        }
    }

    /// The running engines, supplied by the session.
    var runtimes: () -> [EngineRuntime] = { [] }
    private var pendingCopies: [EngineKind: DispatchWorkItem] = [:]
    /// For each pair of engines, the cookies both stores held with the same contents after the last copy between them.
    private var agreed: [Set<EngineKind>: [CookieKey: EngineCookie]] = [:]
    /// Set while a copy or a removal runs. Work runs one piece at a time, so that no copy writes what it read before another copy or a removal changed the stores.
    private var isRunning = false
    /// Work waiting for its turn, oldest first. Each piece calls the closure it receives once it finishes.
    private var queue: [(@escaping () -> Void) -> Void] = []

    /// Copies to `target` what `source` changed since the two stores last agreed (`changes(from:to:agreed:)`), then calls `completion` once the target has stored it.
    func copy(from source: EngineRuntime, to target: EngineRuntime, completion: @escaping () -> Void) {
        let pair: Set = [source.kind, target.kind]
        enqueue { [weak self] finish in
            source.browser.allCookies { sourceCookies in
                target.browser.allCookies { targetCookies in
                    guard let self else { return completion() }
                    let before = self.agreed[pair] ?? [:]
                    let changes = Self.changes(from: sourceCookies, to: targetCookies, agreed: before)
                    Self.apply(changes, to: target.browser, holding: targetCookies) { [weak self] stored in
                        self?.agreed[pair] = Self.agreement(between: sourceCookies, and: stored, before: before)
                        completion()
                        finish()
                    }
                }
            }
        }
    }

    /// What a copy from `source` to `target` writes and deletes in the target, given the cookies both held alike after their last copy (`agreed`, empty before the first): each cookie of the source that differs from its agreed version and from the target's, and each agreed cookie that the source no longer holds and the target still holds as agreed. A cookie the target holds with the same contents keeps the target's `SameSite` policy, which the source store may not have kept: WebKit reads a Chromium cookie without a policy as `SameSite=None`, and writing it back would widen it.
    static func changes(from source: [EngineCookie], to target: [EngineCookie],
                        agreed: [CookieKey: EngineCookie]) -> (write: [EngineCookie], remove: Set<CookieKey>) {
        let held = Dictionary(grouping: target, by: CookieKey.init)
        let current = Set(source.map(CookieKey.init))
        let write = source.filter { cookie in
            let key = CookieKey(cookie)
            return !same(cookie, agreed[key]) && !(held[key] ?? []).contains { $0.hasSameContents(as: cookie) }
        }
        let remove = Set(agreed.filter { key, cookie in
            !current.contains(key) && (held[key] ?? []).contains { $0.hasSameContents(as: cookie) }
        }.keys)
        return (write, remove)
    }

    /// The cookies both stores hold alike after a copy, where `stored` is what the target holds after it. A cookie they hold differently keeps the version they agreed on `before`, so that a change the target made, or a write it refused, is not taken for agreement.
    static func agreement(between source: [EngineCookie], and stored: [EngineCookie],
                          before: [CookieKey: EngineCookie]) -> [CookieKey: EngineCookie] {
        let current = byKey(source)
        let held = byKey(stored)
        var agreed = before
        for key in Set(current.keys).union(held.keys).union(before.keys) where same(current[key], held[key]) {
            agreed[key] = current[key]
        }
        return agreed
    }

    /// Writes and deletes the cookies in `browser`, then passes what it holds afterwards: `held` when there is nothing to change.
    private static func apply(_ changes: (write: [EngineCookie], remove: Set<CookieKey>), to browser: any EngineBrowser, holding held: [EngineCookie],
                              completion: @escaping ([EngineCookie]) -> Void) {
        guard !changes.write.isEmpty || !changes.remove.isEmpty else { return completion(held) }
        let readBack = { browser.allCookies(completion: completion) }
        browser.setCookies(changes.write) {
            guard !changes.remove.isEmpty else { return readBack() }
            browser.removeCookies(where: { changes.remove.contains(CookieKey($0)) }, completion: readBack)
        }
    }

    private static func byKey(_ cookies: [EngineCookie]) -> [CookieKey: EngineCookie] {
        Dictionary(cookies.map { (CookieKey($0), $0) }) { first, _ in first }
    }

    /// Whether two versions of a cookie, either of which may be missing, have the same contents.
    private static func same(_ cookie: EngineCookie?, _ other: EngineCookie?) -> Bool {
        switch (cookie, other) {
        case (nil, nil): return true
        case let (cookie?, other?): return cookie.hasSameContents(as: other)
        default: return false
        }
    }

    /// Copies the cookies of `source` to every other running engine once its changes settle. A report of the copy's own writes finds nothing to copy back.
    func scheduleCopy(from source: EngineKind) {
        guard runtimes().count > 1 else { return }
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

    /// Deletes the cookies `shouldRemove` accepts from every running engine and from the record of what the stores agreed on, then calls `completion`. It runs alone: a copy already running finishes first, and copies asked for meanwhile wait, so that no copy writes back a cookie it read before the deletion.
    func removeCookies(where shouldRemove: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) {
        enqueue { [weak self] finish in
            guard let self else { return completion() }
            self.agreed = self.agreed.mapValues { $0.filter { !shouldRemove($0.value) } }
            let group = DispatchGroup()
            for runtime in self.runtimes() {
                group.enter()
                runtime.browser.removeCookies(where: shouldRemove) { group.leave() }
            }
            group.notify(queue: .main) {
                completion()
                finish()
            }
        }
    }

    private func enqueue(_ work: @escaping (@escaping () -> Void) -> Void) {
        queue.append(work)
        startNext()
    }

    /// Starts the oldest waiting work once nothing runs.
    private func startNext() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        queue.removeFirst()({ [weak self] in
            self?.isRunning = false
            self?.startNext()
        })
    }
}
