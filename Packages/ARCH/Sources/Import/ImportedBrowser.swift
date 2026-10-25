// What File ▸ Import from Browser… reads from one detected browser before the sheet shows it: each profile with the items it can bring, and why any of them cannot be read. Each browser is read once, off the main thread, so that Import applies what the sheet showed without reading again.
import Browsing
import Foundation
import History

/// A detected browser and what its profiles hold.
struct ImportedBrowser: Identifiable {
    let source: BrowserSource
    /// The profiles with something to bring, in the browser's order, or why the list of profiles cannot be read.
    let profiles: Result<[ImportedProfile], Error>
    /// The default engine of the profile the browser used last, when it is one Arch offers.
    let defaultEngine: SearchEngine?

    var id: BrowserSource.ID { source.id }

    /// Whether macOS privacy protection kept Arch from reading the list of profiles or any profile's file, so that the sheet asks for the source's privacy setting.
    var isBlockedByPrivacy: Bool {
        switch profiles {
        case .failure(let error): return Self.isPrivacyDenial(error)
        case .success(let profiles): return profiles.contains { $0.errors.contains(where: Self.isPrivacyDenial) }
        }
    }

    /// Reads the source's files on the calling thread.
    static func read(_ source: BrowserSource) -> ImportedBrowser {
        switch source.layout {
        case .chromium(let userData, let sidebarFile): return readChromium(source, userData: userData, sidebarFile: sidebarFile)
        case .webKit(let bookmarks, let history): return readWebKit(source, bookmarks: bookmarks, history: history)
        }
    }

    /// The profiles that `Local State` lists, then a row for each profile folder that only the sidebar file names, such as a profile of another Mac that the browser synced. A profile's favorites come from the sidebar file and then its bookmarks bar.
    private static func readChromium(_ source: BrowserSource, userData: URL, sidebarFile: URL?) -> ImportedBrowser {
        let chromiumProfiles: [ChromiumProfile]
        do {
            chromiumProfiles = try ChromiumProfile.profiles(in: userData)
        } catch {
            return ImportedBrowser(source: source, profiles: .failure(error), defaultEngine: nil)
        }
        let sidebar = sidebarFile.flatMap { file in attempt { try FileAccess.parse(file, with: SidebarFile.init(data:)) } }
        var defaultEngine: SearchEngine?
        var profiles = chromiumProfiles.map { chromiumProfile in
            let folderName = chromiumProfile.folder.lastPathComponent
            let sidebarProfile = sidebar?.map { file in file.profiles.first { $0.folderName == folderName } }
            let bookmarks = attempt { try chromiumProfile.bookmarks() }?.map { $0.split() }
            let searchKeywords = attempt { try chromiumProfile.searchKeywords() }
            if chromiumProfile.isLastUsed { defaultEngine = (try? searchKeywords?.get())?.defaultEngine }
            return ImportedProfile(id: SidebarImport.Profile(source: source.id, folder: folderName), name: chromiumProfile.name,
                                   favorites: joined(sidebarProfile?.map { $0?.favorites ?? [] }, bookmarks?.map { $0.barItems }),
                                   spaces: sidebarProfile?.map { $0?.spaces ?? [] }, bookmarkFolders: bookmarks?.map { $0.folders },
                                   history: attempt { try chromiumProfile.history() }, searchKeywords: searchKeywords)
        }.filter(\.hasItems)
        if !profiles.isEmpty { profiles[0].isFirst = true }
        if case .success(let file)? = sidebar {
            let listedFolders = Set(chromiumProfiles.map(\.folder.lastPathComponent))
            for sidebarProfile in file.profiles where !listedFolders.contains(sidebarProfile.folderName) {
                let profile = ImportedProfile(id: SidebarImport.Profile(source: source.id, folder: sidebarProfile.folderName), name: sidebarProfile.folderName,
                                              favorites: .success(sidebarProfile.favorites), spaces: .success(sidebarProfile.spaces))
                if profile.hasItems { profiles.append(profile) }
            }
        }
        return ImportedBrowser(source: source, profiles: .success(profiles), defaultEngine: defaultEngine)
    }

    /// The one profile of a WebKit-format browser, the default one, named after the browser: the bar's bookmarks as favorites, the other bookmarks as folders, and the history.
    private static func readWebKit(_ source: BrowserSource, bookmarks: URL, history: URL) -> ImportedBrowser {
        let tree = attempt { try FileAccess.parse(bookmarks, with: BookmarkFile.webKitTree(from:)) }?.map { $0.split() }
        var profile = ImportedProfile(id: SidebarImport.Profile(source: source.id, folder: "Default"), name: source.name,
                                      favorites: tree?.map { $0.barItems }, bookmarkFolders: tree?.map { $0.folders },
                                      history: attempt { try FileAccess.read(history, with: HistoryDatabase.historyItemEntries(at:)) })
        profile.isFirst = true
        return ImportedBrowser(source: source, profiles: .success([profile].filter(\.hasItems)), defaultEngine: nil)
    }

    /// What `read` returns, or the error it throws; nil when it returns nil for a missing file.
    private static func attempt<Value>(_ read: () throws -> Value?) -> Result<Value, Error>? {
        do {
            return try read().map { .success($0) }
        } catch {
            return .failure(error)
        }
    }

