import AVFoundation
import Foundation
import os

/// Speech probability model behind the realtime speaker uplink gate (F2b model mode).
/// Fed continuously with 16 kHz mono Float samples from capture start (never reset at playback start);
/// returns the latest probability (0 before the first inferred block). Throws when inference fails.
/// Not thread safe: only the uplink's deliver thread feeds it.
nonisolated protocol RealtimeSpeechProb: AnyObject {
    func feed(_ samples: UnsafeBufferPointer<Float>) throws -> Double
}

/// Production model: Silero VAD (the same model the cascade conversation uses).
nonisolated final class SileroRealtimeSpeechProb: RealtimeSpeechProb {
    private let vad: SileroVad

    /// Throws when the model cannot be loaded; the session then gates on energy only.
    init() throws {
        vad = try SileroVad()
    }

    func feed(_ samples: UnsafeBufferPointer<Float>) throws -> Double {
        try vad.feed(samples)
        return Double(vad.latestProb)
    }
}

/// Carries a loaded model from the loading queue to the uplink (handed over once, then used on one thread).
nonisolated struct RealtimeSpeechProbBox: @unchecked Sendable {
    let model: any RealtimeSpeechProb
}

nonisolated enum RealtimeSpeechProbLoading {
    /// Loads a model in the background.
    typealias Loader = @Sendable () throws -> any RealtimeSpeechProb

    /// Upper bound on how long the session waits for the model before capture starts.
    static let limit: DispatchTimeInterval = .milliseconds(500)

    static let silero: Loader = { try SileroRealtimeSpeechProb() }

    /// Loads off the main thread; nil when loading throws or does not finish within `limit` (a late model is dropped).
    static func load(_ loader: @escaping Loader, limit: DispatchTimeInterval = limit) async -> RealtimeSpeechProbBox? {
        let claimed = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = {
            claimed.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let box = (try? loader()).map(RealtimeSpeechProbBox.init(model:))
                if claim() { continuation.resume(returning: box) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) {
                if claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Speech model plus its resampler, fed on the uplink's deliver thread only (outside the uplink lock).
/// Probabilities are taken at gate frame boundaries so every 20 ms gate frame carries its own prob.
nonisolated final class RealtimeSpeechFeed: @unchecked Sendable {
    private let model: any RealtimeSpeechProb
    private let resampler: RealtimeSpeechResampler
    /// The model's latest prob (0 before its first block).
    private(set) var latestProb: Double

    /// nil when no resampler can be built for the frame rate (treated as an inference failure).
    init?(model: any RealtimeSpeechProb, sourceSampleRate: Double, latestProb: Double = 0) {
        guard let resampler = RealtimeSpeechResampler(sourceSampleRate: sourceSampleRate) else { return nil }
        self.model = model
        self.resampler = resampler
        self.latestProb = latestProb
    }

    /// Same model (its state kept, never reset) behind a resampler for a new frame rate.
    func rebound(sourceSampleRate: Double) -> RealtimeSpeechFeed? {
        RealtimeSpeechFeed(model: model, sourceSampleRate: sourceSampleRate, latestProb: latestProb)
    }

    /// Feeds every byte of `frame` once, in order. firstBoundary: bytes until the current gate frame completes;
    /// frameBytes: bytes per gate frame. Returns the latest prob at each gate frame boundary inside `frame`;
    /// nil when resampling or inference failed.
    func probs(pcm16 frame: Data, firstBoundary: Int, frameBytes: Int) -> [Double]? {
        var probs: [Double] = []
        var offset = frame.startIndex
        var boundary = max(1, firstBoundary)
        do {
            while offset < frame.endIndex {
                let take = min(boundary, frame.endIndex - offset)
                try resampler.convert(pcm16: frame[offset..<(offset + take)]) { chunk in
                    latestProb = try model.feed(chunk)
                }
                offset += take
                if take == boundary {
                    probs.append(latestProb)
                    boundary = max(1, frameBytes)
                } else {
                    boundary -= take
                }
            }
        } catch {
            return nil
        }
        return probs
    }
}

/// Streaming resampler of mono PCM16 LE uplink frames to the model's 16 kHz Float input; converter state is kept
/// across frames. Not thread safe: serialized by the caller.
nonisolated final class RealtimeSpeechResampler {
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    /// nil = the frames already are 16 kHz and are fed as is.
    private let converter: AVAudioConverter?
    private var input: AVAudioPCMBuffer
    private var output: AVAudioPCMBuffer
    private var supplied = false
    private lazy var inputBlock: AVAudioConverterInputBlock = { [unowned self] _, status in
        if self.supplied {
            status.pointee = .noDataNow
            return nil
        }
        self.supplied = true
        status.pointee = .haveData
        return self.input
    }

    init?(sourceSampleRate: Double) {
        guard let source = RealtimePCM.floatFormat(sampleRate: sourceSampleRate),
              let target = RealtimePCM.floatFormat(sampleRate: Double(SileroVad.sampleRate))
        else { return nil }
        self.source = source
        self.target = target
        if source.isEqual(target) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
            self.converter = converter
        }
        let capacity: AVAudioFrameCount = 4096
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: capacity),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Self.outputCapacity(capacity, source, target))
        else { return nil }
        self.input = input
        self.output = output
    }

    struct ConversionFailed: Error {}

    /// Resamples one PCM16 LE frame and hands the (possibly empty) output to sink; sink must not keep the pointer.
    /// Throws when a buffer cannot be allocated or the converter fails (the caller treats it as an inference failure).
    func convert(pcm16 data: Data, into sink: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        let count = data.count / 2
        guard count > 0 else { return }
        if AVAudioFrameCount(count) > input.frameCapacity {
            guard let grown = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)),
                  let grownOut = AVAudioPCMBuffer(
                      pcmFormat: target, frameCapacity: Self.outputCapacity(AVAudioFrameCount(count), source, target)
                  )
            else { throw ConversionFailed() }
            input = grown
            output = grownOut
        }
        guard let inPtr = input.floatChannelData?[0] else { throw ConversionFailed() }
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                inPtr[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
            }
        }
        guard let converter else {
            try sink(UnsafeBufferPointer(start: inPtr, count: count))
            return
        }
        input.frameLength = AVAudioFrameCount(count)
        output.frameLength = 0
        supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
        guard status != .error else { throw conversionError ?? ConversionFailed() }
        // No output yet (converter latency) is not a failure.
        guard output.frameLength > 0 else { return }
        guard let outPtr = output.floatChannelData?[0] else { throw ConversionFailed() }
        try sink(UnsafeBufferPointer(start: outPtr, count: Int(output.frameLength)))
    }

    private static func outputCapacity(_ frames: AVAudioFrameCount, _ source: AVAudioFormat, _ target: AVAudioFormat) -> AVAudioFrameCount {
        AVAudioFrameCount(Double(frames) * target.sampleRate / source.sampleRate) + 1024
    }
}
