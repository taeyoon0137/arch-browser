// Saved pages (`docs/bookmarks.md`, Saved pages; bookmark rules 2 and 3): the page a pinned tab returns to, the comparisons that tell whether a tab has left it, and the commands that return to it or change it. A favorite's own address and title serve as its saved page, so the commands also act on a favorite's tab. The session's methods that change its lists, such as `duplicateTab(_:)` and `updateFavorite(_:_:)`, live in `BrowserSession.swift`.
import AppKit
import Foundation

/// The page a pinned tab keeps to return to: an address and its title (bookmark rule 2). The title stays empty until the page shows one at that address.
public struct SavedPage: Codable, Equatable, Hashable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

extension URL {
    /// Bookmark rule 3: whether this address shows the same page as `other`. The fragment, `http` against `https`, the host's case, a leading `www.`, and a trailing slash do not count; anything else, such as another path or query, does.
    public func isSamePage(as other: URL) -> Bool {
        guard let page = ComparedAddress(self), let otherPage = ComparedAddress(other) else { return self == other }
        return page == otherPage
    }

    /// Bookmark rule 3: whether this address is on the same site as `other`: the same host, compared as `isSamePage(as:)` compares hosts. An address without a host, such as a file's, is on the site of every address of its scheme without one.
    func isSameSite(as other: URL) -> Bool {
        guard let site = ComparedAddress(self)?.site, let otherSite = ComparedAddress(other)?.site else { return self == other }
        return site == otherSite
    }
}

/// An address reduced to the parts that bookmark rule 3 compares.
private struct ComparedAddress: Equatable {
    enum Site: Equatable {
        /// The host in lowercase without a leading `www.`.
        case host(String)
        /// The scheme of an address without a host.
        case scheme(String)
    }

