// The launch lock belongs to the physical profile directory and releases on process death.
import Darwin
import Foundation
import Testing
@testable import Browsing

@Suite struct ProfileOwnershipTests {
    @Test func competingProcessesRespectThePhysicalProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profile")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: profile)
        do {
            let ownership = try ProfileOwnership(directory: profile)
            let children = try FileManager.default.contentsOfDirectory(atPath: profile.path)
            withExtendedLifetime(ownership) {
                #expect(throws: POSIXError(.EWOULDBLOCK)) { try ProfileOwnership(directory: alias) }
                #expect(children.isEmpty)
            }
        }

        // A separate process takes the same native lock and signals only after it holds it.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-MFcntl=:flock", "-e", """
            open(my $dir, '<', $ARGV[0]) or die $!;
            flock($dir, LOCK_EX | LOCK_NB) or die $!;
            syswrite(STDOUT, '1'); <STDIN>;
            """, alias.path]
        let ready = Pipe(), wait = Pipe()
        child.standardOutput = ready
        child.standardInput = wait
        try child.run()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        try ready.fileHandleForWriting.close()
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("1".utf8))
        #expect(throws: POSIXError(.EWOULDBLOCK)) { try ProfileOwnership(directory: profile) }
        let other = try ProfileOwnership(directory: root.appendingPathComponent("other"))
        try withExtendedLifetime(other) {
            #expect(kill(child.processIdentifier, SIGKILL) == 0)
            child.waitUntilExit()
            let recovered = try ProfileOwnership(directory: alias)
            withExtendedLifetime(recovered) {
                _ = #expect(throws: POSIXError(.EWOULDBLOCK)) { try ProfileOwnership(directory: profile) }
            }
        }
    }
}
