// Web extensions on WebKit, from macOS 15.4: each profile has one `WKWebExtensionController`, which every web view of the profile uses, and each extension the app loads runs in it as a `WKWebExtensionContext`. The profile's web contents are the extensions' tabs, and the windows the app reports are their windows. Popups, questions about access, and native messages go to the app through the delegate.
import AppKit
import ARCHEngine
import WebKit

@available(macOS 15.4, *)
final class WebKitExtensions: NSObject, EngineExtensions, WKWebExtensionControllerDelegate {
    weak var delegate: (any EngineExtensionsDelegate)?
    let controller: WKWebExtensionController
    /// The loaded extensions, by identifier, which each context also carries as its `uniqueIdentifier`.
    private var contexts: [String: WKWebExtensionContext] = [:]
    /// The windows of the last `setWindows(_:focusedWindowID:)` call, in the app's order, each with the profile's tabs only.
    private var windows: [WebKitExtensionWindow] = []
    private var focusedWindow: WebKitExtensionWindow?

    /// Keeps the extensions' data as the profile keeps its website data: nothing for incognito, the default location for the default store, and otherwise under the store's identifier. Extensions reach cookies in the profile's store.
    init(context: WebKitBrowserContext) {
        let configuration = Self.configuration(forStorage: context.attributes.storageIdentifier, isPersistent: context.attributes.type == .regular)
        configuration.defaultWebsiteDataStore = context.dataStore
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    private static func configuration(forStorage identifier: UUID?, isPersistent: Bool) -> WKWebExtensionController.Configuration {
        guard isPersistent else { return .nonPersistent() }
        return identifier.map { .init(identifier: $0) } ?? .default()
    }

    /// Deletes what the extensions of the profile with the storage identifier kept, while no controller of this process uses it, as at launch.
    static func removeData(forStorage identifier: UUID, completion: @escaping () -> Void) {
        let controller = WKWebExtensionController(configuration: configuration(forStorage: identifier, isPersistent: true))
        let types = WKWebExtensionController.allExtensionDataTypes
        controller.fetchDataRecords(ofTypes: types) { records in
            // The controller stays until its data is gone.
            controller.removeData(ofTypes: types, from: records) { withExtendedLifetime(controller, completion) }
        }
    }

    // MARK: Loading

    /// `WKWebExtension` throws only for a manifest it cannot read and keeps other problems in its `errors`, which do not count here.
    func check(_ packageURL: URL) async throws {
        _ = try await WKWebExtension(resourceBaseURL: packageURL)
    }

    /// The extension reaches `webkit-extension://<id>/`, and its storage stays under its identifier across launches.
    func load(_ extension: EngineExtension) async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: `extension`.packageURL)
        unload(`extension`.id)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = `extension`.id
        // Identifiers are lowercase letters, so the address exists.
        context.baseURL = URL(string: "webkit-extension://\(`extension`.id)/")!
        // As the profile's pages, which the browser bundled with macOS can inspect.
        context.isInspectable = true
        context.inspectionName = webExtension.displayName
        for permission in webExtension.requestedPermissions where `extension`.permissions.contains(permission.rawValue) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for site in `extension`.sites {
            guard let pattern = try? WKWebExtension.MatchPattern(string: site) else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        contexts[`extension`.id] = context
    }

    func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    func removeData(of id: String) async {
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
        guard !records.isEmpty else { return }
        await controller.removeData(ofTypes: types, from: records)
    }

    // MARK: Actions

    /// Only the profile's own web contents have actions here.
    func action(of id: String, for tab: any EngineWebContents) -> EngineExtensionAction? {
        guard let tab = extensionTab(of: tab), let action = contexts[id]?.action(for: tab) else { return nil }
        return EngineExtensionAction(label: action.label, icon: action.icon(for: CGSize(width: 16, height: 16)), badgeText: action.badgeText, isEnabled: action.isEnabled)
    }

    func performAction(of id: String, for tab: any EngineWebContents) {
        guard let tab = extensionTab(of: tab) else { return }
        contexts[id]?.performAction(for: tab)
    }

    /// WebKit asks for a site through the controller's prompts instead, so no action of it wants site access.
    func grantSiteAccess(of id: String, for tab: any EngineWebContents) {}

