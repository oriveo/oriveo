import Combine
import Foundation
import Testing
import UIKit
@testable import Oriveo
import OriveoProviderKit

/// Drives VoiceConversationController with fake audio / recognition / chat / read-aloud; no case makes any sound.
@Suite("Voice conversation controller", .serialized, .sharedProcessState)
@MainActor
struct VoiceConversationControllerTests {

    private let audio = FakeConversationAudio()
    private let stt = ScriptedSTT()
    private let chat = FakeVoiceChatPort()
    private let clock = ManualVoiceClock()
    private let defaults = UserDefaults(suiteName: "VoiceConversationControllerTests-\(UUID().uuidString)")!
    private let readAloudStops = Counter()
    private let frame = FrameCursor()

    private static func promptText(_ prompt: VoicePrompt) -> String {
        switch prompt {
        case .didNotCatch: return "PROMPT didNotCatch"
        case .approvalNeeded: return "PROMPT approvalNeeded"
        case .placeholder(let kind): return "PROMPT \(kind.rawValue)"
        }
    }

    private func makeController(
        readAloud: ReadAloudEngineSource = .fixed(ConversationSilentSpeechEngine()), osMajor: Int = 27
    ) -> VoiceConversationController {
        let stops = readAloudStops
        return VoiceConversationController(
            audio: audio,
            dictation: .fixed(stt, isSystem: true),
            readAloud: readAloud,
            chat: chat,
            prompt: Self.promptText,
            clock: clock,
            memory: VoiceBargeInMemory(defaults: defaults, osMajorVersion: osMajor),
            stopReadAloud: { stops.value += 1 },
            detectLanguage: { _ in "en" }
        )
    }

    private func settle() async {
        for _ in 0..<60 { await Task.yield() }
    }

    /// Feeds count frames of db; the clock advances 20 ms per frame.
    private func feed(_ controller: VoiceConversationController, _ db: Double, _ count: Int) {
        for _ in 0..<count {
            controller.conversationAudio(didCaptureFrame: frame.next, db: db)
            frame.next += 1
            clock.nowMs += 20
        }
    }

    /// 400 ms of voice + 600 ms of silence gives speechEnd.
    private func utterance(_ controller: VoiceConversationController) {
        feed(controller, -30, 20)
        feed(controller, -60, 30)
    }

    /// Listening, then speak one utterance, transcribe, send; returns in the thinking state.
    private func firstTurn(_ controller: VoiceConversationController, text: String = "question") async {
        stt.script.append(.success(text))
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
    }

    /// While the speaker is talking: pass the 1 s playback grace, then 400 ms of voice + 600 ms of silence.
    private func bargeIn(_ controller: VoiceConversationController, gracePassed: Bool = false) {
        if !gracePassed { feed(controller, -60, 50) }
        feed(controller, -30, 20)
        feed(controller, -60, 30)
    }

    // MARK: - A full turn

    @Test("full turn: listen, transcribe, send, speak closed sentences, back to listening")
    func fullTurn() async throws {
        let controller = makeController()
        try controller.start()
        #expect(readAloudStops.value == 1)
        #expect(audio.started == 1)
        #expect(controller.displayState == .listening)

        await firstTurn(controller, text: "what's the weather")
        #expect(chat.sent == ["what's the weather"])
        #expect(controller.displayState == .thinking)
        #expect(stt.calls == 1)

        audio.holdPlayback = true
        chat.emit(.text("First sentence. Second"))
        await settle()
        #expect(controller.displayState == .speaking)
        #expect(audio.spoken == ["First sentence."])

        chat.emit(.text("First sentence. Second sentence. Third"))
        await settle()
        #expect(audio.spoken == ["First sentence."])
        audio.completeCurrent()
        await settle()
        #expect(audio.spoken == ["First sentence.", "Second sentence."])

        chat.emit(.text("First sentence. Second sentence. Third one"))
        chat.emit(.completed)
        await settle()
        audio.completeCurrent()
        await settle()
        #expect(audio.spoken == ["First sentence.", "Second sentence.", "Third one"])
        #expect(controller.displayState == .speaking)
        audio.completeCurrent()
        await settle()
        #expect(controller.displayState == .listening)
        #expect(controller.statusKey == .listening)
    }

