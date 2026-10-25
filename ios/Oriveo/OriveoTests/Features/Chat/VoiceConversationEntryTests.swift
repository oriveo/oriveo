import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

// Voice conversation entry, gates, the ChatPort bridge, session lifecycle, VoiceOver and copy.

@Suite("Voice conversation main button")
struct VoiceConversationMainButtonTests {
    static func model(_ id: String = "gpt-5.6", capabilities: [ModelCapability] = [.text]) -> AIModel {
        AIModel(
            id: id,
            name: id,
            capabilities: capabilities,
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "$$"
        )
    }

    @Test("empty draft shows ≋, text shows ↑, generating shows ■")
    func threeStates() {
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true
        ) == .voice)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: true, sendEnabled: true, voiceAvailable: true, modelProducesText: true
        ) == .send(enabled: true))
        #expect(VoiceConversationEntry.primaryAction(
            isSending: true, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true
        ) == .stop)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: true, hasContent: true, sendEnabled: true, voiceAvailable: true, modelProducesText: true
        ) == .stop)
    }

    @Test("when the model can only generate images or the page is unavailable, an empty draft keeps a gray ↑")
    func imageOnlyKeepsGreyArrow() {
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: false
        ) == .send(enabled: false))
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: false, modelProducesText: true
        ) == .send(enabled: false))
    }

    @Test("whether it can produce text: metadata has imageGen without text, and a dedicated image-generation model says no")
    func modelProducesText() {
        #expect(VoiceConversationEntry.modelProducesText(Self.model()))
        #expect(VoiceConversationEntry.modelProducesText(Self.model(capabilities: [.text, .imageGen])))
        #expect(!VoiceConversationEntry.modelProducesText(Self.model("flux-pro", capabilities: [.imageGen])))
        #expect(!VoiceConversationEntry.modelProducesText(Self.model("gpt-image-2", capabilities: [.text, .image])))
        #expect(!VoiceConversationEntry.modelProducesText(nil))
    }

    @Test("within 500 ms after ■ turns back into ≋ it does not respond")
    func quietWindowAfterStop() {
        var guardState = VoiceEntryTapGuard()
        #expect(guardState.acceptsTap(atMs: 10))
        guardState.generationEnded(atMs: 1_000)
        #expect(!guardState.acceptsTap(atMs: 1_000))
        #expect(!guardState.acceptsTap(atMs: 1_499))
        #expect(guardState.acceptsTap(atMs: 1_500))
    }

    @Test("the button-layer quiet window takes the rule constant stopToVoiceGuardMs: the last 1 ms inside the window does not respond, and it responds on the dot")
    func stopToVoiceGuardUsesRuleConstant() {
        let quiet = VoiceConversationLogic.Constants.stopToVoiceGuardMs
        #expect(VoiceEntryTapGuard.quietMs == quiet)
        var guardState = VoiceEntryTapGuard()
        guardState.generationEnded(atMs: 20_000)
        #expect(!guardState.acceptsTap(atMs: 20_000 + quiet - 1))
        #expect(guardState.acceptsTap(atMs: 20_000 + quiet))
        // Restart the count when generation stops again.
        guardState.generationEnded(atMs: 30_000)
        #expect(!guardState.acceptsTap(atMs: 30_000 + quiet - 1))
    }
}

@Suite("Home composer actions")
struct HomeComposerActionsTests {
    @Test("home empty draft: ↑ is tappable (enters the chat page) and the ≋ secondary button shows")
    func home_empty_draft_send_and_voice() {
        #expect(VoiceConversationEntry.homeComposer(
            isSending: false, hasContent: false, voiceAvailable: true, modelProducesText: true
        ) == HomeComposerActions(sendEnabled: true, showsVoice: true))
    }

    @Test("home with text: only ↑, ≋ is hidden")
    func home_text_send_only() {
        #expect(VoiceConversationEntry.homeComposer(
            isSending: false, hasContent: true, voiceAvailable: true, modelProducesText: true
        ) == HomeComposerActions(sendEnabled: true, showsVoice: false))
    }

    @Test("home cannot enter a voice conversation: ≋ is hidden with no grayed-out key, and ↑ stays tappable")
    func home_voice_unavailable_hides_voice() {
        #expect(VoiceConversationEntry.homeComposer(
            isSending: false, hasContent: false, voiceAvailable: false, modelProducesText: true
        ) == HomeComposerActions(sendEnabled: true, showsVoice: false))
    }

    @Test("home with an image-only model: ≋ is hidden, ↑ stays tappable")
    func home_image_only_hides_voice() {
        let imageOnly = VoiceConversationMainButtonTests.model("flux-pro", capabilities: [.imageGen])
        #expect(VoiceConversationEntry.homeComposer(
            isSending: false,
            hasContent: false,
            voiceAvailable: true,
            modelProducesText: VoiceConversationEntry.modelProducesText(imageOnly)
        ) == HomeComposerActions(sendEnabled: true, showsVoice: false))
    }

    @Test("home while sending / while a disclosure confirmation is pending: ↑ is not tappable and ≋ is hidden")
    func home_sending_disables_both() {
        for hasContent in [false, true] {
            #expect(VoiceConversationEntry.homeComposer(
                isSending: true, hasContent: hasContent, voiceAvailable: true, modelProducesText: true
            ) == HomeComposerActions(sendEnabled: false, showsVoice: false))
        }
    }
}

