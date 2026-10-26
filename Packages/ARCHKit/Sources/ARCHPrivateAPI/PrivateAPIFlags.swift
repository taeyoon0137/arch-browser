// Keeps the flags for private APIs and checks whether each API exists on the running system. Features ask before they use one; the `flags://` page shows and changes the flags.
import Foundation

/// A private API that Arch may use behind flags. `check` only looks the API up, for example a class or a selector, so it is quick and safe off the main thread.
public struct PrivateAPI: Identifiable, Sendable {
    public let id: String
    /// The API as its framework names it, such as `WKWebView._inspector`.
    public let name: String
    public let framework: String
    public let check: @Sendable () -> Bool

    public init(id: String, name: String, framework: String, check: @escaping @Sendable () -> Bool) {
        self.id = id
        self.name = name
        self.framework = framework
        self.check = check
    }
}

/// A feature that uses one or more private APIs.
public struct PrivateAPIFeature: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let apiIDs: [String]

    public init(id: String, name: String, apiIDs: [String]) {
        self.id = id
        self.name = name
        self.apiIDs = apiIDs
    }
}

/// The private APIs and features Arch knows, with one flag for all private APIs, one for each API, and one for each feature. Flags are on unless the user turns them off, and are saved in `UserDefaults`.
@MainActor
public final class PrivateAPIFlags: ObservableObject {
    public static let shared = PrivateAPIFlags()

    @Published public private(set) var apis: [PrivateAPI] = []
    @Published public private(set) var features: [PrivateAPIFeature] = []
    /// Whether each checked API exists. An API without an entry has not been checked yet.
    @Published public private(set) var availability: [String: Bool] = [:]

    private let defaults: UserDefaults
    private static let allKey = "ARCHPrivateAPIs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The flag for all private APIs.
    public var allowsPrivateAPIs: Bool {
        get { flag(Self.allKey) }
        set { setFlag(newValue, Self.allKey) }
    }

    public func isOn(api id: String) -> Bool { flag("ARCHPrivateAPI.\(id)") }
    public func setOn(_ isOn: Bool, api id: String) { setFlag(isOn, "ARCHPrivateAPI.\(id)") }
    public func isOn(feature id: String) -> Bool { flag("ARCHPrivateAPIFeature.\(id)") }
    public func setOn(_ isOn: Bool, feature id: String) { setFlag(isOn, "ARCHPrivateAPIFeature.\(id)") }

    /// Lists the API and checks on a background queue whether it exists, so that neither launch nor the flags page waits for the check.
    public func register(_ api: PrivateAPI) {
        guard !apis.contains(where: { $0.id == api.id }) else { return }
        apis.append(api)
        let check = api.check
        let id = api.id
        DispatchQueue.global(qos: .utility).async {
            let isAvailable = check()
            Task { @MainActor in self.availability[id] = isAvailable }
        }
    }

    public func register(_ feature: PrivateAPIFeature) {
        guard !features.contains(where: { $0.id == feature.id }) else { return }
        features.append(feature)
    }

    /// Whether the API exists. An API whose background check has not finished is checked now. The result is recorded after the current turn of the main actor, since a view that is drawing may ask, and a view must not change what it observes while it draws.
    public func isAvailable(_ id: String) -> Bool {
        if let isAvailable = availability[id] { return isAvailable }
        guard let api = apis.first(where: { $0.id == id }) else { return false }
        let isAvailable = api.check()
        Task { @MainActor in self.availability[id] = isAvailable }
        return isAvailable
    }

    /// Whether the feature may run now: the flag for all private APIs, its own flag, and the flag of each of its APIs are on, and each API exists.
    public func allows(_ featureID: String) -> Bool {
        guard allowsPrivateAPIs, isOn(feature: featureID), let feature = features.first(where: { $0.id == featureID }) else { return false }
        return feature.apiIDs.allSatisfy { isOn(api: $0) && isAvailable($0) }
    }

    private func flag(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    private func setFlag(_ isOn: Bool, _ key: String) {
        objectWillChange.send()
        defaults.set(isOn, forKey: key)
    }
}