    @Test("only closed sentences are enqueued while streaming")
    func onlyClosedSentences() async throws {
        let controller = makeController()
        try controller.start()
        await firstTurn(controller)
        chat.emit(.text("Hello there. How are"))
        await settle()
        chat.emit(.text("Hello there. How are you"))
        await settle()
        #expect(audio.spoken == ["Hello there."])
        chat.emit(.completed)
        await settle()
        #expect(audio.spoken == ["Hello there.", "How are you"])
        #expect(controller.displayState == .listening)
    }

    // MARK: - Barge-in

    /// Starts a turn and stops while the first sentence is playing.
    private func speakingTurn(_ controller: VoiceConversationController, reply: String) async {
        await firstTurn(controller)
        audio.holdPlayback = true
        chat.emit(.text(reply))
        await settle()
    }

    @Test("speaker echo barge-in resumes from sentence start without sending")
    func speakerEchoResumes() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        #expect(controller.displayState == .speaking)

        stt.script.append(.success("the weather is nice"))
        bargeIn(controller)
        #expect(audio.pauses == 1)
        await settle()
        #expect(audio.resumes == [true])
        #expect(chat.sent == ["question"])
        #expect(chat.cancels == 0)
        #expect(controller.statusKey == .speaking)
    }

    @Test("speech inside the 1 s playback grace on speaker is not a barge-in")
    func speakerGrace() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        feed(controller, -30, 45)
        feed(controller, -60, 40)
        await settle()
        #expect(audio.pauses == 0)
        #expect(stt.calls == 1)
    }

    /// One false barge-in caused by the speaker's own echo.
    private func falseBargeIn(_ controller: VoiceConversationController) async {
        stt.script.append(.success("the weather is nice"))
        bargeIn(controller)
        await settle()
    }

    @Test("two false barge-ins switch to tap-to-interrupt; two such conversations are remembered on device")
    func falseBargeInsRemembered() async throws {
        audio.route = .speaker
        for round in 0..<2 {
            let controller = makeController()
            try controller.start()
            frame.next = 0
            await speakingTurn(controller, reply: "The weather is nice today. More")
            await falseBargeIn(controller)
            #expect(controller.statusKey == .speaking)
            await falseBargeIn(controller)
            #expect(controller.statusKey == .speakingTapToInterrupt, "round \(round)")
            // Voice barge-in is off: speaking again does not pause
            let pauses = audio.pauses
            bargeIn(controller)
            #expect(audio.pauses == pauses)
            controller.end(.system)
            await settle()
            audio.holdPlayback = false
        }
        #expect(VoiceBargeInMemory(defaults: defaults, osMajorVersion: 27).remembersNoSpeakerBargeIn)
        // Once remembered, a new conversation starts in "tap to interrupt" as soon as it begins speaking
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        #expect(controller.statusKey == .speakingTapToInterrupt)
        // Cleared when the major OS version changes
        #expect(!VoiceBargeInMemory(defaults: defaults, osMajorVersion: 28).remembersNoSpeakerBargeIn)
    }

    @Test("real barge-in cancels generation and sends the new utterance")
    func realBargeIn() async throws {
        audio.route = .headphones
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        stt.script.append(.success("change the topic please"))
        bargeIn(controller, gracePassed: true)
        await settle()
        #expect(chat.cancels == 1)
        #expect(chat.sent == ["question", "change the topic please"])
        #expect(audio.stops >= 1)
        #expect(controller.displayState == .thinking)
    }

    // MARK: - Recognition failure, approval, errors, idle

    @Test("STT failure retries once then says didNotCatch and listens again")
    func sttRetryThenDidNotCatch() async throws {
        let controller = makeController()
        try controller.start()
        stt.script = [.failure(FakeSTTFailure()), .failure(FakeSTTFailure())]
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        #expect(stt.calls == 2)
        #expect(audio.spoken == ["PROMPT didNotCatch"])
        #expect(chat.sent.isEmpty)
        #expect(controller.displayState == .listening)
    }

    @Test("approval pending shows awaitingApproval, speaks a prompt and pauses timers")
    func approvalPauses() async throws {
        let controller = makeController()
        try controller.start()
        await firstTurn(controller)
        chat.emit(.approvalPending(true))
        await settle()
        #expect(controller.displayState == .awaitingApproval)
        #expect(audio.spoken == ["PROMPT approvalNeeded"])
        clock.advance(130_000)
        #expect(audio.earcons.isEmpty)
        #expect(controller.isActive)
        controller.tapOrb()
        #expect(chat.cancels == 0)
        chat.emit(.approvalPending(false))
        await settle()
        #expect(controller.displayState == .thinking)
    }

    @Test("reply failure ends the conversation with error")
    func replyFailureEnds() async throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        controller.onEnded = { ended.append($0) }
        try controller.start()
        await firstTurn(controller)
        chat.emit(.failed(code: "network"))
        await settle()
        #expect(controller.displayState == .error)
        #expect(ended == [VoiceConversationEnd(reason: .error, code: "network", draft: nil)])
        #expect(audio.stopped == 1)
        #expect(!controller.isActive)
    }

    @Test("closing while VAD says speaking but nothing is recording ends without a pending draft")
    func close_without_speech_no_spurious_draft_pending() async throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        var drafts: [String?] = []
        controller.onEnded = { ended.append($0) }
        controller.onDraft = { drafts.append($0) }
        try controller.start()
        // A suspended io finish makes no difference: a segment that is not recording never goes through io.
        audio.holdRecordings = true
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        #expect(controller.state.userSpeaking)
        audio.utteranceOpen = false

        controller.end(.user)
        #expect(ended == [VoiceConversationEnd(reason: .user, code: nil, draft: nil)])
        #expect(!controller.isActive)

        audio.deliverRecordings()
        await settle()
        #expect(drafts.isEmpty)
        #expect(stt.calls == 0)
        #expect(ended.count == 1)
    }

    @Test("system clock: after fires once; a cancelled timer never fires", .timeLimit(.minutes(1)))
    func system_clock_after_fires_once_and_cancel_prevents() async throws {
        let clock = SystemVoiceConversationClock()
        let fired = Counter()
        let cancelled = Counter()
        let startMs = clock.nowMs
        let timer = clock.after(ms: 20) { fired.value += 1 }
        let doomed = clock.after(ms: 20) { cancelled.value += 1 }
        doomed.cancel()
        #expect(fired.value == 0)

        try await Task.sleep(for: .milliseconds(200))
        #expect(fired.value == 1)
        #expect(cancelled.value == 0)
        #expect(clock.nowMs - startMs >= 20)

        // Cancelling after it has fired has no side effect and it never fires again.
        timer.cancel()
        try await Task.sleep(for: .milliseconds(60))
        #expect(fired.value == 1)
        #expect(cancelled.value == 0)
    }

    @Test("closing mid-utterance ends at once; the draft transcript arrives later on its own")
    func close_with_draft_ends_immediately_then_delivers_draft() async throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        var drafts: [String?] = []
        controller.onEnded = { ended.append($0) }
        controller.onDraft = { drafts.append($0) }
        try controller.start()
        stt.script.append(.success("half a sentence"))
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        #expect(controller.state.userSpeaking)

        controller.end(.user)
        #expect(ended == [VoiceConversationEnd(reason: .user, code: nil, draft: nil, draftPending: true)])
        #expect(!controller.isActive)
        #expect(audio.stopped == 1)
        #expect(drafts.isEmpty)
        // The draft is still being transcribed, and the conversation can already be restarted.
        try controller.start()
        #expect(controller.isActive)

        await settle()
        #expect(drafts == ["half a sentence"])
        #expect(stt.calls == 1)
        #expect(ended.count == 1)
    }

    @Test("transcription waits until the recording finishes on the io queue")
    func transcribe_waits_for_recording_finish() async throws {
        let controller = makeController()
        try controller.start()
        audio.holdRecordings = true
        stt.script.append(.success("delayed"))
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        // vadSpeechEnd has been dispatched: it enters thinking first and does not transcribe before the recording is delivered.
        #expect(controller.displayState == .thinking)
        #expect(stt.calls == 0)
        #expect(chat.sent.isEmpty)

        audio.deliverRecordings()
        await settle()
        #expect(stt.calls == 1)
        #expect(chat.sent == ["delayed"])
    }

    @Test("unawaited_segment_file_removed_off_main")
    func unawaited_segment_file_removed_off_main() async throws {
        let files = RemovalRecordingFileManager()
        let controller = VoiceConversationController(
            audio: audio,
            dictation: .fixed(stt, isSystem: true),
            readAloud: .fixed(ConversationSilentSpeechEngine()),
            chat: chat,
            prompt: Self.promptText,
            clock: clock,
            memory: VoiceBargeInMemory(defaults: defaults, osMajorVersion: 27),
            stopReadAloud: {},
            detectLanguage: { _ in "en" },
            segmentFiles: files
        )
        try controller.start()
        audio.holdRecordings = true
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        #expect(controller.displayState == .thinking)

        // The conversation ended: nobody is waiting for this segment any more; once it is finished and delivered on io, it is deleted right away.
        controller.end(.user)
        audio.deliverRecordings()
        let removal = await files.nextRemoval()
        #expect(!removal.onMain)
        #expect(removal.url.lastPathComponent.hasPrefix("fake-"))
        #expect(stt.calls == 0)
    }

    @Test("a send still in flight from the previous session cannot fail the new one")
    func stale_send_from_previous_session_is_ignored() async throws {
        chat.holdSends = true
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        controller.onEnded = { ended.append($0) }
        try controller.start()
        await firstTurn(controller, text: "first")
        controller.end(.system)
        #expect(ended.map(\.reason) == [.system])

        try controller.start()
        await firstTurn(controller, text: "second")
        #expect(chat.sent == ["first", "second"])
        #expect(controller.displayState == .thinking)

        chat.resolveOldestSend(false)
        await settle()
        #expect(controller.isActive)
        #expect(controller.displayState == .thinking)
        #expect(ended.count == 1)

        chat.resolveOldestSend(true)
        await settle()
        #expect(controller.isActive)
        #expect(ended.count == 1)
    }

    @Test("idle 120 s in listening ends with the end earcon")
    func idleEnds() async throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        controller.onEnded = { ended.append($0) }
        try controller.start()
        clock.advance(119_999)
        #expect(ended.isEmpty)
        clock.advance(1)
        #expect(audio.earcons == [.end])
        #expect(ended.map(\.reason) == [.idle])
        #expect(controller.displayState == nil)
    }

    @Test("no_periodic_tick_only_one_deadline_armed")
    func no_periodic_tick_only_one_deadline_armed() async throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        controller.onEnded = { ended.append($0) }
        try controller.start()
        #expect(clock.pendingOneShots == 1)
        clock.advance(1000)
        controller.toggleMute()
        #expect(clock.pendingOneShots == 0)
        controller.toggleMute()
        #expect(clock.pendingOneShots == 1)
        clock.advance(119_999)
        #expect(ended.isEmpty)
        #expect(controller.isActive)
        #expect(clock.pendingOneShots == 1)
        clock.advance(1)
        #expect(ended.map(\.reason) == [.idle])
        #expect(clock.pendingOneShots == 0)
    }

    @Test("mute drops capture in software and tap unmutes")
    func mute() async throws {
        let controller = makeController()
        try controller.start()
        controller.toggleMute()
        #expect(controller.displayState == .muted)
        #expect(audio.muted)
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        #expect(stt.calls == 0)
        clock.advance(200_000)
        #expect(controller.isActive)
        controller.tapOrb()
        #expect(!audio.muted)
        #expect(controller.displayState == .listening)
    }

    @Test("interruption pauses playback and capture; after it, playback stays stopped")
    func interruption() async throws {
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        controller.conversationAudioInterruptionBegan()
        #expect(audio.pauses == 1)
        #expect(audio.capturePaused)
        controller.conversationAudioInterruptionEnded()
        #expect(audio.stops == 1)
        #expect(!audio.capturePaused)
        chat.emit(.completed)
        await settle()
        #expect(controller.displayState == .listening)
    }

    @Test("unplugging headphones stops playback; later sentences are not spoken")
    func unplugStops() async throws {
        audio.route = .headphones
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        audio.route = .speaker
        controller.conversationAudio(routeChanged: .speaker, oldDeviceUnavailable: true)
        #expect(audio.stops == 1)
        chat.emit(.text("The weather is nice today. More text here. And"))
        await settle()
        #expect(audio.spoken == ["The weather is nice today."])
    }

    @Test("cloud read-aloud failure falls back to the system voice once for the rest of the reply")
    func cloudFallbackOnce() async throws {
        let cloud = FakeCloudSpeech(results: [.failure(FakeSTTFailure())])
        let source = ReadAloudEngineSource { _, _ in
            ReadAloudEngineChoice(engine: cloud, fallback: nil)
        }
        let controller = makeController(readAloud: source)
        var fallbacks: [String] = []
        controller.onCloudFallback = { fallbacks.append($0) }
        try controller.start()
        await firstTurn(controller)
        chat.emit(.text("One. Two. Three"))
        chat.emit(.completed)
        await settle()
        #expect(cloud.calls == ["One."])
        #expect(audio.played.isEmpty)
        #expect(audio.spoken == ["One.", "Two.", "Three"])
        #expect(fallbacks == ["Relay"])
        #expect(controller.displayState == .listening)
    }

    @Test("cloud fallback: every reply retries cloud, but the user-visible notice fires once per conversation")
    func fallback_notice_once_per_conversation() async throws {
        let cloud = FakeCloudSpeech(results: [
            .failure(FakeSTTFailure()), .failure(FakeSTTFailure()), .failure(FakeSTTFailure()),
        ])
        let source = ReadAloudEngineSource { _, _ in
            ReadAloudEngineChoice(engine: cloud, fallback: nil)
        }
        let controller = makeController(readAloud: source)
        var fallbacks: [String] = []
        var notices: [String] = []
        controller.onCloudFallback = { fallbacks.append($0) }
        controller.onCloudFallbackNotice = { notices.append($0) }
        try controller.start()
        await firstTurn(controller)
        chat.emit(.text("One. Two"))
        chat.emit(.completed)
        await settle()
        #expect(controller.displayState == .listening)

        await firstTurn(controller)
        chat.emit(.text("Three. Four"))
        chat.emit(.completed)
        await settle()
        // The second reply still tries the cloud first and the callback still fires, but the notice does not fire again.
        #expect(cloud.calls == ["One.", "Three."])
        #expect(fallbacks == ["Relay", "Relay"])
        #expect(notices == ["Relay"])

        // A new conversation counts afresh.
        controller.end(.user)
        try controller.start()
        await firstTurn(controller)
        chat.emit(.text("Five"))
        chat.emit(.completed)
        await settle()
        #expect(cloud.calls == ["One.", "Three.", "Five"])
        #expect(notices == ["Relay", "Relay"])
    }

    @Test("interruption ended without the system suggesting resume ends with interruption, not system")
    func no_resume_end_reports_interruption() async throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        controller.onEnded = { ended.append($0) }
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        controller.conversationAudioInterruptionBegan()
        controller.conversationAudioInterruptionEndedWithoutResume()
        #expect(ended.map(\.reason) == [.interruption])
        #expect(!controller.isActive)
    }

    @Test("cloud read-aloud audio is played through the conversation engine")
    func cloudPlays() async throws {
        let cloud = FakeCloudSpeech(results: [])
        let source = ReadAloudEngineSource { _, _ in
            ReadAloudEngineChoice(engine: cloud, fallback: nil)
        }
        let controller = makeController(readAloud: source)
        try controller.start()
        await firstTurn(controller)
        chat.emit(.text("One. Two"))
        chat.emit(.completed)
        await settle()
        #expect(cloud.calls == ["One.", "Two"])
        #expect(audio.played.count == 2)
        #expect(audio.playedExtensions == ["mp3", "mp3"])
        #expect(audio.spoken.isEmpty)
    }

    @Test("speech start the reducer drops (thinking) opens no recording")
    func speech_start_dropped_by_reducer_opens_no_recording() async throws {
        let controller = makeController()
        try controller.start()
        await firstTurn(controller)
        #expect(controller.displayState == .thinking)
        #expect(audio.begins == 1)
        utterance(controller)
        await settle()
        #expect(audio.begins == 1)
        #expect(stt.calls == 1)
        #expect(controller.displayState == .thinking)
    }

    @Test("level is published at most ~15 times per second")
    func levelThrottle() async throws {
        let controller = makeController()
        try controller.start()
        var updates = 0
        let token = controller.$level.dropFirst().sink { _ in updates += 1 }
        for index in 0..<50 {
            controller.conversationAudio(didCaptureFrame: index, db: index.isMultiple(of: 2) ? -30 : -40)
            clock.nowMs += 20
        }
        token.cancel()
        #expect(updates >= 1)
        #expect(updates <= 15)
    }
}

