// New Live Folder… and Edit Live Folder… (`docs/bookmarks.md`, Live folders ▸ Interface; live folder rules 2, 3, 7, and 8): a sheet on the window that chooses a feed, found at the address the user gives, or a GitHub search that the user's `gh` runs, with the folder's name, item limit, and refresh interval. `LiveFolderSheetModel` holds what the sheet shows and decides, so tests drive it with stubbed lookups; `LiveFolderSheetView` draws it; `BrowserWindowModel` presents it, and the session applies what Add or Save hands over (`LiveFolderTabs.swift`).
import AppKit
import LiveFolders
import SwiftUI

/// What New Live Folder… and Edit Live Folder… show and decide. Nothing reaches the session until Add or Save hands a `Submission` to `commit`.
@MainActor
final class LiveFolderSheetModel: ObservableObject {
    enum Purpose: Equatable {
        case new(spaceID: UUID)
        case edit(folderID: UUID)
    }

    enum SourceKind: Hashable {
        case feed
        case gitHub
    }

    /// `gh`'s state for a host, as `GitHubCLI` reports it.
    enum GitHubState: Equatable {
        case checking
        /// The Host field names no host that `gh --hostname` takes.
        case invalidHost
        case checked(GitHubCLIStatus, host: String)
    }

    /// The folder that Add makes or Save changes.
    struct Submission: Equatable {
        var name: String
        var configuration: LiveFolderConfiguration
        /// A private feed's whole address, which goes to the Keychain before the folder registers (live folder rule 8), or nil when the Keychain has nothing new to keep.
        var keychainAddress: URL?

        /// A new live folder in the space's pinned list, at the top level, expanded.
        func newFolder(in spaceID: UUID) -> TabFolder {
            var folder = TabFolder(spaceID: spaceID, name: name, isPinned: true)
            folder.live = configuration
            return folder
        }

        /// Edit Live Folder…'s change. Registering the changed configuration starts the folder over when its source changed (`LiveFolderService.register(_:)`).
        func apply(to folder: inout TabFolder) {
            folder.name = name
            folder.live = configuration
        }
    }

    /// A feed address the user gave, checked (live folder rules 2, 7, and 8).
    struct FeedAddress: Equatable {
        /// What `session.json` keeps: for a private feed, the address without its query.
        var source: LiveFolderSource
        /// The whole address, for an address with a query, which can carry a token.
        var keychainAddress: URL?
        /// The address the sheet loads: the whole one.
        var url: URL
    }

    /// How the sheet loads addresses and asks `gh` for its state. Tests replace both.
    struct Lookups {
        /// `FeedFetcher.discover(_:)`: the feed at an address, or the feeds its page names.
        var discover: @MainActor (URL) async throws -> FeedDiscovery.Outcome
        /// `gh auth status` for a host; `again` (Check Again) first reads the login shell and looks for `gh` again.
        var gitHubStatus: @MainActor (_ host: String, _ again: Bool) async -> GitHubCLIStatus

        /// The network and the user's `gh` through `GitHubCLI.shared`, which the live folders' searches use too, so Check Again counts for them.
        static var system: Lookups {
            Lookups(discover: { try await sheetFeedFetcher.discover($0) },
                    gitHubStatus: { host, again in
                        if again { _ = await GitHubCLI.shared.locate(again: true) }
                        return await GitHubCLI.shared.status(host: host)
                    })
        }

        private static let sheetFeedFetcher = FeedFetcher()
    }

    nonisolated static let noFeedMessage = "No feed found at this address."
    nonisolated static let keychainNote = "Arch keeps this address in the Keychain on this Mac, and the folder does not sync."
    nonisolated static let folderLimitMessage = "Arch keeps up to \(LiveFolderConfiguration.maximumFolders) live folders."

