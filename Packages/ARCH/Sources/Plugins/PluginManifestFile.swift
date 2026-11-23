// `plugin.json` is a script package's manifest and becomes a `PluginManifest`.
// Arch refuses unknown keys so the plugin never relies on an ignored field. It reads each named page script and style sheet from the package.
import AI
import ARCHEngine
import Events
import Foundation
import UniformTypeIdentifiers

/// What a package's `plugin.json` declares.
struct ScriptManifest {
    static let fileName = "plugin.json"

    let manifest: PluginManifest
    /// The package path of the background script, which commands and page script values reach. A plugin without one adds only page scripts, settings, and panels.
    let background: String?

    /// Reads `plugin.json` in the package folder at `root`. Throws `PluginError.unsupportedAPIVersion` for a newer plugin API, and `.invalidPackage`, `.invalidMatchPattern`, or `.invalidShortcut` for a manifest that breaks the rules of `docs/plugins.md`.
    init(packageAt root: URL) throws {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(Self.fileName)) else {
            throw PluginError.invalidPackage("The package has no plugin.json at its top level.")
        }
        guard let json = try? JSONDecoder().decode(PluginValue.self, from: data) else {
            throw PluginError.invalidPackage("plugin.json is not valid JSON.")
        }
        var object = try ManifestObject(json, at: "")
        // The version comes first, so that a manifest for a newer API reports it rather than the fields that API adds.
        let apiVersion = try object.wholeNumber("apiVersion")
        guard apiVersion <= PluginManifest.apiVersion else { throw PluginError.unsupportedAPIVersion(apiVersion) }
        let idText = try object.string("id")
        guard let id = PluginID(rawValue: idText) else { throw invalidManifest("id “\(idText)” is not a reverse-DNS identifier") }
        // The name loses the spaces at either end, so every view shows it alike, and a name of nothing but spaces, which would show as no name, leaves the plugin to go by its identifier, as a web extension does.
        let givenName = try object.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = givenName.isEmpty ? id.rawValue : givenName
        let version = try object.string("version")
        let summary = try object.string("summary")
        let (permissions, aiDataKinds, network) = try Self.permissions(object.value("permissions"))
        let settingsPage = try object.optionalString("settingsPage")
        if let settingsPage {
            _ = try packageFile(settingsPage, in: root, named: "settingsPage")
            guard UTType(filenameExtension: (settingsPage as NSString).pathExtension)?.conforms(to: .html) == true else {
                throw invalidManifest("settingsPage names “\(settingsPage)”, which is not an HTML file")
            }
        }
        let sites = try object.strings("sites").map(MatchPattern.init)
        let siteAccess = try Self.siteAccess(object.optionalString("siteAccess"))
        // `events` lists the bus's kinds and `settingChanged`, the plugin's own setting changes.
        var receivesSettingChanges = false
        let events = try object.strings("events").compactMap { name -> BrowserEventKind? in
            if name == PluginEvent.settingChangedKind {
                receivesSettingChanges = true
                return nil
            }
            guard let kind = BrowserEventKind(rawValue: name) else { throw invalidManifest("events lists “\(name)”, which is not an event Arch sends") }
            return kind
        }
        let background = try object.optionalString("background")
        if let background { _ = try packageFile(background, in: root, named: "background") }
        let contributions = try object.object("contributes").map { try Self.contributions($0, packageAt: root) } ?? PluginContributions()
        try object.finish()
        guard background != nil || contributions.commands.isEmpty else { throw invalidManifest("commands need a background script") }
        guard background != nil || (events.isEmpty && !receivesSettingChanges) else { throw invalidManifest("events need a background script") }
        // Without settings, the user could change none.
        guard !receivesSettingChanges || !contributions.settings.isEmpty else { throw invalidManifest("events lists settingChanged, which needs contributes.settings") }
        // Without a command to run, a plugin that reaches its sites only where the user runs one would reach none.
        guard siteAccess == .listedSites || !contributions.commands.isEmpty else { throw invalidManifest("siteAccess whenInvoked needs contributes.commands") }
        manifest = PluginManifest(id: id, name: name, version: version, summary: summary, permissions: permissions, aiDataKinds: aiDataKinds, network: network, settingsPage: settingsPage, sites: sites,
                                  siteAccess: siteAccess, contributions: contributions, events: Set(events), receivesSettingChanges: receivesSettingChanges)
        self.background = background
    }

    /// `siteAccess` is `listedSites`, the default, or `whenInvoked`.
    private static func siteAccess(_ name: String?) throws -> SiteAccess {
        guard let name else { return .listedSites }
        guard let siteAccess = SiteAccess(rawValue: name) else { throw invalidManifest("siteAccess must be listedSites or whenInvoked") }
        return siteAccess
    }

    /// The data kinds beyond text that the `ai` permission may list, those whose content plugins reach: the text of pages through page calls, and selected text through commands.
    static let aiDataKinds: [AIDataKind] = [.page, .selection]

    /// `permissions` lists names of `PluginPermission`, and the `ai` permission either by its name, for requests with text only, or as `{"ai": [kinds]}` with the data kinds beyond text that its requests carry.
    private static func permissions(_ value: PluginValue?) throws -> (Set<PluginPermission>, Set<AIDataKind>, [PluginNetworkHost]) {
        guard let value else { return ([], [], []) }
        let malformed = invalidManifest("permissions must be an array of permission names, with ai also as an object such as {\"ai\": [\"page\"]}")
        guard case let .array(items) = value else { throw malformed }
        var permissions: Set<PluginPermission> = []
        var aiDataKinds: Set<AIDataKind> = []
        var network: [PluginNetworkHost] = []
        for item in items {
            switch item {
            case let .string(name):
                guard let permission = PluginPermission(rawValue: name) else { throw invalidManifest("permissions lists “\(name)”, which Arch does not grant") }
                guard permission != .nativeMessaging else { throw invalidManifest("permissions lists “\(name)”, which only web extensions may ask for") }
                guard permission != .network else { throw invalidManifest("permissions lists “\(name)”, which needs its host list") }
                permissions.insert(permission)
            case let .object(fields):
                if fields.count == 1, case let .array(hosts)? = fields[PluginPermission.network.rawValue] {
                    guard !hosts.isEmpty, network.isEmpty else { throw invalidManifest("permissions.network needs a nonempty host list once") }
                    network = try hosts.map { host in
                        guard case let .string(name) = host, let parsed = PluginNetworkHost(name) else {
                            throw invalidManifest("permissions.network needs DNS host names or wildcard subdomains, without IP addresses, localhost, ports, or paths")
                        }
                        return parsed
                    }
                    permissions.insert(.network)
                    continue
                }
                guard fields.count == 1, case let .array(kinds)? = fields[PluginPermission.ai.rawValue] else { throw malformed }
                for kind in kinds {
                    guard case let .string(name) = kind else { throw malformed }
                    guard let dataKind = AIDataKind(rawValue: name), Self.aiDataKinds.contains(dataKind) else {
                        throw invalidManifest("permissions lists ai with “\(name)”, which is not page or selection")
                    }
                    aiDataKinds.insert(dataKind)
                }
                permissions.insert(.ai)
            default:
                throw malformed
            }
        }
        return (permissions, aiDataKinds, network)
    }

    private static func contributions(_ object: ManifestObject, packageAt root: URL) throws -> PluginContributions {
        var object = object
        let commands = try object.objects("commands").map(command)
        let commandIDs = try unique(commands.map(\.id), in: "contributes.commands")
        let menuItems = try object.objects("menus").map { try menuItem($0, commands: commandIDs) }
        let sidebarItems = try object.objects("sidebarItems").map { try sidebarItem($0, commands: commandIDs, packageAt: root) }
        _ = try unique(sidebarItems.map(\.id), in: "contributes.sidebarItems")
        let settings = try object.objects("settings").map(setting)
        _ = try unique(settings.map(\.key), in: "contributes.settings")
        let check = FunctionBodyCheck()
        let pageScripts = try object.objects("pageScripts").flatMap { try pageScripts($0, packageAt: root, check: check) }
        try object.finish()
        return PluginContributions(commands: commands, menuItems: menuItems, sidebarItems: sidebarItems, settings: settings, pageScripts: pageScripts)
    }

    private static func command(_ object: ManifestObject) throws -> PluginCommand {
        var object = object
        let command = PluginCommand(id: try object.string("id"), title: try object.string("title"), symbol: try object.optionalString("symbol"),
                                    keywords: try object.strings("keywords"), shortcut: try object.optionalString("shortcut").map(PluginShortcut.init),
                                    takesArgument: try object.bool("takesArgument") ?? false)
        try object.finish()
        return command
    }

    /// `location` is `pluginsMenu`, `pageContextMenu` with the `contexts` it shows for, `tabContextMenu`, or `spaceMenu`.
    private static func menuItem(_ object: ManifestObject, commands: Set<String>) throws -> PluginMenuItem {
        var object = object
        let command = try object.listedCommand(commands)
        let location: PluginMenuLocation
        switch try object.string("location") {
        case "pluginsMenu": location = .pluginsMenu
        case "tabContextMenu": location = .tabContextMenu
        case "spaceMenu": location = .spaceMenu
        case "pageContextMenu":
            let contexts = try object.strings("contexts").map { name in
                guard let context = PluginPageContext(rawValue: name) else {
                    throw invalidManifest("\(object.path).contexts lists “\(name)”; contexts are page, link, image, selection, and editable")
                }
                return context
            }
            guard !contexts.isEmpty else { throw invalidManifest("\(object.path).contexts is missing") }
            location = .pageContextMenu(Set(contexts))
        default:
            throw invalidManifest("\(object.path).location must be pluginsMenu, pageContextMenu, tabContextMenu, or spaceMenu")
        }
        let item = PluginMenuItem(command: command, location: location, title: try object.optionalString("title"))
        try object.finish()
        return item
    }

    /// A script plugin's sidebar item runs the command that `command` names or shows the HTML file of the package that `panel` names in a panel, and takes one of the two.
    private static func sidebarItem(_ object: ManifestObject, commands: Set<String>, packageAt root: URL) throws -> PluginSidebarItem {
        var object = object
        let id = try object.string("id")
        let title = try object.string("title")
        let symbol = try object.string("symbol")
        let presentationName = try object.optionalString("presentation") ?? "popover"
        guard let presentation = PluginSidebarItem.Presentation(rawValue: presentationName) else {
            throw invalidManifest("\(object.path).presentation must be popover or sidebar")
        }
        let action: PluginSidebarItem.Action
        if let page = try object.optionalString("panel") {
            guard object.value("command") == nil else { throw invalidManifest("\(object.path) takes a command or a panel, not both") }
            _ = try packageFile(page, in: root, named: "\(object.path).panel")
            guard UTType(filenameExtension: (page as NSString).pathExtension)?.conforms(to: .html) == true else {
                throw invalidManifest("\(object.path).panel names “\(page)”, which is not an HTML file")
            }
            action = .panel(page: page)
        } else {
            guard presentation == .popover else { throw invalidManifest("\(object.path).presentation sidebar needs a panel") }
            action = .command(try object.listedCommand(commands))
        }
        try object.finish()
        return PluginSidebarItem(id: id, title: title, symbol: symbol, action: action, presentation: presentation)
    }

    /// `type` is `toggle`, `text`, `number` with an optional `min` and `max`, `choice` with its `options`, or `secret`. Each but a secret takes an optional `default`: false, empty text, the minimum or 0, and the first option without one.
    private static func setting(_ object: ManifestObject) throws -> PluginSetting {
        var object = object
        let key = try object.string("key")
        let title = try object.string("title")
        let help = try object.optionalString("help")
        let type = try object.string("type")
        let defaultValue = object.value("default")
        let mismatch = invalidManifest("\(object.path).default does not suit a \(type) setting")
        let kind: PluginSetting.Kind
        switch (type, defaultValue) {
        case ("toggle", nil): kind = .toggle(default: false)
        case let ("toggle", .bool(value)?): kind = .toggle(default: value)
        case ("text", nil): kind = .text(default: "")
        case let ("text", .string(value)?): kind = .text(default: value)
        case ("number", _):
            let range: ClosedRange<Double>?
            switch (try object.number("min"), try object.number("max")) {
            case (nil, nil): range = nil
            case let (min?, max?) where min <= max: range = min...max
            default: throw invalidManifest("\(object.path) needs both min and max, with min at most max")
            }
            let value: Double
            switch defaultValue {
            case nil: value = range?.lowerBound ?? 0
            case let .number(number)? where range?.contains(number) ?? true: value = number
            default: throw mismatch
            }
            kind = .number(default: value, range: range)
        case ("choice", _):
            let options = try object.strings("options")
            guard !options.isEmpty else { throw invalidManifest("\(object.path).options is missing") }
            switch defaultValue {
            case nil: kind = .choice(default: options[0], options: options)
            case let .string(value)? where options.contains(value): kind = .choice(default: value, options: options)
            default: throw mismatch
            }
        case ("secret", nil): kind = .secret
        case ("toggle", _), ("text", _), ("secret", _): throw mismatch
        default: throw invalidManifest("\(object.path).type must be toggle, text, number, choice, or secret")
        }
        try object.finish()
        return PluginSetting(key: key, title: title, help: help, kind: kind)
    }

    /// One page script for each file that `js` lists, each with the entry's patterns and timing, after one that adds the style files that `css` lists, in their order, with the same patterns and timing. An entry lists `js`, `css`, or both. `runAt` is `documentStart` or `documentEnd`, the default.
    private static func pageScripts(_ object: ManifestObject, packageAt root: URL, check: FunctionBodyCheck) throws -> [PluginPageScript] {
        var object = object
        let matches = try object.strings("matches").map(MatchPattern.init)
        guard !matches.isEmpty else { throw invalidManifest("\(object.path).matches is missing") }
        let excludes = try object.strings("excludes").map(MatchPattern.init)
        let files = try object.strings("js")
        let styleFiles = try object.strings("css")
        guard !files.isEmpty || !styleFiles.isEmpty else { throw invalidManifest("\(object.path) needs js or css") }
        let runAt = try object.optionalString("runAt").map { name in
            guard let time = EnginePageScriptInjectionTime(rawValue: name) else { throw invalidManifest("\(object.path).runAt must be documentStart or documentEnd") }
            return time
        } ?? .documentEnd
        let allFrames = try object.bool("allFrames") ?? false
        try object.finish()
        let entry = object.path
        func text(_ path: String, _ field: String) throws -> String {
            let url = try packageFile(path, in: root, named: "\(entry).\(field)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw invalidManifest("\(path) is not UTF-8 text") }
            return text
        }
        let styles = try styleFiles.map { try text($0, "css") }
        let scripts = try files.map { path in
            let source = try text(path, "js")
            guard check.accepts(source) else { throw invalidManifest("\(path) does not parse as the body of a function, as a page script must") }
            return PluginPageScript(matches: matches, excludes: excludes, source: source, runAt: runAt, allFrames: allFrames)
        }
        guard !styles.isEmpty else { return scripts }
        return [PluginPageScript(matches: matches, excludes: excludes, source: "", styles: styles, runAt: runAt, allFrames: allFrames)] + scripts
    }

    /// The identifiers as a set. Throws for one listed twice.
    private static func unique(_ ids: [String], in path: String) throws -> Set<String> {
        var seen: Set<String> = []
        for id in ids where !seen.insert(id).inserted {
            throw invalidManifest("\(path) lists “\(id)” twice")
        }
        return seen
    }
}

