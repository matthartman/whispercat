import Foundation
import Combine

@MainActor
class AudioLevelMonitor: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0, count: 5)
    @Published var isSilent: Bool = false
    @Published var activeDeviceName: String?

    private var silenceStartTime: Date?
    private let silenceThreshold: Float = 0.005
    private let silenceDuration: TimeInterval = 3.0

    func processAudioChunk(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Split the chunk into 5 segments so each bar shows a different
        // slice of audio, giving a lively waveform-like appearance.
        let segmentSize = samples.count / 5
        var newLevels: [Float] = []
        for i in 0..<5 {
            let start = i * segmentSize
            let end = min(start + segmentSize, samples.count)
            let segment = samples[start..<end]
            let peak = segment.map { abs($0) }.max() ?? 0
            newLevels.append(Self.peakNormalize(peak))
        }
        levels = newLevels
        levels = newLevels

        // Silence detection (still use RMS for accuracy)
        let rms = Self.computeRMS(samples)
        if rms < silenceThreshold {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            }
            if let start = silenceStartTime, Date().timeIntervalSince(start) >= silenceDuration {
                isSilent = true
            }
        } else {
            silenceStartTime = nil
            isSilent = false
        }
    }

    func reset() {
        levels = Array(repeating: 0, count: 5)
        isSilent = false
        silenceStartTime = nil
        activeDeviceName = nil
    }

    static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    /// Map peak amplitude to 0.0–1.0. Peak is much higher than RMS for speech,
    /// giving lively, responsive bars. 0.05 peak = full scale (normal speech).
    private static func peakNormalize(_ peak: Float) -> Float {
        guard peak > 0.005 else { return 0 }  // silence → zero, bars drop down
        let scaled = min(peak / 0.05, 1.0)
        return max(0.35, scaled)  // speaking = at least 35%
    }
}
