// The skill installer in a temporary home folder, never the user's own skill folders: the targets' folders from `HOME` or the account's home folder, `CLAUDE_CONFIG_DIR`, and `CODEX_HOME`; `--path` folders; refusal of folders inside an app bundle; copies written and recognized as current or outdated; folders, files, and links that are not Arch's, and Arch's copies changed since, left alone, with no destination written when one of them is; removal of Arch's folders only; and an in-app session's skill folder.
import AgentControl
import CryptoKit
import Darwin
import Foundation
import Testing

/// A home folder and a folder outside it in the temporary folder, removed afterward.
private final class TemporarySkills {
    let root: URL
    let home: URL
    let other: URL

    init() throws {
        // The resolved path, as the installer's bundle check reads it, so that paths compare as written.
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = temporary.appendingPathComponent("act-skills-\(UUID().uuidString.prefix(8))", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        other = root.appendingPathComponent("other", isDirectory: true)
        for folder in [home, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func installer(_ environment: [String: String] = [:]) -> AgentSkillInstaller {
        AgentSkillInstaller(accountHomeFolder: home, environment: environment)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }
}

private let skill = AgentHarness.entrySkill(cliPath: "/Applications/Arch.app/Contents/Helpers/arch-cli")

@Suite struct SkillInstallerTests {
    @Test func targetsAreTheToolsFoldersInTheHome() throws {
        let place = try TemporarySkills()
        let installer = place.installer()
        let paths = try AgentSkillInstaller.Target.allCases.map { try installer.destination(for: .target($0), skillName: skill.name).folder.path }
        #expect(paths == [".claude/skills/arch-browser", ".agents/skills/arch-browser", ".codex/skills/arch-browser"].map { place.home.appendingPathComponent($0).path })
        let file = try installer.destination(for: .target(.claude), skillName: skill.name).file
        #expect(file.path == place.home.appendingPathComponent(".claude/skills/arch-browser/SKILL.md").path)
    }

    @Test func homeMovesEveryTargetAsTheToolsReadIt() throws {
        let place = try TemporarySkills()
        // HOME comes before the account's home folder, as Claude Code and Codex take it.
        let installer = place.installer(["HOME": place.other.path + "/"])
        let paths = try AgentSkillInstaller.Target.allCases.map { try installer.destination(for: .target($0), skillName: skill.name).skillsFolder.path }
        #expect(paths == [".claude/skills", ".agents/skills", ".codex/skills"].map { place.other.appendingPathComponent($0).path })
        #expect(try place.installer(["HOME": ""]).destination(for: .target(.codex), skillName: skill.name).skillsFolder.path == place.home.appendingPathComponent(".agents/skills").path)
        #expect(throws: AgentSkillInstaller.Failure.notAbsolute(variable: "HOME", value: "home")) {
            try place.installer(["HOME": "home"]).destination(for: .target(.codex), skillName: skill.name)
        }
        // A target whose variable is set and --path do not use HOME.
        let moved = place.installer(["HOME": "home", "CLAUDE_CONFIG_DIR": place.other.appendingPathComponent("claude").path])
        #expect(try moved.destination(for: .target(.claude), skillName: skill.name).skillsFolder.path == place.other.appendingPathComponent("claude/skills").path)
        #expect(try moved.destination(for: .path(place.other.path), skillName: skill.name).skillsFolder.path == place.other.path)
    }

    @Test func claudeConfigDirAndCodexHomeMoveTheirTargets() throws {
        let place = try TemporarySkills()
        let installer = place.installer(["CLAUDE_CONFIG_DIR": place.other.appendingPathComponent("claude").path, "CODEX_HOME": place.other.appendingPathComponent("codex-home").path])
        #expect(try installer.destination(for: .target(.claude), skillName: skill.name).skillsFolder.path == place.other.appendingPathComponent("claude/skills").path)
        #expect(try installer.destination(for: .target(.codexHome), skillName: skill.name).skillsFolder.path == place.other.appendingPathComponent("codex-home/skills").path)
        // CODEX_HOME moves only Codex's own folder; ~/.agents/skills stays in the home folder.
        #expect(try installer.destination(for: .target(.codex), skillName: skill.name).skillsFolder.path == place.home.appendingPathComponent(".agents/skills").path)
        #expect(try place.installer(["CLAUDE_CONFIG_DIR": ""]).destination(for: .target(.claude), skillName: skill.name).skillsFolder.path == place.home.appendingPathComponent(".claude/skills").path)
        // The tools use the value as it is, so a relative path or a leading ~ leaves the folder they read unclear.
        for value in ["codex", "~", "~/codex-home"] {
            #expect(throws: AgentSkillInstaller.Failure.notAbsolute(variable: "CODEX_HOME", value: value)) {
                try place.installer(["CODEX_HOME": value]).destination(for: .target(.codexHome), skillName: skill.name)
            }
        }
        #expect(throws: AgentSkillInstaller.Failure.notAbsolute(variable: "CLAUDE_CONFIG_DIR", value: "~/.claude-work")) {
            try place.installer(["CLAUDE_CONFIG_DIR": "~/.claude-work"]).destination(for: .target(.claude), skillName: skill.name)
        }
        #expect(AgentSkillInstaller.Failure.notAbsolute(variable: "CODEX_HOME", value: "codex").exitCode == .usage)
    }

