// Site patterns, the rate limiter, and the `ai.json` file: its shape, unreadable files, and keys kept out of it.
import Foundation
import Testing
@testable import AI

@Suite struct SitePatternTests {
    @Test func hostsMatchTheirSubdomains() {
        let pattern = AISitePattern("example.org")
        #expect(pattern.matches(URL(string: "https://example.org/a")!))
        #expect(pattern.matches(URL(string: "https://news.EXAMPLE.org/a")!))
        #expect(!pattern.matches(URL(string: "https://notexample.org/")!))
        #expect(!pattern.matches(URL(string: "https://example.org.evil.test/")!))
    }

    @Test func schemesMatchByName() {
        #expect(AISitePattern.fileScheme.matches(URL(fileURLWithPath: "/tmp/a.html")))
        #expect(!AISitePattern.fileScheme.matches(URL(string: "https://example.org")!))
    }

    @Test func localNetworkCoversLoopbackLinkLocalAndPrivateAddresses() {
        let local = AISitePattern.localNetwork
        for address in ["http://localhost:3000", "http://printer.local", "http://app.localhost", "http://127.0.0.1", "http://10.1.2.3", "http://172.16.0.1", "http://172.31.255.1", "http://192.168.1.1", "http://169.254.1.1", "http://[::1]/", "http://[fe80::1]/", "http://[fd12::1]/", "http://[::ffff:192.168.0.1]/"] {
            #expect(local.matches(URL(string: address)!), "\(address)")
        }
        for address in ["https://example.org", "http://172.32.0.1", "http://8.8.8.8", "http://[2001:db8::1]/"] {
            #expect(!local.matches(URL(string: address)!), "\(address)")
        }
    }

    @Test func parsesWhatTheUserTypes() {
        #expect(AISitePattern(parsing: " https://www.Example.org/path?q=1 ")?.value == "www.example.org")
        #expect(AISitePattern(parsing: "*.example.org")?.value == "example.org")
        #expect(AISitePattern(parsing: "file:")?.value == "file:")
        #expect(AISitePattern(parsing: "local-network") == .localNetwork)
        #expect(AISitePattern(parsing: "   ") == nil)
    }
}