@Suite("Voice conversation entry gates")
struct VoiceConversationEntryGateTests {
    @Test("same order as sending: provider disclosure, then pass")
    func gateOrder() {
        func gate(_ kind: ProviderKind?, accepted: Bool = true, chat: Bool = true) -> ChatVoiceConversationGate {
            ChatVoiceConversationGate.evaluate(
                providerKind: kind,
                providerDisclosureAccepted: chat ? { _ in accepted } : nil
            )
        }
        #expect(gate(.openAI, accepted: false) == .providerDisclosure(.openAI))
        #expect(gate(.openAI, accepted: true) == .open)
        // Home goes like sendFromHero: not through the provider disclosure.
        #expect(gate(.openAI, accepted: false, chat: false) == .open)
    }
}

// MARK: - ChatPort bridge

/// @Observable: the port observes hasPendingToolApproval with withObservationTracking (the same approach as AppState reading the MCP confirmation queue).
@MainActor
@Observable
final class FakeVoiceChatHost: VoiceConversationChatHost {
    var streaming: [UUID: String] = [:]
    var busy: Set<UUID> = []
    var lastAssistant: [UUID: ChatMessage] = [:]
    var hasPendingToolApproval = false
    var cancelled: [UUID] = []
    let textSubject = PassthroughSubject<Void, Never>()
    /// Stream-finished signal (a stand-in for ChatManager.streamingDidFinish).
    let finishSubject = PassthroughSubject<Void, Never>()

    func streamingText(in conversationID: UUID) -> String { streaming[conversationID] ?? "" }
    func streamingTextDidChange(in conversationID: UUID) -> AnyPublisher<Void, Never> { textSubject.eraseToAnyPublisher() }
    func streamingDidFinish(in conversationID: UUID) -> AnyPublisher<Void, Never> { finishSubject.eraseToAnyPublisher() }
    func isBusyStreaming(in conversationID: UUID) -> Bool { busy.contains(conversationID) }
    func lastAssistantMessage(in conversationID: UUID) -> ChatMessage? { lastAssistant[conversationID] }
    func cancelGeneration(in conversationID: UUID) { cancelled.append(conversationID) }
}

/// A clock that does not advance on its own: tick() manually fires every timer callback that has not been cancelled.
final class PortManualClock: VoiceConversationClock {
    private final class Entry: VoiceConversationTimer {
        let handler: () -> Void
        var cancelled = false
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        func cancel() { cancelled = true }
    }

    var nowMs = 0
    private var entries: [Entry] = []

    func after(ms: Int, _ handler: @escaping () -> Void) -> VoiceConversationTimer {
        let entry = Entry(handler)
        entries.append(entry)
        return entry
    }

    func tick() {
        for entry in entries where !entry.cancelled { entry.handler() }
    }
}

