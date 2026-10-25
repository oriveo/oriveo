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