// MARK: - Fakes

private final class Counter {
    var value = 0
}

private final class FrameCursor {
    var next = 0
}

private struct FakeSTTFailure: Error {}

private nonisolated final class ScriptedSTT: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _script: [Result<String, Error>] = []
    private var _calls = 0

    var script: [Result<String, Error>] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        let next: Result<String, Error> = lock.withLock {
            _calls += 1
            return _script.isEmpty ? .success("") : _script.removeFirst()
        }
        return try next.get()
    }
}

private final class FakeVoiceChatPort: VoiceConversationChatPort {
    private var continuation: AsyncStream<VoiceConversationReplyEvent>.Continuation?
    var sent: [String] = []
    var cancels = 0
    /// When true, send suspends until resolveOldestSend.
    var holdSends = false
    private var heldSends: [CheckedContinuation<Bool, Never>] = []

    func makeReplyEvents() -> AsyncStream<VoiceConversationReplyEvent> {
        let (stream, continuation) = AsyncStream<VoiceConversationReplyEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func send(_ text: String) async -> Bool {
        sent.append(text)
        guard holdSends else { return true }
        return await withCheckedContinuation { heldSends.append($0) }
    }

    func resolveOldestSend(_ sent: Bool) {
        guard !heldSends.isEmpty else { return }
        heldSends.removeFirst().resume(returning: sent)
    }

    func cancel() {
        cancels += 1
    }

    func emit(_ event: VoiceConversationReplyEvent) {
        continuation?.yield(event)
    }
}

/// Manual clock: advance only fires timers that are due; a one-shot timer is spent once it fires.
private final class ManualVoiceClock: VoiceConversationClock {
    private final class Entry: VoiceConversationTimer {
        /// nil = one-shot.
        let everyMs: Int?
        var nextAt: Int
        let handler: () -> Void
        var cancelled = false
        init(everyMs: Int?, nextAt: Int, handler: @escaping () -> Void) {
            self.everyMs = everyMs
            self.nextAt = nextAt
            self.handler = handler
        }
        func cancel() { cancelled = true }
    }