    private func extensionTab(of webContents: any EngineWebContents) -> WebKitExtensionTab? {
        guard let webContents = webContents as? WebKitWebContents, webContents.context.webExtensions === self else { return nil }
        return webContents.extensionTab
    }

    // MARK: Windows and tabs

    /// The window that lists the tab, as the last call reported it.
    func window(of tab: WebKitExtensionTab) -> WebKitExtensionWindow? {
        windows.first { window in window.tabs.contains { $0 === tab } }
    }

    /// Keeps each window's object while the window stays, as WebKit tells windows apart by their objects, and tells the loaded extensions what changed: windows that opened and closed, tabs that opened, closed, and moved to another window, the active tab of each window, and the focused window. Tabs that only changed their place in a window are not reported; extensions read their index when they need it. A window with the identity of a window before it in the report is left out, so that each identity names one window.
    func setWindows(_ reported: [EngineExtensionWindow], focusedWindowID: UUID?) {
        let previousWindows = windows
        let previousFocus = focusedWindow
        let previousPlaces = Self.places(in: previousWindows)
        let previousActiveTabs = Dictionary(uniqueKeysWithValues: previousWindows.map { ($0.id, $0.activeTab) })
        var reportedIDs: Set<UUID> = []
        windows = reported.filter { reportedIDs.insert($0.id).inserted }.map { report in
            let window = previousWindows.first { $0.id == report.id } ?? WebKitExtensionWindow(id: report.id)
            window.tabs = report.tabs.compactMap(extensionTab(of:))
            window.activeTab = report.activeTab.flatMap(extensionTab(of:))
            window.window = report.window
            return window
        }
        focusedWindow = windows.first { $0.id == focusedWindowID }
        let places = Self.places(in: windows)
        for window in previousWindows where !windows.contains(where: { $0 === window }) {
            for tab in window.tabs where places[ObjectIdentifier(tab)] == nil { controller.didCloseTab(tab, windowIsClosing: true) }
            controller.didCloseWindow(window)
        }
        for window in windows where !previousWindows.contains(where: { $0 === window }) {
            controller.didOpenWindow(window)
        }
        for (key, place) in previousPlaces where places[key] == nil && windows.contains(where: { $0 === place.window }) {
            controller.didCloseTab(place.tab, windowIsClosing: false)
        }
        for (key, place) in places {
            guard let previous = previousPlaces[key] else {
                controller.didOpenTab(place.tab)
                continue
            }
            if previous.window !== place.window { controller.didMoveTab(place.tab, from: previous.index, in: previous.window) }
        }
        for window in windows {
            guard let active = window.activeTab, let previous = previousActiveTabs[window.id], previous !== active else { continue }
            controller.didActivateTab(active, previousActiveTab: previous)
        }
        if focusedWindow !== previousFocus { controller.didFocusWindow(focusedWindow) }
    }

    /// Where the windows list each tab, by the tab's object.
    private static func places(in windows: [WebKitExtensionWindow]) -> [ObjectIdentifier: TabPlace] {
        var places: [ObjectIdentifier: TabPlace] = [:]
        for window in windows {
            for (index, tab) in window.tabs.enumerated() { places[ObjectIdentifier(tab)] = TabPlace(tab: tab, window: window, index: index) }
        }
        return places
    }

    /// Tells the loaded extensions that a listed tab's title, address, or loading state changed.
    func tabDidChange(_ tab: WebKitExtensionTab, _ properties: WKWebExtension.TabChangedProperties) {
        guard !contexts.isEmpty, window(of: tab) != nil else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    // MARK: WKWebExtensionControllerDelegate

    /// The focused window comes first, as WebKit requires.
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let focusedWindow else { return windows }
        return [focusedWindow] + windows.filter { $0 !== focusedWindow }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedWindow
    }

