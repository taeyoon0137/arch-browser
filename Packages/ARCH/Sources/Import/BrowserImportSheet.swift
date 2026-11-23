// File ▸ Import from Browser… shows one section per browser and one row per profile with a destination Persona.
// Each item has a checkbox, and search engines appear below the profiles. The sheet model holds the read browsers and user choices.
// The import controller reads the source browsers and applies the selection.
import AppKit
import Browsing
import Combine
import History
import SwiftUI

/// The sheet's state: the browsers read, each profile's choices, and the search engine choice.
@MainActor final class BrowserImportModel: ObservableObject {
    /// Nil until the browsers are read.
    @Published private(set) var browsers: [ImportedBrowser]?
    /// The Personas, kept current while the sheet is open.
    @Published private(set) var personas: [Persona] = []
    /// Each shown profile's choices.
    @Published var choices: [SidebarImport.Profile: Choice] = [:]
    /// The engine that becomes Arch's, if any. It applies only while a browser still offers it.
    @Published var chosenEngine: SearchEngine?
    /// The browsers whose privacy setting the user went to change. Those still blocked are read again when Arch becomes active, and their sections then say to reopen Arch.
    @Published private(set) var askedBrowserIDs: Set<BrowserSource.ID> = []
    /// What earlier imports made, read when the sheet opens. The default destinations follow it, and Import adds the selection's entries to it.
    let record: SidebarImport.Record
    /// The Persona of the window that shows the sheet, which each browser's first profile goes to by default.
    let currentPersonaID: Persona.ID
    private var personasSubscription: AnyCancellable?
    private var icons: [BrowserSource.ID: NSImage] = [:]

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

    /// Import needs a checked item: a part of an included profile, or the search engine.
    var canImport: Bool {
        includedProfiles.contains { !$0.choice.parts.isEmpty } || appliedEngine != nil
    }

    /// The browsers that offer their default engine because it is not Arch's already.
    var engineOffers: [ImportedBrowser] {
        (browsers ?? []).filter { browser in browser.defaultEngine.map { $0 != SearchEngine.current } ?? false }
    }

    /// Each engine the browsers offer, once, in sheet order, with the names of the browsers that offer it. Two browsers on one engine give one choice.
    var engineChoices: [(engine: SearchEngine, browsers: [String])] {
        var choices: [(engine: SearchEngine, browsers: [String])] = []
        for browser in engineOffers {
            guard let engine = browser.defaultEngine else { continue }
            if let index = choices.firstIndex(where: { $0.engine == engine }) {
                choices[index].browsers.append(browser.source.name)
            } else {
                choices.append((engine, [browser.source.name]))
            }
        }
        return choices
    }

    /// The destinations each profile's menu lists: the current Persona, the other Personas, and a new Persona named after the profile.
    var destinations: [SidebarImport.Destination] {
        (personas.filter { $0.id == currentPersonaID } + personas.filter { $0.id != currentPersonaID }).map { .persona($0.id) } + [.newPersona]
    }

