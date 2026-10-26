// Settings ▸ AI ▸ Providers: the sheet that adds or edits a command-line tool, with its executable, arguments, environment, output format, whether it runs without its own tools, its models, and its limits. Open Terminal and Check help set it up.
import AI
import AppKit
import SwiftUI

/// A command-line tool being added or edited. Nothing reaches `ai.json` until the user saves.
struct AICommandLineDraft: Identifiable {
    struct Argument: Identifiable {
        let id = UUID()
        var value: String
    }

    enum OutputFormat {
        case text
        case jsonLines
    }

    let id: AIProviderID
    let isNew: Bool
    var name: String
    /// A path, or a name that Find looks up in the login shell's PATH.
    var executable: String
    var arguments: [Argument]
    var environment: [AINameValue]
    var outputFormat: OutputFormat
    /// Kept while plain text is chosen, so switching back to JSON lines restores them.
    var paths: AIJSONLinePaths
    var runsWithoutTools: Bool
    var models: [AIModelConfiguration]
    var limits: AIProviderLimits

    /// A new tool starts with the tool's own default model.
    init() {
        id = AIProviderID()
        isNew = true
        name = "New Tool"
        executable = ""
        arguments = []
        environment = []
        outputFormat = .text
        paths = AIJSONLinePaths()
        runsWithoutTools = false
        models = [AIModelConfiguration(name: "")]
        limits = .commandLine
    }

    init(_ provider: AIProviderConfiguration, tool: AICommandLineConfiguration) {
        id = provider.id
        isNew = false
        name = provider.name
        executable = tool.executable.path
        arguments = tool.arguments.map { Argument(value: $0) }
        environment = AINameValue.rows(tool.environment)
        switch tool.output {
        case .text:
            outputFormat = .text
            paths = AIJSONLinePaths()
        case .jsonLines(let jsonPaths):
            outputFormat = .jsonLines
            paths = jsonPaths
        }
        runsWithoutTools = tool.runsWithoutTools
        models = provider.models
        limits = provider.limits
    }