    /// The app opens the tab in its window, which it then reports, and WebKit's options page opens the same way. The tab opens unpinned and unmuted whatever the configuration asks.
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let delegate else { return completionHandler(nil, WebKitExtensionError.tabNotOpened) }
        let window = configuration.window as? WebKitExtensionWindow
        let index = configuration.index < (window?.tabs.count ?? 0) ? configuration.index : nil
        delegate.extensions(self, openTabWith: configuration.url, inWindow: window?.id, active: configuration.shouldBeActive, index: index) { [weak self] contents in
            guard let tab = contents.flatMap({ self?.extensionTab(of: $0) }) else { return completionHandler(nil, WebKitExtensionError.tabNotOpened) }
            completionHandler(tab, nil)
        }
    }

    /// The app opens a window with the addresses as tabs. Tabs to move into it and its type, state, and frame are not followed.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard let delegate, !configuration.shouldBePrivate else { return completionHandler(nil, WebKitExtensionError.windowNotOpened) }
        delegate.extensions(self, openWindowWith: configuration.tabURLs, focused: configuration.shouldBeFocused) { [weak self] id in
            guard let window = self?.windows.first(where: { $0.id == id }) else { return completionHandler(nil, WebKitExtensionError.windowNotOpened) }
            completionHandler(window, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        ask(Set(permissions.map { .permission($0.rawValue) }), in: tab, for: extensionContext) { allowed in
            completionHandler(permissions.filter { allowed.contains(.permission($0.rawValue)) }, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        ask(Set(urls.map { .page($0) }), in: tab, for: extensionContext) { allowed in
            completionHandler(urls.filter { allowed.contains(.page($0)) }, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        ask(Set(matchPatterns.map { .site($0.string) }), in: tab, for: extensionContext) { allowed in
            completionHandler(matchPatterns.filter { allowed.contains(.site($0.string)) }, nil)
        }
    }

    /// Without a delegate, nothing is allowed. What the user allows lasts while the extension stays loaded.
    private func ask(_ access: Set<EngineExtensionAccess>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                     completion: @escaping (Set<EngineExtensionAccess>) -> Void) {
        guard let delegate else { return completion([]) }
        delegate.extensions(self, extension: extensionContext.uniqueIdentifier, requests: access, in: (tab as? WebKitExtensionTab)?.contents, completion: completion)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        delegate?.extensions(self, didUpdateActionOf: context.uniqueIdentifier)
    }

    /// WebKit's popover sizes itself to the popup and closes it when the popup closes itself or the popover goes; the app chooses where it shows.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        let tab = (action.associatedTab as? WebKitExtensionTab)?.contents
        guard let popover = action.popupPopover, delegate?.extensions(self, present: .popover(popover), ofExtension: context.uniqueIdentifier, for: tab) == true else {
            action.closePopup()
            return completionHandler(WebKitExtensionError.popupNotShown)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard let delegate, let json = try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed) else {
            return replyHandler(nil, WebKitExtensionError.notJSON)
        }
        delegate.extensions(self, extension: extensionContext.uniqueIdentifier, sendNativeMessage: json, toApplication: applicationIdentifier) { result in
            switch result {
            case let .success(reply):
                guard let value = try? JSONSerialization.jsonObject(with: reply, options: .fragmentsAllowed) else { return replyHandler(nil, WebKitExtensionError.notJSON) }
                replyHandler(value, nil)
            case let .failure(error):
                replyHandler(nil, error)
            }
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let delegate else { return completionHandler(WebKitExtensionError.noNativeApp) }
        do {
            try delegate.extensions(self, extension: extensionContext.uniqueIdentifier, connect: WebKitNativeMessagingPort(port))
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// Where the last report listed a tab.
@available(macOS 15.4, *)
private struct TabPlace {
    let tab: WebKitExtensionTab
    let window: WebKitExtensionWindow
    let index: Int
}

enum WebKitExtensionError: LocalizedError {
    case popupNotShown
    case notJSON
    case noNativeApp
    case tabClosed
    case tabNotOpened
    case windowNotOpened

    var errorDescription: String? {
        switch self {
        case .popupNotShown: return "No window shows the tab, so the popup cannot show."
        case .notJSON: return "The message is not JSON."
        case .noNativeApp: return "No native app can answer."
        case .tabClosed: return "The tab has closed."
        case .tabNotOpened: return "Arch did not open the tab."
        case .windowNotOpened: return "Arch did not open the window."
        }
    }
}

/// One of the app's windows as extensions see it.
@available(macOS 15.4, *)
final class WebKitExtensionWindow: NSObject, WKWebExtensionWindow {
    let id: UUID
    var tabs: [WebKitExtensionTab] = []
    var activeTab: WebKitExtensionTab?
    weak var window: NSWindow?

    init(id: UUID) {
        self.id = id
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        return window.styleMask.contains(.fullScreen) ? .fullscreen : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    /// Unknown while no AppKit window shows it.
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { (window?.screen ?? NSScreen.main)?.frame ?? .null }
}

/// What the profile's extensions see of a web contents, which it keeps for its lifetime, as WebKit tells tabs apart by their objects. It answers from its page, and from the windows the app last reported for its window, place, and selection; activating and closing it go to the app.
final class WebKitExtensionTab: NSObject {
    private(set) weak var contents: WebKitWebContents?

    init(contents: WebKitWebContents) {
        self.contents = contents
    }
}

@available(macOS 15.4, *)
extension WebKitExtensionTab: WKWebExtensionTab {
    private var extensions: WebKitExtensions? { contents?.context.webExtensions }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { extensions?.window(of: self) }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        extensions?.window(of: self)?.tabs.firstIndex { $0 === self } ?? NSNotFound
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool { extensions?.window(of: self)?.activeTab === self }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { contents?.webView }

    func title(for context: WKWebExtensionContext) -> String? { contents?.webView.title }

    func url(for context: WKWebExtensionContext) -> URL? { contents?.webView.url }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { contents?.webView.isLoading == false }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { contents?.isAudible ?? false }

    func zoomFactor(for context: WKWebExtensionContext) -> Double { contents?.zoomFactor ?? 1 }

    func size(for context: WKWebExtensionContext) -> CGSize { contents?.webView.bounds.size ?? .zero }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        perform(completionHandler) { extensions, contents in extensions.delegate?.extensions(extensions, activate: contents) }
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        perform(completionHandler) { extensions, contents in extensions.delegate?.extensions(extensions, close: contents) }
    }

    /// Loads as the address field does, which answers a page's own dialog first.
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        perform(completionHandler) { _, contents in contents.navigationController.load(URLRequest(url: url)) }
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        perform(completionHandler) { _, contents in
            if fromOrigin { contents.navigationController.reloadWithoutCache() } else { contents.navigationController.reload() }
        }
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        perform(completionHandler) { _, contents in contents.navigationController.goBack() }
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        perform(completionHandler) { _, contents in contents.navigationController.goForward() }
    }

    /// Runs `action` on a tab that is still open in a profile with extensions, and fails otherwise.
    private func perform(_ completionHandler: @escaping ((any Error)?) -> Void, _ action: (WebKitExtensions, WebKitWebContents) -> Void) {
        guard let extensions, let contents else { return completionHandler(WebKitExtensionError.tabClosed) }
        action(extensions, contents)
        completionHandler(nil)
    }
}

/// A port an extension opened to a native app, with its messages as JSON. The port stays open while this object lives.
@available(macOS 15.4, *)
final class WebKitNativeMessagingPort: EngineNativeMessagingPort {
    private let port: WKWebExtension.MessagePort
    var onMessage: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?

    init(_ port: WKWebExtension.MessagePort) {
        self.port = port
        port.messageHandler = { [weak self] message, _ in
            guard let message, let json = try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed) else { return }
            self?.onMessage?(json)
        }
        port.disconnectHandler = { [weak self] _ in self?.onDisconnect?() }
    }

    var application: String? { port.applicationIdentifier }

    func send(_ message: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: message, options: .fragmentsAllowed) else { return }
        port.sendMessage(value, completionHandler: nil)
    }

    func disconnect(_ error: (any Error)?) {
        port.disconnect(throwing: error)
    }
}

/// What changed in a tab that extensions follow.
enum WebKitExtensionTabChange {
    case title, url, loading
}

extension WebKitWebContents {
    /// Tells the profile's extensions that the tab's title, address, or loading state changed.
    func extensionTabDidChange(_ change: WebKitExtensionTabChange) {
        guard #available(macOS 15.4, *), let extensions = context.webExtensions else { return }
        let properties: WKWebExtension.TabChangedProperties = switch change {
        case .title: .title
        case .url: .URL
        case .loading: .loading
        }
        extensions.tabDidChange(extensionTab, properties)
    }
}
