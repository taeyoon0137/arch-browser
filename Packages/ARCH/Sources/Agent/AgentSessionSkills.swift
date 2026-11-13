// An in-app session's skill folder (agent decision 16; docs/agents.md, Harness and skills ▸ Delivery): a Claude Code plugin in the session's own folder, `.claude-plugin/plugin.json` and `skills/<name>/SKILL.md` for each of `AgentHarness.sessionSkills`, which only that session's process loads through `--plugin-dir`. Codex ignores it and keeps the `guide` topics. It holds no user data and goes with the session's folder.
import AgentControl
import AI
import Foundation

enum AgentSessionSkills {
    /// The plugin's name, which `init` lists skills under, as `arch:arch-browsing`.
    static let pluginName = "arch"
    static let folderName = "arch-skills"

    /// What the session's request names: the folder inside the session's folder, the plugin, and the skills' names.
    static func skills(inSessionFolder sessionFolder: URL) -> AIAgentSkills {
        AIAgentSkills(folder: sessionFolder.appendingPathComponent(folderName, isDirectory: true), plugin: pluginName, names: AgentHarness.sessionSkills.map(\.name))
    }

    /// Writes the plugin's manifest and skills into `skills.folder`, which the runner's session folder holds.
    static func write(_ skills: AIAgentSkills) throws {
        let manifestFolder = skills.folder.appendingPathComponent(".claude-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest: [String: String] = ["name": skills.plugin, "description": "Arch's guide topics for this agent session, written by Arch.", "version": "1"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestFolder.appendingPathComponent("plugin.json"), options: .atomic)
        try AgentSkillInstaller.write(AgentHarness.sessionSkills, into: skills.folder.appendingPathComponent("skills", isDirectory: true))
    }
}