@MainActor
final class EventCollector {
    var events: [VoiceConversationReplyEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<VoiceConversationReplyEvent>) {
        task = Task { @MainActor [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func stop() { task?.cancel() }
}

@MainActor
@Suite("AppState voice chat port")
struct AppStateVoiceChatPortTests {
    @Test("home: no conversation is created before the first send; send passes nil so AppState creates it, and it then follows the new conversation id")
    func homeFirstSendCreatesConversation() async {
        let host = FakeVoiceChatHost()
        let created = UUID()
        var sends: [(String, UUID?)] = []
        let port = AppStateVoiceChatPort(host: host, conversationID: nil) { text, id in
            sends.append((text, id))
            return .sent(id ?? created)
        }
        var changed: [UUID] = []
        port.onConversationChanged = { changed.append($0) }
        _ = port.makeReplyEvents()
        #expect(sends.isEmpty)
        #expect(port.conversationID == nil)

        #expect(await port.send("\u{7B2C}\u{4E8C}\u{5929}\u{80FD}\u{4E0D}\u{80FD}\u{6362}\u{6210}\u{5948}\u{826F}"))
        #expect(await port.send("\u{90A3}\u{7B2C}\u{4E09}\u{5929}\u{5462}"))
        #expect(sends.map(\.1) == [nil, created])
        #expect(port.conversationID == created)
        #expect(changed == [created])
    }

    @Test("reply events: streaming text -> after the stream-finished signal, reading a delivered message gives completed; only new replies after the send count")
    func replyEventsFromStreamingAndFinalState() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let old = TestFactories.makeMessage(role: .assistant, text: "\u{65E7}\u{56DE}\u{7B54}", state: .delivered)
        host.lastAssistant[conversation] = old
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        let collector = EventCollector(port.makeReplyEvents())
        #expect(await port.send("\u{8BB2}\u{8BB2}\u{5948}\u{826F}"))
        // The old answer is still there and the new reply has not appeared: not completed.
        host.finishSubject.send()

        let replyID = UUID()
        host.busy.insert(conversation)
        host.lastAssistant[conversation] = TestFactories.makeMessage(id: replyID, role: .assistant, text: "", state: .generating)
        host.streaming[conversation] = "\u{53EF}\u{4EE5}\u{3002}"
        host.textSubject.send()
        host.streaming[conversation] = "\u{53EF}\u{4EE5}\u{3002}\u{4E0A}\u{5348}\u{4E1C}\u{5927}\u{5BFA}"
        host.textSubject.send()
        host.busy.remove(conversation)
        host.streaming[conversation] = nil
        host.lastAssistant[conversation] = TestFactories.makeMessage(
            id: replyID, role: .assistant, text: "\u{53EF}\u{4EE5}\u{3002}\u{4E0A}\u{5348}\u{4E1C}\u{5927}\u{5BFA}\u{FF0C}\u{4E0B}\u{5348}\u{5948}\u{826F}\u{516C}\u{56ED}\u{3002}", state: .delivered
        )
        host.finishSubject.send()
        await collector.settle()

        #expect(collector.events == [
            .text("\u{53EF}\u{4EE5}\u{3002}"),
            .text("\u{53EF}\u{4EE5}\u{3002}\u{4E0A}\u{5348}\u{4E1C}\u{5927}\u{5BFA}"),
            .text("\u{53EF}\u{4EE5}\u{3002}\u{4E0A}\u{5348}\u{4E1C}\u{5927}\u{5BFA}\u{FF0C}\u{4E0B}\u{5348}\u{5948}\u{826F}\u{516C}\u{56ED}\u{3002}"),
            .completed,
        ])
        #expect(port.completedTurns == 1)
        collector.stop()
    }

    @Test("failure reads ChatMessage.state = failed; approval observes the MCP confirmation queue; cancel goes through stop generation")
    func failureApprovalAndCancel() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        let collector = EventCollector(port.makeReplyEvents())
        #expect(await port.send("\u{6253}\u{5F00}\u{65E5}\u{5386}"))

        host.hasPendingToolApproval = true
        await collector.settle()
        host.hasPendingToolApproval = false
        await collector.settle()
        port.cancel()
        host.lastAssistant[conversation] = TestFactories.makeMessage(role: .assistant, text: "", state: .failed)
        host.finishSubject.send()
        await collector.settle()

        #expect(collector.events == [.approvalPending(true), .approvalPending(false), .failed(code: "reply_failed")])
        #expect(host.cancelled == [conversation])
        #expect(port.completedTurns == 0)
        collector.stop()
    }

    @Test("an interrupted reply still completes as usual but does not count toward turn_count")
    func interrupted_reply_not_counted() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        let collector = EventCollector(port.makeReplyEvents())

        #expect(await port.send("\u{8BB2}\u{8BB2}\u{5948}\u{826F}"))
        host.lastAssistant[conversation] = TestFactories.makeMessage(role: .assistant, text: "\u{53EF}\u{4EE5}\u{3002}\u{4E0A}\u{5348}", state: .interrupted)
        host.finishSubject.send()
        #expect(await port.send("\u{90A3}\u{4EAC}\u{90FD}\u{5462}"))
        host.lastAssistant[conversation] = TestFactories.makeMessage(role: .assistant, text: "\u{4EAC}\u{90FD}\u{5F88}\u{8FD1}\u{3002}", state: .delivered)
        host.finishSubject.send()
        await collector.settle()

        #expect(collector.events == [.text("\u{53EF}\u{4EE5}\u{3002}\u{4E0A}\u{5348}"), .completed, .text("\u{4EAC}\u{90FD}\u{5F88}\u{8FD1}\u{3002}"), .completed])
        #expect(port.completedTurns == 1)
        collector.stop()
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func refusedSend() async {
        let port = AppStateVoiceChatPort(host: FakeVoiceChatHost(), conversationID: nil) { _, _ in
            .refused
        }
        #expect(await port.send("\u{4F60}\u{597D}") == false)
        #expect(port.conversationID == nil)
    }
}

