import AVFoundation
import Combine
import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Main flow of the dictation controller. A real RecordingStore points at a temporary directory; the engine, capture and permission are fakes.
/// Every flow ends by checking that the RecordingStore lost count is 0. When a fake timer / continuation hangs, timeLimit is the backstop so the test host is not held up.
@Suite("Dictation controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DictationControllerTests {

    private static let inputRate = 48_000.0
    private static let slotKey = "conversation-a"
    private static let otherKey = "conversation-b"

    private let engine = FakeSTTEngine()
    private let capture = FakeAudioCapture(sampleRate: inputRate)
    private let permission = FakeMicrophonePermission()
    private let center = NotificationCenter()
    private let lost = LostCounter()
    private let timer = ManualTimer()
    private let idleTimer = FakeIdleTimer()
    private let screenAwake: ScreenAwakeHolds
    private let store: RecordingStore
    private let readAloud = ReadAloudController(
        engine: SilentSpeechEngine(), platform: SilentReadAloudPlatform(),
        screenAwake: ScreenAwakeHolds(timer: FakeIdleTimer()),
        notificationCenter: NotificationCenter(), detectLanguage: { _ in "en" }
    )

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DictationControllerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
        let lost = self.lost
        screenAwake = ScreenAwakeHolds(timer: idleTimer)
        store = try RecordingStore(root: root, onLost: { lost.total += $0 })
    }

    private func makeController(
        engines: DictationEngineSource? = nil,
        system: DictationSystemPreparation? = nil,
        store: RecordingStore? = nil,
        capture: AudioCapture? = nil,
        audioSession: VoiceAudioSessionOwner = .shared
    ) async -> (DictationController, EventSpy) {
        let timer = self.timer
        let controller = DictationController(
            engines: engines ?? .fixed(engine), system: system ?? .skipped,
            capture: capture ?? self.capture, store: store ?? self.store, audioSession: audioSession,
            permission: permission, readAloud: readAloud, screenAwake: screenAwake, notificationCenter: center,
            now: { Date(timeIntervalSince1970: 1_000) },
            sleep: { try await timer.sleep($0) }
        )
        controller.bind(slotKey: Self.slotKey)
        await controller.bindLoad?.value
        let spy = EventSpy()
        controller.onEvent = { spy.events.append($0) }
        return (controller, spy)
    }

    /// Grants permission, starts recording, and feeds `seconds` seconds (amplitude 0 is digital silence).
    private func record(_ controller: DictationController, seconds: Double, amplitude: Float = 0.1) async {
        permission.status = .granted
        await controller.micTapped()
        capture.feed(seconds: seconds, amplitude: amplitude)
    }

    private var audioExists: Bool {
        FileManager.default.fileExists(atPath: store.audioURL(for: Self.slotKey).path)
    }

    private func postInterruptionBegan() {
        center.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
    }

    // MARK: Permission and read-aloud

    @Test("Tapping the mic stops read-aloud first, then starts recording")
    func micStopsReadAloud() async {
        let (controller, _) = await makeController()
        readAloud.toggle(messageID: UUID(), text: "First sentence. Second sentence.")
        #expect(readAloud.state != .idle)

        permission.status = .granted
        await controller.micTapped()

        #expect(readAloud.state == .idle)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(capture.startCount == 1)
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    @Test("Microphone denied -> denied with no prompt; first ask refused -> denied")
    func deniedPermission() async throws {
        let (controller, _) = await makeController()
        permission.status = .denied
        await controller.micTapped()
        #expect(controller.state == .denied(.microphone))
        #expect(permission.requestCount == 0)
        #expect(capture.startCount == 0)

        permission.status = .undetermined
        permission.answer = false
        await controller.micTapped()
        #expect(controller.state == .denied(.microphone))
        #expect(permission.requestCount == 1)
        #expect(capture.startCount == 0)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
    }

    // MARK: Success and precheck

    @Test("The Transcribe button succeeds -> insert result, slot deleted")
    func insertSucceeds() async throws {
        let (controller, spy) = await makeController()
        engine.outcome = .success("  hello world \n")
        await record(controller, seconds: 1)
        await controller.finish(.insert)
        await controller.storeDrained()

        #expect(spy.events == [.insert("hello world")])
        #expect(controller.state == .idle)
        #expect(capture.stopCount == 1)
        let call = try #require(engine.calls.first)
        #expect(engine.calls.count == 1)
        #expect(abs(call.durationSec - 1) < 0.05)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(!audioExists)
        #expect(lost.total == 0)
    }

    @Test("The up-arrow (send) button succeeds -> send result")
    func sendSucceeds() async throws {
        let (controller, spy) = await makeController()
        engine.outcome = .success("send me")
        await record(controller, seconds: 1)
        await controller.finish(.send)
        await controller.storeDrained()

        #expect(spy.events == [.send("send me")])
        #expect(controller.state == .idle)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
    }

    @Test("Precheck finds silence -> no-sound notice, recording deleted, engine not called")
    func silentRecordingSkipsEngine() async throws {
        let (controller, spy) = await makeController()
        await record(controller, seconds: 1, amplitude: 0)
        await controller.finish(.insert)
        await controller.storeDrained()

        #expect(spy.events == [.noSpeechHeard])
        #expect(controller.state == .idle)
        #expect(engine.calls.isEmpty)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(!audioExists)
        #expect(lost.total == 0)
    }

    // MARK: Discard

    @Test("Cancel (X): over 5 s is undoable, and undo returns to interrupted with the recording intact")
    func longDiscardIsUndoable() async throws {
        let (controller, spy) = await makeController()
        engine.outcome = .success("restored")
        await record(controller, seconds: 6)

        #expect(await controller.discard() == .undoable)
        #expect(controller.state == .idle)
        #expect(try store.slot(for: Self.slotKey) == nil)

        await controller.undoDiscard()
        #expect(controller.state == .interrupted)
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .ready)
        #expect(abs(slot.durationSec - 6) < 0.05)
        #expect(audioExists)

        await controller.finish(.insert)
        await controller.storeDrained()
        #expect(spy.events == [.insert("restored")])
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
    }

    @Test("Cancel (X): up to 5 s is deleted directly with nothing to undo")
    func shortDiscardDeletes() async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 1)

        #expect(await controller.discard() == .deleted)
        #expect(controller.undoWindowTask == nil)
        #expect(timer.requested.isEmpty)
        await controller.undoDiscard()
        #expect(controller.state == .idle)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(!audioExists)
        #expect(lost.total == 0)
    }

    // MARK: System events

    @Test("Interruption began -> interrupted, file closed and in the slot")
    func interruptionKeepsRecording() async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 1)
        center.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )

        #expect(controller.state == .interrupted)
        #expect(capture.stopCount == 1)
        await controller.storeDrained()
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 1) < 0.05)
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    @Test("Media services reset while recording -> same as an interruption: interrupted, file closed and in the slot")
    func mediaServicesResetKeepsRecording() async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 1)
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        #expect(controller.state == .interrupted)
        #expect(capture.stopCount == 1)
        await controller.storeDrained()
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 1) < 0.05)
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    @Test("Input format changed after activation -> the writer is built from the format start returned, recording duration > 0")
    func writerUsesFormatReturnedByStart() async throws {
        let (controller, spy) = await makeController()
        capture.formatAfterStart = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                                 channels: 2, interleaved: false)!
        engine.outcome = .success("hello")
        await record(controller, seconds: 1)
        await controller.finish(.insert)

        #expect(spy.events == [.insert("hello")])
        let call = try #require(engine.calls.first)
        #expect(call.durationSec > 0)
        #expect(abs(call.durationSec - 1) < 0.05, "duration \(call.durationSec)")
        #expect(lost.total == 0)
    }

    @Test("Write error while recording -> recording stops, file kept, interrupted (not idle, slot not deleted)")
    func appendFailureInterrupts() async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 1)
        let mismatched = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050,
                                       channels: 1, interleaved: false)!
        capture.feed(seconds: 0.2, amplitude: 0.1, format: mismatched)

        #expect(controller.state == .interrupted)
        #expect(capture.stopCount == 1)
        await controller.storeDrained()
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 1) < 0.05, "duration \(slot.durationSec)")
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    @Test("Entering background -> interrupted, file kept")
    func backgroundKeepsRecording() async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 1)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        #expect(controller.state == .interrupted)
        #expect(capture.stopCount == 1)
        await controller.storeDrained()
        #expect(try store.slot(for: Self.slotKey)?.status == .interrupted)
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    // MARK: Across restarts and slot switches

    /// The process is killed before markReady: open a slot directly through the store, write `seconds` seconds, close the file, and leave the sidecar at recording.
    private func crashedRecording(key: String, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.inputRate,
                                   channels: 1, interleaved: false)!
        let writer = try store.open(slotKey: key, inputFormat: format)
        let frames = Int(seconds * Self.inputRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            buffer.floatChannelData![0][frame] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(frame) / Self.inputRate))
        }
        try writer.append(buffer)
        _ = try writer.close()
    }

    @Test("The launch sweep runs before the first bind: a recording sidecar left by a crash -> interrupted, duration > 0; each directory is swept once per process")
    func firstBindSweepsOncePerProcess() async throws {
        try crashedRecording(key: Self.slotKey, seconds: 1)
        #expect(try store.slot(for: Self.slotKey)?.status == .recording)

        let (controller, _) = await makeController()
        #expect(controller.state == .interrupted)
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(slot.durationSec > 0)
        #expect(abs(slot.durationSec - 1) < 0.05, "recovered \(slot.durationSec)")

        // Later bindings in the same process (slot switch, new controller) do not sweep again: a new crash sidecar stays recording.
        try crashedRecording(key: Self.otherKey, seconds: 0.5)
        controller.bind(slotKey: Self.otherKey)
        await controller.bindLoad?.value
        #expect(controller.state == .interrupted)
        #expect(try store.slot(for: Self.otherKey)?.status == .recording)
        let (second, _) = await makeController()
        second.bind(slotKey: Self.otherKey)
        await second.bindLoad?.value
        #expect(try store.slot(for: Self.otherKey)?.status == .recording)
        #expect(lost.total == 0)
    }

    @Test("Cold start after interruption / backgrounding: a new controller binding the same slot -> interrupted, duration preserved, transcribable", arguments: [false, true])
    func rebindAfterRestartShowsInterrupted(viaBackground: Bool) async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 1)
        if viaBackground {
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        } else {
            postInterruptionBegan()
        }
        #expect(controller.state == .interrupted)
        await controller.storeDrained()
        #expect(try store.slot(for: Self.slotKey)?.status == .interrupted)

        // Cold start: a new store points at the same directory and runs the launch sweep; the new controller binds the same slot key through bind.
        let lost = self.lost
        let relaunched = try RecordingStore(root: store.root, onLost: { lost.total += $0 })
        #expect(try relaunched.sweepOnLaunch() == RecordingSweepReport())
        engine.outcome = .success("after restart")
        let (restored, spy) = await makeController(store: relaunched)
        #expect(restored.slotKey == Self.slotKey)
        #expect(restored.state == .interrupted)
        let slot = try #require(try relaunched.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 1) < 0.05)

        await restored.finish(.insert)
        await restored.storeDrained()
        #expect(spy.events == [.insert("after restart")])
        #expect(abs((engine.calls.first?.durationSec ?? 0) - 1) < 0.05)
        #expect(engine.calls.map(\.url) == [relaunched.audioURL(for: Self.slotKey)])
        #expect(try relaunched.slot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
    }

    @Test("Switching to another slot while recording -> the original slot is first finalized as interrupted, then the switch happens; switching back -> interrupted")
    func switchingSlotsKeepsRecording() async throws {
        let (controller, spy) = await makeController()
        await record(controller, seconds: 1)

        controller.bind(slotKey: Self.otherKey)
        await controller.bindLoad?.value
        #expect(controller.slotKey == Self.otherKey)
        #expect(controller.state == .idle)
        #expect(capture.stopCount == 1)
        let first = try #require(try store.slot(for: Self.slotKey))
        #expect(first.status == .interrupted)
        #expect(abs(first.durationSec - 1) < 0.05)
        #expect(audioExists)
        #expect(try store.slot(for: Self.otherKey) == nil)

        // The other slot records independently; switching back to the original slot, the second take is finalized as interrupted the same way.
        await controller.micTapped()
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        capture.feed(seconds: 2, amplitude: 0.1)
        controller.bind(slotKey: Self.slotKey)
        await controller.bindLoad?.value
        #expect(controller.state == .interrupted)
        #expect(capture.stopCount == 2)
        let second = try #require(try store.slot(for: Self.otherKey))
        #expect(second.status == .interrupted)
        #expect(abs(second.durationSec - 2) < 0.05)

        // After switching back, what gets transcribed is the original slot's take; the other slot is unaffected.
        engine.outcome = .success("first take")
        await controller.finish(.insert)
        await controller.storeDrained()
        #expect(spy.events == [.insert("first take")])
        #expect(engine.calls.map(\.url) == [store.audioURL(for: Self.slotKey)])
        #expect(try store.slot(for: Self.slotKey) == nil)

        controller.bind(slotKey: Self.otherKey)
        await controller.bindLoad?.value
        #expect(controller.state == .interrupted)
        #expect(await controller.discard() == .deleted)
        #expect(try store.slot(for: Self.otherKey) == nil)
        #expect(lost.total == 0)
    }

    @Test("Switching to another slot while transcribing -> the in-flight transcription is cancelled, the original slot's sidecar is interrupted and its recording kept")
    func switchingSlotsWhileTranscribingKeepsRecording() async throws {
        let suspended = SuspendedSTTEngine()
        let (controller, spy) = await makeController(engines: .fixed(suspended))
        await record(controller, seconds: 2)
        let finishing = Task { await controller.finish(.insert) }
        await suspended.waitForCall()
        #expect(controller.state == .transcribing(.insert))

        controller.bind(slotKey: Self.otherKey)
        await controller.bindLoad?.value
        await finishing.value
        #expect(suspended.cancelled)
        #expect(spy.events.isEmpty)
        #expect(controller.state == .idle)
        let first = try #require(try store.slot(for: Self.slotKey))
        #expect(first.status == .interrupted)
        #expect(abs(first.durationSec - 2) < 0.05)
        #expect(audioExists)

        controller.bind(slotKey: Self.slotKey)
        await controller.bindLoad?.value
        #expect(controller.state == .interrupted)
        #expect(lost.total == 0)
    }

    @Test("Transcription succeeds but there is no receiver (onEvent is nil) -> recording not deleted, sidecar interrupted")
    func successWithoutReceiverKeepsRecording() async throws {
        let (controller, _) = await makeController()
        controller.onEvent = nil
        engine.outcome = .success("hello world")
        await record(controller, seconds: 1)
        await controller.finish(.insert)
        await controller.storeDrained()

        #expect(engine.calls.count == 1)
        #expect(controller.state == .interrupted)
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 1) < 0.05)
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    @Test("Cancel (X) over 5 s: undo within the 4 s undo window restores; it takes effect automatically when time is up, and undo afterwards is invalid")
    func undoWindowCommitsAfterFourSeconds() async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 6)

        #expect(await controller.discard() == .undoable)
        await timer.waitForSleeps(1)
        #expect(timer.requested == [.seconds(4)])
        timer.advance(by: .milliseconds(3_900))
        #expect(controller.undoWindowTask != nil)
        await controller.undoDiscard()
        #expect(controller.state == .interrupted)
        #expect(controller.undoWindowTask == nil)
        let restored = try #require(try store.slot(for: Self.slotKey))
        #expect(abs(restored.durationSec - 6) < 0.05)
        #expect(audioExists)

        #expect(await controller.discard() == .undoable)
        await timer.waitForSleeps(2)
        #expect(timer.requested == [.seconds(4), .seconds(4)])
        let window = try #require(controller.undoWindowTask)
        timer.advance(by: .seconds(4))
        await window.value
        #expect(controller.undoWindowTask == nil)
        let discarded = try FileManager.default.contentsOfDirectory(at: store.discardRoot,
                                                                    includingPropertiesForKeys: nil)
        #expect(discarded.isEmpty)

        await controller.undoDiscard()
        #expect(controller.state == .idle)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(!audioExists)
        #expect(lost.total == 0)
    }

    @Test("The sidecar records the engine used: system / cloud providerKind + model")
    func sidecarRecordsEngine() async throws {
        let (systemController, _) = await makeController(engines: systemSource(FakeSTTEngine()))
        permission.status = .granted
        await systemController.micTapped()
        #expect(try store.slot(for: Self.slotKey)?.engine == "system")
        #expect(await systemController.discard() == .deleted)

        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider)
        let (cloudController, _) = await makeController(engines: resolvingSource(
            settings: settings, catalog: .available(Self.catalog(models: [Self.cloudModel])),
            providers: [provider], system: FakeSTTEngine()
        ))
        await cloudController.micTapped()
        #expect(cloudController.engine is CloudSTTEngine)
        #expect(try store.slot(for: Self.slotKey)?.engine == "\(ProviderKind.relay.rawValue)/\(Self.cloudModel)")
        #expect(await cloudController.discard() == .deleted)
        #expect(lost.total == 0)
    }

    // MARK: Failure

    @Test("401 -> failed(checkConnection), recording kept")
    func authFailureKeepsRecording() async throws {
        let (controller, spy) = await makeController()
        engine.outcome = .failure(STTError(action: .checkConnection, failure: .http(status: 401, retryAfter: nil)))
        await record(controller, seconds: 1)
        await controller.finish(.insert)

        #expect(controller.state == .failed(.checkConnection))
        #expect(spy.events.isEmpty)
        // The sidecar's failed state is written asynchronously on the store queue by fail(); wait for the queue to drain before reading the sidecar.
        await controller.storeDrained()
        #expect(try store.slot(for: Self.slotKey)?.status == .failed)
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    @Test("Other failures -> failed(retry), recording kept, retry reuses the same recording")
    func otherFailuresRetry() async throws {
        let (controller, spy) = await makeController()
        engine.outcome = .failure(STTError(action: .retry, failure: .network))
        await record(controller, seconds: 1)
        await controller.finish(.send)
        #expect(controller.state == .failed(.retry))
        #expect(audioExists)

        engine.outcome = .failure(URLError(.cannotConnectToHost))
        await controller.finish(.send)
        #expect(controller.state == .failed(.retry))
        // The sidecar's failed state is written asynchronously on the store queue by fail(); wait for the queue to drain before reading the sidecar.
        await controller.storeDrained()
        #expect(try store.slot(for: Self.slotKey)?.status == .failed)
        #expect(audioExists)

        engine.outcome = .success("third time")
        await controller.finish(.send)
        #expect(spy.events == [.send("third time")])
        #expect(engine.calls.count == 3)
        #expect(Set(engine.calls.map(\.url)).count == 1)
        #expect(lost.total == 0)
    }

    @Test("Empty text -> failed(noTranscript), recording kept")
    func emptyTranscriptKeepsRecording() async throws {
        let (controller, spy) = await makeController()
        engine.outcome = .success(" \n\t ")
        await record(controller, seconds: 1)
        await controller.finish(.insert)

        #expect(controller.state == .failed(.noTranscript))
        #expect(spy.events.isEmpty)
        // The sidecar's failed state is written asynchronously on the store queue by fail(); wait for the queue to drain before reading the sidecar.
        await controller.storeDrained()
        #expect(try store.slot(for: Self.slotKey) != nil)
        #expect(audioExists)
        #expect(lost.total == 0)
    }

    // MARK: Slot occupied

    /// Records 1 s then goes to the background, leaving a ready recording in the slot.
    private func leaveOccupiedSlot(_ controller: DictationController) async {
        await record(controller, seconds: 1)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(controller.state == .interrupted)
        await controller.storeDrained()
    }

    @Test("Tapping the mic with the slot occupied -> slotOccupied, recording does not start")
    func occupiedSlotAsksFirst() async throws {
        let (controller, _) = await makeController()
        await leaveOccupiedSlot(controller)

        await controller.micTapped()
        #expect(controller.state == .slotOccupied)
        #expect(capture.startCount == 1)
        #expect(try store.slot(for: Self.slotKey)?.status == .interrupted)
        #expect(lost.total == 0)
    }

    @Test("Transcribe first -> the old recording is transcribed and inserted, slot deleted")
    func occupiedSlotTranscribesOld() async throws {
        let (controller, spy) = await makeController()
        engine.outcome = .success("old take")
        await leaveOccupiedSlot(controller)
        let oldURL = store.audioURL(for: Self.slotKey)
        await controller.micTapped()

        await controller.transcribeOccupied()
        await controller.storeDrained()
        #expect(spy.events == [.insert("old take")])
        #expect(controller.state == .idle)
        #expect(engine.calls.map(\.url) == [oldURL])
        #expect(abs((engine.calls.first?.durationSec ?? 0) - 1) < 0.05)
        #expect(capture.startCount == 1)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
    }

    @Test("Discard and re-record -> old recording deleted, new recording starts")
    func occupiedSlotDiscardsAndRerecords() async throws {
        let (controller, _) = await makeController()
        await leaveOccupiedSlot(controller)
        await controller.micTapped()

        await controller.discardAndRerecord()
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(capture.startCount == 2)
        #expect(engine.calls.isEmpty)
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .recording)
        #expect(await controller.discard() == .deleted)
        #expect(lost.total == 0)
    }

    // MARK: Engine selection

    private static let cloudModel = "whisper-1"
    private static let cloudPath = "/v1/audio/transcriptions"

    private static func catalog(models: [String]) -> VoiceCatalog {
        let entries = models.map {
            VoiceSTTEntry(model: $0, transport: .openAITranscriptions, path: cloudPath, maxBytes: 25_000_000,
                          maxDurationSec: 1_500, languageField: "language", isDefault: true)
        }
        return VoiceCatalog(schemaVersion: 2, revision: "r1",
                            providers: [.relay: VoiceProviderEntries(stt: entries, tts: [])])
    }

    private static func relayProvider(apiKey: String = "sk-voice") -> Provider {
        TestFactories.makeProvider(kind: .relay, apiKey: apiKey, baseURLText: "https://relay.example.com/gateway/v1")
    }

    private static func freshSettings() -> VoiceEngineSettings {
        VoiceEngineSettings(defaults: UserDefaults(suiteName: "DictationControllerTests-\(UUID().uuidString)")!)
    }

    /// Writes the cloud dictation selection; by default it also records the provider's disclosure consent (writing through the engine sheet always implies consent).
    private static func selectCloud(_ settings: VoiceEngineSettings, provider: Provider, accepted: Bool = true) {
        settings.setSelection(.cloud(VoiceCloudEngine(
            providerKind: provider.kind, connectionID: provider.id.uuidString, model: cloudModel
        )), for: .stt)
        if accepted { settings.disclosures.markAccepted(provider.kind, direction: .stt) }
    }

    private func resolvingSource(
        settings: VoiceEngineSettings,
        catalog: VoiceCatalogState?,
        providers: [Provider],
        system: FakeSTTEngine
    ) -> DictationEngineSource {
        .resolving(
            settings: settings,
            catalog: { catalog },
            providers: { providers },
            makeSystem: { system }
        )
    }

    @Test("A valid cloud selection -> CloudSTTEngine, URL = connection origin + catalog path, key taken from the connection")
    func validCloudSelection() async throws {
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider)
        let systemEngine = FakeSTTEngine()
        let (controller, spy) = await makeController(engines: resolvingSource(
            settings: settings, catalog: .available(Self.catalog(models: [Self.cloudModel])),
            providers: [provider], system: systemEngine
        ))

        permission.status = .granted
        await controller.micTapped()

        let cloud = try #require(controller.engine as? CloudSTTEngine)
        #expect(DictationRules.requestURL(baseURL: cloud.baseURL, path: cloud.entry.path)?.absoluteString
                == "https://relay.example.com/v1/audio/transcriptions")
        #expect(cloud.apiKey == "sk-voice")
        #expect(cloud.entry.model == Self.cloudModel)
        #expect(spy.events.isEmpty)
        #expect(settings.selection(for: .stt) != .system)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    @Test("Connection deleted / key cleared / entry withdrawn -> system engine, notice shown once, setting reverts to system")
    func invalidCloudSelectionFallsBack() async throws {
        let provider = Self.relayProvider()
        var keyCleared = provider
        keyCleared.apiKey = ""
        let cases: [(VoiceFallbackReason, [Provider], VoiceCatalog)] = [
            (.connectionMissing, [], Self.catalog(models: [Self.cloudModel])),
            (.keyMissing, [keyCleared], Self.catalog(models: [Self.cloudModel])),
            (.entryRemoved, [provider], Self.catalog(models: ["other-model"])),
        ]
        for (reason, providers, catalog) in cases {
            let settings = Self.freshSettings()
            Self.selectCloud(settings, provider: provider)
            let systemEngine = FakeSTTEngine()
            systemEngine.outcome = .success("system text")
            let (controller, spy) = await makeController(engines: resolvingSource(
                settings: settings, catalog: .available(catalog), providers: providers, system: systemEngine
            ))

            await record(controller, seconds: 1)
            #expect((controller.engine as? FakeSTTEngine) === systemEngine, "\(reason)")
            #expect(spy.events == [.engineFallback(reason)], "\(reason)")
            #expect(settings.selection(for: .stt) == .system, "\(reason)")
            await controller.finish(.insert)
            #expect(spy.events == [.engineFallback(reason), .insert("system text")], "\(reason)")

            // The setting has reverted to system: no notice next time.
            await record(controller, seconds: 1)
            await controller.finish(.insert)
            await controller.storeDrained()
            #expect(spy.events == [.engineFallback(reason), .insert("system text"), .insert("system text")],
                    "\(reason)")
            #expect(try store.slot(for: Self.slotKey) == nil)
        }
        #expect(lost.total == 0)
    }

    @Test("No catalog cache and loading fails -> system engine this time, setting unchanged, no notice")
    func catalogLoadFailedUsesSystemOnce() async throws {
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider)
        let stored = settings.selection(for: .stt)
        let systemEngine = FakeSTTEngine()
        let (controller, spy) = await makeController(engines: resolvingSource(
            settings: settings, catalog: .loadFailed, providers: [provider], system: systemEngine
        ))

        await record(controller, seconds: 1)
        #expect((controller.engine as? FakeSTTEngine) === systemEngine)
        #expect(spy.events.isEmpty)
        #expect(settings.selection(for: .stt) == stored)
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    @Test("Cold catalog fetch never returns -> micTapped returns within the limit, same as a load failure: system engine this time, setting unchanged, no notice; tapping again can continue")
    func catalogRefreshThatNeverReturnsTimesOut() async throws {
        let hang = NeverReturningCall()
        defer { hang.releaseAll() }
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider)
        let stored = settings.selection(for: .stt)
        let systemEngine = FakeSTTEngine()
        let (controller, spy) = await makeController(engines: .resolving(
            settings: settings,
            catalog: {
                await hang.hang()
                return .loadFailed
            },
            catalogLimit: .milliseconds(50),
            providers: { [provider] },
            makeSystem: { systemEngine }
        ))

        let started = ContinuousClock.now
        await record(controller, seconds: 1)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(hang.callCount == 1)
        #expect((controller.engine as? FakeSTTEngine) === systemEngine)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(spy.events.isEmpty)
        #expect(settings.selection(for: .stt) == stored)
        _ = await controller.discard()

        await record(controller, seconds: 1)
        #expect(hang.callCount == 2)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(capture.startCount == 2)
        #expect(settings.selection(for: .stt) == stored)
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    @Test("Cloud selection without disclosure consent (restored backup / old data) -> system engine this time, setting not rewritten, no engineFallback")
    func cloudSelectionWithoutConsentUsesSystemOnce() async throws {
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider, accepted: false)
        let selected = settings.selection(for: .stt)
        let systemEngine = FakeSTTEngine()
        systemEngine.outcome = .success("system text")
        let (controller, spy) = await makeController(engines: resolvingSource(
            settings: settings, catalog: .available(Self.catalog(models: [Self.cloudModel])),
            providers: [provider], system: systemEngine
        ))

        await record(controller, seconds: 1)
        #expect((controller.engine as? FakeSTTEngine) === systemEngine)
        await controller.finish(.insert)
        #expect(spy.events == [.insert("system text")])
        #expect(settings.selection(for: .stt) == selected)
        #expect(settings.takePendingNotice(site: .settings, direction: .stt) == nil)
        #expect(lost.total == 0)
    }

    @Test("The settings page detects the fallback first and rewrites -> notice once on the next recording, none the time after")
    func settingsSiteFallbackNotifiesNextUseOnce() async throws {
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider)
        // The connection was already deleted when the settings page resolved: storage reverts to system and leaves one pending notice for the call site.
        settings.resolve(direction: .stt, catalog: Self.catalog(models: [Self.cloudModel]), connections: [], site: .settings)
        #expect(settings.selection(for: .stt) == .system)
        let systemEngine = FakeSTTEngine()
        systemEngine.outcome = .success("system text")
        let (controller, spy) = await makeController(engines: resolvingSource(
            settings: settings, catalog: .available(Self.catalog(models: [Self.cloudModel])),
            providers: [], system: systemEngine
        ))

        await record(controller, seconds: 1)
        #expect((controller.engine as? FakeSTTEngine) === systemEngine)
        #expect(spy.events == [.engineFallback(.connectionMissing)])
        await controller.finish(.insert)

        await record(controller, seconds: 1)
        await controller.finish(.insert)
        #expect(spy.events == [.engineFallback(.connectionMissing), .insert("system text"), .insert("system text")])
        #expect(settings.takePendingNotice(site: .settings, direction: .stt) == nil)
        #expect(lost.total == 0)
    }

    // MARK: System engine preparation

    private func systemSource(_ systemEngine: FakeSTTEngine) -> DictationEngineSource {
        resolvingSource(settings: Self.freshSettings(), catalog: nil, providers: [], system: systemEngine)
    }

    @Test("iOS 18-25 system engine: speech recognition authorization is requested after the microphone, refused -> denied(speechRecognition)")
    func legacySystemEngineAsksSpeechRecognition() async throws {
        let authorizer = DictationSpeechAuthorizerFake()
        authorizer.answer = false
        let system = DictationSystemPreparation(
            analyzerAvailable: false, authorizer: authorizer, assets: nil, assetLocale: { _ in nil }
        )
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: system)

        permission.status = .undetermined
        await controller.micTapped()
        #expect(permission.requestCount == 1)
        #expect(authorizer.requestCount == 1)
        #expect(controller.state == .denied(.speechRecognition))
        #expect(capture.startCount == 0)
        #expect(try store.slot(for: Self.slotKey) == nil)

        authorizer.answer = true
        await controller.micTapped()
        #expect(authorizer.requestCount == 2)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    @Test("iOS 18-25 microphone denied -> speech recognition authorization is not requested")
    func legacyMicrophoneDeniedSkipsSpeechRecognition() async {
        let authorizer = DictationSpeechAuthorizerFake()
        let system = DictationSystemPreparation(
            analyzerAvailable: false, authorizer: authorizer, assets: nil, assetLocale: { _ in nil }
        )
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: system)
        permission.status = .denied
        await controller.micTapped()
        #expect(controller.state == .denied(.microphone))
        #expect(authorizer.requestCount == 0)
        #expect(lost.total == 0)
    }

    @Test("iOS 26+ system engine does not need speech recognition authorization; the cloud engine does not need it on iOS 18-25 either")
    func modernSystemEngineSkipsSpeechRecognition() async {
        let authorizer = DictationSpeechAuthorizerFake()
        let modern = DictationSystemPreparation(
            analyzerAvailable: true, authorizer: authorizer, assets: nil, assetLocale: { _ in nil }
        )
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: modern)
        permission.status = .granted
        await controller.micTapped()
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(authorizer.requestCount == 0)
        _ = await controller.discard()

        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider)
        let legacy = DictationSystemPreparation(
            analyzerAvailable: false, authorizer: authorizer, assets: nil, assetLocale: { _ in nil }
        )
        let (cloudController, _) = await makeController(engines: resolvingSource(
            settings: settings, catalog: .available(Self.catalog(models: [Self.cloudModel])),
            providers: [provider], system: FakeSTTEngine()
        ), system: legacy)
        await cloudController.micTapped()
        #expect(cloudController.engine is CloudSTTEngine)
        #expect(authorizer.requestCount == 0)
        _ = await cloudController.discard()
        #expect(lost.total == 0)
    }

    /// System preparation whose assetLocale never returns; the limit is in milliseconds.
    private func hangingAssetLocaleSystem(_ hang: NeverReturningCall) -> DictationSystemPreparation {
        let assets = SpeechAssetManager(
            inventory: FakeSpeechAssetInventory(maximum: 4),
            defaults: UserDefaults(suiteName: "DictationControllerTests-\(UUID().uuidString)")!
        )
        return DictationSystemPreparation(
            analyzerAvailable: true, authorizer: DictationSpeechAuthorizerFake(), assets: assets,
            assetLocale: { _ in
                await hang.hang()
                return Locale(identifier: "en-US")
            },
            assetLocaleLimit: .milliseconds(50)
        )
    }

    @Test("assetLocale never returns: micTapped returns within the limit, with the same state as assetLocale = nil")
    func assetLocaleThatNeverReturnsTimesOut() async {
        let hang = NeverReturningCall()
        defer { hang.releaseAll() }
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: hangingAssetLocaleSystem(hang))
        permission.status = .granted

        let started = ContinuousClock.now
        await controller.micTapped()
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(hang.callCount == 1)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(capture.startCount == 1)
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    @Test("Tapping the mic again after the preparation timeout: not silently dropped, recording can start")
    func tapAfterTimedOutPreparationIsNotDropped() async {
        let hang = NeverReturningCall()
        defer { hang.releaseAll() }
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: hangingAssetLocaleSystem(hang))
        permission.status = .granted

        await controller.micTapped()
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        _ = await controller.discard()

        await controller.micTapped()
        #expect(hang.callCount == 2)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(capture.startCount == 2)
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    @Test("System assets downloading -> preparing(progress), completion goes to recording")
    func systemAssetsDownloadShowsPreparing() async throws {
        let inventory = DictationAssetInventoryFake()
        let defaults = UserDefaults(suiteName: "DictationControllerTests-\(UUID().uuidString)")!
        let assets = SpeechAssetManager(inventory: inventory, defaults: defaults)
        let locale = Locale(identifier: "en-US")
        let system = DictationSystemPreparation(
            analyzerAvailable: true, authorizer: DictationSpeechAuthorizerFake(), assets: assets, assetLocale: { _ in locale }
        )
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: system)
        permission.status = .granted

        let tap = Task { await controller.micTapped() }
        let preparing = await controller.$state.values.first { $0 == .preparing(progress: 0.5) }
        #expect(preparing == .preparing(progress: 0.5))
        #expect(capture.startCount == 0)
        #expect(try store.slot(for: Self.slotKey) == nil)

        inventory.finishInstall()
        await tap.value
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(assets.state(.speechTranscriber, locale: locale) == .installed)
        #expect(capture.startCount == 1)
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    @Test("Host detaches during preparing -> the start is voided, still idle after preparation completes, no recording in the slot")
    func hostDetachDuringPreparingCancelsStart() async throws {
        let inventory = DictationAssetInventoryFake()
        let assets = SpeechAssetManager(
            inventory: inventory, defaults: UserDefaults(suiteName: "DictationControllerTests-\(UUID().uuidString)")!
        )
        let locale = Locale(identifier: "en-US")
        let system = DictationSystemPreparation(
            analyzerAvailable: true, authorizer: DictationSpeechAuthorizerFake(), assets: assets, assetLocale: { _ in locale }
        )
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: system)
        let host = DictationHostBinding()
        host.attach(controller: controller, slotKey: Self.slotKey)
        permission.status = .granted

        let tap = Task { await controller.micTapped() }
        let preparing = await controller.$state.values.first { $0 == .preparing(progress: 0.5) }
        #expect(preparing == .preparing(progress: 0.5))

        host.detach()
        #expect(controller.state == .idle)
        inventory.finishInstall()
        await tap.value
        #expect(controller.state == .idle)
        #expect(capture.startCount == 0)
        #expect(try store.slot(for: Self.slotKey) == nil)
        #expect(controller.onEvent == nil)
        #expect(lost.total == 0)
    }

    @Test("System assets already installed -> recording directly, without passing through preparing")
    func installedAssetsSkipPreparing() async {
        let inventory = DictationAssetInventoryFake()
        inventory.installed = true
        let assets = SpeechAssetManager(
            inventory: inventory, defaults: UserDefaults(suiteName: "DictationControllerTests-\(UUID().uuidString)")!
        )
        let system = DictationSystemPreparation(
            analyzerAvailable: true, authorizer: DictationSpeechAuthorizerFake(), assets: assets,
            assetLocale: { _ in Locale(identifier: "en-US") }
        )
        let (controller, _) = await makeController(engines: systemSource(FakeSTTEngine()), system: system)
        var seen: [DictationState] = []
        let cancellable = controller.$state.sink { seen.append($0) }
        permission.status = .granted
        await controller.micTapped()
        cancellable.cancel()

        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(!seen.contains { if case .preparing = $0 { return true } else { return false } })
        #expect(inventory.installCount == 0)
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    // MARK: Card and transcribing-state exits

    @Test("While the cloud engine transcribes engineInfo = connection display name + id; nil for the system engine; cleared on return to idle")
    func engineInfoForCloudAndSystem() async throws {
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, provider: provider)
        let cloud = SuspendedSTTEngine()
        let (controller, spy) = await makeController(engines: .resolving(
            settings: settings,
            catalog: { .available(Self.catalog(models: [Self.cloudModel])) },
            providers: { [provider] },
            makeSystem: { FakeSTTEngine() },
            makeCloud: { _, _, _ in cloud }
        ))
        #expect(controller.engineInfo == nil)
        await record(controller, seconds: 1)
        let finishing = Task { await controller.finish(.insert) }
        await cloud.waitForCall()
        #expect(controller.state == .transcribing(.insert))
        #expect(controller.engineInfo == DictationEngineInfo(displayName: provider.displayName, providerID: provider.id))
        #expect(await controller.discard() == .deleted)
        await finishing.value
        #expect(controller.state == .idle)
        #expect(controller.engineInfo == nil)
        #expect(spy.events.isEmpty)

        let systemEngine = SuspendedSTTEngine()
        let (systemController, _) = await makeController(engines: .resolving(
            settings: Self.freshSettings(), catalog: { nil }, providers: { [] }, makeSystem: { systemEngine }
        ))
        await record(systemController, seconds: 1)
        let systemFinishing = Task { await systemController.finish(.insert) }
        await systemEngine.waitForCall()
        #expect(systemController.state == .transcribing(.insert))
        #expect(systemController.engineInfo == nil)
        #expect(await systemController.discard() == .deleted)
        await systemFinishing.value
        #expect(lost.total == 0)
    }

    @Test("In interrupted / slotOccupied / failed pendingDurationSec = sidecar duration; nil in idle / recording")
    func pendingDurationFollowsSidecar() async throws {
        let (controller, _) = await makeController()
        #expect(controller.state == .idle)
        #expect(controller.pendingDurationSec == nil)

        await record(controller, seconds: 3)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(controller.pendingDurationSec == nil)

        postInterruptionBegan()
        #expect(controller.state == .interrupted)
        await controller.storeDrained()
        let sidecar = try #require(try store.slot(for: Self.slotKey)).durationSec
        #expect(abs(sidecar - 3) < 0.05)
        await controller.pendingDurationLoad?.value
        #expect(controller.pendingDurationSec == sidecar)

        await controller.micTapped()
        #expect(controller.state == .slotOccupied)
        await controller.pendingDurationLoad?.value
        #expect(controller.pendingDurationSec == sidecar)

        engine.outcome = .failure(URLError(.cannotConnectToHost))
        await controller.transcribeOccupied()
        #expect(controller.state == .failed(.retry))
        let failedSidecar = try #require(try store.slot(for: Self.slotKey)).durationSec
        await controller.pendingDurationLoad?.value
        #expect(controller.pendingDurationSec == failedSidecar)
        #expect(abs(failedSidecar - 3) < 0.05)

        #expect(await controller.discard() == .deleted)
        #expect(controller.pendingDurationSec == nil)
        #expect(lost.total == 0)
    }

    /// The slot store points at a temporary directory and file operations go through a thread-recording FileManager; returns the controller, store and recorder.
    private func makeThreadRecordedController(
        capture: AudioCapture? = nil,
        audioSession: VoiceAudioSessionOwner = .shared
    ) async throws -> (DictationController, RecordingStore, ThreadRecordingFileManager) {
        let files = ThreadRecordingFileManager()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DictationControllerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
        let lost = self.lost
        let store = try RecordingStore(root: root, onLost: { lost.total += $0 }, fileManager: files)
        let (controller, _) = await makeController(store: store, capture: capture, audioSession: audioSession)
        return (controller, store, files)
    }

    @Test("pendingDurationSec: the sidecar is read on the store queue (not the main thread) and published on the main thread when done")
    func pendingDurationLoadedOffMainThenPublished() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await record(controller, seconds: 3)
        var publishedOnMain: [Bool] = []
        let subscription = controller.$pendingDurationSec.dropFirst().sink { _ in
            publishedOnMain.append(Thread.isMainThread)
        }
        defer { subscription.cancel() }

        // Closing the file and updating the sidecar on interruption are also on the store queue (covered by another test); here only the duration reads afterwards are counted, and none may be on the main thread.
        postInterruptionBegan()
        files.reset()
        #expect(controller.state == .interrupted)
        let load = try #require(controller.pendingDurationLoad)
        await load.value

        let sidecar = try #require(store.peekSlot(for: Self.slotKey)).durationSec
        #expect(abs(sidecar - 3) < 0.05)
        #expect(controller.pendingDurationSec == sidecar)
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)
        #expect(publishedOnMain == [true])
        #expect(lost.total == 0)
    }

    @Test("Entering background: state switches to interrupted synchronously; closing the file and marking the sidecar interrupted run on the store queue (not the main thread), and the sidecar is interrupted when done")
    func background_interrupt_closes_file_off_main() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await record(controller, seconds: 1)
        await controller.storeDrained()

        // Another controller binds another slot on the same store: its occupancy query stalls on the shared store queue, so every wrap-up enqueued afterwards must queue behind it.
        files.holdNextOffMainCall()
        let blocker = DictationController(
            engines: .fixed(engine), system: .skipped, capture: FakeAudioCapture(sampleRate: Self.inputRate),
            store: store, permission: permission, readAloud: readAloud, screenAwake: screenAwake,
            notificationCenter: NotificationCenter(), now: { Date(timeIntervalSince1970: 1_000) },
            sleep: { _ in }
        )
        blocker.bind(slotKey: Self.otherKey)
        await files.waitUntilHeld()

        files.reset()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        // When the notification callback returns: capture has stopped and the state has moved on; the sidecar has not yet been rewritten by the main thread (the wrap-up is queued behind the stalled queue).
        #expect(controller.state == .interrupted)
        #expect(capture.stopCount == 1)
        #expect(store.peekSlot(for: Self.slotKey)?.status == .recording)
        #expect(files.mainThreadCalls == 0)

        files.releaseHeld()
        await blocker.bindLoad?.value
        await controller.storeDrained()
        let slot = try #require(store.peekSlot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 1) < 0.05)
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)
        #expect(lost.total == 0)
    }

    @Test("Tapping the mic with the slot occupied: the occupancy query is off the main thread, and slotOccupied is reached when it completes")
    func micTappedOccupiedCheckOffMain() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await leaveOccupiedSlot(controller)
        await controller.storeDrained()

        files.reset()
        await controller.micTapped()
        #expect(controller.state == .slotOccupied)
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)
        #expect(capture.startCount == 1)
        #expect(store.peekSlot(for: Self.slotKey)?.status == .interrupted)
        #expect(lost.total == 0)
    }

    @Test("Cancel (X) and early-committed discard: reading the sidecar and moving / deleting files are all off the main thread")
    func discardAndCommitOffMain() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await record(controller, seconds: 6)
        postInterruptionBegan()
        #expect(controller.state == .interrupted)
        await controller.storeDrained()

        files.reset()
        #expect(await controller.discard() == .undoable)
        #expect(controller.state == .idle)
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)
        #expect(store.peekSlot(for: Self.slotKey) == nil)
        await timer.waitForSleeps(1)
        let window = try #require(controller.undoWindowTask)

        files.reset()
        await controller.commitDiscard()
        await window.value
        #expect(controller.undoWindowTask == nil)
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)
        let discarded = try FileManager.default.contentsOfDirectory(at: store.discardRoot,
                                                                    includingPropertiesForKeys: nil)
        #expect(discarded.isEmpty)
        #expect(lost.total == 0)
    }

    @Test("Switching back after a slot switch, and undoing a discard: slot queries and file moves are off the main thread, with results landing in state on the main thread")
    func bindAndUndoOffMain() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await record(controller, seconds: 6)
        postInterruptionBegan()
        #expect(controller.state == .interrupted)
        await controller.storeDrained()

        files.reset()
        controller.bind(slotKey: Self.otherKey)
        controller.bind(slotKey: Self.slotKey)
        await controller.bindLoad?.value
        #expect(controller.state == .interrupted)
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)

        #expect(await controller.discard() == .undoable)
        files.reset()
        await controller.undoDiscard()
        #expect(controller.state == .interrupted)
        #expect(controller.undoWindowTask == nil)
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)
        let restored = try #require(store.peekSlot(for: Self.slotKey))
        #expect(abs(restored.durationSec - 6) < 0.05)
        #expect(audioExists(in: store))
        #expect(lost.total == 0)
    }

    @Test("Finish after recording silence: precheck finds silence, the slot-clearing write runs on the store queue, and the main thread never touches files")
    func silent_finish_no_main_thread_file_calls() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await record(controller, seconds: 3, amplitude: 0)
        await controller.storeDrained()
        files.reset()

        await controller.finish(.insert)
        #expect(controller.state == .idle)
        await controller.storeDrained()
        #expect(files.mainThreadCalls == 0)
        #expect(files.offMainCalls > 0)
        #expect(store.peekSlot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
    }

    @Test("Switching away and back to the same slot before the discard's file operations finish: bind sees the slot as it is after the discard, not the old recording")
    func bindAfterDiscardSeesNoStaleSlot() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await record(controller, seconds: 6)
        postInterruptionBegan()
        #expect(controller.state == .interrupted)
        await controller.storeDrained()
        // The duration read when entering interrupted is also on the store queue: wait for it to finish, so the one stalled below is the one inside the discard.
        await controller.pendingDurationLoad?.value

        // The next file operation on the store queue (the one inside the discard) stalls until released.
        files.holdNextOffMainCall()
        let discarding = Task { await controller.discard() }
        await files.waitUntilHeld()
        controller.bind(slotKey: Self.otherKey)
        controller.bind(slotKey: Self.slotKey)
        files.releaseHeld()

        #expect(await discarding.value == .undoable)
        await controller.bindLoad?.value
        #expect(controller.state == .idle)
        #expect(controller.pendingDurationSec == nil)
        #expect(store.peekSlot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
    }

    @Test("The start flow is voided while the slot open waits on the store queue -> capture stopped, the just-opened slot removed, state not rewritten")
    func test_startRecording_cancelledDuringOpen_leavesNoSlot() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        // Once capture is running, the next file operation on the store queue is the one inside the slot open: stall it.
        capture.onStart = { files.holdNextOffMainCall() }
        permission.status = .granted

        let tap = Task { await controller.micTapped() }
        await files.waitUntilHeld()
        #expect(capture.startCount == 1)
        controller.interrupt()
        files.releaseHeld()
        await tap.value
        await controller.storeDrained()

        #expect(controller.state == .idle)
        #expect(capture.stopCount == 1)
        #expect(store.peekSlot(for: Self.slotKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: Self.slotKey).path))
        #expect(lost.total == 0)
    }

    @Test("The start flow is voided during slot open and a voice conversation then claims the session: the old dictation's late stop does not deactivate the session, and the conversation lease remains")
    func test_cancelledDuringOpen_thenConversation_keepsSessionActive() async throws {
        let owner = VoiceAudioSessionOwner()
        let activator = RecordingSessionActivator()
        let input = FakeInputTap(sampleRate: Self.inputRate)
        let engineCapture = EngineAudioCapture(activator: activator, owner: owner, input: input)
        let (controller, store, files) = try await makeThreadRecordedController(capture: engineCapture, audioSession: owner)
        input.onStart = { files.holdNextOffMainCall() }
        permission.status = .granted

        let tap = Task { await controller.micTapped() }
        await files.waitUntilHeld()
        #expect(input.startCount == 1)
        #expect(owner.current?.client == .dictation)
        controller.interrupt()
        let conversation = owner.claim(.conversation)
        files.releaseHeld()
        await tap.value
        await controller.storeDrained()

        #expect(input.stopCount == 1)
        #expect(activator.calls == [.activate])
        #expect(owner.current == conversation)
        #expect(controller.state == .idle)
        #expect(store.peekSlot(for: Self.slotKey) == nil)
        #expect(lost.total == 0)
        #expect(owner.release(conversation))
    }

    @Test("Discarding again while the previous undo window is still open: tapping the mic between committing the old discard and the new discard, the occupancy query cannot see the recording pending deletion, and recording starts after the discard completes")
    func micTapBetweenCommitAndDiscardDoesNotSeeStaleSlot() async throws {
        let (controller, store, files) = try await makeThreadRecordedController()
        await record(controller, seconds: 6)
        postInterruptionBegan()
        #expect(await controller.discard() == .undoable)
        #expect(controller.undoWindowTask != nil)

        controller.bind(slotKey: Self.otherKey)
        await controller.bindLoad?.value
        await record(controller, seconds: 6)
        postInterruptionBegan()
        #expect(controller.state == .interrupted)
        await controller.storeDrained()

        // The new discard's first file operation (committing the previous one) stalls; tapping the mic now queues the query behind it.
        files.holdNextOffMainCall()
        let discarding = Task { await controller.discard() }
        await files.waitUntilHeld()
        // The mic-tap task signals as soon as it starts running; micTapped has no suspension point before it enqueues the occupancy query, and the main actor is serial,
        // so by the time this test wakes from that wait, the query has been enqueued (behind the stalled block). The store queue is stalled, so
        // the query's file calls only happen after release, and on the FileManager side there is no "arrived" signal to wait on.
        var tapping: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            tapping = Task {
                started.resume()
                await controller.micTapped()
            }
        }
        files.releaseHeld()

        #expect(await discarding.value == .undoable)
        await tapping?.value
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(store.peekSlot(for: Self.otherKey)?.status == .recording)
        _ = await controller.discard()
        #expect(lost.total == 0)
    }

    private func audioExists(in store: RecordingStore) -> Bool {
        FileManager.default.fileExists(atPath: store.audioURL(for: Self.slotKey).path)
    }

    @Test("denied -> dismissDenied() -> idle; no effect in other states")
    func dismissDeniedReturnsIdle() async throws {
        let (controller, _) = await makeController()
        controller.dismissDenied()
        #expect(controller.state == .idle)

        permission.status = .denied
        await controller.micTapped()
        #expect(controller.state == .denied(.microphone))
        controller.dismissDenied()
        #expect(controller.state == .idle)

        await record(controller, seconds: 1)
        controller.dismissDenied()
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(await controller.discard() == .deleted)
        #expect(lost.total == 0)
    }

    @Test("Cancel (X) while transcribing: the in-flight transcription is cancelled and no insert / send is emitted; over 5 s goes to the undo window")
    func discardWhileTranscribing() async throws {
        let suspended = SuspendedSTTEngine()
        let (controller, spy) = await makeController(engines: .fixed(suspended))
        await record(controller, seconds: 6)
        let finishing = Task { await controller.finish(.send) }
        await suspended.waitForCall()
        #expect(controller.state == .transcribing(.send))

        #expect(await controller.discard() == .undoable)
        await finishing.value
        #expect(suspended.cancelled)
        #expect(suspended.callCount == 1)
        #expect(spy.events.isEmpty)
        #expect(controller.state == .idle)
        #expect(try store.slot(for: Self.slotKey) == nil)

        await timer.waitForSleeps(1)
        #expect(timer.requested == [.seconds(4)])
        #expect(controller.undoWindowTask != nil)
        await controller.undoDiscard()
        #expect(controller.state == .interrupted)
        let restored = try #require(try store.slot(for: Self.slotKey))
        #expect(abs(restored.durationSec - 6) < 0.05)
        #expect(audioExists)
        #expect(spy.events.isEmpty)
        #expect(lost.total == 0)
    }

    // MARK: Live level and keeping the screen awake

    @Test("Feeding loud audio while recording -> levels non-empty with a peak above that of silence, at most 24 kept; cleared after leaving recording")
    func levelMeterTracksLoudness() async throws {
        let (controller, _) = await makeController()
        await record(controller, seconds: 1, amplitude: 0)
        let silent = controller.levelMeter.levels
        #expect(!silent.isEmpty)
        #expect(silent.allSatisfy { $0 == 0 })

        capture.feed(seconds: 1, amplitude: 0.5)
        let loud = try #require(controller.levelMeter.levels.max())
        #expect(loud > (silent.max() ?? 0))
        #expect(loud <= 1)

        capture.feed(seconds: 3, amplitude: 0.5)
        #expect(controller.levelMeter.levels.count == DictationLevelMeter.capacity)

        _ = await controller.discard()
        #expect(controller.state == .idle)
        #expect(controller.levelMeter.levels.isEmpty)
        #expect(lost.total == 0)
    }

    @Test("Level refreshes do not trigger the controller's objectWillChange")
    func levelUpdatesDoNotChangeController() async {
        let (controller, _) = await makeController()
        await record(controller, seconds: 0.2)
        let controllerChanges = ChangeCounter()
        let meterChanges = ChangeCounter()
        let controllerSink = controller.objectWillChange.sink { controllerChanges.count += 1 }
        let meterSink = controller.levelMeter.objectWillChange.sink { meterChanges.count += 1 }

        capture.feed(seconds: 1, amplitude: 0.3)
        #expect(meterChanges.count > 0)
        #expect(controllerChanges.count == 0)
        controllerSink.cancel()
        meterSink.cancel()
    }

    @Test("The screen stays awake while recording; after transcribe / interruption / discard the previous value is restored",
          arguments: DictationRecordingExit.allCases, [false, true])
    func idleTimerOnlyWhileRecording(exit: DictationRecordingExit, prior: Bool) async {
        idleTimer.isIdleTimerDisabled = prior
        let (controller, _) = await makeController()
        engine.outcome = .success("done")
        #expect(idleTimer.isIdleTimerDisabled == prior)

        await record(controller, seconds: 1)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(idleTimer.isIdleTimerDisabled)

        switch exit {
        case .finish:
            await controller.finish(.insert)
            #expect(controller.state == .idle)
        case .interrupt:
            postInterruptionBegan()
            #expect(controller.state == .interrupted)
        case .discard:
            _ = await controller.discard()
            #expect(controller.state == .idle)
        }
        #expect(idleTimer.isIdleTimerDisabled == prior)
        #expect(lost.total == 0)
    }

    @Test("The NotificationCenter observer is removed when the instance is released: notifications posted after release no longer fire")
    func notificationObserversRemovedOnDeinit() {
        let spyCenter = ObserverCountingCenter()
        weak var released: DictationController?
        do {
            let controller = DictationController(
                engines: .fixed(engine), system: .skipped, capture: capture, store: store,
                permission: permission, readAloud: readAloud, screenAwake: screenAwake, notificationCenter: spyCenter
            )
            released = controller
            #expect(spyCenter.added.count == 3)
        }
        #expect(released == nil)
        #expect(spyCenter.removed == spyCenter.added.count)
        spyCenter.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        spyCenter.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(spyCenter.fired == 0)
    }

    // MARK: VoiceConnection(provider:)

    @Test("VoiceConnection(provider:): subscription is not listed; empty apiKey -> hasKey false")
    func voiceConnectionFromProvider() {
        var subscription = TestFactories.makeProvider(kind: .openAI, apiKey: "sk-live")
        subscription.authMode = .subscription
        let empty = TestFactories.makeProvider(kind: .relay, apiKey: "")
        let usable = TestFactories.makeProvider(kind: .relay, apiKey: "sk-voice")

        let connections = [subscription, empty, usable].map(VoiceConnection.init(provider:))
        #expect(connections.map(\.id) == [subscription, empty, usable].map(\.id.uuidString))
        #expect(connections[0].authMode == .subscription)
        #expect(!connections[0].isUsable)
        #expect(connections[1].hasKey == false)
        #expect(connections[2].hasKey && connections[2].isUsable)

        let catalog = VoiceCatalog(schemaVersion: 2, revision: "r1", providers: [
            .openAI: Self.catalog(models: ["gpt-4o-transcribe"]).providers[.relay]!,
            .relay: Self.catalog(models: [Self.cloudModel]).providers[.relay]!,
        ])
        let options = VoiceEngineResolver.options(direction: .stt, catalog: catalog, connections: connections)
        #expect(options == [
            .system,
            .cloud(providerKind: .relay, connectionID: usable.id.uuidString, model: Self.cloudModel, isDefault: true),
        ])
    }
}