    let purpose: Purpose
    let title: String
    /// Whether the app holds as many live folders as it keeps (live folder rule 7), which only New Live Folder… heeds.
    let isAtFolderLimit: Bool
    /// Opens the built-in terminal, where the user installs `gh` and signs in (live folder rule 3).
    let openTerminal: (() -> Void)?
    /// Why the Address field shows a private feed's address without its query: the Keychain did not give the whole address.
    let keychainReadError: String?

    @Published var sourceKind: SourceKind {
        didSet { if sourceKind != oldValue { saveError = nil } }
    }

    // Feed
    @Published var address: String {
        didSet {
            guard address != oldValue else { return }
            feedLinks = []
            chosenFeed = nil
            feedMessage = nil
        }
    }
    /// The feeds of a page that names several, to choose from.
    @Published private(set) var feedLinks: [FeedLink] = []
    @Published var chosenFeed: URL?
    /// Why Add found no feed: none at the address, or the failure of its load.
    @Published private(set) var feedMessage: String?

    // GitHub
    /// A change that leaves `gitHubHost` as it was, as a pasted address of the same host, keeps `gh`'s state, since the sheet checks again only when `gitHubHost` changes.
    @Published var host: String {
        didSet { if Self.gitHubHost(fromInput: host) != Self.gitHubHost(fromInput: oldValue) { gitHubState = .checking } }
    }
    @Published var gitHubKind: GitHubSearch.Kind
    @Published var searchText: String
    @Published private(set) var gitHubState: GitHubState = .checking

    // The folder
    @Published var name: String
    @Published var itemLimit: Int
    /// The interval the user chose, or nil for the source's default (live folder rule 6).
    @Published var chosenRefreshMinutes: Int?

    /// While Add loads a feed or the session applies the sheet's folder.
    @Published private(set) var isWorking = false
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    /// Ends the sheet. The presenter sets it.
    var dismiss: () -> Void = {}

    private let lookups: Lookups
    private let commit: (Submission) async throws -> Void
    /// Edit Live Folder…'s folder as it was: its name, configuration, and the Address field's first text. Save keeps the source while the field keeps that text, so an unchanged private feed needs no Keychain write, and one whose whole address the Keychain did not give keeps it.
    private let original: (name: String, configuration: LiveFolderConfiguration, addressText: String)?
    private var checkCount = 0
    private var addTask: Task<Void, Never>?

    /// New Live Folder… in `space`, with the Address field prefilled with `address`, the selected tab's address when it shows a web page.
    init(newIn space: Space, personas: [Persona], liveFolderCount: Int, address: URL?, openTerminal: (() -> Void)?, lookups: Lookups = .system,
         commit: @escaping (Submission) async throws -> Void) {
        purpose = .new(spaceID: space.id)
        title = Self.title(newIn: space, among: personas)
        isAtFolderLimit = liveFolderCount >= LiveFolderConfiguration.maximumFolders
        self.openTerminal = openTerminal
        keychainReadError = nil
        sourceKind = .feed
        self.address = address?.absoluteString ?? ""
        host = "github.com"
        gitHubKind = .myPullRequests
        searchText = ""
        name = ""
        itemLimit = LiveFolderConfiguration.defaultItemLimit
        original = nil
        self.lookups = lookups
        self.commit = commit
    }

    /// Edit Live Folder… for a live folder of `space`, with a private feed's whole address from the Keychain, or nil and the reason when the Keychain did not give it.
    init(editing folder: TabFolder, configuration: LiveFolderConfiguration, in space: Space, personas: [Persona], wholeAddress: URL?, keychainReadError: String?,
         openTerminal: (() -> Void)?, lookups: Lookups = .system, commit: @escaping (Submission) async throws -> Void) {
        purpose = .edit(folderID: folder.id)
        title = Self.title(editingIn: space, among: personas)
        isAtFolderLimit = false
        self.openTerminal = openTerminal
        var addressText = ""
        var search = GitHubSearch(kind: .myPullRequests)
        switch configuration.source {
        case .feed(let stored, let isPrivate):
            sourceKind = .feed
            addressText = (isPrivate ? wholeAddress ?? stored : stored).absoluteString
            self.keychainReadError = isPrivate && wholeAddress == nil ? keychainReadError ?? LiveFolderError.privateAddressMissing.message : nil
        case .gitHub(let stored):
            sourceKind = .gitHub
            search = stored
            self.keychainReadError = nil
        }
        address = addressText
        host = search.host
        gitHubKind = search.kind
        searchText = search.text
        name = folder.name
        itemLimit = configuration.itemLimit
        chosenRefreshMinutes = configuration.refreshMinutes
        original = (folder.name, configuration, addressText)
        self.lookups = lookups
        self.commit = commit
    }

