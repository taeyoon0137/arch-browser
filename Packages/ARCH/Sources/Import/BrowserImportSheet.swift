// The sheet of File ▸ Import from Browser…: one section per browser found, with one row per profile that has a destination Persona and a checkbox per item, and the search engine choice below them. Its model keeps the browsers read and the user's choices; the import controller reads the browsers and applies the selection.
import AppKit
import Browsing
import Combine
import History
import SwiftUI

/// The sheet's state: the browsers read, each profile's choices, and the search engine choice.
final class BrowserImportModel: ObservableObject {
    /// Nil until the browsers are read.
    @Published private(set) var browsers: [ImportedBrowser]?
    /// The Personas, kept current while the sheet is open.
    @Published private(set) var personas: [Persona] = []
    /// Each shown profile's choices.
    @Published var choices: [SidebarImport.Profile: Choice] = [:]
    /// The browser whose default engine becomes Arch's, if any.
    @Published var engineBrowserID: BrowserSource.ID?
    /// The browsers whose privacy setting the user went to change. Those still blocked are read again when Arch becomes active, and their sections then say to reopen Arch.
    @Published private(set) var askedBrowserIDs: Set<BrowserSource.ID> = []
    /// What earlier imports made, read when the sheet opens. The default destinations follow it, and Import adds the selection's entries to it.
    let record: SidebarImport.Record
    /// The Persona of the window that shows the sheet, which each browser's first profile goes to by default.
    let currentPersonaID: Persona.ID
    private var personasSubscription: AnyCancellable?
    private var icons: [BrowserSource.ID: NSImage] = [:]

    /// Each imported pinned tab loads whenever Arch opens, so the parts that bring pinned tabs start checked only up to this many in all.
    static let pinnedTabLimit = 50

    /// Whether a profile is included, where it goes, and which of its parts are checked.
    struct Choice: Equatable {
        var isIncluded = true
        var destination: SidebarImport.Destination
        var parts: Set<ImportedProfile.Part>
    }

    /// `personas` publishes the session's Personas, starting with the current ones.
    init(personas: some Publisher<[Persona], Never>, currentPersonaID: Persona.ID, record: SidebarImport.Record) {
        self.currentPersonaID = currentPersonaID
        self.record = record
        personasSubscription = personas.sink { [weak self] in self?.update($0) }
    }

    /// Shows the browsers read, with each profile's choices at their defaults.
    func show(_ browsers: [ImportedBrowser]) {
        self.browsers = browsers
        browsers.forEach(setDefaultChoices)
    }

    /// Shows a browser read again in place of the earlier reading, with its profiles' choices at their defaults.
    func replace(_ browser: ImportedBrowser) {
        guard let index = browsers?.firstIndex(where: { $0.id == browser.id }) else { return }
        browsers?[index] = browser
        setDefaultChoices(for: browser)
    }

    /// Notes that the user went to change the browser's privacy setting.
    func markAsked(_ browser: ImportedBrowser) {
        askedBrowserIDs.insert(browser.id)
    }

    /// The browsers to read again when Arch becomes active: those whose setting the user went to change and that are still blocked.
    var browsersToReread: [ImportedBrowser] {
        (browsers ?? []).filter { askedBrowserIDs.contains($0.id) && $0.isBlockedByPrivacy }
    }

    /// The pinned tabs that the checked parts of the included profiles open, before duplicates are left out.
    var checkedPinnedTabCount: Int {
        includedProfiles.reduce(0) { total, included in total + included.choice.parts.reduce(0) { $0 + included.profile.pinnedTabCount(of: $1) } }
    }

    /// Import needs a checked item: a part of an included profile, or the search engine.
    var canImport: Bool {
        includedProfiles.contains { !$0.choice.parts.isEmpty } || chosenEngine != nil
    }