/// The file of the package at `path`, which the manifest field `name` gives. Throws for a path that is not a file of the package.
private func packageFile(_ path: String, in root: URL, named name: String) throws -> URL {
    guard let url = PluginPackage.file(path, in: root) else { throw invalidManifest("\(name) names “\(path)”, which is not a file of the package") }
    return url
}

/// A manifest problem, stated as a clause, as a sentence that names the file.
private func invalidManifest(_ problem: String) -> PluginError {
    .invalidPackage("plugin.json: \(problem).")
}

/// One JSON object of `plugin.json`, read one key at a time. `finish()` refuses the keys that nothing read. A key with `null` counts as missing.
private struct ManifestObject {
    /// Where the object sits in the manifest, such as `contributes.commands[0]`, for messages; empty for the manifest itself.
    let path: String
    private var fields: [String: PluginValue]

    init(_ value: PluginValue, at path: String) throws {
        guard case let .object(fields) = value else { throw invalidManifest(path.isEmpty ? "the manifest must be a JSON object" : "\(path) must be an object") }
        self.path = path
        self.fields = fields
    }

    /// The value of `key`, which counts as read.
    mutating func value(_ key: String) -> PluginValue? {
        let value = fields.removeValue(forKey: key)
        return value == .null ? nil : value
    }

