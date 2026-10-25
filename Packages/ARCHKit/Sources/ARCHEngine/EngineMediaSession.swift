import AppKit
import Foundation

public enum EngineMediaPlaybackState: String, Codable, Sendable {
    case none
    case playing
    case paused
}

public struct EngineMediaPosition: Hashable, Sendable {
    /// Infinite for a live stream and 0 while unknown.
    public var duration: TimeInterval
    public var position: TimeInterval
    public var playbackRate: Double
    public init(duration: TimeInterval, position: TimeInterval, playbackRate: Double) {
        self.duration = duration
        self.position = position
        self.playbackRate = playbackRate
    }
}

/// What the page says its media is, through the Media Session API's `navigator.mediaSession.metadata`. Empty strings stand for values the page leaves out.
public struct EngineMediaMetadata: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// The largest image the page lists.
    public var artwork: URL?
    public init(title: String, artist: String, album: String, artwork: URL?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }
}

public protocol EngineMediaSessionDelegate: AnyObject {
    /// The page's media started or stopped, moved, or changed its metadata or the tracks it offers. The session's properties hold the new values.
    func mediaSessionDidChange(_ session: any EngineMediaSession)
}

/// The media of one page, for Now Playing and the media keys. Picture-in-picture is not part of it: WebKit's video controls start the system's, and Chromium's needs a CEF source build (docs/plan.md, Phase VI).
public protocol EngineMediaSession: AnyObject {
    var delegate: (any EngineMediaSessionDelegate)? { get set }
    /// `.none` until media in the page plays sound, and again once that media leaves the page.
    var playbackState: EngineMediaPlaybackState { get }
    /// Where the media is now, read at each access.
    var position: EngineMediaPosition? { get }
    /// `nil` when the page sets no Media Session metadata.
    var metadata: EngineMediaMetadata? { get }
    /// Whether the page handles the Media Session API's next track action.
    var canGoToNextTrack: Bool { get }
    /// Whether the page handles the Media Session API's previous track action.
    var canGoToPreviousTrack: Bool { get }
    /// Runs the page's play handler, or plays the media when the page has none.
    func play()
    /// Runs the page's pause handler, or pauses the media when the page has none.
    func pause()
    func nextTrack()
    func previousTrack()
}
