// What the library button and the Clear button show of the downloads: whether one is in progress, the combined progress of those that know their size, and whether one has finished, each published only when it changes.
import ARCHEngine
import Combine
import Foundation
import Testing
@testable import Browsing

@Suite struct DownloadSummaryTests {
    @Test func theSummaryCombinesTheDownloadsInProgressThatKnowTheirSize() {
        let sized = StubDownload(completedBytes: 25, totalBytes: 100)
        let unsized = StubDownload(completedBytes: 10, totalBytes: 0)
        let finished = StubDownload(state: .completed, completedBytes: 300, totalBytes: 300)
        let summary = DownloadSummary()
        summary.refresh(from: [sized, unsized].map(entry))
        #expect(summary.isDownloading && summary.progress == 0.25 && !summary.hasFinished)

        let entries = [sized, unsized, finished].map(entry)
        summary.refresh(from: entries)
        #expect(summary.progress == 0.25 && summary.hasFinished)

        unsized.state = .cancelled
        sized.state = .paused
        entries.forEach { $0.refresh() }
        summary.refresh(from: entries)
        #expect(!summary.isDownloading && summary.progress == nil && summary.hasFinished)
    }

    @Test func accessibilityDescribesAStartedTransferBeforeOnePercent() {
        let summary = DownloadSummary()
        let download = StubDownload(completedBytes: 0, totalBytes: 734_000_000)
        let entries = [entry(download)]
        for (bytes, value) in [(0, "Downloading, 0%"), (409_600, "Downloading, less than 1%"), (7_340_000, "Downloading, 1%"), (733_999_999, "Downloading, 99%")] {
            download.completedBytes = Int64(bytes)
            entries[0].refresh()
            summary.refresh(from: entries)
            #expect(summary.progressDescription == value)
        }
    }

    @Test func onlyAChangeToWhatTheSummaryShowsPublishes() {
        let download = StubDownload(completedBytes: 0, totalBytes: 0)
        let entries = [entry(download)]
        let summary = DownloadSummary()
        var changes = 0
        let observation = summary.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        summary.refresh(from: entries)
        #expect(changes == 1)

        // Bytes of a download without a known size change nothing the summary shows.
        download.completedBytes = 50
        entries[0].refresh()
        summary.refresh(from: entries)
        #expect(changes == 1)

        download.totalBytes = 200
        entries[0].refresh()
        summary.refresh(from: entries)
        #expect(changes == 2 && summary.progress == 0.25)
    }

    private func entry(_ download: StubDownload) -> DownloadEntry {
        DownloadEntry(item: download, personaID: Persona.defaultID)
    }
}

/// A download whose state and byte counts the test sets.
private final class StubDownload: EngineDownloadItem {
    let sourceURL = URL(string: "https://example.org/file.zip")!
    let pageURL: URL? = nil
    let webContents: (any EngineWebContents)? = nil
    let targetPath: URL? = nil
    var state: EngineDownloadState
    var completedBytes: Int64
    var totalBytes: Int64

    init(state: EngineDownloadState = .inProgress, completedBytes: Int64, totalBytes: Int64) {
        self.state = state
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    func pause() {}
    func resume() {}
    func cancel() {}
    func remove() {}
}
