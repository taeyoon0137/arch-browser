// New Feature with AI in Settings ▸ Plugins: the user describes a feature, the composer has AI write a plugin for it, and the review sheet shows the plugin, from which the user can ask for changes, install it, or discard it. Nothing of the plugin runs before the user installs and enables it.
import AI
import Plugins
import SwiftUI

/// The request field, or the review of the version AI wrote last. Each change replaces the version under review once AI has written it.
struct PluginComposerSheet: View {
    @ObservedObject var plugins: PluginManager
    @Environment(\.dismiss) private var dismiss
    @State private var composer: PluginComposer
    /// The version under review, staged until the user installs or discards it.
    @State private var draft: PluginPackage?
    /// Whether the review shows the draft, rather than the field for a change to it.
    @State private var isReviewing = false
    /// The request, or the change the user asks for.
    @State private var text = ""
    @State private var writing: Task<Void, Never>?
    /// Why the last request failed.
    @State private var failure: Error?

    init(plugins: PluginManager) {
        self.plugins = plugins
        _composer = State(initialValue: PluginComposer(plugins: plugins, service: .shared))
    }

    var body: some View {
        Group {
            if isReviewing, let draft {
                PluginInstallSheet(plugins: plugins, review: PluginReview(package: draft)) { isReviewing = false }
                    .id(draft.id)
            } else {
                requestForm
            }
        }
        // Closing the sheet any way, such as deleting its Persona, stops the request and discards the draft, which an install has already moved.
        .onDisappear {
            writing?.cancel()
            if let draft { plugins.discard(draft) }
        }
    }

    private var requestForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.map { "Change \u{201C}\($0.manifest.name)\u{201D}" } ?? "New Feature with AI")
                    .font(.headline)
                Text(draft == nil
                     ? "Describe what the feature should do. AI writes a plugin for it, and you review its permissions and code before any of it runs."
                     : "Describe what to change. AI writes the plugin again, and you review it before any of it runs.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(draft == nil ? "Feature" : "Change", text: $text, axis: .vertical)
                .lineLimit(4...10)
                .textFieldStyle(.roundedBorder)
                .disabled(writing != nil)
            if writing != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing the plugin\u{2026}").foregroundStyle(.secondary)
                }
            } else if let failure {
                Text(failure.localizedDescription)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if Self.isFixedInSettings(failure) {
                    Button("Open AI Settings") {
                        dismiss()
                        PreferencesWindowController.shared.showAISection()
                    }
                }
            }
            HStack {
                Spacer()
                Button(draft == nil ? "Cancel" : "Discard", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if draft != nil {
                    Button("Back to Review") { isReviewing = true }
                        .disabled(writing != nil)
                }
                if writing != nil {
                    Button("Stop") { writing?.cancel() }
                } else {
                    Button("Write Plugin", action: write)
                        .keyboardShortcut(.defaultAction)
                        .disabled(request.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private var request: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes the plugin, or the change to the draft, and shows the new version's review. A stopped request leaves the field as it was.
    private func write() {
        let request = request
        failure = nil
        writing = Task {
            do {
                let package = try await composer.write(request)
                if let draft { plugins.discard(draft) }
                draft = package
                text = ""
                isReviewing = true
            } catch AIError.cancelled {
                // Stopped by the user.
            } catch {
                failure = error
            }
            writing = nil
        }
    }

    /// Whether Settings ▸ AI fixes the failure, as it does the AI interface's errors about models, keys, and limits.
    private static func isFixedInSettings(_ failure: Error) -> Bool {
        switch failure as? AIError {
        case .notConfigured?, .authentication?, .budgetReached?: return true
        default: return false
        }
    }
}
