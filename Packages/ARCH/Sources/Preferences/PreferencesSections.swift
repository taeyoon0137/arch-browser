// Settings sections for General, Sidebar, and Appearance.
// General controls the default browser, links from other apps, new pages, downloads, the app's language, and update checks. Sidebar controls tab archiving. Appearance controls the app's appearance.
import AppKit
import ARCHEngine
import Browsing
import SwiftUI

/// Every section has the same width, so only the window's height changes between them.
let sectionWidth: CGFloat = 540

/// A grouped form's footer is trailing-aligned, primary, and sometimes cut to one line by default.
func formFootnote(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
}

/// The default browser, whether links from other apps open in small windows, the engine and search engine for new pages, where downloads go, the language Arch uses from its next launch, and, with an updater, its update checks.
struct GeneralSection: View {
    let updates: AppUpdateControls?
    @State private var isDefaultBrowser = DefaultBrowser.isDefault
    @AppStorage(AutomaticPictureInPictureSetting.defaultsKey) private var automaticPictureInPicture = AutomaticPictureInPictureSetting.enabledByDefault
    @AppStorage(BrowserSession.opensLinksInSmallWindowKey) private var opensLinksInSmallWindow = BrowserSession.opensLinksInSmallWindowByDefault
    /// The registry keeps the default engine here. The site settings popover can change it while the window is open, and the picker then shows the change (`defaultEngine`).
    @AppStorage(EngineRegistry.defaultEngineKey) private var storedDefaultEngine: String?
    @AppStorage(SearchEngine.defaultsKey) private var searchEngine = SearchEngine.google
    @AppStorage(BrowserSession.downloadsFolderKey) private var downloadsFolderPath: String?
    @AppStorage(BrowserSession.asksWhereToSaveDownloadsKey) private var asksWhereToSaveDownloads = false
    /// The language choice, nil for the system's, and the one the window opened with, which the running app still uses.
    @State private var language = LanguageSetting().chosen
    @State private var languageAtOpen = LanguageSetting().chosen

    var body: some View {
        Form {
            Section {
                LabeledContent(localized("Default browser")) {
                    if isDefaultBrowser {
                        Text("Arch", bundle: .module)
                    } else {
                        Button(localized("Set as Default\u{2026}")) {
                            DefaultBrowser.makeDefault { isDefaultBrowser = DefaultBrowser.isDefault }
                        }
                        .disabled(!DefaultBrowser.canBecomeDefault)
                    }
                }
                Toggle(localized("Open links from other apps in a small window when Arch is in the background"), isOn: $opensLinksInSmallWindow)
                Toggle(AutomaticPictureInPictureSetting.title, isOn: $automaticPictureInPicture)
                Picker(localized("Engine for new tabs"), selection: defaultEngine) {
                    ForEach(EngineRegistry.shared.registeredKinds, id: \.self) { kind in
                        Text(kind.displayName)
                    }
                }
                Picker(localized("Search engine"), selection: $searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.title)
                    }
                }
            }
            LinkOpeningSettings()
            Section(localized("Downloads")) {
                LabeledContent(localized("Save downloads to")) {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: downloadsFolder.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(FileManager.default.displayName(atPath: downloadsFolder.path))
                        Button(localized("Choose\u{2026}"), action: chooseDownloadsFolder)
                    }
                }
                Toggle(localized("Ask where to save each download"), isOn: $asksWhereToSaveDownloads)
            }
            Section {
                Picker(localized("Language"), selection: Binding(get: { language }, set: { language = $0; LanguageSetting().choose($0) })) {
                    Text(localized("System (default)")).tag(String?.none)
                    ForEach(LanguageSetting.languages, id: \.self) { code in
                        Text(verbatim: LanguageSetting.name(of: code)).tag(Optional(code))
                    }
                }
            } footer: {
                // A choice applies from the next launch; only an app bundle can open itself again.
                if language != languageAtOpen {
                    HStack(alignment: .firstTextBaseline) {
                        formFootnote(localized("Arch uses this language the next time it opens."))
                        if DefaultBrowser.canBecomeDefault {
                            Button(localized("Relaunch")) { LanguageSetting.relaunch() }
                        }
                    }
                }
            }
            if let updates {
                UpdatesSettings(controls: updates)
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
        .frame(maxHeight: 600)
        // The system's confirmation and System Settings can change the default browser while the window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isDefaultBrowser = DefaultBrowser.isDefault
        }
    }

    /// The engine new tabs use, as the registry reads it from the stored value, falling back to another engine when the stored one did not register. Reading the stored value here makes the section redraw when it changes.
    private var defaultEngine: Binding<EngineKind> {
        _ = storedDefaultEngine
        return Binding { EngineRegistry.shared.defaultKind } set: { EngineRegistry.shared.defaultKind = $0 }
    }

    /// The saved folder, or the user's Downloads folder when none is saved or the saved one is gone, as the session reads it.
    private var downloadsFolder: URL {
        var isDirectory: ObjCBool = false
        if let path = downloadsFolderPath, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    private func chooseDownloadsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = downloadsFolder
        panel.prompt = localized("Choose")
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { downloadsFolderPath = url.path }
        }
        if let window = PreferencesWindowController.shared.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

