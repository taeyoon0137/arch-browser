// The app-wide site rules table, its editor, and the site controls shared by the sidebar and menu bar.
import AppKit
import SwiftUI

/// Settings ▸ Websites places this group above its Persona-specific permissions.
public struct SiteRulesSection: View {
    @ObservedObject private var session: BrowserSession
    @ObservedObject private var store: SiteRuleStore
    @State private var selectedID: UUID?
    @State private var editing: SiteRule?
    @State private var removalFailed = false

    public init(session: BrowserSession) {
        self.session = session
        store = session.siteRules
    }

    public var body: some View {
        Section {
            if store.rules.isEmpty {
                Text("No site rules", bundle: .module).foregroundStyle(.secondary)
            } else {
                Table(store.rules, selection: $selectedID) {
                    TableColumn(localized("Site")) { rule in
                        Text(rule.host + rule.pathPrefix).lineLimit(1).help(rule.host + rule.pathPrefix)
                    }
                    TableColumn(localized("Opens In")) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.siteRuleDestination(rule).map(session.siteRulePlace) ?? localized("Waiting for destination"))
                                .lineLimit(1)
                            if !session.spaces.contains(where: { $0.id == rule.spaceID }), session.siteRuleDestination(rule) != nil {
                                Text("Space deleted", bundle: .module).font(.caption).foregroundStyle(.secondary)
                                Button(localized("Choose Space…")) { editing = rule }.buttonStyle(.link)
                            }
                        }
                    }
                    TableColumn(localized("Window")) { rule in
                        Text(rule.window == .space ? localized("In Its Space") : localized("In a New Window"))
                    }
                }
                .frame(height: min(200, CGFloat(store.rules.count) * 44 + 32))
            }
            HStack(spacing: 8) {
                Button(localized("Add…")) {
                    guard let space = session.siteRuleDestinations.first else { return }
                    editing = SiteRule(host: "", spaceID: space.id, personaID: space.resolvedPersonaID)
                }
                .disabled(session.siteRuleDestinations.isEmpty)
                Button(localized("Edit…")) { editing = selectedRule }.disabled(selectedRule == nil)
                Button(localized("Remove")) {
                    if let selectedID { removalFailed = !store.remove(id: selectedID) }
                    if !removalFailed { selectedID = nil }
                }.disabled(selectedRule == nil)
                Spacer()
            }
            .disabled(store.isReadOnly)
            if removalFailed { Text("Couldn’t Remove Site Rule", bundle: .module).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Label(localized("Where Sites Open"), systemImage: "arrow.up.forward.app")
        } footer: {
            Text(store.isReadOnly
                 ? localized("These site rules were saved by a newer version of Arch. Update Arch to edit them.")
                 : localized("Links from other apps, links you open in new tabs, and addresses you type open here. Pages already open stay where they are."))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { rule in SiteRuleEditor(session: session, rule: rule) }
    }

    private var selectedRule: SiteRule? { store.rules.first { $0.id == selectedID } }
}