// MARK: - Session lifecycle and VoiceOver

@MainActor
final class SessionProbe {
    var announcements: [String] = []
    var toasts: [String] = []
    var voiceOver = false
    var audio = FakeConversationAudio()

    func dependencies(listening: DictationEngineChoice? = DictationEngineChoice(
        engine: SilentSTT(), isSystem: true, fallback: nil
    )) -> VoiceConversationSession.Dependencies {
        VoiceConversationSession.Dependencies(
            prepareListening: { listening },
            makeController: { [self] choice, port in
                VoiceConversationController(
                    audio: audio,
                    dictation: DictationEngineSource { choice },
                    readAloud: .fixed(MuteSpeechEngine()),
                    chat: port,
                    prompt: VoiceConversationCopy.prompt,
                    clock: PortManualClock(),
                    memory: VoiceBargeInMemory(defaults: UserDefaults(suiteName: "voice-session-\(UUID())")!, osMajorVersion: 27),
                    stopReadAloud: {},
                    detectLanguage: { _ in "en" }
                )
            },
            toast: { [self] in toasts.append($0) },
            isVoiceOverRunning: { [self] in voiceOver },
            announce: { [self] in announcements.append($0) },
            leaveGraceNanoseconds: 0
        )
    }
}

/// Transcription hangs until the test releases it in order; used to make a draft arrive only after the new conversation has started.
nonisolated final class HeldSTT: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<String, Never>] = []

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
    }

    func release(_ text: String) {
        let next: CheckedContinuation<String, Never>? = lock.withLock {
            waiting.isEmpty ? nil : waiting.removeFirst()
        }
        next?.resume(returning: text)
    }
}

nonisolated final class SilentSTT: STTEngine, @unchecked Sendable {
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String { "" }
}

/// Always transcribes the same sentence; counts calls (a ghost utterance would add one more transcription).
nonisolated final class FixedTextSTT: STTEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(text: String) { self.text = text }

    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        lock.withLock { _calls += 1 }
        return text
    }
}

final class MuteSpeechEngine: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice: Bool { true }
    func speak(_ utterances: [SpeechUtterance]) {}
    func stop() {}
}

@MainActor
@Suite("Voice conversation session")
struct VoiceConversationSessionTests {
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    @Test("home zero-turn exit: send is not called and no conversation is created")
    func homeZeroTurnExitLeavesNoTrace() async {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        var sends = 0
        let started = await session.start(origin: .home, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in
            sends += 1
            return .refused
        }
        #expect(started)
        #expect(session.isPresented(in: nil))
        #expect(probe.audio.started == 1)

        session.end(.user)
        await settle()

        #expect(sends == 0)
        #expect(!session.isActive)
        // No draft: no new delivery is produced.
        #expect(session.lastEnd == nil)
    }