    @Test func aPathMustBeAnExistingFolderOutsideAnyAppBundle() throws {
        let place = try TemporarySkills()
        let installer = place.installer()
        #expect(try installer.destination(for: .path(place.other.path), skillName: skill.name).folder.path == place.other.appendingPathComponent("arch-browser").path)
        let missing = place.other.appendingPathComponent("missing")
        #expect(throws: AgentSkillInstaller.Failure.notAFolder(missing.path)) { try installer.destination(for: .path(missing.path), skillName: skill.name) }
        let file = place.other.appendingPathComponent("file")
        try place.write("x", to: file)
        #expect(throws: AgentSkillInstaller.Failure.notAFolder(file.path)) { try installer.destination(for: .path(file.path), skillName: skill.name) }
        // A folder in a bundle, directly, through a link, or as a target's folder, is never written.
        let helpers = place.other.appendingPathComponent("Arch.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let shortcut = place.other.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: shortcut, withDestinationURL: helpers)
        for folder in [helpers, shortcut] {
            #expect(throws: AgentSkillInstaller.Failure.insideAppBundle(folder.path)) { try installer.destination(for: .path(folder.path), skillName: skill.name) }
        }
        let bundled = helpers.appendingPathComponent("claude")
        #expect(throws: AgentSkillInstaller.Failure.insideAppBundle(bundled.appendingPathComponent("skills").path)) {
            try place.installer(["CLAUDE_CONFIG_DIR": bundled.path]).destination(for: .target(.claude), skillName: skill.name)
        }
        #expect(AgentSkillInstaller.Failure.insideAppBundle("x").exitCode == .usage)
        #expect(!FileManager.default.fileExists(atPath: helpers.appendingPathComponent("arch-browser").path))
    }

