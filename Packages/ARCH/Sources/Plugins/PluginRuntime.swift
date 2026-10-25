// The runtimes the app supplies for installed plugins of kinds that the manager does not run itself, such as web extensions, which the `Extensions` module runs. The manager runs built-in and script plugins itself.
import ARCHEngine
import Foundation

/// What one engine's runtime found when it checked a package, without running any of it.
public enum PluginEngineCheck: Hashable, Sendable {
    case runs
    /// With why, as a sentence that names the engine, such as `WebKit cannot run this extension: …`.
    case refused(String)
}

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
    /// The engines that run plugins of the kind on this Mac now, each with the version of its runtime, which the manager records with each answer. Empty for kinds that Arch runs alike on every engine.
    var engines: [EngineKind: String] { get }
    /// Checks the package folder at `root` in each engine of `engines`, without running any of it. The manager calls it at staging, for the package and for the installed plugin it could update.
    func check(packageAt root: URL) async -> [EngineKind: PluginEngineCheck]
    /// Set by the manager: tells it that an enabled plugin cannot run, with why as a sentence, so that it switches the plugin off and Settings shows why.
    var onFailure: ((PluginID, String) -> Void)? { get set }
    /// Set by the manager, which records each answer with the engine's version: engines without a current answer checked an enabled plugin's package before loading it.
    var onCheck: ((PluginID, [EngineKind: PluginEngineCheck]) -> Void)? { get set }
    /// Set by the manager: a plugin's package that the engine's check passed failed to start there, with why as a sentence. The manager keeps the failure for the run and switches the plugin off once it has failed on every engine it ran on.
    var onEngineFailure: ((PluginID, EngineKind, String) -> Void)? { get set }
    /// The enabled plugins of the kind, each time they change; none while `unavailability` says why the kind cannot run.
    func run(_ enabled: [InstalledPlugin])
    /// A new instance of an enabled plugin of the kind, which the manager starts at the plugin's first command.
    func makePlugin(_ installed: InstalledPlugin) -> any Plugin
    /// Deletes what the runtime keeps of a plugin the user removes, such as a web extension's storage in the engines.
    func remove(_ installed: InstalledPlugin)
}
