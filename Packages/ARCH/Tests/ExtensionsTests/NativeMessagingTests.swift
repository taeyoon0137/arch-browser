// Native messaging: finding a native app through its host manifest, the apps and extensions Arch refuses, one message and its reply, the extension's origin as the app's argument, an app that ends without replying, an app that does not start, a port's messages both ways, and an app that breaks the message format. A shell script stands for the app.
import ARCHEngine
@testable import Extensions
import Foundation
import Testing

@MainActor
@Suite struct NativeMessagingTests {
    private let folder = TemporaryFolder()
    private let extensionID = "jpignaibiiemhngfjkcpokkamffknabf"
    /// The calling extension, without proof, which no link of Arch's gates in these tests.
    private var caller: NativeMessagingCaller { NativeMessagingCaller(extensionID: extensionID, isProven: false) }

    /// A host manifest for `name` that names a shell script with `body`, which accepts the extensions in `origins`.
    private func installApp(_ name: String, script body: String, origins: [String]? = nil) throws -> NativeMessaging {
        let hosts = folder.url.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        let script = folder.url.appendingPathComponent(name + ".sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manifest: [String: Any] = ["name": name, "description": "Test app", "path": script.path, "type": "stdio",
                                       "allowed_origins": origins ?? ["chrome-extension://\(extensionID)/"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: hosts.appendingPathComponent(name + ".json"))
        return NativeMessaging(directory: hosts)
    }

    /// The app's answer, which arrives on the main thread. It fails the test when none comes within ten seconds, so that an app that never ends fails instead of stopping the run.
    private func reply(to message: String, from app: String, through messaging: NativeMessaging) async throws -> Result<Data, any Error> {
        var result: Result<Data, any Error>?
        messaging.send(Data(message.utf8), to: app, from: caller) { result = $0 }
        _ = await eventually { result != nil }
        return try #require(result)
    }

    @Test func sendsOneMessageAndReturnsTheReply() async throws {
        // `cat` writes each message back as it came, its length first.
        let messaging = try installApp("org.example.echo", script: "exec cat")
        let reply = try await reply(to: #"{"text":"hello"}"#, from: "org.example.echo", through: messaging).get()
        #expect(String(decoding: reply, as: UTF8.self) == #"{"text":"hello"}"#)
    }

    @Test func passesTheExtensionsOriginAsTheArgument() async throws {
        // The app answers only when its argument is the calling extension's origin.
        let messaging = try installApp("org.example.origin", script: #"[ "$1" = "chrome-extension://jpignaibiiemhngfjkcpokkamffknabf/" ] || exit 1; exec cat"#)
        let reply = try await reply(to: "1", from: "org.example.origin", through: messaging).get()
        #expect(String(decoding: reply, as: UTF8.self) == "1")
    }

    @Test func refusesAppsAndExtensionsTheManifestsDoNotAllow() throws {
        let messaging = try installApp("org.example.echo", script: "exec cat", origins: ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
        #expect(throws: NativeMessagingError.notAllowed("org.example.echo")) { try messaging.executable(of: "org.example.echo", for: caller) }
        #expect(throws: NativeMessagingError.invalidName("../escape")) { try messaging.executable(of: "../escape", for: caller) }
        #expect(throws: NativeMessagingError.invalidName("Org.Example")) { try messaging.executable(of: "Org.Example", for: caller) }
        #expect(throws: NativeMessagingError.notFound("org.example.missing")) { try messaging.executable(of: "org.example.missing", for: caller) }
    }

    @Test func failsAnAppThatEndsWithoutReplyingOrBreaksTheFormat() async throws {
        // The app closes its output and reads until its input closes.
        let messaging = try installApp("org.example.quiet", script: "exec cat > /dev/null")
        let result = try await reply(to: "1", from: "org.example.quiet", through: messaging)
        #expect(throws: NativeMessagingError.noReply) { try result.get() }
        let broken = try installApp("org.example.broken", script: #"printf '\377\377\377\177'"#)
        let tooLarge = try await reply(to: "1", from: "org.example.broken", through: broken)
        #expect(throws: NativeMessagingError.messageTooLarge) { try tooLarge.get() }
    }

    @Test func failsAndLetsGoOfAnAppThatDoesNotStart() async throws {
        let messaging = try installApp("org.example.gone", script: "exit 0")
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("org.example.gone.sh"))
        let result = try await reply(to: "1", from: "org.example.gone", through: messaging)
        #expect(throws: (any Error).self) { try result.get() }
        weak var released: NativeMessagingConnection?
        do {
            let connection = NativeMessagingConnection(executable: try messaging.executable(of: "org.example.gone", for: caller), origin: "")
            released = connection
            #expect(throws: (any Error).self) { try connection.start() }
        }
        #expect(released == nil)
    }

    @Test func connectsAPortBothWays() async throws {
        let messaging = try installApp("org.example.echo", script: "exec cat")
        let port = RecordingPort(application: "org.example.echo")
        try messaging.connect(port, from: caller)
        port.onMessage?(Data("1".utf8))
        port.onMessage?(Data(#"["two"]"#.utf8))
        #expect(await eventually { port.received.count == 2 })
        #expect(port.received.map { String(decoding: $0, as: UTF8.self) } == ["1", #"["two"]"#])
        port.onDisconnect?()
        port.onMessage?(Data("3".utf8))
        try await Task.sleep(for: .milliseconds(200))
        #expect(port.received.count == 2 && !port.isDisconnected)
    }
}

/// A port that records what the app sends and whether the app ended the connection.
private final class RecordingPort: EngineNativeMessagingPort {
    let application: String?
    var onMessage: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var received: [Data] = []
    private(set) var isDisconnected = false

    init(application: String) {
        self.application = application
    }

    func send(_ message: Data) {
        received.append(message)
    }

    func disconnect(_ error: (any Error)?) {
        isDisconnected = true
    }
}
