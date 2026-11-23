// Loop protection's rate (`docs/hooks.md`, Loop protection): what one owner runs for events within a minute, at most 10 for one subject and 60 in all. The hook registry applies it to each hook's runs and the plugin manager to each plugin's events, so code that reacts to its own or another's changes thins out instead of running without end.
import Foundation

/// Limits one owner's event runs within a rolling minute by subject and in total.
public struct BrowserEventRateLimiter: Sendable {
    public static let window: TimeInterval = 60
    public static let runsPerSubject = 10
    public static let runsPerOwner = 60

    /// Whether a run fits both limits or exceeds one of them.
    public enum Admission: Equatable, Sendable {
        case allowed, overSubject, overOwner
    }

    private struct Admitted: Sendable {
        var subject: UUID
        var date: Date
    }

    private var admitted: [String: [Admitted]] = [:]

    public init() {}

    /// Counts a run of `owner`, such as a hook's or a plugin's scheduler owner, for the event subject at `date` while both caps leave room. Runs past a cap are not counted.
    public mutating func admit(_ owner: String, subject: UUID, at date: Date) -> Admission {
        var recent = (admitted[owner] ?? []).filter { date.timeIntervalSince($0.date) < Self.window }
        defer { admitted[owner] = recent.isEmpty ? nil : recent }
        if recent.filter({ $0.subject == subject }).count >= Self.runsPerSubject { return .overSubject }
        if recent.count >= Self.runsPerOwner { return .overOwner }
        recent.append(Admitted(subject: subject, date: date))
        return .allowed
    }

    /// Forgets the owner's runs, as when the user resumes a hook.
    public mutating func reset(_ owner: String) {
        admitted[owner] = nil
    }
}
