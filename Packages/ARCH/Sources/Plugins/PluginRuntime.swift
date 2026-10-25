// The runtimes the app supplies for installed plugins of kinds that the manager does not run itself, such as web extensions, which the `Extensions` module runs. The manager runs built-in and script plugins itself.
import Foundation

/// Runs the installed plugins of one kind in one Persona. The manager reads the packages of the kind through it, tells it which of them are enabled, so that it runs what an enabled plugin runs without being asked, such as a web extension's content scripts, and makes the plugins' instances through it.
@MainActor
public protocol PluginRuntime: AnyObject, Sendable {
    nonisolated var kind: PluginKind { get }
    /// The file at the top of a package of the kind, such as `manifest.json`, by which staging tells a package's kind.
    nonisolated var manifestFileName: String { get }
    /// Reads the manifest of the package folder at `root`, which came from the folder or archive at `source`, without running any of it. Called off the main thread. Throws `PluginError.invalidPackage` for a package that Arch cannot install.
    nonisolated func manifest(forPackageAt root: URL, source: URL) throws -> PluginManifest
    /// Why plugins of the kind cannot run on this Mac, as Settings says it, or nil while they can. The manager leaves out their contributions meanwhile.
    var unavailability: String? { get }
    /// Set by the manager: tells it that an enabled plugin cannot run, with why as a sentence, so that it switches the plugin off and Settings shows why.
    var onFailure: ((PluginID, String) -> Void)? { get set }
    /// The enabled plugins of the kind, each time they change; none while `unavailability` says why the kind cannot run.
    func run(_ enabled: [InstalledPlugin])
    /// A new instance of an enabled plugin of the kind, which the manager starts at the plugin's first command.
    func makePlugin(_ installed: InstalledPlugin) -> any Plugin
    /// Deletes what the runtime keeps of a plugin the user removes, such as a web extension's storage in the engines.
    func remove(_ installed: InstalledPlugin)
}