private struct SiteRuleEditor: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var store: SiteRuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var id: UUID
    @State private var site: String
    @State private var destinationID: UUID
    @State private var window: SiteRule.Window
    @State private var error: String?

    init(session: BrowserSession, rule: SiteRule) {
        self.session = session
        store = session.siteRules
        _id = State(initialValue: rule.id)
        _site = State(initialValue: (rule.host.contains(":") ? "[\(rule.host)]" : rule.host) + rule.pathPrefix)
        _destinationID = State(initialValue: rule.spaceID)
        _window = State(initialValue: rule.window)
    }

    private var parsed: SiteRuleSite? { try? SiteRuleSite(parsing: site) }
    private var destination: Space? { session.siteRuleDestinations.first { $0.id == destinationID } }
    private var duplicate: SiteRule? {
        guard let parsed else { return nil }
        return store.rules.first { $0.id != id && $0.host == parsed.host && $0.pathPrefix == parsed.pathPrefix }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(store.rules.contains { $0.id == id } ? localized("Edit Site Rule") : localized("Add Site Rule"))
                .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 20)
            Form {
                TextField(localized("Site"), text: $site, prompt: Text(verbatim: "example.com/work"))
                if parsed == nil, !site.isEmpty {
                    Text("Enter a host and optional path, without a username or password.", bundle: .module)
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let duplicate {
                    Text("A rule already uses this site and path.", bundle: .module).font(.callout).foregroundStyle(.secondary)
                    Button(localized("Edit Existing Rule…")) { id = duplicate.id }
                }
                Picker(localized("Opens In"), selection: $destinationID) {
                    if destination == nil { Text("Choose Space…", bundle: .module).tag(destinationID) }
                    ForEach(session.siteRuleDestinations) { space in Text(session.siteRulePlace(space)).tag(space.id) }
                }
                Picker(localized("Window"), selection: $window) {
                    Text("In Its Space", bundle: .module).tag(SiteRule.Window.space)
                    Text("In a New Window", bundle: .module).tag(SiteRule.Window.newWindow)
                }
                if let error { Text(error).foregroundStyle(.secondary).font(.callout) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(localized("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(localized("Save"), action: save).keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil || destination == nil || duplicate != nil || store.isReadOnly)
            }.padding(20)
        }.frame(width: 460)
    }

    private func save() {
        guard let parsed, let destination else { return }
        do {
            try store.save(SiteRule(id: id, host: parsed.host, pathPrefix: parsed.pathPrefix,
                                   spaceID: destination.id, personaID: destination.resolvedPersonaID, window: window))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension BrowserSession {
    func siteRulePlace(_ space: Space) -> String {
        displayedPlace(ofPersona: space.resolvedPersonaID, space: space) ?? space.name
    }

    /// All controls use the same Persona grouping and exclude the Agents Persona.
    var siteRuleSections: [SpaceMoveSection] {
        let destinations = Set(siteRuleDestinations.map(\.id))
        return spaceMoveSections { _ in nil }.compactMap { section in
            let spaces = section.spaces.filter { destinations.contains($0.id) }
            guard !spaces.isEmpty else { return nil }
            return SpaceMoveSection(personaID: section.personaID, title: section.title, spaces: spaces, refusal: nil)
        }
    }

    /// Quick controls edit the host rule. A more specific path can keep its destination, and removing one match can reveal another.
    func quickRuleNote(for url: URL, removing: Bool = false) -> String? {
        guard let matching = siteRule(for: url) else { return nil }
        let site = matching.host + matching.pathPrefix
        if removing {
            guard let remaining = SiteRuleSet.match(url: url, rules: siteRules.rules.filter { $0.id != matching.id }) else { return nil }
            let remainingSite = remaining.host + remaining.pathPrefix
            return localized("Choosing Anywhere removes \(site); \(remainingSite) will still apply. Edit rules in Settings ▸ Websites.")
        }
        guard let host = url.host, let current = try? SiteRuleSite(host: host, pathPrefix: ""),
              matching.host == current.host, !matching.pathPrefix.isEmpty else { return nil }
        return localized("This page still follows \(site). Edit path rules in Settings ▸ Websites.")
    }

    func setSiteRuleFromMenu(for url: URL, destination: Space?) {
        do { try setSiteRule(for: url, destination: destination) }
        catch {
            let alert = NSAlert()
            alert.messageText = localized("Couldn’t Save Site Rule")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: localized("OK"))
            if let window = activeWindow?.nsWindow { alert.beginSheetModal(for: window) }
        }
    }
}

struct SiteRuleMenu: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @ObservedObject private var store: SiteRuleStore

    init(session: BrowserSession, tab: Tab) {
        self.session = session
        self.tab = tab
        store = session.siteRules
    }

    var body: some View {
        if !tab.isPrivate, let url = tab.url, (try? SiteRuleSite(parsing: url.absoluteString)) != nil {
            Menu(localized("Always Open This Site In")) {
                let selected = session.siteRule(for: url).flatMap(session.siteRuleDestination)?.id
                Toggle(localized("Anywhere"), isOn: Binding(get: { selected == nil }, set: { _ in session.setSiteRuleFromMenu(for: url, destination: nil) }))
                if let note = session.quickRuleNote(for: url, removing: true) { Button(note) {}.disabled(true) }
                if let note = session.quickRuleNote(for: url) { Button(note) {}.disabled(true) }
                ForEach(session.siteRuleSections) { section in
                    Divider()
                    if let title = section.title {
                        Section(title) { destinations(section.spaces, selected: selected, url: url) }
                    } else { destinations(section.spaces, selected: selected, url: url) }
                }
            }.disabled(store.isReadOnly)
        }
    }

    private func destinations(_ spaces: [Space], selected: UUID?, url: URL) -> some View {
        ForEach(spaces) { space in
            Toggle(space.name, isOn: Binding(get: { selected == space.id }, set: { _ in session.setSiteRuleFromMenu(for: url, destination: space) }))
        }
    }
}

struct SiteRulePopoverSection: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @ObservedObject private var store: SiteRuleStore
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let close: () -> Void

    init(session: BrowserSession, tab: Tab, close: @escaping () -> Void) {
        self.session = session
        self.tab = tab
        self.close = close
        store = session.siteRules
    }

    var body: some View {
        if !tab.isPrivate, let url = tab.url, (try? SiteRuleSite(parsing: url.absoluteString)) != nil {
            let destination = session.siteRule(for: url).flatMap(session.siteRuleDestination)
            let notes = [session.quickRuleNote(for: url), session.quickRuleNote(for: url, removing: true),
                         destination?.resolvedPersonaID != nil && destination?.resolvedPersonaID != tab.personaID
                         ? localized("Moving this tab to another Persona loads the page signed out.") : nil].compactMap { $0 }
            SiteSettingsGroup(localized("Open This Site In"), footnote: notes.isEmpty ? nil : notes.joined(separator: " ")) {
                SiteSettingsRow(symbol: "arrow.up.forward.app", title: localized("Opens In")) {
                    Picker(localized("Open This Site In"), selection: Binding<UUID?>(get: { destination?.id }, set: { id in
                        session.setSiteRuleFromMenu(for: url, destination: session.siteRuleDestinations.first { $0.id == id })
                    })) {
                        Text("Anywhere", bundle: .module).tag(nil as UUID?)
                        ForEach(session.siteRuleDestinations) { space in Text(session.siteRulePlace(space)).tag(Optional(space.id)) }
                    }.disabled(store.isReadOnly)
                }
                if let destination, session.canCarryTab(tab.id, toSpace: destination.id) {
                    SiteSettingsDivider()
                    SiteSettingsRow(symbol: "arrow.right", title: localized("Move This Tab"), action: {
                        close()
                        session.moveTab(tab.id, toSpace: destination.id, windowsFollow: false, activating: windowModel)
                    })
                }
            }
        }
    }
}

/// The Tab menu uses the Browsing catalog, just like the tab row’s submenu.
@MainActor public final class SiteRulesMenu: NSMenu, NSMenuDelegate {
    private weak var session: BrowserSession?
    private struct Choice { let url: URL; let space: Space? }

    public init(session: BrowserSession) {
        self.session = session
        super.init(title: localized("Always Open This Site In"))
        autoenablesItems = false
        delegate = self
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    public func menuWillOpen(_ menu: NSMenu) {
        removeAllItems()
        guard let session, let url = session.lastMainWindow?.selectedTab?.url,
              (try? SiteRuleSite(parsing: url.absoluteString)) != nil else {
            addItem(withTitle: localized("No Site to Set"), action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        let selected = session.siteRule(for: url).flatMap(session.siteRuleDestination)?.id
        addChoice(title: localized("Anywhere"), url: url, space: nil, selected: selected, enabled: !session.siteRules.isReadOnly)
        for note in [session.quickRuleNote(for: url, removing: true), session.quickRuleNote(for: url)].compactMap({ $0 }) {
            addItem(withTitle: note, action: nil, keyEquivalent: "").isEnabled = false
        }
        for section in session.siteRuleSections {
            addItem(.separator())
            if let title = section.title { addItem(.sectionHeader(title: title)) }
            for space in section.spaces { addChoice(title: space.name, url: url, space: space, selected: selected, enabled: !session.siteRules.isReadOnly) }
        }
    }

    private func addChoice(title: String, url: URL, space: Space?, selected: UUID?, enabled: Bool) {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Choice(url: url, space: space)
        item.state = space?.id == selected ? .on : .off
        item.isEnabled = enabled
        addItem(item)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        session?.setSiteRuleFromMenu(for: choice.url, destination: choice.space)
    }
}

struct SiteRuleCommand: Identifiable {
    let space: Space
    let title: String
    var id: UUID { space.id }
}

extension BrowserSession {
    func siteRuleCommands(matching text: String, forTab tab: Tab) -> [SiteRuleCommand] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !tab.isPrivate, !words.isEmpty, !siteRules.isReadOnly, let url = tab.url,
              (try? SiteRuleSite(parsing: url.absoluteString)) != nil else { return [] }
        return siteRuleDestinations.compactMap { space in
            let place = siteRulePlace(space)
            let title = localized("Always Open This Site In \(place)")
            guard title.lowercased().hasPrefix(words) || "always open this site in \(place.lowercased())".hasPrefix(words) else { return nil }
            return SiteRuleCommand(space: space, title: title)
        }
    }
}
