import AVFoundation
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
        case .sayAgain: return "PROMPT sayAgain"
        case .checkLanguage: return "PROMPT checkLanguage"
        case .echoHint: return "PROMPT echoHint"
        case .placeholder(let kind): return "PROMPT \(kind.rawValue)"
        }
    }

    private func makeController(
        readAloud: ReadAloudEngineSource = .fixed(ConversationSilentSpeechEngine()), osMajor: Int = 27,
        isSystemSTT: Bool = true, sttLanguage: @escaping () -> String? = { nil },
        engine: (any STTEngine)? = nil, dictation: DictationEngineSource? = nil,
        liveFinishLimit: Duration = VoiceConversationController.liveFinishLimit,
        loadSpeechModel: @escaping @Sendable () async -> SpeechModelLoad = VoiceConversationController.loadSileroVad,
        diagnostics: VoiceConversationDiagnostics = NoOpVoiceConversationDiagnostics(),
        chatPort: VoiceConversationChatPort? = nil
    ) -> VoiceConversationController {
        let stops = readAloudStops
        return VoiceConversationController(
            audio: audio,
            dictation: dictation ?? .fixed(engine ?? stt, isSystem: isSystemSTT),
            readAloud: readAloud,
            chat: chatPort ?? chat,
            prompt: Self.promptText,
            clock: clock,
            memory: VoiceBargeInMemory(defaults: defaults, osMajorVersion: osMajor),
            stopReadAloud: { stops.value += 1 },
            detectLanguage: { _ in "en" },
            sttLanguage: sttLanguage,
            liveFinishLimit: liveFinishLimit,
            loadSpeechModel: loadSpeechModel,
            diagnostics: diagnostics
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

    /// Passes the reply-audio gate: from the decision moment (silence start + vadEndSilenceMs) to silence start + replyAudioGateMs; replies queued before the gate are sent when due.
    private func passReplyGate() async {
        clock.advance(VoiceConversationLogic.Constants.replyAudioGateMs - VoiceConversationLogic.Constants.vadEndSilenceMs)
        await settle()
    }

    /// Speaker playing: past the 1 s playback-start grace, then 400 ms of voice + 600 ms of silence.
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
        // Reply audio gate: sentences arriving before the gate are queued and stay silent
        #expect(controller.displayState == .thinking)
        #expect(audio.spoken.isEmpty)
        await passReplyGate()
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
        await passReplyGate()
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
        await passReplyGate()
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
        let earconsBefore = audio.earcons
        clock.advance(130_000)
        #expect(audio.earcons == earconsBefore)
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
        #expect(audio.earcons == [.start, .end])
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
        await passReplyGate()
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
        await passReplyGate()
        #expect(controller.displayState == .listening)

        await firstTurn(controller)
        chat.emit(.text("Three. Four"))
        chat.emit(.completed)
        await settle()
        await passReplyGate()
        // The second reply still tries cloud first and its callback still fires, but the hint is not sent again.
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
        await passReplyGate()
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

    // MARK: Visible wrap-up on stop frames

    @Test("capture failure (rebuild failed / frames stalled) ends with system, mid-reply too")
    func capture_failed_ends_with_system() async throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        controller.onEnded = { ended.append($0) }
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        controller.conversationAudioCaptureFailed(reason: .stall)
        #expect(ended.map(\.reason) == [.system])
        #expect(!controller.isActive)
        #expect(audio.stopped == 1)
    }

    @Test("capture failure while listening ends with system")
    func capture_failed_while_listening_ends_with_system() throws {
        let controller = makeController()
        var ended: [VoiceConversationEnd] = []
        controller.onEnded = { ended.append($0) }
        try controller.start()
        feed(controller, -60, 10)
        controller.conversationAudioCaptureFailed(reason: .stall)
        #expect(ended.map(\.reason) == [.system])
        #expect(!controller.isActive)
    }

    // MARK: VAD mode diagnostics

    @Test("vadMode: model ready reports model once; inference failure switches to energy exactly once")
    func vad_mode_model_then_inference_failed_once() async throws {
        let spy = VadModeDiagnosticsSpy()
        let controller = makeController(loadSpeechModel: { .ready }, diagnostics: spy)
        try await controller.prepareAudioSession()
        try controller.start()
        controller.conversationAudio(didCaptureFrame: frame.next, db: -60, speechProb: 0.1)
        frame.next += 1
        controller.conversationAudio(didCaptureFrame: frame.next, db: -60, speechProb: nil)
        frame.next += 1
        controller.conversationAudio(didCaptureFrame: frame.next, db: -60, speechProb: nil)
        frame.next += 1
        #expect(spy.modes == [VadModeRecord(mode: "model", reason: nil), VadModeRecord(mode: "energy", reason: "inference_failed")])
    }

    @Test(
        "vadMode: energy reasons none / timeout / load_failed:<reason>, reported once at start",
        arguments: [
            (SpeechModelLoad.unavailable, "none"),
            (SpeechModelLoad.timeout, "timeout"),
            (SpeechModelLoad.failed("modelMissing"), "load_failed:modelMissing"),
        ]
    )
    func vad_mode_energy_reasons(load: SpeechModelLoad, reason: String) async throws {
        let spy = VadModeDiagnosticsSpy()
        let controller = makeController(loadSpeechModel: { load }, diagnostics: spy)
        try await controller.prepareAudioSession()
        try controller.start()
        controller.conversationAudio(didCaptureFrame: frame.next, db: -60, speechProb: nil)
        frame.next += 1
        #expect(spy.modes == [VadModeRecord(mode: "energy", reason: reason)])
    }

    @Test("vadMode: start without prepare reports energy none")
    func vad_mode_without_prepare_is_energy_none() throws {
        let spy = VadModeDiagnosticsSpy()
        let controller = makeController(loadSpeechModel: { .ready }, diagnostics: spy)
        try controller.start()
        #expect(spy.modes == [VadModeRecord(mode: "energy", reason: "none")])
    }

    @Test("load failure reason: SileroVad.LoadError keeps the case name")
    func speech_model_load_reason() {
        #expect(SpeechModelLoad.reason(of: SileroVad.LoadError.modelMissing) == "modelMissing")
        #expect(SpeechModelLoad.failed("modelMissing").vadMode.reason == "load_failed:modelMissing")
        #expect(SpeechModelLoad.ready.vadMode.mode == "model")
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
        await passReplyGate()
        #expect(cloud.calls == ["One.", "Two"])
        #expect(audio.played.count == 2)
        #expect(audio.playedExtensions == ["mp3", "mp3"])
        #expect(audio.spoken.isEmpty)
    }

    @Test("speech start while the transcript is pending is queued and recorded; after an empty result it listens and transcribes u2")
    func speech_start_while_awaiting_transcript_queues_and_records() async throws {
        let controller = makeController()
        try controller.start()
        // u1's recording wrap-up is suspended: the transcript has not come back; thinking and waiting for the transcript
        audio.holdRecordings = true
        stt.script = [.success(""), .success("second")]
        feed(controller, -60, 10)
        utterance(controller)
        #expect(controller.displayState == .thinking)
        #expect(audio.begins == 1)

        // Speaking while waiting for the transcript: the reducer queues it, and recording still starts
        feed(controller, -30, 20)
        #expect(audio.begins == 2)
        #expect(audio.utteranceOpen)
        #expect(controller.state.pendingVad.count == 1)
        #expect(controller.displayState == .thinking)

        // u1 result is empty → back to listening; replaying the speech start → speaking, and the recording is not dropped by resetVad
        audio.holdRecordings = false
        audio.deliverRecordings()
        await settle()
        #expect(stt.calls == 1)
        #expect(controller.state.pendingVad.isEmpty)
        #expect(controller.displayState == .userSpeaking)
        #expect(audio.utteranceOpen)

        feed(controller, -60, 30)
        await settle()
        #expect(audio.finishes == 2)
        #expect(stt.calls == 2)
        #expect(chat.sent == ["second"])
    }

    @Test("queued speech start without a recording still dispatches vadSpeechEnd; after replay it does not stay speaking )")
    func queued_start_without_recording_still_ends() async throws {
        let controller = makeController()
        try controller.start()
        audio.holdRecordings = true
        stt.script = [.success("")]
        feed(controller, -60, 10)
        utterance(controller)
        #expect(controller.state.awaitedUtteranceId == "u1")

        // Speaking while waiting for the transcript: the speech start is queued; this recording is gone afterwards, and VAD is still speaking
        feed(controller, -30, 20)
        #expect(controller.state.pendingVad.count == 1)
        controller.discardOpenUtteranceForTesting()
        #expect(!audio.utteranceOpen)

        // The speech end is still enqueued as usual
        feed(controller, -60, 30)
        #expect(controller.state.pendingVad.count == 2)

        // u1 result is empty → replaying the speech start and end: does not get stuck in speaking
        audio.holdRecordings = false
        audio.deliverRecordings()
        await settle()
        #expect(controller.state.pendingVad.isEmpty)
        #expect(!controller.state.userSpeaking)
        #expect(controller.displayState != .userSpeaking)
    }

    @Test("pause then the second half while the first transcript is pending: the second half is not lost")
    func second_half_after_pause_is_not_lost() async throws {
        let controller = makeController()
        try controller.start()
        audio.holdRecordings = true
        stt.script = [.success("what is the weather"), .success("in Paris")]
        feed(controller, -60, 10)
        // The first segment's speech end is decided by real Vad frames
        utterance(controller)
        #expect(controller.state.awaitedUtteranceId == "u1")

        // Continuing to speak a whole segment before the transcript returns: the speech start and end are both queued; u2's recording wraps up first and is kept
        utterance(controller)
        #expect(audio.begins == 2)
        #expect(audio.finishes == 2)
        #expect(!audio.utteranceOpen)
        #expect(controller.state.pendingVad.count == 2)
        #expect(stt.calls == 0)

        audio.holdRecordings = false
        audio.deliverRecordings()
        await settle()
        // u1 sent; replaying the u2 speech start = barge-in while thinking (cancels generation); speech end → transcribe u2
        #expect(chat.sent == ["what is the weather"])
        #expect(chat.cancels >= 1)
        #expect(stt.calls == 2)
        #expect(controller.state.pendingVad.isEmpty)
    }

    @Test("replay: send then cancel in one batch cancels the turn just sent; the cancelled send is not a failure and the second half amends it")
    func replay_send_then_cancel_cancels_that_turn() async throws {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            host.calls.append("send")
            host.lastUser[id!] = UUID()
            return .sent(id!)
        }
        let controller = makeController(chatPort: port)
        try controller.start()
        audio.holdRecordings = true
        stt.script = [.success("what is the weather"), .success("in Paris")]
        feed(controller, -60, 10)
        utterance(controller)
        utterance(controller)
        #expect(controller.state.pendingVad.count == 2)

        audio.holdRecordings = false
        audio.deliverRecordings()
        await settle()
        // Replay batch sendMessage(u1) → cancelGeneration: after u1 is persisted, the generation it dispatched is stopped
        let sendIndex = try #require(host.calls.firstIndex(of: "send"))
        #expect(host.calls[(sendIndex + 1)...].first == "cancel", "calls: \(host.calls)")
        #expect(host.cancelled.count >= 2)
        // A voided send returning false is not a send failure; the second half attaches to u1
        #expect(controller.isActive)
        #expect(stt.calls == 2)
        #expect(host.amends.map(\.text) == ["in Paris"])
        #expect(host.amends.first?.messageID == host.lastUser[conversation])
    }

    @Test("replay: amend then cancel in one batch stops generating but keeps the user text; the next amend carries it")
    func replay_amend_then_cancel_keeps_amend_text() async throws {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            host.calls.append("send")
            host.lastUser[id!] = UUID()
            return .sent(id!)
        }
        let controller = makeController(chatPort: port)
        try controller.start()
        stt.script = [.success("what is the weather"), .success("in Paris"), .success("tomorrow")]
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        #expect(host.calls == ["send"])

        // Barge-in u2 while thinking: transcription hangs; speaking again, u3 is queued
        audio.holdRecordings = true
        utterance(controller)
        feed(controller, -30, 20)
        #expect(controller.state.pendingVad.count == 1, "pendingVad: \(controller.state.pendingVad)")

        // u2 settles: replay batch amendLastMessage(u2) → cancelGeneration (u3 speech start); cancel only stops generation, u2 was not handed to the host but its text is held
        audio.holdRecordings = false
        audio.deliverRecordings()
        await settle()
        #expect(controller.isActive)
        #expect(host.amends.isEmpty, "calls: \(host.calls)")

        // u3 wraps up: the barge-in carries the held u2; the final user message contains u1 + u2 + u3 (cancelling does not revoke user text)
        feed(controller, -60, 30)
        await settle()
        #expect(controller.isActive)
        #expect(host.amends.map(\.text) == ["in Paris tomorrow"], "calls: \(host.calls)")
        let amend = try #require(host.amends.last)
        #expect(VoiceConversationLogic.joinAmend(amend.turnText ?? "", amend.text) == "what is the weather in Paris tomorrow")
    }

    @Test("amend handed to the host but not yet returned, then cancel: the next amend does not repeat that text )")
    func cancel_after_amend_delivered_does_not_carry_text() async throws {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            host.calls.append("send")
            host.lastUser[id!] = UUID()
            return .sent(id!)
        }
        let controller = makeController(chatPort: port)
        try controller.start()
        stt.script = [.success("what is the weather"), .success("in Paris"), .success("tomorrow")]
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        #expect(host.calls == ["send"])

        // Barge-in u2 while thinking: the host already received the text replacing the message; the rewrite has not returned yet
        host.holdAmends = true
        utterance(controller)
        await settle()
        #expect(host.amends.map(\.text) == ["in Paris"], "calls: \(host.calls)")
        #expect(host.heldAmendCount == 1)

        // u3 speech start: cancelling generation lands in the window after delivery and before return
        let cancelsBefore = host.cancelled.count
        feed(controller, -30, 20)
        #expect(host.cancelled.count > cancelsBefore, "calls: \(host.calls)")
        host.holdAmends = false
        host.releaseAmends()
        await settle()

        // u3 wraps up: u2 is already in the message, so the barge-in carries only u3
        feed(controller, -60, 30)
        await settle()
        #expect(controller.isActive)
        #expect(host.amends.map(\.text) == ["in Paris", "tomorrow"], "calls: \(host.calls)")
    }

    @Test("replay: a live caption that arrived while the start was queued is shown once the utterance replays", .timeLimit(.minutes(1)))
    func replay_dispatches_first_live_caption() async throws {
        let live = FakeLiveSTT(file: stt)
        let controller = makeController(engine: live)
        try controller.start()
        await settle()
        audio.holdRecordings = true
        stt.script = [.success("what is the weather")]
        feed(controller, -60, 10)
        utterance(controller)
        #expect(controller.state.awaitedUtteranceId == "u1")

        // Speaking while waiting for the transcript: the speech start is queued; u2's realtime session still opens and the captions arrive first
        feed(controller, -30, 20)
        #expect(controller.state.pendingVad.count == 1)
        await settle { live.sessions.count == 2 }
        let session = try #require(live.sessions.last)
        session.partial("in Paris")
        await settle()
        #expect(controller.displayState == .thinking)

        // u1 settles → replaying the speech start becomes speaking: the same captions do not change, but it must still be dispatched
        audio.holdRecordings = false
        audio.deliverRecordings()
        await settle { controller.state.userSpeaking }
        #expect(controller.state.userSpeaking)
        #expect(controller.state.partialText == "in Paris")
        #expect(controller.caption == "in Paris")
    }

    @Test("muting while speech is queued clears the queue and discards its recording")
    func queued_utterance_cleared_by_abandon_discards_recording() async throws {
        let controller = makeController()
        try controller.start()
        audio.holdRecordings = true
        stt.script = [.success("what is the weather")]
        feed(controller, -60, 10)
        utterance(controller)
        feed(controller, -30, 20)
        #expect(audio.utteranceOpen)
        #expect(controller.state.pendingVad.count == 1)

        // Silence = external void: queued speech starts are all cleared and the recording is dropped; after the transcript returns only u1 is sent
        controller.toggleMute()
        #expect(controller.state.pendingVad.isEmpty)
        #expect(!audio.utteranceOpen)
        audio.holdRecordings = false
        audio.deliverRecordings()
        await settle()
        #expect(chat.sent == ["what is the weather"])
        #expect(stt.calls == 1)
    }

    // MARK: - Turns (continued speech, echo window, recognition language, failure records)

    @Test("continuation: speech resumed during the hold keeps the same utterance id and keeps writing the same recording")
    func continuation_same_id_same_recording() async throws {
        let controller = makeController()
        try controller.start()
        stt.script.append(.success("hello world"))
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        feed(controller, -60, 29)
        // Captions just changed: vadSpeechEnd enters hold; the recording is not wrapped up or transcribed immediately
        controller.receivePartial("hello")
        feed(controller, -60, 1)
        await settle()
        #expect(audio.begins == 1)
        #expect(audio.finishes == 0)
        #expect(stt.calls == 0)
        #expect(controller.displayState != .thinking)

        // Speaking again within the hold window: the same utterance, no new recording
        feed(controller, -30, 20)
        #expect(audio.begins == 1)
        #expect(audio.finishes == 0)
        feed(controller, -60, 30)
        await settle()
        #expect(audio.begins == 1)
        #expect(audio.finishes == 1)
        #expect(stt.calls == 1)
        #expect(chat.sent == ["hello world"])
        #expect(controller.displayState == .thinking)
    }

    @Test("the recording is closed only when the transcribe effect runs, not at vadSpeechEnd")
    func recording_closed_on_transcribe_effect() async throws {
        let controller = makeController()
        try controller.start()
        stt.script.append(.success("question"))
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        feed(controller, -60, 29)
        controller.receivePartial("question")
        feed(controller, -60, 1)
        #expect(audio.finishes == 0)
        // Hold expires (captions stable for 500 ms) → transcribe → only now wrap up
        clock.advance(600)
        await settle()
        #expect(audio.finishes == 1)
        #expect(stt.calls == 1)
        #expect(chat.sent == ["question"])
    }

    @Test("partial stall force-ends the utterance and still transcribes its recording")
    func stall_force_end_transcribes_recording() async throws {
        let controller = makeController()
        try controller.start()
        stt.script.append(.success("stalled words"))
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        controller.receivePartial("stalled")
        // Captions unchanged for 1500 ms while voice keeps going: the stall fallback calls forceEndUtterance mid-dispatch
        feed(controller, -30, 80)
        clock.advance(2_000)
        await settle()
        #expect(audio.finishes == 1)
        #expect(stt.calls == 1)
        #expect(chat.sent == ["stalled words"])
    }

    @Test("tapping the orb mid-speech force-ends the utterance and still transcribes its recording")
    func tap_orb_force_end_transcribes_recording() async throws {
        let controller = makeController()
        try controller.start()
        stt.script.append(.success("tapped words"))
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        controller.tapOrb()
        clock.advance(2_000)
        await settle()
        #expect(audio.finishes == 1)
        #expect(stt.calls == 1)
        #expect(chat.sent == ["tapped words"])
    }

    /// Starts a turn, completes one reply sentence, and stops while that sentence is playing (speaker).
    private func lastSentencePlaying(_ controller: VoiceConversationController) async {
        await firstTurn(controller)
        audio.holdPlayback = true
        chat.emit(.text("Only sentence."))
        chat.emit(.completed)
        await settle()
        await passReplyGate()
    }

    @Test("playback end = clock at the last dataPlayedBack: back to listening then, not when speak returns")
    func playback_end_from_last_played_back() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await lastSentencePlaying(controller)
        #expect(controller.displayState == .speaking)
        feed(controller, -60, 60)

        audio.reportPlayedBack()
        await settle()
        #expect(controller.displayState == .listening)

        // speak returns 600 ms late: the echo window still counts from the moment playback completion is reported
        feed(controller, -60, 30)
        audio.completeCurrent()
        await settle()
        #expect(controller.displayState == .listening)
        feed(controller, -60, 15)
        // 900 ms after playback ends: outside the echo window, so 120 ms of voice counts as speaking
        let begins = audio.begins
        feed(controller, -30, 7)
        #expect(audio.begins == begins + 1)
    }

    @Test("after resetVad, a speech start inside the post-playback window needs the guard threshold")
    func post_playback_window_uses_guard_threshold() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await lastSentencePlaying(controller)
        feed(controller, -60, 60)
        audio.completeCurrent()
        await settle()
        #expect(controller.displayState == .listening)

        // Inside the echo window: 140 ms of voice is below the 160 ms echo-window threshold and does not count as speaking
        let begins = audio.begins
        feed(controller, -30, 7)
        feed(controller, -60, 5)
        #expect(audio.begins == begins)
        // Inside the echo window, 160 ms of sustained voice counts as speaking (a short one-syllable answer)
        feed(controller, -30, 8)
        #expect(audio.begins == begins + 1)
    }

    @Test("the recognition language from settings is passed to every transcription")
    func stt_language_passed_to_recognizer() async throws {
        let controller = makeController(sttLanguage: { "fr-FR" })
        try controller.start()
        stt.script = [.failure(FakeSTTFailure()), .success("bonjour")]
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        #expect(stt.calls == 2)
        #expect(stt.languages == ["fr-FR", "fr-FR"])
        #expect(chat.sent == ["bonjour"])
    }

    // MARK: - Live recognition (system engine)

    /// Yields the main thread until the condition holds; the live session runs in a background task (at most about 2 s).
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func pcm(frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    @Test("live: a new utterance opens one live session in the recognition language and its sink feeds it", .timeLimit(.minutes(1)))
    func live_session_opens_with_sink() async throws {
        let live = FakeLiveSTT(file: stt)
        let controller = makeController(sttLanguage: { "fr-FR" }, engine: live)
        try controller.start()
        await settle()
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        #expect(audio.begins == 1)
        let sink = try #require(audio.liveSinks.last ?? nil)
        await settle { live.sessions.count == 1 }
        let session = try #require(live.sessions.first)
        #expect(session.language == "fr-FR")
        // Pre-recorded and later frames all enter the session in order through the same sink
        sink(Self.pcm(frames: 2_880))
        sink(Self.pcm(frames: 960))
        await settle { session.fedFrames.count == 2 }
        #expect(session.fedFrames == [2_880, 960])
    }

    @Test("live: frames that arrive before the engine choice resolves are queued and fed once the session opens", .timeLimit(.minutes(1)))
    func live_frames_queued_until_session_ready() async throws {
        let live = FakeLiveSTT(file: stt)
        let gate = ChoiceGate()
        let source = DictationEngineSource {
            await gate.wait()
            return DictationEngineChoice(engine: live, isSystem: true, fallback: nil)
        }
        let controller = makeController(dictation: source)
        try controller.start()
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        let sink = try #require(audio.liveSinks.last ?? nil)
        sink(Self.pcm(frames: 2_880))
        sink(Self.pcm(frames: 960))
        await settle()
        #expect(live.sessions.isEmpty)
        gate.open()
        await settle { live.sessions.first?.fedFrames.count == 2 }
        #expect(live.sessions.count == 1)
        #expect(live.sessions.first?.fedFrames == [2_880, 960])
    }

    @Test("live: captions = livePartial(finals, partial), dispatched only when the text changes", .timeLimit(.minutes(1)))
    func live_partial_dispatches_caption_on_change() async throws {
        let live = FakeLiveSTT(file: stt)
        let controller = makeController(engine: live)
        try controller.start()
        await settle()
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        await settle { live.sessions.count == 1 }
        let session = try #require(live.sessions.first)
        session.partial("hello")
        await settle { controller.state.partialText == "hello" }
        #expect(controller.state.partialText == "hello")
        let changedAt = controller.state.partialChangedAtMs
        // The final matches the just-received partial text: captions do not change and sttPartial is not dispatched again
        clock.nowMs += 100
        session.final("hello")
        await settle()
        #expect(controller.state.partialChangedAtMs == changedAt)
        session.partial("world")
        await settle { controller.state.partialText == "hello world" }
        #expect(controller.state.partialText == "hello world")
    }

    @Test("live: a non-empty live result is used directly, no file transcription; recorded as an ok system attempt", .timeLimit(.minutes(1)))
    func live_result_used_directly() async throws {
        let live = FakeLiveSTT(file: stt)
        live.nextEnding = .text("question")
        let controller = makeController(engine: live)
        try controller.start()
        await settle()
        feed(controller, -60, 10)
        utterance(controller)
        await settle { chat.sent == ["question"] }
        #expect(chat.sent == ["question"])
        #expect(stt.calls == 0)
        #expect(live.sessions.first?.inputEnded == true)
    }

    @Test("live: empty, failed or timed-out live results fall back to file transcription of the same recording", .timeLimit(.minutes(1)))
    func live_fallback_to_file() async throws {
        for ending in [FakeLiveSession.Ending.text("  "), .failure, .hang] {
            let live = FakeLiveSTT(file: stt)
            live.nextEnding = ending
            let before = stt.calls
            let sentBefore = chat.sent.count
            let controller = makeController(engine: live, liveFinishLimit: .milliseconds(50))
            try controller.start()
            await settle()
            stt.script = [.success("from file")]
            feed(controller, -60, 10)
            utterance(controller)
            await settle { chat.sent.count == sentBefore + 1 }
            #expect(stt.calls == before + 1, "\(ending)")
            #expect(chat.sent.last == "from file", "\(ending)")
            if case .hang = ending { #expect(live.sessions.first?.cancelled == true) }
            controller.end(.system)
            await settle()
        }
    }

    @Test("live: continuing during the hold keeps the same session; no second session is opened", .timeLimit(.minutes(1)))
    func live_continuation_same_session() async throws {
        let live = FakeLiveSTT(file: stt)
        live.nextEnding = .text("hello world")
        let controller = makeController(engine: live)
        try controller.start()
        await settle()
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        feed(controller, -60, 29)
        await settle { live.sessions.count == 1 }
        live.sessions.first?.partial("hello")
        await settle { controller.state.partialText == "hello" }
        feed(controller, -60, 1)
        await settle()
        #expect(controller.state.holdUtteranceId != nil)
        feed(controller, -30, 20)
        feed(controller, -60, 30)
        await settle { chat.sent == ["hello world"] }
        #expect(audio.begins == 1)
        #expect(live.sessions.count == 1)
        #expect(stt.calls == 0)
        #expect(chat.sent == ["hello world"])
    }

    @Test("live: an abandoned utterance cancels its session at once (mute, end)", .timeLimit(.minutes(1)))
    func live_abandon_cancels_session() async throws {
        let live = FakeLiveSTT(file: stt)
        let controller = makeController(engine: live)
        try controller.start()
        await settle()
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        await settle { live.sessions.count == 1 }
        controller.toggleMute()
        await settle { live.sessions.first?.cancelled == true }
        #expect(live.sessions.first?.cancelled == true)

        controller.toggleMute()
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        await settle { live.sessions.count == 2 }
        controller.end(.user)
        await settle { live.sessions.last?.cancelled == true }
        #expect(live.sessions.count == 2)
        #expect(live.sessions.last?.cancelled == true)
    }

    @Test("live: a cloud recognizer opens no live session and transcribes the file", .timeLimit(.minutes(1)))
    func live_cloud_opens_no_session() async throws {
        let live = FakeLiveSTT(file: stt)
        let controller = makeController(isSystemSTT: false, engine: live)
        try controller.start()
        await settle()
        stt.script = [.success("cloud")]
        feed(controller, -60, 10)
        utterance(controller)
        await settle { chat.sent == ["cloud"] }
        #expect(live.sessions.isEmpty)
        #expect(audio.liveSinks.allSatisfy { $0 == nil })
        #expect(stt.calls == 1)
    }

    @Test("screen reader: speaking drops the open utterance and cancels its live session; frames meanwhile skip the VAD (floor frozen)", .timeLimit(.minutes(1)))
    func screen_reader_drops_utterance_and_freezes_vad() async throws {
        let live = FakeLiveSTT(file: stt)
        let controller = makeController(engine: live)
        try controller.start()
        await settle()
        // Noise floor about −54 dB; speaking creates the recording and the live session
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        await settle { live.sessions.count == 1 }
        #expect(audio.begins == 1)
        #expect(audio.utteranceOpen)

        controller.setScreenReaderSpeaking(true)
        await settle { live.sessions.first?.cancelled == true }
        #expect(live.sessions.first?.cancelled == true)
        #expect(!audio.utteranceOpen)
        // −45 dB during screen reading: if it enters VAD, the noise floor would track to about −45, after which −35 no longer counts as speaking
        feed(controller, -45, 200)
        controller.setScreenReaderSpeaking(false)
        feed(controller, -35, 20)
        await settle()
        #expect(audio.begins == 2)
        #expect(stt.calls == 0)
        #expect(chat.sent.isEmpty)
    }

    @Test("file transcription limit = durationSec × 1.5 + 5 s, same as dictation")
    func file_transcription_limit_matches_dictation() {
        #expect(VoiceConversationController.fileTranscriptionLimit(durationSec: 2) == .seconds(8))
        #expect(VoiceConversationController.fileTranscriptionLimit(durationSec: 0) == .seconds(5))
    }

    @Test("a hanging system file transcription fails at the limit", .timeLimit(.minutes(1)))
    func hanging_file_transcription_times_out() async throws {
        let controller = makeController(engine: HangingSTT())
        try controller.start()
        await settle()
        audio.recordingDurationSec = 0
        feed(controller, -60, 10)
        let began = ContinuousClock.now
        utterance(controller)
        // The first timeout is the first failed attempt; the reducer retries once (sttAttempts 1 -> 2).
        for _ in 0..<500 where controller.state.sttAttempts < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = ContinuousClock.now - began
        #expect(elapsed >= .milliseconds(4_900))
        controller.end(.system)
        await settle()
    }

    @Test("level is published at most ~15 times per second, each value the window's peak rather than its first frame")
    func levelThrottle() async throws {
        let controller = makeController()
        try controller.start()
        var published: [Double] = []
        let token = controller.$level.dropFirst().sink { published.append($0) }
        // Every 4 frames (80 ms, one publish window), only the middle frame is loud: taking the first value would always be 0; only taking the peak shows it.
        var floor = VoiceConversationLogic.Constants.floorInitDb
        var expected: [Double] = []
        for index in 0..<50 {
            let loud = index % 4 == 2
            let db = loud ? -30.0 : -60.0
            if loud {
                expected.append(ConversationAudioMath.level(db: db, floorDb: floor))
            } else {
                // Only quiet frames update the noise floor (same recurrence as VAD).
                floor += VoiceConversationLogic.Constants.floorAlpha * (db - floor)
            }
            controller.conversationAudio(didCaptureFrame: index, db: db)
            clock.nowMs += 20
        }
        token.cancel()
        #expect(published.count <= 15)
        // The loud frames 2, 6…46 each fall in the windows published at frames 4, 8…48 (the publish at frame 0 is 0 and does not count as a change).
        #expect(published.count == expected.count)
        for (value, peak) in zip(published, expected) { #expect(abs(value - peak) < 1e-9) }
        #expect(published.allSatisfy { $0 > 0.45 })
    }

    @Test("mic level is mapped against the current VAD noise floor")
    func levelFollowsNoiseFloor() async throws {
        let controller = makeController()
        try controller.start()
        // 100 frames at −70 dB pull the noise floor down; the same −50 dB is 0 against the original floor (−50) and now clearly lights up.
        var floor = VoiceConversationLogic.Constants.floorInitDb
        for index in 0..<100 {
            controller.conversationAudio(didCaptureFrame: index, db: -70)
            floor += VoiceConversationLogic.Constants.floorAlpha * (-70 - floor)
            clock.nowMs += 20
        }
        controller.conversationAudio(didCaptureFrame: 100, db: -50)
        #expect(ConversationAudioMath.level(db: -50, floorDb: VoiceConversationLogic.Constants.floorInitDb) == 0)
        #expect(abs(controller.level - ConversationAudioMath.level(db: -50, floorDb: floor)) < 1e-9)
        #expect(controller.level > 0.45)
    }

    @Test("playback level is mapped against the fixed -50 dB AI floor and published as the window peak")
    func playbackLevelMapping() async throws {
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        #expect(controller.displayState == .speaking)
        clock.nowMs += 100
        controller.conversationAudio(didMeasureOutput: -26)
        #expect(abs(controller.level - 0.6) < 1e-9)
        clock.nowMs += 20
        controller.conversationAudio(didMeasureOutput: -20)
        clock.nowMs += 20
        controller.conversationAudio(didMeasureOutput: -40)
        #expect(abs(controller.level - 0.6) < 1e-9)
        clock.nowMs += 40
        controller.conversationAudio(didMeasureOutput: -40)
        #expect(abs(controller.level - 0.8) < 1e-9)
        clock.nowMs += 80
        controller.conversationAudio(didMeasureOutput: ConversationAudioMath.silenceDb)
        #expect(controller.level == 0)
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

/// Recording-file recognition never returns (until cancelled).
private nonisolated final class HangingSTT: STTEngine, @unchecked Sendable {
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return ""
    }
}

private nonisolated final class ScriptedSTT: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _script: [Result<String, Error>] = []
    private var _calls = 0
    private var _languages: [String?] = []

    var languages: [String?] { lock.withLock { _languages } }

    var script: [Result<String, Error>] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        let next: Result<String, Error> = lock.withLock {
            _calls += 1
            _languages.append(language)
            return _script.isEmpty ? .success("") : _script.removeFirst()
        }
        return try next.get()
    }
}

/// Live recognition fake: each startLive opens one fake session; recording-file recognition goes to ScriptedSTT.
private nonisolated final class FakeLiveSTT: LiveSTTEngine, @unchecked Sendable {
    private let file: ScriptedSTT
    private let lock = NSLock()
    private var _sessions: [FakeLiveSession] = []
    private var _nextEnding: FakeLiveSession.Ending = .text("")

    init(file: ScriptedSTT) { self.file = file }

    var sessions: [FakeLiveSession] { lock.withLock { _sessions } }

    /// How sessions opened afterwards wrap up when input ends.
    var nextEnding: FakeLiveSession.Ending {
        get { lock.withLock { _nextEnding } }
        set { lock.withLock { _nextEnding = newValue } }
    }

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        try await file.transcribe(recording, language: language)
    }

    func startLive(language: String?) -> SystemSTTSession {
        let session = FakeLiveSession(language: language, ending: nextEnding)
        lock.withLock { _sessions.append(session) }
        return SystemSTTSession { stream, onResult in try await session.run(stream, onResult) }
    }
}

