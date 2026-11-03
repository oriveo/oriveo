import Foundation
import Testing
@testable import Oriveo

/// Runs the real Silero model on the simulator: synthetic speech segments are classed as voice, silent segments as non-voice; reset clears state.
@Suite struct SileroVadTests {
    private static let rate = 16_000

    /// Feeds 160-sample (10 ms) frames and collects the probability after each chunk's inference.
    private static func probabilities(_ vad: SileroVad, samples: [Float]) throws -> [Float] {
        var probs: [Float] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 160, samples.count)
            let before = vad.inferenceCount
            try samples[offset..<end].withUnsafeBufferPointer { try vad.feed($0) }
            if vad.inferenceCount != before { probs.append(vad.latestProb) }
            offset = end
        }
        return probs
    }

    /// Second-order resonator (formant filter).
    private static func resonate(_ x: ArraySlice<Float>, freq: Double, bandwidth: Double) -> [Float] {
        let r = exp(-Double.pi * bandwidth / Double(rate))
        let theta = 2 * Double.pi * freq / Double(rate)
        let a1 = -2 * r * cos(theta), a2 = r * r, gain = 1 - r
        var y1 = 0.0, y2 = 0.0
        return x.map { sample in
            let v = gain * Double(sample) - a1 * y1 - a2 * y2
            y2 = y1
            y1 = v
            return Float(v)
        }
    }

    /// Formant-synthesized voice-like sound: a pitch-varying sawtooth glottal source, three formants that change vowel every 180 ms, and a 4 Hz syllable envelope.
    private static func syntheticSpeech(seconds: Double) -> [Float] {
        let count = Int(seconds * Double(rate))
        var phase = 0.0
        let source: [Float] = (0..<count).map { n in
            let t = Double(n) / Double(rate)
            let f0 = 120 + 20 * sin(2 * .pi * 0.7 * t) + 10 * sin(2 * .pi * 3.1 * t)
            phase += f0 / Double(rate)
            return Float(phase.truncatingRemainder(dividingBy: 1) * 2 - 1)
        }
        let vowels: [(Double, Double, Double)] = [
            (730, 1090, 2440), (270, 2290, 3010), (300, 870, 2240), (530, 1840, 2480), (570, 840, 2410),
        ]
        let segment = Int(0.18 * Double(rate))
        var out = [Float](repeating: 0, count: count)
        var start = 0, index = 0
        while start < count {
            let end = min(start + segment, count)
            let slice = source[start..<end]
            let (f1, f2, f3) = vowels[(index * 3 + 1) % vowels.count]
            let r1 = resonate(slice, freq: f1, bandwidth: 80)
            let r2 = resonate(slice, freq: f2, bandwidth: 100)
            let r3 = resonate(slice, freq: f3, bandwidth: 120)
            for i in 0..<(end - start) {
                let t = Double(start + i) / Double(rate)
                let envelope = Float(0.55 + 0.45 * sin(2 * .pi * 4 * t))
                out[start + i] = (r1[i] + 0.6 * r2[i] + 0.3 * r3[i]) * envelope
            }
            start = end
            index += 1
        }
        let peak = out.map(abs).max() ?? 1
        return out.map { $0 / peak * 0.5 }
    }

    /// Fixed-seed low-level white noise (about -60 dBFS), simulating a quiet room's noise floor.
    private static func quietNoise(seconds: Double) -> [Float] {
        var seed: UInt64 = 0x5EED
        return (0..<Int(seconds * Double(rate))).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(seed >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * 0.001
        }
    }

    private static func ratio(_ probs: [Float], _ predicate: (Float) -> Bool) -> Double {
        Double(probs.filter(predicate).count) / Double(probs.count)
    }

    @Test func syntheticSpeechIsDetectedAsVoice() throws {
        let vad = try SileroVad()
        let probs = try Self.probabilities(vad, samples: Self.syntheticSpeech(seconds: 3))
        #expect(probs.count == 3 * Self.rate / SileroVad.chunkSize)
        let voiced = Self.ratio(probs, { $0 >= 0.5 })
        #expect(voiced >= 0.8, "voiced ratio \(voiced), probs \(probs)")
        #expect(vad.lastInferenceNanos > 0)
    }

    @Test func silenceAndQuietNoiseAreNotVoice() throws {
        let vad = try SileroVad()
        let silence = try Self.probabilities(vad, samples: [Float](repeating: 0, count: 2 * Self.rate))
        #expect(Self.ratio(silence, { $0 < 0.35 }) >= 0.95, "silence probs \(silence)")
        vad.reset()
        let noise = try Self.probabilities(vad, samples: Self.quietNoise(seconds: 2))
        #expect(Self.ratio(noise, { $0 < 0.35 }) >= 0.95, "noise probs \(noise)")
    }

    @Test func resetZeroesStateAndProbability() throws {
        let vad = try SileroVad()
        _ = try Self.probabilities(vad, samples: Self.syntheticSpeech(seconds: 1))
        #expect(vad.stateSnapshot().contains { $0 != 0 })
        #expect(vad.latestProb > 0)
        vad.reset()
        let state = vad.stateSnapshot()
        #expect(state.count == SileroVad.stateCount)
        #expect(state.allSatisfy { $0 == 0 })
        #expect(vad.latestProb == 0)
        // After reset, feeding the same silence from the start matches a fresh instance.
        let silence = [Float](repeating: 0, count: SileroVad.chunkSize)
        let fresh = try SileroVad()
        try silence.withUnsafeBufferPointer { try vad.feed($0) }
        try silence.withUnsafeBufferPointer { try fresh.feed($0) }
        #expect(vad.latestProb == fresh.latestProb)
        #expect(vad.stateSnapshot() == fresh.stateSnapshot())
    }
}