    /// The executable, if it is an absolute path to a file this user may run.
    var executableURL: URL? {
        let path = (executable.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        return AICommandLineConfiguration.isExecutable(at: url) ? url : nil
    }

    var configuration: AIProviderConfiguration? {
        guard let executableURL, !name.trimmingCharacters(in: .whitespaces).isEmpty, !models.isEmpty else { return nil }
        let tool = AICommandLineConfiguration(executable: executableURL,
                                              arguments: arguments.map(\.value).filter { !$0.isEmpty },
                                              environment: AINameValue.dictionary(environment),
                                              output: outputFormat == .text ? .text : .jsonLines(paths),
                                              runsWithoutTools: runsWithoutTools)
        return AIProviderConfiguration(id: id, name: name.trimmingCharacters(in: .whitespaces), kind: .commandLine(tool), models: models, limits: limits)
    }
}

struct AICommandLineEditor: View {
    @State var draft: AICommandLineDraft
    let service: AIService
    @ObservedObject var settings: AISettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var isLocating = false
    @State private var message: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkResult: String?
    @State private var checkFailed = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                toolSection
                argumentsSection
                Section {
                    AINameValueRows(rows: $draft.environment, addTitle: "Add Variable")
                } header: {
                    Text("Environment")
                } footer: {
                    aiFootnote("The tool runs with only HOME, USER, LOGNAME, SHELL, PATH from your login shell, LANG, TMPDIR, and TERM, plus these variables. They are saved in ai.json, so they must not hold secrets.")
                }
                outputSection
                Section {
                    Toggle("Runs without its own tools", isOn: $draft.runsWithoutTools)
                } footer: {
                    aiFootnote("Turn this on only if the arguments stop the tool from running commands, editing files, or using other tools of its own. Text in a page could otherwise steer the tool, so until then it gets no page, selection, file, or download data. Arch cannot check this; it only runs the tool in an empty folder with a small environment.")
                }
                Section {
                    AIModelList(models: $draft.models, defaultCapabilities: AICommandLineConfiguration.capabilities) {
                        if !draft.models.contains(where: { $0.name.isEmpty }) {
                            Button("Add Default") { draft.models.insert(AIModelConfiguration(name: ""), at: 0) }
                                .help("Add the tool's own default model")
                        }
                    }
                } header: {
                    Text("Models")
                } footer: {
                    aiFootnote("The default model leaves out the arguments that name a model, so the tool uses its own choice.")
                }
                AIProviderLimitsSection(limits: $draft.limits)
                checkSection
                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            AIProviderEditorButtons(name: draft.name, isNew: draft.isNew, canSave: draft.configuration != nil,
                                    removalNote: "Features that used its models fall back to their other models. The tool and its sign-in stay on this Mac.",
                                    remove: remove, save: save)
        }
        .frame(width: 480, height: 580)
        .onDisappear { checkTask?.cancel() }
    }

    // MARK: Tool

    @ViewBuilder private var toolSection: some View {
        Section {
            TextField("Name", text: $draft.name)
            HStack {
                TextField("Executable", text: $draft.executable, prompt: Text("Name or path"))
                    .onSubmit { Task { await locate() } }
                Button(isLocating ? "Finding\u{2026}" : "Find") { Task { await locate() } }
                    .disabled(isLocating || draft.executable.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Look the name up in your login shell's PATH")
                Button("Choose\u{2026}", action: chooseExecutable)
            }
            if !draft.executable.isEmpty, draft.executableURL == nil {
                Text("Enter the tool's full path, or its name and click Find.").font(.callout).foregroundStyle(.red)
            }
            if let openTerminal = PreferencesWindowController.openTerminal {
                HStack {
                    Spacer()
                    Button("Open Terminal", action: openTerminal)
                }
            }
        } header: {
            Text("Tool")
        } footer: {
            aiFootnote("Install the tool and sign in to it in the terminal. The tool keeps its own sign-in; Arch never reads it.")
        }
    }

    private func locate() async {
        let name = draft.executable
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLocating = true
        defer { isLocating = false }
        if let url = await AICommandLineConfiguration.locateExecutable(named: name) {
            draft.executable = url.path
            message = nil
        } else {
            message = "\(name) is not in your login shell's PATH. Install it in the terminal, or choose the file with Choose\u{2026}."
        }
    }

    /// Hidden folders show too, since tools often install under one in the home folder.
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = draft.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Choose"
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { draft.executable = url.path }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: Arguments and output

    @ViewBuilder private var argumentsSection: some View {
        Section {
            ForEach(draft.arguments) { argument in
                HStack {
                    TextField("Argument", text: rowBinding($draft.arguments, id: argument.id, field: \.value), prompt: Text("Argument"))
                        .labelsHidden()
                    Button {
                        draft.arguments.removeAll { $0.id == argument.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Spacer()
                Button("Add Argument") { draft.arguments.append(AICommandLineDraft.Argument(value: "")) }
            }
        } header: {
            Text("Arguments")
        } footer: {
            aiFootnote("Each row is one argument. \(AICommandLineConfiguration.modelPlaceholder) becomes the model's name, and an argument that contains it is left out for the default model, so write an option and its model as one argument, such as --model=\(AICommandLineConfiguration.modelPlaceholder). The prompt goes to the tool's standard input, never into its arguments.")
        }
    }

    @ViewBuilder private var outputSection: some View {
        Section {
            Picker("Output", selection: $draft.outputFormat) {
                Text("Plain text").tag(AICommandLineDraft.OutputFormat.text)
                Text("JSON lines").tag(AICommandLineDraft.OutputFormat.jsonLines)
            }
            if draft.outputFormat == .jsonLines {
                TextField("Text delta", text: pathBinding(\.textDelta), prompt: Text("delta.text"))
                TextField("Final text", text: pathBinding(\.finalText), prompt: Text("result"))
                TextField("Input tokens", text: pathBinding(\.inputTokens), prompt: Text("usage.input_tokens"))
                TextField("Output tokens", text: pathBinding(\.outputTokens), prompt: Text("usage.output_tokens"))
                TextField("Error", text: pathBinding(\.error), prompt: Text("error.message"))
            }
        } header: {
            Text("Output")
        } footer: {
            aiFootnote(draft.outputFormat == .text
                       ? "The tool's standard output is the reply."
                       : "Each line is a JSON object. Enter the dotted path of each field the tool prints; a number picks an array element. Lines that are not JSON are skipped, and the final text is used when no delta arrives.")
        }
    }

    /// An empty field leaves the path out.
    private func pathBinding(_ field: WritableKeyPath<AIJSONLinePaths, String?>) -> Binding<String> {
        Binding(
            get: { draft.paths[keyPath: field] ?? "" },
            set: { draft.paths[keyPath: field] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) })
    }

    // MARK: Check

    @ViewBuilder private var checkSection: some View {
        Section {
            HStack {
                Spacer()
                if checkTask != nil {
                    Button("Stop") { checkTask?.cancel() }
                } else {
                    Button("Check", action: check)
                        .disabled(draft.configuration == nil)
                }
            }
            if let checkResult {
                Text(checkResult).foregroundStyle(checkFailed ? .red : .secondary).textSelection(.enabled)
            }
        } footer: {
            aiFootnote("Check sends a short request to the first model and shows the reply or the error.")
        }
    }

    private func check() {
        guard let configuration = draft.configuration else { return }
        checkResult = nil
        checkFailed = false
        checkTask = Task {
            do {
                checkResult = try await service.check(configuration).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch AIError.cancelled {
                checkResult = nil
            } catch {
                checkResult = error.localizedDescription
                checkFailed = true
            }
            checkTask = nil
        }
    }

    // MARK: Saving

    private func save() {
        guard let configuration = draft.configuration else { return }
        settings.save(configuration)
        dismiss()
    }

    private func remove() async {
        do {
            try await settings.removeProvider(draft.id)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