    /// The browsers that offer their default engine because it is not Arch's already.
    var engineOffers: [ImportedBrowser] {
        (browsers ?? []).filter { browser in browser.defaultEngine.map { $0 != SearchEngine.current } ?? false }
    }

    /// The destinations each profile's menu lists: the current Persona, the other Personas, and a new Persona named after the profile.
    var destinations: [SidebarImport.Destination] {
        (personas.filter { $0.id == currentPersonaID } + personas.filter { $0.id != currentPersonaID }).map { .persona($0.id) } + [.newPersona]
    }

    /// The title of `destination` in the menu of `profile`.
    func title(of destination: SidebarImport.Destination, for profile: ImportedProfile) -> String {
        switch destination {
        case .persona(let id): return personas.first { $0.id == id }?.name ?? ""
        case .newPersona: return "New Persona \u{201C}\(profile.name)\u{201D}"
        }
    }

    /// The browser's app icon, or nil when the app is not installed.
    func icon(for source: BrowserSource) -> NSImage? {
        if let icon = icons[source.id] { return icon }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icons[source.id] = icon
        return icon
    }

    // MARK: Selection

    /// What Import applies, from the included profiles in sheet order.
    struct Selection {
        /// The profiles that bring favorites or spaces, each with its destination. A profile that brings only history or shortcuts goes to no Persona.
        var rows: [(row: SidebarImport, destination: SidebarImport.Destination)] = []
        var shortcuts: [SiteSearchShortcut] = []
        /// The checked profiles' shortcuts that Arch cannot use (`SearchKeywords.skippedCount`).
        var skippedShortcutCount = 0
        var history: [HistoryEntry] = []
        var searchEngine: SearchEngine?
        /// Why parts of the included profiles with checked items could not be read, each reason once per profile. A profile with nothing checked and a browser whose profiles cannot be read bring nothing, and the sheet showed why.
        var failures: [String] = []
    }

    /// The selection as the sheet's choices stand.
    var selection: Selection {
        var selection = Selection()
        for (browser, profile, choice) in includedProfiles where !choice.parts.isEmpty {
            let row = profile.sidebarImport(of: choice.parts, browserName: browser.source.name)
            if !row.favorites.isEmpty || !row.spaces.isEmpty { selection.rows.append((row, choice.destination)) }
            if choice.parts.contains(.history), let history = try? profile.history?.get() { selection.history += history }
            if choice.parts.contains(.searchShortcuts), let keywords = try? profile.searchKeywords?.get() {
                selection.shortcuts += keywords.shortcuts
                selection.skippedShortcutCount += keywords.skippedCount
            }
            selection.failures += profile.errors.map { "\(browser.source.name) \u{25B8} \(profile.name): \($0.localizedDescription)" }
        }
        selection.searchEngine = chosenEngine
        return selection
    }

    // MARK: Choices

    /// The included profiles with their choices, in sheet order.
    private var includedProfiles: [(browser: ImportedBrowser, profile: ImportedProfile, choice: Choice)] {
        (browsers ?? []).flatMap { browser -> [(browser: ImportedBrowser, profile: ImportedProfile, choice: Choice)] in
            guard case .success(let profiles) = browser.profiles else { return [] }
            return profiles.compactMap { profile in
                guard let choice = choices[profile.id], choice.isIncluded else { return nil }
                return (browser, profile, choice)
            }
        }
    }

    /// The engine the user checked, while its browser still offers it.
    private var chosenEngine: SearchEngine? {
        engineOffers.first { $0.id == engineBrowserID }?.defaultEngine
    }

