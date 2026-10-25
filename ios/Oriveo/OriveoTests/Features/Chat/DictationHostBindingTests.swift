import Foundation
import Testing
@testable import Oriveo

/// Host binding and event routing. A real controller + a real RecordingStore (temporary directory);
/// events arrive through the production closure that attach installs on the controller's onEvent.
@Suite("Dictation host binding", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DictationHostBindingTests {

    private static let slotKey = "conversation-a"
    private static let otherKey = "conversation-b"

    private let store: RecordingStore

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DictationHostBindingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
        store = try RecordingStore(root: root, onLost: { _ in })
    }

    private func makeController(
        engine: any STTEngine = FakeSTTEngine(),
        capture: FakeAudioCapture = FakeAudioCapture(sampleRate: 48_000)
    ) -> DictationController {
        DictationController(
            engines: .fixed(engine), system: .skipped,
            capture: capture, store: store,
            permission: FakeMicrophonePermission(),
            readAloud: ReadAloudController(
                engine: SilentSpeechEngine(), platform: SilentReadAloudPlatform(),
                notificationCenter: NotificationCenter(), detectLanguage: { _ in "en" }
            ),
            screenAwake: ScreenAwakeHolds(timer: FakeIdleTimer()), notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    /// Host callbacks, recorded in order.
    private final class HostLog {
        var entries: [String] = []
        var toasts: [DictationToast] = []
    }

    private func makeHost(_ log: HostLog, canSend: Bool = true, tag: String = "") -> DictationHostBinding {
        DictationHostBinding(
            canSend: { canSend },
            onInsert: { log.entries.append("\(tag)insert:\($0)") },
            onSend: { log.entries.append("\(tag)send") },
            toast: { log.toasts.append($0) }
        )
    }

    @Test("after attach the controller is bound to the host key")
    func attachBindsSlot() {
        let controller = makeController()
        let host = makeHost(HostLog())
        host.attach(controller: controller, slotKey: Self.slotKey)
        #expect(controller.slotKey == Self.slotKey)
        #expect(controller.state == .idle)
    }

    @Test("changing the key rebinds")
    func reattachRebinds() {
        let controller = makeController()
        let host = makeHost(HostLog())
        host.attach(controller: controller, slotKey: Self.slotKey)
        host.attach(controller: controller, slotKey: Self.otherKey)
        #expect(controller.slotKey == Self.otherKey)
    }

    @Test("an insert event is handed to the host's insert closure")
    func insertRoutesToHost() {
        let controller = makeController()
        let log = HostLog()
        let host = makeHost(log)
        host.attach(controller: controller, slotKey: Self.slotKey)
        withExtendedLifetime(host) { controller.onEvent?(.insert("hello world")) }
        #expect(log.entries == ["insert:hello world"])
        #expect(log.toasts.isEmpty)
    }

    @Test("send when sendable: insert first, then send")
    func sendWhenSendableInsertsThenSends() {
        let controller = makeController()
        let log = HostLog()
        let host = makeHost(log, canSend: true)
        host.attach(controller: controller, slotKey: Self.slotKey)
        withExtendedLifetime(host) { controller.onEvent?(.send("ship it")) }
        #expect(log.entries == ["insert:ship it", "send"])
    }

    @Test("send when not sendable: insert only")
    func sendWhenNotSendableOnlyInserts() {
        let controller = makeController()
        let log = HostLog()
        let host = makeHost(log, canSend: false)
        host.attach(controller: controller, slotKey: Self.slotKey)
        withExtendedLifetime(host) { controller.onEvent?(.send("ship it")) }
        #expect(log.entries == ["insert:ship it"])
    }

    @Test("noSpeechHeard and engineFallback show the matching toast")
    func toastsForNoSpeechAndFallback() {
        let controller = makeController()
        let log = HostLog()
        let host = makeHost(log)
        host.attach(controller: controller, slotKey: Self.slotKey)
        withExtendedLifetime(host) {
            controller.onEvent?(.noSpeechHeard)
            controller.onEvent?(.engineFallback(.keyMissing))
        }
        #expect(log.toasts.map(\.message) == [
            L10n.tr("Didn't hear anything", table: .voice),
            L10n.tr("The selected dictation engine is unavailable. Using system dictation.", table: .voice),
        ])
        #expect(log.toasts.allSatisfy { $0.undoTitle == nil })
        #expect(log.entries.isEmpty)
    }

    @Test("a host attached later takes over events, the earlier host no longer receives them")
    func laterHostTakesOver() {
        let controller = makeController()
        let log = HostLog()
        let chat = makeHost(log, tag: "chat-")
        let home = makeHost(log, tag: "home-")
        chat.attach(controller: controller, slotKey: Self.slotKey)
        home.attach(controller: controller, slotKey: "home-draft")
        withExtendedLifetime((chat, home)) { controller.onEvent?(.insert("x")) }
        #expect(controller.slotKey == "home-draft")
        #expect(log.entries == ["home-insert:x"])
    }

    // MARK: taking over on mic tap, and wrapping up when the host leaves

    @Test("a host attached earlier activates: the slot and event receiver return to it")
    func activateReclaimsSlotAndEvents() {
        let controller = makeController()
        let log = HostLog()
        let chat = makeHost(log, tag: "chat-")
        let home = makeHost(log, tag: "home-")
        chat.attach(controller: controller, slotKey: Self.slotKey)
        home.attach(controller: controller, slotKey: "home-draft")
        chat.activate()
        withExtendedLifetime((chat, home)) { controller.onEvent?(.insert("x")) }
        #expect(controller.slotKey == Self.slotKey)
        #expect(log.entries == ["chat-insert:x"])
    }

    @Test("host of this key detaches while recording: sidecar interrupted, recording kept, onEvent cleared")
    func detachWhileRecordingInterrupts() async throws {
        let capture = FakeAudioCapture(sampleRate: 48_000)
        let controller = makeController(capture: capture)
        let host = makeHost(HostLog())
        host.attach(controller: controller, slotKey: Self.slotKey)
        await controller.micTapped()
        capture.feed(seconds: 1, amplitude: 0.1)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))

        host.detach()
        #expect(controller.state == .interrupted)
        #expect(capture.stopCount == 1)
        // Marking the sidecar interrupted and persisting the duration happen on the store queue: wait for the queue before inspecting the sidecar.
        await controller.storeDrained()
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 1) < 0.05)
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: Self.slotKey).path))
        #expect(controller.onEvent == nil)
    }

    @Test("host of this key detaches while transcribing: transcription cancelled, sidecar interrupted, recording kept, onEvent cleared")
    func detachWhileTranscribingInterrupts() async throws {
        let engine = HangingSTTEngine()
        let capture = FakeAudioCapture(sampleRate: 48_000)
        let controller = makeController(engine: engine, capture: capture)
        let log = HostLog()
        let host = makeHost(log)
        host.attach(controller: controller, slotKey: Self.slotKey)
        await controller.micTapped()
        capture.feed(seconds: 2, amplitude: 0.1)
        let finishing = Task { await controller.finish(.insert) }
        await engine.waitForCall()
        #expect(controller.state == .transcribing(.insert))

        host.detach()
        await finishing.value
        #expect(engine.cancelled)
        #expect(controller.state == .interrupted)
        // Marking the sidecar interrupted happens on the store queue: wait for the queue before inspecting the sidecar.
        await controller.storeDrained()
        let slot = try #require(try store.slot(for: Self.slotKey))
        #expect(slot.status == .interrupted)
        #expect(abs(slot.durationSec - 2) < 0.05)
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: Self.slotKey).path))
        #expect(controller.onEvent == nil)
        #expect(log.entries.isEmpty)
    }

    @Test("controller bound to another key: detach touches neither the recording nor onEvent")
    func detachOnOtherKeyLeavesControllerAlone() async throws {
        let capture = FakeAudioCapture(sampleRate: 48_000)
        let controller = makeController(capture: capture)
        let log = HostLog()
        let chat = makeHost(log, tag: "chat-")
        let home = makeHost(log, tag: "home-")
        chat.attach(controller: controller, slotKey: Self.slotKey)
        home.attach(controller: controller, slotKey: Self.otherKey)
        await controller.micTapped()
        capture.feed(seconds: 1, amplitude: 0.1)

        chat.detach()
        #expect(controller.slotKey == Self.otherKey)
        #expect(controller.state == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(capture.stopCount == 0)
        withExtendedLifetime((chat, home)) { controller.onEvent?(.insert("x")) }
        #expect(log.entries == ["home-insert:x"])
    }

    @Test("a later host of the same key took over events: an earlier host's detach does not clear its onEvent")
    func detachKeepsOtherHostsHandler() {
        let controller = makeController()
        let log = HostLog()
        let first = makeHost(log, tag: "first-")
        let second = makeHost(log, tag: "second-")
        first.attach(controller: controller, slotKey: Self.slotKey)
        second.attach(controller: controller, slotKey: Self.slotKey)
        first.detach()
        withExtendedLifetime((first, second)) { controller.onEvent?(.insert("x")) }
        #expect(log.entries == ["second-insert:x"])
    }
}

/// Transcription hangs until cancelled; waitForCall waits until the engine has been called.
private nonisolated final class HangingSTTEngine: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var _cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var cancelled: Bool { lock.withLock { _cancelled } }

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            called = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
        do {
            try await Task.sleep(for: .seconds(600))
        } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
        return "unreachable"
    }

    func waitForCall() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = lock.withLock { () -> Bool in
                if called { return true }
                waiters.append(continuation)
                return false
            }
            if reached { continuation.resume() }
        }
    }
}
