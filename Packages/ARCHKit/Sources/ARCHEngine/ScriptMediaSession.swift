// A media session for engine adapters whose pages describe their media through a script, so that both engines show it and answer the media keys alike.
import Foundation

/// Follows the media that a script reports for each document of one page. It shows the document that plays, or else the one that reported last, and sends actions to that document through `send`.
public final class ScriptMediaSession: EngineMediaSession {
    /// The Media Session API's names for the actions a document's script runs.
    public enum Action: String, Sendable {
        case play
        case pause
        case previousTrack = "previoustrack"
        case nextTrack = "nexttrack"
    }

    /// One document's report: `playing`, `duration` (0 while unknown), `live`, `position`, `rate`, `metadata` (`title`, `artist`, `album`, `artwork`) or null, `next`, and `previous`.
    private struct Media {
        var isPlaying: Bool
        var duration: TimeInterval
        var isLive: Bool
        var position: TimeInterval
        var rate: Double
        var metadata: EngineMediaMetadata?
        var canGoToNextTrack: Bool
        var canGoToPreviousTrack: Bool
        let reportedAt = Date()

        init?(report: Any?) {
            guard let report = report as? [String: Any] else { return nil }
            func number(_ key: String) -> Double? { (report[key] as? NSNumber)?.doubleValue }
            isPlaying = report["playing"] as? Bool ?? false
            duration = number("duration") ?? 0
            isLive = report["live"] as? Bool ?? false
            position = number("position") ?? 0
            rate = number("rate") ?? 1
            metadata = (report["metadata"] as? [String: Any]).map { values in
                EngineMediaMetadata(title: values["title"] as? String ?? "", artist: values["artist"] as? String ?? "", album: values["album"] as? String ?? "",
                                    artwork: (values["artwork"] as? String).flatMap { URL(string: $0) })
            }
            canGoToNextTrack = report["next"] as? Bool ?? false
            canGoToPreviousTrack = report["previous"] as? Bool ?? false
        }
    }

    public weak var delegate: (any EngineMediaSessionDelegate)?
    private let send: (_ document: String, _ action: Action) -> Void
    /// Documents with media, in the order of their last reports.
    private var documents: [(id: String, media: Media)] = []

    public init(send: @escaping (_ document: String, _ action: Action) -> Void) {
        self.send = send
    }

    /// Records a document's report. A report that is not a dictionary, as when the document's media left or the document went away, forgets the document.
    public func update(document id: String, report: Any?) {
        documents.removeAll { $0.id == id }
        if let media = Media(report: report) {
            documents.append((id, media))
        }
        delegate?.mediaSessionDidChange(self)
    }

    /// Forgets every document, as when the page's process quits.
    public func removeAllDocuments() {
        guard !documents.isEmpty else { return }
        documents.removeAll()
        delegate?.mediaSessionDidChange(self)
    }

    private var current: (id: String, media: Media)? {
        documents.last { $0.media.isPlaying } ?? documents.last
    }

    public var playbackState: EngineMediaPlaybackState {
        guard let current else { return .none }
        return current.media.isPlaying ? .playing : .paused
    }

    /// Scripts report the position only when playback changes, so the position moves on from the last report at the playback rate.
    public var position: EngineMediaPosition? {
        guard let media = current?.media else { return nil }
        var position = media.position
        if media.isPlaying { position += Date().timeIntervalSince(media.reportedAt) * media.rate }
        if !media.isLive, media.duration > 0 { position = min(position, media.duration) }
        return EngineMediaPosition(duration: media.isLive ? .infinity : media.duration, position: max(position, 0), playbackRate: media.rate)
    }

    public var metadata: EngineMediaMetadata? { current?.media.metadata }
    public var canGoToNextTrack: Bool { current?.media.canGoToNextTrack ?? false }
    public var canGoToPreviousTrack: Bool { current?.media.canGoToPreviousTrack ?? false }

    public func play() {
        if let current { send(current.id, .play) }
    }

    /// Pauses every document that plays, so the page falls silent.
    public func pause() {
        for document in documents where document.media.isPlaying {
            send(document.id, .pause)
        }
    }

    public func nextTrack() {
        if let current, current.media.canGoToNextTrack { send(current.id, .nextTrack) }
    }

    public func previousTrack() {
        if let current, current.media.canGoToPreviousTrack { send(current.id, .previousTrack) }
    }
}