    /// Includes each of the browser's profiles with its default destination and its readable parts checked, except that a part that brings pinned tabs starts checked only when, with the parts checked before it in sheet order, it adds at most `pinnedTabLimit` of them.
    private func setDefaultChoices(for browser: ImportedBrowser) {
        guard case .success(let profiles) = browser.profiles else { return }
        profiles.forEach { choices[$0.id] = nil }
        var pinnedTabCount = checkedPinnedTabCount
        for profile in profiles {
            var parts: Set<ImportedProfile.Part> = []
            for part in ImportedProfile.Part.allCases {
                guard case .success? = profile.count(of: part) else { continue }
                let partPinnedTabCount = profile.pinnedTabCount(of: part)
                guard partPinnedTabCount == 0 || pinnedTabCount + partPinnedTabCount <= Self.pinnedTabLimit else { continue }
                pinnedTabCount += partPinnedTabCount
                parts.insert(part)
            }
            let destination = profile.sidebarImport(of: [], browserName: browser.source.name)
                .defaultDestination(record: record, personas: personas, currentPersonaID: currentPersonaID, isFirstProfile: profile.isFirst)
            choices[profile.id] = Choice(destination: destination, parts: parts)
        }
    }

    /// Takes the session's Personas. A destination Persona deleted while the sheet is open gives way to a new Persona, as Import would make one.
    private func update(_ personas: [Persona]) {
        self.personas = personas
        for (profile, choice) in choices {
            if case .persona(let id) = choice.destination, !personas.contains(where: { $0.id == id }) {
                choices[profile]?.destination = .newPersona
            }
        }
    }
}

/// The sheet's view of a `BrowserImportModel`.
struct BrowserImportSheet: View {
    @ObservedObject var model: BrowserImportModel
    let actions: Actions

    /// What the sheet's buttons do, which the import controller supplies.
    struct Actions {
        var importSelection: () -> Void
        var cancel: () -> Void
        var openPrivacySetting: (ImportedBrowser) -> Void
        var chooseExportedFile: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Browser")
                .font(.headline)
            if let browsers = model.browsers {
                if browsers.isEmpty {
                    Text("No other browsers were found on this Mac.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(browsers) { BrowserSection(model: model, browser: $0, actions: actions) }
                            engineChoices
                        }
                    }
                    .frame(maxHeight: 520)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for browsers\u{2026}")
                        .foregroundStyle(.secondary)
                }
            }
            if model.checkedPinnedTabCount > BrowserImportModel.pinnedTabLimit {
                Label("The checked items add \(model.checkedPinnedTabCount.formatted()) pinned tabs, which load each time Arch opens.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            buttons
        }
        .padding(20)
        .frame(width: 540)
    }

    /// "Use <engine> as the search engine, as in <browser>" for each browser that offers its engine. Checking one unchecks the others.
    @ViewBuilder private var engineChoices: some View {
        ForEach(model.engineOffers) { browser in
            if let engine = browser.defaultEngine {
                Toggle("Use \(engine.title) as the search engine, as in \(browser.source.name)", isOn: Binding {
                    model.engineBrowserID == browser.id
                } set: { isOn in
                    model.engineBrowserID = isOn ? browser.id : nil
                })
                .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if model.browsers?.isEmpty == true {
                Button("Choose Exported File\u{2026}", action: actions.chooseExportedFile)
                Spacer()
                Button("Close", action: actions.cancel)
                    .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Cancel", role: .cancel, action: actions.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: actions.importSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
            }
        }
    }
}

/// A browser's section: its icon and name, the privacy setting it needs when macOS blocks its files, and its profiles.
private struct BrowserSection: View {
    @ObservedObject var model: BrowserImportModel
    let browser: ImportedBrowser
    let actions: BrowserImportSheet.Actions

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if browser.isBlockedByPrivacy {
                    privacyNotice
                }
                switch browser.profiles {
                case .failure(let error):
                    if !browser.isBlockedByPrivacy {
                        Text(error.localizedDescription)
                            .foregroundStyle(.secondary)
                    }
                case .success(let profiles):
                    if profiles.isEmpty {
                        Text("No bookmarks, history, or search shortcuts were found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(profiles) { ProfileRow(model: model, browser: browser, profile: $0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label {
                Text(browser.source.name)
                    .font(.headline)
            } icon: {
                if let icon = model.icon(for: browser.source) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "globe")
                }
            }
        }
    }

    /// Names the setting that lets Arch read the browser's files, with a way to it and the file import as the other way. After the user went to the setting, the sheet reads the browser again on returning; when the files are still blocked, the grant may apply only after Arch reopens.
    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Arch needs \(browser.source.privacySetting.name) to read \(browser.source.name)\u{2019}s bookmarks and history."
                 + (model.askedBrowserIDs.contains(browser.id) ? " If you turned it on, quit and reopen Arch." : ""))
            HStack {
                Button("Open System Settings") { actions.openPrivacySetting(browser) }
                Button("Choose Exported File\u{2026}", action: actions.chooseExportedFile)
            }
        }
    }
}