// MARK: - Test doubles

/// Records whether each file operation is called on the main thread (the RecordingStore fileManager test seam).
private nonisolated final class ThreadRecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var offMain = 0

    var mainThreadCalls: Int { lock.withLock { main } }
    var offMainCalls: Int { lock.withLock { offMain } }

    /// The stalled call: once armed, the next off-main call waits here for release and notifies waitUntilHeld.
    private var armed = false
    private var held = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private let release = DispatchSemaphore(value: 0)

    func reset() { lock.withLock { main = 0; offMain = 0 } }

    func holdNextOffMainCall() { lock.withLock { armed = true } }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if held { return true }
                heldWaiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseHeld() { release.signal() }

    private func record() {
        let isMain = Thread.isMainThread
        let (hold, waiter) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            if isMain { main += 1 } else { offMain += 1 }
            guard !isMain, armed else { return (false, nil) }
            armed = false
            held = true
            defer { heldWaiter = nil }
            return (true, heldWaiter)
        }
        guard hold else { return }
        waiter?.resume()
        release.wait()
    }

    override func fileExists(atPath path: String) -> Bool {
        record()
        return super.fileExists(atPath: path)
    }

    override func removeItem(at url: URL) throws {
        record()
        try super.removeItem(at: url)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        record()
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class LostCounter {
    var total = 0
}

private final class ChangeCounter {
    var count = 0
}

nonisolated enum DictationRecordingExit: CaseIterable, Sendable {
    case finish
    case interrupt
    case discard
}

/// A NotificationCenter that records addObserver / removeObserver; fired counts how many times a still-registered observer fired.
nonisolated final class ObserverCountingCenter: NotificationCenter, @unchecked Sendable {
    private(set) var added: [NSObjectProtocol] = []
    private(set) var removed = 0
    private(set) var fired = 0

    override func addObserver(
        forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue) { [weak self] note in
            self?.fired += 1
            block(note)
        }
        added.append(token)
        return token
    }

    override func removeObserver(_ observer: Any) {
        if added.contains(where: { $0 === observer as AnyObject }) { removed += 1 }
        super.removeObserver(observer)
    }
}

