// Native messaging: finding a native app through its host manifest, the apps and extensions Arch refuses, one message and its reply, a port's messages both ways, and an app that breaks the message format. A shell script stands for the app.
import ARCHEngine
@testable import Extensions
import Foundation
import Testing

@MainActor
@Suite struct NativeMessagingTests {
    private let folder = TemporaryFolder()
    private let extensionID = "jpignaibiiemhngfjkcpokkamffknabf"

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

    private func reply(to message: String, from app: String, through messaging: NativeMessaging) async -> Result<Data, any Error> {
        await withCheckedContinuation { continuation in
            messaging.send(Data(message.utf8), to: app, from: extensionID) { continuation.resume(returning: $0) }
        }
    }

    @Test func sendsOneMessageAndReturnsTheReply() async throws {
        // `cat` writes each message back as it came, its length first.
        let messaging = try installApp("org.example.echo", script: "exec cat")
        let reply = try await reply(to: #"{"text":"hello"}"#, from: "org.example.echo", through: messaging).get()
        #expect(String(decoding: reply, as: UTF8.self) == #"{"text":"hello"}"#)
    }

    @Test func refusesAppsAndExtensionsTheManifestsDoNotAllow() throws {
        let messaging = try installApp("org.example.echo", script: "exec cat", origins: ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
        #expect(throws: NativeMessagingError.notAllowed("org.example.echo")) { try messaging.executable(of: "org.example.echo", for: extensionID) }
        #expect(throws: NativeMessagingError.invalidName("../escape")) { try messaging.executable(of: "../escape", for: extensionID) }
        #expect(throws: NativeMessagingError.invalidName("Org.Example")) { try messaging.executable(of: "Org.Example", for: extensionID) }
        #expect(throws: NativeMessagingError.notFound("org.example.missing")) { try messaging.executable(of: "org.example.missing", for: extensionID) }
    }

    @Test func passesTheOriginAndFailsAnAppThatEndsWithoutReplying() async throws {
        let messaging = try installApp("org.example.quiet", script: #"[ "$1" = "chrome-extension://jpignaibiiemhngfjkcpokkamffknabf/" ] || exit 1; exec cat > /dev/null"#)
        // The app reads until its input closes, which only ending the connection does, so a missing argument shows as an early end.
        let result = await reply(to: "1", from: "org.example.quiet", through: messaging)
        #expect(throws: NativeMessagingError.noReply) { try result.get() }
        let broken = try installApp("org.example.broken", script: #"printf '\377\377\377\177'"#)
        let tooLarge = await reply(to: "1", from: "org.example.broken", through: broken)
        #expect(throws: NativeMessagingError.messageTooLarge) { try tooLarge.get() }
    }

    @Test func connectsAPortBothWays() async throws {
        let messaging = try installApp("org.example.echo", script: "exec cat")
        let port = RecordingPort(application: "org.example.echo")
        try messaging.connect(port, from: extensionID)
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
