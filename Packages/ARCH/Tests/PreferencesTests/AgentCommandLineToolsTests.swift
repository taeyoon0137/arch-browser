// Settings ▸ AI ▸ Agents ▸ Command-Line Tools without its view: the links Install Command-Line Tools… plans and shows before writing, the links on PATH that the section lists and Remove removes, and the sentences it shows, in a temporary home folder with a scratch app bundle.
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
        AgentCommandLineTools(bundle: bundle, homeFolder: home, searchPath: folders.map(\.path).joined(separator: ":"))
    }

    func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

@Suite struct AgentCommandLineToolsTests {
    @Test func installPlansBothLinksInLocalBinAndShowsBothPathsBeforeWriting() throws {
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
        // Planning writes nothing; the confirmation comes first.
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

    @Test func aFileInTheWayLeavesBothPlacesAlone() throws {
        let scratch = try ScratchHome()
        let tools = scratch.commandLineTools([scratch.local])
        try Data("#!/bin/sh\n".utf8).write(to: scratch.local.appendingPathComponent("arch-mcp"))
        let links = try tools.plannedLinks()
        #expect(throws: AgentLinkInstaller.Failure.foreignFile(scratch.local.appendingPathComponent("arch-mcp").path)) { try tools.install(links) }
        #expect(scratch.contents(of: scratch.local) == ["arch-mcp"])
        #expect(AgentCommandLineTools.sentence(for: .foreignFile("/x")) == AgentLinkInstaller.Failure.foreignFile("/x").message)
    }

    @Test func withoutAWritableFolderOnPATHTheSentenceSaysToReopenArch() throws {
        let scratch = try ScratchHome()
        #expect(throws: AgentLinkInstaller.Failure.noFolder) { try scratch.commandLineTools([scratch.outside, URL(fileURLWithPath: "/usr/bin")]).plannedLinks() }
        let sentence = AgentCommandLineTools.sentence(for: .noFolder)
        #expect(sentence.hasPrefix(AgentLinkInstaller.Failure.noFolder.message))
        #expect(sentence.hasSuffix("quit and reopen Arch after changing it."))
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