    @Test func installWritesACopyThatListsAsCurrent() throws {
        let place = try TemporarySkills()
        let installer = place.installer()
        let destinations = try [AgentSkillInstaller.Place.target(.claude), .target(.codex), .target(.codexHome), .path(place.other.path)].map { try installer.destination(for: $0, skillName: skill.name) }
        for destination in destinations { #expect(installer.state(of: destination, skill: skill) == .absent) }
        try installer.install(skill, at: destinations)
        for destination in destinations {
            #expect(installer.state(of: destination, skill: skill) == .current)
            #expect(place.read(destination.file) == skill.markdown)
            // A copy, not a link, in a folder of its own.
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: destination.file.path)) == nil)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: destination.folder.path)) == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.folder.path) == ["SKILL.md"])
            #expect(destination.folder.path.hasPrefix(place.root.path))
        }
        try installer.install(skill, at: destinations)
        #expect(installer.state(of: destinations[0], skill: skill) == .current)
    }

    @Test func anOlderCopyIsOutdatedAndReplaced() throws {
        let place = try TemporarySkills()
        let installer = place.installer()
        let destination = try installer.destination(for: .target(.claude), skillName: skill.name)
        // A copy from an Arch elsewhere, and one in an older format, with its digest, that Finder visited.
        try installer.install(AgentHarness.entrySkill(cliPath: "/Users/someone/Old/Arch.app/Contents/Helpers/arch-cli"), at: [destination])
        #expect(installer.state(of: destination, skill: skill) == .outdated)
        let older = "---\nname: arch-browser\ndescription: Old.\n---\narch-skill-version: 0\n\nOld text.\n"
        let digest = SHA256.hash(data: Data(older.utf8)).map { String(format: "%02x", $0) }.joined()
        try place.write(older.replacingOccurrences(of: "version: 0", with: "version: 0 sha256=\(digest)"), to: destination.file)
        try place.write("", to: destination.folder.appendingPathComponent(".DS_Store"))
        #expect(installer.state(of: destination, skill: skill) == .outdated)
        try installer.install(skill, at: [destination])
        #expect(installer.state(of: destination, skill: skill) == .current)
        #expect(place.read(destination.file) == skill.markdown)
    }

    @Test func foldersThatAreNotArchsStayAndStopEveryWrite() throws {
        let place = try TemporarySkills()
        let installer = place.installer()
        let claude = try installer.destination(for: .target(.claude), skillName: skill.name)
        let other = try installer.destination(for: .path(place.other.path), skillName: skill.name)
        // The user's own skill of that name, without the version line.
        let users = "---\nname: arch-browser\ndescription: Mine.\n---\nMy own notes.\n"
        try place.write(users, to: claude.file)
        #expect(installer.state(of: claude, skill: skill) == .foreign)
        #expect(throws: AgentSkillInstaller.Failure.foreignFolder(claude.folder.path)) { try installer.install(skill, at: [other, claude]) }
        #expect(place.read(claude.file) == users)
        #expect(installer.state(of: other, skill: skill) == .absent)
        #expect(AgentSkillInstaller.Failure.foreignFolder("x").exitCode == .refused)

        // Arch's text beside another file, a link to a folder, a link as SKILL.md, a file where the folder goes, and an oversized file.
        let cases = try TemporarySkills()
        let target = cases.other.appendingPathComponent("target", isDirectory: true)
        try cases.write(skill.markdown, to: target.appendingPathComponent("SKILL.md"))
        var destinations: [AgentSkillInstaller.Destination] = []
        for name in ["extra", "linked", "linked-file", "file", "large"] {
            let folder = cases.home.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destinations.append(try cases.installer().destination(for: .path(folder.path), skillName: skill.name))
        }
        try cases.write(skill.markdown, to: destinations[0].file)
        try cases.write("mine", to: destinations[0].folder.appendingPathComponent("notes.md"))
        try FileManager.default.createSymbolicLink(at: destinations[1].folder, withDestinationURL: target)
        try FileManager.default.createDirectory(at: destinations[2].folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destinations[2].file, withDestinationURL: target.appendingPathComponent("SKILL.md"))
        try cases.write(skill.markdown, to: destinations[3].folder)
        try cases.write(skill.markdown + String(repeating: " ", count: 1024 * 1024), to: destinations[4].file)
        for destination in destinations {
            #expect(cases.installer().state(of: destination, skill: skill) == .foreign, "\(destination.folder.path)")
            #expect(throws: AgentSkillInstaller.Failure.foreignFolder(destination.folder.path)) { try cases.installer().remove(at: destination) }
        }
        #expect(cases.read(destinations[0].folder.appendingPathComponent("notes.md")) == "mine")
        #expect(cases.read(target.appendingPathComponent("SKILL.md")) == skill.markdown)

        // An empty folder of that name, as a failed write would leave, loses nothing when written.
        let empty = try cases.installer().destination(for: .path(cases.other.path), skillName: skill.name)
        try FileManager.default.createDirectory(at: empty.folder, withIntermediateDirectories: true)
        try cases.write("", to: empty.folder.appendingPathComponent(".DS_Store"))
        #expect(cases.installer().state(of: empty, skill: skill) == .absent)
        #expect(try cases.installer().remove(at: empty) == false)
        try cases.installer().install(skill, at: [empty])
        #expect(cases.installer().state(of: empty, skill: skill) == .current)
    }

    @Test func aCopyChangedSinceArchWroteItStays() throws {
        let place = try TemporarySkills()
        let installer = place.installer()
        let claude = try installer.destination(for: .target(.claude), skillName: skill.name)
        let other = try installer.destination(for: .path(place.other.path), skillName: skill.name)
        // The user's note in Arch's copy, which keeps the version line.
        try installer.install(skill, at: [claude])
        let edited = skill.markdown + "My own note.\n"
        try place.write(edited, to: claude.file)
        #expect(installer.state(of: claude, skill: skill) == .modified)
        #expect(throws: AgentSkillInstaller.Failure.modifiedSkill(claude.folder.path)) { try installer.install(skill, at: [other, claude]) }
        #expect(throws: AgentSkillInstaller.Failure.modifiedSkill(claude.folder.path)) { try installer.remove(at: claude) }
        #expect(place.read(claude.file) == edited)
        #expect(installer.state(of: other, skill: skill) == .absent)
        #expect(AgentSkillInstaller.Failure.modifiedSkill("x").exitCode == .refused)
    }

    @Test func removeDeletesOnlyArchsFolders() throws {
        let place = try TemporarySkills()
        let installer = place.installer()
        let destination = try installer.destination(for: .target(.codex), skillName: skill.name)
        #expect(try installer.remove(at: destination) == false)
        try installer.install(skill, at: [destination])
        try place.write("", to: destination.folder.appendingPathComponent(".DS_Store"))
        #expect(try installer.remove(at: destination))
        #expect(!FileManager.default.fileExists(atPath: destination.folder.path))
        // The folder of skill folders and the user's other skills stay.
        #expect(FileManager.default.fileExists(atPath: destination.skillsFolder.path))
        let users = destination.skillsFolder.appendingPathComponent("my-skill/SKILL.md")
        try place.write("---\nname: my-skill\n---\nMine.\n", to: users)
        try installer.install(AgentHarness.entrySkill(cliPath: "/Other/Arch.app/Contents/Helpers/arch-cli"), at: [destination])
        #expect(try installer.remove(at: destination))
        #expect(place.read(users) == "---\nname: my-skill\n---\nMine.\n")
    }

    @Test func aSessionsSkillFolderHoldsEveryTopicSkill() throws {
        let place = try TemporarySkills()
        let folder = place.other.appendingPathComponent("Arch-Agent-session/skills", isDirectory: true)
        try AgentSkillInstaller.write(AgentHarness.sessionSkills, into: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == AgentHarness.sessionSkills.map(\.name).sorted())
        let installer = place.installer()
        for skill in AgentHarness.sessionSkills {
            let destination = try installer.destination(for: .path(folder.path), skillName: skill.name)
            #expect(installer.state(of: destination, skill: skill) == .current, "\(skill.name)")
        }
    }
}
