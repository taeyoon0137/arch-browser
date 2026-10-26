// Keeps the cookie stores of one Persona's engines in step so that a site stays signed in, and signed out, whichever engine shows it. A copy carries what the source changed since the two stores last agreed: the cookies it added or changed, and the deletion of those it removed. A cookie that only the target changed stays, and the copy the other way carries it. When both changed one cookie, the source's version wins, but a deletion leaves a cookie the target changed, which may be a new sign-in after the old cookie expired. The record of what the stores agreed on outlasts the launch in a file per Persona, so the first copy of a launch also carries what one engine changed while the other was not running. The file keeps no cookie values. Local storage and IndexedDB stay with each engine.
import ARCHEngine
import CryptoKit
import Foundation

final class CookieSync {
    /// A cookie's identity in a store: its name, domain, and path.
    struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: EngineCookie) {
            self.init(name: cookie.name, domain: cookie.domain, path: cookie.path)
        }

        init(name: String, domain: String, path: String) {
            self.name = name
            self.domain = domain.lowercased()
            self.path = path
        }
    }

    /// What the record keeps of an agreed cookie in place of its value: a SHA-256 digest of its value, its flags, and its expiry to the whole second, as WebKit keeps it. Both engines' versions of one cookie, which differ at most in their `SameSite` policy and in the fraction of a second of their expiry (`EngineCookie.hasSameContents(as:)`), have the same digest.
    struct Digest: Hashable {
        let sha256: Data
        /// Whether the cookie has an expiry. The file leaves out cookies without one: both engines drop them at quit, and a later launch would take such a cookie that a site sets again with the same value in one engine for one that both stores hold.
        let hasExpiry: Bool

        init(_ cookie: EngineCookie) {
            let expiry = cookie.expires.map { "\($0.timeIntervalSince1970.rounded(.down))" } ?? "none"
            // The value's length comes first, so that no value can run into the fields after it.
            let contents = "\(cookie.value.utf8.count):\(cookie.value) \(cookie.isSecure) \(cookie.isHTTPOnly) \(expiry)"
            sha256 = Data(SHA256.hash(data: Data(contents.utf8)))
            hasExpiry = cookie.expires != nil
        }

        /// A digest the file kept, which lists only cookies with an expiry.
        init(saved sha256: Data) {
            self.sha256 = sha256
            hasExpiry = true
        }
    }

    /// The cookies two stores held with the same contents after the last copy between them.
    typealias Record = [CookieKey: Digest]

    /// The running engines, supplied by the session.
    var runtimes: () -> [EngineRuntime] = { [] }
    private var pendingCopies: [EngineKind: DispatchWorkItem] = [:]
    /// The file that keeps the records across launches, or nil to keep them in memory only.
    private let recordURL: URL?
    /// For each pair of engines, the record of what their stores agreed on, read from the file at the first copy of a launch (`loadRecords()`).
    private var agreed: [Set<EngineKind>: Record] = [:]
    /// Whether `agreed` holds what the file kept. Until then nothing writes the file, so that a removal in a launch in which only one engine ran leaves the record for the next.
    private var isLoaded = false
    /// The pairs whose record came from the file and that no copy of this launch has checked yet (`record(of:holding:)`).
    private var unchecked: Set<Set<EngineKind>> = []
    /// Set while a copy or a removal runs. Work runs one piece at a time, so that no copy writes what it read before another copy or a removal changed the stores.
    private var isRunning = false
    /// Work waiting for its turn, oldest first. Each piece calls the closure it receives once it finishes.
    private var queue: [(@escaping () -> Void) -> Void] = []
    /// Writes the records' files in the order they changed, away from the main thread.
    private static let writeQueue = DispatchQueue(label: "xyz.taeyoon.arch.cookie-sync", qos: .utility)

    /// Keeps the records in `recordURL`, which `recordURL(ofPersona:in:)` names for a Persona, or in memory only when it is nil.
    init(recordURL: URL? = nil) {
        self.recordURL = recordURL
    }

    /// Copies to `target` what `source` changed since the two stores last agreed (`changes(from:to:agreed:)`), then calls `completion` once the target has stored it.
    func copy(from source: EngineRuntime, to target: EngineRuntime, completion: @escaping () -> Void) {
        let pair: Set = [source.kind, target.kind]
        enqueue { [weak self] finish in
            source.browser.allCookies { sourceCookies in
                target.browser.allCookies { targetCookies in
                    guard let self else { return completion() }
                    let before = self.record(of: pair, holding: [sourceCookies, targetCookies])
                    let changes = Self.changes(from: sourceCookies, to: targetCookies, agreed: before)
                    Self.apply(changes, to: target.browser, holding: targetCookies) { [weak self] stored in
                        self?.update(pair, to: Self.agreement(between: sourceCookies, and: stored, before: before))
                        completion()
                        finish()
                    }
                }
            }
        }
    }

    /// What a copy from `source` to `target` writes and deletes in the target, given the cookies both held alike after their last copy (`agreed`, empty without a record): each cookie of the source that differs from its agreed version and from the target's, and each agreed cookie that the source no longer holds and the target still holds as agreed. A cookie the target holds with the same contents keeps the target's `SameSite` policy, which the source store may not have kept: WebKit reads a Chromium cookie without a policy as `SameSite=None`, and writing it back would widen it.
    static func changes(from source: [EngineCookie], to target: [EngineCookie],
                        agreed: Record) -> (write: [EngineCookie], remove: Set<CookieKey>) {
        let held = Dictionary(grouping: target, by: CookieKey.init)
        let current = Set(source.map(CookieKey.init))
        let write = source.filter { cookie in
            let key = CookieKey(cookie)
            return agreed[key] != Digest(cookie) && !(held[key] ?? []).contains { $0.hasSameContents(as: cookie) }
        }
        let remove = Set(agreed.filter { key, digest in
            !current.contains(key) && (held[key] ?? []).contains { Digest($0) == digest }
        }.keys)
        return (write, remove)
    }

    /// The cookies both stores hold alike after a copy, where `stored` is what the target holds after it. A cookie they hold differently keeps the version they agreed on `before`, so that a change the target made, or a write it refused, is not taken for agreement.
    static func agreement(between source: [EngineCookie], and stored: [EngineCookie], before: Record) -> Record {
        let current = byKey(source)
        let held = byKey(stored)
        var agreed = before
        for key in Set(current.keys).union(held.keys).union(before.keys) where same(current[key], held[key]) {
            agreed[key] = current[key].map(Digest.init)
        }
        return agreed
    }

    /// Whether each store still holds, by name, domain, and path, at least half of the cookies a record lists that any of the stores holds. A cookie none holds any longer, as after it expired, counts against no store.
    static func stores(_ stores: [[EngineCookie]], holdMostOf record: Record) -> Bool {
        let held = stores.map { Set($0.map(CookieKey.init)) }
        let kept = record.keys.filter { key in held.contains { $0.contains(key) } }
        return held.allSatisfy { keys in kept.filter(keys.contains).count * 2 >= kept.count }
    }

    /// The pair's record for a copy between stores that hold `stores`. The first copy of a launch reads the file. A record from the file counts only while each store still holds most of its cookies (`stores(_:holdMostOf:)`): a store that lost more was emptied or could not be read, as when its profile was deleted or Chromium could not decrypt its cookies, and the copy would carry its loss to the other store as deletions. Without a record, a copy writes the cookies the target lacks or holds with other contents and deletes none.
    private func record(of pair: Set<EngineKind>, holding stores: [[EngineCookie]]) -> Record {
        loadRecords()
        let record = agreed[pair] ?? [:]
        guard unchecked.remove(pair) != nil else { return record }
        return Self.stores(stores, holdMostOf: record) ? record : [:]
    }

    /// Keeps the pair's record after a copy, and writes the file when the record changed.
    private func update(_ pair: Set<EngineKind>, to record: Record) {
        guard agreed[pair] != record else { return }
        agreed[pair] = record
        saveRecords()
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
            var removed: Set<CookieKey> = []
            let group = DispatchGroup()
            for runtime in self.runtimes() {
                group.enter()
                runtime.browser.allCookies { cookies in
                    removed.formUnion(cookies.filter(shouldRemove).map(CookieKey.init))
                    runtime.browser.removeCookies(where: shouldRemove) { group.leave() }
                }
            }
            group.notify(queue: .main) { [weak self] in
                self?.forget(removed)
                completion()
                finish()
            }
        }
    }

    /// Drops the cookies from every record.
    private func forget(_ keys: Set<CookieKey>) {
        guard !keys.isEmpty, isLoaded else { return }
        agreed = agreed.mapValues { $0.filter { !keys.contains($0.key) } }
        saveRecords()
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

    // MARK: Record file

    /// The file's layout: for each pair of engines, the agreed cookies that have an expiry, each with its name, domain, path, and digest. A file of another version, or one that does not decode, counts as none.
    private struct RecordFile: Codable {
        static let currentVersion = 1

        struct Pair: Codable {
            var engines: [EngineKind]
            var cookies: [Cookie]
        }

        struct Cookie: Codable {
            var name: String
            var domain: String
            var path: String
            var digest: Data
        }

        var version = currentVersion
        var pairs: [Pair]
    }

    /// `CookieSync/<persona id>.json` in `directory`, the app's Application Support folder.
    static func recordURL(ofPersona id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("CookieSync", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    /// Deletes the Persona's record file, as the launch after the Persona's deletion does. Returns whether no file is left.
    static func removeRecord(ofPersona id: UUID, in directory: URL) -> Bool {
        let url = recordURL(ofPersona: id, in: directory)
        return !FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Returns once every queued write of a record file is on disk, as quitting needs.
    static func finishWrites() {
        writeQueue.sync {}
    }

    /// Reads the file's records once per launch, each to be checked at its pair's first copy.
    private func loadRecords() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let recordURL, let data = try? Data(contentsOf: recordURL), let file = try? JSONDecoder().decode(RecordFile.self, from: data),
              file.version == RecordFile.currentVersion else { return }
        for pair in file.pairs {
            let engines = Set(pair.engines)
            agreed[engines] = Dictionary(pair.cookies.map { cookie in
                (CookieKey(name: cookie.name, domain: cookie.domain, path: cookie.path), Digest(saved: cookie.digest))
            }) { first, _ in first }
            unchecked.insert(engines)
        }
    }

    /// Writes every record's cookies that have an expiry on `writeQueue`, once the file has been read.
    private func saveRecords() {
        guard isLoaded, let recordURL else { return }
        let agreed = agreed
        Self.writeQueue.async {
            let pairs = agreed.map { engines, record in
                RecordFile.Pair(engines: engines.sorted { $0.rawValue < $1.rawValue },
                                cookies: record.filter(\.value.hasExpiry).map { key, digest in
                                    RecordFile.Cookie(name: key.name, domain: key.domain, path: key.path, digest: digest.sha256)
                                })
            }
            guard let data = try? JSONEncoder().encode(RecordFile(pairs: pairs)) else { return }
            try? FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: recordURL, options: .atomic)
        }
    }
}
