import Foundation

/// Live frequency levels for one page. All methods and callbacks run on the main thread.
/// Observation never changes playback.
public protocol EngineAudioSpectrum: AnyObject {
    /// Starts measuring for the first observer and returns its cancellation token. Reports contain 24
    /// bytes from 0 to 255, ordered from low to high frequency; empty data clears an unavailable measure.
    @discardableResult func observe(_ receive: @escaping (Data) -> Void) -> UUID
    /// Stops measuring when the last observer leaves. A removed observer receives no further reports.
    func removeObserver(_ id: UUID)
}
