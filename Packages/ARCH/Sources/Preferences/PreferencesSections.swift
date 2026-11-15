// The Settings sections: General for the default browser, links from other apps, new pages, and downloads; Sidebar for tab archiving; Appearance for the app's appearance.
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

/// The default browser, whether links from other apps open in small windows, the engine and search engine for new pages, and where downloads go.
struct GeneralSection: View {
    @State private var isDefaultBrowser = DefaultBrowser.isDefault
    @AppStorage(BrowserSession.opensLinksInSmallWindowKey) private var opensLinksInSmallWindow = BrowserSession.opensLinksInSmallWindowByDefault
    /// The registry keeps the default engine here. The site settings popover can change it while the window is open, and the picker then shows the change (`defaultEngine`).
    @AppStorage(EngineRegistry.defaultEngineKey) private var storedDefaultEngine: String?
    @AppStorage(SearchEngine.defaultsKey) private var searchEngine = SearchEngine.google
    @AppStorage(BrowserSession.downloadsFolderKey) private var downloadsFolderPath: String?
    @AppStorage(BrowserSession.asksWhereToSaveDownloadsKey) private var asksWhereToSaveDownloads = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Default browser") {
                    if isDefaultBrowser {
                        Text("Arch")
                    } else {
                        Button("Set as Default\u{2026}") {
                            DefaultBrowser.makeDefault { isDefaultBrowser = DefaultBrowser.isDefault }
                        }
                        .disabled(!DefaultBrowser.canBecomeDefault)
                    }
                }
                Toggle("Open links from other apps in a small window when Arch is in the background", isOn: $opensLinksInSmallWindow)
                Picker("Engine for new tabs", selection: defaultEngine) {
                    ForEach(EngineRegistry.shared.registeredKinds, id: \.self) { kind in
                        Text(kind.displayName)
                    }
                }
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.title)
                    }
                }
            }
            Section("Downloads") {
                LabeledContent("Save downloads to") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: downloadsFolder.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: downloadsFolder.path))
                        Button("Choose\u{2026}", action: chooseDownloadsFolder)
                    }
                }
                Toggle("Ask where to save each download", isOn: $asksWhereToSaveDownloads)
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
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
        panel.prompt = "Choose"
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

/// How long an unpinned tab stays open without being selected, and how long pinned tabs and favorites keep their pages without being shown (bookmark rule 5).
struct SidebarSection: View {
    @AppStorage(FavoriteTileLayout.columnsKey) private var favoriteColumns = FavoriteTileLayout.defaultColumns
    @AppStorage(FavoriteTileLayout.rowSizesKey) private var favoriteRowData = Data()

    private var favoriteRows: [Int] { FavoriteTileLayout.rowSizes(from: favoriteRowData) }
    @AppStorage(BrowserSession.archiveAfterHoursKey) private var archiveAfterHours = BrowserSession.archiveAfterHoursByDefault
    @AppStorage(TabUnloading.unloadAfterHoursKey) private var unloadAfterHours = TabUnloading.unloadAfterHoursByDefault

    var body: some View {
        Form {
            Section {
                ForEach(favoriteRows.indices, id: \.self) { index in
                    HStack {
                        favoriteCountPicker("Row \(index + 1)", selection: Binding(
                            get: { favoriteRows.indices.contains(index) ? favoriteRows[index] : favoriteColumns },
                            set: { count in
                                var rows = favoriteRows
                                guard rows.indices.contains(index) else { return }
                                rows[index] = count
                                favoriteRowData = FavoriteTileLayout.encode(rowSizes: rows)
                            }))
                        Button {
                            var rows = favoriteRows
                            guard rows.indices.contains(index) else { return }
                            rows.remove(at: index)
                            favoriteRowData = FavoriteTileLayout.encode(rowSizes: rows)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove row \(index + 1)")
                    }
                }
                // The default follows the rows it sets, as the grid lays them out.
                favoriteCountPicker(favoriteRows.isEmpty ? "All rows" : "Other rows", selection: Binding(
                    get: { FavoriteTileLayout.columnCount(favoriteColumns) },
                    set: { favoriteColumns = $0 }))
                Button("Add Row") {
                    favoriteRowData = FavoriteTileLayout.encode(rowSizes: favoriteRows + [favoriteColumns])
                }
            } header: {
                Text("Favorites per row")
            } footer: {
                if !favoriteRows.isEmpty { formFootnote("Rows after these use this number.") }
            }

            Section {
                // In both pickers a saved delay outside the choices, such as 5, stays listed and selected. 0 or less archives or unloads nothing.
                Picker("Archive unpinned tabs", selection: Binding(get: { max(archiveAfterHours, 0) }, set: { archiveAfterHours = $0 })) {
                    ForEach(Set([0, 1, 12, 24, 168, max(archiveAfterHours, 0)]).sorted(), id: \.self) { hours in
                        Text(Self.title(for: hours)).tag(hours)
                    }
                }
            } footer: {
                formFootnote("Unpinned tabs not selected for this long move to the closed list.")
            }
            Section {
                Picker("Unload pinned tabs and favorites", selection: Binding(get: { max(unloadAfterHours, 0) }, set: { unloadAfterHours = $0 })) {
                    ForEach(Set([0, 1, 12, 24, 168, max(unloadAfterHours, 0)]).sorted(), id: \.self) { hours in
                        Text(Self.title(for: hours)).tag(hours)
                    }
                }
            } footer: {
                // The longer footer wraps through the shared footnote style. Never also keeps every page when the Mac runs low on memory (`TabUnloading.tabsToUnload`).
                if unloadAfterHours <= 0 {
                    formFootnote("Tabs keep their pages until you close them, also when the Mac runs low on memory.")
                } else {
                    formFootnote("Pinned tabs and favorites not shown for this long close their pages and keep their places. When the Mac runs low on memory, every tab not shown does. Tabs that play audio or video with sound, show a video in picture in picture, use the camera or microphone, hold text you typed, or may post notifications stay loaded; sound that a page makes in other ways, as many games do, does not keep it loaded.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
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
        case 0: return "Never"
        case 1: return "After 1 Hour"
        case 24: return "After 1 Day"
        case 168: return "After 1 Week"
        default: return "After \(hours) Hours"
        }
    }
}

/// The app's appearance (the system's, light, or dark) and how strongly the current space's tint washes the window.
struct AppearanceSection: View {
    @AppStorage(AppearanceSetting.defaultsKey) private var appearance = AppearanceSetting.system
    @AppStorage(TintStrength.defaultsKey) private var tintStrength = TintStrength.subtle

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceSetting.allCases, id: \.self) { choice in
                    Text(choice.title)
                }
            }
            .onChange(of: appearance) { NSApp.appearance = $1.appearance }
            Picker("Space tint", selection: $tintStrength) {
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