    @Test("a pending-approval change reaches the reducer without a timer: when the confirmation queue changes, the status orb enters and leaves awaitingApproval")
    func approval_change_reaches_reducer_without_timer() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: DictationEngineChoice(
            engine: FixedTextSTT(text: "\u{6253}\u{5F00}\u{65E5}\u{5386}"), isSystem: true, fallback: nil
        )))
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        await session.start(origin: .chat, conversationID: conversation, host: host) { _, id in .sent(id ?? conversation) }
        await settle()
        let controller = try #require(session.controller)
        // 200 ms of silence + 400 ms of speech + 600 ms of silence -> one complete utterance; the session clock never ticks.
        var frame = 0
        for db in Array(repeating: -60.0, count: 10) + Array(repeating: -30.0, count: 20) + Array(repeating: -60.0, count: 30) {
            controller.conversationAudio(didCaptureFrame: frame, db: db)
            frame += 1
        }
        await settle()
        #expect(controller.displayState == .thinking)

        host.hasPendingToolApproval = true
        await settle()
        #expect(controller.displayState == .awaitingApproval)
        host.hasPendingToolApproval = false
        await settle()
        #expect(controller.displayState == .thinking)
        session.end(.user)
        await settle()
    }

    @Test("preparation failure (microphone denied etc.) does not enter the conversation")
    func preparationDenied() async {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: nil))
        let started = await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        #expect(!started)
        #expect(!session.isActive)
    }

    @Test("all pages leaving ends the conversation as a back (navigation); the home -> chat page handoff does not count as a back")
    func leavingHostEndsConversation() async {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        let conversation = UUID()
        session.hostAppeared(conversation)
        await session.start(origin: .chat, conversationID: conversation, host: FakeVoiceChatHost()) { _, _ in .refused }
        // Switching carriers: leave first and appear again, coming back within the grace period does not end it.
        session.hostAppeared(conversation)
        session.hostDisappeared(conversation)
        session.endIfHostGone()
        #expect(session.isActive)

        session.hostDisappeared(conversation)
        session.endIfHostGone()
        await settle()
        #expect(!session.isActive)
    }

    @Test("VoiceOver: a status text change is announced only once and pauses listening; listening resumes after the announcement ends; the body text is not announced")
    func screenReaderAnnouncesStatusOnly() async {
        let probe = SessionProbe()
        probe.voiceOver = true
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        await settle()

        session.statusChanged(.listening)
        session.statusChanged(.listening)
        #expect(probe.announcements == [VoiceConversationCopy.status(.listening)])
        let controller = session.controller
        #expect(controller?.state.screenReaderSpeaking == true)

        session.announcementFinished()
        #expect(controller?.state.screenReaderSpeaking == false)

        session.statusChanged(.muted)
        #expect(probe.announcements == [VoiceConversationCopy.status(.listening), VoiceConversationCopy.status(.muted)])
        session.end(.user)
        await settle()
    }

    @Test("VoiceOver on: five rounds of conversation, voice frames fed during every status announcement, and the user messages are still only five")
    func screenReaderFiveRoundsNoGhost() async throws {
        let probe = SessionProbe()
        probe.voiceOver = true
        let stt = FixedTextSTT(text: "question")
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: DictationEngineChoice(
            engine: stt, isSystem: true, fallback: nil
        )))
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        var userMessages: [String] = []
        await session.start(origin: .chat, conversationID: conversation, host: host) { text, id in
            userMessages.append(text)
            return .sent(id ?? conversation)
        }
        await settle()
        let controller = try #require(session.controller)

        var frame = 0
        var ghostsFed = 0
        func feed(_ db: Double, _ count: Int) {
            for _ in 0..<count {
                controller.conversationAudio(didCaptureFrame: frame, db: db)
                frame += 1
            }
        }
        // 200 ms of silence + 400 ms of speech + 600 ms of silence -> one complete utterance.
        func utterance() {
            feed(-60, 10)
            feed(-30, 20)
            feed(-60, 30)
        }
        // Speaking during a status announcement: it should be dropped; listening resumes once the announcement ends.
        func speakOverAnnouncement() async {
            guard controller.state.screenReaderSpeaking else { return }
            utterance()
            ghostsFed += 1
            await settle()
            session.announcementFinished()
        }

        for round in 1...5 {
            await speakOverAnnouncement()
            #expect(controller.state.screenReaderSpeaking == false)
            #expect(controller.displayState == .listening)
            #expect(userMessages.count == round - 1)

            utterance()
            await settle()
            #expect(userMessages.count == round)
            await speakOverAnnouncement()

            host.lastAssistant[conversation] = ChatMessage(
                id: UUID(), role: .assistant, text: "Answer \(round).", providerKind: .grok,
                providerName: "Grok", modelName: "grok-4.6", state: .delivered
            )
            host.textSubject.send()
            await settle()
            await speakOverAnnouncement()
        }

        #expect(userMessages == Array(repeating: "question", count: 5))
        #expect(stt.calls == 5)
        #expect(ghostsFed >= 10)
        #expect(probe.announcements.contains(VoiceConversationCopy.status(.thinking)))
        session.end(.user)
        await settle()
    }

    @Test("voice bar seam: statusKey follows the cascade controller, and muting is delivered through the seam")
    func bar_surface_reflects_cascade_controller() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        #expect(session.surface == nil)
        await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        await settle()

        let surface = try #require(session.surface)
        let controller = try #require(session.controller)
        #expect(surface === controller)
        #expect(surface.statusKey == .listening)
        #expect(surface.statusKey == controller.statusKey)

        surface.toggleMute()
        #expect(controller.statusKey == .muted)
        #expect(surface.statusKey == .muted)
        #expect(surface.displayState == .muted)

        session.end(.user)
        await settle()
        #expect(session.surface == nil)
    }

    @Test("cascade conversation continues in the background: after a background notification is posted through the injected center, three rounds still converse and it does not end")
    func cascadeBackgroundKeepsThreeRounds() async throws {
        let probe = SessionProbe()
        let center = NotificationCenter()
        var deps = probe.dependencies(listening: DictationEngineChoice(
            engine: FixedTextSTT(text: "question"), isSystem: true, fallback: nil
        ))
        deps.notificationCenter = center
        let session = VoiceConversationSession(dependencies: deps)
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        var userMessages: [String] = []
        await session.start(origin: .chat, conversationID: conversation, host: host) { text, id in
            userMessages.append(text)
            return .sent(id ?? conversation)
        }
        await settle()
        let controller = try #require(session.controller)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await settle()

        var frame = 0
        func feed(_ db: Double, _ count: Int) {
            for _ in 0..<count {
                controller.conversationAudio(didCaptureFrame: frame, db: db)
                frame += 1
            }
        }
        for round in 1...3 {
            #expect(session.isActive)
            #expect(controller.displayState == .listening)
            // 200 ms of silence + 400 ms of speech + 600 ms of silence -> one complete utterance.
            feed(-60, 10)
            feed(-30, 20)
            feed(-60, 30)
            await settle()
            #expect(userMessages.count == round)
            host.lastAssistant[conversation] = ChatMessage(
                id: UUID(), role: .assistant, text: "Answer \(round).", providerKind: .grok,
                providerName: "Grok", modelName: "grok-4.6", state: .delivered
            )
            host.textSubject.send()
            await settle()
        }

        #expect(userMessages == ["question", "question", "question"])
        #expect(session.isActive)
        #expect(session.controller === controller)
        #expect(session.lastEnd == nil)
        #expect(probe.audio.started == 1)
        #expect(probe.audio.stopped == 0)
        #expect(probe.audio.pauses == 0)
        session.end(.user)
        await settle()
    }

    @Test("a draft in flight at ✕: if a new conversation was opened before the transcription arrived it is not written into lastEnd; without a new conversation it is delivered as usual")
    func stale_draft_not_delivered_into_new_session() async throws {
        let probe = SessionProbe()
        let stt = HeldSTT()
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: DictationEngineChoice(
            engine: stt, isSystem: true, fallback: nil
        )))
        let conversation = UUID()
        var frame = 0
        func speakHalf(_ controller: VoiceConversationController) {
            for db in Array(repeating: -60.0, count: 10) + Array(repeating: -30.0, count: 20) {
                controller.conversationAudio(didCaptureFrame: frame, db: db)
                frame += 1
            }
        }

        await session.start(origin: .chat, conversationID: conversation, host: FakeVoiceChatHost()) { _, _ in .refused }
        let first = try #require(session.controller)
        speakHalf(first)
        #expect(first.state.userSpeaking)
        session.end(.user)
        #expect(!session.isActive)

        // A new conversation was opened while the draft was still being transcribed, and the old draft arrives afterwards.
        await session.start(origin: .chat, conversationID: conversation, host: FakeVoiceChatHost()) { _, _ in .refused }
        let second = try #require(session.controller)
        #expect(second !== first)
        await settle()
        stt.release("old draft")
        await settle()
        #expect(session.lastEnd == nil)

        // Control: without a new conversation the draft is delivered as usual.
        speakHalf(second)
        session.end(.user)
        await settle()
        stt.release("second draft")
        await settle()
        #expect(session.lastEnd?.draft == "second draft")
        #expect(session.lastEnd?.conversationID == conversation)
    }

    @Test("no announcement when VoiceOver is off")
    func noAnnouncementWithoutVoiceOver() async {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        session.statusChanged(.thinking)
        #expect(probe.announcements.isEmpty)
        session.end(.user)
        await settle()
    }
}

