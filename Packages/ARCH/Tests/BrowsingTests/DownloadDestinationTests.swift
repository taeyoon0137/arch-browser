import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@Suite @MainActor struct DownloadDestinationTests {
    @Test func aSmallWindowOpensTheDownloadsInItsMainWindow() throws {
        try withFixture { session, _, _, _ in
            let space = try #require(session.spaces.first)
            let record = SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: false)
            let main = session.makeWindow(from: record, kind: .main)
            let small = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: false), kind: .small)
            defer { session.windowWillClose(small); session.windowWillClose(main) }
            main.nsWindow = nil
            small.toggleLibrary()
            #expect(main.isSidebarVisible && main.isLibraryVisible)
            #expect(!small.isSidebarVisible && !small.isLibraryVisible)
            small.toggleLibrary()
            #expect(main.isLibraryVisible)
        }
    }

    @Test func closingADownloadOnlyTabReturnsToItsSourceOrPreviousTab() throws {
        try withFixture { session, _, _, _ in
            let space = try #require(session.spaces.first)
            let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(window) }
            @MainActor func tab() -> Tab {
                session.openTab(url: URL(string: "about:blank")!, in: space.id, select: false, engine: .chromium)
            }
            let unrelated = tab(), source = tab()
            window.selectTab(source.id)
            let popup = tab()
            popup.opener = source.webContents
            window.selectTab(popup.id)
            session.closeTab(popup, reason: .download)
            #expect(window.selectedTabID == source.id)

            window.selectTab(source.id)
            let direct = tab()
            window.selectTab(direct.id)
            session.closeTab(direct, reason: .download)
            #expect(window.selectedTabID == source.id)

            let background = tab()
            background.opener = source.webContents
            window.selectTab(unrelated.id)
            session.closeTab(background, reason: .download)
            #expect(window.selectedTabID == unrelated.id)
        }
    }

    @Test func simultaneousRequestsReserveNamesAcrossProfilesBeforeEitherFileExists() throws {
        try withFixture { session, chromium, webKit, directory in
            let existing = directory.appendingPathComponent("report.txt")
            try Data("existing".utf8).write(to: existing)
            let first = TestDownload(), second = TestDownload()
            chromium.delegate?.downloads(chromium, didCreate: first)
            webKit.delegate?.downloads(webKit, didCreate: second)
            #expect(session.downloads.count == 2)
            let firstURL = try #require(choose(first, in: chromium, name: "report.txt"))
            let secondURL = try #require(choose(second, in: webKit, name: "report.txt"))
            #expect(firstURL.lastPathComponent == "report 2.txt")
            #expect(secondURL.lastPathComponent == "report 3.txt")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["report.txt"])
            #expect(try Data(contentsOf: existing) == Data("existing".utf8))
        }
    }

    @Test func interruptedAndPausedDownloadsKeepTheirNamesUntilTheyEndOrAreRemoved() throws {
        try withFixture { session, chromium, webKit, directory in
            let first = TestDownload(), second = TestDownload(), third = TestDownload()
            let fourth = TestDownload()
            chromium.delegate?.downloads(chromium, didCreate: first)
            webKit.delegate?.downloads(webKit, didCreate: second)
            chromium.delegate?.downloads(chromium, didCreate: third)
            webKit.delegate?.downloads(webKit, didCreate: fourth)
            let original = directory.appendingPathComponent("notes")
            #expect(choose(first, in: chromium, name: "notes") == original)
            first.state = .failed
            chromium.delegate?.downloads(chromium, didUpdate: first)
            #expect(choose(second, in: webKit, name: "notes")?.lastPathComponent == "notes 2")
            first.resume()
            chromium.delegate?.downloads(chromium, didUpdate: first)
            #expect(choose(first, in: chromium, name: "notes") == original)
            second.pause()
            webKit.delegate?.downloads(webKit, didUpdate: second)
            #expect(choose(third, in: chromium, name: "notes")?.lastPathComponent == "notes 3")
            #expect(choose(fourth, in: webKit, name: "notes")?.lastPathComponent == "notes 4")
            first.cancel()
            chromium.delegate?.downloads(chromium, didUpdate: first)
            let replacement = TestDownload()
            chromium.delegate?.downloads(chromium, didCreate: replacement)
            #expect(choose(replacement, in: chromium, name: "notes") == original)
            chromium.delegate?.downloads(chromium, didRemove: third)
            second.resume()
            webKit.delegate?.downloads(webKit, didUpdate: second)
            #expect(choose(second, in: webKit, name: "notes")?.lastPathComponent == "notes 2")
            let last = TestDownload()
            chromium.delegate?.downloads(chromium, didCreate: last)
            #expect(choose(last, in: chromium, name: "notes")?.lastPathComponent == "notes 3")
            #expect(session.downloads.count == 5)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(files.isEmpty)
        }
    }

    @Test func deletingAPersonaCancelsItsRetryAndReleasesOnlyItsReservedNames() throws {
        try withFixture { session, surviving, retiring, directory in
            let failed = TestDownload(), otherFailed = TestDownload(), completed = TestDownload()
            retiring.delegate?.downloads(retiring, didCreate: failed)
            surviving.delegate?.downloads(surviving, didCreate: otherFailed)
            let name = try #require(choose(failed, in: retiring, name: "report.txt"))
            #expect(choose(otherFailed, in: surviving, name: "report.txt")?.lastPathComponent == "report 2.txt")
            failed.state = .failed
            otherFailed.state = .failed
            retiring.delegate?.downloads(retiring, didUpdate: failed)
            surviving.delegate?.downloads(surviving, didUpdate: otherFailed)
            completed.state = .completed
            let saved = directory.appendingPathComponent("finished.txt")
            try Data("kept".utf8).write(to: saved)
            completed.targetPath = saved
            retiring.delegate?.downloads(retiring, didCreate: completed)

            let personaID = try #require(session.downloads.first(where: { $0.item === failed })?.personaID)
            session.deletePersona(personaID)

            #expect(failed.state == .cancelled)
            #expect(otherFailed.state == .failed && completed.state == .completed)
            #expect(try Data(contentsOf: saved) == Data("kept".utf8))
            #expect(choose(failed, in: retiring, name: "report.txt") == nil)
            let replacement = TestDownload()
            surviving.delegate?.downloads(surviving, didCreate: replacement)
            #expect(choose(replacement, in: surviving, name: "report.txt") == name)
            #expect(choose(otherFailed, in: surviving, name: "report.txt")?.lastPathComponent == "report 2.txt")
        }
    }

    @Test func manualChoicesAndFinishedFileRenamesRespectOtherDownloads() throws {
        try withFixture { session, chromium, webKit, directory in
            let finished = TestDownload(), manual = TestDownload(), automatic = TestDownload()
            let original = directory.appendingPathComponent("original.txt")
            let renamed = directory.appendingPathComponent("Report.txt")
            try Data("finished".utf8).write(to: original)
            finished.state = .completed
            finished.targetPath = original
            chromium.delegate?.downloads(chromium, didCreate: finished)
            webKit.delegate?.downloads(webKit, didCreate: manual)
            chromium.delegate?.downloads(chromium, didCreate: automatic)
            let entry = try #require(session.downloads.first { $0.item === finished })
            let manualEntry = try #require(session.downloads.first { $0.item === manual })
            let automaticEntry = try #require(session.downloads.first { $0.item === automatic })
            #expect(manualEntry.reserveDestination(renamed))
            #expect(!automaticEntry.reserveDestination(renamed))
            #expect(entry.rename(to: "Report"))
            #expect(entry.filename == "Report 2.txt")
            #expect(choose(automatic, in: chromium, name: "original.txt") == original)
            entry.restoreOriginalName()
            #expect(entry.filename == "original 2.txt")
            entry.restoreOriginalName()
            #expect(entry.filename == "original 2.txt")
            #expect(try Data(contentsOf: #require(entry.fileURL)) == Data("finished".utf8))
            #expect(!FileManager.default.fileExists(atPath: original.path))
            chromium.delegate?.downloads(chromium, didRemove: automatic)
            entry.restoreOriginalName()
            #expect(entry.fileURL == original)
            // An explicitly accepted panel URL can still replace an ordinary file.
            #expect(manualEntry.reserveDestination(original))
            #expect(try Data(contentsOf: original) == Data("finished".utf8))
        }
    }

    @Test func reservationsFollowFolderAliasesAndTheVolumesCaseSensitivity() throws {
        try withFixture { session, chromium, webKit, directory in
            let alias = directory.deletingLastPathComponent().appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            let first = TestDownload(), second = TestDownload()
            chromium.delegate?.downloads(chromium, didCreate: first)
            webKit.delegate?.downloads(webKit, didCreate: second)
            let entry = try #require(session.downloads.first { $0.item === first })
            #expect(entry.reserveDestination(alias.appendingPathComponent("REPORT.txt")))
            let caseSensitive = try #require(directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
            let expected = caseSensitive ? "report.txt" : "report 2.txt"
            #expect(choose(second, in: webKit, name: "report.txt")?.lastPathComponent == expected)
            first.state = .completed
            chromium.delegate?.downloads(chromium, didUpdate: first)
            let next = TestDownload()
            chromium.delegate?.downloads(chromium, didCreate: next)
            #expect(choose(next, in: chromium, name: "REPORT.txt")?.lastPathComponent == "REPORT.txt")
        }
    }

    private func withFixture(_ body: (BrowserSession, any EngineDownloads, any EngineDownloads, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine(kind: .chromium))
        registry.register(SessionTestEngine(kind: .webKit))
        let session = try BrowserSession(testRegistry: registry, directory: root)
        let other = session.addPersona(named: "Work")
        let chromium = session.runtime(for: .chromium, in: Persona.defaultID).context
        let webKit = session.runtime(for: .webKit, in: other.id).context
        for context in [chromium, webKit] { context.preferences = EnginePreferences(downloadFilePath: directory) }
        try body(session, chromium.downloads, webKit.downloads, directory)
    }

    private func choose(_ item: TestDownload, in downloads: any EngineDownloads, name: String) -> URL? {
        var url: URL?
        downloads.delegate?.downloads(downloads, determineFilenameFor: item, defaultFilename: name) { url = $0 }
        return url
    }

    private final class TestDownload: EngineDownloadItem {
        let sourceURL = URL(string: "https://fixture.invalid/file")!
        let pageURL: URL? = nil
        let webContents: (any EngineWebContents)? = nil
        var targetPath: URL?
        var state: EngineDownloadState = .inProgress
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        func pause() { state = .paused }
        func resume() { state = .inProgress }
        func cancel() { state = .cancelled }
        func remove() {}
    }
}
