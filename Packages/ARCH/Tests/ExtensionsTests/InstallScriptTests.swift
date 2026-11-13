// `scripts/install_app.sh` (`docs/password-managers.md`, Installing Arch into /Applications, and Tests): its syntax; with `ARCH_INSTALL_FUNCTIONS_ONLY=1`, `signed_with_team` on fixed `codesign -dv` text, and `may_replace`, `replace_app`, and `undo_replace` on minimal bundles in temporary folders; and whole runs into a temporary destination: a bundle signed ad hoc is refused and the destination stays as it was, and, with a `codesign` on the path that stands for a team's signature, another app at the destination stays, an earlier Arch stays when the copy's signature does not verify, and an earlier Arch is replaced. No run reaches `/Applications`, and the made-up team is not a real one.
import Foundation
import Testing

/// The script, from this file's place in the repository.
private let installScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/install_app.sh")

/// `codesign -dv` output, which it writes to standard error, for a bundle signed by a team, with a made-up team.
private let teamOutput = """
Executable=/Example/Arch.app/Contents/MacOS/Arch
Identifier=xyz.taeyoon.arch
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=1000 flags=0x0(none) hashes=20+7 location=embedded
Signature size=4800
TeamIdentifier=TEAM000001
Sealed Resources version=2 rules=13 files=10
"""

/// `codesign -dv` output for a bundle signed ad hoc.
private let adHocOutput = """
Executable=/Example/Arch.app/Contents/MacOS/Arch
Identifier=xyz.taeyoon.arch
CodeDirectory v=20400 size=265 flags=0x2(adhoc) hashes=2+3 location=embedded
Signature=adhoc
TeamIdentifier=not set
"""

/// What a shell command printed, its errors included, and how it ended.
private struct ShellRun {
    let status: Int32
    let output: String
}

@Suite struct InstallScriptTests {
    private let folder = TemporaryFolder()
    private var destination: URL { folder.url.appendingPathComponent("Destination", isDirectory: true) }
    private var source: URL { folder.url.appendingPathComponent("Source/Arch.app", isDirectory: true) }