// MARK: - Copy

@Suite("Voice conversation copy")
struct VoiceConversationCopyTests {
    static func repoFile(_ relative: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test("the iOS keys of p2-copy.v1.json go into Voice.xcstrings verbatim (16 languages, manual), and the old settings copy is gone")
    func p2CopyInVoiceTable() throws {
        let copy = try Self.json(Self.repoFile("shared/voice-contracts/p2-copy.v1.json"))
        let table = try Self.json(Self.repoFile("ios/Oriveo/Oriveo/Voice.xcstrings"))
        let strings = try #require(table["strings"] as? [String: [String: Any]])
        let keys = try #require(copy["keys"] as? [String: [String: Any]])
        let locales = try #require(copy["locales"] as? [String])
        #expect(locales.count == 16)
        var checked = 0
        // Platform-specific keys follow the platforms field: absent = common to both platforms; a key without "ios" does not go into the iOS table.
        for (id, spec) in keys where (spec["platforms"] as? [String])?.contains("ios") ?? true {
            let values = try #require(spec["values"] as? [String: String], "\(id)")
            let english = try #require(values["en"], "\(id)")
            let entry = try #require(strings[english], "missing \(id)")
            #expect(entry["extractionState"] as? String == "manual", "\(id)")
            let localizations = try #require(entry["localizations"] as? [String: [String: [String: String]]], "\(id)")
            for locale in locales {
                #expect(localizations[locale]?["stringUnit"]?["value"] == values[locale], "\(id) \(locale)")
            }
            checked += 1
        }
        #expect(checked > 0)
        // Keys that are not for iOS leave no dead copy.
        for (id, spec) in keys {
            guard let platforms = spec["platforms"] as? [String], !platforms.contains("ios"),
                  let english = (spec["values"] as? [String: String])?["en"] else { continue }
            #expect(strings[english] == nil, "\(id) is not an iOS key")
        }
        let iosMap = try #require((copy["settingsKeyMap"] as? [String: Any])?["ios"] as? [String: String])
        for key in ["voice_settings_header", "voice_dictation_footer_cloud", "voice_dictation_footer_system_ios", "voice_read_aloud_footer"] {
            let old = try #require(iosMap[key])
            #expect(strings[old] == nil, "old \(key) still present")
        }
    }

    @Test("the settings page header / footer use the new copy")
    func settingsCopy() {
        #expect(VoiceSettingsModel.pageHeader == L10n.tr(
            "You don't need to change anything here: dictation, read aloud, and voice conversations use your device's built-in voice at no cost. For better accuracy or a nicer voice, switch to a provider you've connected.",
            table: .voice
        ))
        #expect(VoiceSettingsModel.pageHeader.contains("voice conversations") || AppLocalization.currentLanguage.rawValue != "en")
    }

    @Test("prompts: did not catch / please confirm / the placeholder sentence reuse the read-aloud copy")
    func prompts() {
        #expect(VoiceConversationCopy.prompt(.didNotCatch) == L10n.tr("Sorry, I didn't catch that.", table: .voice))
        #expect(VoiceConversationCopy.prompt(.approvalNeeded) == L10n.tr("Please confirm on the screen.", table: .voice))
        #expect(VoiceConversationCopy.prompt(.placeholder(.code)) == L10n.tr("Here's a code block.", table: .voice))
    }
}