    var nowMs = 0
    private var entries: [Entry] = []

    /// Number of one-shot timers still pending.
    var pendingOneShots: Int { entries.filter { !$0.cancelled && $0.everyMs == nil }.count }

    func after(ms: Int, _ handler: @escaping () -> Void) -> VoiceConversationTimer {
        let entry = Entry(everyMs: nil, nextAt: nowMs + ms, handler: handler)
        entries.append(entry)
        return entry
    }

    func advance(_ ms: Int) {
        let end = nowMs + ms
        while let entry = entries.filter({ !$0.cancelled && $0.nextAt <= end }).min(by: { $0.nextAt < $1.nextAt }) {
            nowMs = max(nowMs, entry.nextAt)
            if let every = entry.everyMs {
                entry.nextAt += every
            } else {
                entry.cancelled = true
            }
            entry.handler()
        }
        entries.removeAll { $0.cancelled }
        nowMs = end
    }
}

private final class ConversationSilentSpeechEngine: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice: Bool { true }
    func speak(_ utterances: [SpeechUtterance]) {}
    func stop() {}
}

private final class FakeCloudSpeech: SpeechEngine, ConversationCloudSynthesizing {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice: Bool { true }
    private var results: [Result<Data, Error>]
    var calls: [String] = []

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    func speak(_ utterances: [SpeechUtterance]) {}
    func stop() {}

