// `plugin.json`, the manifest of a script plugin's package, read into a `PluginManifest`. Arch refuses the keys it does not read, so that a plugin never goes without a field it relies on, and reads each page script from the package file the manifest names.
import ARCHEngine
import Events
import Foundation

/// What a package's `plugin.json` declares.
struct ScriptManifest {
    static let fileName = "plugin.json"

    let manifest: PluginManifest
    /// The package path of the background script, which commands and page script values reach. A plugin without one adds only page scripts and settings.
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
        let name = try object.string("name")
        let version = try object.string("version")
        let summary = try object.string("summary")
        let permissions = try object.strings("permissions").map { name in
            guard let permission = PluginPermission(rawValue: name) else { throw invalidManifest("permissions lists “\(name)”, which Arch does not grant") }
            guard permission != .nativeMessaging else { throw invalidManifest("permissions lists “\(name)”, which only web extensions may ask for") }
            return permission
        }
        let sites = try object.strings("sites").map(MatchPattern.init)
        let events = try object.strings("events").map { name in
            guard let kind = BrowserEventKind(rawValue: name) else { throw invalidManifest("events lists “\(name)”, which is not an event Arch sends") }
            return kind
        }
        let background = try object.optionalString("background")
        if let background { _ = try packageFile(background, in: root, named: "background") }
        let contributions = try object.object("contributes").map { try Self.contributions($0, packageAt: root) } ?? PluginContributions()
        try object.finish()
        guard background != nil || contributions.commands.isEmpty else { throw invalidManifest("commands need a background script") }
        guard background != nil || events.isEmpty else { throw invalidManifest("events need a background script") }
        manifest = PluginManifest(id: id, name: name, version: version, summary: summary, permissions: Set(permissions), sites: sites, contributions: contributions, events: Set(events))
        self.background = background
    }

    private static func contributions(_ object: ManifestObject, packageAt root: URL) throws -> PluginContributions {
        var object = object
        let commands = try object.objects("commands").map(command)
        let commandIDs = try unique(commands.map(\.id), in: "contributes.commands")
        let menuItems = try object.objects("menus").map { try menuItem($0, commands: commandIDs) }
        let sidebarItems = try object.objects("sidebarItems").map { try sidebarItem($0, commands: commandIDs) }
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
                                    keywords: try object.strings("keywords"), shortcut: try object.optionalString("shortcut").map(PluginShortcut.init))
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

    /// A script plugin's sidebar item runs a command.
    private static func sidebarItem(_ object: ManifestObject, commands: Set<String>) throws -> PluginSidebarItem {
        var object = object
        let item = PluginSidebarItem(id: try object.string("id"), title: try object.string("title"), symbol: try object.string("symbol"),
                                     action: .command(try object.listedCommand(commands)))
        try object.finish()
        return item
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

    /// One page script for each file that `js` lists, each with the entry's patterns and timing. `runAt` is `documentStart` or `documentEnd`, the default.
    private static func pageScripts(_ object: ManifestObject, packageAt root: URL, check: FunctionBodyCheck) throws -> [PluginPageScript] {
        var object = object
        let matches = try object.strings("matches").map(MatchPattern.init)
        guard !matches.isEmpty else { throw invalidManifest("\(object.path).matches is missing") }
        let excludes = try object.strings("excludes").map(MatchPattern.init)
        let files = try object.strings("js")
        guard !files.isEmpty else { throw invalidManifest("\(object.path).js is missing") }
        let runAt = try object.optionalString("runAt").map { name in
            guard let time = EnginePageScriptInjectionTime(rawValue: name) else { throw invalidManifest("\(object.path).runAt must be documentStart or documentEnd") }
            return time
        } ?? .documentEnd
        let allFrames = try object.bool("allFrames") ?? false
        try object.finish()
        return try files.map { path in
            let url = try packageFile(path, in: root, named: "\(object.path).js")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { throw invalidManifest("\(path) is not UTF-8 text") }
            guard check.accepts(source) else { throw invalidManifest("\(path) does not parse as the body of a function, as a page script must") }
            return PluginPageScript(matches: matches, excludes: excludes, source: source, runAt: runAt, allFrames: allFrames)
        }
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

    /// Text that is not empty.
    mutating func optionalString(_ key: String) throws -> String? {
        switch value(key) {
        case nil: return nil
        case let .string(text)? where !text.isEmpty: return text
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
