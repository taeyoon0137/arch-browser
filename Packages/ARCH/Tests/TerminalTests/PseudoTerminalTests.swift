// The pseudo-terminal's flow control: output that reaches the main queue in batches and pauses reading at a limit, and Control-C that gets through while pasted input waits for a program that does not read. The terminal tests start shell scripts of their own in place of the login shell.
import Foundation
import Testing
@testable import Terminal

@Suite struct PseudoTerminalTests {
    @Test func pendingOutputBatchesReadsAndPausesReadingAtTheLimit() {
        var events: [String] = []
        let output = PendingOutput(limit: 4, pause: { events.append("pause") }, resume: { events.append("resume") })
        #expect(output.append(Data("ab".utf8)))
        #expect(!output.append(Data("c".utf8)))
        #expect(events.isEmpty)
        #expect(!output.append(Data("de".utf8)))
        #expect(!output.append(Data("f".utf8)))
        #expect(events == ["pause"])
        #expect(output.take() == Data("abcdef".utf8))
        #expect(events == ["pause", "resume"])
        #expect(output.append(Data("g".utf8)))
        #expect(output.take() == Data("g".utf8))
        #expect(events == ["pause", "resume"])
    }

    @MainActor @Test func heavyOutputArrivesWholeInBatchesWhileTheMainQueueIsBusy() async throws {
        let count = 1_000_000
        let folder = try scriptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let terminal = try PseudoTerminal(size: TerminalSize(columns: 80, rows: 24), shell: script("head -c \(count) /dev/zero | tr '\\0' y", in: folder))
        defer { terminal.close() }
        var batches: [Data] = []
        terminal.onOutput = { batches.append($0) }
        // The main queue stays busy while the program writes, as it does while a window draws, until reading pauses, however late the program starts under load.
        let deadline = ContinuousClock.now + .seconds(30)
        while !terminal.isReadingPaused, ContinuousClock.now < deadline {
            usleep(1_000)
        }
        try #require(terminal.isReadingPaused)
        await waitUntil { batches.reduce(0) { $0 + $1.count } >= count }
        #expect(batches.reduce(Data(), +) == Data(repeating: UInt8(ascii: "y"), count: count))
        // The first batch holds what was read until reading paused: the limit, plus at most one read of 64 KB.
        let first = batches.first?.count ?? 0
        #expect(first >= PseudoTerminal.outputLimit)
        #expect(first < PseudoTerminal.outputLimit + 65_536)
    }

    @MainActor @Test func controlCStopsAProgramThatDoesNotReadAPaste() async throws {
        let folder = try scriptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let terminal = try PseudoTerminal(size: TerminalSize(columns: 80, rows: 24), shell: script("exec sleep 60", in: folder))
        defer { terminal.close() }
        var hasExited = false
        terminal.onExit = { hasExited = true }
        // More lines than the terminal holds for a program that does not read them.
        terminal.write(Data(String(repeating: "echo pasted\r", count: 1_000).utf8))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!hasExited)
        terminal.write(Data([3]))
        await waitUntil { hasExited }
        #expect(hasExited)
    }
}

// MARK: - Helpers

private func scriptFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchTerminalTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// An executable shell script that the terminal starts in place of the login shell, which ignores the `-l` it gets.
private func script(_ body: String, in folder: URL) throws -> String {
    let url = folder.appendingPathComponent("shell")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// Waits on the main actor, which lets the terminal's callbacks run, until `condition` holds or 10 seconds pass.
@MainActor private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