/// A profile's row: a checkbox with its name, its destination menu, and a checkbox per part.
private struct ProfileRow: View {
    @ObservedObject var model: BrowserImportModel
    let browser: ImportedBrowser
    let profile: ImportedProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: choice.isIncluded) {
                    Text(profile.name)
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Picker("Persona", selection: choice.destination) {
                    ForEach(model.destinations, id: \.self) { Text(model.title(of: $0, for: profile)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ImportedProfile.Part.allCases.filter { profile.count(of: $0) != nil }, id: \.self, content: partToggle)
            }
            .padding(.leading, 20)
            .disabled(!choice.wrappedValue.isIncluded)
        }
    }

    /// The profile's choice, which the model holds for each profile it shows.
    private var choice: Binding<BrowserImportModel.Choice> {
        Binding {
            model.choices[profile.id] ?? BrowserImportModel.Choice(isIncluded: false, destination: .newPersona, parts: [])
        } set: {
            model.choices[profile.id] = $0
        }
    }

    /// A part's checkbox with its count, or, for a part that cannot be read, unchecked and disabled with the reason.
    private func partToggle(_ part: ImportedProfile.Part) -> some View {
        let count = profile.count(of: part)
        let note: String?
        if case .failure(let error)? = count {
            note = error.localizedDescription
        } else {
            switch part {
            case .spaces, .bookmarkFolders: note = "Each pinned tab loads whenever Arch opens."
            case .history, .searchShortcuts: note = "Applies to every Persona."
            case .favorites: note = nil
            }
        }
        return Toggle(isOn: Binding {
            choice.wrappedValue.parts.contains(part)
        } set: { isOn in
            if isOn { choice.wrappedValue.parts.insert(part) } else { choice.wrappedValue.parts.remove(part) }
        }) {
            VStack(alignment: .leading, spacing: 1) {
                Text((try? count?.get()).map { Self.title(of: part, count: $0, pinnedTabCount: profile.pinnedTabCount(of: part)) } ?? Self.name(of: part))
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled((try? count?.get()) == nil)
    }

    private static func name(of part: ImportedProfile.Part) -> String {
        switch part {
        case .favorites: return "Favorites"
        case .spaces: return "Spaces"
        case .bookmarkFolders: return "Bookmark Folders"
        case .history: return "History"
        case .searchShortcuts: return "Search Shortcuts"
        }
    }

    /// Such as "Spaces (3) with 24 pinned tabs" or "History (5,210 pages)".
    private static func title(of part: ImportedProfile.Part, count: Int, pinnedTabCount: Int) -> String {
        switch part {
        case .favorites, .searchShortcuts: return "\(name(of: part)) (\(count.formatted()))"
        case .spaces: return "Spaces (\(count.formatted())) with \(ImportSummary.count(pinnedTabCount, "pinned tab", "pinned tabs"))"
        case .bookmarkFolders: return "Bookmark Folders (\(count.formatted())) with \(ImportSummary.count(pinnedTabCount, "bookmark", "bookmarks"))"
        case .history: return "History (\(ImportSummary.count(count, "page", "pages")))"
        }
    }
}