    mutating func string(_ key: String) throws -> String {
        guard let text = try optionalString(key) else { throw invalidManifest("\(name(key)) is missing") }
        return text
    }

    /// Text that is not empty. Empty text is refused as empty, as an empty `name` is, as Chromium refuses an extension's, while a `name` of nothing but spaces takes the plugin's `id`.
    mutating func optionalString(_ key: String) throws -> String? {
        switch value(key) {
        case nil: return nil
        case let .string(text)? where !text.isEmpty: return text
        case .string?: throw invalidManifest("\(name(key)) must not be empty")
        default: throw invalidManifest("\(name(key)) must be text")
        }
    }

    mutating func number(_ key: String) throws -> Double? {
        switch value(key) {
        case nil: return nil
        case let .number(number)?: return number
        default: throw invalidManifest("\(name(key)) must be a number")
        }
    }

    /// A whole number from 1.
    mutating func wholeNumber(_ key: String) throws -> Int {
        guard let number = try number(key), number >= 1, number <= Double(Int32.max), number == number.rounded() else {
            throw invalidManifest("\(name(key)) must be a whole number from 1")
        }
        return Int(number)
    }

    mutating func bool(_ key: String) throws -> Bool? {
        switch value(key) {
        case nil: return nil
        case let .bool(flag)?: return flag
        default: throw invalidManifest("\(name(key)) must be true or false")
        }
    }