    func synthesize(text: String) async throws -> Data {
        calls.append(text)
        let next = results.isEmpty ? .success(Data(text.utf8)) : results.removeFirst()
        return try next.get()
    }

    var audioFileExtension: String { "mp3" }
    var fallbackProviderName: String { "Relay" }
}

/// Records the calling thread and path of removeItem (without really deleting); nextRemoval waits for the next call.
private nonisolated final class RemovalRecordingFileManager: FileManager, @unchecked Sendable {
    struct Removal: Sendable {
        let url: URL
        let onMain: Bool
    }

    private let lock = NSLock()
    private var removals: [Removal] = []
    private var waiter: CheckedContinuation<Removal, Never>?

    override func removeItem(at URL: URL) throws {
        let removal = Removal(url: URL, onMain: Thread.isMainThread)
        let waiting = lock.withLock { () -> CheckedContinuation<Removal, Never>? in
            guard let waiter else {
                removals.append(removal)
                return nil
            }
            self.waiter = nil
            return waiter
        }
        waiting?.resume(returning: removal)
    }

    func nextRemoval() async -> Removal {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Removal? in
                if !removals.isEmpty { return removals.removeFirst() }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

final class FakeConversationAudio: ConversationAudioEngine {
    weak var delegate: ConversationAudioEngineDelegate?
    var route: VoiceConversationLogic.Route = .headphones
    var isSpeakerRoute: Bool { route.isSpeaker }

    var started = 0
    var stopped = 0
    var muted = false
    var capturePaused = false
    var spoken: [String] = []
    var played: [Data] = []
    var playedExtensions: [String] = []
    var pauses = 0
    var resumes: [Bool] = []
    var stops = 0
    var earcons: [VoiceConversationLogic.Earcon] = []
    /// When true, playing a sentence suspends until completeCurrent.
    var holdPlayback = false
    /// Whether a recording segment is in progress (a test can close it directly to simulate the capture side no longer recording).
    var utteranceOpen = false
    private var pending: CheckedContinuation<ConversationPlaybackOutcome, Never>?

    func start() throws { started += 1 }

    func stop() {
        stopped += 1
        resolve(.stopped)
    }

    func setCaptureMuted(_ muted: Bool) { self.muted = muted }
    func pauseCapture() { capturePaused = true }
    func resumeCapture() { capturePaused = false }
    var begins = 0
    func beginUtterance(fromFrame frame: Int) {
        begins += 1
        utteranceOpen = true
    }

    /// When true, finishing a recording suspends until deliverRecordings (simulating a close on the io queue that has not completed).
    var holdRecordings = false
    private var heldRecordings: [@MainActor () -> Void] = []

    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) {
        var recording: RecordingResult?
        if utteranceOpen {
            utteranceOpen = false
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).aac")
            recording = RecordingResult(url: url, durationSec: 1, envelope: [])
        }
        let result = recording
        // Same behavior as ConversationCaptureCore: when not recording, call back nil synchronously without going through io.
        if holdRecordings && result != nil {
            heldRecordings.append { completion(result) }
        } else {
            completion(result)
        }
    }

    func deliverRecordings() {
        let held = heldRecordings
        heldRecordings = []
        for deliver in held { deliver() }
    }

    func discardUtterance() { utteranceOpen = false }

    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome {
        spoken.append(text)
        return await output()
    }

    func play(audio: Data, fileExtension: String) async -> ConversationPlaybackOutcome {
        played.append(audio)
        playedExtensions.append(fileExtension)
        return await output()
    }

    private func output() async -> ConversationPlaybackOutcome {
        delegate?.conversationAudioDidBeginSentence()
        guard holdPlayback else { return .finished }
        return await withCheckedContinuation { pending = $0 }
    }

    func completeCurrent(_ outcome: ConversationPlaybackOutcome = .finished) {
        resolve(outcome)
    }

    private func resolve(_ outcome: ConversationPlaybackOutcome) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: outcome)
    }

    func pausePlayback() { pauses += 1 }
    func resumePlayback(fromSentenceStart: Bool) { resumes.append(fromSentenceStart) }

    func stopPlayback() {
        stops += 1
        resolve(.stopped)
    }

    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { earcons.append(earcon) }
}