    /// "New Live Folder in Research", or "New Live Folder in Work / Research" with two or more Personas (Persona rule 7).
    static func title(newIn space: Space, among personas: [Persona]) -> String {
        "New Live Folder in \(BrowserSession.displayedPlace(ofPersona: space.resolvedPersonaID, space: space, among: personas) ?? space.name)"
    }

    static func title(editingIn space: Space, among personas: [Persona]) -> String {
        "Edit Live Folder in \(BrowserSession.displayedPlace(ofPersona: space.resolvedPersonaID, space: space, among: personas) ?? space.name)"
    }

    var isNew: Bool {
        if case .new = purpose { return true }
        return false
    }

    var refreshMinutes: Int {
        chosenRefreshMinutes ?? (sourceKind == .gitHub ? 15 : 30)
    }

    // MARK: Feed

    /// The typed text as a feed address, or nil while the field is empty. Text without a scheme counts as `https`, also when its query holds an address. Throws `LiveFolderError.invalidAddress` for an address that is not `http` or `https` or that holds a user name or password.
    static func feedAddress(fromInput text: String) throws -> FeedAddress? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let hasScheme = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        guard !text.contains(where: \.isWhitespace), let url = URL(string: hasScheme ? text : "https://" + text) else {
            throw LiveFolderError.invalidAddress("This is not a web address.")
        }
        return try feedAddress(url)
    }

    static func feedAddress(_ url: URL) throws -> FeedAddress {
        let (source, keychainAddress) = try LiveFolderSource.makeFeed(address: url)
        guard case .feed(let address, _) = source else { throw LiveFolderError.invalidAddress("This is not a web address.") }
        return FeedAddress(source: source, keychainAddress: keychainAddress, url: keychainAddress ?? address)
    }

    /// Why the Address field's text cannot be a feed's address.
    var addressError: String? {
        do {
            _ = try Self.feedAddress(fromInput: address)
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Whether the folder's address goes to the Keychain (live folder rule 8): the chosen feed's, or the typed one's, has a query, or an unchanged private feed keeps its own.
    var keepsAddressInKeychain: Bool {
        if isUnchangedFeed, case .feed(_, isPrivate: true)? = original?.configuration.source { return true }
        if let chosenFeed { return (try? Self.feedAddress(chosenFeed))?.keychainAddress != nil }
        return (try? Self.feedAddress(fromInput: address))?.keychainAddress != nil
    }

    /// Edit Live Folder… on a feed whose Address field keeps its first text.
    private var isUnchangedFeed: Bool {
        guard let original, sourceKind == .feed, case .feed = original.configuration.source else { return false }
        return address == original.addressText
    }

    // MARK: GitHub

    /// The Host field's host: without surrounding spaces, in lowercase, and taken out of an address when the user pastes one.
    var gitHubHost: String {
        Self.gitHubHost(fromInput: host)
    }

    static func gitHubHost(fromInput host: String) -> String {
        let text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.contains("://"), let components = URLComponents(string: text), let name = components.host else { return text }
        return components.port.map { "\(name):\($0)" } ?? name
    }

    /// The search the GitHub fields describe, or nil without a valid host or, for Search, without text.
    var gitHubSearch: GitHubSearch? {
        let host = gitHubHost
        guard GitHubSearch.isValidHost(host) else { return nil }
        let text = gitHubKind == .search ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if gitHubKind == .search, text.isEmpty { return nil }
        return GitHubSearch(host: host, kind: gitHubKind, text: text)
    }

    /// Whether `gh` is signed in to the Host field's host.
    var isGitHubReady: Bool {
        gitHubState == .checked(.signedIn, host: gitHubHost)
    }

    /// The status line: what the user does next, or the host once `gh` is ready.
    var gitHubMessage: String {
        switch gitHubState {
        case .checking:
            return "Checking the GitHub CLI\u{2026}"
        case .invalidHost:
            return "Enter a GitHub host, such as github.com."
        case .checked(.notInstalled, _):
            return "Install the GitHub CLI in the built-in terminal, for example with `brew install gh`."
        case .checked(.signedOut, let host):
            let command = host == "github.com" ? "gh auth login" : "gh auth login --hostname \(host)"
            return "Sign in with `\(command)` in the built-in terminal."
        case .checked(.signedIn, let host):
            return "Signed in to \(host)."
        }
    }

    /// Asks `gh` for its state on the Host field's host; Check Again passes `again`. Only the newest check's answer counts, and one for a host the field no longer names counts for nothing.
    func checkGitHub(again: Bool = false) async {
        checkCount += 1
        let check = checkCount
        let host = gitHubHost
        guard GitHubSearch.isValidHost(host) else {
            gitHubState = .invalidHost
            return
        }
        gitHubState = .checking
        let status = await lookups.gitHubStatus(host, again)
        guard check == checkCount, !Task.isCancelled, gitHubHost == host else { return }
        gitHubState = .checked(status, host: host)
    }

    static func title(of kind: GitHubSearch.Kind) -> String {
        switch kind {
        case .myPullRequests: return "My Pull Requests"
        case .reviewRequests: return "Review Requests"
        case .assignedIssues: return "Assigned Issues"
        case .search: return "Search"
        }
    }

    // MARK: The folder

    /// The Name field's placeholder: the name an empty field gives, as far as the sheet knows it before Add.
    var namePlaceholder: String {
        switch sourceKind {
        case .feed: return isUnchangedFeed ? original?.name ?? "Name" : "Feed Title"
        case .gitHub: return GitHubSearch(kind: gitHubKind).defaultName
        }
    }

    /// The typed name, else `defaultName`, else the folder's own name.
    private func chosenName(default defaultName: String?) -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if let defaultName = defaultName?.trimmingCharacters(in: .whitespacesAndNewlines), !defaultName.isEmpty { return defaultName }
        return original?.name ?? "Live Folder"
    }

    private func configuration(_ source: LiveFolderSource) -> LiveFolderConfiguration {
        LiveFolderConfiguration(source: source, itemLimit: itemLimit, refreshMinutes: refreshMinutes)
    }

    /// Edit Live Folder… keeping its source: Save then needs no load and no `gh`.
    private func keepsSource(_ source: LiveFolderSource?) -> Bool {
        source != nil && source == original?.configuration.source
    }

    /// Whether Add or Save can act: no work runs, and the sheet describes a folder it can make.
    var canAdd: Bool {
        !isWorking && describesFolder
    }

    /// New Live Folder… is under the limit, and the source is complete: an address that can be a feed's or a chosen feed, or a search on a host where `gh` is signed in. An edit that keeps its source needs neither a load nor `gh`.
    private var describesFolder: Bool {
        guard !(isNew && isAtFolderLimit) else { return false }
        switch sourceKind {
        case .feed:
            if isUnchangedFeed || chosenFeed != nil { return true }
            return (try? Self.feedAddress(fromInput: address)) != nil
        case .gitHub:
            guard let search = gitHubSearch else { return false }
            return isGitHubReady || keepsSource(.gitHub(search: search))
        }
    }

    // MARK: Add and Save

    /// Add or Save, once: a second press while it works does nothing.
    func startAdding() {
        guard canAdd else { return }
        isWorking = true
        addTask = Task { await add() }
    }

    /// Cancel: stops a load and ends the sheet. The session's part, once it started, runs to its end.
    func cancel() {
        guard !isSaving else { return }
        addTask?.cancel()
        dismiss()
    }

    /// Works out the folder, loading a feed address first, and hands it to `commit`, then ends the sheet. A page that names several feeds lists them and waits for a choice; a failure stays in the sheet. It ends the work that `startAdding()` began also when a check of `gh` that ran first leaves the sheet describing no folder.
    func add() async {
        isWorking = true
        defer { isWorking = false }
        guard describesFolder else { return }
        saveError = nil
        guard let submission = await submission(), !Task.isCancelled else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await commit(submission)
            dismiss()
        } catch {
            saveError = Self.message(for: error)
        }
    }

    /// The folder the sheet describes. A feed address loads first: a feed is used directly, a page's only feed at once, and a page with several leaves them to choose from (`docs/bookmarks.md`, Interface).
    func submission() async -> Submission? {
        switch sourceKind {
        case .gitHub:
            guard let search = gitHubSearch, isGitHubReady || keepsSource(.gitHub(search: search)) else { return nil }
            return Submission(name: chosenName(default: search.defaultName), configuration: configuration(.gitHub(search: search)), keychainAddress: nil)
        case .feed:
            if isUnchangedFeed, let original {
                return Submission(name: chosenName(default: nil), configuration: configuration(original.configuration.source), keychainAddress: nil)
            }
            if let chosenFeed {
                return await loadFeed(chosenFeed, title: feedLinks.first { $0.url == chosenFeed }?.title)
            }
            let typed: FeedAddress
            do {
                guard let address = try Self.feedAddress(fromInput: address) else { return nil }
                typed = address
            } catch {
                feedMessage = Self.message(for: error)
                return nil
            }
            feedMessage = nil
            let outcome: FeedDiscovery.Outcome
            do {
                outcome = try await lookups.discover(typed.url)
            } catch {
                feedMessage = Self.message(for: error)
                return nil
            }
            switch outcome {
            case .feed(let feed):
                return submission(for: typed, title: feed.title)
            case .links(let links) where links.isEmpty:
                feedMessage = Self.noFeedMessage
                return nil
            case .links(let links) where links.count == 1:
                return await loadFeed(links[0].url, title: links[0].title)
            case .links(let links):
                feedLinks = links
                chosenFeed = links[0].url
                return nil
            }
        }
    }

    /// Loads a feed that a page names, which must be a feed itself, so a broken link makes no folder.
    private func loadFeed(_ url: URL, title: String?) async -> Submission? {
        let address: FeedAddress
        do {
            address = try Self.feedAddress(url)
        } catch {
            feedMessage = Self.message(for: error)
            return nil
        }
        feedMessage = nil
        do {
            guard case .feed(let feed) = try await lookups.discover(address.url) else {
                feedMessage = Self.noFeedMessage
                return nil
            }
            return submission(for: address, title: feed.title ?? title)
        } catch {
            feedMessage = Self.message(for: error)
            return nil
        }
    }

    /// A feed's folder, named by the user, else by the feed's title, else by its host.
    private func submission(for address: FeedAddress, title: String?) -> Submission {
        Submission(name: chosenName(default: title ?? address.url.host), configuration: configuration(address.source), keychainAddress: address.keychainAddress)
    }

    static func message(for error: any Error) -> String {
        (error as? LiveFolderError)?.message ?? error.localizedDescription
    }
}

