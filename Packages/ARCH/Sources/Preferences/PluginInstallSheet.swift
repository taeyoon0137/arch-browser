// The review sheet of a plugin package the user chose to install or update: its name, version, origin, the permissions and sites it asks for in plain sentences, and its files. The user can leave sites out before installing, and granting every website asks for Touch ID or the login password.
import LocalAuthentication
import Plugins
import SwiftUI

struct PluginInstallSheet: View {
    @ObservedObject var plugins: PluginManager
    let package: PluginPackage
    @Environment(\.dismiss) private var dismiss
    /// The sites the user grants, all that the manifest asks for at first.
    @State private var sites: Set<MatchPattern>
    /// Why the last install failed.
    @State private var failure: String?

    init(plugins: PluginManager, package: PluginPackage) {
        self.plugins = plugins
        self.package = package
        _sites = State(initialValue: Set(package.manifest.sites))
    }

    /// The installed plugin that the package updates, if any.
    private var installed: InstalledPlugin? {
        plugins.plugins.first { $0.id == package.manifest.id }
    }

    var body: some View {
        let manifest = package.manifest
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(installed == nil ? "Install “\(manifest.name)”?" : "Update “\(manifest.name)”?")
                    .font(.headline)
                Text("Version \(manifest.version) from \(package.sourceURL.lastPathComponent). \(manifest.summary)")
                    .foregroundStyle(.secondary)
            }
            Form {
                Section("Access") {
                    let permissions = PluginPermission.allCases.filter(manifest.permissions.contains)
                    if permissions.isEmpty && manifest.sites.isEmpty {
                        Text("None")
                    }
                    ForEach(permissions, id: \.self) { permission in
                        RequestRow(text: permission.summary, isNew: installed.map { !$0.grant.permissions.contains(permission) } ?? false)
                    }
                    ForEach(manifest.sites, id: \.self) { site in
                        Toggle(isOn: Binding(get: { sites.contains(site) }, set: { if $0 { sites.insert(site) } else { sites.remove(site) } })) {
                            RequestRow(text: site.accessSummary, isNew: installed.map { !$0.grant.sites.contains(site) } ?? false)
                            Text(site.description)
                        }
                    }
                }
                Section("Files") {
                    ForEach(package.files, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
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
        .frame(width: 480, height: 520)
        .interactiveDismissDisabled()
    }

    /// Installs with every permission the manifest asks for and the chosen sites, once the user confirms a grant of every website.
    private func install(isEnabled: Bool) {
        let grant = PluginGrant(permissions: package.manifest.permissions, sites: package.manifest.sites.filter(sites.contains))
        Task {
            if grant.sites.contains(where: \.coversEverySite) {
                guard await Self.authorize("let “\(package.manifest.name)” run scripts on every website") else { return }
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
