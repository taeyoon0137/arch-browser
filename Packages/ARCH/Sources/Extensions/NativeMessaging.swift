// Native messaging: what web extensions send to apps on the Mac. Arch finds an app through its host manifest in `NativeMessagingHosts/` in the app's Application Support folder, in the format Chromium reads, starts the executable that the manifest names for each message or connection with the calling extension's origin as its argument, and exchanges JSON with it over its standard input and output: each message is a 32-bit length in the Mac's byte order followed by that many bytes of UTF-8 JSON. Under one of Arch's links to another browser's host manifest, only a version whose identifier Arch can prove reaches the app (`NativeMessagingHostLinks`). What each plugin's calls last met is kept for the run, which Settings ▸ Plugins shows (`NativeAppOutcomes`).
import ARCHEngine
import Foundation
import Plugins

/// The native apps that the extensions of one Persona reach on WebKit, which leaves native messaging to the app; Chromium reads the same folder itself.
@MainActor
final class NativeMessaging {
    /// Arch's links in its folder, which the gate reads.
    private let links: NativeMessagingHostLinks
    /// `NativeMessagingHosts/` in the app's Application Support folder.
    private var directory: URL { links.directory }
    /// What each plugin's last message or port met in this run.
    let outcomes = NativeAppOutcomes()

    init(links: NativeMessagingHostLinks) {
        self.links = links
    }

    /// Native messaging through the host manifests in `directory`, with no listed folders, so that nothing there is one of Arch's links.
    convenience init(directory: URL) {
        self.init(links: NativeMessagingHostLinks(directory: directory, folders: []))
    }

    /// Sends one message to the app that `application` names and answers with the app's first message, then ends the app.
    func send(_ message: Data, to application: String?, from caller: NativeMessagingCaller, reply: @escaping (Result<Data, any Error>) -> Void) {
        do {
            let (connection, app) = try open(application, from: caller)
            connection.onMessage = { [weak connection, outcomes] message in
                connection?.close()
                outcomes.record(.answered(app), for: caller)
                reply(.success(message))
            }
            connection.onEnd = { [outcomes] error in
                outcomes.record(error.map { .failed($0.localizedDescription) } ?? .endedWithoutAnswer(app), for: caller)
                reply(.failure(error ?? NativeMessagingError.noReply))
            }
            connection.send(message)
        } catch {
            outcomes.record(NativeAppOutcome(error), for: caller)
            reply(.failure(error))
        }
    }

    /// Connects the extension's port to the app it names, until either side ends the connection. Throws when the app cannot be reached. The app's first message counts as its answer; an end that the extension causes records nothing.
    func connect(_ port: any EngineNativeMessagingPort, from caller: NativeMessagingCaller) throws {
        let connection: NativeMessagingConnection
        let app: String
        do {
            (connection, app) = try open(port.application, from: caller)
        } catch {
            outcomes.record(NativeAppOutcome(error), for: caller)
            throw error
        }
        var hasAnswered = false
        connection.onMessage = { [outcomes] message in
            if !hasAnswered {
                hasAnswered = true
                outcomes.record(.answered(app), for: caller)
            }
            port.send(message)
        }
        connection.onEnd = { [outcomes] error in
            if let error {
                outcomes.record(.failed(error.localizedDescription), for: caller)
            } else if !hasAnswered {
                outcomes.record(.endedWithoutAnswer(app), for: caller)
            }
            port.disconnect(error)
        }
        port.onMessage = { [weak connection] in connection?.send($0) }
        port.onDisconnect = { [weak connection] in connection?.close() }
    }

    /// Starts the app that `application` names for the extension, and gives the connection with the app's `description`, or its name without one.
    private func open(_ application: String?, from caller: NativeMessagingCaller) throws -> (NativeMessagingConnection, String) {
        let manifest = try hostManifest(of: application, for: caller)
        let connection = NativeMessagingConnection(executable: URL(fileURLWithPath: manifest.path), origin: Self.origin(of: caller.extensionID))
        try connection.start()
        return (connection, manifest.description ?? manifest.name)
    }

    /// The origin that Chromium gives the extension and that host manifests list, which the app receives as its argument.
    nonisolated static func origin(of extensionID: String) -> String {
        "chrome-extension://\(extensionID)/"
    }

