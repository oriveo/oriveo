import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Cascade recording wrap-up: finishUtterance does not wait synchronously on the io queue from the main thread.
@Suite("Conversation capture core")
@MainActor
struct ConversationCaptureCoreTests {

    @Test("finishing returns at once while io is stalled; the result arrives on main with the last write", .timeLimit(.minutes(1)))
    func finish_does_not_wait_on_io_from_main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationCaptureCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let io = DispatchQueue(label: "ConversationCaptureCoreTests.io")
        let core = ConversationCaptureCore(directory: directory, io: io)
        core.configure(sampleRate: 48_000)

        // Suspend io: writer creation, writes and close are all queued.
        io.suspend()
        core.beginUtterance(fromFrame: 0)
        let consumed = core.consume(try Self.tone(seconds: 0.5))
        #expect(!consumed.frames.isEmpty)

        let probe = DeliveryProbe()
        core.finishUtterance { recording in probe.deliver(recording, onMain: Thread.isMainThread) }
        // The call has returned; the close on io has not run yet.
        #expect(!probe.delivered)

        io.resume()
        let (recording, onMain) = await probe.value()
        #expect(onMain)
        let result = try #require(recording)
        #expect(result.durationSec > 0)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
    }

    @Test("finishing while not recording delivers nil synchronously without touching io", .timeLimit(.minutes(1)))
    func finish_when_not_recording_delivers_nil_synchronously() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationCaptureCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let io = DispatchQueue(label: "ConversationCaptureCoreTests.io")
        let core = ConversationCaptureCore(directory: directory, io: io)
        core.configure(sampleRate: 48_000)
        _ = core.consume(try Self.tone(seconds: 0.1))

        // io is suspended: if the callback had to go through io or the next main-thread turn, it would not have fired by the time the call returns.
        io.suspend()
        defer { io.resume() }
        let probe = DeliveryProbe()
        core.finishUtterance { recording in probe.deliver(recording, onMain: Thread.isMainThread) }
        #expect(probe.delivered)
        let (recording, onMain) = await probe.value()
        #expect(recording == nil)
        #expect(onMain)
    }

    @Test("a live sink gets the preroll first, then the recorded frames, in order; nothing after finishing", .timeLimit(.minutes(1)))
    func live_sink_gets_preroll_then_recording_in_order() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationCaptureCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let io = DispatchQueue(label: "ConversationCaptureCoreTests.io")
        let core = ConversationCaptureCore(directory: directory, io: io)
        core.configure(sampleRate: 48_000)
        let samplesPerFrame = ConversationAudioMath.samplesPerFrame(sampleRate: 48_000)
        let source = try Self.tone(seconds: 0.3)
        let samples = try #require(source.floatChannelData?[0])

        // The first 0.1 s (5 frames, numbered 0…4) goes into the pre-roll ring; an utterance opened from frame 2 pre-records 3 frames.
        _ = core.consume(try Self.slice(source, from: 0, count: 5 * samplesPerFrame))
        let sink = LiveSinkProbe()
        core.beginUtterance(fromFrame: 2, live: { sink.receive($0) })
        _ = core.consume(try Self.slice(source, from: 5 * samplesPerFrame, count: 5 * samplesPerFrame))

        let probe = DeliveryProbe()
        core.finishUtterance { probe.deliver($0, onMain: Thread.isMainThread) }
        _ = core.consume(try Self.slice(source, from: 10 * samplesPerFrame, count: 5 * samplesPerFrame))
        _ = await probe.value()
        await withCheckedContinuation { continuation in io.async { continuation.resume() } }

        let chunks = sink.chunks
        #expect(chunks.map(\.count) == [3 * samplesPerFrame, 5 * samplesPerFrame])
        // Pre-recorded frames (starting at frame 2) followed by the later frames; the samples match the original waveform one by one.
        let received = chunks.flatMap { $0 }
        let expected = (2 * samplesPerFrame..<10 * samplesPerFrame).map { samples[$0] }
        #expect(received == expected)
    }

    @Test("real capture core and Silero: each frame carries the block's own probability; a same-rate rebuild keeps the model state", .timeLimit(.minutes(1)))
    func real_model_probability_is_synchronous_and_survives_rebuild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationCaptureCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 0.5 s of zero silence + hello-16k.wav, upsampled to 48 kHz.
        let silence = 24_000
        let samples = [Float](repeating: 0, count: silence) + (try Self.hello48k())
        let blockSize = 1024

        func run(rebuildAt: Int?) async throws -> [Double?] {
            let io = DispatchQueue(label: "ConversationCaptureCoreTests.io")
            let core = ConversationCaptureCore(directory: directory, io: io)
            core.configure(sampleRate: 48_000)
            // The first model load runs on io: wait for it to finish before feeding.
            await withCheckedContinuation { continuation in io.async { continuation.resume() } }
            var probs: [Double?] = []
            var start = 0
            var block = 0
            while start + blockSize <= samples.count {
                if block == rebuildAt { core.configure(sampleRate: 48_000, newSession: false) }
                let consumed = core.consume(try Self.buffer(Array(samples[start..<start + blockSize])))
                probs.append(consumed.speechProb)
                start += blockSize
                block += 1
            }
            return probs
        }

        let straight = try await run(rebuildAt: nil)
        let values = try straight.map { try #require($0) }
        let silentBlocks = silence / blockSize
        #expect(values.prefix(silentBlocks).allSatisfy { $0 < 0.35 })
        #expect(values.dropFirst(silentBlocks).contains { $0 >= 0.5 })

        // Mid-speech rebuild at the same sample rate (simulating a route change): the probability sequence stays unchanged block by block.
        let rebuilt = try await run(rebuildAt: silentBlocks + 20)
        #expect(rebuilt == straight)
    }

    /// Reads hello-16k.wav (16 kHz Int16 mono) into Float and upsamples it to 48 kHz via AVAudioConverter.
    private static func hello48k() throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("hello-16k.wav")
        let file = try AVAudioFile(forReading: url)
        let source = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
        let output = try #require(AVAudioPCMBuffer(
            pcmFormat: target, frameCapacity: AVAudioFrameCount(file.length) * 3 + 4096
        ))
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied {
                state.pointee = .endOfStream
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return source
        }
        #expect(status != .error)
        let pointer = try #require(output.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: pointer, count: Int(output.frameLength)))
    }

    /// 48 kHz mono buffer.
    private static func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let target = try #require(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /// Mono copy of the original buffer's [from, from + count) range.
    private static func slice(_ source: AVAudioPCMBuffer, from: Int, count: Int) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let target = try #require(buffer.floatChannelData?[0])
        let samples = try #require(source.floatChannelData?[0])
        for index in 0..<count { target[index] = samples[from + index] }
        return buffer
    }

    /// 48 kHz mono sine wave.
    private static func tone(seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let count = AVAudioFrameCount(48_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(count) {
            samples[index] = Float(0.3 * sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        return buffer
    }
}

@MainActor
private final class DeliveryProbe {
    private(set) var delivered = false
    private var recording: RecordingResult?
    private var onMain = false
    private var continuation: CheckedContinuation<Void, Never>?

    func deliver(_ recording: RecordingResult?, onMain: Bool) {
        delivered = true
        self.recording = recording
        self.onMain = onMain
        continuation?.resume()
        continuation = nil
    }

    func value() async -> (RecordingResult?, Bool) {
        if !delivered {
            await withCheckedContinuation { self.continuation = $0 }
        }
        return (recording, onMain)
    }
}

/// Records each block of samples the live sink receives (called on the io queue).
private nonisolated final class LiveSinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _chunks: [[Float]] = []

    var chunks: [[Float]] { lock.withLock { _chunks } }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        lock.withLock { _chunks.append(samples) }
    }
}
