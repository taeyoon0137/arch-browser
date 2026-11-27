import ARCHEngine
import Foundation

/// Shares one native measurement between visible representations of the same page.
final class ChromiumAudioSpectrum: EngineAudioSpectrum {
    private var observers: [UUID: (Data) -> Void] = [:]
    private let setMeasuring: (Bool) -> Void
    private var isClosed = false

    init(setMeasuring: @escaping (Bool) -> Void) {
        self.setMeasuring = setMeasuring
    }

    func observe(_ receive: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        guard !isClosed else { return id }
        observers[id] = receive
        if observers.count == 1 { setMeasuring(true) }
        return id
    }

    func removeObserver(_ id: UUID) {
        guard observers.removeValue(forKey: id) != nil else { return }
        if observers.isEmpty && !isClosed { setMeasuring(false) }
    }

    func receive(_ bands: Data) {
        guard !isClosed else { return }
        let measure = bands.count == 24 ? bands : Data()
        // A callback may remove an observer, including itself.
        for id in Array(observers.keys) { observers[id]?(measure) }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if !observers.isEmpty { setMeasuring(false) }
        for id in Array(observers.keys) { observers.removeValue(forKey: id)?(Data()) }
    }
}