    /// Whether `name` can name a native app: dot-separated runs of lowercase letters, digits, and `_`, as Chromium requires, so that a name cannot lead out of the folder.
    nonisolated static func isValidName(_ name: String) -> Bool {
        name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
        }
    }

    /// The executable of the app that `application` names, whose host manifest lets the extension reach it (`hostManifest(of:for:)`).
    func executable(of application: String?, for caller: NativeMessagingCaller) throws -> URL {
        URL(fileURLWithPath: try hostManifest(of: application, for: caller).path)
    }

    /// The host manifest of the app that `application` names, which lets the extension reach it. Under one of Arch's links, the caller needs proof of its identifier, which the gate asks of it by the manifest read here, so that a vendor's change to that manifest during the run counts at once (`NativeMessagingHostLinks`, the gate). A held host, which has no manifest in Arch's folder, fails with why Arch does not start its app.
    private func hostManifest(of application: String?, for caller: NativeMessagingCaller) throws -> NativeMessagingHostManifest {
        guard let application, Self.isValidName(application) else { throw NativeMessagingError.invalidName(application ?? "") }
        // Asked before the read, so that a link that a pass makes meanwhile counts.
        let isGated = !caller.isProven && links.coversLink(named: application)
        let file = directory.appendingPathComponent(application + ".json")
        guard let data = try? Data(contentsOf: file) else {
            if let host = links.hosts[application], host.held != nil { throw NativeMessagingError.held(host.description) }
            throw NativeMessagingError.notFound(application)
        }
        guard let manifest = try? JSONDecoder().decode(NativeMessagingHostManifest.self, from: data), manifest.name == application, manifest.type == "stdio",
              manifest.path.hasPrefix("/") else { throw NativeMessagingError.invalidManifest(application) }
        guard manifest.allowedOrigins.contains(Self.origin(of: caller.extensionID)) else { throw NativeMessagingError.notAllowed(application) }
        if isGated {
            throw NativeMessagingError.unproven(NativeMessagingHostLinks.gateSentence(naming: manifest.description ?? application, predatesProof: caller.predatesProof))
        }
        return manifest
    }
}

/// What a plugin's last native message or port met on WebKit tabs, as Settings ▸ Plugins says it. Arch does not see Chromium's native messages.
public enum NativeAppOutcome: Hashable, Sendable {
    /// The native app with the description sent a message.
    case answered(String)
    /// The native app with the description ended without sending one, as a native app does when it does not accept the browser.
    case endedWithoutAnswer(String)
    /// Arch did not start the native app with the description, since macOS does not start it for Arch (`NativeMessagingHost.HeldReason`).
    case held(String)
    /// The call failed for another reason, with the failure's message.
    case failed(String)

    init(_ error: any Error) {
        if case let .held(app)? = error as? NativeMessagingError {
            self = .held(app)
        } else {
            self = .failed(error.localizedDescription)
        }
    }

    /// "On WebKit tabs, 1Password BrowserSupport answered.", and the like.
    public var sentence: String {
        switch self {
        case let .answered(app): return "On WebKit tabs, \(app) answered."
        case let .endedWithoutAnswer(app): return "On WebKit tabs, \(app) ended without answering, as a native app does when it does not accept the browser."
        case let .held(app): return "On WebKit tabs, Arch did not start \(app), which macOS does not start for Arch."
        case let .failed(message): return message
        }
    }
}

/// What the native messages and ports of a Persona's plugins last met on WebKit tabs in this run, by plugin, each with the install it came from, so that an update or a reinstall, as one that brings a proof, starts without one.
@MainActor
public final class NativeAppOutcomes: ObservableObject {
    private struct Entry: Equatable {
        let installedAt: Date?
        let outcome: NativeAppOutcome
    }

    @Published private var entries: [PluginID: Entry] = [:]

    /// The plugin's last outcome in this run, while it has the install that met it.
    public func outcome(of plugin: InstalledPlugin) -> NativeAppOutcome? {
        guard let entry = entries[plugin.id], entry.installedAt == plugin.installedAt else { return nil }
        return entry.outcome
    }

    /// Keeps the outcome for the caller's plugin, if it names one.
    func record(_ outcome: NativeAppOutcome, for caller: NativeMessagingCaller) {
        guard let plugin = caller.plugin else { return }
        entries[plugin] = Entry(installedAt: caller.installedAt, outcome: outcome)
    }
}

