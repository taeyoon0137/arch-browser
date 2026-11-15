// Settings ▸ AI ▸ Providers: the sheet that adds or edits a command-line tool, with its executable, arguments, environment, output format, whether it runs without its own tools, its models, and its limits. Open Terminal and Check help set it up. For the Claude Code and Codex presets, Arch builds the arguments and reads the output, so the sheet shows the tool's version and sign-in with Sign In instead (`docs/agents.md`, Connecting a subscription).
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
    /// Set for the Claude Code and Codex presets, whose arguments, output, and tools Arch decides.
    var agent: AIAgentKind?
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
        agent = tool.agent
        models = provider.models
        limits = provider.limits
    }

    /// A Claude Code or Codex preset with the tool found in the login shell's PATH, or in `searchPath` when given, its default model, and two concurrent requests. Without a match, the executable holds the tool's name for Find.
    static func preset(_ kind: AIAgentKind, searchPath: String? = nil) async -> AICommandLineDraft {
        var draft = AICommandLineDraft()
        draft.name = kind.title
        draft.agent = kind
        draft.executable = await kind.locateExecutable(searchPath: searchPath)?.path ?? kind.executableName
        draft.limits = .agentPreset
        return draft
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
        if let agent {
            let tool = AICommandLineConfiguration(executable: executableURL, environment: AINameValue.dictionary(environment), agent: agent)
            return AIProviderConfiguration(id: id, name: name.trimmingCharacters(in: .whitespaces), kind: .commandLine(tool), models: models, limits: limits)
        }
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
    /// Why the last Find did not find the tool, under the executable field until the field changes.
    @State private var locateFailure: String?
    /// Why the last removal failed, over the buttons.
    @State private var message: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkResult: String?
    @State private var checkFailed = false
    @State private var status: AIAgentToolStatus?
    @State private var statusError: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.isNew ? "Add Command-Line Tool" : "Edit Command-Line Tool")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                toolSection
                if let agent = draft.agent {
                    statusSection(agent)
                } else {
                    argumentsSection
                }
                Section {
                    AINameValueRows(rows: $draft.environment, addTitle: "Add Variable", removeTitle: "Remove Variable")
                } header: {
                    Text("Environment")
                } footer: {
                    formFootnote(draft.agent == nil
                               ? "The tool runs with only HOME, USER, LOGNAME, SHELL, PATH from your login shell, LANG, TMPDIR, and TERM, plus these variables. They are saved in ai.json, so they must not hold secrets."
                               : "The tool runs with only HOME, USER, LOGNAME, SHELL, and PATH, with CLAUDE_CONFIG_DIR or CODEX_HOME from your login shell, LANG, TMPDIR, and TERM, Arch's settings, and these variables, which take precedence. They are saved in ai.json, so they must not hold secrets. ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, OPENAI_API_KEY, and CODEX_API_KEY are never passed, so the tool uses its own sign-in.")
                }
                if draft.agent == nil {
                    outputSection
                    Section {
                        Toggle("Runs without its own tools", isOn: $draft.runsWithoutTools)
                    } footer: {
                        formFootnote("Turn this on only if the arguments stop the tool from running commands, editing files, or using other tools of its own. Text in a page could otherwise steer the tool, so until then it gets no page, selection, file, or download data. Arch cannot check this; it only runs the tool in an empty folder with a small environment.")
                    }
                }
                Section {
                    AIModelList(models: $draft.models, defaultCapabilities: AICommandLineConfiguration.capabilities) {
                        if !draft.models.contains(where: { $0.name.isEmpty }) {
                            Button("Add Default") { draft.models.insert(AIModelConfiguration(name: ""), at: 0) }
                                .help("Add the tool\u{2019}s own default model")
                        }
                    }
                } header: {
                    Text("Models")
                } footer: {
                    formFootnote(modelsNote)
                }
                AIProviderLimitsSection(limits: $draft.limits)
                checkSection
            }
            .formStyle(.grouped)
            Divider()
            AIProviderEditorButtons(name: draft.name, isNew: draft.isNew, canSave: draft.configuration != nil, failure: message,
                                    removalNote: "Features that used its models fall back to their other models. The tool and its sign-in stay on this Mac.",
                                    remove: remove, save: save)
        }
        .frame(width: 480, height: 500)
        .onDisappear { checkTask?.cancel() }
    }

    // MARK: Tool

    @ViewBuilder private var toolSection: some View {
        Section {
            TextField("Name", text: $draft.name)
            HStack {
                TextField("Executable", text: $draft.executable, prompt: Text("Name or path"))
                    .onSubmit { Task { await locate() } }
                    .onChange(of: draft.executable) { locateFailure = nil }
                Button("Find") { Task { await locate() } }
                    .disabled(isLocating || draft.executable.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Look the name up in your login shell\u{2019}s PATH")
                Button("Choose\u{2026}", action: chooseExecutable)
            }
            // The button keeps its width while it runs, so the field beside it stays still. Until Find fails, the line under the field is guidance, not an error.
            if isLocating {
                AIProgressRow(text: "Looking in your login shell\u{2019}s PATH\u{2026}")
            } else if let locateFailure {
                Text(locateFailure).font(.callout).foregroundStyle(.red)
            } else if !draft.executable.isEmpty, draft.executableURL == nil {
                Text("Enter the tool\u{2019}s full path, or its name and click Find.").font(.callout).foregroundStyle(.secondary)
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
            formFootnote("Install the tool and sign in to it in the terminal. The tool keeps its own sign-in; Arch never reads it.")
        }
    }

    /// Return in the field runs this too, so a lookup under way makes it do nothing. A result for a name the user has since changed is dropped.
    private func locate() async {
        let name = draft.executable
        guard !isLocating, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLocating = true
        locateFailure = nil
        defer { isLocating = false }
        let url = await AICommandLineConfiguration.locateExecutable(named: name)
        guard draft.executable == name else { return }
        if let url {
            draft.executable = url.path
        } else {
            locateFailure = "\(name) is not in your login shell\u{2019}s PATH. Install it in the terminal, or choose the file with Choose\u{2026}."
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

    // MARK: Status

    /// The version and sign-in from the tool's own status commands, read again when the executable changes.
    @ViewBuilder private func statusSection(_ agent: AIAgentKind) -> some View {
        Section {
            LabeledContent("Version", value: status?.version ?? (statusError == nil && draft.executableURL != nil ? "Checking\u{2026}" : "\u{2014}"))
            LabeledContent("Sign-in", value: signInText)
            if let statusError {
                Text(statusError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Refresh") { Task { await loadStatus() } }
                    .disabled(draft.executableURL == nil)
                if status?.isSignedIn == false, PreferencesWindowController.openTerminalTyping != nil {
                    Button("Sign In\u{2026}") { Task { await signIn(agent) } }
                }
            }
        } header: {
            Text("Status")
        } footer: {
            formFootnote("Arch reads the version and the sign-in from \(agent.title)'s own status commands and never reads its credentials. Arch builds every argument: the tool's own tools, settings, hooks, plugins, and other servers stay off, so its ordinary requests may get page data, and agent sessions get only Arch's tools. Sign In types the tool's sign-in command in the terminal; press Return there to run it.")
        }
        .task(id: draft.executableURL) { await loadStatus() }
    }

    private var signInText: String {
        switch status?.isSignedIn {
        case true?: return "Signed In"
        case false?: return "Not Signed In"
        case nil: return status == nil ? "\u{2014}" : "Unknown"
        }
    }

    private var modelsNote: String {
        switch draft.agent {
        case .claudeCode?: return "Name models as Claude Code accepts them, such as sonnet or opus, or keep the default model, the tool's own choice."
        case .codex?: return "Name models by their Codex names, or keep the default model, the tool's own choice."
        case nil: return "The default model leaves out the arguments that name a model, so the tool uses its own choice."
        }
    }

    private func loadStatus() async {
        guard let agent = draft.agent, let executable = draft.executableURL else {
            status = nil
            statusError = nil
            return
        }
        do {
            status = try await AIAgentToolStatus.read(kind: agent, executable: executable, environment: AINameValue.dictionary(draft.environment))
            statusError = nil
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
    }

    /// The tool's name when the login shell finds this executable by it, or else its quoted path, then its sign-in arguments, after the preset's variables, so the tool signs in where its status is read, as with `CODEX_HOME` or `CLAUDE_CONFIG_DIR`.
    private func signIn(_ agent: AIAgentKind) async {
        guard let executable = draft.executableURL, let type = PreferencesWindowController.openTerminalTyping else { return }
        let found = await AICommandLineConfiguration.locateExecutable(named: agent.executableName)
        let program = found?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() ? agent.executableName : Self.shellQuoted(executable.path)
        type(Self.signInCommand(program: program, arguments: agent.signInArguments, environment: AINameValue.dictionary(draft.environment)))
    }

    /// `NAME='value' … <program> <arguments>`, with each variable whose name the shell accepts, in name order. The variables are not secret (Environment's footnote).
    nonisolated static func signInCommand(program: String, arguments: [String], environment: [String: String]) -> String {
        let assignments = environment.keys.sorted()
            .filter { name in
                name.first.map { $0 == "_" || $0.isASCII && $0.isLetter } == true && name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
            }
            .map { "\($0)=\(shellQuoted(environment[$0] ?? ""))" }
        return (assignments + [program] + arguments).joined(separator: " ")
    }

    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
                    .help("Remove Argument")
                    .accessibilityLabel("Remove Argument")
                }
            }
            HStack {
                Spacer()
                Button("Add Argument") { draft.arguments.append(AICommandLineDraft.Argument(value: "")) }
            }
        } header: {
            Text("Arguments")
        } footer: {
            formFootnote("Each row is one argument. \(AICommandLineConfiguration.modelPlaceholder) becomes the model\u{2019}s name, and an argument that contains it is left out for the default model, so write an option and its model as one argument, such as --model=\(AICommandLineConfiguration.modelPlaceholder). The prompt goes to the tool\u{2019}s standard input, never into its arguments.")
        }
    }

    @ViewBuilder private var outputSection: some View {
        Section {
            Picker("Output", selection: $draft.outputFormat) {
                Text("Plain Text").tag(AICommandLineDraft.OutputFormat.text)
                Text("JSON Lines").tag(AICommandLineDraft.OutputFormat.jsonLines)
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
            formFootnote(draft.outputFormat == .text
                         ? "The tool\u{2019}s standard output is the reply."
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
            formFootnote(draft.agent == nil
                       ? "Check sends a short request to the first model and shows the reply or the error."
                       : "Check runs the tool's status command and Arch's checks of the flags, features, and settings it passes, never a model, so it uses none of your subscription.")
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
                checkResult = settings.message(for: error)
                checkFailed = true
            }
            checkTask = nil
            if draft.agent != nil { await loadStatus() }
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
            message = settings.message(for: error)
        }
    }
}