// MARK: The home cascade's first sentence creates the conversation: the conversation id is handed out before presentChat (the same beat as the realtime makeConversation)

/// Every request gets an immediate 503: the send path still runs to completion (create the message, start the stream, stream fails) without touching the network.
private final class HomeCascadeRefusingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension VoiceConversationControllerTests {
    /// The conversation id of the chat page currently shown by navigation (top of the compact stack / the regular right pane).
    private static func presentedChat(_ state: AppState) -> UUID? {
        if case .chat(let id) = state.navigation.path.last { return id }
        return state.navigation.chatDetail.conversationID
    }

    @Test(.timeLimit(.minutes(1))) func home_cascade_first_send_publishes_conversation_id_before_present_chat() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeCascadeRefusingURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "home-cascade-handoff-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "gpt-4o")
        // Matches the cascade send closure in HomeView.
        let port = AppStateVoiceChatPort(host: state, conversationID: nil) { [state] text, id in
            await state.sendMessageOutcome(text, in: id, delivery: .voice)
        }
        // Each time an id is handed out: the id on the port, the conversation already shown in navigation, and the time.
        var published: [(id: UUID, portID: UUID?, presented: UUID?, at: Date)] = []
        port.onConversationChanged = { [port] id in
            published.append((id, port.conversationID, Self.presentedChat(state), Date()))
        }
        let events = port.makeReplyEvents()