/// A host manifest, as Chromium reads one.
struct NativeMessagingHostManifest: Decodable {
    let name: String
    /// What the native app is, such as "1Password BrowserSupport", which Settings and the gate's sentence show.
    let description: String?
    /// The app's executable, an absolute path.
    let path: String
    /// Always `stdio`.
    let type: String
    /// The extensions that may reach the app, as `chrome-extension://<id>/`.
    let allowedOrigins: [String]

    enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }
}

enum NativeMessagingError: LocalizedError, Equatable {
    case invalidName(String)
    case notFound(String)
    case invalidManifest(String)
    case notAllowed(String)
    /// The gate's sentence for a version without proof under one of Arch's links.
    case unproven(String)
    /// The description of a held host's native app, which Arch does not start.
    case held(String)
    case messageTooLarge
    case noReply

    var errorDescription: String? {
        switch self {
        case let .invalidName(name): return "“\(name)” is not the name of a native app."
        case let .notFound(name): return "No native app named \(name) is set up for Arch."
        case let .invalidManifest(name): return "The host manifest of the native app \(name) could not be read."
        case let .notAllowed(name): return "The native app \(name) does not accept this extension."
        case let .unproven(sentence): return sentence
        case let .held(app): return "Arch did not start \(app), which macOS does not start for Arch."
        case .messageTooLarge: return "The native app sent a message larger than 1 MB."
        case .noReply: return "The native app ended without replying."
        }
    }
}

/// One running native app and the messages to and from it. Messages from the app arrive on the main thread in order; writes go out in order without blocking it. A running connection keeps itself through the handler that reads the app's output, until it ends.
@MainActor
final class NativeMessagingConnection {
    /// The longest message an app may send, as in Chromium.
    nonisolated static let messageLimit = 1024 * 1024

    /// Receives each message the app sends.
    var onMessage: ((Data) -> Void)?
    /// Called once when the app ends the connection: with nil when it closes its output, as it does when it exits, and with the error when it breaks the message format. Not called after `close()`.
    var onEnd: (((any Error)?) -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writes = DispatchQueue(label: "xyz.taeyoon.arch.native-messaging")
    private var hasEnded = false

    init(executable: URL, origin: String) {
        process.executableURL = executable
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A write after the app has ended fails instead of ending Arch with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Starts the app and reads its messages until it closes its output, as it does when it ends. Reading starts once the app runs, since the reading handler keeps the connection: an app that cannot start leaves nothing that keeps it.
    func start() throws {
        try process.run()
        let reader = NativeMessageReader()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // The handler would go on running at the end of the output.
            if data.isEmpty { handle.readabilityHandler = nil }
            let messages = reader.messages(after: data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch messages {
                    case let .success(messages):
                        messages.forEach { self.onMessage?($0) }
                        if data.isEmpty { self.end(nil, byApp: true) }
                    case let .failure(error):
                        self.end(error, byApp: true)
                    }
                }
            }
        }
    }

    /// Writes one message, its length first, to the app's standard input.
    func send(_ message: Data) {
        guard !hasEnded else { return }
        let frame = withUnsafeBytes(of: UInt32(message.count)) { Data($0) } + message
        let handle = input.fileHandleForWriting
        writes.async { try? handle.write(contentsOf: frame) }
    }

    /// Ends the app and the connection.
    func close() {
        end(nil, byApp: false)
    }

    /// Stops reading, which lets the connection go, closes the app's input, and ends the app. Only an end the app caused reaches `onEnd`.
    private func end(_ error: (any Error)?, byApp: Bool) {
        guard !hasEnded else { return }
        hasEnded = true
        output.fileHandleForReading.readabilityHandler = nil
        let handle = input.fileHandleForWriting
        writes.async { try? handle.close() }
        if process.isRunning { process.terminate() }
        let onEnd = byApp ? onEnd : nil
        self.onEnd = nil
        onMessage = nil
        onEnd?(error)
    }
}

/// Cuts the app's output into messages. Only the reading thread uses it.
private final class NativeMessageReader: @unchecked Sendable {
    private var buffer = Data()

    /// The messages that `data` completes, or `messageTooLarge` for a message past the limit.
    func messages(after data: Data) -> Result<[Data], NativeMessagingError> {
        buffer.append(data)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard length <= NativeMessagingConnection.messageLimit else { return .failure(.messageTooLarge) }
            guard buffer.count >= 4 + length else { break }
            messages.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return .success(messages)
    }
}