    /// An array of text, empty when the object has none.
    mutating func strings(_ key: String) throws -> [String] {
        guard let value = value(key) else { return [] }
        guard case let .array(items) = value else { throw invalidManifest("\(name(key)) must be an array of text") }
        return try items.map { item in
            guard case let .string(text) = item else { throw invalidManifest("\(name(key)) must be an array of text") }
            return text
        }
    }

    mutating func object(_ key: String) throws -> ManifestObject? {
        try value(key).map { try ManifestObject($0, at: name(key)) }
    }

    /// An array of objects, empty when the object has none.
    mutating func objects(_ key: String) throws -> [ManifestObject] {
        guard let value = value(key) else { return [] }
        guard case let .array(items) = value else { throw invalidManifest("\(name(key)) must be an array") }
        return try items.enumerated().map { try ManifestObject($1, at: "\(name(key))[\($0)]") }
    }

    /// The `command` key, which must name one of `commands`.
    mutating func listedCommand(_ commands: Set<String>) throws -> String {
        let command = try string("command")
        guard commands.contains(command) else { throw invalidManifest("\(name("command")) names “\(command)”, which contributes.commands does not list") }
        return command
    }

    /// Throws for a key that nothing read.
    func finish() throws {
        if let key = fields.keys.sorted().first {
            throw invalidManifest("\(name(key)) is not a field Arch reads")
        }
    }

    private func name(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}