    /// Runs `command` with `/bin/sh -c`, with `environment` added, the script's path as `$SCRIPT`, and the test's folder as `$DIR`, and ends it after a minute, which fails the test.
    private func shell(_ command: String, _ environment: [String: String] = [:]) throws -> ShellRun {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let log = folder.url.appendingPathComponent("shell-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(["SCRIPT": installScript.path, "DIR": folder.url.path]) { $1 }.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            Issue.record("The command did not end within a minute: \(command)")
            guard ended.wait(timeout: .now() + 5) == .success else { return ShellRun(status: -1, output: "") }
        }
        return ShellRun(status: process.terminationStatus, output: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    /// Runs `command` after sourcing the script for its functions, with errors that do not end the shell.
    private func functions(_ command: String, _ environment: [String: String] = [:]) throws -> ShellRun {
        try shell(#". "$SCRIPT"; set +e; "# + command, environment.merging(["ARCH_INSTALL_FUNCTIONS_ONLY": "1"]) { $1 })
    }

    /// Writes a minimal bundle at `url` whose `Info.plist` gives `identifier`, or that has none, with a marker file among its resources that tells it apart.
    private func writeBundle(at url: URL, identifier: String?, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        if let identifier {
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Arch"], format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker"))
    }

    private func marker(at url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8)
    }

    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// What the destination holds, hidden names included.
    private var destinationNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).sorted()
    }

    @Test func passesTheShellsSyntaxCheck() throws {
        #expect(try shell(#"sh -n "$SCRIPT""#).status == 0)
    }

    @Test func acceptsOnlyASignatureWithATeamAndPrintsNothing() throws {
        let check = #"printf '%s\n' "$TEXT" | signed_with_team; echo "status $?""#
        #expect(try functions(check, ["TEXT": teamOutput]).output == "status 0\n")
        #expect(try functions(check, ["TEXT": adHocOutput]).output == "status 1\n")
        #expect(try functions(check, ["TEXT": "/Example/Arch.app: code object is not signed at all"]).output == "status 1\n")
    }

    @Test func mayReplaceOnlyNothingALinkOrAnEarlierArch() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try writeBundle(at: folder.url.appendingPathComponent("Elsewhere/Arch.app"), identifier: "xyz.taeyoon.arch", marker: "linked")
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Link.app"), withDestinationURL: folder.url.appendingPathComponent("Elsewhere/Arch.app"))
        try writeBundle(at: destination.appendingPathComponent("Arch.app"), identifier: "xyz.taeyoon.arch", marker: "earlier")
        try writeBundle(at: destination.appendingPathComponent("Other.app"), identifier: "org.example.other", marker: "other")
        try writeBundle(at: destination.appendingPathComponent("Plain.app"), identifier: nil, marker: "plain")
        let run = try functions(#"for name in Missing.app Link.app Arch.app Other.app Plain.app; do may_replace "$DIR/Destination/$name"; echo "$name $?"; done"#)
        let lines = run.output.split(separator: "\n").map(String.init)
        let other = destination.appendingPathComponent("Other.app").path
        let plain = destination.appendingPathComponent("Plain.app").path
        #expect(lines == ["Missing.app 0", "Link.app 0", "Arch.app 0",
                          "\(other) is not Arch (bundle identifier org.example.other). Move it elsewhere, then run the script again.", "Other.app 1",
                          "\(plain) is not Arch. Move it elsewhere, then run the script again.", "Plain.app 1"])
        #expect(destinationNames == ["Arch.app", "Link.app", "Other.app", "Plain.app"] && marker(at: destination.appendingPathComponent("Other.app")) == "other")
    }

    @Test func replacesALinkOrAnEarlierArchAndPutsItBackWhenAMoveFails() throws {
        let app = destination.appendingPathComponent("Arch.app")
        let linked = folder.url.appendingPathComponent("Elsewhere/Arch.app")
        try writeBundle(at: linked, identifier: "xyz.taeyoon.arch", marker: "linked")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: linked)
        try writeBundle(at: source, identifier: "xyz.taeyoon.arch", marker: "new")
        // The minimal bundles carry no signature, so a `codesign` that passes stands in for one.
        let replace = #"codesign() { return 0; }; replace_app "$DIR/Source/Arch.app" "$DIR/Destination/Arch.app"; echo "status $?""#
        // A link goes, and what it leads to stays.
        #expect(try functions(replace).output == "status 0\n")
        #expect(!isLink(app) && marker(at: app) == "new" && marker(at: linked) == "linked" && destinationNames == ["Arch.app"])
        // A move that macOS refuses puts the earlier bundle back and leaves no temporary copy.
        try Data("newer".utf8).write(to: source.appendingPathComponent("Contents/Resources/marker"))
        let refusingMove = #"mv() { case "$1" in *.installing.*) echo "mv: rename: Operation not permitted" >&2; return 1;; esac; command mv "$@"; }; "#
        let refused = try functions(refusingMove + replace)
        #expect(refused.output.hasSuffix("status 1\n") && refused.output.contains("Allow your terminal app in System Settings ▸ Privacy & Security ▸ App Management"))
        #expect(marker(at: app) == "new" && destinationNames == ["Arch.app"])
        // An earlier bundle goes once the copy is in place.
        #expect(try functions(replace).output == "status 0\n")
        #expect(marker(at: app) == "newer" && destinationNames == ["Arch.app"])
    }

    @Test func undoMovesTheEarlierBundleBackOnlyWhileTheCopyHasNotTakenItsPlace() throws {
        let app = destination.appendingPathComponent("Arch.app")
        let previous = destination.appendingPathComponent(".Arch.app.previous.1")
        let undo = #"replace_copy="$DIR/Destination/.Arch.app.installing.1"; replace_previous="$DIR/Destination/.Arch.app.previous.1"; undo_replace "$DIR/Destination/Arch.app"; echo "status $?""#
        // Before the last move, the copy goes and the earlier bundle moves back.
        try writeBundle(at: destination.appendingPathComponent(".Arch.app.installing.1"), identifier: "xyz.taeyoon.arch", marker: "new")
        try writeBundle(at: previous, identifier: "xyz.taeyoon.arch", marker: "earlier")
        #expect(try functions(undo).output == "status 0\n")
        #expect(marker(at: app) == "earlier" && destinationNames == ["Arch.app"])
        // After it, as when a signal arrives before the trap is removed, the earlier bundle stays aside instead of moving into the new one.
        try FileManager.default.moveItem(at: app, to: previous)
        try writeBundle(at: app, identifier: "xyz.taeyoon.arch", marker: "new")
        let late = try functions(undo)
        #expect(late.output == "The new copy is at \(app.path), and the earlier copy stays at \(previous.path); delete it by hand.\nstatus 0\n")
        #expect(marker(at: app) == "new" && marker(at: previous) == "earlier" && destinationNames == [".Arch.app.previous.1", "Arch.app"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []) == ["Contents"])
    }

    @Test func refusesABundleSignedAdHocAndLeavesTheDestinationAsItWas() throws {
        try writeBundle(at: source, identifier: "xyz.taeyoon.arch", marker: "new")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: source.appendingPathComponent("Contents/MacOS/Arch"))
        let signing = try shell(#"codesign --force --sign - "$DIR/Source/Arch.app""#)
        #expect(signing.status == 0, "\(signing.output)")
        let install = ["ARCH_APP_SOURCE": source.path, "ARCH_INSTALL_DIR": destination.path]
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let empty = try shell(#"sh "$SCRIPT""#, install)
        #expect(empty.status != 0 && destinationNames.isEmpty)
        #expect(empty.output == "1Password connects only to signed browsers. Set up an Apple Development identity or set ARCH_SIGN_IDENTITY, then run scripts/bundle_app.sh again.\n")
        try writeBundle(at: destination.appendingPathComponent("Arch.app"), identifier: "org.example.other", marker: "other")
        #expect(try shell(#"sh "$SCRIPT""#, install).status != 0)
        #expect(destinationNames == ["Arch.app"] && marker(at: destination.appendingPathComponent("Arch.app")) == "other")
    }

    @Test func installsOverAnEarlierArchOnlyWithATeamsSignature() throws {
        // A `codesign` that answers for a team's signature, written for the test, and records each verification, which fails with `VERIFY_FAILS` set.
        let bin = folder.url.appendingPathComponent("Bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codesign = bin.appendingPathComponent("codesign")
        try Data("""
        #!/bin/sh
        case "$1" in
          -dv) printf '%s\\n' "$TEAM_OUTPUT" >&2 ;;
          --verify) echo "$*" >> "$DIR/verified"; [ -z "${VERIFY_FAILS:-}" ] || { echo "$4: a sealed resource is missing or invalid" >&2; exit 1; } ;;
          *) exit 1 ;;
        esac

        """.utf8).write(to: codesign)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesign.path)
        let install = ["ARCH_APP_SOURCE": source.path, "ARCH_INSTALL_DIR": destination.path, "TEAM_OUTPUT": teamOutput,
                       "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
        let app = destination.appendingPathComponent("Arch.app")
        try writeBundle(at: source, identifier: "xyz.taeyoon.arch", marker: "new")
        try writeBundle(at: app, identifier: "org.example.other", marker: "other")
        let refused = try shell(#"sh "$SCRIPT""#, install)
        #expect(refused.status != 0 && refused.output == "\(app.path) is not Arch (bundle identifier org.example.other). Move it elsewhere, then run the script again.\n")
        #expect(destinationNames == ["Arch.app"] && marker(at: app) == "other")
        try FileManager.default.removeItem(at: app)
        try writeBundle(at: app, identifier: "xyz.taeyoon.arch", marker: "earlier")
        // A copy whose signature does not verify, such as one of a bundle changed after signing, leaves the earlier Arch in place.
        let broken = try shell(#"sh "$SCRIPT""#, install.merging(["VERIFY_FAILS": "1"]) { $1 })
        #expect(broken.status != 0 && broken.output.hasSuffix("The signature of \(source.path) does not verify, so \(app.path) stays as it was. Run scripts/bundle_app.sh again, then run the script again.\n"))
        #expect(destinationNames == ["Arch.app"] && marker(at: app) == "earlier")
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("verified"))
        let installed = try shell(#"sh "$SCRIPT""#, install)
        #expect(installed.status == 0 && installed.output == "\(app.path)\n")
        #expect(destinationNames == ["Arch.app"] && marker(at: app) == "new" && !isLink(app))
        // The copy is verified under its temporary name, before it replaces anything.
        let verified = try String(contentsOf: folder.url.appendingPathComponent("verified"), encoding: .utf8)
        #expect(verified.hasPrefix("--verify --deep --strict \(destination.path)/.Arch.app.installing.") && verified.filter { $0 == "\n" }.count == 1)
    }
}
