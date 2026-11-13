// Settings ▸ AI ▸ Agents ▸ Skills without its view: each tool's folder from the login shell's environment, the buttons each state offers, the confirmation's text before Install and Update write, Install, Update, and Remove for both tools, copies that Arch leaves alone, and the sentences the section shows, in a temporary home folder with a scratch bundle path.
import AgentControl
import Foundation
import Testing
@testable import Preferences

/// A home folder and the folders that `CLAUDE_CONFIG_DIR` and `CODEX_HOME` name, in the temporary folder, removed afterward.
private final class ScratchSkillFolders {
    let root: URL
    let home: URL
    let claudeConfig: URL
    let codexHome: URL
    let bundle: AgentBundleLayout

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pref-skills-\(UUID().uuidString.prefix(8))")
        home = root.appendingPathComponent("home")
        claudeConfig = root.appendingPathComponent("claude config")
        codexHome = root.appendingPathComponent("codex")
        bundle = AgentBundleLayout(bundleURL: home.appendingPathComponent("Applications/Arch.app"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var environment: [String: String] {
        ["HOME": home.path, "CLAUDE_CONFIG_DIR": claudeConfig.path, "CODEX_HOME": codexHome.path]
    }

    func places(environment: [String: String]? = nil, bundle: AgentBundleLayout? = nil) -> AgentSkillPlaces {
        AgentSkillPlaces(bundle: bundle ?? self.bundle, accountHomeFolder: root.appendingPathComponent("account"), environment: environment ?? self.environment)
    }

    /// The skill's folder for a target, as the tool reads it.
    func folder(for target: AgentSkillInstaller.Target) -> URL {
        switch target {
        case .claude: return claudeConfig.appendingPathComponent("skills/arch-browser")
        case .codex: return home.appendingPathComponent(".agents/skills/arch-browser")
        case .codexHome: return codexHome.appendingPathComponent("skills/arch-browser")
        }
    }
}

@Suite struct AgentSkillPlacesTests {
    private func found(_ place: AgentSkillPlaces.Place) -> (AgentSkillInstaller.Destination, AgentSkillInstaller.State)? {
        guard case .found(let destination, let state) = place else { return nil }
        return (destination, state)
    }

    @Test func claudeCodesRowFollowsCLAUDE_CONFIG_DIRAndCodexsRowUsesOnlyTheAgentsFolder() throws {
        let scratch = ScratchSkillFolders()
        let places = scratch.places()
        #expect(AgentSkillPlaces.targets == [.claude, .codex])
        for target in AgentSkillPlaces.targets {
            let (destination, state) = try #require(found(places.place(for: target)))
            #expect(destination.folder.path == scratch.folder(for: target).path, "\(target)")
            #expect(state == .absent)
            #expect(AgentSkillPlaces.actions(for: state) == [.install])
        }
        // Without HOME, the account's home folder holds Codex's folder and Claude Code's default one.
        let account = scratch.places(environment: [:])
        #expect(try #require(found(account.place(for: .claude))).0.folder.path == scratch.root.appendingPathComponent("account/.claude/skills/arch-browser").path)
        #expect(try #require(found(account.place(for: .codex))).0.folder.path == scratch.root.appendingPathComponent("account/.agents/skills/arch-browser").path)
    }

    @Test func installUpdatesAndRemovesBothSkillsAfterShowingTheFile() throws {
        let scratch = ScratchSkillFolders()
        let places = scratch.places()
        for target in AgentSkillPlaces.targets {
            let (destination, _) = try #require(found(places.place(for: target)))
            #expect(places.confirmation(for: .install, at: destination) == "Arch writes its skill to \(destination.file.path), a copy that names \(scratch.bundle.cliExecutableURL.path).")
            // Confirming is the view's; the text alone writes nothing.
            #expect(!FileManager.default.fileExists(atPath: destination.folder.path))

            try places.install(at: destination)
            #expect(AgentSkillPlaces.installedSentence(at: destination, for: target) == "Wrote \(destination.file.path). New \(target.title) sessions read it.")
            #expect(found(places.place(for: target))?.1 == .current)
            #expect(AgentSkillPlaces.actions(for: .current) == [.remove])
            #expect(try String(contentsOf: destination.file, encoding: .utf8) == places.skill.markdown)

            // A copy written by an Arch at another path is outdated, and Update replaces it.
            let other = scratch.places(bundle: AgentBundleLayout(bundleURL: scratch.root.appendingPathComponent("Old/Arch.app")))
            try other.install(at: destination)
            #expect(found(places.place(for: target))?.1 == .outdated)
            #expect(AgentSkillPlaces.actions(for: .outdated) == [.remove, .update])
            #expect(places.confirmation(for: .update, at: destination) == "Arch replaces its copy at \(destination.file.path) with this Arch's skill, which names \(scratch.bundle.cliExecutableURL.path).")
            try places.install(at: destination)
            #expect(found(places.place(for: target))?.1 == .current)

            #expect(try places.remove(at: destination))
            #expect(AgentSkillPlaces.removedSentence(at: destination, removed: true) == "Removed \(destination.folder.path).")
            #expect(found(places.place(for: target))?.1 == .absent)
            #expect(try !places.remove(at: destination))
            #expect(AgentSkillPlaces.removedSentence(at: destination, removed: false) == "No skill of Arch's is at \(destination.folder.path).")
        }
        // Codex's row never writes under CODEX_HOME, where a second copy would be listed twice.
        try places.install(at: try #require(found(places.place(for: .codex))).0)
        #expect(!FileManager.default.fileExists(atPath: scratch.folder(for: .codexHome).path))
    }

    @Test func aChangedCopyAndAFolderArchDidNotWriteAreLeftAloneWithoutButtons() throws {
        let scratch = ScratchSkillFolders()
        let places = scratch.places()
        let (claude, _) = try #require(found(places.place(for: .claude)))
        try places.install(at: claude)
        let edited = try String(contentsOf: claude.file, encoding: .utf8) + "\nAlso use this.\n"
        try Data(edited.utf8).write(to: claude.file)
        #expect(found(places.place(for: .claude))?.1 == .modified)
        #expect(AgentSkillPlaces.actions(for: .modified).isEmpty)
        #expect(AgentSkillPlaces.sentence(for: .modified) == "Arch's copy with changes made after Arch wrote it, which Arch leaves alone.")
        // A write or removal that reaches it anyway, as after a change outside Arch while the row showed, leaves it unchanged with Settings' sentence.
        #expect(throws: AgentSkillInstaller.Failure.modifiedSkill(claude.folder.path)) { try places.install(at: claude) }
        #expect(throws: AgentSkillInstaller.Failure.modifiedSkill(claude.folder.path)) { try places.remove(at: claude) }
        #expect(AgentSkillPlaces.sentence(for: AgentSkillInstaller.Failure.modifiedSkill(claude.folder.path)) == "\(claude.folder.path) holds Arch's skill with changes made after Arch wrote it, so Arch leaves it alone.")
        #expect(try String(contentsOf: claude.file, encoding: .utf8) == edited)

        let (codex, _) = try #require(found(places.place(for: .codex)))
        try FileManager.default.createDirectory(at: codex.folder, withIntermediateDirectories: true)
        try Data("Notes".utf8).write(to: codex.folder.appendingPathComponent("NOTES.md"))
        #expect(found(places.place(for: .codex))?.1 == .foreign)
        #expect(AgentSkillPlaces.actions(for: .foreign).isEmpty)
        #expect(AgentSkillPlaces.sentence(for: .foreign) == "A folder that Arch did not write, which Arch leaves alone.")
        #expect(throws: AgentSkillInstaller.Failure.foreignFolder(codex.folder.path)) { try places.install(at: codex) }
        #expect(AgentSkillPlaces.sentence(for: AgentSkillInstaller.Failure.foreignFolder(codex.folder.path)) == "\(codex.folder.path) holds files that Arch did not write, so Arch leaves it alone.")
        #expect(FileManager.default.fileExists(atPath: codex.folder.appendingPathComponent("NOTES.md").path))
    }

    @Test func aVariableThatIsNotAnAbsolutePathLeavesOnlyItsRowWithoutAFolder() throws {
        let scratch = ScratchSkillFolders()
        let places = scratch.places(environment: ["HOME": scratch.home.path, "CLAUDE_CONFIG_DIR": "~/claude"])
        #expect(places.place(for: .claude) == .unresolved("CLAUDE_CONFIG_DIR is set to ~/claude, which is not an absolute path, so the folder the tool reads is unclear."))
        #expect(try #require(found(places.place(for: .codex))).0.folder.path == scratch.folder(for: .codex).path)
        // A folder inside an app bundle is named with Settings' sentence.
        let bundled = scratch.places(environment: ["HOME": scratch.home.path, "CLAUDE_CONFIG_DIR": scratch.root.appendingPathComponent("Tools.app/Contents").path])
        guard case .unresolved(let sentence) = bundled.place(for: .claude) else {
            Issue.record("A folder inside an app bundle was named.")
            return
        }
        #expect(sentence.hasSuffix("is inside an app bundle, whose signature covers its files, so Arch leaves it alone."))
    }

    @Test func aSkillUnderCODEX_HOMEGetsARowWithRemoveAndCodexsRowNoInstall() throws {
        let scratch = ScratchSkillFolders()
        let places = scratch.places()
        #expect(places.rows().map(\.target) == [.claude, .codex])
        #expect(places.rows().map(\.actions) == [[.install], [.install]])

        // A copy that `arch-cli skills install --target codex-home` wrote.
        let codexHome = try places.installer.destination(for: .target(.codexHome), skillName: places.skill.name)
        try places.installer.install(places.skill, at: [codexHome])
        var rows = places.rows()
        #expect(rows.map(\.target) == [.claude, .codex, .codexHome])
        #expect(rows[1] == AgentSkillPlaces.Row(target: .codex, place: places.place(for: .codex), actions: [], sentence: "Not installed here. Codex reads the skill under CODEX_HOME, and would list a second copy here twice."))
        #expect(rows[2] == AgentSkillPlaces.Row(target: .codexHome, place: .found(codexHome, .current), actions: [.remove], sentence: "Installed, with this Arch's text."))
        // An outdated copy there still offers only Remove, since Settings writes nothing under CODEX_HOME.
        let other = scratch.places(bundle: AgentBundleLayout(bundleURL: scratch.root.appendingPathComponent("Old/Arch.app")))
        try other.install(at: codexHome)
        #expect(places.rows()[2].actions == [.remove])
        // A copy in both folders, as from an earlier install, leaves Codex's row its own buttons.
        let codex = try #require(found(places.place(for: .codex))).0
        try places.install(at: codex)
        #expect(places.rows()[1].actions == [.remove])
        #expect(places.rows()[1].sentence == "Installed, with this Arch's text.")
        _ = try places.remove(at: codex)

        // A folder of that name that Arch did not write is shown without buttons, and still withholds Install.
        _ = try places.remove(at: codexHome)
        try FileManager.default.createDirectory(at: codexHome.folder, withIntermediateDirectories: true)
        try Data("Notes".utf8).write(to: codexHome.folder.appendingPathComponent("NOTES.md"))
        rows = places.rows()
        #expect(rows.map(\.target) == [.claude, .codex, .codexHome])
        #expect(rows[1].actions.isEmpty)
        #expect(rows[2].actions.isEmpty)
        try FileManager.default.removeItem(at: codexHome.folder)
        #expect(places.rows().map(\.actions) == [[.install], [.install]])

        // With CODEX_HOME at `~/.agents`, its skills folder is Codex's row's own, which shows once.
        let shared = scratch.places(environment: ["HOME": scratch.home.path, "CODEX_HOME": scratch.home.appendingPathComponent(".agents").path])
        try shared.install(at: try #require(shared.rows()[1].destination))
        #expect(shared.rows().map(\.target) == [.claude, .codex])
        #expect(shared.rows()[1].actions == [.remove])
    }

    @Test func aTranslocatedBundleOffersOnlyRemove() throws {
        let scratch = ScratchSkillFolders()
        let translocated = AgentBundleLayout(bundleURL: scratch.root.appendingPathComponent("var/folders/xy/T/AppTranslocation/0F2C/d/Arch.app"))
        let places = scratch.places(bundle: translocated)
        #expect(places.isTranslocated)
        #expect(places.rows().map(\.actions) == [[], []])
        // A copy from the same Arch at its usual place is outdated here, and offers Remove without Update.
        try scratch.places().install(at: try #require(found(places.place(for: .claude))).0)
        #expect(found(places.place(for: .claude))?.1 == .outdated)
        #expect(places.rows()[0].actions == [.remove])
        #expect(!scratch.places().isTranslocated)
    }

    @Test func withoutTheLoginShellsEnvironmentTheSentenceNamesTheBundlesCommands() {
        let scratch = ScratchSkillFolders()
        let sentence = AgentSkillPlaces.unreadEnvironmentSentence(bundle: scratch.bundle)
        #expect(sentence.hasPrefix("Arch could not read your login shell's environment"))
        #expect(sentence.contains("\(scratch.bundle.cliExecutableURL.path) skills install --target claude --target codex writes the skill"))
        #expect(sentence.contains("\(scratch.bundle.cliExecutableURL.path) skills remove --target claude --target codex removes Arch's copies."))
    }
}
