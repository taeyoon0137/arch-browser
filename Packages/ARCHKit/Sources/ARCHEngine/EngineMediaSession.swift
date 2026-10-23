import AppKit
import Foundation

public enum EngineMediaPlaybackState: String, Codable, Sendable {
    case none
    case playing
    case paused
}

public struct EngineMediaPosition: Hashable, Sendable {
    public var duration: TimeInterval
    public var position: TimeInterval
    public var playbackRate: Double
    public init(duration: TimeInterval, position: TimeInterval, playbackRate: Double) {
        self.duration = duration
        self.position = position
        self.playbackRate = playbackRate
    }
}

public protocol EngineMediaSessionDelegate: AnyObject {
    func mediaSession(_ session: any EngineMediaSession, didChangePlaybackState state: EngineMediaPlaybackState)
    func mediaSession(_ session: any EngineMediaSession, didChangePosition position: EngineMediaPosition)
    func mediaSession(_ session: any EngineMediaSession, didChangePictureInPictureActive isActive: Bool)
    func mediaSession(_ session: any EngineMediaSession, didChangeAudible isAudible: Bool)
    func mediaSession(_ session: any EngineMediaSession, didChangeMuted isMuted: Bool)
}

/// Media control and picture-in-picture. PiP prefers Apple-provided support (WebKit built-in PiP, AVKit).
public protocol EngineMediaSession: AnyObject {
    var delegate: (any EngineMediaSessionDelegate)? { get set }
    var playbackState: EngineMediaPlaybackState { get }
    var position: EngineMediaPosition? { get }
    var isPictureInPictureActive: Bool { get }
    func play()
    func pause()
    func seek(to position: TimeInterval)
    func setMuted(_ muted: Bool)
    func requestPictureInPicture()
    func exitPictureInPicture()
}