// MARK: - Status text is never truncated

@Suite("Voice conversation bar status fits")
struct VoiceConversationBarStatusFitTests {
    /// The voice bar widths of the two hosts on a 375pt-wide device: the home hero card (page margin 20 + card padding 19) and the chat page input area (page margin 16).
    static let homeBarWidth: CGFloat = 375 - 2 * 20 - 2 * 19
    static let chatBarWidth: CGFloat = 375 - 2 * 16
    static let narrowestBarWidth: CGFloat = homeBarWidth

    static let statusKeyIDs: [VoiceConversationLogic.StatusKey: String] = [
        .listening: "voice_conversation_status_listening",
        .thinking: "voice_conversation_status_thinking",
        .speaking: "voice_conversation_status_speaking",
        .speakingTapToInterrupt: "voice_conversation_status_speaking_tap_to_interrupt",
        .muted: "voice_conversation_status_muted",
        .awaitingApproval: "voice_conversation_status_awaiting_approval",
        .error: "voice_conversation_status_error",
    ]

    @Test("reachability: the reachable states of the two pages match pageReachableStatusKeys in voice-conversation.v1.json")
    func reachability() throws {
        let contract = try VoiceConversationCopyTests.json(
            VoiceConversationCopyTests.repoFile("shared/voice-contracts/voice-conversation.v1.json")
        )
        let pages = try #require(contract["pageReachableStatusKeys"] as? [String: [String]])
        #expect(Set(pages.keys) == ["home", "chat"])
        for (page, name) in [(VoiceConversationPage.home, "home"), (VoiceConversationPage.chat, "chat")] {
            let raw = try #require(pages[name], "\(name)")
            let keys = raw.compactMap(VoiceConversationLogic.StatusKey.init(rawValue:))
            #expect(keys.count == raw.count, "\(name) has unknown status keys: \(raw)")
            #expect(Set(keys).count == keys.count, "\(name) duplicates")
            #expect(Set(keys) == page.reachableStatusKeys, "\(name)")
        }
        #expect(Set(Self.statusKeyIDs.keys) == VoiceConversationPage.chat.reachableStatusKeys)
    }

