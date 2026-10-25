// The browser import sheet's choices on browsers built as values: which parts start checked under the pinned tab limit, where each profile goes by default and after its Persona is deleted, and what Import applies. Rows hold made-up addresses only.
import Combine
import Foundation
import History
import Testing
@testable import Browsing
@testable import Import

@Suite struct BrowserImportModelTests {
    private static let work = Persona(name: "Work")
    private static let source = BrowserSource(name: "Test Browser", bundleIdentifier: "test.browser",
                                              layout: .chromium(userData: URL(fileURLWithPath: "/nonexistent"), sidebarFile: nil), privacySetting: .fullDiskAccess)

    /// `count` items whose IDs and hosts start with `prefix`, which may be a profile folder's name.
    private static func items(_ prefix: String, _ count: Int) -> [SidebarImport.Item] {
        let host = prefix.lowercased().replacingOccurrences(of: " ", with: "-")
        return (0..<count).map { SidebarImport.Item(sourceID: "\(prefix)\($0)", url: URL(string: "https://\(host)-\($0).example/")!, title: "\(prefix)\($0)") }
    }

    private static func space(_ prefix: String, pinnedTabs: Int) -> SidebarImport.SourceSpace {
        SidebarImport.SourceSpace(origin: .space(prefix), name: prefix, tint: nil, pinnedItems: items(prefix, pinnedTabs), folders: [])
    }

    private static func folder(_ prefix: String, bookmarks: Int) -> SidebarImport.Folder {
        SidebarImport.Folder(sourceID: prefix, name: prefix, items: items(prefix, bookmarks))
    }

    private static func profile(_ folder: String, name: String? = nil, isFirst: Bool = false, favorites: Int = 0, spaces: [SidebarImport.SourceSpace] = [],
                                bookmarkFolders: [SidebarImport.Folder] = [], history: [HistoryEntry] = [], searchKeywords: Result<SearchKeywords, Error>? = nil) -> ImportedProfile {
        var profile = ImportedProfile(id: SidebarImport.Profile(source: source.id, folder: folder), name: name ?? folder, favorites: .success(items(folder, favorites)),
                                      spaces: .success(spaces), bookmarkFolders: .success(bookmarkFolders), history: .success(history), searchKeywords: searchKeywords)
        profile.isFirst = isFirst
        return profile
    }

    private static func model(_ browsers: [ImportedBrowser], personas: CurrentValueSubject<[Persona], Never> = CurrentValueSubject([Persona(id: Persona.defaultID, name: "Default"), work]),
                              record: SidebarImport.Record = emptyRecord()) -> BrowserImportModel {
        let model = BrowserImportModel(personas: personas, currentPersonaID: Persona.defaultID, record: record)
        model.show(browsers)
        return model
    }

    /// A record in a folder that does not exist, as on a first import. The model never writes it.
    private static func emptyRecord() -> SidebarImport.Record {
        SidebarImport.Record(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)"))
    }

    /// Search keywords with one shortcut Arch can use and one it cannot, read from a synthetic `Web Data` database.
    private static func searchKeywords(in folder: TemporaryFolder) throws -> SearchKeywords {
        let file = try folder.database("Web Data", [
            ChromiumDatabases.keywordsTable,
            ChromiumDatabases.keyword("Docs", "d", "https://docs.example/?q={searchTerms}"),
            ChromiumDatabases.keyword("Spaced", "two words", "https://spaced.example/?q={searchTerms}"),
        ])
        return try SearchKeywords.read(at: file, preferences: nil)
    }

