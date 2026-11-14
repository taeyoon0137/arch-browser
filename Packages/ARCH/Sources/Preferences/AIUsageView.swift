// Settings ▸ AI ▸ Usage and Activity: the month's totals by feature and by model with estimated costs, the spending and daily limits, and the requests made since launch.
import AI
import SwiftUI

struct AIUsagePage: View {
    @ObservedObject var usage: AIUsageStore
    @ObservedObject var settings: AISettingsStore
    @State private var monthsAgo = 0

    private struct Row: Identifiable {
        var id: String
        var title: String
        var requests = 0
        var errors = 0
        var tokens = 0
        var costs: [String: Decimal] = [:]
    }

    var body: some View {
        let totals = usage.totals(monthsAgo: monthsAgo)
        Section {
            Picker("Month", selection: $monthsAgo) {
                Text("This Month").tag(0)
                Text("Last Month").tag(1)
            }
            .pickerStyle(.segmented)
        }
        Section("By Feature") {
            rows(Self.group(totals, by: { ($0.feature, $0.featureName) }))
        }
        Section("By Model") {
            rows(Self.group(totals, by: { ("\($0.provider)/\($0.model)", "\($0.providerName) \u{2014} \(aiModelTitle($0.model))") }))
        }
        Section {
            Stepper("Automatic requests per day: \(settings.limits.automaticRequestsPerDay)", value: $settings.limits.automaticRequestsPerDay, in: 10...10_000, step: 10)
            Toggle("Monthly spending limit", isOn: Binding(
                get: { settings.limits.monthlySpendingLimit != nil },
                set: { settings.limits.monthlySpendingLimit = $0 ? AIMoney(currency: Locale.current.currency?.identifier ?? "USD", amount: 20) : nil }))
            if let limit = settings.limits.monthlySpendingLimit {
                TextField("Amount", value: Binding(
                    get: { limit.amount },
                    set: { settings.limits.monthlySpendingLimit?.amount = $0 }), format: .number)
                TextField("Currency", text: Binding(
                    get: { limit.currency },
                    set: { settings.limits.monthlySpendingLimit?.currency = $0.uppercased() }))
            }
        } header: {
            Text("Limits")
        } footer: {
            formFootnote("The daily limit applies to each feature that runs on its own. At the spending limit, every AI request stops until the next month or a higher limit. Costs are estimates from the prices entered for each model.")
        }
    }

    @ViewBuilder private func rows(_ rows: [Row]) -> some View {
        if rows.isEmpty {
            Text("No requests").foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            LabeledContent(row.title) {
                Text(Self.summary(of: row)).foregroundStyle(.secondary)
            }
        }
    }

    private static func group(_ totals: [AIUsageStore.Total], by key: (AIUsageStore.Total) -> (id: String, title: String)) -> [Row] {
        var rows: [String: Row] = [:]
        for total in totals {
            let (id, title) = key(total)
            var row = rows[id] ?? Row(id: id, title: title)
            row.requests += total.requests
            row.errors += total.errors
            row.tokens += total.usage.inputTokens + total.usage.outputTokens + total.usage.cachedInputTokens
            row.costs.merge(total.costs, uniquingKeysWith: +)
            rows[id] = row
        }
        return rows.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func summary(of row: Row) -> String {
        var parts = ["\(row.requests) \(row.requests == 1 ? "request" : "requests")"]
        if row.errors > 0 { parts.append("\(row.errors) failed") }
        parts.append("\(row.tokens.formatted()) tokens")
        // Single requests often cost a fraction of a cent.
        parts += row.costs.sorted { $0.key < $1.key }.map { "about \($0.value.formatted(.currency(code: $0.key).precision(.fractionLength(2...4))))" }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The last 50 requests, kept in memory only, newest first. Show Content reveals what was sent.
struct AIActivityPage: View {
    @ObservedObject var service: AIService
    @ObservedObject var settings: AISettingsStore
    @State private var shownContent: Set<UUID> = []

    var body: some View {
        Section {
            if service.activity.isEmpty {
                Text("No requests since Arch started").foregroundStyle(.secondary)
            }
            ForEach(service.activity.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    // The time is secondary, as in the History window. A failure's reason takes a line of its own, so that a long one cannot squeeze the feature's name.
                    HStack(alignment: .firstTextBaseline) {
                        Text(service.features.first(where: { $0.id == entry.feature })?.name ?? entry.feature.rawValue)
                        Text(entry.date, style: .time)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Text(Self.result(of: entry)).foregroundStyle(Self.isFailure(entry) ? .red : .secondary)
                    }
                    if case .failed(let error) = entry.result {
                        Text(settings.message(for: error)).font(.callout).foregroundStyle(.red)
                    }
                    Text(details(of: entry)).font(.subheadline).foregroundStyle(.secondary)
                    // A request that records no content, as an agent hook's run at Keep Nothing, has nothing to show.
                    if !entry.content.isEmpty {
                        Button(shownContent.contains(entry.id) ? "Hide Content" : "Show Content") {
                            if shownContent.contains(entry.id) { shownContent.remove(entry.id) } else { shownContent.insert(entry.id) }
                        }
                        .buttonStyle(.link)
                        .font(.subheadline)
                    }
                    if shownContent.contains(entry.id), !entry.content.isEmpty {
                        ScrollView {
                            Text(entry.content)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
        } header: {
            Text("Recent Requests")
        } footer: {
            formFootnote("Kept in memory until Arch quits. Replies are not kept.")
        }
    }

    private func details(of entry: AIActivityEntry) -> String {
        var parts = [entry.model.map(settings.title(of:)) ?? "No model"]
        parts += entry.parts.map { "\($0.kind) \($0.characters.formatted()) \($0.characters == 1 ? "character" : "characters")" }
        if let usage = entry.usage {
            parts.append("\((usage.inputTokens + usage.cachedInputTokens).formatted()) input and \(usage.outputTokens.formatted()) output tokens")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func result(of entry: AIActivityEntry) -> String {
        switch entry.result {
        case .completed(.lengthLimit): return "Cut at the length limit"
        case .completed: return "Answered"
        case .cancelled: return "Cancelled"
        // The reason shows on its own line under the row's first line.
        case .failed: return "Failed"
        }
    }

    private static func isFailure(_ entry: AIActivityEntry) -> Bool {
        if case .failed = entry.result { return true }
        return false
    }
}
