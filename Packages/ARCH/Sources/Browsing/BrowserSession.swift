// Owns the engine application, one profile, one browser for the window, and the open tabs.
import AppKit
import ARCHEngine
import Combine
import Foundation

public final class BrowserSession: ObservableObject {
    public let application: any EngineApplication
    public let context: any EngineBrowserContext
    public private(set) var browser: (any EngineBrowser)!
    @Published public private(set) var tabs: [Tab] = []
    @Published public var selectedTabID: UUID?
    @Published public var isSidebarVisible = true
    /// Increment this value to move keyboard focus to the command bar.
    @Published public var commandBarFocusRequest = 0

    public static let searchURL = URL(string: "https://www.google.com/search")!
    public static let newTabURL = URL(string: "https://www.google.com")!

    public init(engine: any Engine, userDataDirectory: URL) throws {
        let configuration = EngineApplicationConfiguration(userDataDirectory: userDataDirectory,
                                                           cacheDirectory: userDataDirectory.appendingPathComponent("Cache"))
        application = try engine.makeApplication(configuration: configuration)
        var created: (any EngineBrowserContext)?
        let attributes = EngineBrowserContextAttributes(id: EngineBrowserContextID(rawValue: "default"), userVisibleName: "Default", type: .regular)
        application.createBrowserContext(attributes) { created = try? $0.get() }
        guard let context = created else { throw SessionError.contextUnavailable }
        self.context = context
        application.run()
        browser = application.createBrowser(EngineBrowserCreateParams(initialBounds: .zero), context: context, delegate: self, window: nil)
    }

    public enum SessionError: Error {
        case contextUnavailable
    }

    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    @discardableResult
    public func openTab(url: URL? = nil, select: Bool = true) -> Tab {
        let webContents = browser.createWebContents(EngineWebContentsConfiguration(initialURL: url ?? Self.newTabURL))
        return adopt(webContents, select: select)
    }

    private func adopt(_ webContents: any EngineWebContents, select: Bool) -> Tab {
        let tab = Tab(webContents: webContents)
        tab.openNewTab = { [weak self] popup in
            self?.browser.takeOwnership(of: popup)
            _ = self?.adopt(popup, select: true)
        }
        tabs.append(tab)
        if select || selectedTabID == nil { selectedTabID = tab.id }
        return tab
    }

    public func closeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        browser.closeWebContents(tab.webContents)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    public func closeSelectedTab() {
        selectedTab.map(closeTab)
    }

    /// Loads a URL when the text parses as one, otherwise runs a web search.
    public func navigate(to input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL
        if let parsed = URL(string: text), parsed.scheme != nil, parsed.host != nil {
            url = parsed
        } else if !text.contains(" "), text.contains("."), let parsed = URL(string: "https://\(text)"), parsed.host != nil {
            url = parsed
        } else {
            var components = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            url = components.url!
        }
        if let tab = selectedTab {
            tab.webContents.navigationController.load(URLRequest(url: url))
        } else {
            openTab(url: url)
        }
    }

    public func goBack() { selectedTab?.webContents.navigationController.goBack() }
    public func goForward() { selectedTab?.webContents.navigationController.goForward() }
    public func reload() { selectedTab?.webContents.navigationController.reload() }
    public func focusCommandBar() { commandBarFocusRequest += 1 }
    public func toggleSidebar() { isSidebarVisible.toggle() }
}

extension BrowserSession: EngineBrowserDelegate {
    public func browser(_ browser: any EngineBrowser, didCreateNewWebContents webContents: any EngineWebContents, isActive: Bool) {
        _ = adopt(webContents, select: isActive)
    }
}
