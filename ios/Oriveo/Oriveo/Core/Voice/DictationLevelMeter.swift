import Accelerate
import AVFoundation
import Combine
import Foundation

/// Live input level while recording (for the waveform): computes RMS dBFS on the audio thread and hops
/// to the main thread to advance `levels`.
/// Maps -60...0 dB linearly to 0...1, keeps only the latest `capacity` values, and pushes once per
/// 1/maxUpdatesPerSecond seconds of audio (at most 15 updates per second).
/// A separate ObservableObject so level refreshes do not trigger DictationController's objectWillChange.
@MainActor
final class DictationLevelMeter: ObservableObject {

    static let capacity = 24
    static let maxUpdatesPerSecond = 15.0

    @Published private(set) var levels: [Float] = []

    /// Bumped each time a new tap is installed or the meter is cleared: late pushes from an older tap
    /// are dropped.
    private var generation = 0

    /// The tap added to the handler list when capture starts; each call starts a new generation and a
    /// fresh accumulation window.
    func makeTap() -> AudioBufferHandler {
        generation += 1
        let generation = self.generation
        let window = DictationLevelWindow(minDuration: 1 / Self.maxUpdatesPerSecond)
        return { [weak self] buffer, _ in
            guard let level = window.add(buffer) else { return }
            runOnMain { [weak self] in self?.push(level, generation: generation) }
        }
    }

    /// Leaving recording: clear and invalidate in-flight pushes.
    func reset() {
        generation += 1
        if !levels.isEmpty { levels = [] }
    }

    private func push(_ level: Float, generation: Int) {
        guard generation == self.generation else { return }
        var next = levels
        next.append(level)
        if next.count > Self.capacity { next.removeFirst(next.count - Self.capacity) }
        levels = next
    }

    /// RMS (linear amplitude) -> 0...1: -60 dBFS and below is 0, 0 dBFS is 1.
    nonisolated static func level(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let floorDB: Float = -60
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDB) / -floorDB))
    }

}

/// Accumulation window on the audio thread: sums squares and audio duration, and once minDuration
/// seconds are reached emits one level and resets.
/// Throttles by audio duration rather than wall clock: capture is real time so the two are equivalent,
/// and tests can feed deterministic data.
nonisolated final class DictationLevelWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let minDuration: Double
    private var sumOfSquares: Double = 0
    private var sampleCount = 0
    private var duration: Double = 0

    init(minDuration: Double) {
        self.minDuration = minDuration
    }

    /// Returns nil while not enough has accumulated; only Float32 buffers are accepted (the format of
    /// the input node tap).
    func add(_ buffer: AVAudioPCMBuffer) -> Float? {
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard frames > 0, rate > 0, let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.stride
        var squares: Double = 0
        for channel in 0..<channelCount {
            var sum: Float = 0
            vDSP_svesq(channels[channel], vDSP_Stride(stride), &sum, vDSP_Length(frames))
            squares += Double(sum)
        }
        let samples = frames * channelCount
        return lock.withLock { () -> Float? in
            sumOfSquares += squares
            sampleCount += samples
            duration += Double(frames) / rate
            guard duration >= minDuration, sampleCount > 0 else { return nil }
            let rms = Float((sumOfSquares / Double(sampleCount)).squareRoot())
            sumOfSquares = 0
            sampleCount = 0
            duration = 0
            return DictationLevelMeter.level(rms: rms)
        }
    }
}
