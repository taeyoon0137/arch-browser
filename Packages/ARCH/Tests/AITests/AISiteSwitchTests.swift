// The switch that allows or excludes a page's site, and how the interface names a model and estimates the cost of its reply.
import Foundation
import Testing
@testable import AI

@MainActor
@Suite struct SiteSwitchTests {
    private func settings() -> AISettingsStore {
        AISettingsStore(fileURL: temporaryDirectory().appendingPathComponent("ai.json"), keys: InMemoryKeys())
    }

    @Test func allowsWebPagesOutsideTheExclusions() {
        let settings = settings()
        #expect(settings.allowsAI(on: URL(string: "https://example.org/a?b=1")!))
        #expect(!settings.allowsAI(on: URL(fileURLWithPath: "/tmp/page.html")))
        #expect(!settings.allowsAI(on: URL(string: "http://localhost:3000/")!))
    }

    @Test func neverAllowsInternalPagesOrOtherSchemes() {
        let settings = settings()
        settings.excludedSites = []
        for address in ["flags://", "about:blank", "data:text/plain,hello", "mailto:someone@example.org"] {
            let url = URL(string: address)!
            #expect(!settings.allowsAI(on: url), "\(address)")
            settings.setAllowsAI(true, on: url)
            settings.setAllowsAI(false, on: url)
            #expect(settings.excludedSites.isEmpty, "\(address)")
        }
    }

    @Test func excludingAddsTheHostOnce() {
        let settings = settings()
        let page = URL(string: "https://News.Example.org/story")!
        settings.setAllowsAI(false, on: page)
        settings.setAllowsAI(false, on: page)
        #expect(settings.excludedSites == AISitePattern.defaultExclusions + [AISitePattern("news.example.org")])
        #expect(!settings.allowsAI(on: page))
    }

    @Test func allowingRemovesEveryExclusionThatMatches() {
        let settings = settings()
        settings.excludedSites += [AISitePattern("example.org"), AISitePattern("news.example.org"), AISitePattern("other.test")]
        let page = URL(string: "https://news.example.org/story")!
        settings.setAllowsAI(true, on: page)
        #expect(settings.allowsAI(on: page))
        #expect(settings.excludedSites == AISitePattern.defaultExclusions + [AISitePattern("other.test")])
    }

    @Test func excludingAgainPutsBackWhatAllowingRemoved() {
        let settings = settings()
        settings.excludedSites += [AISitePattern("example.org")]
        for page in [URL(string: "http://localhost:3000/")!, URL(string: "https://news.example.org/story")!] {
            settings.setAllowsAI(true, on: page)
            #expect(settings.allowsAI(on: page))
            settings.setAllowsAI(false, on: page)
            #expect(!settings.allowsAI(on: page))
        }
        #expect(settings.excludedSites == AISitePattern.defaultExclusions + [AISitePattern("example.org")])
        #expect(!settings.allowsAI(on: URL(string: "http://192.168.1.1/")!))
        #expect(!settings.allowsAI(on: URL(string: "https://mail.example.org/")!))
    }

    @Test func localFilesSwitchTheFileScheme() {
        let settings = settings()
        let file = URL(fileURLWithPath: "/tmp/page.html")
        settings.setAllowsAI(true, on: file)
        #expect(settings.allowsAI(on: file))
        #expect(settings.excludedSites == [.localNetwork])
        settings.setAllowsAI(false, on: file)
        #expect(settings.excludedSites == [.localNetwork, .fileScheme])
    }
}

@MainActor
@Suite struct ModelDescriptionTests {
    private func settings(with providers: [AIProviderConfiguration]) -> AISettingsStore {
        let settings = AISettingsStore(fileURL: temporaryDirectory().appendingPathComponent("ai.json"), keys: InMemoryKeys())
        settings.providers = providers
        return settings
    }

    @Test func namesTheProviderAndModel() {
        let work = provider("Work API", models: [AIModelConfiguration(name: "model-a")])
        let settings = settings(with: [work])
        #expect(settings.title(of: AIModelRef(provider: work.id, model: "model-a")) == "Work API \u{2014} model-a")
        #expect(settings.title(of: AIModelRef(provider: AIProviderID(), model: "model-b")) == "model-b (removed)")
    }

    @Test func estimatesCostsOnlyForPricedModels() {
        let price = AIPrice(currency: "USD", inputPerMillion: 3, outputPerMillion: 15, cachedInputPerMillion: 1)
        let work = provider("Work API", models: [AIModelConfiguration(name: "priced", price: price), AIModelConfiguration(name: "free")])
        let settings = settings(with: [work])
        let usage = AIUsage(inputTokens: 1_000_000, outputTokens: 100_000, cachedInputTokens: 500_000)
        #expect(settings.estimatedCost(of: usage, on: AIModelRef(provider: work.id, model: "priced")) == AIMoney(currency: "USD", amount: Decimal(string: "5")!))
        #expect(settings.estimatedCost(of: usage, on: AIModelRef(provider: work.id, model: "free")) == nil)
        #expect(settings.estimatedCost(of: usage, on: AIModelRef(provider: AIProviderID(), model: "priced")) == nil)
    }
}