final class FakeIdleTimer: ScreenIdleTimer {
    var isIdleTimerDisabled = false
}

private final class EventSpy {
    var events: [DictationEvent] = []
}

/// A manually advanced timer: sleep suspends until advance passes the deadline; it throws CancellationError when cancelled.
/// The undo-window timer registers inside a Task the controller starts, so tests first waitForSleeps until it is registered, then advance.
private nonisolated final class ManualTimer: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var waiters: [Waiter] = []
    private var _requested: [Duration] = []
    private var sleepWaiters: [(id: UUID, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var requested: [Duration] { lock.withLock { _requested } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (cancelled, reached) = lock.withLock {
                    _requested.append(duration)
                    let reached = sleepWaiters.filter { $0.count <= _requested.count }.map(\.continuation)
                    sleepWaiters.removeAll { $0.count <= _requested.count }
                    if Task.isCancelled { return (true, reached) }
                    waiters.append(Waiter(id: id, deadline: elapsed + duration, continuation: continuation))
                    return (false, reached)
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                for waiter in reached { waiter.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits until sleep has been registered count times in total; returns immediately when the task it runs in is cancelled (timeLimit fired), so the host is not held.
    func waitForSleeps(_ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let reached = lock.withLock { () -> Bool in
                    if _requested.count >= count || Task.isCancelled { return true }
                    sleepWaiters.append((id, count, continuation))
                    return false
                }
                if reached { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = sleepWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepWaiters.remove(at: index).continuation
            }
            waiter?.resume()
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Waiter] in
            elapsed += duration
            let due = waiters.filter { $0.deadline <= elapsed }
            waiters.removeAll { $0.deadline <= elapsed }
            return due
        }
        for waiter in due { waiter.continuation.resume() }
    }
}

nonisolated final class FakeSTTEngine: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: Result<String, Error> = .success("text")
    private var _calls: [RecordingResult] = []

    var outcome: Result<String, Error> {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }

    var calls: [RecordingResult] { lock.withLock { _calls } }

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        let outcome = lock.withLock {
            _calls.append(recording)
            return _outcome
        }
        return try outcome.get()
    }
}

