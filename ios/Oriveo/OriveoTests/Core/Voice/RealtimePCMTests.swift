import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Test-only: mono Float32 at any sample rate → 24 kHz PCM16 LE (one shot, including flush); returns nil for empty input or a failed conversion.
/// Only tests and live fixtures need whole-clip conversion; production uplink streams frame by frame through RealtimeUplinkResampler.
extension RealtimePCM {
    static func pcm16LE24k(from samples: [Float], sampleRate: Double) -> Data? {
        guard !samples.isEmpty, let resampler = RealtimeUplinkResampler(sourceSampleRate: sampleRate) else { return nil }
        return resampler.convert(samples, endOfStream: true)
    }
}

/// Realtime uplink / downlink PCM utilities (Float32 at any rate → 24 kHz PCM16 LE; PCM16 → playback buffer).
@Suite("RealtimePCM")
struct RealtimePCMTests {

    private static func sine(count: Int, sampleRate: Double, hz: Double = 440, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    @Test func resample_to_24k_length() throws {
        // 1 s of mono audio at each input rate converts to about 24000 samples (48000 bytes); the SRC filter delay may shift this by a few dozen samples.
        for rate in [48_000.0, 44_100.0, 16_000.0, 24_000.0] {
            let data = try #require(RealtimePCM.pcm16LE24k(from: Self.sine(count: Int(rate), sampleRate: rate), sampleRate: rate))
            #expect(data.count % 2 == 0, "\(rate)")
            let samples = data.count / 2
            #expect(abs(samples - 24_000) <= 64, "\(rate) → \(samples)")
        }
        #expect(RealtimePCM.pcm16LE24k(from: [], sampleRate: 48_000) == nil)
    }

    @Test func resample_streaming_keeps_total_length() throws {
        // Feeding the same converter in 20 ms chunks gives the same total length as one conversion (converter state is kept across chunks).
        let rate = 48_000.0
        let source = Self.sine(count: 48_000, sampleRate: rate)
        let resampler = try #require(RealtimeUplinkResampler(sourceSampleRate: rate))
        var total = 0
        var start = 0
        while start < source.count {
            let end = min(source.count, start + 960)
            total += resampler.convert(Array(source[start..<end]))?.count ?? 0
            start = end
        }
        #expect(abs(total / 2 - 24_000) <= 64, "\(total / 2)")
    }

    @Test func pcm16_le_round_trip() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, -0.123]
        let data = RealtimePCM.encodePCM16LE(samples)
        #expect(data.count == samples.count * 2)
        // Little-endian: 0.5 → 16384 = 0x4000 → 00 40.
        #expect(Array(data[2...3]) == [0x00, 0x40])
        #expect(Array(data[6...7]) == [0xFF, 0x7F])

        let buffer = try #require(RealtimePCM.buffer(fromPCM16: data))
        #expect(buffer.format.sampleRate == RealtimePCM.sampleRate)
        #expect(buffer.format.channelCount == 1)
        #expect(Int(buffer.frameLength) == samples.count)
        let decoded = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            #expect(abs(decoded[index] - sample) <= 1.0 / 32_767, "\(index)")
        }
        #expect(RealtimePCM.encodePCM16LE(Array(UnsafeBufferPointer(start: decoded, count: samples.count))) == data)

        // A trailing odd byte is dropped; empty data produces no buffer.
        #expect(RealtimePCM.buffer(fromPCM16: data + Data([0x01]))?.frameLength == AVAudioFrameCount(samples.count))
        #expect(RealtimePCM.buffer(fromPCM16: Data()) == nil)
    }
}
