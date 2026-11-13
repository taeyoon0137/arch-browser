// Native messaging: what web extensions send to apps on the Mac. Arch finds an app through its host manifest in `NativeMessagingHosts/` in the app's Application Support folder, in the format Chromium reads, starts the executable that the manifest names for each message or connection with the calling extension's origin as its argument, and exchanges JSON with it over its standard input and output: each message is a 32-bit length in the Mac's byte order followed by that many bytes of UTF-8 JSON. Under one of Arch's links to another browser's host manifest, only a version whose identifier Arch can prove reaches the app (`NativeMessagingHostLinks`).
import ARCHEngine
import Foundation

/// The native apps that the extensions of one Persona reach on WebKit, which leaves native messaging to the app; Chromium reads the same folder itself.
@MainActor
final class NativeMessaging {
    /// Arch's links in its folder, which the gate reads.
    private let links: NativeMessagingHostLinks
    /// `NativeMessagingHosts/` in the app's Application Support folder.
    private var directory: URL { links.directory }

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
            let connection = try open(application, from: caller)
            connection.onMessage = { [weak connection] message in
                connection?.close()
                reply(.success(message))
            }
            connection.onEnd = { reply(.failure($0 ?? NativeMessagingError.noReply)) }
            connection.send(message)
        } catch {
            reply(.failure(error))
        }
    }

    /// Connects the extension's port to the app it names, until either side ends the connection. Throws when the app cannot be reached.
    func connect(_ port: any EngineNativeMessagingPort, from caller: NativeMessagingCaller) throws {
        let connection = try open(port.application, from: caller)
        connection.onMessage = { port.send($0) }
        connection.onEnd = { port.disconnect($0) }
        port.onMessage = { [weak connection] in connection?.send($0) }
        port.onDisconnect = { [weak connection] in connection?.close() }
    }

    /// Starts the app that `application` names for the extension.
    private func open(_ application: String?, from caller: NativeMessagingCaller) throws -> NativeMessagingConnection {
        let connection = NativeMessagingConnection(executable: try executable(of: application, for: caller), origin: Self.origin(of: caller.extensionID))
        try connection.start()
        return connection
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

    /// The executable of the app that `application` names, whose host manifest lets the extension reach it. Under one of Arch's links, the caller needs proof of its identifier, which the gate asks of it by the manifest read here, so that a vendor's change to that manifest during the run counts at once (`NativeMessagingHostLinks`, the gate).
    func executable(of application: String?, for caller: NativeMessagingCaller) throws -> URL {
        guard let application, Self.isValidName(application) else { throw NativeMessagingError.invalidName(application ?? "") }
        // Asked before the read, so that a link that a pass makes meanwhile counts.
        let isGated = !caller.isProven && links.coversLink(named: application)
        let file = directory.appendingPathComponent(application + ".json")
        guard let data = try? Data(contentsOf: file) else { throw NativeMessagingError.notFound(application) }
        guard let manifest = try? JSONDecoder().decode(NativeMessagingHostManifest.self, from: data), manifest.name == application, manifest.type == "stdio",
              manifest.path.hasPrefix("/") else { throw NativeMessagingError.invalidManifest(application) }
        guard manifest.allowedOrigins.contains(Self.origin(of: caller.extensionID)) else { throw NativeMessagingError.notAllowed(application) }
        if isGated {
            throw NativeMessagingError.unproven(NativeMessagingHostLinks.gateSentence(naming: manifest.description ?? application, predatesProof: caller.predatesProof))
        }
        return URL(fileURLWithPath: manifest.path)
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
    case messageTooLarge
    case noReply

    var errorDescription: String? {
        switch self {
        case let .invalidName(name): return "“\(name)” is not the name of a native app."
        case let .notFound(name): return "No native app named \(name) is set up for Arch."
        case let .invalidManifest(name): return "The host manifest of the native app \(name) does not read."
        case let .notAllowed(name): return "The native app \(name) does not accept this extension."
        case let .unproven(sentence): return sentence
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