    /// The title of `destination` in the menu of `profile`.
    func title(of destination: SidebarImport.Destination, for profile: ImportedProfile) -> String {
        switch destination {
        case .persona(let id): return personas.first { $0.id == id }?.name ?? ""
        case .newPersona: return localized("New Persona \u{201C}\(profile.name)\u{201D}")
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
        /// The profiles that bring favorites, spaces, or history pages, each with its destination and its history pages, which go to the destination Persona. A profile that brings only shortcuts goes to no Persona.
        var rows: [(row: SidebarImport, destination: SidebarImport.Destination, history: [HistoryEntry])] = []
        var shortcuts: [SiteSearchShortcut] = []
        /// The checked profiles' shortcuts that Arch cannot use (`SearchKeywords.skippedCount`).
        var skippedShortcutCount = 0
        var searchEngine: SearchEngine?
        /// Why parts of the included profiles with checked items could not be read, each reason once per profile. A profile with nothing checked and a browser whose profiles cannot be read bring nothing, and the sheet showed why.
        var failures: [String] = []
    }

    /// The selection as the sheet's choices stand.
    var selection: Selection {
        var selection = Selection()
        for (browser, profile, choice) in includedProfiles where !choice.parts.isEmpty {
            let row = profile.sidebarImport(of: choice.parts, browserName: browser.source.name)
            let history = choice.parts.contains(.history) ? (try? profile.history?.get()) ?? [] : []
            if !row.favorites.isEmpty || !row.spaces.isEmpty || !history.isEmpty { selection.rows.append((row, choice.destination, history)) }
            if choice.parts.contains(.searchShortcuts), let keywords = try? profile.searchKeywords?.get() {
                selection.shortcuts += keywords.shortcuts
                selection.skippedShortcutCount += keywords.skippedCount
            }
            selection.failures += profile.errors.map { "\(browser.source.name) \u{25B8} \(profile.name): \($0.localizedDescription)" }
        }
        selection.searchEngine = appliedEngine
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

    /// The engine the user chose, while a browser still offers it.
    private var appliedEngine: SearchEngine? {
        engineChoices.contains { $0.engine == chosenEngine } ? chosenEngine : nil
    }

    /// Includes each profile with its readable parts checked and its default destination.
    private func setDefaultChoices(for browser: ImportedBrowser) {
        guard case .success(let profiles) = browser.profiles else { return }
        for profile in profiles {
            let parts = Set(ImportedProfile.Part.allCases.filter { part in
                if case .success? = profile.count(of: part) { return true }
                return false
            })
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
            Text("Import from Browser", bundle: .module)
                .font(.headline)
            if let browsers = model.browsers {
                if browsers.isEmpty {
                    Text("No other browsers were found on this Mac.", bundle: .module)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(browsers) { BrowserSection(model: model, browser: $0, actions: actions) }
                            if !model.engineChoices.isEmpty { engineSection }
                        }
                    }
                    .frame(maxHeight: 520)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for browsers\u{2026}", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            }
            buttons
        }
        .padding(20)
        .frame(width: 540)
    }

    /// A section of its own after the browsers', labeled as theirs are. One engine is a checkbox, "Use <engine> as the search engine, as in <browsers>". Two engines are exclusive choices, so they are radio buttons after one that keeps Arch's engine.
    private var engineSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if model.engineChoices.count == 1, let choice = model.engineChoices.first {
                    Toggle(localized("Use \(choice.engine.title) as the search engine, as in \(choice.browsers.formatted(.list(type: .and)))"), isOn: Binding {
                        model.chosenEngine == choice.engine
                    } set: { isOn in
                        model.chosenEngine = isOn ? choice.engine : nil
                    })
                    .toggleStyle(.checkbox)
                } else {
                    Picker(localized("Search engine"), selection: $model.chosenEngine) {
                        Text("Keep \(SearchEngine.current.title)", bundle: .module).tag(SearchEngine?.none)
                        ForEach(model.engineChoices, id: \.engine) { choice in
                            Text("Use \(choice.engine.title), as in \(choice.browsers.formatted(.list(type: .and)))", bundle: .module).tag(Optional(choice.engine))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .accessibilityLabel(localized("Search engine"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            // A symbol in the app icons' box, so that its name starts where the browsers' names do.
            Label {
                Text("Search Engine", bundle: .module)
                    .font(.headline)
            } icon: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if model.browsers?.isEmpty == true {
                Button(localized("Choose Exported File\u{2026}"), action: actions.chooseExportedFile)
                Spacer()
                Button(localized("Close"), action: actions.cancel)
                    .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button(localized("Cancel"), role: .cancel, action: actions.cancel)
                    .keyboardShortcut(.cancelAction)
                Button(localized("Import"), action: actions.importSelection)
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
                        Text("No bookmarks, history, or search shortcuts were found.", bundle: .module)
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
                // The symbol takes the app icon's box, so that every section's name starts at one place.
                if let icon = model.icon(for: browser.source) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 15))
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// Names the setting that lets Arch read the browser's files, with a way to it and the file import as the other way. After the user went to the setting, the sheet reads the browser again on returning; when the files are still blocked, the grant may apply only after Arch reopens.
    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("Arch needs \(browser.source.privacySetting.name) to read \(browser.source.name)\u{2019}s bookmarks and history.")
                 + (model.askedBrowserIDs.contains(browser.id) ? " " + localized("If you turned it on, quit and reopen Arch.") : ""))
            HStack {
                Button(localized("Open System Settings")) { actions.openPrivacySetting(browser) }
                Button(localized("Choose Exported File\u{2026}"), action: actions.chooseExportedFile)
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .toggleStyle(.checkbox)
                Spacer()
                // The existing Personas, then the one the import would create. The menu applies only to a checked profile that brings favorites, spaces, bookmark folders, or history; search shortcuts go to every Persona.
                Picker(localized("Persona"), selection: choice.destination) {
                    ForEach(model.destinations.filter { $0 != .newPersona }, id: \.self) { Text(model.title(of: $0, for: profile)).tag($0) }
                    Divider()
                    Text(model.title(of: .newPersona, for: profile)).tag(SidebarImport.Destination.newPersona)
                }
                .labelsHidden()
                .accessibilityLabel(localized("Persona"))
                .fixedSize()
                .disabled(!choice.wrappedValue.isIncluded || choice.wrappedValue.parts.isDisjoint(with: [.favorites, .spaces, .bookmarkFolders, .history]))
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
            case .spaces: note = localized("Pinned tabs load when you open them.")
            case .bookmarkFolders: note = localized("Each bookmark becomes a pinned tab. It loads when you open it.")
            case .searchShortcuts: note = localized("Applies to every Persona.")
            case .favorites, .history: note = nil
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
        case .favorites: return localized("Favorites")
        case .spaces: return localized("Spaces")
        case .bookmarkFolders: return localized("Bookmark Folders")
        case .history: return localized("History")
        case .searchShortcuts: return localized("Search Shortcuts")
        }
    }

    /// Such as "Spaces (3) with 24 pinned tabs" or "History (5,210 pages)".
    private static func title(of part: ImportedProfile.Part, count: Int, pinnedTabCount: Int) -> String {
        switch part {
        case .favorites, .searchShortcuts: return "\(name(of: part)) (\(count.formatted()))"
        case .spaces: return localized("Spaces (\(count.formatted())) with \(ImportSummary.count(pinnedTabCount, { localized("\($0) pinned tab") }, { localized("\($0) pinned tabs") }))")
        case .bookmarkFolders: return localized("Bookmark Folders (\(count.formatted())) with \(ImportSummary.count(pinnedTabCount, { localized("\($0) bookmark") }, { localized("\($0) bookmarks") }))")
        case .history: return localized("History (\(ImportSummary.count(count, { localized("\($0) page") }, { localized("\($0) pages") })))")
        }
    }
}