    /// The items of both parts in order: nil when both are missing, and the first error when either cannot be read, so that part of the items never passes for all of them.
    private static func joined<Item>(_ first: Result<[Item], Error>?, _ second: Result<[Item], Error>?) -> Result<[Item], Error>? {
        let parts = [first, second].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return Result { try parts.flatMap { try $0.get() } }
    }

    private static func isPrivacyDenial(_ error: Error) -> Bool {
        if case .blockedByPrivacy? = error as? ImportError { return true }
        return false
    }
}

/// One profile of a browser, one row of the sheet. Each part is what the profile's files hold, or why they cannot be read; a part the profile lacks or that holds nothing is nil, so the sheet hides it.
struct ImportedProfile: Identifiable {
    /// The profile as the import record keys it, which also identifies the row.
    let id: SidebarImport.Profile
    /// The name the browser shows for the profile.
    let name: String
    /// Whether the profile is the first in its browser's order with something to bring, which makes the current Persona its default destination. The rows for profile folders that only the sidebar file names never are.
    var isFirst = false
    let favorites: Result<[SidebarImport.Item], Error>?
    /// The browser's own spaces, those with pinned tabs or folders: a space with nothing to pin is not made.
    let spaces: Result<[SidebarImport.SourceSpace], Error>?
    /// The bookmark folders, which go into a space named after the browser.
    let bookmarkFolders: Result<[SidebarImport.Folder], Error>?
    let history: Result<[HistoryEntry], Error>?
    /// The search keywords, present only with shortcuts to bring.
    let searchKeywords: Result<SearchKeywords, Error>?

    init(id: SidebarImport.Profile, name: String, favorites: Result<[SidebarImport.Item], Error>? = nil, spaces: Result<[SidebarImport.SourceSpace], Error>? = nil,
         bookmarkFolders: Result<[SidebarImport.Folder], Error>? = nil, history: Result<[HistoryEntry], Error>? = nil, searchKeywords: Result<SearchKeywords, Error>? = nil) {
        self.id = id
        self.name = name
        self.favorites = Self.nonEmpty(favorites)
        self.spaces = Self.nonEmpty(spaces?.map { spaces in spaces.filter { !$0.pinnedItems.isEmpty || !$0.folders.isEmpty } })
        self.bookmarkFolders = Self.nonEmpty(bookmarkFolders)
        self.history = Self.nonEmpty(history)
        self.searchKeywords = searchKeywords.flatMap { keywords in (try? keywords.get())?.shortcuts.isEmpty == true ? nil : keywords }
    }

    /// The items a row offers, in the order the sheet lists them.
    enum Part: CaseIterable {
        case favorites, spaces, bookmarkFolders, history, searchShortcuts
    }

    /// How many items `part` holds, or why it cannot be read; nil when the profile lacks it.
    func count(of part: Part) -> Result<Int, Error>? {
        switch part {
        case .favorites: return favorites?.map(\.count)
        case .spaces: return spaces?.map(\.count)
        case .bookmarkFolders: return bookmarkFolders?.map(\.count)
        case .history: return history?.map(\.count)
        case .searchShortcuts: return searchKeywords?.map(\.shortcuts.count)
        }
    }

    /// The pinned tabs that `part` opens, counted before duplicates are left out: those of the spaces, inside and outside folders, and the bookmarks of the bookmark folders.
    func pinnedTabCount(of part: Part) -> Int {
        switch part {
        case .spaces:
            return (try? spaces?.get())?.reduce(0) { total, space in total + space.pinnedItems.count + space.folders.reduce(0) { $0 + $1.items.count } } ?? 0
        case .bookmarkFolders:
            return (try? bookmarkFolders?.get())?.reduce(0) { $0 + $1.items.count } ?? 0
        case .favorites, .history, .searchShortcuts:
            return 0
        }
    }

    /// What the session adds for the checked parts: the favorites, the browser's spaces, and the bookmark folders in a space named `browserName`.
    func sidebarImport(of parts: Set<Part>, browserName: String) -> SidebarImport {
        var spaces = parts.contains(.spaces) ? (try? self.spaces?.get()) ?? [] : []
        if parts.contains(.bookmarkFolders), let folders = try? bookmarkFolders?.get() {
            spaces.append(SidebarImport.SourceSpace(origin: .bookmarks, name: browserName, tint: nil, pinnedItems: [], folders: folders))
        }
        let favorites = parts.contains(.favorites) ? (try? self.favorites?.get()) ?? [] : []
        return SidebarImport(profile: id, profileName: name, favorites: favorites, spaces: spaces)
    }

    /// Whether the sheet shows the row: it has at least one part, readable or not.
    var hasItems: Bool {
        Part.allCases.contains { count(of: $0) != nil }
    }

    /// Why the parts that cannot be read failed, each reason once, since the parts read from one file share its failure.
    var errors: [Error] {
        var descriptions: Set<String> = []
        return Part.allCases.compactMap { part in
            guard case .failure(let error)? = count(of: part), descriptions.insert(error.localizedDescription).inserted else { return nil }
            return error
        }
    }

    private static func nonEmpty<Items: Collection>(_ part: Result<Items, Error>?) -> Result<Items, Error>? {
        (try? part?.get())?.isEmpty == true ? nil : part
    }
}
