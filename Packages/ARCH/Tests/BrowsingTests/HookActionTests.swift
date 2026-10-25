// What the built-in hooks' actions do to the browser: a downloaded file's new name is safe, keeps the extension, and avoids taken names, Restore Original Name undoes it, a tab's name is the first line of the reply, cut to length, and a tab takes one only while the user has neither named it nor turned the name down for its document.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@Suite struct DownloadRenameTests {
    @Test func safeNamesKeepTheExtensionAndDropWhatAFileNameCannotHold() {
        #expect(DownloadEntry.safeFilename("Quarterly Report", keepingExtensionOf: "a1b2.pdf") == "Quarterly Report.pdf")
        #expect(DownloadEntry.safeFilename("Quarterly Report.PDF", keepingExtensionOf: "a1b2.pdf") == "Quarterly Report.pdf")
        #expect(DownloadEntry.safeFilename("../2026/Q3: Plan\nFinal", keepingExtensionOf: "x.zip") == "2026Q3 Plan Final.zip")
        #expect(DownloadEntry.safeFilename("Notes", keepingExtensionOf: "README") == "Notes")
        #expect(DownloadEntry.safeFilename("Project Backup", keepingExtensionOf: "backup-2026.tar.gz") == "Project Backup.tar.gz")
        #expect(DownloadEntry.safeFilename("Project Backup.tar.gz", keepingExtensionOf: "backup.TAR.GZ") == "Project Backup.TAR.GZ")
        #expect(DownloadEntry.safeFilename("Notes", keepingExtensionOf: "notes.v2.gz") == "Notes.gz")
        #expect(DownloadEntry.safeFilename(" ... ", keepingExtensionOf: "x.zip") == nil)
        let long = DownloadEntry.safeFilename(String(repeating: "a", count: 100), keepingExtensionOf: "x.pdf")
        #expect(long?.count == DownloadEntry.maximumFilenameLength)
        #expect(long?.hasSuffix("a.pdf") == true)
    }

    @Test func renamingPicksAnUnusedNameAndRestoringPutsTheOriginalBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchBrowsingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("a1b2.pdf")
        try Data("pdf".utf8).write(to: original)
        try Data("other".utf8).write(to: folder.appendingPathComponent("Report.pdf"))
        let entry = DownloadEntry(item: FinishedDownload(targetPath: original), personaID: Persona.defaultID)

        #expect(entry.rename(to: "Report"))
        #expect(entry.filename == "Report 2.pdf")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Report 2.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!entry.rename(to: "Report 2"))

        entry.restoreOriginalName()
        #expect(entry.renamedPath == nil)
        #expect(entry.filename == "a1b2.pdf")
        #expect(try Data(contentsOf: original) == Data("pdf".utf8))

        try FileManager.default.removeItem(at: original)
        #expect(!entry.rename(to: "Gone"))
    }
}

@MainActor
@Suite struct TabNameTests {
    @Test func aTabNameIsTheReplysFirstLineCutToLength() {
        #expect(BuiltInHooks.plainReply("\u{201C}Seoul Weather.\u{201D}\nIt names the forecast.") == "Seoul Weather")
        #expect(BuiltInHooks.plainReply("\n**Release Notes**") == "Release Notes")
        #expect(BrowserHooks.tabName(from: "  Seoul Weather  \nmore") == "Seoul Weather")
        #expect(BrowserHooks.tabName(from: String(repeating: "a", count: 100))?.count == BrowserHooks.maximumTabNameLength)
        #expect(BrowserHooks.tabName(from: "   ") == nil)
    }

    @Test func aTabTakesAHooksNameUntilTheUserNamesItOrTurnsTheNameDown() {
        let page = URL(string: "https://example.org/a")!
        let named = SuggestedTitle(title: "Example", url: page)
        let turnedDown = SuggestedTitle(title: nil, url: page)
        #expect(BrowserHooks.takesName(for: page, customTitle: nil, suggestedTitle: nil, shownURL: URL(string: "https://example.org/a#top")))
        #expect(BrowserHooks.takesName(for: page, customTitle: nil, suggestedTitle: named, shownURL: page))
        #expect(!BrowserHooks.takesName(for: page, customTitle: "Mine", suggestedTitle: nil, shownURL: page))
        #expect(!BrowserHooks.takesName(for: page, customTitle: nil, suggestedTitle: turnedDown, shownURL: page))
        #expect(!BrowserHooks.takesName(for: URL(string: "https://example.org/a#part")!, customTitle: nil, suggestedTitle: turnedDown, shownURL: page))
        #expect(!BrowserHooks.takesName(for: page, customTitle: nil, suggestedTitle: nil, shownURL: URL(string: "https://example.org/b")))
        #expect(named.isFor(URL(string: "https://example.org/a#top")!))
        #expect(!turnedDown.isFor(URL(string: "https://example.org/b")!))
    }
}

/// A download the engine finished at `targetPath`.
private final class FinishedDownload: EngineDownloadItem {
    let id = "1"
    let sourceURL = URL(string: "https://example.org/files/a1b2.pdf")!
    let pageURL: URL? = URL(string: "https://example.org/files")
    let targetPath: URL?
    let state = EngineDownloadState.completed
    let completedBytes: Int64 = 3
    let totalBytes: Int64 = 3
    let startTime = Date()

    init(targetPath: URL) {
        self.targetPath = targetPath
    }

    func pause() {}
    func resume() {}
    func cancel() {}
    func remove() {}
}
