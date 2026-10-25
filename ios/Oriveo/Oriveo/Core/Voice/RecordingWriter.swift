import AVFoundation
import Foundation

nonisolated enum RecordingWriterError: Error, Equatable {
    /// The input is not Float32 non-interleaved PCM (which is what the AVAudioEngine tap delivers).
    case unsupportedInputFormat
    case converterUnavailable
    case conversionFailed
    case alreadyClosed
}

/// Result of a finished recording: duration is computed from the written 16 kHz frames, and the
/// envelope has one value per windowSec seconds.
nonisolated struct RecordingResult: Sendable, Equatable {
    let url: URL
    let durationSec: Double
    let envelope: [Double?]
}

/// Microphone buffers -> 16 kHz mono AAC-ADTS (`.aac`). Every ADTS frame carries its own header, so
/// frames already on disk stay readable after the process is killed.
/// Also produces a volume envelope from the converted PCM: one window per windowSec,
/// dBFS = 20*log10(RMS), and an all-zero window is nil.
/// Not thread-safe: append / close must be called from the same serial context (for example the thread
/// of the tap callback).
nonisolated final class RecordingWriter {

    let url: URL
    private(set) var envelope: [Double?] = []
    private(set) var framesWritten: AVAudioFramePosition = 0

    var durationSec: Double { Double(framesWritten) / outputFormat.sampleRate }

    private let inputFormat: AVAudioFormat
    private let monoFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var file: AVAudioFile?

    private var window: DbfsWindowAccumulator

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
              inputFormat.channelCount >= 1,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                       channels: 1, interleaved: false)
        else { throw RecordingWriterError.unsupportedInputFormat }
        let sampleRate = Double(DictationRules.recordingSampleRateHz)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(DictationRules.recordingChannels),
                                         interleaved: false),
              let converter = AVAudioConverter(from: mono, to: output)
        else { throw RecordingWriterError.converterUnavailable }

        self.url = url
        self.inputFormat = inputFormat
        self.monoFormat = mono
        self.outputFormat = output
        self.converter = converter
        self.window = DbfsWindowAccumulator(windowFrames: Int((sampleRate * DictationRules.windowSec).rounded()))
        // The file type (ADTS) is inferred from the `.aac` extension.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: DictationRules.recordingChannels,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Writes one microphone buffer; its format must equal the inputFormat given to init.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard file != nil else { throw RecordingWriterError.alreadyClosed }
        guard buffer.format.isEqual(inputFormat) else { throw RecordingWriterError.unsupportedInputFormat }
        guard buffer.frameLength > 0, let mono = downmix(buffer) else { return }
        var supplied = false
        try convert { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
    }

    /// Flushes what is left in the converter, appends the last partial window, and closes the file.
    /// Repeated calls return the same result.
    @discardableResult
    func close() throws -> RecordingResult {
        if file != nil {
            try convert { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if window.count > 0 { envelope.append(window.take()) }
            file?.close()
            file = nil
        }
        return RecordingResult(url: url, durationSec: durationSec, envelope: envelope)
    }

    // MARK: - Internals

    /// Averages multiple channels into a mono buffer at the same sample rate.
    private func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard let source = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let target = mono.floatChannelData?[0]
        else { return nil }
        let channels = Int(buffer.format.channelCount)
        let scale = Float(1) / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += source[channel][frame] }
            target[frame] = channels == 1 ? sum : sum * scale
        }
        mono.frameLength = buffer.frameLength
        return mono
    }

    private func convert(_ input: @escaping AVAudioConverterInputBlock) throws {
        let ratio = outputFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(4096 * max(ratio, 1)) + 1024
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw RecordingWriterError.conversionFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: input)
            if status == .error { throw conversionError ?? RecordingWriterError.conversionFailed }
            if output.frameLength > 0 { try write(output) }
            // A full output buffer means there is more to drain, so keep pulling; otherwise this
            // round's input is used up.
            if status != .haveData || output.frameLength < output.frameCapacity { return }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        try file?.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        guard let samples = buffer.floatChannelData?[0] else { return }
        for index in 0..<Int(buffer.frameLength) {
            if window.add(Double(samples[index])) { envelope.append(window.take()) }
        }
    }
}