private nonisolated final class FakeLiveSession: @unchecked Sendable {
    enum Ending: Sendable, CustomStringConvertible {
        case text(String)
        case failure
        case hang

        var description: String {
            switch self {
            case .text(let text): return "text(\(text))"
            case .failure: return "failure"
            case .hang: return "hang"
            }
        }
    }

    let language: String?
    private let ending: Ending
    private let lock = NSLock()
    private var _fedFrames: [Int] = []
    private var _cancelled = false
    private var _inputEnded = false
    private var onResult: (@Sendable (SystemSTTResult) -> Void)?

    init(language: String?, ending: Ending) {
        self.language = language
        self.ending = ending
    }

    var fedFrames: [Int] { lock.withLock { _fedFrames } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    /// Input ends normally (finish), not cancelled.
    var inputEnded: Bool { lock.withLock { _inputEnded } }

    func partial(_ text: String) { deliver(SystemSTTResult(text: text, isFinal: false)) }
    func final(_ text: String) { deliver(SystemSTTResult(text: text, isFinal: true)) }

    private func deliver(_ result: SystemSTTResult) {
        let onResult = lock.withLock { self.onResult }
        onResult?(result)
    }

    func run(_ stream: AsyncStream<PCMChunk>, _ onResult: @escaping @Sendable (SystemSTTResult) -> Void) async throws -> String {
        lock.withLock { self.onResult = onResult }
        return try await withTaskCancellationHandler {
            for await chunk in stream {
                let frames = Int(chunk.buffer.frameLength)
                lock.withLock { _fedFrames.append(frames) }
            }
            try Task.checkCancellation()
            lock.withLock { _inputEnded = true }
            switch ending {
            case .text(let text): return text
            case .failure: throw FakeSTTFailure()
            case .hang:
                try await Task.sleep(for: .seconds(30))
                return ""
            }
        } onCancel: {
            lock.withLock { _cancelled = true }
        }
    }
}

/// Holds the engine selection until open.
@MainActor
private final class ChoiceGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
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

/// Manual clock: advance only fires timers that are due; a one-shot timer becomes invalid after it fires.
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

    /// Number of one-shot timers waiting to fire.
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

struct VadModeRecord: Equatable {
    let mode: String
    let reason: String?
}

@MainActor
final class VadModeDiagnosticsSpy: VoiceConversationDiagnostics {
    private(set) var modes: [VadModeRecord] = []
    func vadMode(mode: String, reason: String?) { modes.append(VadModeRecord(mode: mode, reason: reason)) }
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
    /// The current utterance has already reported playback complete (the last chunk's dataPlayedBack).
    private var pendingPlayedBack = false
    var finishes = 0
    /// Recording duration handed over at wrap-up (seconds).
    var recordingDurationSec = 1.0

    /// Order of prepareSession / start ("prepare" / "start").
    var lifecycle: [String] = []
    var prepared = 0

    func prepareSession() async throws {
        prepared += 1
        lifecycle.append("prepare")
    }

    func start() throws {
        started += 1
        lifecycle.append("start")
    }

    func stop() {
        stopped += 1
        resolve(.stopped)
    }

    func setCaptureMuted(_ muted: Bool) { self.muted = muted }
    func pauseCapture() { capturePaused = true }
    func resumeCapture() { capturePaused = false }
    var begins = 0
    /// The live sink handed in each time an utterance opens (nil = this utterance does not open live recognition).
    var liveSinks: [ConversationLiveSink?] = []
    func beginUtterance(fromFrame frame: Int) {
        begins += 1
        utteranceOpen = true
    }

    func beginUtterance(fromFrame frame: Int, live: ConversationLiveSink?) {
        liveSinks.append(live)
        beginUtterance(fromFrame: frame)
    }

    /// When true, recording wrap-up suspends until deliverRecordings (simulates the close on the io queue not yet finished).
    var holdRecordings = false
    private var heldRecordings: [@MainActor () -> Void] = []

    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) {
        finishes += 1
        var recording: RecordingResult?
        if utteranceOpen {
            utteranceOpen = false
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).aac")
            recording = RecordingResult(url: url, durationSec: recordingDurationSec, envelope: [])
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
        guard holdPlayback else {
            // Same order as VPIO: the last chunk's dataPlayedBack reports playback complete first, then returns.
            delegate?.conversationAudioDidFinishPlayback()
            return .finished
        }
        pendingPlayedBack = false
        return await withCheckedContinuation { pending = $0 }
    }

    /// Reports only that the last chunk has finished playing (dataPlayedBack); speak / play do not return yet.
    func reportPlayedBack() {
        guard pending != nil, !pendingPlayedBack else { return }
        pendingPlayedBack = true
        delegate?.conversationAudioDidFinishPlayback()
    }

    func completeCurrent(_ outcome: ConversationPlaybackOutcome = .finished) {
        if outcome == .finished { reportPlayedBack() }
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

// MARK: - Host feedback: haptic / light-tap signals, captions, hint start and end

extension VoiceConversationControllerTests {
    @Test("hostFeedback: haptic effects reach onHaptic; an echo barge-in bumps nudgeCount")
    func hostFeedback_haptic_and_nudge() async throws {
        audio.route = .speaker
        let controller = makeController()
        var haptics: [VoiceConversationLogic.Haptic] = []
        controller.onHaptic = { haptics.append($0) }
        try controller.start()
        #expect(haptics == [.light])
        #expect(controller.nudgeCount == 0)

        await speakingTurn(controller, reply: "The weather is nice today. More")
        // Heard: the heard haptic
        #expect(haptics.count >= 2)
        stt.script.append(.success("the weather is nice"))
        bargeIn(controller)
        await settle()
        #expect(audio.resumes == [true])
        #expect(controller.nudgeCount == 1)
    }

    @Test("hostFeedback: caption = caption(state) after every reduce; follows the partial while the user speaks")
    func hostFeedback_caption_follows_partial() async throws {
        let controller = makeController()
        try controller.start()
        #expect(controller.caption == nil)
        feed(controller, -60, 10)
        feed(controller, -30, 20)
        controller.receivePartial("hello")
        #expect(controller.statusKey == .caption)
        #expect(controller.caption == "hello")
        controller.receivePartial("hello there")
        #expect(controller.caption == "hello there")
        #expect(controller.caption == VoiceConversationLogic.caption(controller.state))

        stt.script.append(.success("hello there"))
        feed(controller, -60, 30)
        await settle()
        #expect(chat.sent == ["hello there"])
        #expect(controller.caption == nil)
        #expect(controller.caption == VoiceConversationLogic.caption(controller.state))
    }

    @Test(
        "hostFeedback: a prompt reports promptStarted with the spoken text and promptEnded however playback ends",
        arguments: [ConversationPlaybackOutcome.finished, .failed, .stopped]
    )
    func hostFeedback_prompt_started_and_ended(_ outcome: ConversationPlaybackOutcome) async throws {
        let controller = makeController()
        try controller.start()
        stt.script = [.failure(FakeSTTFailure()), .failure(FakeSTTFailure())]
        audio.holdPlayback = true
        feed(controller, -60, 10)
        utterance(controller)
        await settle()
        #expect(audio.spoken == ["PROMPT didNotCatch"])
        #expect(controller.state.promptPlaying)
        #expect(controller.state.spoken == ["PROMPT didNotCatch"])

        audio.completeCurrent(outcome)
        await settle()
        #expect(!controller.state.promptPlaying)
        #expect(controller.displayState == .listening)
    }

    @Test("hostFeedback: a prompt still playing when the conversation ends leaves nothing behind for the next one")
    func hostFeedback_prompt_cut_by_end_does_not_leak() async throws {
        let controller = makeController()
        try controller.start()
        await firstTurn(controller)
        audio.holdPlayback = true
        chat.emit(.approvalPending(true))
        await settle()
        #expect(audio.spoken == ["PROMPT approvalNeeded"])
        #expect(controller.state.promptPlaying)

        controller.end(.user)
        await settle()
        #expect(!controller.isActive)
        try controller.start()
        await settle()
        #expect(!controller.state.promptPlaying)
        #expect(controller.state.spoken.isEmpty)
        #expect(controller.displayState == .listening)
    }
}

// MARK: - Host value alignment: barge-in candidate window and grace, hint interjection, live result count

extension VoiceConversationControllerTests {
    @Test("hostRules: speech started in the gap between two sentences is still a barge-in; the next sentence does not restart the grace")
    func hostRules_gap_between_sentences_is_candidate() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. It will rain tomorrow. More")
        #expect(audio.spoken == ["The weather is nice today."])
        feed(controller, -60, 50)
        // First sentence finished, second not yet started: speaking in the gap between sentences
        audio.completeCurrent()
        feed(controller, -30, 8)
        await settle()
        #expect(audio.spoken.last == "It will rain tomorrow.")
        #expect(audio.pauses == 0)
        feed(controller, -30, 12)
        #expect(audio.pauses == 1)
        #expect(controller.state.bargeIn)
    }

    @Test("hostRules: the grace is set once when playback starts and on every resume, not per sentence")
    func hostRules_grace_once_per_start_and_resume() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. It will rain tomorrow. More")
        // First sentence starts: voice within the 1 s grace does not count as barge-in
        feed(controller, -30, 45)
        feed(controller, -60, 40)
        #expect(audio.pauses == 0)
        audio.completeCurrent()
        await settle()
        #expect(audio.spoken.last == "It will rain tomorrow.")
        // The second sentence starting does not reset the grace: speaking immediately is a barge-in
        feed(controller, -30, 20)
        #expect(audio.pauses == 1)
        stt.script.append(.success("it will rain"))
        feed(controller, -60, 30)
        await settle()
        #expect(audio.resumes == [true])
        // resume resets the grace: voice within 1 s does not count as barge-in
        feed(controller, -30, 45)
        feed(controller, -60, 40)
        #expect(audio.pauses == 1)
    }

    @Test("hostRules: a drain while the reply still streams keeps the window; the next sentence does not restart the grace")
    func hostRules_streaming_drain_keeps_grace() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        feed(controller, -60, 50)
        // The only sentence finished and the reply is still streaming: the queue is momentarily empty
        audio.completeCurrent()
        await settle()
        chat.emit(.text("The weather is nice today. It will rain tomorrow. More"))
        await settle()
        #expect(audio.spoken.last == "It will rain tomorrow.")
        // The next sentence starting does not reset the grace: speaking immediately is a barge-in
        feed(controller, -30, 20)
        #expect(audio.pauses == 1)
        #expect(controller.state.bargeIn)
    }

    @Test("hostRules: speech in the gap after a drain while the reply still streams is still a barge-in")
    func hostRules_streaming_drain_gap_is_candidate() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        feed(controller, -60, 50)
        audio.completeCurrent()
        await settle()
        #expect(controller.state.phase == .speaking)
        // The next sentence has not arrived: speaking in the gap
        feed(controller, -30, 20)
        #expect(controller.state.bargeIn)
        #expect(audio.pauses == 1)
    }

    @Test("hostRules: the drain after the reply completes closes the window; the next reply restarts the grace")
    func hostRules_completed_drain_closes_window() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. More")
        feed(controller, -60, 50)
        // Briefly empty midway through streaming (window kept), then the reply completes with no new sentence: the drained at completion closes the window
        audio.completeCurrent()
        await settle()
        chat.emit(.text("The weather is nice today."))
        chat.emit(.completed)
        await settle()
        #expect(controller.displayState == .listening)
        // The first sentence of the next turn resets the grace: voice within 1 s does not count as barge-in
        await speakingTurn(controller, reply: "It will rain tomorrow. More")
        #expect(audio.spoken.last == "It will rain tomorrow.")
        feed(controller, -30, 45)
        feed(controller, -60, 40)
        #expect(audio.pauses == 0)
    }

    @Test("hostRules: prompts play right after the current sentence and before the rest of the reply, first in first out")
    func hostRules_prompts_after_current_sentence_fifo() async throws {
        audio.route = .speaker
        let controller = makeController()
        try controller.start()
        await speakingTurn(controller, reply: "The weather is nice today. It will rain tomorrow. Bring an umbrella. More")
        chat.emit(.approvalPending(true))
        await settle()
        chat.emit(.approvalPending(false))
        await settle()
        // Two false speaker-echo barge-ins → echoHint is sent after the second
        await falseBargeIn(controller)
        await falseBargeIn(controller)
        #expect(controller.statusKey == .speakingTapToInterrupt)
        #expect(audio.spoken == ["The weather is nice today."])
        for _ in 0..<3 {
            audio.completeCurrent()
            await settle()
        }
        #expect(audio.spoken == [
            "The weather is nice today.", "PROMPT approvalNeeded", "PROMPT echoHint", "It will rain tomorrow.",
        ])
    }

    @Test(
        "hostRules: a live result that falls back to the file counts as one attempt with the final result",
        .timeLimit(.minutes(1))
    )
    func hostRules_live_fallback_counts_one_attempt() async throws {
        #expect(VoiceConversationController.liveFinishLimit == .milliseconds(1500))
        for ending in [FakeLiveSession.Ending.text("  "), .failure, .hang] {
            let live = FakeLiveSTT(file: stt)
            live.nextEnding = ending
            let sentBefore = chat.sent.count
            let controller = makeController(engine: live, liveFinishLimit: .milliseconds(50))
            try controller.start()
            await settle()
            stt.script = [.success("from file")]
            feed(controller, -60, 10)
            utterance(controller)
            await settle { chat.sent.count == sentBefore + 1 }
            controller.end(.system)
            await settle()
        }
    }
}