        #expect(await port.send("hello"))
        let sentAt = Date()

        let created = try #require(state.conversations.first?.id)
        #expect(state.conversations.map(\.id) == [created])
        #expect(published.map(\.id) == [created])
        let handoff = try #require(published.first)
        #expect(handoff.portID == created)
        // The chat page is not open yet when the id is handed out: there is no gap between the home bar and the chat page where the conversation is shown but the session still has no id.
        #expect(handoff.presented == nil)
        #expect(Self.presentedChat(state) == created)
        #expect(port.conversationID == created)
        // presentChat to .sent: only the synchronous preparation before sending, not the reply.
        let elapsed = sentAt.timeIntervalSince(handoff.at)
        #expect(elapsed < 1, "presentChat → .sent took \(elapsed) s")

        // Wait for this round's stream to finish (503 gives failed) so no in-flight request is left to later cases.
        for await event in events {
            if case .failed = event { break }
            if case .completed = event { break }
        }
    }
}

// MARK: The home cascade's first send fails: once the conversation is created it has already been handed out (the id and homeHandedOff are written back) and the port still reports failure

extension VoiceConversationControllerTests {
    @Test(
        "home cascade first send fails after the conversation is created: id and hand-off are written back, port returns false",
        arguments: [ChatSendOutcome.refused, .blockedWhileSending]
    )
    func home_cascade_first_send_failure_keeps_handoff(_ failure: ChatSendOutcome) async throws {
        // Port layer: the conversation-created callback arrives, then the send fails.
        let created = UUID()
        let port = AppStateVoiceChatPort(host: FakeVoiceChatHost(), conversationID: nil) { _, _ in
            VoiceSendContext.onConversationCreated?(created)
            return failure
        }
        var handOffs = 0
        var changed: [UUID] = []
        port.onHandedOff = { handOffs += 1 }
        port.onConversationChanged = { changed.append($0) }
        #expect(await port.send("hello") == false)
        #expect(port.conversationID == created)
        #expect(changed == [created])
        #expect(handOffs == 1)
        #expect(!port.isCreatingConversation)

        // Session layer: for a conversation started from home, after the first send fails the conversationID and homeHandedOff are written back, and the home bar no longer gets the controller.
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: DictationEngineChoice(
            engine: FixedTextSTT(text: "hello"), isSystem: true, fallback: nil
        )))
        let sessionCreated = UUID()
        var sends = 0
        let started = await session.start(origin: .home, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in
            sends += 1
            VoiceSendContext.onConversationCreated?(sessionCreated)
            return failure
        }
        #expect(started)
        for _ in 0..<30 { await Task.yield() }
        let controller = try #require(session.controller)
        var frame = 0
        for db in Array(repeating: -60.0, count: 10) + Array(repeating: -30.0, count: 20) + Array(repeating: -60.0, count: 30) {
            controller.conversationAudio(didCaptureFrame: frame, db: db)
            frame += 1
        }
        for _ in 0..<30 { await Task.yield() }
        #expect(sends == 1)
        #expect(session.conversationID == sessionCreated)
        #expect(session.homeHandedOff)
        #expect(session.homeVoiceSurface == nil)

        session.end(.user)
        for _ in 0..<30 { await Task.yield() }
    }
}