/// The updater's state and actions, which the app shell connects to Sparkle so that this module does not depend on it (`docs/updates.md`).
@MainActor public final class AppUpdateControls: ObservableObject {
    /// Whether the updater checks on its own, once a day.
    @Published public var automaticallyChecks: Bool
    /// False while a check or an update is in progress.
    @Published public var canCheckNow: Bool
    @Published public var lastCheck: Date?
    public var setAutomaticallyChecks: (Bool) -> Void = { _ in }
    /// Checks at once, showing what it finds, also when it finds no update.
    public var checkNow: () -> Void = {}

    public init(automaticallyChecks: Bool, canCheckNow: Bool, lastCheck: Date?) {
        self.automaticallyChecks = automaticallyChecks
        self.canCheckNow = canCheckNow
        self.lastCheck = lastCheck
    }
}

/// Settings ▸ General's updates: automatic checks, the running version with Check Now, and when the last check was.
private struct UpdatesSettings: View {
    @ObservedObject var controls: AppUpdateControls

    var body: some View {
        Section {
            Toggle(localized("Check for updates automatically"), isOn: Binding(get: { controls.automaticallyChecks }, set: { controls.setAutomaticallyChecks($0) }))
            LabeledContent(localized("Version")) {
                HStack(spacing: 6) {
                    Text(verbatim: Self.version)
                    Button(localized("Check Now")) { controls.checkNow() }
                        .disabled(!controls.canCheckNow)
                }
            }
        } header: {
            Text("Updates", bundle: .module)
        } footer: {
            // As Settings ▸ Plugins words its checks: the time for a check today, and the date too for an earlier one.
            if let lastCheck = controls.lastCheck {
                formFootnote(Calendar.current.isDateInToday(lastCheck)
                    ? localized("Last checked at \(lastCheck.formatted(date: .omitted, time: .shortened)).")
                    : localized("Last checked on \(lastCheck.formatted(date: .abbreviated, time: .shortened))."))
            }
        }
    }

    /// The short version and the build number, as "0.1.0 (202611231530)".
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

/// How long an unpinned tab stays open without being selected, and how long pinned tabs and favorites keep their pages without being shown (bookmark rule 5).
struct SidebarSection: View {
    @ObservedObject var session: BrowserSession
    @State private var personaID = Persona.defaultID
    @AppStorage(FavoriteTileLayout.columnsKey) private var favoriteColumns = FavoriteTileLayout.defaultColumns

    private var shownPersonaID: Persona.ID {
        session.personas.contains { $0.id == personaID } ? personaID : Persona.defaultID
    }
    private var favoriteRows: [Int] { session.favoriteRows(in: shownPersonaID) }
    @AppStorage(BrowserSession.archiveAfterHoursKey) private var archiveAfterHours = BrowserSession.archiveAfterHoursByDefault
    @AppStorage(TabUnloading.unloadAfterHoursKey) private var unloadAfterHours = TabUnloading.unloadAfterHoursByDefault

