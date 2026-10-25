import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Pending-transcription slot store: a slot is persisted as soon as it opens, deleted only on success or discard, expires after 7 days, recovers from crashes, counts lost recordings, and stays out of backups.
@Suite("Recording store")
struct RecordingStoreTests {

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class LostCounter {
        var calls: [Int] = []
        var total: Int { calls.reduce(0, +) }
    }

    /// Simulates a killed process: after `allowed` removals / moves go through, the next file operation throws and nothing runs afterwards.
    private final class KillingFileManager: FileManager, @unchecked Sendable {
        struct Killed: Error {}
        var allowed: Int?

        private func step() throws {
            guard let remaining = allowed else { return }
            guard remaining > 0 else { throw Killed() }
            allowed = remaining - 1
        }

        override func removeItem(at url: URL) throws {
            try step()
            try super.removeItem(at: url)
        }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            try step()
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    enum LeavingOperation: String, CaseIterable, Sendable, CustomStringConvertible {
        case complete
        case discardDeleted
        case discardUndoable
        case undoDiscard
        var description: String { rawValue }
    }

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let inputRate = 48_000.0

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "RecordingStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
    }

    private static var inputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
    }

    /// 48 kHz mono 440 Hz sine (peak 0.1), written in 0.1 s chunks.
    private static func feed(_ writer: RecordingWriter, seconds: Double) throws {
        let chunk = Int(inputRate / 10)
        let total = Int(seconds * inputRate)
        var position = 0
        while position < total {
            let frames = min(chunk, total - position)
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                buffer.floatChannelData![0][frame] =
                    0.1 * Float(sin(2 * Double.pi * 440 * Double(position + frame) / inputRate))
            }
            try writer.append(buffer)
            position += frames
        }
    }

    private static func makeStore(root: URL, clock: Clock, lost: LostCounter) throws -> RecordingStore {
        try RecordingStore(root: root, now: { clock.now }, onLost: { lost.calls.append($0) })
    }

    /// Opens a slot, writes 0.3 s, closes the file, and marks the sidecar ready with the given duration.
    private static func readySlot(_ store: RecordingStore, key: String, durationSec: Double) throws {
        let writer = try store.open(slotKey: key, inputFormat: inputFormat, engine: "system")
        try feed(writer, seconds: 0.3)
        let result = try writer.close()
        try store.markReady(slotKey: key, result: RecordingResult(url: result.url, durationSec: durationSec,
                                                                  envelope: result.envelope))
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("open creates sidecar and .aac; success deletes both; reopening the same key is occupied")
    func openCompleteOccupied() throws {
        let root = Self.tempRoot()
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let key = RecordingStore.slotKey(conversationID: UUID())

        let writer = try store.open(slotKey: key, inputFormat: Self.inputFormat, engine: "system")
        #expect(Self.exists(store.sidecarURL(for: key)))
        #expect(Self.exists(store.audioURL(for: key)))
        #expect(store.audioURL(for: key).lastPathComponent == "\(RecordingStore.fileStem(for: key)).aac")
        #expect(RecordingStore.fileStem(for: key).count == 64)
        let slot = try #require(try store.slot(for: key))
        #expect(slot.slotKey == key)
        #expect(slot.status == .recording)
        #expect(slot.createdAt == Self.start)
        #expect(slot.engine == "system")

        #expect(throws: RecordingStoreError.slotOccupied) {
            _ = try store.open(slotKey: key, inputFormat: Self.inputFormat)
        }

        // The home draft is a separate slot and is unaffected by a conversation slot being occupied.
        let draft = try store.open(slotKey: RecordingStore.homeDraftKey, inputFormat: Self.inputFormat)
        try draft.close()

        try Self.feed(writer, seconds: 0.5)
        let result = try writer.close()
        try store.markReady(slotKey: key, result: result)
        let ready = try #require(try store.slot(for: key))
        #expect(ready.status == .ready)
        #expect(ready.durationSec == result.durationSec)
        #expect(ready.envelope == result.envelope)

        try store.complete(slotKey: key)
        #expect(!Self.exists(store.sidecarURL(for: key)))
        #expect(!Self.exists(store.audioURL(for: key)))
        #expect(try store.slot(for: key) == nil)
        #expect(lost.total == 0)
    }

    @Test("discard over 5 s is undoable and undo restores it exactly; exactly 5 s deletes with no undo")
    func discardThreshold() throws {
        let root = Self.tempRoot()
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let longKey = RecordingStore.slotKey(conversationID: UUID())
        let shortKey = RecordingStore.homeDraftKey

        try Self.readySlot(store, key: longKey, durationSec: 5.5)
        let sidecarBefore = try Data(contentsOf: store.sidecarURL(for: longKey))
        let audioBefore = try Data(contentsOf: store.audioURL(for: longKey))

        #expect(try store.discard(slotKey: longKey) == .undoable)
        #expect(!Self.exists(store.sidecarURL(for: longKey)))
        #expect(!Self.exists(store.audioURL(for: longKey)))
        #expect(try store.slot(for: longKey) == nil)

        try store.undoDiscard(slotKey: longKey)
        #expect(try Data(contentsOf: store.sidecarURL(for: longKey)) == sidecarBefore)
        #expect(try Data(contentsOf: store.audioURL(for: longKey)) == audioBefore)
        #expect(try store.slot(for: longKey)?.status == .ready)

        // Discard again and have the caller confirm: the discard area is emptied and undo is no longer possible.
        #expect(try store.discard(slotKey: longKey) == .undoable)
        try store.commitDiscard(slotKey: longKey)
        #expect(throws: RecordingStoreError.slotNotFound) { try store.undoDiscard(slotKey: longKey) }
        #expect(try store.slot(for: longKey) == nil)

        try Self.readySlot(store, key: shortKey, durationSec: DictationRules.discardUndoAboveSec)
        #expect(try store.discard(slotKey: shortKey) == .deleted)
        #expect(!Self.exists(store.sidecarURL(for: shortKey)))
        #expect(!Self.exists(store.audioURL(for: shortKey)))
        #expect(throws: RecordingStoreError.slotNotFound) { try store.undoDiscard(slotKey: shortKey) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: store.discardRoot.path).isEmpty)
        #expect(try store.sweepOnLaunch() == RecordingSweepReport())
        #expect(lost.total == 0)
    }

    @Test("launch sweep: exactly 7 days kept, older deleted and counted expired not lost")
    func expiry() throws {
        let root = Self.tempRoot()
        let clock = Clock(Self.start)
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: clock, lost: lost)
        let key = RecordingStore.slotKey(conversationID: UUID())
        try Self.readySlot(store, key: key, durationSec: 1)

        clock.now = Self.start.addingTimeInterval(DictationRules.pendingRetentionSec)
        #expect(try store.sweepOnLaunch() == RecordingSweepReport())
        #expect(try store.slot(for: key)?.status == .ready)

        clock.now = Self.start.addingTimeInterval(DictationRules.pendingRetentionSec + 1)
        let report = try store.sweepOnLaunch()
        #expect(report.expired == 1)
        #expect(report.lost == 0)
        #expect(!Self.exists(store.sidecarURL(for: key)))
        #expect(!Self.exists(store.audioURL(for: key)))
        #expect(lost.calls.isEmpty)
    }

    @Test("expiry goes through DictationRules.isPendingExpired: exactly 7 days kept, 7 days + 1 s expired")
    func test_recordingStoreExpiry_usesDictationRules() throws {
        let root = Self.tempRoot()
        let clock = Clock(Self.start)
        var expired: [Int] = []
        let store = try RecordingStore(root: root, now: { clock.now }, onExpired: { expired.append($0) })
        let key = RecordingStore.slotKey(conversationID: UUID())
        try Self.readySlot(store, key: key, durationSec: 1)

        let keptAge = DictationRules.pendingRetentionSec
        #expect(!DictationRules.isPendingExpired(ageSec: keptAge))
        clock.now = Self.start.addingTimeInterval(keptAge)
        #expect(try store.slot(for: key)?.status == .ready)
        #expect(expired.isEmpty)

        let expiredAge = DictationRules.pendingRetentionSec + 1
        #expect(DictationRules.isPendingExpired(ageSec: expiredAge))
        clock.now = Self.start.addingTimeInterval(expiredAge)
        #expect(try store.slot(for: key) == nil)
        #expect(expired == [1])
        #expect(!Self.exists(store.sidecarURL(for: key)))
        #expect(!Self.exists(store.audioURL(for: key)))
    }

    /// Records which thread each removal happens on and which file is removed.
    private final class ThreadRecordingFileManager: FileManager, @unchecked Sendable {
        private let lock = NSLock()
        private var _removals: [(path: String, onMain: Bool)] = []
        var removals: [(path: String, onMain: Bool)] { lock.withLock { _removals } }

        override func removeItem(at url: URL) throws {
            let onMain = Thread.isMainThread
            lock.withLock { _removals.append((url.standardizedFileURL.path, onMain)) }
            try super.removeItem(at: url)
        }
    }

    @Test("open removes an orphan .aac off the main thread, then the new recording takes its place")
    func test_openRemovesOrphanOffMainThread() async throws {
        #expect(Thread.isMainThread)
        let root = Self.tempRoot()
        let files = ThreadRecordingFileManager()
        let store = try RecordingStore(root: root, fileManager: files)
        let key = RecordingStore.slotKey(conversationID: UUID())
        let audio = store.audioURL(for: key)
        let orphan = Data("orphan".utf8)
        try orphan.write(to: audio)

        let queue = DispatchQueue(label: "RecordingStoreTests.open")
        let writer = try await store.open(slotKey: key, inputFormat: Self.inputFormat, engine: "system", on: queue)
        try Self.feed(writer, seconds: 0.3)
        _ = try writer.close()

        let removals = files.removals.filter { $0.path == audio.standardizedFileURL.path }
        #expect(removals.count == 1)
        #expect(removals.allSatisfy { !$0.onMain })
        #expect(try Data(contentsOf: audio) != orphan)
        #expect(try store.slot(for: key)?.status == .recording)
    }

    @Test("launch sweep drops discard-area leftovers without counting them lost")
    func sweepDropsDiscardArea() throws {
        let root = Self.tempRoot()
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let key = RecordingStore.slotKey(conversationID: UUID())
        try Self.readySlot(store, key: key, durationSec: 8)
        #expect(try store.discard(slotKey: key) == .undoable)

        let relaunched = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        #expect(try relaunched.sweepOnLaunch() == RecordingSweepReport())
        #expect(try FileManager.default.contentsOfDirectory(atPath: relaunched.discardRoot.path).isEmpty)
        #expect(throws: RecordingStoreError.slotNotFound) { try relaunched.undoDiscard(slotKey: key) }
        #expect(lost.calls.isEmpty)
    }

    @Test("audio deleted externally: lost reported once and sidecar cleared")
    func lostAudio() throws {
        let root = Self.tempRoot()
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let key = RecordingStore.slotKey(conversationID: UUID())
        try Self.readySlot(store, key: key, durationSec: 2)
        try FileManager.default.removeItem(at: store.audioURL(for: key))

        let relaunched = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let report = try relaunched.sweepOnLaunch()
        #expect(report.lost == 1)
        #expect(report.expired == 0)
        #expect(lost.calls == [1])
        #expect(!Self.exists(relaunched.sidecarURL(for: key)))
        #expect(try relaunched.sweepOnLaunch() == RecordingSweepReport())
        #expect(lost.calls == [1])

        // A loss detected while reading at runtime is likewise reported only once.
        try Self.readySlot(relaunched, key: RecordingStore.homeDraftKey, durationSec: 2)
        try FileManager.default.removeItem(at: relaunched.audioURL(for: RecordingStore.homeDraftKey))
        #expect(try relaunched.slot(for: RecordingStore.homeDraftKey) == nil)
        #expect(try relaunched.slot(for: RecordingStore.homeDraftKey) == nil)
        #expect(lost.calls == [1, 1])
        #expect(!Self.exists(relaunched.sidecarURL(for: RecordingStore.homeDraftKey)))
    }

    @Test("peekSlot reads the sidecar only: expired or audio-lost slots keep their files and fire no callback")
    func peekSlotHasNoSideEffects() throws {
        let root = Self.tempRoot()
        let clock = Clock(Self.start)
        var callbacks: [String] = []
        let store = try RecordingStore(
            root: root, now: { clock.now },
            onLost: { callbacks.append("lost:\($0)") },
            onExpired: { callbacks.append("expired:\($0)") }
        )
        let lostKey = RecordingStore.slotKey(conversationID: UUID())
        let expiredKey = RecordingStore.slotKey(conversationID: UUID())
        try Self.readySlot(store, key: lostKey, durationSec: 1.5)
        try Self.readySlot(store, key: expiredKey, durationSec: 2.5)
        try FileManager.default.removeItem(at: store.audioURL(for: lostKey))

        let lost = try #require(store.peekSlot(for: lostKey))
        #expect(lost.status == .ready)
        #expect(lost.durationSec == 1.5)
        #expect(lost.engine == "system")
        #expect(Self.exists(store.sidecarURL(for: lostKey)))
        #expect(callbacks.isEmpty)
        // Contrast: slot(for:) handles the loss and fires the callback
        #expect(try store.slot(for: lostKey) == nil)
        #expect(callbacks == ["lost:1"])
        callbacks.removeAll()

        clock.now = Self.start.addingTimeInterval(DictationRules.pendingRetentionSec + 1)
        let expired = try #require(store.peekSlot(for: expiredKey))
        #expect(expired.durationSec == 2.5)
        #expect(Self.exists(store.sidecarURL(for: expiredKey)))
        #expect(Self.exists(store.audioURL(for: expiredKey)))
        #expect(store.peekSlot(for: RecordingStore.slotKey(conversationID: UUID())) == nil)
        #expect(callbacks.isEmpty)
        // Contrast: slot(for:) handles the expiry and fires the callback
        #expect(try store.slot(for: expiredKey) == nil)
        #expect(callbacks == ["expired:1"])
    }

    @Test("launch sweep reports expired count per sweep; lost callback fires for both launch sweep and runtime")
    func expiredAndLostStageCallbacks() throws {
        let root = Self.tempRoot()
        let clock = Clock(Self.start)
        var expired: [Int] = []
        var lostCounts: [Int] = []
        let store = try RecordingStore(
            root: root, now: { clock.now },
            onLost: { lostCounts.append($0) },
            onExpired: { expired.append($0) }
        )
        let old = [RecordingStore.slotKey(conversationID: UUID()), RecordingStore.slotKey(conversationID: UUID())]
        for key in old { try Self.readySlot(store, key: key, durationSec: 1) }

        clock.now = Self.start.addingTimeInterval(DictationRules.pendingRetentionSec + 1)
        let lostKey = RecordingStore.slotKey(conversationID: UUID())
        let runtimeKey = RecordingStore.slotKey(conversationID: UUID())
        let lateKey = RecordingStore.slotKey(conversationID: UUID())
        for key in [lostKey, runtimeKey, lateKey] { try Self.readySlot(store, key: key, durationSec: 1) }
        try FileManager.default.removeItem(at: store.audioURL(for: lostKey))

        let report = try store.sweepOnLaunch()
        #expect(report.expired == 2)
        #expect(report.lost == 1)
        #expect(expired == [2])
        #expect(lostCounts == [1])

        // A loss found at runtime is reported on its own; an expiry found afterwards is reported as another expired batch.
        try FileManager.default.removeItem(at: store.audioURL(for: runtimeKey))
        #expect(try store.slot(for: runtimeKey) == nil)
        clock.now = clock.now.addingTimeInterval(DictationRules.pendingRetentionSec + 1)
        #expect(try store.slot(for: lateKey) == nil)
        #expect(lostCounts == [1, 1])
        #expect(expired == [2, 1])

        #expect(try store.sweepOnLaunch() == RecordingSweepReport())
        #expect(expired == [2, 1])
        #expect(lostCounts == [1, 1])
    }

    @Test("crash recovery: a recording sidecar becomes interrupted with duration and envelope from the file")
    func crashRecovery() throws {
        let root = Self.tempRoot()
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let key = RecordingStore.slotKey(conversationID: UUID())
        let writer = try store.open(slotKey: key, inputFormat: Self.inputFormat)
        try Self.feed(writer, seconds: 2)
        // The process is killed before markReady: the audio is on disk and the sidecar is still recording.
        let result = try writer.close()
        #expect(try store.slot(for: key)?.status == .recording)

        let relaunched = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let report = try relaunched.sweepOnLaunch()
        #expect(report.recovered == [key])
        #expect(report.lost == 0)
        let slot = try #require(try relaunched.slot(for: key))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - result.durationSec) <= 0.05, "recovered \(slot.durationSec) vs \(result.durationSec)")
        #expect(abs(slot.envelope.count - result.envelope.count) <= 1)
        let voiced = slot.envelope.compactMap { $0 }.filter { DictationRules.isVoiced($0) }
        #expect(Double(voiced.count) * DictationRules.windowSec >= 1.5, "voiced windows \(voiced.count)")
        #expect(DictationRules.precheck(durationSec: slot.durationSec, envelope: slot.envelope)
            == DictationRules.precheck(durationSec: result.durationSec, envelope: result.envelope))

        // A recovered slot is not processed again on the next launch.
        #expect(try relaunched.sweepOnLaunch() == RecordingSweepReport())
        #expect(lost.calls.isEmpty)
    }

    @Test("markInterrupted: sidecar becomes interrupted with duration and envelope; a reopened store reads it back")
    func markInterruptedSurvivesReopen() throws {
        let root = Self.tempRoot()
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let key = RecordingStore.slotKey(conversationID: UUID())

        #expect(throws: RecordingStoreError.slotNotFound) {
            try store.markInterrupted(slotKey: key, result: RecordingResult(url: store.audioURL(for: key),
                                                                            durationSec: 1, envelope: []))
        }

        let writer = try store.open(slotKey: key, inputFormat: Self.inputFormat, engine: "system")
        try Self.feed(writer, seconds: 0.3)
        let result = try writer.close()
        try store.markInterrupted(slotKey: key, result: result)

        let slot = try #require(try store.slot(for: key))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 0.3) < 0.05)
        #expect(slot.durationSec == result.durationSec)
        #expect(slot.envelope == result.envelope)
        #expect(!slot.envelope.isEmpty)
        #expect(slot.engine == "system")

        // Cold start: a new store pointing at the same directory; the launch sweep does not treat interrupted as needing recovery.
        let reopened = try Self.makeStore(root: root, clock: Clock(Self.start.addingTimeInterval(60)), lost: lost)
        #expect(try reopened.sweepOnLaunch() == RecordingSweepReport())
        #expect(try reopened.slot(for: key) == slot)
        #expect(Self.exists(reopened.audioURL(for: key)))
        #expect(lost.calls.isEmpty)
    }

    @Test("killed between the two file steps of complete / discard / undo: relaunch sweep counts nothing lost",
          arguments: LeavingOperation.allCases, [0, 1])
    func killMidOperation(operation: LeavingOperation, allowedSteps: Int) throws {
        let root = Self.tempRoot()
        let lost = LostCounter()
        let files = KillingFileManager()
        let store = try RecordingStore(root: root, now: { Self.start }, onLost: { lost.calls.append($0) },
                                       fileManager: files)
        let key = RecordingStore.slotKey(conversationID: UUID())
        let longDuration = DictationRules.discardUndoAboveSec + 3
        try Self.readySlot(store, key: key,
                           durationSec: operation == .discardDeleted ? 1 : longDuration)
        if operation == .undoDiscard { #expect(try store.discard(slotKey: key) == .undoable) }

        files.allowed = allowedSteps
        #expect(throws: KillingFileManager.Killed.self) {
            switch operation {
            case .complete: try store.complete(slotKey: key)
            case .discardDeleted, .discardUndoable: _ = try store.discard(slotKey: key)
            case .undoDiscard: try store.undoDiscard(slotKey: key)
            }
        }
        if allowedSteps == 1 {
            // At the interruption point the root holds only the audio (leaving the root moves the sidecar first), or only gains the audio (entering the root moves the audio first).
            #expect(!Self.exists(store.sidecarURL(for: key)), "\(operation): sidecar without audio left in root")
            #expect(Self.exists(store.audioURL(for: key)))
        }

        let relaunched = try Self.makeStore(root: root, clock: Clock(Self.start), lost: lost)
        let report = try relaunched.sweepOnLaunch()
        #expect(report.lost == 0)
        #expect(lost.calls.isEmpty)
        if allowedSteps == 1 { #expect(try relaunched.slot(for: key) == nil) }
        #expect(try relaunched.sweepOnLaunch() == RecordingSweepReport())
        #expect(lost.calls.isEmpty)
    }

    @Test("slot(for:) on an expired slot clears it as expired, never lost, even with its audio gone",
          arguments: [false, true])
    func slotForExpired(audioGone: Bool) throws {
        let root = Self.tempRoot()
        let clock = Clock(Self.start)
        let lost = LostCounter()
        let store = try Self.makeStore(root: root, clock: clock, lost: lost)
        let key = RecordingStore.slotKey(conversationID: UUID())
        try Self.readySlot(store, key: key, durationSec: 1)
        if audioGone { try FileManager.default.removeItem(at: store.audioURL(for: key)) }

        clock.now = Self.start.addingTimeInterval(DictationRules.pendingRetentionSec + 1)
        #expect(try store.slot(for: key) == nil)
        #expect(!Self.exists(store.sidecarURL(for: key)))
        #expect(!Self.exists(store.audioURL(for: key)))
        #expect(lost.calls.isEmpty)
        #expect(try store.sweepOnLaunch() == RecordingSweepReport())
        #expect(lost.calls.isEmpty)
    }

    @Test("pending and discard directories are excluded from backup")
    func excludedFromBackup() throws {
        let store = try RecordingStore(root: Self.tempRoot())
        for directory in [store.root, store.discardRoot] {
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(directory.path)")
        }
        #expect(try RecordingStore.productionRoot().path.hasSuffix("Application Support/Oriveo/Voice/pending"))
    }
}
