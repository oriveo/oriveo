import AVFoundation
import Foundation

nonisolated enum RecordingExporterError: Error, Equatable {
    case sessionUnavailable
}

/// Before upload, remuxes an ADTS recording to `.m4a` with Passthrough (no re-encoding); when a time
/// span is given, only that span is exported.
/// The span uses the recording timeline (written PCM frames / envelope windows). ADTS does not record
/// the encoder priming frames, so the file timeline is aacPrimingSec longer than the recording timeline;
/// the offset is added here before trimming, and the exported m4a's edit list drops the priming frames
/// so its duration matches the recording.
nonisolated enum RecordingExporter {

    /// The Apple AAC-LC encoder always emits 2112 priming frames (Apple TN2258).
    static let aacPrimingFrames = 2112
    static var aacPrimingSec: Double {
        Double(aacPrimingFrames) / Double(DictationRules.recordingSampleRateHz)
    }

    /// Samples per AAC frame.
    static let samplesPerFrame = 1024
    /// Extra frames kept before the segment start: the decoder overlap-adds with the previous frame, so
    /// without it the first half frame is lost; the extra frames are trimmed off by timeRange.
    static let prerollFrames = 2

    /// Exports the whole recording when span is nil; endpoints are in seconds. An existing destination
    /// file is removed first.
    /// First cuts the frames covering span (nil means all complete frames) into a temporary .aac by ADTS
    /// frame headers, then exports: ADTS has no index, so exporting directly by timeRange or asset
    /// duration makes AVFoundation seek by estimated bitrate, which can put the segment start off by tens
    /// of seconds for a VBR recording and truncate the tail.
    static func exportM4A(from source: URL, to destination: URL, span: DictationSpan? = nil) async throws {
        let data = try Data(contentsOf: source)
        let frames = adtsFrames(data)
        guard !frames.isEmpty else {
            if let span {
                try await passthrough(from: source, to: destination,
                                      start: span.start + aacPrimingSec, end: span.end + aacPrimingSec)
            } else {
                try await passthrough(from: source, to: destination, start: aacPrimingSec, end: nil)
            }
            return
        }
        let rate = Double(DictationRules.recordingSampleRateHz)
        // Recording time plus priming frames gives file sample positions; take the frames covering the
        // range on frame boundaries (start rounds down, end rounds up); the whole recording runs to the
        // last complete frame.
        let startSample = max(0, Int(((span?.start ?? 0) * rate).rounded())) + aacPrimingFrames
        let endFrame: Int
        if let span {
            let endSample = max(startSample, Int((span.end * rate).rounded()) + aacPrimingFrames)
            endFrame = min((endSample + samplesPerFrame - 1) / samplesPerFrame, frames.count)
        } else {
            endFrame = frames.count
        }
        let firstFrame = min(startSample / samplesPerFrame, frames.count - 1)
        let keptFirst = max(0, firstFrame - prerollFrames)
        var slice = Data()
        for range in frames[keptFirst..<max(endFrame, firstFrame + 1)] { slice.append(data[range]) }
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "RecordingExporter-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: temp) }
        try slice.write(to: temp)
        // The segment end is already fixed by frame selection (less than one extra frame), so no end is
        // given to timeRange: the temporary file has no index either, and an end derived from the
        // estimated bitrate would cut the tail.
        let offset = Double(startSample - keptFirst * samplesPerFrame) / rate
        try await passthrough(from: temp, to: destination, start: offset, end: nil, clampEnd: false)
    }

    /// Passthrough export of file timeline [start, end); when end is nil, clampEnd runs to the asset
    /// duration, otherwise no end is set (exports to the end of the file).
    private static func passthrough(from source: URL, to destination: URL, start: Double, end: Double?,
                                    clampEnd: Bool = true) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingExporterError.sessionUnavailable
        }
        let timescale = CMTimeScale(DictationRules.recordingSampleRateHz)
        let startTime = CMTime(seconds: start, preferredTimescale: timescale)
        if end == nil && !clampEnd {
            session.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)
        } else {
            let fileDuration = try await asset.load(.duration).seconds
            let end = min(end ?? fileDuration, fileDuration)
            session.timeRange = CMTimeRange(start: startTime,
                                            end: CMTime(seconds: max(end, start), preferredTimescale: timescale))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try await session.export(to: destination, as: .m4a)
    }

    /// Splits frame by frame using the ADTS header (syncword + 13-bit frame_length) and returns each
    /// frame's byte range; stops at a truncated frame (the tail left when the process was killed).
    static func adtsFrames(_ data: Data) -> [Range<Int>] {
        var frames: [Range<Int>] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 7 <= bytes.count {
                guard bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 else { break }
                let length = (Int(bytes[offset + 3] & 0x03) << 11)
                    | (Int(bytes[offset + 4]) << 3)
                    | (Int(bytes[offset + 5]) >> 5)
                guard length >= 7, offset + length <= bytes.count else { break }
                frames.append((data.startIndex + offset)..<(data.startIndex + offset + length))
                offset += length
            }
        }
        return frames
    }
}