/// A live folder that Add cannot make, with the reason the sheet shows.
struct LiveFolderSheetError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }

    static let folderLimit = LiveFolderSheetError(message: LiveFolderSheetModel.folderLimitMessage)
}

// MARK: The sheet

/// The sheet's form: the source, the feed's address or the GitHub search with `gh`'s state, and the folder's name, item limit, and refresh interval.
struct LiveFolderSheetView: View {
    @ObservedObject var model: LiveFolderSheetModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case address
        case host
    }

    /// The Host field and the source the GitHub check follows; a change waits briefly, so typing a host does not run `gh` at every key.
    private struct GitHubCheck: Equatable {
        var isGitHub: Bool
        var host: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.title)
                .font(.headline)
            Form {
                Picker("Source:", selection: $model.sourceKind) {
                    Text("Feed").tag(LiveFolderSheetModel.SourceKind.feed)
                    Text("GitHub").tag(LiveFolderSheetModel.SourceKind.gitHub)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                switch model.sourceKind {
                case .feed: feedRows
                case .gitHub: gitHubRows
                }
                TextField("Name:", text: $model.name, prompt: Text(model.namePlaceholder))
                Picker("Items:", selection: $model.itemLimit) {
                    ForEach(LiveFolderConfiguration.itemLimits, id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Picker("Refresh:", selection: Binding(get: { model.refreshMinutes }, set: { model.chosenRefreshMinutes = $0 })) {
                    ForEach(LiveFolderConfiguration.refreshIntervals, id: \.self) { Text(Self.intervalTitle($0)).tag($0) }
                }
                .fixedSize()
            }
            .formStyle(.columns)
            .disabled(model.isWorking)
            if model.isNew, model.isAtFolderLimit {
                note(LiveFolderSheetModel.folderLimitMessage, isError: true)
            }
            if let error = model.saveError {
                note(error, isError: true)
            }
            HStack {
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                Button(model.isNew ? "Add" : "Save", action: model.startAdding)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focusedField = model.sourceKind == .feed ? .address : .host }
        .task(id: GitHubCheck(isGitHub: model.sourceKind == .gitHub, host: model.gitHubHost)) {
            guard model.sourceKind == .gitHub else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.checkGitHub()
        }
    }

    @ViewBuilder private var feedRows: some View {
        TextField("Address:", text: $model.address, prompt: Text("https://example.com/feed.xml"))
            .focused($focusedField, equals: .address)
        if !model.feedLinks.isEmpty {
            Picker("Feed:", selection: $model.chosenFeed) {
                ForEach(model.feedLinks, id: \.url) { link in
                    Text(link.title ?? link.url.absoluteString).tag(Optional(link.url))
                }
            }
            .pickerStyle(.radioGroup)
        }
        if let message = model.addressError ?? model.feedMessage {
            row { note(message, isError: true) }
        }
        if model.keepsAddressInKeychain {
            row { note(LiveFolderSheetModel.keychainNote) }
        }
        if let error = model.keychainReadError {
            row { note(error, isError: true) }
        }
    }

    @ViewBuilder private var gitHubRows: some View {
        TextField("Host:", text: $model.host, prompt: Text("github.com"))
            .focused($focusedField, equals: .host)
        Picker("Show:", selection: $model.gitHubKind) {
            ForEach(GitHubSearch.Kind.allCases, id: \.self) { Text(LiveFolderSheetModel.title(of: $0)).tag($0) }
        }
        .fixedSize()
        if model.gitHubKind == .search {
            TextField("Search:", text: $model.searchText, prompt: Text("is:pr is:open review-requested:@me"))
        }
        LabeledContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusSymbol
                    Text(Self.markdown(model.gitHubMessage))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let openTerminal = model.openTerminal {
                        Button("Open Terminal", action: openTerminal)
                    }
                    Button("Check Again") { Task { await model.checkGitHub(again: true) } }
                        .disabled(model.gitHubState == .checking)
                }
            }
        } label: {
            Text("Status:")
        }
    }

    @ViewBuilder private var statusSymbol: some View {
        switch model.gitHubState {
        case .checking:
            ProgressView()
                .controlSize(.mini)
        case .checked(.signedIn, _):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    /// A row in the form's content column without a label.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        LabeledContent {
            content()
        } label: {
            Text("")
        }
    }

    private func note(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The status line's commands show as code.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    static func intervalTitle(_ minutes: Int) -> String {
        switch minutes {
        case 60: return "Every Hour"
        case let minutes where minutes % 60 == 0: return "Every \(minutes / 60) Hours"
        default: return "Every \(minutes) Minutes"
        }
    }
}