@Suite struct RateLimiterTests {
    @Test func waitsForAFreeSlot() async throws {
        let limiter = AIRateLimiter(provider: AIProviderID(), limits: AIProviderLimits(concurrentRequests: 1))
        try await limiter.acquire(isUser: true) { _ in }
        let waits = WaitLog()
        let second = Task { try await limiter.acquire(isUser: true) { waits.append($0) } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(waits.reasons == [.queued])
        await limiter.release()
        try await second.value
        await limiter.release()
    }

    @Test func userRequestsTakeSlotsBeforeAutomaticOnes() async throws {
        let limiter = AIRateLimiter(provider: AIProviderID(), limits: AIProviderLimits(concurrentRequests: 1))
        try await limiter.acquire(isUser: true) { _ in }
        let order = WaitLog()
        let automatic = Task {
            try await limiter.acquire(isUser: false) { _ in }
            order.append(.rateLimited(until: .distantPast))
            await limiter.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        let user = Task {
            try await limiter.acquire(isUser: true) { _ in }
            order.append(.queued)
            await limiter.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        await limiter.release()
        try await user.value
        try await automatic.value
        #expect(order.reasons == [.queued, .rateLimited(until: .distantPast)])
    }

    @Test func coolDownDelaysTheNextRequest() async throws {
        let limiter = AIRateLimiter(provider: AIProviderID(), limits: .http)
        await limiter.coolDown(retryAfter: Date() + 0.3)
        let waits = WaitLog()
        let start = ContinuousClock.now
        try await limiter.acquire(isUser: true) { waits.append($0) }
        #expect(ContinuousClock.now - start >= .milliseconds(250))
        guard case .rateLimited = waits.reasons.first else {
            Issue.record("Expected a rate-limit wait")
            return
        }
        await limiter.release()
    }

    @Test func automaticRequestsGiveUpAfterTheWaitLimit() async throws {
        let limiter = AIRateLimiter(provider: AIProviderID(), limits: AIProviderLimits(concurrentRequests: 1), automaticWaitLimit: .milliseconds(100))
        try await limiter.acquire(isUser: true) { _ in }
        do {
            try await limiter.acquire(isUser: false) { _ in }
            Issue.record("Expected rateLimited")
        } catch AIError.rateLimited {
        }
        await limiter.release()
        // The expired request left no slot taken.
        try await limiter.acquire(isUser: false) { _ in }
        await limiter.release()
    }

    @Test func cancellingAWaitingRequestFreesItsPlace() async throws {
        let limiter = AIRateLimiter(provider: AIProviderID(), limits: AIProviderLimits(concurrentRequests: 1))
        try await limiter.acquire(isUser: true) { _ in }
        let waiting = Task { try await limiter.acquire(isUser: true) { _ in } }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await limiter.release()
        try await limiter.acquire(isUser: true) { _ in }
        await limiter.release()
    }

    @Test func backoffDoublesWithoutRetryAfterAndResetsOnSuccess() async {
        let doubling = AIRateLimiter(provider: AIProviderID(), limits: .http)
        #expect(abs(await doubling.coolDown(retryAfter: nil).timeIntervalSinceNow - 20) < 2)
        #expect(abs(await doubling.coolDown(retryAfter: nil).timeIntervalSinceNow - 40) < 2)
        let resetting = AIRateLimiter(provider: AIProviderID(), limits: .http)
        await resetting.coolDown(retryAfter: nil)
        await resetting.recordSuccess()
        #expect(abs(await resetting.coolDown(retryAfter: nil).timeIntervalSinceNow - 20) < 2)
    }
}

/// Wait reasons in the order they were reported.
private final class WaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AIWaitReason] = []

    func append(_ reason: AIWaitReason) {
        lock.lock()
        entries.append(reason)
        lock.unlock()
    }

    var reasons: [AIWaitReason] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

@MainActor
@Suite struct SettingsFileTests {
    @Test func writesTheDocumentedShapeWithoutKeys() throws {
        let directory = temporaryDirectory()
        let keys = InMemoryKeys()
        let store = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
        let first = provider("Work API", models: [AIModelConfiguration(name: "model-a", price: AIPrice(currency: "USD", inputPerMillion: 3, outputPerMillion: 15))], baseURL: "https://api.example.com/v1")
        store.providers = [first]
        try store.setKey("secret-key", for: first.id)
        store.setRoute(AIRoute(isEnabled: false), for: .tabNameHook)
        store.saveNow()

        let data = try Data(contentsOf: store.fileURL)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-key"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["excludedSites"] as? [String] == ["file:", "local-network"])
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let http = try #require((provider["kind"] as? [String: Any])?["http"] as? [String: Any])
        #expect(http["format"] as? String == "chatCompletions")
        #expect(http["baseURL"] as? String == "https://api.example.com/v1")
        #expect(http["hasKey"] as? Bool == true)
        #expect((object["routes"] as? [String: Any])?["hook.tabName"] is [String: Any])
        #expect((object["limits"] as? [String: Any])?["automaticRequestsPerDay"] as? Int == 300)

        let reloaded = AISettingsStore(fileURL: store.fileURL, keys: keys)
        #expect(reloaded.providers == store.providers)
        #expect(reloaded.route(for: .tabNameHook) == AIRoute(isEnabled: false))
        #expect(try keys.key(for: first.id) == "secret-key")
    }

    @Test func readsTheDocumentedExample() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai.json")
        try Data("""
        {
          "version": 1,
          "providers": [
            {
              "id": "6F1C",
              "name": "Work API",
              "kind": { "http": { "format": "chatCompletions", "baseURL": "https://api.example.com/v1", "headers": {}, "hasKey": true } },
              "models": [ { "name": "model-a", "inputCharacterLimit": 100000, "price": { "currency": "USD", "inputPerMillion": 3, "outputPerMillion": 15 } } ],
              "limits": { "concurrentRequests": 4 }
            }
          ],
          "routes": {
            "default": { "isEnabled": true, "models": [ { "provider": "6F1C", "model": "model-a" } ] },
            "pageReader": { "isEnabled": true, "models": [] },
            "hook.tabName": { "isEnabled": false, "models": [] }
          },
          "excludedSites": ["file:", "local-network"],
          "limits": { "automaticRequestsPerDay": 300 }
        }
        """.utf8).write(to: file)
        let store = AISettingsStore(fileURL: file, keys: InMemoryKeys())
        #expect(!store.replacedUnreadableFile)
        #expect(store.providers.first?.models.first?.price?.outputPerMillion == 15)
        #expect(store.route(for: .defaultRoute).models == [AIModelRef(provider: AIProviderID(rawValue: "6F1C"), model: "model-a")])
        #expect(store.route(for: .downloadNameHook) == AIRoute(isEnabled: false))
        #expect(store.route(for: .pageQuestion) == AIRoute(isEnabled: true))
    }

    @Test func renamesAnUnreadableFile() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai.json")
        try Data("not json".utf8).write(to: file)
        let store = AISettingsStore(fileURL: file, keys: InMemoryKeys())
        #expect(store.replacedUnreadableFile)
        #expect(store.providers.isEmpty)
        #expect(store.excludedSites == AISitePattern.defaultExclusions)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("unreadable").path))
    }
}
