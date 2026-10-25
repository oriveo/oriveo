import AVFoundation
import CryptoKit
import Foundation

nonisolated enum RecordingSlotStatus: String, Codable, Sendable {
    case recording
    case ready
    case interrupted
    case failed
}

/// Sidecar `<hex>.json` next to `<hex>.aac`.
nonisolated struct RecordingSlot: Codable, Sendable, Equatable {
    let slotKey: String
    let createdAt: Date
    var status: RecordingSlotStatus
    var durationSec: Double
    var envelope: [Double?]
    var engine: String?
}

nonisolated enum RecordingStoreError: Error, Equatable {
    case slotOccupied
    case slotNotFound
}

nonisolated enum RecordingDiscardOutcome: Sendable, Equatable {
    /// Moved to the discard area; the caller commits after the undo window or undoes.
    case undoable
    /// Deleted right away; there is nothing to undo.
    case deleted
}

/// Result of the launch sweep.
nonisolated struct RecordingSweepReport: Sendable, Equatable {
    var expired = 0
    var lost = 0
    /// Slot keys whose sidecar was still `recording` and were turned into `interrupted`.
    var recovered: [String] = []
}

/// One pending-transcription slot per conversation (UUID string) or home draft (`draft:home`).
/// Audio is on disk from the moment recording starts and is removed only on success or discard,
/// so a crash or a failed upload never loses the recording. Not thread-safe: call from one serial context.
nonisolated final class RecordingStore {

    static let homeDraftKey = "draft:home"

    static func slotKey(conversationID: UUID) -> String { conversationID.uuidString }

    /// Production root: `Application Support/Oriveo/Voice/pending/`.
    static func productionRoot() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Oriveo", directoryHint: .isDirectory)
            .appending(path: "Voice", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
    }

    let root: URL
    let discardRoot: URL
    private let now: () -> Date
    /// Receives how many slots were found lost.
    private let onLost: (Int) -> Void
    /// How many slots were cleared for being older than `pendingRetentionSec`.
    private let onExpired: (Int) -> Void
    private let fileManager: FileManager

    /// `fileManager` is a test seam for simulating a process kill between two file operations.
    init(root: URL, now: @escaping () -> Date = Date.init, onLost: @escaping (Int) -> Void = { _ in },
         onExpired: @escaping (Int) -> Void = { _ in },
         fileManager: FileManager = .default) throws {
        self.root = root
        self.discardRoot = root.appending(path: "discarded", directoryHint: .isDirectory)
        self.now = now
        self.onLost = onLost
        self.onExpired = onExpired
        self.fileManager = fileManager
        try Self.prepareDirectory(root)
        try Self.prepareDirectory(discardRoot)
    }

    convenience init(now: @escaping () -> Date = Date.init, onLost: @escaping (Int) -> Void = { _ in },
                     onExpired: @escaping (Int) -> Void = { _ in }) throws {
        try self.init(root: try Self.productionRoot(), now: now, onLost: onLost, onExpired: onExpired)
    }

    // MARK: - Paths

    static func fileStem(for slotKey: String) -> String {
        SHA256.hash(data: Data(slotKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func audioURL(for slotKey: String) -> URL {
        root.appending(path: "\(Self.fileStem(for: slotKey)).\(DictationRules.recordingFileExtension)")
    }

    func sidecarURL(for slotKey: String) -> URL {
        root.appending(path: "\(Self.fileStem(for: slotKey)).json")
    }

    // MARK: - Lifecycle

    /// Opens the slot and starts writing; the `.aac` and a `recording` sidecar both exist on return.
    func open(slotKey: String, inputFormat: AVAudioFormat, engine: String? = nil) throws -> RecordingWriter {
        let sidecar = sidecarURL(for: slotKey)
        guard !fileManager.fileExists(atPath: sidecar.path) else { throw RecordingStoreError.slotOccupied }
        let audio = audioURL(for: slotKey)
        // A leftover audio file without sidecar is an orphan from an earlier crash.
        try? fileManager.removeItem(at: audio)
        let writer = try RecordingWriter(url: audio, inputFormat: inputFormat)
        let slot = RecordingSlot(slotKey: slotKey, createdAt: now(), status: .recording,
                                 durationSec: 0, envelope: [], engine: engine)
        do {
            try writeSidecar(slot, to: sidecar)
        } catch {
            try? writer.close()
            try? fileManager.removeItem(at: audio)
            throw error
        }
        return writer
    }

    /// `open` run on `queue` (the owner's serial store queue) and awaited: the orphan removal has to
    /// precede creating the same-named file, so the whole open moves off the caller's thread together.
    func open(slotKey: String, inputFormat: AVAudioFormat, engine: String? = nil,
              on queue: DispatchQueue) async throws -> RecordingWriter {
        let request = UncheckedBox(value: (store: self, format: inputFormat))
        let outcome: UncheckedBox<Result<RecordingWriter, Error>> = await withCheckedContinuation { continuation in
            queue.async {
                let result = Result {
                    try request.value.store.open(slotKey: slotKey, inputFormat: request.value.format, engine: engine)
                }
                continuation.resume(returning: UncheckedBox(value: result))
            }
        }
        return try outcome.value.get()
    }

    /// Carries non-Sendable values across the queue hop; the owner serializes store access on that queue.
    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: T
    }

    /// Reads the slot. An expired slot is cleared as expired (never lost), checked before the audio;
    /// a sidecar whose audio vanished is reported lost and cleared.
    func slot(for slotKey: String) throws -> RecordingSlot? {
        let sidecar = sidecarURL(for: slotKey)
        guard fileManager.fileExists(atPath: sidecar.path) else { return nil }
        let stored = try? readSidecar(sidecar)
        if let stored, isExpired(stored) {
            try removePair(stem: Self.fileStem(for: slotKey), in: root)
            onExpired(1)
            return nil
        }
        guard fileManager.fileExists(atPath: audioURL(for: slotKey).path) else {
            try? fileManager.removeItem(at: sidecar)
            onLost(1)
            return nil
        }
        if let stored { return stored }
        return try readSidecar(sidecar)
    }

    /// Decodes the sidecar only: no expiry or lost handling, no file removed, no callback fired.
    /// Nil when the sidecar is missing or unreadable.
    func peekSlot(for slotKey: String) -> RecordingSlot? {
        try? readSidecar(sidecarURL(for: slotKey))
    }

    /// After `RecordingWriter.close()`: store duration and envelope, status `ready`.
    func markReady(slotKey: String, result: RecordingResult) throws {
        try update(slotKey) {
            $0.status = .ready
            $0.durationSec = result.durationSec
            $0.envelope = result.envelope
        }
    }

    /// Recording cut short (interruption, background, slot switch) after `RecordingWriter.close()`:
    /// store duration and envelope, status `interrupted`; the slot stays transcribable.
    func markInterrupted(slotKey: String, result: RecordingResult) throws {
        try update(slotKey) {
            $0.status = .interrupted
            $0.durationSec = result.durationSec
            $0.envelope = result.envelope
        }
    }

    func markFailed(slotKey: String) throws {
        try update(slotKey) { $0.status = .failed }
    }

    /// Transcript inserted: the slot is done.
    func complete(slotKey: String) throws {
        try removePair(stem: Self.fileStem(for: slotKey), in: root)
    }

    /// `DictationRules.showsDiscardUndo` goes to the discard area (undoable);
    /// otherwise deleted at once. `durationSec` overrides the sidecar value when given.
    /// The writer must already be closed.
    func discard(slotKey: String, durationSec: Double? = nil) throws -> RecordingDiscardOutcome {
        let stem = Self.fileStem(for: slotKey)
        let sidecar = sidecarURL(for: slotKey)
        guard fileManager.fileExists(atPath: sidecar.path) else { throw RecordingStoreError.slotNotFound }
        let duration = try durationSec ?? readSidecar(sidecar).durationSec
        guard DictationRules.showsDiscardUndo(durationSec: duration) else {
            try removePair(stem: stem, in: root)
            return .deleted
        }
        // A previous discard of the same key still waiting is superseded.
        try removePair(stem: stem, in: discardRoot)
        try move(stem: stem, from: root, to: discardRoot)
        return .undoable
    }

    /// Restores a discarded slot exactly as it was.
    func undoDiscard(slotKey: String) throws {
        let stem = Self.fileStem(for: slotKey)
        guard fileManager.fileExists(atPath: discardRoot.appending(path: "\(stem).json").path) else {
            throw RecordingStoreError.slotNotFound
        }
        guard !fileManager.fileExists(atPath: sidecarURL(for: slotKey).path) else {
            throw RecordingStoreError.slotOccupied
        }
        try move(stem: stem, from: discardRoot, to: root)
    }

    /// Called by the owner when the undo window ends.
    func commitDiscard(slotKey: String) throws {
        try removePair(stem: Self.fileStem(for: slotKey), in: discardRoot)
    }

    /// Launch sweep: drop the discard area, expire slots older than `pendingRetentionSec`,
    /// report lost slots, and turn `recording` sidecars into `interrupted` with duration and
    /// envelope read back from the audio file.
    @discardableResult
    func sweepOnLaunch() throws -> RecordingSweepReport {
        var report = RecordingSweepReport()
        for url in try contents(of: discardRoot) { try? fileManager.removeItem(at: url) }

        let entries = try contents(of: root).filter { $0 != discardRoot }
        let sidecars = entries.filter { $0.pathExtension == "json" }
        let stemsWithSidecar = Set(sidecars.map { $0.deletingPathExtension().lastPathComponent })
        // Audio without sidecar: crash between file creation and sidecar write.
        for url in entries where url.pathExtension == DictationRules.recordingFileExtension
            && !stemsWithSidecar.contains(url.deletingPathExtension().lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }

        for sidecar in sidecars {
            let stem = sidecar.deletingPathExtension().lastPathComponent
            guard var slot = try? readSidecar(sidecar) else {
                try removePair(stem: stem, in: root)
                continue
            }
            if isExpired(slot) {
                try removePair(stem: stem, in: root)
                report.expired += 1
                continue
            }
            let audio = audioURL(for: slot.slotKey)
            guard fileManager.fileExists(atPath: audio.path) else {
                try? fileManager.removeItem(at: sidecar)
                report.lost += 1
                continue
            }
            if slot.status == .recording {
                let recovered = Self.readBack(audio)
                slot.status = .interrupted
                slot.durationSec = recovered.durationSec
                slot.envelope = recovered.envelope
                try writeSidecar(slot, to: sidecar)
                report.recovered.append(slot.slotKey)
            }
        }
        if report.lost > 0 { onLost(report.lost) }
        if report.expired > 0 { onExpired(report.expired) }
        return report
    }

    // MARK: - Internals

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private func isExpired(_ slot: RecordingSlot) -> Bool {
        DictationRules.isPendingExpired(ageSec: now().timeIntervalSince(slot.createdAt))
    }

    private func contents(of directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func update(_ slotKey: String, _ change: (inout RecordingSlot) -> Void) throws {
        let sidecar = sidecarURL(for: slotKey)
        guard fileManager.fileExists(atPath: sidecar.path) else { throw RecordingStoreError.slotNotFound }
        var slot = try readSidecar(sidecar)
        change(&slot)
        try writeSidecar(slot, to: sidecar)
    }

    private func readSidecar(_ url: URL) throws -> RecordingSlot {
        try JSONDecoder().decode(RecordingSlot.self, from: Data(contentsOf: url))
    }

    private func writeSidecar(_ slot: RecordingSlot, to url: URL) throws {
        try JSONEncoder().encode(slot).write(to: url, options: .atomic)
    }

    private func pair(stem: String, in directory: URL) -> [URL] {
        [directory.appending(path: "\(stem).\(DictationRules.recordingFileExtension)"),
         directory.appending(path: "\(stem).json")]
    }

    /// Sidecar first, audio last: a kill in between leaves an orphan audio file (swept), never a sidecar
    /// without audio, which would read as lost.
    private func removePair(stem: String, in directory: URL) throws {
        for url in pair(stem: stem, in: directory).reversed() where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Whatever leaves `root` moves its sidecar first; whatever enters `root` moves its audio first.
    /// Either way `root` never holds a sidecar without its audio, so a kill mid-move is never counted lost.
    private func move(stem: String, from source: URL, to destination: URL) throws {
        var steps = Array(zip(pair(stem: stem, in: source), pair(stem: stem, in: destination)))
        if destination != root { steps.reverse() }
        for (from, to) in steps where fileManager.fileExists(atPath: from.path) {
            try fileManager.moveItem(at: from, to: to)
        }
    }

    /// Reads whatever ADTS frames are on disk; the envelope uses the same windows as `RecordingWriter`.
    /// ADTS keeps no priming info, so the decoded stream starts with `RecordingExporter.aacPrimingFrames`
    /// encoder frames; they are skipped to stay on the recording timeline that spans and envelopes use.
    /// An unreadable file yields zero duration and an empty envelope.
    static func readBack(_ url: URL) -> (durationSec: Double, envelope: [Double?]) {
        guard let file = try? AVAudioFile(forReading: url) else { return (0, []) }
        let format = file.processingFormat
        let windowFrames = max(1, Int((format.sampleRate * DictationRules.windowSec).rounded()))
        let chunk: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return (0, []) }
        var frames = 0
        var priming = RecordingExporter.aacPrimingFrames
        var envelope: [Double?] = []
        var window = DbfsWindowAccumulator(windowFrames: windowFrames)
        while true {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                break
            }
            let length = Int(buffer.frameLength)
            if length == 0 { break }
            let skipped = min(priming, length)
            priming -= skipped
            frames += length - skipped
            if let samples = buffer.floatChannelData?[0] {
                for index in skipped..<length {
                    if window.add(Double(samples[index])) { envelope.append(window.take()) }
                }
            }
        }
        if window.count > 0 { envelope.append(window.take()) }
        return (Double(frames) / format.sampleRate, envelope)
    }
}
