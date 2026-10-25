// Token usage, prices, and spending limits, and the usage totals in `ai-usage.json`. Arch ships no price list; costs come from the prices the user enters and are estimates.
import Foundation

public struct AIUsage: Codable, Sendable, Equatable {
    /// Input tokens that were not read from the provider's cache.
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens, cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens)
    }
}

public struct AIMoney: Codable, Sendable, Equatable {
    public var currency: String
    public var amount: Decimal

    public init(currency: String, amount: Decimal) {
        self.currency = currency
        self.amount = amount
    }
}

public struct AIPrice: Codable, Sendable, Equatable {
    public var currency: String
    public var inputPerMillion: Decimal
    public var outputPerMillion: Decimal
    /// nil uses `inputPerMillion`.
    public var cachedInputPerMillion: Decimal?

    public init(currency: String, inputPerMillion: Decimal, outputPerMillion: Decimal, cachedInputPerMillion: Decimal? = nil) {
        self.currency = currency
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
    }

    /// The estimated cost of `usage` in `currency`.
    public func cost(of usage: AIUsage) -> Decimal {
        let input = Decimal(usage.inputTokens) * inputPerMillion
        let output = Decimal(usage.outputTokens) * outputPerMillion
        let cached = Decimal(usage.cachedInputTokens) * (cachedInputPerMillion ?? inputPerMillion)
        return (input + output + cached) / 1_000_000
    }
}

public struct AILimits: Codable, Sendable, Equatable {
    /// Per automatic feature.
    public var automaticRequestsPerDay: Int
    /// nil means no limit.
    public var monthlySpendingLimit: AIMoney?

    public init(automaticRequestsPerDay: Int = 300, monthlySpendingLimit: AIMoney? = nil) {
        self.automaticRequestsPerDay = automaticRequestsPerDay
        self.monthlySpendingLimit = monthlySpendingLimit
    }
}

// MARK: - Usage store

/// Usage totals without content or addresses: per month (the last 13), per feature, provider, and model, plus the current day's automatic request counts for the daily limit. Names are kept with each total so a removed feature or provider still reads well.
@MainActor
public final class AIUsageStore: ObservableObject {
    public struct Total: Codable, Sendable, Identifiable {
        public var id: String { "\(feature)\u{1F}\(provider)\u{1F}\(model)" }
        public var feature: String
        public var featureName: String
        public var provider: String
        public var providerName: String
        public var model: String
        public var requests: Int
        public var errors: Int
        public var usage: AIUsage
        /// Estimated cost by currency, for models with a price.
        public var costs: [String: Decimal]
    }

    public struct Month: Codable, Sendable {
        /// `yyyy-MM` in the user's calendar.
        public var month: String
        public var totals: [Total]
    }

    private struct File: Codable {
        var version = 1
        var months: [Month]
        var day: String
        var automaticRequests: [String: Int]
    }

    public static let keptMonths = 13

    /// Newest last.
    @Published public private(set) var months: [Month] = []
    private var day = ""
    private var automaticRequests: [String: Int] = [:]
    let fileURL: URL
    private let now: () -> Date
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        if let data = try? Data(contentsOf: fileURL) {
            if let file = try? JSONDecoder().decode(File.self, from: data) {
                months = file.months
                day = file.day
                automaticRequests = file.automaticRequests
            } else {
                // Like `ai.json`, a file that does not decode is set aside, so the first save does not overwrite its totals.
                let unreadable = fileURL.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: unreadable)
                try? FileManager.default.moveItem(at: fileURL, to: unreadable)
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// The totals `monthsAgo` months before the current one; empty when none were recorded.
    public func totals(monthsAgo: Int) -> [Total] {
        let key = Self.monthKey(Calendar.current.date(byAdding: .month, value: -monthsAgo, to: now()) ?? now())
        return months.first(where: { $0.month == key })?.totals ?? []
    }

    /// Adds one request to the totals of its feature and model. A failed request counts as an error and adds the tokens the provider reported before it failed.
    func record(feature: AIFeature, provider: AIProviderConfiguration, model: AIModelConfiguration, usage: AIUsage?, isError: Bool) {
        let key = Self.monthKey(now())
        if months.last?.month != key {
            months.append(Month(month: key, totals: []))
            months = Array(months.suffix(Self.keptMonths))
        }
        let total = Total(feature: feature.id.rawValue, featureName: feature.name, provider: provider.id.rawValue, providerName: provider.name, model: model.name, requests: 0, errors: 0, usage: AIUsage(inputTokens: 0, outputTokens: 0), costs: [:])
        var totals = months[months.count - 1].totals
        let index = totals.firstIndex(where: { $0.id == total.id }) ?? {
            totals.append(total)
            return totals.count - 1
        }()
        totals[index].featureName = feature.name
        totals[index].providerName = provider.name
        totals[index].requests += 1
        if isError { totals[index].errors += 1 }
        if let usage {
            totals[index].usage = totals[index].usage + usage
            if let price = model.price {
                totals[index].costs[price.currency, default: 0] += price.cost(of: usage)
            }
        }
        months[months.count - 1].totals = totals
        scheduleSave()
    }

    /// Automatic requests the feature made today.
    func automaticRequestCount(for feature: AIFeatureID) -> Int {
        day == Self.dayKey(now()) ? automaticRequests[feature.rawValue] ?? 0 : 0
    }

    func countAutomaticRequest(for feature: AIFeatureID) {
        let today = Self.dayKey(now())
        if day != today {
            day = today
            automaticRequests = [:]
        }
        automaticRequests[feature.rawValue, default: 0] += 1
        scheduleSave()
    }

    /// The current month's estimated cost in `currency`.
    func estimatedCost(in currency: String) -> Decimal {
        guard let month = months.last, month.month == Self.monthKey(now()) else { return 0 }
        return month.totals.reduce(0) { $0 + ($1.costs[currency] ?? 0) }
    }

    /// Combines rapid changes into one file write, like the session store.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let file = File(months: months, day: day, automaticRequests: automaticRequests)
        guard let data = try? JSONEncoder.aiFiles.encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func monthKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

extension JSONEncoder {
    /// Readable output for the files the user may inspect: `ai.json` and `ai-usage.json`.
    static var aiFiles: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
