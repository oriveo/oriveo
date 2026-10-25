import AVFoundation
import Foundation

/// Consumer of microphone buffers (writing to disk, live recognition, ...); called on the audio thread, so do not block.
typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

/// Microphone capture. The same buffer is handed to every handler in turn, so recording to disk and recognition share a single tap.
nonisolated protocol AudioCapture: AnyObject {
    /// Current format of the input node; the value read before the session is active may differ from the one after recording starts, so the file writer should use the return value of start.
    var inputFormat: AVAudioFormat { get }
    /// Activates the recording session and installs the tap; returns the tap's actual format (the format of the buffers handed to handlers).
    @discardableResult
    func start(handlers: [AudioBufferHandler]) throws -> AVAudioFormat
    func stop()
}

/// Activation and deactivation of the recording session; tests inject a fake that records calls.
nonisolated protocol AudioSessionActivating: AnyObject {
    /// Sets the category and activates the session (for recording).
    func activateForRecording() throws
    func deactivate()
}

/// AVAudioSession implementation.
nonisolated final class SystemAudioSessionActivator: AudioSessionActivating {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activateForRecording() throws {
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Microphone input tap; tests inject a fake so the real engine is never touched.
nonisolated protocol AudioInputTap: AnyObject {
    var format: AVAudioFormat { get }
    /// Installs the tap and starts; on failure removes the tap itself before throwing. Returns the tap's actual format.
    func start(bufferSize: AVAudioFrameCount, handlers: [AudioBufferHandler]) throws -> AVAudioFormat
    func stop()
}

/// AVAudioEngine input node implementation.
nonisolated final class EngineInputTap: AudioInputTap {
    private let engine = AVAudioEngine()

    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func start(bufferSize: AVAudioFrameCount, handlers: [AudioBufferHandler]) throws -> AVAudioFormat {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, time in
            for handler in handlers { handler(buffer, time) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        return format
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Dictation capture: input tap + recording session. Session ownership goes through VoiceAudioSessionOwner: start claims a dictation lease,
/// and stop deactivates the session only if the lease is still current (it leaves the session alone when a voice conversation has taken it over in the meantime).
nonisolated final class EngineAudioCapture: AudioCapture {

    private let input: AudioInputTap
    private let activator: AudioSessionActivating
    private let owner: VoiceAudioSessionOwner
    private let bufferSize: AVAudioFrameCount
    private var lease: VoiceAudioSessionOwner.Lease?

    init(
        activator: AudioSessionActivating,
        owner: VoiceAudioSessionOwner = .shared,
        input: AudioInputTap = EngineInputTap(),
        bufferSize: AVAudioFrameCount = 4096
    ) {
        self.activator = activator
        self.owner = owner
        self.input = input
        self.bufferSize = bufferSize
    }

    convenience init(session: AVAudioSession = .sharedInstance(), bufferSize: AVAudioFrameCount = 4096) {
        self.init(activator: SystemAudioSessionActivator(session: session), bufferSize: bufferSize)
    }

    var inputFormat: AVAudioFormat { input.format }

    @discardableResult
    func start(handlers: [AudioBufferHandler]) throws -> AVAudioFormat {
        guard lease == nil else { return input.format }
        let lease = owner.claim(.dictation)
        // Set the category and activate first: the input format (sample rate, channels) only takes its recording value after activation.
        do {
            try activator.activateForRecording()
        } catch {
            owner.release(lease)
            throw error
        }
        do {
            let format = try input.start(bufferSize: bufferSize, handlers: handlers)
            self.lease = lease
            return format
        } catch {
            if owner.release(lease) { activator.deactivate() }
            throw error
        }
    }

    func stop() {
        guard let lease else { return }
        self.lease = nil
        input.stop()
        if owner.release(lease) { activator.deactivate() }
    }
}