    @Test func partsWithPinnedTabsStartCheckedUpToTheLimitInSheetOrder() throws {
        let browser = ImportedBrowser(source: Self.source, profiles: .success([
            Self.profile("Default", isFirst: true, favorites: 2, spaces: [Self.space("home", pinnedTabs: 30)]),
            Self.profile("Profile 2", bookmarkFolders: [Self.folder("docs", bookmarks: 30)], history: [HistoryEntry(url: URL(string: "https://h.example/")!, title: "", visitCount: 1, lastVisit: Date())]),
            Self.profile("Profile 3", spaces: [Self.space("small", pinnedTabs: 10)]),
        ]), defaultEngine: nil)
        let model = Self.model([browser])
        func parts(_ folder: String) -> Set<ImportedProfile.Part>? {
            model.choices[SidebarImport.Profile(source: Self.source.id, folder: folder)]?.parts
        }
        #expect(parts("Default") == [.favorites, .spaces])
        // Its 30 pinned tabs would pass the limit, but a later part that fits still starts checked.
        #expect(parts("Profile 2") == [.history])
        #expect(parts("Profile 3") == [.spaces])
        #expect(model.checkedPinnedTabCount == 40)
        #expect(model.canImport)

        let second = SidebarImport.Profile(source: Self.source.id, folder: "Profile 2")
        model.choices[second]?.parts.insert(.bookmarkFolders)
        #expect(model.checkedPinnedTabCount == 70)
        // An excluded profile's parts do not count.
        model.choices[second]?.isIncluded = false
        #expect(model.checkedPinnedTabCount == 40)
    }

    @Test func profilesGoToTheirRecordedOrSameNamedPersonaAndADeletedOneGivesWayToANewPersona() throws {
        let other = Persona(name: "Other")
        let personas = CurrentValueSubject<[Persona], Never>([Persona(id: Persona.defaultID, name: "Default"), Self.work, other])
        var record = Self.emptyRecord()
        let recorded = SidebarImport.Profile(source: Self.source.id, folder: "Profile 3")
        record.update(SidebarImport.Record.Entry(profile: recorded, personaID: other.id, personas: []))
        let browser = ImportedBrowser(source: Self.source, profiles: .success([
            Self.profile("Default", name: "Personal", isFirst: true, favorites: 1),
            Self.profile("Profile 2", name: "Work", favorites: 1),
            Self.profile("Profile 3", name: "Recorded", favorites: 1),
            Self.profile("Profile 4", name: "New", favorites: 1),
        ]), defaultEngine: nil)
        let model = Self.model([browser], personas: personas, record: record)
        func destination(_ folder: String) -> SidebarImport.Destination? {
            model.choices[SidebarImport.Profile(source: Self.source.id, folder: folder)]?.destination
        }
        #expect(destination("Default") == .persona(Persona.defaultID))
        #expect(destination("Profile 2") == .persona(Self.work.id))
        #expect(destination("Profile 3") == .persona(other.id))
        #expect(destination("Profile 4") == .newPersona)
        #expect(model.destinations == [.persona(Persona.defaultID), .persona(Self.work.id), .persona(other.id), .newPersona])
        let profiles = try browser.profiles.get()
        #expect(model.title(of: .newPersona, for: profiles[3]) == "New Persona \u{201C}New\u{201D}")
        #expect(model.title(of: .persona(Self.work.id), for: profiles[3]) == "Work")

        personas.send([Persona(id: Persona.defaultID, name: "Default"), other])
        #expect(destination("Profile 2") == .newPersona)
        #expect(destination("Profile 3") == .persona(other.id))
        #expect(model.destinations == [.persona(Persona.defaultID), .persona(other.id), .newPersona])
    }

