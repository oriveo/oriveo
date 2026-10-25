import AVFoundation
import Foundation

/// Audio IO for realtime voice: the microphone goes up as PCM16 frames at the sample rate the transport declares, downlink is streamed 24 kHz PCM16 playback.
/// Shares the VPIO engine and player with the cascaded path (so AEC has its reference signal). All callbacks except onFrame run on the main actor.
protocol RealtimeAudioIO: AnyObject {
    /// Start the capture and playback pipeline. onFrame receives mono PCM16 LE at uplinkSampleRate (RealtimeTransport.uplinkSampleRate),
    /// resampled once from the device rate straight to that value; it is called on the audio thread (any thread) and never hops to main.
    /// System interruptions (didBecomeInactive / interruptionNotification) and capture failures call onInterruption; it does not recover on its own.
    func startRealtime(
        uplinkSampleRate: Double,
        onFrame: @escaping (Data) -> Void,
        onInterruption: @escaping () -> Void
    ) throws
    /// Queue a chunk of 24 kHz mono PCM16 LE downlink audio; itemId is used for the playedMs count.
    func enqueue(pcm16: Data, itemId: String)
    /// Milliseconds actually played since the first chunk of this item; 0 for an unknown item.
    func playedMs(itemId: String) -> Int
    /// Queued samples remain unplayed (only used to decide whether something is playing when interrupting; not polled).
    var isPlaying: Bool { get }
    /// Playback drained callback: called once (main actor) when the last chunk finished and no new chunk is pending; callbacks for old chunks are void after a stop.
    var onPlaybackDrained: (() -> Void)? { get set }
    /// Stop playback at once and clear the downlink queue (barge-in); the played milliseconds stay frozen.
    func stopRealtimePlayback()
    /// Stop playback, capture and the engine.
    func stopRealtime()
    /// Play an earcon (thinking timeout etc.) on the same engine as the downlink.
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon)
}

/// Realtime PCM helpers: downlink is always 24 kHz mono PCM16 little-endian; uplink uses the transport-declared value (24 kHz by default).
nonisolated enum RealtimePCM {
    static let sampleRate = 24_000.0

    /// 24 kHz mono non-interleaved Float32: the player format.
    static var floatFormat: AVAudioFormat { floatFormat(sampleRate: sampleRate)! }

    /// Mono non-interleaved Float32 at the given sample rate (uplink resample target); nil for an invalid rate.
    static func floatFormat(sampleRate: Double) -> AVAudioFormat? {
        guard sampleRate > 0 else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Float32 to PCM16 LE, clamped to [-1, 1].
    static func encodePCM16LE<C: Collection>(_ samples: C) -> Data where C.Element == Float {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            var offset = 0
            for sample in samples {
                let clamped = max(-1, min(1, sample))
                let value = UInt16(bitPattern: Int16((clamped * 32_767).rounded()))
                raw[offset] = UInt8(value & 0xFF)
                raw[offset + 1] = UInt8(value >> 8)
                offset += 2
            }
        }
        return data
    }

    /// PCM16 LE (24 kHz mono) to a Float32 playback buffer; a trailing odd byte is dropped, empty data returns nil.
    static func buffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let count = data.count / 2
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(count)),
              let target = buffer.floatChannelData?[0]
        else { return nil }
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = UInt16(raw[index * 2]) | (UInt16(raw[index * 2 + 1]) << 8)
                target[index] = Float(Int16(bitPattern: value)) / 32_767
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }
}

/// Streaming uplink resampler: mono Float32 at any rate to PCM16 LE at targetSampleRate (the transport-declared uplink rate), in one step;
/// converter state is kept across chunks. Not thread-safe; the caller serializes access.
nonisolated final class RealtimeUplinkResampler {
    private let sourceFormat: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: PCMFormatConverter
    private let flushing: AVAudioConverter?

    init?(sourceSampleRate: Double, targetSampleRate: Double = RealtimePCM.sampleRate) {
        guard let source = RealtimePCM.floatFormat(sampleRate: sourceSampleRate),
              let target = RealtimePCM.floatFormat(sampleRate: targetSampleRate),
              let converter = PCMFormatConverter(from: source, to: target)
        else { return nil }
        sourceFormat = source
        self.target = target
        self.converter = converter
        flushing = source.isEqual(target) ? nil : AVAudioConverter(from: source, to: target)
    }

    /// Feed a chunk of samples; with endOfStream = true the filter tail is flushed too (one-shot conversion only). Returns nil when nothing is produced.
    func convert(_ samples: [Float], endOfStream: Bool = false) -> Data? {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let pointer = input.floatChannelData?[0]
        else { return nil }
        for (index, sample) in samples.enumerated() { pointer[index] = sample }
        input.frameLength = AVAudioFrameCount(samples.count)
        let output: AVAudioPCMBuffer?
        if endOfStream, let flushing {
            output = Self.drain(flushing, input: input, target: target)
        } else {
            output = converter.convert(input)
        }
        guard let output, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return nil }
        return RealtimePCM.encodePCM16LE(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Feed everything at once and flush with endOfStream.
    private static func drain(_ converter: AVAudioConverter, input: AVAudioPCMBuffer, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else { return nil }
        return output
    }
}
