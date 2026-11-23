// Native app status and guidance in Settings ▸ Plugins (`docs/password-managers.md`, Status and guidance in Settings ▸ Plugins): for a web extension whose grant has `nativeMessaging`, which native apps on this Mac accept it, which of their known conditions Arch does not meet, the user's step for the vendors Arch knows, and what the app last did on WebKit tabs. The lines name no Persona, since Settings shows one Persona's plugins and Arch's folder serves every Persona, and no host folder, since those folders name other browser products. Nothing here shows or keeps Arch's team.
import Foundation
import Plugins
import Security

/// Where Arch runs from and how it is signed, which native apps check before they accept a browser: 1Password accepts only a signed browser in the Applications folder that is not reached through a symbolic link (`docs/password-managers.md`, Facts). It keeps only the kind of signature.
public struct ArchInstallation: Equatable, Sendable {
    /// The installation category used to explain native app availability.
    public enum Signing: Equatable, Sendable {
        /// Signed by a developer team.
        case team
        /// Signed without a team, as an ad hoc signature is.
        case adHoc
        /// Not signed.
        case unsigned
    }

    /// The folder that holds the bundle Arch runs from, after symbolic links.
    public let folder: URL
    /// Whether the bundle is directly in the Applications folder and is not a symbolic link.
    public let isInApplications: Bool
    public let signing: Signing

    /// Arch's own bundle and signature, read once per run.
    public static let current = ArchInstallation(bundleURL: Bundle.main.bundleURL, signingInformation: CodeSignature.ownSigningInformation())

    /// The bundle at `bundleURL`, with what `SecCodeCopySigningInformation` gives for its code, nil when that does not read; `applicationsFolder` stands for `/Applications` in tests.
    init(bundleURL: URL, signingInformation: [String: Any]?, applicationsFolder: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        let bundle = bundleURL.standardizedFileURL
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: bundle.path)) != nil
        folder = bundle.resolvingSymlinksInPath().deletingLastPathComponent()
        isInApplications = !isLink && bundle.deletingLastPathComponent().resolvingSymlinksInPath().path == applicationsFolder.resolvingSymlinksInPath().path
        signing = Self.signing(of: signingInformation)
    }

    /// A signature has a signing identifier, and a team's has its team identifier, which this reads only to tell the kinds apart.
    private static func signing(of information: [String: Any]?) -> Signing {
        guard let information, information[kSecCodeInfoIdentifier as String] is String else { return .unsigned }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? .team : .adHoc
    }
}

/// The native app lines of a web extension plugin's section in Settings ▸ Plugins, from what the run's passes found (`NativeMessagingHostLinks`), where Arch runs from (`ArchInstallation`), and what the plugin's calls last met on WebKit tabs (`NativeAppOutcomes`).
@MainActor
public enum NativeAppGuide {
    /// The user's step for each vendor's native app that Arch knows, by host name.
    static let guidance: [String: String] = [
        "com.1password.1password": localized("1Password connects to a browser it does not list only after you allow it. When 1Password asks about Arch, allow it, or add Arch in 1Password\u{2019}s settings for browsers."),
        "com.apple.passwordmanager": localized("iCloud Passwords starts its helper only for the browsers that macOS lists, which come with macOS updates, and for browsers with Apple\u{2019}s browser passkey entitlement."),
    ]

    static let lookingLine = localized("Looking for native apps\u{2026}")

    /// Whether the section of a plugin with these versions, one or a pair's two, shows native app lines: while a version is a web extension whose grant has `nativeMessaging`, on or off.
    public static func applies(to versions: [InstalledPlugin]) -> Bool {
        !callers(among: versions).isEmpty
    }

    /// Has Arch look for native apps, as the section does when it first shows in a run (`NativeMessagingHostLinks.update()`, which runs one pass per run), for a plugin to which the lines apply, on or off.
    public static func look(for versions: [InstalledPlugin], in links: NativeMessagingHostLinks) async {
        guard applies(to: versions) else { return }
        await links.update()
    }

    /// The lines, in order: "Looking for native apps…" until a pass has ended in this run; then each manifest in Arch's folder or among the discovered hosts that allows a version's identifier, by host name, or that no native app accepts the extension, with why Arch may not have seen one; while one does, the conditions Arch does not meet and the vendors' steps; and the last outcome on WebKit tabs.
    public static func lines(for versions: [InstalledPlugin], links: NativeMessagingHostLinks, installation: ArchInstallation, outcomes: NativeAppOutcomes?) -> [String] {
        let callers = callers(among: versions)
        guard !callers.isEmpty else { return [] }
        guard links.hasLooked else { return [lookingLine] }
        let origins = Set(callers.map { NativeMessaging.origin(of: WebExtensionManifest.extensionID(of: $0.manifest.id)) })
        var userHosts: [String: NativeMessagingLinkedHost] = [:]
        for (name, host) in links.userHosts {
            userHosts[name] = NativeMessagingLinkedHost(description: host.description, allowedOrigins: host.allowedOrigins)
        }
        // What Arch's folder holds under each name: one of Arch's links, or the user's file.
        let inArch = links.linkedHosts.merging(userHosts) { $1 }
        var lines: [String] = []
        var apps: [String] = []
        for name in Set(links.hosts.keys).union(inArch.keys).sorted() {
            let discovered = links.hosts[name]
            let archAllows = inArch[name]?.allowedOrigins.map { !origins.isDisjoint(with: $0) } == true
            let discoveredAllows = discovered.map { !origins.isDisjoint(with: $0.allowedOrigins) } == true
            guard archAllows || discoveredAllows else { continue }
            if let discovered, discovered.held != nil {
                lines.append(localized("\(discovered.description), which macOS does not start for Arch on this Mac."))
            } else if archAllows, let host = inArch[name] {
                lines.append(localized("\(host.description), set up for Arch."))
            } else if let discovered {
                lines.append(localized("\(discovered.description), set up for another browser."))
            }
            apps.append(name)
        }
        if apps.isEmpty {
            lines.append(localized("No native app on this Mac accepts this extension."))
            if !links.unreadableFolders.isEmpty { lines.append(localized("macOS kept Arch from reading another browser\u{2019}s native app setup.")) }
        } else {
            lines += conditions(of: installation)
            for name in apps {
                guard let step = guidance[name] else { continue }
                lines.append(step)
                guard HelperLaunchConstraints.constrainedHosts.contains(name), let path = links.userHosts[name]?.path ?? links.hosts[name]?.path,
                      let admits = links.launchConstraintAnswers[path] ?? nil else { continue }
                lines.append(admits ? localized("Arch is among them on this Mac.") : localized("Arch is not among them on this Mac."))
            }
        }
        if let outcome = callers.lazy.compactMap({ outcomes?.outcome(of: $0) }).first { lines.append(outcome.sentence) }
        return lines
    }

    /// The versions that may reach native apps: web extensions whose grant has `nativeMessaging`.
    private static func callers(among versions: [InstalledPlugin]) -> [InstalledPlugin] {
        versions.filter { $0.kind == .webExtension && $0.grant.permissions.contains(.nativeMessaging) }
    }

    /// The conditions of native apps that Arch does not meet: the Applications folder, and a team's signature.
    private static func conditions(of installation: ArchInstallation) -> [String] {
        var lines: [String] = []
        if !installation.isInApplications {
            let folder = (installation.folder.path as NSString).abbreviatingWithTildeInPath
            lines.append(localized("Arch runs from \(folder); some native apps accept only browsers in the Applications folder."))
        }
        if installation.signing != .team { lines.append(localized("Arch is not signed by a developer team; some native apps accept only signed browsers.")) }
        return lines
    }
}
