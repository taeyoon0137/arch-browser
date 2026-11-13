// The store sheet (`docs/web-store.md`, Entry points and Updates): a field for a Web Store address or an extension identifier, whose Continue asks the store for the extension's current package and stages it, with progress while it runs and the install flow's failures, after which the package's review takes the sheet's place. `PluginInstallSheet` shows it as its first step for Install from Web Store… and From the Web Store… in Settings ▸ Plugins, for a start from a store page or the palette, which fills in the identifier and asks at once, and, without the field, for a plugin's Review Update…, which downloads the update at once. Cancel, closing the sheet, and deleting the Persona cancel the install, which then leaves nothing staged.
import ARCHEngine
import Extensions
import Plugins
import SwiftUI

/// What the store sheet starts with: the field's text, and, for From the Web Store… in Install <Engine> Version…, the plugin and the engine whose version the package becomes.
struct WebStoreStart {
    var text = ""
    var versionOf: PluginID?
    var engine: EngineKind?
    /// For Review Update…, the plugin installed from the store whose newer version the last update check found (`WebStoreInstaller.stageUpdate(of:in:)`); the sheet then has no field.
    var update: PluginID?
    /// Asks the store as the sheet appears, for a start from a store page or the palette, whose identifier `text` holds.
    var startsAtOnce = false
}

struct WebStoreInstallSheet: View {
    @ObservedObject var plugins: PluginManager
    let installer: WebStoreInstaller
    let start: WebStoreStart
    let close: () -> Void
    /// Puts the staged package's review in the sheet's place.
    let review: (PluginReview) -> Void
    @State private var text: String
    /// The install under way, whose task Cancel cancels.
    @State private var install: Task<Void, Never>?
    @State private var hasStarted = false
    /// Why the last install failed.
    @State private var failure: String?
    /// That the Persona has the store's current version installed from the store, after which the sheet offers Done.
    @State private var installedNote: String?

    init(plugins: PluginManager, installer: WebStoreInstaller, start: WebStoreStart, close: @escaping () -> Void, review: @escaping (PluginReview) -> Void) {
        self.plugins = plugins
        self.installer = installer
        self.start = start
        self.close = close
        self.review = review
        _text = State(initialValue: start.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text("Arch downloads the extension\u{2019}s current package from the Web Store, and you review what it asks for before it installs.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if start.update == nil {
                TextField("Web Store address or extension ID", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .disabled(install != nil)
                    .onSubmit(begin)
            }
            if install != nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Getting the extension from the Web Store\u{2026}")
                        .foregroundStyle(.secondary)
                }
            }
            if let installedNote {
                Text(installedNote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if installedNote != nil {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        install?.cancel()
                        close()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Continue", action: begin)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canBegin || install != nil)
                }
            }
        }
        .onAppear {
            guard start.startsAtOnce, !hasStarted else { return }
            hasStarted = true
            begin()
        }
        .onChange(of: text) {
            failure = nil
            installedNote = nil
        }
        // A Persona deleted during a download would otherwise let the download run to its end.
        .onChange(of: plugins.isClosed) { _, isClosed in
            if isClosed { install?.cancel() }
        }
        .onDisappear { install?.cancel() }
    }

    private var title: String {
        if let update = start.update, let plugin = plugins.plugins.first(where: { $0.id == update }) {
            return "Update \u{201C}\(plugin.manifest.name)\u{201D} from the Web Store"
        }
        guard let engine = start.engine, let plugin = start.versionOf.flatMap(plugins.leadVersion(of:)) else { return "Install from the Web Store" }
        return "Install the \(engine.displayName) Version of \u{201C}\(plugin.manifest.name)\u{201D} from the Web Store"
    }

    /// Whether Continue has something to stage: the update, or the extension that the field names.
    private var canBegin: Bool {
        start.update != nil || WebStore.extensionID(from: text) != nil
    }

    /// Stages the update, or asks the store for the extension that the field names and stages its package, for the review, unless the install was cancelled, which ends it without a message.
    private func begin() {
        guard install == nil, canBegin else { return }
        let id = WebStore.extensionID(from: text)
        failure = nil
        installedNote = nil
        install = Task {
            do {
                let package: PluginPackage
                if let update = start.update {
                    package = try await installer.stageUpdate(of: update, in: plugins)
                } else {
                    package = try await installer.stage(id ?? text, in: plugins)
                }
                review(PluginReview(package: package, versionOf: start.versionOf, engine: start.engine))
            } catch is CancellationError {
                // Cancel, closing the sheet, or deleting the Persona ended it, and the sheet closes without a message.
            } catch let error as WebStoreError {
                if case .alreadyInstalled = error { installedNote = error.localizedDescription } else { failure = error.localizedDescription }
            } catch {
                failure = error.localizedDescription
            }
            install = nil
        }
    }
}