    var body: some View {
        Form {
            Section {
                if session.personas.count > 1 {
                    Picker(localized("Persona"), selection: $personaID) {
                        ForEach(session.personas) { Text($0.name).tag($0.id) }
                    }
                }
                ForEach(favoriteRows.indices, id: \.self) { index in
                    HStack {
                        favoriteCountPicker(localized("Row \(index + 1)"), selection: Binding(
                            get: { favoriteRows.indices.contains(index) ? favoriteRows[index] : favoriteColumns },
                            set: { count in
                                var rows = favoriteRows
                                guard rows.indices.contains(index) else { return }
                                rows[index] = count
                                session.setFavoriteRows(FavoriteTileLayout.counts(for: session.favorites(in: shownPersonaID).count,
                                                                                 rowSizes: rows, defaultColumns: favoriteColumns), in: shownPersonaID)
                            }))
                        Button {
                            session.setFavoriteRows(rows(removing: index), in: shownPersonaID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(rows(removing: index) == favoriteRows)
                        .accessibilityLabel(localized("Remove row \(index + 1)"))
                    }
                }
                // The default follows the rows it sets, as the grid lays them out.
                favoriteCountPicker(favoriteRows.isEmpty ? localized("All rows") : localized("Other rows"), selection: Binding(
                    get: { FavoriteTileLayout.columnCount(favoriteColumns) },
                    set: { favoriteColumns = $0 }))
                Button(localized("Add Row")) {
                    var rows = favoriteRows
                    guard let last = rows.lastIndex(where: { $0 > 1 }) else { return }
                    rows[last] -= 1
                    session.setFavoriteRows(rows + [1], in: shownPersonaID)
                }
                .disabled(!favoriteRows.contains { $0 > 1 })
            } header: {
                Text("Favorites per row", bundle: .module)
            }

            Section {
                // In both pickers a saved delay outside the choices, such as 5, stays listed and selected. 0 or less archives or unloads nothing.
                Picker(localized("Archive unpinned tabs"), selection: Binding(get: { max(archiveAfterHours, 0) }, set: { archiveAfterHours = $0 })) {
                    ForEach(Set([0, 1, 12, 24, 168, max(archiveAfterHours, 0)]).sorted(), id: \.self) { hours in
                        Text(Self.title(for: hours)).tag(hours)
                    }
                }
            } footer: {
                formFootnote(localized("Unpinned tabs not selected for this long move to the closed list."))
            }
            Section {
                Picker(localized("Unload pinned tabs and favorites"), selection: Binding(get: { max(unloadAfterHours, 0) }, set: { unloadAfterHours = $0 })) {
                    ForEach(Set([0, 1, 12, 24, 168, max(unloadAfterHours, 0)]).sorted(), id: \.self) { hours in
                        Text(Self.title(for: hours)).tag(hours)
                    }
                }
            } footer: {
                // The longer footer wraps through the shared footnote style. Never also keeps every page when the Mac runs low on memory (`TabUnloading.tabsToUnload`).
                if unloadAfterHours <= 0 {
                    formFootnote(localized("Tabs keep their pages until you close them, also when the Mac runs low on memory."))
                } else {
                    formFootnote(localized("Pinned tabs and favorites not shown for this long close their pages and keep their places. When the Mac runs low on memory, every tab not shown does. Tabs that play audio or video with sound, show a video in picture in picture, use the camera or microphone, hold text you typed, or may post notifications stay loaded; sound that a page makes in other ways, as many games do, does not keep it loaded."))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
        .onAppear { personaID = session.activeWindow?.personaID ?? Persona.defaultID }
        .onChange(of: session.personas.map(\.id)) {
            if !session.personas.contains(where: { $0.id == personaID }) { personaID = Persona.defaultID }
        }
    }

    private func rows(removing index: Int) -> [Int] {
        var rows = favoriteRows
        guard rows.indices.contains(index) else { return rows }
        rows.remove(at: index)
        return FavoriteTileLayout.normalizedRows(for: session.favorites(in: shownPersonaID).count,
                                                 rowSizes: rows, defaultColumns: favoriteColumns)
    }

    private func favoriteCountPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(FavoriteTileLayout.choices, id: \.self) { count in
                Text(String(count)).tag(count)
            }
        }
        .pickerStyle(.segmented)
    }

    /// "Never", "After 1 Hour", "After 1 Day", "After 1 Week", or "After 5 Hours".
    static func title(for hours: Int) -> String {
        switch hours {
        case 0: return localized("Never")
        case 1: return localized("After 1 Hour")
        case 24: return localized("After 1 Day")
        case 168: return localized("After 1 Week")
        default: return localized("After \(hours) Hours")
        }
    }
}

/// The app's appearance (the system's, light, or dark) and how strongly the current space's tint washes the window.
struct AppearanceSection: View {
    @AppStorage(AppearanceSetting.defaultsKey) private var appearance = AppearanceSetting.system
    @AppStorage(TintStrength.defaultsKey) private var tintStrength = TintStrength.subtle

    var body: some View {
        Form {
            Picker(localized("Appearance"), selection: $appearance) {
                ForEach(AppearanceSetting.allCases, id: \.self) { choice in
                    Text(choice.title)
                }
            }
            .onChange(of: appearance) { NSApp.appearance = $1.appearance }
            Picker(localized("Space tint"), selection: $tintStrength) {
                ForEach(TintStrength.allCases, id: \.self) { strength in
                    Text(strength.title)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
    }
}

/// Whether Arch opens web links from other apps, as Launch Services reports. Only an app bundle can register, and the system asks the user to confirm. Registering `http` covers `https` as well.
public enum DefaultBrowser {
    public static var canBecomeDefault: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Calls `completion` on the main queue once the user answers the system's confirmation.
    public static func makeDefault(completion: @escaping () -> Void = {}) {
        guard canBecomeDefault else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }
}