    @Test func theSelectionTakesTheCheckedPartsOfTheIncludedProfilesInOrder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let entry = HistoryEntry(url: URL(string: "https://h.example/")!, title: "H", visitCount: 2, lastVisit: Date())
        let unreadable = ImportError.unreadableFile(folder.url.appendingPathComponent("Sidebar.json"))
        let blockedHistory = ImportError.blockedByPrivacy(folder.url.appendingPathComponent("History.db"))
        let browser = ImportedBrowser(source: Self.source, profiles: .success([
            Self.profile("Default", isFirst: true, favorites: 1, spaces: [Self.space("home", pinnedTabs: 1)], bookmarkFolders: [Self.folder("docs", bookmarks: 1)]),
            Self.profile("Profile 2", history: [entry], searchKeywords: .success(try Self.searchKeywords(in: folder))),
            Self.profile("Profile 3", favorites: 1),
            // Its favorites and spaces come from one file that cannot be read.
            ImportedProfile(id: SidebarImport.Profile(source: Self.source.id, folder: "Profile 4"), name: "Profile 4", favorites: .failure(unreadable), spaces: .failure(unreadable), history: .success([entry])),
            // Nothing in it can be checked, so it brings nothing.
            ImportedProfile(id: SidebarImport.Profile(source: Self.source.id, folder: "Profile 5"), name: "Profile 5", history: .failure(blockedHistory)),
        ]), defaultEngine: nil)
        let blocked = BrowserSource(name: "Other Browser", bundleIdentifier: "test.other", layout: .chromium(userData: folder.url, sidebarFile: nil), privacySetting: .fullDiskAccess)
        let localState = folder.url.appendingPathComponent("Local State")
        let model = Self.model([browser, ImportedBrowser(source: blocked, profiles: .failure(ImportError.blockedByPrivacy(localState)), defaultEngine: nil)])
        #expect(model.browsers?.last?.isBlockedByPrivacy == true)
        model.choices[SidebarImport.Profile(source: Self.source.id, folder: "Default")]?.parts.remove(.favorites)
        model.choices[SidebarImport.Profile(source: Self.source.id, folder: "Profile 3")]?.isIncluded = false

        let selection = model.selection
        // Only the first profile brings sidebar items: its space, and its bookmark folders in a space named after the browser.
        #expect(selection.rows.map(\.row.profile.folder) == ["Default"])
        #expect(selection.rows.first?.row.favorites.isEmpty == true)
        #expect(selection.rows.first?.row.spaces.map(\.origin) == [.space("home"), .bookmarks])
        #expect(selection.rows.first?.row.spaces.last?.name == "Test Browser")
        #expect(selection.rows.first?.destination == .persona(Persona.defaultID))
        #expect(selection.history.map(\.url) == [entry.url, entry.url])
        #expect(selection.shortcuts.map(\.keyword) == ["d"])
        #expect(selection.skippedShortcutCount == 1)
        #expect(selection.searchEngine == nil)
        // Only the profiles that bring something report what could not be read, each reason once; the browser whose profiles cannot be read brings nothing.
        #expect(selection.failures == ["Test Browser \u{25B8} Profile 4: \(unreadable.localizedDescription)"])
    }

    @Test func aBrowserOffersItsEngineOnlyWhenItIsNotArchsAlready() throws {
        let otherEngine = try #require(SearchEngine.allCases.first { $0 != SearchEngine.current })
        let offering = ImportedBrowser(source: Self.source, profiles: .success([Self.profile("Default", isFirst: true)]), defaultEngine: otherEngine)
        let sameSource = BrowserSource(name: "Same Engine", bundleIdentifier: "test.same", layout: Self.source.layout, privacySetting: .fullDiskAccess)
        let same = ImportedBrowser(source: sameSource, profiles: .success([]), defaultEngine: SearchEngine.current)
        let model = Self.model([offering, same])
        #expect(model.engineOffers.map(\.id) == [Self.source.id])
        // The profile brings nothing, so only the engine can make Import do something.
        #expect(!model.canImport)
        model.engineBrowserID = Self.source.id
        #expect(model.canImport)
        #expect(model.selection.searchEngine == otherEngine)
        model.engineBrowserID = sameSource.id
        #expect(model.selection.searchEngine == nil)
    }

    @Test func aBrowserReadAgainTakesItsDefaultChoicesAgain() throws {
        let localState = URL(fileURLWithPath: "/nonexistent/Local State")
        let model = Self.model([ImportedBrowser(source: Self.source, profiles: .failure(ImportError.blockedByPrivacy(localState)), defaultEngine: nil)])
        model.markAsked(try #require(model.browsers?.first))
        #expect(model.browsersToReread.map(\.id) == [Self.source.id])
        #expect(model.choices.isEmpty)

        model.replace(ImportedBrowser(source: Self.source, profiles: .success([Self.profile("Default", isFirst: true, favorites: 1)]), defaultEngine: nil))
        #expect(model.browsersToReread.isEmpty)
        #expect(model.choices[SidebarImport.Profile(source: Self.source.id, folder: "Default")] == BrowserImportModel.Choice(destination: .persona(Persona.defaultID), parts: [.favorites]))
    }
}
