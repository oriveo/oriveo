import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Recording writes ADTS, recovers from an unclosed file, computes the volume envelope, passes through to m4a, and exports segments.
@Suite("Recording writer")
struct RecordingWriterTests {

    private static let inputRate = 48_000.0
    private static let toneSec = 1.5
    private static let silenceSec = 1.5
    private static let totalSec = toneSec + silenceSec
    /// Peak 0.1 = a -20 dBFS sine, whose theoretical RMS is -23.01 dBFS.
    private static let amplitude: Float = 0.1
    private static let tolerance = 0.05

    private static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "RecordingWriterTests-\(UUID().uuidString).\(ext)")
    }

    private static var inputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: false)!
    }

    /// 48 kHz stereo: a 440 Hz sine for the first toneSec seconds, then digital silence for silenceSec seconds, in 0.1 s chunks.
    private static func syntheticBuffers(totalSec: Double = totalSec) -> [AVAudioPCMBuffer] {
        let chunk = Int(inputRate / 10)
        let toneFrames = Int(toneSec * inputRate)
        let totalFrames = Int(totalSec * inputRate)
        var buffers: [AVAudioPCMBuffer] = []
        var position = 0
        while position < totalFrames {
            let frames = min(chunk, totalFrames - position)
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                let index = position + frame
                let value: Float = index < toneFrames
                    ? amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / inputRate))
                    : 0
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            buffers.append(buffer)
            position += frames
        }
        return buffers
    }

    private static func writeRecording() throws -> (RecordingResult, URL) {
        let url = tempURL("aac")
        let writer = try RecordingWriter(url: url, inputFormat: inputFormat)
        for buffer in syntheticBuffers() { try writer.append(buffer) }
        return (try writer.close(), url)
    }

    /// Reads the whole file back and returns (file format, duration in seconds).
    private static func readBack(_ url: URL) throws -> (AVAudioFormat, Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (file.fileFormat, Double(buffer.frameLength) / file.fileFormat.sampleRate)
    }

    /// Reads back the RMS (dBFS) of the file over [from, to) seconds; all zeros returns -infinity.
    private static func rmsDbfs(_ url: URL, from: Double, to: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let lower = Int(from * rate)
        let upper = min(Int(to * rate), Int(buffer.frameLength))
        var sum = 0.0
        for index in lower..<upper { sum += Double(samples[index]) * Double(samples[index]) }
        return 20 * log10((sum / Double(upper - lower)).squareRoot())
    }

    @Test("ADTS readback is 16 kHz mono with source duration")
    func writesReadableADTS() throws {
        let (result, url) = try Self.writeRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let (format, duration) = try Self.readBack(url)
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        // ADTS does not record the encoder priming frames, so the read-back length includes the leading aacPrimingSec.
        let content = duration - RecordingExporter.aacPrimingSec
        #expect(abs(content - Self.totalSec) <= Self.tolerance, "duration \(duration)")
        #expect(abs(result.durationSec - Self.totalSec) <= Self.tolerance, "written \(result.durationSec)")
    }

    @Test("bytes copied before close stay readable")
    func survivesKillBeforeClose() throws {
        let url = Self.tempURL("aac")
        let copy = Self.tempURL("aac")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: copy)
        }
        let writer = try RecordingWriter(url: url, inputFormat: Self.inputFormat)
        for buffer in Self.syntheticBuffers() { try writer.append(buffer) }
        // Simulates a killed process: skip close and copy the bytes currently on disk.
        try Data(contentsOf: url).write(to: copy)
        let (format, duration) = try Self.readBack(copy)
        #expect(format.sampleRate == 16_000)
        #expect(duration >= 1.0, "recovered \(duration)")
        #expect(duration <= Self.totalSec + Self.tolerance)
        try writer.close()
    }

    @Test("buffer in another format → append throws, not silently dropped")
    func mismatchedBufferThrows() throws {
        let url = Self.tempURL("aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, inputFormat: Self.inputFormat)
        let other = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        #expect(throws: RecordingWriterError.unsupportedInputFormat) { try writer.append(buffer) }
        try writer.close()
    }

    @Test("envelope: digital silence is nil, -20 dBFS sine is about -23 dBFS")
    func envelopeWindows() throws {
        let (result, url) = try Self.writeRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let window = DictationRules.windowSec
        #expect(window == 0.05)
        #expect(abs(Double(result.envelope.count) * window - Self.totalSec) <= window)
        // Only look at windows away from the start, end and the tone/silence switch, to avoid the resampling filter's transition.
        let toneWindows = Int(0.2 / window)..<Int((Self.toneSec - 0.2) / window)
        let silenceWindows = Int((Self.toneSec + 0.2) / window)..<Int((Self.totalSec - 0.2) / window)
        for index in toneWindows {
            let value = try #require(result.envelope[index], "tone window \(index) nil")
            #expect(abs(value - -23.0) <= 1.0, "tone window \(index) = \(value)")
        }
        for index in silenceWindows {
            #expect(result.envelope[index] == nil, "silence window \(index) = \(String(describing: result.envelope[index]))")
        }
        #expect(DictationRules.precheck(durationSec: result.durationSec, envelope: result.envelope) == .ok)
    }

    /// Per-window values of the previous algorithm (hand-written sum of squares / count / 20·log10(RMS), all zeros is nil) over the same sequence, written as constants.
    @Test("shared_window_accumulator_matches_previous_values")
    func sharedWindowAccumulatorMatchesPreviousValues() {
        let samples: [Float] = [0.5, -0.25, 0.125, 0.75, 0, 0, 0, 0, 0.5, 0.5, 0.25]
        let previous: [Double?] = [-6.523651096393581, nil, -7.269987279362624]
        var accumulator = DbfsWindowAccumulator(windowFrames: 4)
        var windows: [Double?] = []
        for sample in samples {
            if accumulator.add(Double(sample)) { windows.append(accumulator.take()) }
        }
        if accumulator.count > 0 { windows.append(accumulator.take()) }
        #expect(accumulator.count == 0)
        #expect(windows.count == previous.count)
        for (index, (value, expected)) in zip(windows, previous).enumerated() {
            if let expected {
                let actual = value ?? .nan
                #expect(abs(actual - expected) <= 1e-12, "window \(index) = \(actual)")
            } else {
                #expect(value == nil, "window \(index) = \(String(describing: value))")
            }
        }
    }

    /// Long recording: white noise in the noise ranges, digital silence elsewhere, and a 440 Hz sine at each [start, start + markerSec) given by markers. Generated and written incrementally without accumulating the whole PCM.
    private static let markerSec = 0.5
    private static func writeLongRecording(totalSec: Double, noise: [Range<Double>],
                                           markers: [Double]) throws -> RecordingResult {
        let noiseFrames = noise.map { Int($0.lowerBound * inputRate)..<Int($0.upperBound * inputRate) }
        let noiseAmplitude: Float = 0.05
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let url = tempURL("aac")
        let writer = try RecordingWriter(url: url, inputFormat: inputFormat)
        let chunk = Int(inputRate / 10)
        let totalFrames = Int(totalSec * inputRate)
        let ranges = markers.map { Int($0 * inputRate)..<Int(($0 + markerSec) * inputRate) }
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var position = 0
        while position < totalFrames {
            let frames = min(chunk, totalFrames - position)
            buffer.frameLength = AVAudioFrameCount(frames)
            let window = position..<(position + frames)
            for frame in 0..<frames {
                // Deterministic white noise in the noise ranges makes the bit rate fluctuate (like VBR in a real voice recording).
                var value: Float = 0
                if noiseFrames.contains(where: { $0.contains(position + frame) }) {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    value = noiseAmplitude * (Float(seed >> 40) / Float(1 << 24) * 2 - 1)
                }
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            for range in ranges where range.overlaps(window) {
                for index in max(range.lowerBound, position)..<min(range.upperBound, position + frames) {
                    let value = amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / inputRate))
                    buffer.floatChannelData![0][index - position] = value
                    buffer.floatChannelData![1][index - position] = value
                }
            }
            try writer.append(buffer)
            position += frames
        }
        return try writer.close()
    }

    /// Reads the file back and returns the time (seconds) of the first |x| > threshold after each stretch of silence.
    private static func onsets(_ url: URL, threshold: Float = 0.01, gapSec: Double = 1.0) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let gap = Int(gapSec * rate)
        var result: [Double] = []
        var last = -gap
        for index in 0..<Int(buffer.frameLength) where abs(samples[index]) > threshold {
            if index - last >= gap { result.append(Double(index) / rate) }
            last = index
        }
        return result
    }

    @Test("long ADTS: segment from 593 s starts and lasts as the span (within one AAC frame)")
    func exportsLongSegmentAligned() async throws {
        // The cut point is taken from a measured long recording; the offset from bit-rate-estimated seeking only reproduces beyond about 13 minutes.
        let spanStart = 593.075
        let spanEnd = 700.0
        // Noise both before and inside the segment: the segment start and end both fall after VBR stretches, so bit-rate-estimated seeking would drift.
        let noise = [0.0..<500.0, 600.0..<680.0]
        let markers = [593.5, 690.0, 699.0]
        let result = try Self.writeLongRecording(totalSec: 800, noise: noise, markers: markers)
        let segment = Self.tempURL("m4a")
        defer {
            for item in [result.url, segment] { try? FileManager.default.removeItem(at: item) }
        }
        try await RecordingExporter.exportM4A(from: result.url, to: segment,
                                              span: DictationSpan(start: spanStart, end: spanEnd))
        let frameSec = 1024.0 / Double(DictationRules.recordingSampleRateHz)
        let (_, duration) = try Self.readBack(segment)
        #expect(abs(duration - (spanEnd - spanStart)) <= frameSec, "segment duration \(duration)")
        let found = try Self.onsets(segment)
        let expected = [593.5, 600.0, 690.0, 699.0].map { $0 - spanStart }
        #expect(found.count == expected.count, "onsets \(found) vs \(expected)")
        for (got, want) in zip(found, expected) {
            #expect(abs(got - want) <= frameSec, "onset \(got) vs \(want)")
        }

        // Head segment [0, spanStart): its end must not be cut short by bit-rate estimation.
        let head = Self.tempURL("m4a")
        defer { try? FileManager.default.removeItem(at: head) }
        try await RecordingExporter.exportM4A(from: result.url, to: head,
                                              span: DictationSpan(start: 0, end: spanStart))
        let (_, headDuration) = try Self.readBack(head)
        #expect(abs(headDuration - spanStart) <= frameSec, "head duration \(headDuration)")
        let headFound = try Self.onsets(head)
        #expect(headFound.count == 1, "head onsets \(headFound)")
    }

    @Test("long ADTS: whole export keeps full duration and the tail marker (within one AAC frame)")
    func exportsLongWholeKeepsTail() async throws {
        // Noise first, silence after: for an unindexed ADTS file the duration estimated from the high early bit rate comes out short, and the whole-file export must not truncate the tail because of that.
        let totalSec = 600.0
        let tailMarker = 595.0
        let result = try Self.writeLongRecording(totalSec: totalSec, noise: [0.0..<400.0], markers: [tailMarker])
        let whole = Self.tempURL("m4a")
        defer {
            for item in [result.url, whole] { try? FileManager.default.removeItem(at: item) }
        }
        try await RecordingExporter.exportM4A(from: result.url, to: whole)
        let frameSec = 1024.0 / Double(DictationRules.recordingSampleRateHz)
        let (_, duration) = try Self.readBack(whole)
        #expect(abs(duration - result.durationSec) <= frameSec, "whole duration \(duration) vs \(result.durationSec)")
        let found = try Self.onsets(whole)
        #expect(found.count == 2, "whole onsets \(found)")
        if let last = found.last {
            #expect(abs(last - tailMarker) <= frameSec, "tail marker \(last) vs \(tailMarker)")
        }
    }

    @Test("passthrough m4a keeps duration and exports a [1.0, 2.0] segment")
    func exportsM4A() async throws {
        let (result, url) = try Self.writeRecording()
        let full = Self.tempURL("m4a")
        let segment = Self.tempURL("m4a")
        defer {
            for item in [url, full, segment] { try? FileManager.default.removeItem(at: item) }
        }
        let (_, sourceDuration) = try Self.readBack(url)

        try await RecordingExporter.exportM4A(from: result.url, to: full)
        let (fullFormat, fullDuration) = try Self.readBack(full)
        #expect(fullFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(fullFormat.sampleRate == 16_000)
        let sourceContent = sourceDuration - RecordingExporter.aacPrimingSec
        #expect(abs(fullDuration - sourceContent) <= Self.tolerance, "m4a \(fullDuration) vs \(sourceContent)")

        try await RecordingExporter.exportM4A(from: result.url, to: segment,
                                              span: DictationSpan(start: 1.0, end: 2.0))
        let (_, segmentDuration) = try Self.readBack(segment)
        #expect(abs(segmentDuration - 1.0) <= Self.tolerance, "segment \(segmentDuration)")
        // Segments align to the recording timeline: the sine ends at 1.5 s in the recording = 0.5 s in the segment; [0.2, 0.4] in the segment is voiced and [0.6, 0.9] is silent.
        let tone = try Self.rmsDbfs(segment, from: 0.2, to: 0.4)
        let quiet = try Self.rmsDbfs(segment, from: 0.6, to: 0.9)
        #expect(abs(tone - -23.0) <= 1.5, "segment tone \(tone)")
        #expect(quiet < -40, "segment quiet \(quiet)")
    }
}