    let site: Site
    /// `https` for `http`, which the comparison treats as the same scheme.
    let scheme: String
    let port: Int?
    let user: String?
    let password: String?
    /// The path without one trailing slash, so that the root of a site is the empty path.
    let path: String
    /// The query, with an empty one counting as none.
    let query: String?

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = components.scheme?.lowercased() else { return nil }
        self.scheme = scheme == "http" ? "https" : scheme
        if let host = components.host?.lowercased(), !host.isEmpty {
            site = .host(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        } else {
            site = .scheme(scheme)
        }
        port = components.port
        user = components.percentEncodedUser
        password = components.percentEncodedPassword
        let path = components.percentEncodedPath
        self.path = path.hasSuffix("/") ? String(path.dropLast()) : path
        query = components.percentEncodedQuery.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: The tab's side

extension Tab {
    /// Whether the tab shows another page than `saved` under bookmark rule 3. A tab whose page has reported no address yet is not off it.
    func isOff(page saved: URL) -> Bool {
        url.map { !$0.isSamePage(as: saved) } ?? false
    }

    /// Whether the tab is on another site than `saved` under bookmark rule 3.
    func isOff(site saved: URL) -> Bool {
        url.map { !$0.isSameSite(as: saved) } ?? false
    }

    /// Whether a pinned tab is off its saved page, for Go Back to Saved Page. A favorite's tab compares with its favorite's address, which only the session knows (`BrowserSession.isOffSavedPage(_:)`).
    var isOffSavedPage: Bool { savedPage.map { isOff(page: $0.url) } ?? false }

    /// Whether a pinned tab is off its saved site, for the back button on its row (bookmark rule 3).
    var isOffSavedSite: Bool { savedPage.map { isOff(site: $0.url) } ?? false }

    /// The page the tab shows, as Use Current Page as Saved Page takes it, or nil before its page reports an address.
    var currentPage: SavedPage? { url.map { SavedPage(url: $0, title: title) } }

    /// Loads `url`, the tab's saved page or its favorite's address, as the user asked for it. A tab without its page moves its stand-in there without loading, as any load on it does (`UnloadedWebContents`).
    func goBack(toSavedPage url: URL) {
        forgetExternalAppDecline()
        webContents.navigationController.load(URLRequest(url: url))
    }

    /// Use Current Page as Saved Page for a pinned tab: the page it shows becomes its saved page. A live folder item's source owns its tab's saved page.
    func useCurrentPageAsSavedPage() {
        guard isPinned, liveItemID == nil, let page = currentPage else { return }
        savedPage = page
    }

    /// Edit Saved Address… for a pinned tab: the address in `text`, read as the address field reads it, becomes the saved page, and a tab without its page moves its stand-in there. The title stays while the address names the same page and is otherwise empty until the page shows one there. Returns false and changes nothing for text that `BrowserSession.url(forInput:)` rejects, and for a live folder item's tab, whose source owns its saved page.
    @discardableResult
    func setSavedAddress(fromInput text: String) -> Bool {
        guard isPinned, liveItemID == nil, let url = BrowserSession.url(forInput: text) else { return false }
        let title = savedPage.flatMap { url.isSamePage(as: $0.url) ? $0.title : nil } ?? ""
        savedPage = SavedPage(url: url, title: title)
        if !isLoaded { webContents.navigationController.load(URLRequest(url: url)) }
        return true
    }
}

// MARK: The favorite's side

extension Favorite {
    /// Use Current Page as Saved Page for the favorite's tab: the favorite at the tab's address with its page title, or nil while the tab has no address or another favorite of the Persona has it, since a Persona's favorites come once per address (`BrowserSession.addFavorite(_:)`).
    @MainActor func usingCurrentPage(of tab: Tab, among favorites: [Favorite]) -> Favorite? {
        guard let url = tab.url, BrowserSession.canUse(url, asAddressOf: self, among: favorites) else { return nil }
        var favorite = self
        favorite.url = url
        favorite.title = tab.pageTitle
        return favorite
    }

    /// Edit Favorite…: the favorite at the address in `address`, read as the address field reads it, and named `name` unless it is empty. Nil for an address that `BrowserSession.url(forInput:)` rejects or that another favorite of the Persona has.
    func edited(name: String, address: String, among favorites: [Favorite]) -> Favorite? {
        guard let url = BrowserSession.url(forInput: address), BrowserSession.canUse(url, asAddressOf: self, among: favorites) else { return nil }
        var favorite = self
        favorite.url = url
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { favorite.title = name }
        return favorite
    }
}

// MARK: The session's side

extension BrowserSession {
    /// The favorite whose own tab `tab` is, or nil for a space's tab.
    func favorite(ofTab tab: Tab) -> Favorite? {
        guard let id = favoriteTabs.first(where: { $0.value === tab })?.key else { return nil }
        return favorites.first { $0.id == id }
    }

    /// The favorite's tab while it is open. A tab saved from the last session counts once the favorite's first click opens it.
    func openTab(ofFavorite favorite: Favorite) -> Tab? {
        favoriteTabs[favorite.id]
    }

    /// The address the tab returns to: a pinned tab's saved page, or a favorite's address for its tab (bookmark rule 2). Nil for any other tab.
    func savedAddress(of tab: Tab) -> URL? {
        tab.savedPage?.url ?? favorite(ofTab: tab)?.url
    }

    /// Whether Go Back to Saved Page applies: the tab is a pinned tab or a favorite's tab, and is off its saved page (bookmark rule 3).
    public func isOffSavedPage(_ tab: Tab) -> Bool {
        savedAddress(of: tab).map(tab.isOff(page:)) ?? false
    }

    /// Go Back to Saved Page: loads the saved page in a pinned tab, or the favorite's address in a favorite's tab.
    public func goBackToSavedPage(_ tab: Tab) {
        guard let url = savedAddress(of: tab) else { return }
        tab.goBack(toSavedPage: url)
    }

    /// Whether Use Current Page as Saved Page applies: the tab has an address and is pinned, but not a live folder item's tab, whose source owns its saved page, or is a favorite's tab whose address no other favorite of its Persona has.
    public func canUseCurrentPageAsSavedPage(_ tab: Tab) -> Bool {
        guard tab.url != nil, tab.liveItemID == nil else { return false }
        if tab.isPinned { return true }
        return favorite(ofTab: tab)?.usingCurrentPage(of: tab, among: favorites) != nil
    }

    /// Use Current Page as Saved Page: a pinned tab's page becomes its saved page, and a favorite's tab's page, with its title, becomes the favorite's address and title.
    public func useCurrentPageAsSavedPage(_ tab: Tab) {
        if tab.isPinned { return tab.useCurrentPageAsSavedPage() }
        guard let favorite = favorite(ofTab: tab), let moved = favorite.usingCurrentPage(of: tab, among: favorites) else { return }
        updateFavorite(favorite.id) { $0 = moved }
    }

    /// Edit Favorite…: the favorite takes the name and address that `Favorite.edited(name:address:among:)` gives it. Returns false and changes nothing when it gives none.
    @discardableResult
    func editFavorite(_ id: UUID, name: String, address: String) -> Bool {
        guard let favorite = favorites.first(where: { $0.id == id }), let edited = favorite.edited(name: name, address: address, among: favorites) else { return false }
        updateFavorite(id) { $0 = edited }
        return true
    }

    /// Whether `favorite` can take `url` as its address: no other favorite of its Persona has it, since a Persona's favorites come once per address (`addFavorite(_:)`).
    nonisolated static func canUse(_ url: URL, asAddressOf favorite: Favorite, among favorites: [Favorite]) -> Bool {
        !favorites.contains { $0.id != favorite.id && $0.resolvedPersonaID == favorite.resolvedPersonaID && $0.url == url }
    }

    /// Copy Address: puts the address on the pasteboard as a URL and as text.
    static func copyAddress(_ url: URL) {
        Tab.copyToPasteboard(url)
    }
}
