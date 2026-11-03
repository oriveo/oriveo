import Foundation
import OnnxRuntimeBindings

/// Silero VAD (silero_vad_16k_op15.onnx, MIT) inference: takes a 16 kHz mono Float sample stream and runs inference once per 512 samples,
/// updating `latestProb` (the speech probability of that chunk).
///
/// - Model inputs: `input` [1, 64 + 512] (last 64 samples of the previous chunk as context, plus this chunk), `state` [2, 1, 128], `sr` int64 scalar;
///   outputs: `output` [1, 1], `stateN` [2, 1, 128]. Names are validated at load time against `session.inputNames()/outputNames()`.
/// - ORTEnv / ORTSession are lazily loaded singletons per process; each instance holds only its own context and state.
/// - Zero per-frame allocation: input and output tensors are created once and their buffers reused; `feed` only copies and calls `run` once.
/// - Instances are not thread-safe: an instance must be called from one thread only (for example the audio capture callback queue).
nonisolated final class SileroVad {
    enum LoadError: Error, Equatable {
        /// Model file not found in the package.
        case modelMissing
        /// Model input or output names do not match expectations (model version changed).
        case unexpectedSignature(inputs: [String], outputs: [String])
    }

    static let sampleRate: Int64 = 16_000
    static let chunkSize = 512
    static let contextSize = 64
    static let stateCount = 2 * 1 * 128

    private static let inputName = "input"
    private static let stateName = "state"
    private static let rateName = "sr"
    private static let outputName = "output"
    private static let stateOutName = "stateN"

    /// Speech probability of the most recent chunk; 0 before any inference or after reset.
    private(set) var latestProb: Float = 0
    /// Duration of the most recent inference in nanoseconds (for diagnostics); 0 if no inference has run.
    private(set) var lastInferenceNanos: UInt64 = 0
    /// Cumulative inference chunk count (for diagnostics).
    private(set) var inferenceCount: Int = 0

    private let session: ORTSession
    private let inputData: NSMutableData
    private let stateData: NSMutableData
    private let stateOutData: NSMutableData
    private let outputData: NSMutableData
    private let inputs: [String: ORTValue]
    private let outputs: [String: ORTValue]
    /// Samples accumulated so far for the current chunk (written after contextSize in inputData).
    private var pending = 0

    /// Load failure throws; the caller falls back to energy-based detection.
    init() throws {
        session = try Self.sharedSession()
        let windowCount = Self.contextSize + Self.chunkSize
        inputData = NSMutableData(length: windowCount * MemoryLayout<Float>.size)!
        stateData = NSMutableData(length: Self.stateCount * MemoryLayout<Float>.size)!
        stateOutData = NSMutableData(length: Self.stateCount * MemoryLayout<Float>.size)!
        outputData = NSMutableData(length: MemoryLayout<Float>.size)!
        var rate = Self.sampleRate
        let rateData = NSMutableData(bytes: &rate, length: MemoryLayout<Int64>.size)
        let stateShape: [NSNumber] = [2, 1, 128]
        inputs = [
            Self.inputName: try ORTValue(
                tensorData: inputData, elementType: .float, shape: [1, NSNumber(value: windowCount)]
            ),
            Self.stateName: try ORTValue(tensorData: stateData, elementType: .float, shape: stateShape),
            Self.rateName: try ORTValue(tensorData: rateData, elementType: .int64, shape: []),
        ]
        outputs = [
            Self.outputName: try ORTValue(tensorData: outputData, elementType: .float, shape: [1, 1]),
            Self.stateOutName: try ORTValue(tensorData: stateOutData, elementType: .float, shape: stateShape),
        ]
    }

    /// Accumulates samples, runs inference every 512 and updates `latestProb`; accepts any length per call.
    func feed(_ samples: UnsafeBufferPointer<Float>) throws {
        guard var src = samples.baseAddress else { return }
        var remaining = samples.count
        let window = inputData.mutableBytes.assumingMemoryBound(to: Float.self)
        while remaining > 0 {
            let take = min(remaining, Self.chunkSize - pending)
            (window + Self.contextSize + pending).update(from: src, count: take)
            pending += take
            src += take
            remaining -= take
            if pending == Self.chunkSize {
                try infer(window: window)
            }
        }
    }

    /// Clears the context, state and probability, discarding samples that do not fill a chunk.
    func reset() {
        memset(inputData.mutableBytes, 0, inputData.length)
        memset(stateData.mutableBytes, 0, stateData.length)
        memset(stateOutData.mutableBytes, 0, stateOutData.length)
        pending = 0
        latestProb = 0
    }

    /// Copy of the current RNN state (for diagnostics and tests; allocates).
    func stateSnapshot() -> [Float] {
        let ptr = stateData.mutableBytes.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: Self.stateCount))
    }

    private func infer(window: UnsafeMutablePointer<Float>) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        try session.run(withInputs: inputs, outputs: outputs, runOptions: nil)
        lastInferenceNanos = DispatchTime.now().uptimeNanoseconds &- start
        inferenceCount += 1
        latestProb = outputData.mutableBytes.assumingMemoryBound(to: Float.self).pointee
        memcpy(stateData.mutableBytes, stateOutData.mutableBytes, stateData.length)
        // The last 64 samples of this chunk become the context for the next chunk.
        window.update(from: window + Self.chunkSize, count: Self.contextSize)
        pending = 0
    }

    // MARK: - Process singleton

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedEnv: ORTEnv?
    nonisolated(unsafe) private static var shared: ORTSession?

    /// Lazily loads ORTEnv / ORTSession; failures are not cached, so the next call retries.
    private static func sharedSession() throws -> ORTSession {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        guard let url = Bundle.main.url(forResource: "silero_vad_16k_op15", withExtension: "onnx") else {
            throw LoadError.modelMissing
        }
        let env = try sharedEnv ?? ORTEnv(loggingLevel: .warning)
        sharedEnv = env
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        let inputNames = try session.inputNames()
        let outputNames = try session.outputNames()
        guard Set(inputNames) == [inputName, stateName, rateName],
              Set(outputNames) == [outputName, stateOutName] else {
            throw LoadError.unexpectedSignature(inputs: inputNames, outputs: outputNames)
        }
        shared = session
        return session
    }
}
