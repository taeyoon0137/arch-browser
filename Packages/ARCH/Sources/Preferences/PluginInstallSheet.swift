// The review sheet of a plugin package the user chose to install or update, a web extension's among them, or that AI wrote: its name, version, origin, where it runs and which engines refused it, the permissions and sites it asks for in plain sentences, and its files, with the source of each for a plugin that AI wrote, after the requests it came from. The user can leave sites out before installing, and granting every website or native apps asks for Touch ID or the login password. An update from another place than the installed plugin's comes with a warning, as identifiers are not signed and such a package takes over the plugin's data.
import LocalAuthentication
import Plugins
import SwiftUI

struct PluginInstallSheet: View {
    @ObservedObject var plugins: PluginManager
    let package: PluginPackage
    /// The installed plugin that the package updates, if any.
    private let installed: InstalledPlugin?
    /// Takes the user back to the composer of a plugin that AI wrote, to ask for a change.
    private let askForChanges: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    /// The sites the user grants: at first all that the manifest asks for, except, in an update, those that the installed version asked for and the user left out.
    @State private var sites: Set<MatchPattern>
    /// Why the last install failed.
    @State private var failure: String?

    init(plugins: PluginManager, package: PluginPackage, askForChanges: (() -> Void)? = nil) {
        self.plugins = plugins
        self.package = package
        self.askForChanges = askForChanges
        let installed = plugins.plugins.first { $0.id == package.manifest.id }
        self.installed = installed
        let offered = installed.map { PluginGrant(updating: $0, to: package.manifest) } ?? PluginGrant(requestedBy: package.manifest)
        _sites = State(initialValue: Set(offered.sites))
    }

    var body: some View {
        let manifest = package.manifest
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(installed == nil ? "Install “\(manifest.name)”?" : "Update “\(manifest.name)”?")
                    .font(.headline)
                Text("Version \(manifest.version) \(origin). \(manifest.summary)")
                    .foregroundStyle(.secondary)
                if let note = package.kind.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                ForEach(package.engineNotes, id: \.self) { note in
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if let otherSourceWarning {
                    Label(otherSourceWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Form {
                if let composition {
                    Section("Requests") {
                        ForEach(composition.requests.indices, id: \.self) { Text(composition.requests[$0]) }
                    }
                }
                Section("Access") {
                    let permissions = PluginPermission.allCases.filter(manifest.permissions.contains)
                    if permissions.isEmpty && manifest.sites.isEmpty && manifest.extensionPermissions.isEmpty {
                        Text("None")
                    }
                    ForEach(permissions, id: \.self) { permission in
                        RequestRow(text: permission.summary, isNew: installed.map { !$0.manifest.permissions.contains(permission) } ?? false)
                    }
                    if let summary = manifest.extensionPermissionsSummary {
                        RequestRow(text: summary, isNew: installed.map { !Set(manifest.extensionPermissions).isSubset(of: $0.manifest.extensionPermissions) } ?? false)
                    }
                    ForEach(manifest.sites, id: \.self) { site in
                        Toggle(isOn: Binding(get: { sites.contains(site) }, set: { if $0 { sites.insert(site) } else { sites.remove(site) } })) {
                            RequestRow(text: site.accessSummary, isNew: installed.map { !$0.manifest.sites.contains(site) } ?? false)
                            Text(site.description)
                        }
                    }
                }
                Section("Files") {
                    ForEach(package.files, id: \.self) { path in
                        if composition == nil {
                            Text(path).font(.system(.body, design: .monospaced))
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(path).font(.system(.body, design: .monospaced).weight(.semibold))
                                Text(package.text(of: path) ?? "")
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    plugins.discard(package)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if let askForChanges {
                    Button("Ask for Changes\u{2026}", action: askForChanges)
                }
                if let installed {
                    Button("Update") { install(isEnabled: installed.isEnabled) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Install") { install(isEnabled: false) }
                    Button("Install and Enable") { install(isEnabled: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        // A plugin that AI wrote shows its sources.
        .frame(width: composition == nil ? 480 : 600, height: composition == nil ? 520 : 640)
        .interactiveDismissDisabled()
    }

    /// How AI wrote the package, if it did.
    private var composition: PluginComposition? {
        guard case let .generated(composition) = package.origin else { return nil }
        return composition
    }

    /// Where the package came from, as the subtitle says it.
    private var origin: String {
        switch package.origin {
        case .bundled: return "built into Arch"
        case let .file(url): return "from \(url.lastPathComponent)"
        case let .generated(composition): return "written by AI with \(composition.model)"
        }
    }

    /// The warning for a package that updates the installed plugin from another place: another file than the one it was installed from, or a file for a plugin that AI wrote.
    private var otherSourceWarning: String? {
        guard let installed else { return nil }
        let replaces = "This package replaces \u{201C}\(installed.manifest.name)\u{201D}"
        switch (installed.origin, package.origin) {
        case let (.file(source), .file(packageSource)) where packageSource.standardizedFileURL.path == source.standardizedFileURL.path:
            return nil
        case let (.file(source), _):
            return "\(replaces), which you installed from \(source.lastPathComponent), and takes over its data. Update only if both come from the same developer."
        case (.generated, .file):
            return "\(replaces), which AI wrote, and takes over its data. Update only if you made this package from it."
        default:
            return nil
        }
    }

    /// Installs with every permission the manifest asks for and the chosen sites, once the user confirms a grant of every website or of native apps.
    private func install(isEnabled: Bool) {
        let grant = PluginGrant(permissions: package.manifest.permissions, sites: package.manifest.sites.filter(sites.contains))
        Task {
            if let reason = grant.confirmationReason(for: package.manifest.name) {
                guard await Self.authorize(reason) else { return }
            }
            do {
                try plugins.install(package, grant: grant, isEnabled: isEnabled)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Touch ID or the login password through LocalAuthentication.
    private static func authorize(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// One thing the plugin asks for, marked when an update asks for it and the installed version did not.
private struct RequestRow: View {
    let text: String
    let isNew: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if isNew {
                Text("New")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
        }
    }
}
