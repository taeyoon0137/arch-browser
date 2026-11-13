// Settings ▸ AI ▸ Agents ▸ Command-Line Tools without its view: the links Install Command-Line Tools… plans and its confirmation's text, the links on PATH that the section lists and Remove removes, and the sentences it shows, in a temporary home folder with a scratch app bundle.
import AgentControl
import Darwin
import Foundation
import Testing
@testable import Preferences

/// A home folder in the temporary folder with `.local/bin`, `bin`, and `tools`, a folder outside it, and an Arch bundle inside it whose helpers may not exist, removed afterward.
private final class ScratchHome {
    let root: URL
    let home: URL
    let local: URL
    let bin: URL
    let tools: URL
    let outside: URL
    let bundle: AgentBundleLayout

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pref-links-\(UUID().uuidString.prefix(8))")
        home = root.appendingPathComponent("home")
        local = home.appendingPathComponent(".local/bin")
        bin = home.appendingPathComponent("bin")
        tools = home.appendingPathComponent("tools")
        outside = root.appendingPathComponent("outside")
        for folder in [local, bin, tools, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        bundle = AgentBundleLayout(bundleURL: home.appendingPathComponent("Applications/Arch.app"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func commandLineTools(_ folders: [URL]) -> AgentCommandLineTools {
        commandLineTools(searchPath: folders.map(\.path).joined(separator: ":"))
    }

    func commandLineTools(searchPath: String) -> AgentCommandLineTools {
        AgentCommandLineTools(bundle: bundle, homeFolder: home, searchPath: searchPath)
    }

    /// Writes a bundle's `arch-cli` as an executable script and `arch-mcp` as a relative link to it, as `scripts/bundle_app.sh` lays them out.
    func makeHelpers(of bundle: AgentBundleLayout) throws {
        try FileManager.default.createDirectory(at: bundle.helpersURL, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bundle.cliExecutableURL)
        chmod(bundle.cliExecutableURL.path, 0o755)
        try FileManager.default.createSymbolicLink(atPath: bundle.mcpExecutableURL.path, withDestinationPath: AgentBundleLayout.cliName)
    }

    func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

@Suite struct AgentCommandLineToolsTests {
    @Test func installPlansBothLinksInLocalBinWithoutWritingAndItsConfirmationShowsBothPaths() throws {
        let scratch = try ScratchHome()
        let tools = scratch.commandLineTools([scratch.outside, scratch.bin, scratch.local])
        let links = try tools.plannedLinks()
        #expect(links.map(\.location.path) == [scratch.local.appendingPathComponent("arch-cli").path, scratch.local.appendingPathComponent("arch-mcp").path])
        #expect(links.map(\.destination.path) == [scratch.bundle.cliExecutableURL.path, scratch.bundle.mcpExecutableURL.path])
        #expect(AgentCommandLineTools.confirmation(for: links, bundle: scratch.bundle) == """
            arch-cli and arch-mcp are in \(scratch.bundle.helpersURL.path). Arch links them into \(scratch.local.path):
            \(scratch.local.path)/arch-cli \u{2192} \(scratch.bundle.cliExecutableURL.path)
            \(scratch.local.path)/arch-mcp \u{2192} \(scratch.bundle.mcpExecutableURL.path)
            """)
        // Planning writes nothing. That the view shows the confirmation before Install writes is check 62's.
        #expect(scratch.contents(of: scratch.local).isEmpty)
        #expect(tools.installedLinks().isEmpty)
    }

    @Test func installLinksBothToolsAndRemoveUnlinksOnlyLinksIntoArch() throws {
        let scratch = try ScratchHome()
        let tools = scratch.commandLineTools([scratch.local, scratch.bin, scratch.tools, scratch.outside])
        try tools.install(try tools.plannedLinks())
        // A relative link into another Arch bundle, as an earlier copy may have left, a file of the same name that is not Arch's, and a link outside the home folder.
        let other = AgentBundleLayout(bundleURL: scratch.home.appendingPathComponent("Old/Arch.app"))
        try FileManager.default.createSymbolicLink(atPath: scratch.bin.appendingPathComponent("arch-mcp").path, withDestinationPath: "../Old/Arch.app/Contents/Helpers/arch-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: scratch.tools.appendingPathComponent("arch-cli"))
        try FileManager.default.createSymbolicLink(atPath: scratch.outside.appendingPathComponent("arch-cli").path, withDestinationPath: scratch.bundle.cliExecutableURL.path)

        let installed = tools.installedLinks()
        #expect(installed.map(\.location.path) == [scratch.local.appendingPathComponent("arch-cli").path, scratch.local.appendingPathComponent("arch-mcp").path, scratch.bin.appendingPathComponent("arch-mcp").path])
        #expect(installed.map(\.destination.path) == [scratch.bundle.cliExecutableURL.path, scratch.bundle.mcpExecutableURL.path, other.mcpExecutableURL.path])

        let removed = try tools.removeLinks()
        #expect(removed.map(\.path) == installed.map(\.location.path))
        #expect(tools.installedLinks().isEmpty)
        #expect(scratch.contents(of: scratch.local).isEmpty)
        #expect(scratch.contents(of: scratch.bin).isEmpty)
        #expect(scratch.contents(of: scratch.tools) == ["arch-cli"])
        #expect(scratch.contents(of: scratch.outside) == ["arch-cli"])
        #expect(try tools.removeLinks().isEmpty)
    }

    @Test func aFolderThatPATHSpellsTwiceListsItsLinksOnce() throws {
        let scratch = try ScratchHome()
        // The same folder with a trailing slash, and through a link to it.
        let alias = scratch.home.appendingPathComponent("lbin")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: ".local/bin")
        let tools = scratch.commandLineTools(searchPath: [scratch.local.path, scratch.local.path + "/", alias.path].joined(separator: ":"))
        try tools.install(try tools.plannedLinks())
        let installed = tools.installedLinks()
        #expect(installed.map(\.location.path) == [scratch.local.appendingPathComponent("arch-cli").path, scratch.local.appendingPathComponent("arch-mcp").path])
        #expect(Set(installed.map(\.location.path)).count == installed.count)
        #expect(try tools.removeLinks().map(\.path) == installed.map(\.location.path))
        #expect(scratch.contents(of: scratch.local).isEmpty)
    }

    @Test func installNamesAFileThatPATHReachesFirstByALinksName() throws {
        let scratch = try ScratchHome()
        try scratch.makeHelpers(of: scratch.bundle)
        let other = AgentBundleLayout(bundleURL: scratch.home.appendingPathComponent("Old/Arch.app"))
        try scratch.makeHelpers(of: other)
        // An older bundle's arch-cli in a home folder before ~/.local/bin, which Remove removes, and an arch-mcp that is not Arch's outside the home folder.
        try FileManager.default.createSymbolicLink(atPath: scratch.bin.appendingPathComponent("arch-cli").path, withDestinationPath: other.cliExecutableURL.path)
        let foreign = scratch.outside.appendingPathComponent("arch-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: foreign)
        chmod(foreign.path, 0o755)
        let tools = scratch.commandLineTools([scratch.outside, scratch.bin, scratch.local])
        let links = try tools.plannedLinks()
        try tools.install(links)
        #expect(tools.installedSentence(for: links) == "Linked arch-cli and arch-mcp into \(scratch.local.path). \(scratch.bin.path)/arch-cli comes first on your PATH and runs instead; Remove, then Install again, to replace it. \(foreign.path) comes first on your PATH and runs instead.")

        // After Remove and Install, and with the file that is not Arch's gone, PATH reaches the bundle's tools; a link to this bundle earlier on PATH runs the same file.
        _ = try tools.removeLinks()
        try tools.install(links)
        try FileManager.default.removeItem(at: foreign)
        try FileManager.default.createSymbolicLink(atPath: scratch.bin.appendingPathComponent("arch-mcp").path, withDestinationPath: scratch.bundle.mcpExecutableURL.path)
        #expect(tools.installedSentence(for: links) == "Linked arch-cli and arch-mcp into \(scratch.local.path).")
    }

    @Test func aFileInTheWayLeavesBothPlacesAlone() throws {
        let scratch = try ScratchHome()
        let tools = scratch.commandLineTools([scratch.local])
        try Data("#!/bin/sh\n".utf8).write(to: scratch.local.appendingPathComponent("arch-mcp"))
        let links = try tools.plannedLinks()
        #expect(throws: AgentLinkInstaller.Failure.foreignFile(scratch.local.appendingPathComponent("arch-mcp").path)) { try tools.install(links) }
        #expect(scratch.contents(of: scratch.local) == ["arch-mcp"])
        #expect(AgentCommandLineTools.sentence(for: .foreignFile("/x"), bundle: scratch.bundle) == AgentLinkInstaller.Failure.foreignFile("/x").message)
    }

    @Test func withoutAWritableFolderOnPATHTheSentenceNamesTheBundlesCommandAndSaysToReopenArch() throws {
        let scratch = try ScratchHome()
        #expect(throws: AgentLinkInstaller.Failure.noFolder) { try scratch.commandLineTools([scratch.outside, URL(fileURLWithPath: "/usr/bin")]).plannedLinks() }
        let sentence = AgentCommandLineTools.sentence(for: .noFolder, bundle: scratch.bundle)
        #expect(sentence.hasPrefix("No folder on your PATH inside your home folder is writable. Make one and add it to PATH"))
        // Settings has no --dir of its own, so the sentence names the command that has it.
        #expect(sentence.contains("or run \(scratch.bundle.cliExecutableURL.path) links install --dir <folder> in a terminal."))
        #expect(!sentence.contains("name a folder with --dir"))
        #expect(sentence.hasSuffix("quit and reopen Arch after changing it."))
    }

    @Test func withoutTheLoginShellsPATHTheSentenceNamesBothCommands() throws {
        let scratch = try ScratchHome()
        let sentence = AgentCommandLineTools.unreadPathSentence(bundle: scratch.bundle)
        #expect(sentence.contains("\(scratch.bundle.cliExecutableURL.path) links install links the tools"))
        #expect(sentence.contains("\(scratch.bundle.cliExecutableURL.path) links remove removes Arch's links."))
    }

    @Test func aBundleThatMacOSRunsFromATemporaryFolderIsTranslocated() throws {
        let scratch = try ScratchHome()
        #expect(!AgentCommandLineTools.isTranslocated(scratch.bundle))
        #expect(AgentCommandLineTools.isTranslocated(AgentBundleLayout(bundleURL: URL(fileURLWithPath: "/private/var/folders/xy/abc/T/AppTranslocation/6D1E2F30-0000-4000-8000-000000000000/d/Arch.app"))))
        // Only a folder of that name counts, not a name that contains it.
        #expect(!AgentCommandLineTools.isTranslocated(AgentBundleLayout(bundleURL: scratch.home.appendingPathComponent("NotAppTranslocation/Arch.app"))))
    }

    @Test func onlyABundleWithItsCLIHasToolsToShow() throws {
        let scratch = try ScratchHome()
        #expect(!AgentCommandLineTools.hasTools(scratch.bundle))
        try FileManager.default.createDirectory(at: scratch.bundle.helpersURL, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: scratch.bundle.cliExecutableURL)
        #expect(!AgentCommandLineTools.hasTools(scratch.bundle))
        chmod(scratch.bundle.cliExecutableURL.path, 0o755)
        #expect(AgentCommandLineTools.hasTools(scratch.bundle))
    }
}
