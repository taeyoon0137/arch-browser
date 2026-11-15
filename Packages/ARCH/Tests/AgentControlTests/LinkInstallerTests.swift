// The setup commands without the user's own folders: the MCP configuration texts and `setup`'s commands for a bundle path, and the PATH link installer in a temporary home folder with folders on and off PATH, inside and outside that home, an Arch bundle's own `Contents/Helpers` among them, links into Arch bundles, and files that are not Arch's.
import AgentControl
import Darwin
import Foundation
import Testing

@Suite struct MCPConfigurationTests {
    private let path = "/Applications/Arch.app/Contents/Helpers/arch-mcp"

    @Test func eachClientsConfigurationNamesArchMCPByItsPath() throws {
        #expect(AgentMCPConfiguration.text(.claude, mcpPath: path) == "claude mcp add --scope user arch -- /Applications/Arch.app/Contents/Helpers/arch-mcp")
        #expect(AgentMCPConfiguration.text(.codex, mcpPath: path) == """
            [mcp_servers.arch]
            command = "/Applications/Arch.app/Contents/Helpers/arch-mcp"
            tool_timeout_sec = 645
            """)
        let json = try AgentJSON.decode(Data(AgentMCPConfiguration.text(.json, mcpPath: path).utf8))
        #expect(json == ["mcpServers": ["arch": ["command": .string(path)]]])
    }

    @Test func setupRunsTheToolsOwnCommand() {
        #expect(AgentMCPConfiguration.setupArguments(for: .claude, mcpPath: path) == ["claude", "mcp", "add", "--scope", "user", "arch", "--", path])
        #expect(AgentMCPConfiguration.setupArguments(for: .codex, mcpPath: path) == ["codex", "mcp", "add", "arch", "--", path])
    }

    @Test func pathsThatNeedQuotingAreQuoted() throws {
        let odd = "/Users/someone/My Apps/Arch's \"test\".app/Contents/Helpers/arch-mcp"
        #expect(AgentMCPConfiguration.text(.claude, mcpPath: odd) == #"claude mcp add --scope user arch -- '/Users/someone/My Apps/Arch'\''s "test".app/Contents/Helpers/arch-mcp'"#)
        #expect(AgentMCPConfiguration.text(.codex, mcpPath: odd).contains(#"command = "/Users/someone/My Apps/Arch's \"test\".app/Contents/Helpers/arch-mcp""#))
        #expect(AgentMCPConfiguration.text(.codex, mcpPath: "/a\\b\u{7}").contains(#"command = "/a\\b\u0007""#))
        #expect(try AgentJSON.decode(Data(AgentMCPConfiguration.text(.json, mcpPath: odd).utf8))["mcpServers"]?["arch"]?["command"] == .string(odd))
        #expect(AgentMCPConfiguration.shellCommand(["echo", ""]) == "echo ''")
    }
}

/// A home folder in the temporary folder with `.local/bin`, `bin`, a read-only folder, and a folder outside it, removed afterward.
private final class TemporaryHome {
    let root: URL
    let home: URL
    let local: URL
    let bin: URL
    let readOnly: URL
    let outside: URL
    let bundle: AgentBundleLayout
    let otherBundle: AgentBundleLayout

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("act-links-\(UUID().uuidString.prefix(8))")
        home = root.appendingPathComponent("home")
        local = home.appendingPathComponent(".local/bin")
        bin = home.appendingPathComponent("bin")
        readOnly = home.appendingPathComponent("locked")
        outside = root.appendingPathComponent("outside")
        for folder in [local, bin, readOnly, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        chmod(readOnly.path, 0o555)
        // The links may point at files that do not exist; the installer reads only the bundle's layout.
        bundle = AgentBundleLayout(bundleURL: home.appendingPathComponent("Applications/Arch.app"))
        otherBundle = AgentBundleLayout(bundleURL: root.appendingPathComponent("Old/Arch.app"))
    }

    deinit {
        chmod(readOnly.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func installer(_ folders: [URL]) -> AgentLinkInstaller {
        AgentLinkInstaller(homeFolder: home, searchPath: folders.map(\.path).joined(separator: ":"))
    }

    func destination(_ name: String, in folder: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(name).path)
    }
}

@Suite struct LinkInstallerTests {
    @Test func theFolderIsAWritableOneOnPATHInsideTheHomeWithLocalBinFirst() throws {
        let home = try TemporaryHome()
        // ~/.local/bin comes first even when PATH lists another home folder before it.
        #expect(try home.installer([home.outside, URL(fileURLWithPath: "/usr/bin"), home.bin, home.local]).installFolder(named: nil).path == home.local.path)
        #expect(try home.installer([home.outside, home.readOnly, home.bin]).installFolder(named: nil).path == home.bin.path)
        // Folders outside the home folder and read-only ones are never chosen.
        #expect(throws: AgentLinkInstaller.Failure.noFolder) { try home.installer([home.outside, home.readOnly, URL(fileURLWithPath: "/usr/local/bin")]).installFolder(named: nil) }
        #expect(throws: AgentLinkInstaller.Failure.noFolder) { try home.installer([]).installFolder(named: nil) }
        #expect(AgentLinkInstaller.Failure.noFolder.message.contains("--dir"))
        #expect(AgentLinkInstaller.Failure.noFolder.exitCode == .toolError)
        // Relative PATH entries are not folders anyone can rely on.
        #expect(AgentLinkInstaller(homeFolder: home.home, searchPath: "bin:.:\(home.bin.path):\(home.bin.path)").searchFolders.map(\.path) == [home.bin.path])
        // A folder that PATH spells twice is looked in once.
        #expect(try AgentLinkInstaller(homeFolder: home.home, searchPath: "\(home.local.path):\(home.local.path)/").removalFolders(named: nil).map(\.path) == [home.local.path])
    }

    @Test func aNamedFolderMustBeAWritableFolderInsideTheHome() throws {
        let home = try TemporaryHome()
        let installer = home.installer([home.local])
        #expect(try installer.installFolder(named: home.bin.path).path == home.bin.path)
        #expect(throws: AgentLinkInstaller.Failure.outsideHome(home.outside.path)) { try installer.installFolder(named: home.outside.path) }
        #expect(throws: AgentLinkInstaller.Failure.notAFolder(home.home.appendingPathComponent("missing").path)) { try installer.installFolder(named: home.home.appendingPathComponent("missing").path) }
        #expect(throws: AgentLinkInstaller.Failure.notWritable(home.readOnly.path)) { try installer.installFolder(named: home.readOnly.path) }
        // A link inside the home folder to a folder outside it is outside.
        let escape = home.home.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: home.outside)
        #expect(throws: AgentLinkInstaller.Failure.outsideHome(escape.path)) { try installer.installFolder(named: escape.path) }
        #expect(AgentLinkInstaller.Failure.outsideHome("x").exitCode == .usage)
        #expect(installer.isOnSearchPath(home.local))
        #expect(!installer.isOnSearchPath(home.bin))
    }

    @Test func installLinksBothToolsAndReplacesOnlyLinksIntoAnArchBundle() throws {
        let home = try TemporaryHome()
        let installer = home.installer([home.local])
        let links = AgentLinkInstaller.links(in: home.local, for: home.bundle)
        #expect(links.map(\.location.lastPathComponent) == ["arch-cli", "arch-mcp"])
        try installer.install(links)
        #expect(home.destination("arch-cli", in: home.local) == home.bundle.cliExecutableURL.path)
        #expect(home.destination("arch-mcp", in: home.local) == home.bundle.mcpExecutableURL.path)
        // Again, and over links into another Arch bundle, as after the app moved.
        try installer.install(links)
        try installer.install(AgentLinkInstaller.links(in: home.bin, for: home.otherBundle))
        try installer.install(AgentLinkInstaller.links(in: home.bin, for: home.bundle))
        #expect(home.destination("arch-mcp", in: home.bin) == home.bundle.mcpExecutableURL.path)
    }

    @Test func aFileThatIsNotArchsLeavesBothLinksUnwritten() throws {
        let home = try TemporaryHome()
        let installer = home.installer([home.local])
        // A file of the user's named arch-mcp, and a link elsewhere named arch-cli.
        try Data("#!/bin/sh\n".utf8).write(to: home.local.appendingPathComponent("arch-mcp"))
        #expect(throws: AgentLinkInstaller.Failure.foreignFile(home.local.appendingPathComponent("arch-mcp").path)) {
            try installer.install(AgentLinkInstaller.links(in: home.local, for: home.bundle))
        }
        #expect(home.destination("arch-cli", in: home.local) == nil)
        try FileManager.default.createSymbolicLink(atPath: home.bin.appendingPathComponent("arch-cli").path, withDestinationPath: "/usr/bin/true")
        #expect(throws: AgentLinkInstaller.Failure.foreignFile(home.bin.appendingPathComponent("arch-cli").path)) {
            try installer.install(AgentLinkInstaller.links(in: home.bin, for: home.bundle))
        }
        #expect(home.destination("arch-cli", in: home.bin) == "/usr/bin/true")
        #expect(home.destination("arch-mcp", in: home.bin) == nil)
        #expect(AgentLinkInstaller.Failure.foreignFile("x").exitCode == .refused)
    }

    @Test func removeDeletesOnlyLinksIntoAnArchBundle() throws {
        let home = try TemporaryHome()
        let installer = home.installer([home.outside, home.local, home.bin])
        try installer.install(AgentLinkInstaller.links(in: home.local, for: home.bundle))
        try FileManager.default.createSymbolicLink(atPath: home.bin.appendingPathComponent("arch-mcp").path, withDestinationPath: "../Old/Arch.app/Contents/Helpers/arch-cli")
        try Data("mine".utf8).write(to: home.bin.appendingPathComponent("arch-cli"))
        try FileManager.default.createSymbolicLink(atPath: home.outside.appendingPathComponent("arch-cli").path, withDestinationPath: home.bundle.cliExecutableURL.path)
        let folders = try installer.removalFolders(named: nil)
        #expect(folders.map(\.path) == [home.local.path, home.bin.path])
        let removed = try installer.remove(from: folders)
        #expect(removed.map(\.path) == ["arch-cli", "arch-mcp"].map { home.local.appendingPathComponent($0).path } + [home.bin.appendingPathComponent("arch-mcp").path])
        // The user's file and the link outside the home folder stay.
        #expect(FileManager.default.fileExists(atPath: home.bin.appendingPathComponent("arch-cli").path))
        #expect(home.destination("arch-cli", in: home.outside) == home.bundle.cliExecutableURL.path)
        #expect(try installer.remove(from: folders) == [])
        #expect(throws: AgentLinkInstaller.Failure.outsideHome(home.outside.path)) { try installer.removalFolders(named: home.outside.path) }
    }

    @Test func aFolderInsideAnAppBundleIsNeverUsed() throws {
        let home = try TemporaryHome()
        // Arch's own Contents/Helpers on PATH, with the bundle's arch-cli and its relative arch-mcp link.
        let helpers = home.bundle.helpersURL
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: home.bundle.cliExecutableURL)
        try FileManager.default.createSymbolicLink(atPath: home.bundle.mcpExecutableURL.path, withDestinationPath: AgentBundleLayout.cliName)
        let installer = home.installer([helpers, home.local])
        #expect(try installer.removalFolders(named: nil).map(\.path) == [home.local.path])
        #expect(try installer.remove(from: installer.removalFolders(named: nil)) == [])
        #expect(throws: AgentLinkInstaller.Failure.noFolder) { try home.installer([helpers]).installFolder(named: nil) }
        // Named, directly or through a link to it, a folder in a bundle is a usage error.
        let shortcut = home.home.appendingPathComponent("helpers")
        try FileManager.default.createSymbolicLink(at: shortcut, withDestinationURL: helpers)
        for folder in [helpers, shortcut, home.bundle.bundleURL.appendingPathComponent("Contents")] {
            #expect(throws: AgentLinkInstaller.Failure.insideAppBundle(folder.path)) { try installer.installFolder(named: folder.path) }
            #expect(throws: AgentLinkInstaller.Failure.insideAppBundle(folder.path)) { try installer.removalFolders(named: folder.path) }
        }
        #expect(AgentLinkInstaller.Failure.insideAppBundle("x").exitCode == .usage)
        #expect(home.destination(AgentBundleLayout.mcpName, in: helpers) == AgentBundleLayout.cliName)
        #expect(FileManager.default.fileExists(atPath: home.bundle.cliExecutableURL.path))
    }

    @Test func archLinksPointIntoAnAppBundlesHelpers() {
        let folder = URL(fileURLWithPath: "/Users/someone/.local/bin")
        #expect(AgentLinkInstaller.isArchLink(destination: "/Applications/Arch.app/Contents/Helpers/arch-cli", in: folder))
        #expect(AgentLinkInstaller.isArchLink(destination: "../../Applications/Arch.app/Contents/Helpers/arch-mcp", in: folder))
        #expect(!AgentLinkInstaller.isArchLink(destination: "/Applications/Arch.app/Contents/MacOS/Arch", in: folder))
        #expect(!AgentLinkInstaller.isArchLink(destination: "/usr/local/bin/arch-cli", in: folder))
        #expect(!AgentLinkInstaller.isArchLink(destination: "/Applications/Arch/Contents/Helpers/arch-cli", in: folder))
    }
}