/// Transcription hangs until cancelled: waitForCall waits until the engine is called; when cancelled it throws CancellationError and records it.
private nonisolated final class SuspendedSTTEngine: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<String, Error>?
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var _callCount = 0
    private var _cancelled = false

    var callCount: Int { lock.withLock { _callCount } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let (cancelledNow, waiters) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    _callCount += 1
                    let waiters = callWaiters
                    callWaiters = []
                    if Task.isCancelled {
                        _cancelled = true
                        return (true, waiters)
                    }
                    pending = continuation
                    return (false, waiters)
                }
                if cancelledNow { continuation.resume(throwing: CancellationError()) }
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
                _cancelled = true
                defer { pending = nil }
                return pending
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Waits until the engine has been called at least once; when it hangs, the suite's timeLimit is the backstop.
    func waitForCall() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = lock.withLock { () -> Bool in
                if _callCount > 0 { return true }
                callWaiters.append(continuation)
                return false
            }
            if reached { continuation.resume() }
        }
    }
}

/// Does not touch the microphone: start records the handler and returns the tap format; feed synchronously feeds a 440 Hz sine (amplitude 0 is all zeros).
nonisolated final class FakeAudioCapture: AudioCapture {
    let inputFormat: AVAudioFormat
    /// When non-nil, simulates the input format changing after the session activates: start returns it, and buffers are then fed in that format.
    var formatAfterStart: AVAudioFormat?
    private(set) var tapFormat: AVAudioFormat
    private var handlers: [AudioBufferHandler] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(sampleRate: Double) {
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                    channels: 1, interleaved: false)!
        tapFormat = inputFormat
    }

    /// Called the moment capture is running (before the slot opens): tests use it to stage a stall in file operations before the slot opens.
    var onStart: (() -> Void)?

    func start(handlers: [AudioBufferHandler]) throws -> AVAudioFormat {
        startCount += 1
        onStart?()
        self.handlers = handlers
        tapFormat = formatAfterStart ?? inputFormat
        return tapFormat
    }

    func stop() {
        stopCount += 1
        handlers = []
    }

    /// When format is nil, feeds in the tap format; pass another format to simulate the writer's append failing.
    func feed(seconds: Double, amplitude: Float, format: AVAudioFormat? = nil) {
        let format = format ?? tapFormat
        let rate = format.sampleRate
        let chunk = Int(rate / 10)
        let total = Int(seconds * rate)
        var position = 0
        while position < total {
            let frames = min(chunk, total - position)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                let value = amplitude * Float(sin(2 * Double.pi * 440 * Double(position + frame) / rate))
                for channel in 0..<Int(format.channelCount) {
                    buffer.floatChannelData![channel][frame] = value
                }
            }
            let time = AVAudioTime(sampleTime: AVAudioFramePosition(position), atRate: rate)
            for handler in handlers { handler(buffer, time) }
            position += frames
        }
    }
}