    /// Lay out in the given width with the voice bar's font (callout semibold, minimum scale, Dynamic Type cap) and return the line count; nil when a single word does not fit.
    static func lineCount(_ text: String, width: CGFloat) -> Int? {
        let category = UIContentSizeCategory(VoiceConversationBarContent.maxDynamicType)
        let base = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        let font = UIFont.systemFont(ofSize: base.pointSize * VoiceConversationBarContent.minimumScale, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        for word in text.split(whereSeparator: \.isWhitespace) {
            if (String(word) as NSString).size(withAttributes: attributes).width > width { return nil }
        }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return Int((rect.height / font.lineHeight).rounded(.up))
    }

    @Test("page x that page's reachable states: the longest one among the 16 languages takes <= 2 lines at the xLarge size and is not truncated", arguments: [
        (VoiceConversationPage.home, VoiceConversationBarStatusFitTests.homeBarWidth),
        (VoiceConversationPage.chat, VoiceConversationBarStatusFitTests.chatBarWidth),
    ])
    func longestStatusFitsTwoLines(page: VoiceConversationPage, barWidth: CGFloat) throws {
        let copy = try VoiceConversationCopyTests.json(
            VoiceConversationCopyTests.repoFile("shared/voice-contracts/p2-copy.v1.json")
        )
        let keys = try #require(copy["keys"] as? [String: [String: Any]])
        // Available width when the status text wraps (orb on top): bar width minus the side padding, the ✕ / mute hit areas and spacing, and the label padding (production layout constants).
        let bar = VoiceConversationBarContent.self
        let width = barWidth - 2 * bar.barPadding - 2 * bar.minimumHitSize - 2 * bar.controlSpacing - 2 * bar.labelPadding
        #expect(VoiceConversationBarContent.maxDynamicType == .xLarge)
        for status in page.reachableStatusKeys {
            let key = try #require(Self.statusKeyIDs[status])
            let values = try #require(keys[key]?["values"] as? [String: String], "\(key)")
            let longest = try #require(values.max { $0.value.count < $1.value.count })
            let lines = Self.lineCount(longest.value, width: width)
            #expect(lines != nil && lines! <= 2, "\(page) \(key) \(longest.key) \"\(longest.value)\" lines=\(String(describing: lines)) width=\(width)")
        }
    }

    @MainActor
    @Test("the voice bar lays out at the narrowest width, with the orb + status text still >= 44pt")
    func barLaysOutAtNarrowestWidth() throws {
        let content = VoiceConversationBarContent(
            displayState: .thinking,
            statusKey: .thinking,
            level: 0.4,
            onEnd: {},
            onOrb: {},
            onMute: {}
        )
        let host = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: "fr")))
        let size = host.sizeThatFits(in: CGSize(width: Self.narrowestBarWidth, height: 400))
        #expect(size.width <= Self.narrowestBarWidth + 0.5)
        #expect(size.height >= VoiceConversationBarContent.minimumHitSize)
    }
}

@Suite("Home voice entry disclosure")
struct HomeVoiceEntryDisclosureTests {
    @Test("home ≋ + provider not yet disclosed: disclose first; only after confirming does it enter and record the consent")
    func disclosureThenStart() {
        let gate = ChatVoiceConversationGate.evaluate(
            providerKind: .openAI,
            providerDisclosureAccepted: { _ in false }
        )
        #expect(gate == .providerDisclosure(.openAI))
        var pending = PendingVoiceEntry()
        pending.hold(.openAI)
        var marked: [ProviderKind] = []
        #expect(pending.accept(.openAI) { marked.append($0) })
        #expect(marked == [.openAI])
        #expect(!pending.isPending)
    }

    @MainActor
    @Test("declining the disclosure: does not enter the conversation or create a conversation")
    func declineLeavesNoTrace() async {
        var pending = PendingVoiceEntry()
        pending.hold(.openAI)
        pending.decline()
        var marked: [ProviderKind] = []
        #expect(!pending.accept(.openAI) { marked.append($0) })
        #expect(marked.isEmpty)
        // Nothing was entered: the session was not opened and send was never called.
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        #expect(!session.isActive)
    }
}