final class FakeMicrophonePermission: MicrophonePermission {
    var status: MicrophonePermissionStatus = .granted
    var answer = true
    private(set) var requestCount = 0

    func request() async -> Bool {
        requestCount += 1
        if answer { status = .granted } else { status = .denied }
        return answer
    }
}

final class SilentSpeechEngine: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice = true
    func speak(_ utterances: [SpeechUtterance]) {}
    func stop() {}
}

final class SilentReadAloudPlatform: ReadAloudPlatform {
    var uiLanguage = "en"
    func activateAudioSession() throws {}
    func deactivateAudioSession() {}
    func localizedVoiceString(_ key: String, locale: String) -> String { key }
    func showToast(_ toast: ReadAloudToast) {}
}

private nonisolated final class DictationSpeechAuthorizerFake: SpeechAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorized = false
    private var _undetermined = true
    private var _answer = true
    private var _requestCount = 0

    /// The user already answered before (granted / refused): later requests no longer prompt.
    func settle(authorized: Bool) {
        lock.withLock {
            _authorized = authorized
            _undetermined = false
        }
    }

    var isUndetermined: Bool { lock.withLock { _undetermined } }

    var answer: Bool {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    var requestCount: Int { lock.withLock { _requestCount } }

    var isAuthorized: Bool { lock.withLock { _authorized } }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _requestCount += 1
            _authorized = _answer
            _undetermined = false
            return _answer
        }
    }
}

/// Installing first reports 0.5 progress, then stalls until finishInstall.
private nonisolated final class DictationAssetInventoryFake: SpeechAssetInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var _installed = false
    private var _installCount = 0
    private let gate: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation

    init() {
        (gate, release) = AsyncStream.makeStream(of: Void.self)
    }

    var installed: Bool {
        get { lock.withLock { _installed } }
        set { lock.withLock { _installed = newValue } }
    }

    var installCount: Int { lock.withLock { _installCount } }

    func finishInstall() { release.yield() }

    func maximumReservedLocales() async -> Int { 0 }
    func reservedLocales() async -> [Locale] { [] }
    func reserve(_ locale: Locale) async throws {}
    func release(_ locale: Locale) async {}
    func isInstalled(_ module: SpeechAssetModule, locale: Locale) async -> Bool { installed }

    func install(
        _ module: SpeechAssetModule,
        locale: Locale,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        lock.withLock { _installCount += 1 }
        await progress(0.5)
        for await _ in gate { break }
        installed = true
    }
}
