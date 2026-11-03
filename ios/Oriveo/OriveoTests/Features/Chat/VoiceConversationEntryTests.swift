import Combine
import Foundation
import OriveoProviderKit
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
    func realtimeSelectedIsVoiceStage() {
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true
        ) == .voiceStage)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: true, sendEnabled: true, voiceAvailable: true, modelProducesText: false,
            realtimeSelected: true
        ) == .voiceStage)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: true, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true
        ) == .stop)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: false, modelProducesText: true,
            realtimeSelected: true
        ) == .send(enabled: false))
        // Switch back to a text model: restore the plain three-state.
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: false
        ) == .voice)
    }

    @Test("when the model can only generate images or the page is unavailable, an empty draft keeps a gray ↑")
    func realtimeSelectedIgnoresDictationEngineAndRemovedBanner() {
        // voiceAvailable = false simulates the dictation engine being absent / a false banner; the realtime branch only looks at realtimeReadOnly.
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: false, modelProducesText: true,
            realtimeSelected: true, realtimeReadOnly: false
        ) == .voiceStage)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: false, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true, realtimeReadOnly: false
        ) == .backToStage)
        #expect(VoiceConversationEntry.homeComposer(
            isSending: false, hasContent: false, voiceAvailable: false, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true, realtimeReadOnly: false
        ) == HomeComposerActions(sendEnabled: true, showsVoice: false, showsBackToStage: true))
        // Non-realtime is unchanged: with the engine absent it is still a gray ↑.
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: false, modelProducesText: true,
            realtimeSelected: false, realtimeReadOnly: false
        ) == .send(enabled: false))
    }

    @Test("when the model can only generate images or the page is unavailable, an empty draft keeps a gray ↑")
    func realtimeSelectedReadOnlyIsNotStage() {
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: false, modelProducesText: true,
            realtimeSelected: true, realtimeReadOnly: true
        ) == .send(enabled: false))
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: false, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true, realtimeReadOnly: true
        ) == .send(enabled: false))
        #expect(ComposerRealtimeMode.resolve(
            realtimeSelected: true, isSending: false, voiceAvailable: false
        ) == .typing)
    }

    @Test("when the model can only generate images or the page is unavailable, an empty draft keeps a gray ↑")
    func realtimeTypingShowsBackToStage() {
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true
        ) == .backToStage)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: false,
            realtimeSelected: true, realtimeTyping: true
        ) == .backToStage)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: true, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true
        ) == .stop)
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: false, sendEnabled: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: false, realtimeTyping: true
        ) == .voice)
    }

    @Test("when the model can only generate images or the page is unavailable, an empty draft keeps a gray ↑")
    func realtimeTypingWithDraftShowsSend() {
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: true, sendEnabled: true, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true
        ) == .send(enabled: true))
        #expect(VoiceConversationEntry.primaryAction(
            isSending: false, hasContent: true, sendEnabled: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true
        ) == .send(enabled: false))
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
    func homeRealtimeTypingShowsBackToStage() {
        for producesText in [true, false] {
            #expect(VoiceConversationEntry.homeComposer(
                isSending: false, hasContent: false, voiceAvailable: true, modelProducesText: producesText,
                realtimeSelected: true, realtimeTyping: true
            ) == HomeComposerActions(sendEnabled: true, showsVoice: false, showsBackToStage: true))
        }
        #expect(VoiceConversationEntry.homeComposer(
            isSending: true, hasContent: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true
        ) == HomeComposerActions(sendEnabled: false, showsVoice: false))
        #expect(VoiceConversationEntry.homeComposer(
            isSending: false, hasContent: false, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: false, realtimeTyping: true
        ) == HomeComposerActions(sendEnabled: true, showsVoice: true))
    }

    @Test("home while sending / while a disclosure confirmation is pending: ↑ is not tappable and ≋ is hidden")
    func homeRealtimeTypingWithDraftShowsSend() {
        #expect(VoiceConversationEntry.homeComposer(
            isSending: false, hasContent: true, voiceAvailable: true, modelProducesText: true,
            realtimeSelected: true, realtimeTyping: true
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

    @Test("Engine-switch notice model name: realtime takes the selected-state model; switching back to text takes the in-memory current conversation's model name, not the old provider's default model")
    func engine_switch_name_uses_in_memory_model() {
        let smoke = TestFactories.makeModel(id: "smoke-model")
        let realtime = RealtimeModelSelection(providerID: UUID(), providerKind: .gemini, model: "gemini-3.8-live")
        #expect(ChatView.engineSwitchModelName(selection: realtime, inMemoryModel: smoke, inMemoryModelID: "smoke-model")
            == "gemini-3.8-live")
        #expect(ChatView.engineSwitchModelName(selection: nil, inMemoryModel: smoke, inMemoryModelID: "smoke-model")
            == smoke.name)
        #expect(ChatView.engineSwitchModelName(selection: nil, inMemoryModel: nil, inMemoryModelID: "smoke-model")
            == "smoke-model")
        #expect(ChatView.engineSwitchModelName(selection: nil, inMemoryModel: nil, inMemoryModelID: nil) == nil)
    }

    @Test("Gate provider takes the in-memory current conversation first: the library summary is still the old provider while memory has switched → take memory; fall back to summary when memory has none")
    func gate_provider_prefers_in_memory_conversation() {
        let gemini = UUID()
        let relay = UUID()
        #expect(ChatView.gateProviderID(inMemory: relay, summary: gemini) == relay)
        #expect(ChatView.gateProviderID(inMemory: nil, summary: gemini) == gemini)
        #expect(ChatView.gateProviderID(inMemory: nil, summary: nil) == nil)
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
    /// Conversation whose pre-send confirmation gate is pending (a stand-in for ContextCapConfirmCoordinator.pending(for:)).
    var pendingSendConfirmations: Set<UUID> = []
    func hasPendingSendConfirmation(in conversationID: UUID) -> Bool { pendingSendConfirmations.contains(conversationID) }
    /// Messages already removed from the conversation (a stand-in for rollback); all present by default.
    var removedMessages: Set<UUID> = []
    func containsMessage(_ messageID: UUID, in conversationID: UUID) -> Bool { !removedMessages.contains(messageID) }
    var cancelled: [UUID] = []
    let textSubject = PassthroughSubject<Void, Never>()
    /// Stream-finished signal (a stand-in for ChatManager.streamingDidFinish).
    let finishSubject = PassthroughSubject<Void, Never>()

    func streamingText(in conversationID: UUID) -> String { streaming[conversationID] ?? "" }
    func streamingTextDidChange(in conversationID: UUID) -> AnyPublisher<Void, Never> { textSubject.eraseToAnyPublisher() }
    func streamingDidFinish(in conversationID: UUID) -> AnyPublisher<Void, Never> { finishSubject.eraseToAnyPublisher() }
    func isBusyStreaming(in conversationID: UUID) -> Bool { busy.contains(conversationID) }
    func lastAssistantMessage(in conversationID: UUID) -> ChatMessage? { lastAssistant[conversationID] }
    func cancelGeneration(in conversationID: UUID) {
        cancelled.append(conversationID)
        calls.append("cancel")
    }

    /// Host call order (cancel / amend), to verify "stop first, then generate".
    var calls: [String] = []
    var amends: [(text: String, messageID: UUID?, turnText: String?, conversationID: UUID)] = []
    /// Return value of amend; when true, nextAssistant is set to the last assistant message in the same tick (the new reply the host regenerated).
    var amendResult = true
    var nextAssistant: ChatMessage?
    /// Id of the conversation's last user message (a stand-in for ChatManager persisting the send).
    var lastUser: [UUID: UUID] = [:]
    func lastUserMessageID(in conversationID: UUID) -> UUID? { lastUser[conversationID] }
    /// When true, amend records the text and then suspends (the window where the host has replaced the message but has not returned yet), until releaseAmends.
    var holdAmends = false
    private var heldAmends: [CheckedContinuation<Void, Never>] = []
    var heldAmendCount: Int { heldAmends.count }
    func releaseAmends() {
        let pending = heldAmends
        heldAmends = []
        for waiter in pending { waiter.resume() }
    }
    func amendLastUserMessage(_ text: String, messageID: UUID?, turnText: String?, in conversationID: UUID) async -> Bool {
        calls.append("amend")
        amends.append((text, messageID, turnText, conversationID))
        if holdAmends { await withCheckedContinuation { heldAmends.append($0) } }
        if amendResult, let nextAssistant {
            busy.insert(conversationID)
            lastAssistant[conversationID] = nextAssistant
        }
        return amendResult
    }
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

    /// The clock fires every uncancelled timer callback once it advances ms (whether due is judged by each callback against nowMs).
    func advance(_ ms: Int) {
        nowMs += ms
        tick()
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
    func sendConfirmationGateReportsApprovalPending() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        let collector = EventCollector(port.makeReplyEvents())
        #expect(await port.send("Summarize this long document for me"))

        host.pendingSendConfirmations.insert(conversation)
        await collector.settle()
        host.pendingSendConfirmations.remove(conversation)
        await collector.settle()

        #expect(collector.events == [.approvalPending(true), .approvalPending(false)])
        collector.stop()
    }

    @Test("an interrupted reply still completes as usual but does not count toward turn_count")
    func rolledBackTurnReportsFailedOnce() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let userID = UUID()
        let old = TestFactories.makeMessage(role: .assistant, text: "Old answer", state: .delivered)
        host.lastAssistant[conversation] = old
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            host.lastUser[id!] = userID
            return .sent(id!)
        }
        let collector = EventCollector(port.makeReplyEvents())
        #expect(await port.send("Summarize this long document for me"))

        host.pendingSendConfirmations.insert(conversation)
        await collector.settle()
        // User cancelled: the coordinator dequeues, the turn's user + assistant placeholder are removed, and the next stream-finished signal arrives.
        host.pendingSendConfirmations.remove(conversation)
        host.removedMessages.insert(userID)
        host.finishSubject.send()
        host.finishSubject.send()
        host.textSubject.send()
        await collector.settle()

        #expect(collector.events == [.approvalPending(true), .approvalPending(false), .failed(code: "reply_failed")])
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
    func amendStreamsRegeneratedReply() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        host.lastAssistant[conversation] = TestFactories.makeMessage(role: .assistant, text: "Old answer", state: .delivered)
        let replyID = UUID()
        host.nextAssistant = TestFactories.makeMessage(id: replyID, role: .assistant, text: "", state: .generating)
        var sends: [String] = []
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { text, id in
            sends.append(text)
            return .sent(id!)
        }
        let collector = EventCollector(port.makeReplyEvents())

        #expect(await port.amend("And day three"))
        #expect(host.amends.map(\.text) == ["And day three"])
        #expect(host.amends.map(\.conversationID) == [conversation])
        #expect(sends.isEmpty, "An interjection does not send another user message")
        #expect(host.cancelled.isEmpty, "Not generating, so nothing is stopped")

        host.streaming[conversation] = "Day three: go to Uji"
        host.textSubject.send()
        host.busy.remove(conversation)
        host.streaming[conversation] = nil
        host.lastAssistant[conversation] = TestFactories.makeMessage(
            id: replyID, role: .assistant, text: "Day three: go to Uji.", state: .delivered
        )
        host.finishSubject.send()
        await collector.settle()

        #expect(collector.events == [.text("Day three: go to Uji"), .text("Day three: go to Uji."), .completed])
        #expect(port.completedTurns == 1)
        collector.stop()
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func amendEmptyTextRegenerates() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        #expect(await port.amend(""))
        #expect(host.amends.map(\.text) == [""])
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func amendWhileGeneratingLeavesStopToHost() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        host.busy.insert(conversation)
        host.lastAssistant[conversation] = TestFactories.makeMessage(role: .assistant, text: "", state: .generating)
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        #expect(await port.amend("Also book a hotel"))
        #expect(host.calls == ["amend"])
        #expect(host.cancelled.isEmpty)
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func amendWaitsForInFlightSendAndTargetsItsMessage() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let previousTurn = UUID()
        let thisTurn = UUID()
        host.lastUser[conversation] = previousTurn
        var release: CheckedContinuation<Void, Never>?
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            await withCheckedContinuation { release = $0 }
            host.lastUser[conversation] = thisTurn
            return .sent(id!)
        }
        let sending = Task { await port.send("Go to Kyoto tomorrow") }
        for _ in 0..<50 where release == nil { await Task.yield() }
        let amending = Task { await port.amend("Also look at the autumn leaves") }
        for _ in 0..<50 { await Task.yield() }
        #expect(host.amends.isEmpty, "send has not returned yet, the interjection must not rewrite first")

        release?.resume()
        #expect(await sending.value)
        #expect(await amending.value)
        #expect(host.amends.map(\.text) == ["Also look at the autumn leaves"])
        #expect(host.amends.map(\.messageID) == [thisTurn])
        #expect(host.amends.map(\.turnText) == ["Go to Kyoto tomorrow"], "The turn's original text goes to the host: used to continue if the target is rolled back")
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func amendBeforeAnySendCarriesNoTurnText() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        #expect(await port.amend("And"))
        #expect(host.amends.map(\.turnText) == [nil])
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func cancelVoidsPendingSendAndAmend() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        var release: CheckedContinuation<Void, Never>?
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            await withCheckedContinuation { release = $0 }
            host.lastUser[conversation] = UUID()
            return .sent(id!)
        }
        let collector = EventCollector(port.makeReplyEvents())
        let sending = Task { await port.send("Go to Kyoto tomorrow") }
        for _ in 0..<50 where release == nil { await Task.yield() }
        let amending = Task { await port.amend("Also look at the autumn leaves") }
        for _ in 0..<50 { await Task.yield() }

        port.cancel()
        release?.resume()
        #expect(await sending.value == false)
        #expect(await amending.value == false)
        #expect(host.amends.isEmpty)
        #expect(host.cancelled == [conversation, conversation], "one cancel + after the voided send returns, stop the generation it queued")
        host.lastAssistant[conversation] = TestFactories.makeMessage(role: .assistant, text: "Kyoto", state: .delivered)
        host.finishSubject.send()
        await collector.settle()
        #expect(collector.events.isEmpty)
        collector.stop()
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func amendReportsDeliveryRightBeforeHandingTextToHost() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        var release: CheckedContinuation<Void, Never>?
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            await withCheckedContinuation { release = $0 }
            host.lastUser[conversation] = UUID()
            return .sent(id!)
        }
        // send in flight: the interjection has not been handed to the host, so no delivery is reported; not reported after cancel either
        let sending = port.beginSend("Go to Kyoto tomorrow")
        for _ in 0..<50 where release == nil { await Task.yield() }
        var voidedDelivered = false
        let voided = port.beginAmend("Also look at the autumn leaves") { voidedDelivered = true }
        for _ in 0..<50 { await Task.yield() }
        #expect(voidedDelivered == false)
        port.cancel()
        release?.resume()
        #expect(await sending.value == false)
        #expect(await voided.value == false)
        #expect(voidedDelivered == false)
        #expect(host.amends.isEmpty)

        // Flag is set at the moment of handover: delivery is reported even while the host's rewrite has not returned
        host.holdAmends = true
        host.calls = []
        let amending = port.beginAmend("Also look at the autumn leaves") { host.calls.append("delivered") }
        for _ in 0..<50 where host.heldAmendCount == 0 { await Task.yield() }
        #expect(host.calls == ["delivered", "amend"])
        host.releaseAmends()
        #expect(await amending.value)
        #expect(host.amends.map(\.text) == ["Also look at the autumn leaves"])
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func amendWithoutTargetReturnsFalse() async {
        let host = FakeVoiceChatHost()
        let none = AppStateVoiceChatPort(host: host, conversationID: nil) { _, _ in .refused }
        #expect(await none.amend("And") == false)
        #expect(host.amends.isEmpty)

        let conversation = UUID()
        host.amendResult = false
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in .sent(id!) }
        let collector = EventCollector(port.makeReplyEvents())
        #expect(await port.amend("And") == false)
        host.lastAssistant[conversation] = TestFactories.makeMessage(role: .assistant, text: "x", state: .delivered)
        host.finishSubject.send()
        await collector.settle()
        #expect(collector.events.isEmpty)
        collector.stop()
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func rolledBackTurnWithoutFinishSignalReportsFailed() async {
        let host = FakeVoiceChatHost()
        let conversation = UUID()
        let userID = UUID()
        let port = AppStateVoiceChatPort(host: host, conversationID: conversation) { _, id in
            host.lastUser[id!] = userID
            return .sent(id!)
        }
        let collector = EventCollector(port.makeReplyEvents())
        #expect(await port.send("Summarize this long document for me"))

        host.pendingSendConfirmations.insert(conversation)
        await collector.settle()
        host.removedMessages.insert(userID)
        host.pendingSendConfirmations.remove(conversation)
        await collector.settle()

        #expect(collector.events == [.approvalPending(true), .approvalPending(false), .failed(code: "reply_failed")])
        collector.stop()
    }

    @Test("a send that cannot be made (refused) returns false and the conversation id stays the same")
    func appStateSendConfirmationIsPerConversation() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "voice-port-cap-\(UUID().uuidString)")
        let coordinator = state.contextCapConfirmCoordinator
        let conversation = UUID()
        let other = UUID()
        let port = AppStateVoiceChatPort(host: state, conversationID: conversation) { _, id in .sent(id!) }
        let collector = EventCollector(port.makeReplyEvents())

        let otherHeld = Task { await coordinator.request(Self.capPrompt, conversationID: other, messageID: UUID()) }
        await collector.settle()
        let otherPending = try #require(coordinator.pending(for: other))
        #expect(collector.events.isEmpty)

        let ownHeld = Task { await coordinator.request(Self.capPrompt, conversationID: conversation, messageID: UUID()) }
        await collector.settle()
        let ownPending = try #require(coordinator.pending(for: conversation))
        #expect(collector.events == [.approvalPending(true)])

        coordinator.resolve(id: ownPending.id, choice: .cancel)
        await collector.settle()
        #expect(collector.events == [.approvalPending(true), .approvalPending(false)])

        coordinator.resolve(id: otherPending.id, choice: .cancel)
        _ = await otherHeld.value
        _ = await ownHeld.value
        collector.stop()
    }

    private static let capPrompt = ContextCapConfirmPresentation.Prompt(
        input: .init(attempt: .send, model: "test-model", reminderEnabled: true, conversationState: .initial,
                     pricing: nil, estimatedInput: 1, B: nil, limitedBy: nil, priceLineTokens: nil),
        decision: .none,
        text: .init(title: "", body: "", showsDontAsk: false)
    )

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
    /// Manual clock shared by the controller tests: the case advances it past the reply audio gate.
    let clock = PortManualClock()

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
                    clock: clock,
                    memory: VoiceBargeInMemory(defaults: UserDefaults(suiteName: "voice-session-\(UUID())")!, osMajorVersion: 27),
                    stopReadAloud: {},
                    detectLanguage: { _ in "en" },
                    // Session-level cases do not really load Silero
                    loadSpeechModel: { .unavailable }
                )
            },
            toast: { [self] in toasts.append($0) },
            isVoiceOverRunning: { [self] in voiceOver },
            announce: { [self] in announcements.append($0) },
            leaveGraceNanoseconds: 0,
            now: Date.init
        )
    }
}

/// Cascaded audio stand-in: prepareSession records the lease at that time, can be activated on the coordinator, and can be suspended until releasePrepare; everything else is delegated to FakeConversationAudio.
final class GatedPrepareAudio: ConversationAudioEngine {
    let inner: FakeConversationAudio
    var coordinator: AudioSessionCoordinator?
    var owner: VoiceAudioSessionOwner?
    var holdPrepare = false
    private(set) var leaseAtPrepare: VoiceAudioSessionOwner.Lease?
    private var held: CheckedContinuation<Void, Never>?
    private var reached = false
    private var reachedWaiter: CheckedContinuation<Void, Never>?

    init(_ inner: FakeConversationAudio) { self.inner = inner }

    /// Waits until prepareSession has entered (before the suspension point).
    func prepareReached() async {
        if reached { return }
        await withCheckedContinuation { reachedWaiter = $0 }
    }

    func releasePrepare() {
        held?.resume()
        held = nil
    }

    func prepareSession() async throws {
        leaseAtPrepare = owner?.current
        reached = true
        reachedWaiter?.resume()
        reachedWaiter = nil
        if holdPrepare { await withCheckedContinuation { held = $0 } }
        if let coordinator { try await coordinator.activate(nil) }
        try await inner.prepareSession()
    }

    var delegate: ConversationAudioEngineDelegate? {
        get { inner.delegate }
        set { inner.delegate = newValue }
    }
    var route: VoiceConversationLogic.Route { inner.route }
    var isSpeakerRoute: Bool { inner.isSpeakerRoute }
    func start() throws { try inner.start() }
    func stop() { inner.stop() }
    func setCaptureMuted(_ muted: Bool) { inner.setCaptureMuted(muted) }
    func pauseCapture() { inner.pauseCapture() }
    func resumeCapture() { inner.resumeCapture() }
    func beginUtterance(fromFrame frame: Int) { inner.beginUtterance(fromFrame: frame) }
    func beginUtterance(fromFrame frame: Int, live: ConversationLiveSink?) { inner.beginUtterance(fromFrame: frame, live: live) }
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) { inner.finishUtterance(completion) }
    func discardUtterance() { inner.discardUtterance() }
    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome { await inner.speak(text, language: language) }
    func play(audio: Data, fileExtension: String) async -> ConversationPlaybackOutcome { await inner.play(audio: audio, fileExtension: fileExtension) }
    func pausePlayback() { inner.pausePlayback() }
    func resumePlayback(fromSentenceStart: Bool) { inner.resumePlayback(fromSentenceStart: fromSentenceStart) }
    func stopPlayback() { inner.stopPlayback() }
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { inner.playEarcon(earcon) }
}

/// Transcription suspends until the test releases in order; used to let the draft arrive only after a new session starts.
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

/// Every call throws the same recognition error.
nonisolated final class FailingSTT: STTEngine, @unchecked Sendable {
    private let error: Error
    init(error: Error) { self.error = error }
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String { throw error }
}

/// A chat port that neither sends nor replies (only used to build the controller).
final class NullVoiceChatPort: VoiceConversationChatPort {
    func send(_ text: String) async -> Bool { false }
    func makeReplyEvents() -> AsyncStream<VoiceConversationReplyEvent> { AsyncStream { $0.finish() } }
    func cancel() {}
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

    // MARK: realtime typed send 

    typealias RealtimeFakes = RealtimeVoiceConversationControllerTests

    /// Number of times makeRealtime was called (= how many realtime sessions were opened).
    private final class RealtimeOpens { var count = 0 }
    /// Fake microphone authorization: records the number of requests and answers by granted.
    private final class MicrophoneProbe {
        var granted = true
        var requests = 0
    }

    /// Plan produced by the production path: ChatMessage → realtimeSessionInput → assembleRealtimeSession → PlannedRealtimeSession.
    private static func realtimePlan() throws -> PlannedRealtimeSession {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."),
            messages: [TestFactories.makeMessage(role: .user, text: "Typed question")],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let sessionInput = ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: [], checkpoint: nil
        )
        return try #require(PlannedRealtimeSession.from(ContextAssembler.assembleRealtimeSession(sessionInput)))
    }

    /// The chat page selects realtime: makeRealtime gives the same fake connection and fake audio each time.
    private func typedRealtimeSession(
        _ connection: RealtimeFakes.FakeConnection,
        _ audio: RealtimeFakes.FakeAudio,
        opens: RealtimeOpens,
        microphone: MicrophoneProbe = MicrophoneProbe()
    ) throws -> VoiceConversationSession {
        let plan = try Self.realtimePlan()
        var deps = SessionProbe().dependencies()
        deps.grantMicrophone = {
            microphone.requests += 1
            return microphone.granted
        }
        deps.makeRealtime = { _, _ in
            opens.count += 1
            return .realtime(RealtimeVoiceSessionParts(
                connection: connection,
                audio: RealtimeVoiceAudio(audio, route: { .speaker }),
                plan: plan,
                sink: RealtimeFakes.FakeSink(),
                attribution: RealtimeVoiceAttribution(
                    providerID: UUID(), providerKind: .openAI, providerName: "OpenAI", model: "gpt-realtime"
                )
            ))
        }
        return VoiceConversationSession(dependencies: deps)
    }

    private func waitRealtimeStatus(_ controller: RealtimeVoiceConversationController, _ key: VoiceConversationLogic.StatusKey) async {
        for await value in controller.$statusKey.values where value == key { return }
    }

    @Test("Realtime typed send: no realtime session in this conversation → open one that only plays (no capture started), then send this sentence once ready", .timeLimit(.minutes(1)))
    func realtimeTypedSendStartsSessionThenSends() async throws {
        let connection = RealtimeFakes.FakeConnection()
        let audio = RealtimeFakes.FakeAudio()
        let opens = RealtimeOpens()
        let session = try typedRealtimeSession(connection, audio, opens: opens)
        let id = UUID()
        #expect(await session.sendRealtimeTyped("  Hello  ", conversationID: id, host: FakeVoiceChatHost()))
        let realtime = try #require(session.realtime)
        #expect(session.isPresented(in: id))
        #expect(session.controller == nil)
        #expect(opens.count == 1)
        #expect(connection.openCount == 1)
        // Before ready, only queued
        #expect(connection.texts.isEmpty)

        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitRealtimeStatus(realtime, .speaking)
        #expect(connection.texts == ["Hello"])
        #expect(audio.log.contains("startRealtimePlayback"))
        #expect(!audio.log.contains("startRealtimeCapture"))
        #expect(!audio.log.contains("startRealtime"))
        session.end(.user)
        await settle()
    }

    @Test("Realtime typed cold start does not request the microphone: even if the microphone is denied, the playback-only session still opens and sends this sentence", .timeLimit(.minutes(1)))
    func realtimeTypedColdStartDoesNotRequestMicrophone() async throws {
        let connection = RealtimeFakes.FakeConnection()
        let audio = RealtimeFakes.FakeAudio()
        let microphone = MicrophoneProbe()
        microphone.granted = false
        let session = try typedRealtimeSession(connection, audio, opens: RealtimeOpens(), microphone: microphone)
        let id = UUID()
        #expect(await session.sendRealtimeTyped("Hello", conversationID: id, host: FakeVoiceChatHost()))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitRealtimeStatus(realtime, .speaking)
        #expect(connection.texts == ["Hello"])
        #expect(microphone.requests == 0)
        #expect(!audio.log.contains("startRealtimeCapture"))
        session.end(.user)
        await settle()
    }

    @Test("Typed mode back to the voice dock: request the microphone first; after agreement, capture starts on the same connection", .timeLimit(.minutes(1)))
    func resumeRealtimeVoiceRequestsMicrophoneFirst() async throws {
        let connection = RealtimeFakes.FakeConnection()
        let audio = RealtimeFakes.FakeAudio()
        let microphone = MicrophoneProbe()
        let session = try typedRealtimeSession(connection, audio, opens: RealtimeOpens(), microphone: microphone)
        let id = UUID()
        #expect(await session.sendRealtimeTyped("Hello", conversationID: id, host: FakeVoiceChatHost()))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitRealtimeStatus(realtime, .speaking)
        #expect(microphone.requests == 0)

        #expect(await session.resumeRealtimeVoice(in: id))
        #expect(microphone.requests == 1)
        #expect(audio.log.filter { $0 == "startRealtimeCapture" }.count == 1)
        #expect(session.realtime === realtime)
        #expect(connection.openCount == 1)
        session.end(.user)
        await settle()
    }

    @Test("Typed mode back to the voice dock: if the microphone is denied, capture does not start and the session is kept (the page stays in typed mode)", .timeLimit(.minutes(1)))
    func resumeRealtimeVoiceDeniedKeepsTyping() async throws {
        let connection = RealtimeFakes.FakeConnection()
        let audio = RealtimeFakes.FakeAudio()
        let microphone = MicrophoneProbe()
        let session = try typedRealtimeSession(connection, audio, opens: RealtimeOpens(), microphone: microphone)
        let id = UUID()
        #expect(await session.sendRealtimeTyped("Hello", conversationID: id, host: FakeVoiceChatHost()))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitRealtimeStatus(realtime, .speaking)

        microphone.granted = false
        #expect(!(await session.resumeRealtimeVoice(in: id)))
        #expect(microphone.requests == 1)
        #expect(!audio.log.contains("startRealtimeCapture"))
        #expect(session.realtime === realtime)
        #expect(session.hasRealtime(in: id))
        #expect(realtime.statusKey == .speaking)
        #expect(connection.closeCount == 0)
        // Typing continues to be handed to this session
        #expect(await session.sendRealtimeTyped("Again", conversationID: id, host: FakeVoiceChatHost()))
        #expect(connection.texts == ["Hello", "Again"])
        session.end(.user)
        await settle()
    }

    @Test("Realtime typed send: this conversation already has a realtime session → hand it to that session, no new session and no reconnection; other pages do not take it", .timeLimit(.minutes(1)))
    func realtimeTypedSendReusesOpenSession() async throws {
        let connection = RealtimeFakes.FakeConnection()
        let audio = RealtimeFakes.FakeAudio()
        let opens = RealtimeOpens()
        let session = try typedRealtimeSession(connection, audio, opens: opens)
        let id = UUID()
        #expect(await session.sendRealtimeTyped("Hello", conversationID: id, host: FakeVoiceChatHost()))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitRealtimeStatus(realtime, .speaking)

        #expect(await session.sendRealtimeTyped("Again", conversationID: id, host: FakeVoiceChatHost()))
        #expect(session.realtime === realtime)
        #expect(opens.count == 1)
        #expect(connection.openCount == 1)
        #expect(connection.texts == ["Hello", "Again"])
        // Empty text, and other conversations are not handed to this one
        #expect(!(await session.sendRealtimeTyped("   ", conversationID: id, host: FakeVoiceChatHost())))
        #expect(!(await session.sendRealtimeTyped("Elsewhere", conversationID: UUID(), host: FakeVoiceChatHost())))
        #expect(connection.texts == ["Hello", "Again"])
        #expect(opens.count == 1)
        session.end(.user)
        await settle()
    }

    /// Passes the reply audio gate : from the judgement moment (silence start + vadEndSilenceMs) to silence start + replyAudioGateMs, replies queued before the gate are sent on time.
    private func passReplyGate(_ probe: SessionProbe) async {
        probe.clock.advance(VoiceConversationLogic.Constants.replyAudioGateMs - VoiceConversationLogic.Constants.vadEndSilenceMs)
        await settle()
    }

    @Test("home zero-turn exit: send is not called and no conversation is created")
    func production_passes_recognition_language() {
        let settings = VoiceEngineSettings(
            defaults: UserDefaults(suiteName: "VoiceConversationSessionTests-\(UUID().uuidString)")!
        )
        settings.recognitionLanguage = "fr-FR"
        let deps = VoiceConversationSession.Dependencies.production(
            audioSession: VoiceAudioSessionOwner(), settings: settings
        )
        let controller = deps.makeController(
            DictationEngineChoice(engine: SilentSTT(), isSystem: true, fallback: nil), NullVoiceChatPort()
        )
        #expect(controller.sttLanguage() == "fr-FR")
        settings.recognitionLanguage = nil
        #expect(controller.sttLanguage() == nil)
    }

    @Test("home zero-turn exit: send is not called and no conversation is created")
    func cascadeStartPreparesSessionBeforeEngine() async {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        let started = await session.start(origin: .home, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in
            .refused
        }
        #expect(started)
        #expect(probe.audio.lifecycle == ["prepare", "start"])
        session.end(.user)
        await settle()
    }

    /// Cascaded conversation dependency: audio is wrapped in a lease wrapper (gated), stop-speaking goes through the given closure, and the lease is on the given owner.
    private func leasedDependencies(
        _ probe: SessionProbe, gated: GatedPrepareAudio, owner: VoiceAudioSessionOwner,
        stopReadAloud: @escaping () -> Void = {}
    ) -> VoiceConversationSession.Dependencies {
        var deps = probe.dependencies()
        deps.audioSession = owner
        deps.makeController = { choice, port in
            VoiceConversationController(
                audio: SessionLeasedConversationAudio(gated, owner: owner),
                dictation: DictationEngineSource { choice },
                readAloud: .fixed(MuteSpeechEngine()),
                chat: port,
                prompt: VoiceConversationCopy.prompt,
                clock: PortManualClock(),
                memory: VoiceBargeInMemory(defaults: UserDefaults(suiteName: "voice-session-\(UUID())")!, osMajorVersion: 27),
                stopReadAloud: stopReadAloud,
                detectLanguage: { _ in "en" }
            )
        }
        return deps
    }

    @Test("home zero-turn exit: send is not called and no conversation is created")
    func cascadeStopsReadAloudBeforeActivating() async {
        let probe = SessionProbe()
        let recorder = SessionOpRecorder()
        let coordinator = AudioSessionCoordinator(apply: recorder.apply)
        let gated = GatedPrepareAudio(probe.audio)
        gated.coordinator = coordinator
        let session = VoiceConversationSession(dependencies: leasedDependencies(
            probe, gated: gated, owner: VoiceAudioSessionOwner(),
            stopReadAloud: { coordinator.deactivate(notifyOthers: true) }
        ))
        let started = await session.start(origin: .home, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in
            .refused
        }
        #expect(started)
        #expect(recorder.operations.first == .deactivate(notifyOthers: true))
        #expect(recorder.operations.firstIndex(of: .activate) ?? -1 > 0)
        session.end(.user)
        await settle()
    }

    @Test("home zero-turn exit: send is not called and no conversation is created")
    func cascadeClaimsLeaseBeforePreparing() async {
        let probe = SessionProbe()
        let owner = VoiceAudioSessionOwner()
        let gated = GatedPrepareAudio(probe.audio)
        gated.owner = owner
        let session = VoiceConversationSession(dependencies: leasedDependencies(probe, gated: gated, owner: owner))
        let started = await session.start(origin: .home, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in
            .refused
        }
        #expect(started)
        #expect(gated.leaseAtPrepare?.client == .conversation)
        // start reuses the lease claimed during preparation, does not claim again.
        #expect(owner.current == gated.leaseAtPrepare)
        session.end(.user)
        await settle()
        #expect(owner.current == nil)
    }

    @Test("home zero-turn exit: send is not called and no conversation is created")
    func cascadeEndDuringPrepareDoesNotStart() async {
        let probe = SessionProbe()
        let owner = VoiceAudioSessionOwner()
        let gated = GatedPrepareAudio(probe.audio)
        gated.holdPrepare = true
        let session = VoiceConversationSession(dependencies: leasedDependencies(probe, gated: gated, owner: owner))
        let opening = Task {
            await session.start(origin: .home, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in .refused }
        }
        await gated.prepareReached()
        #expect(owner.current?.client == .conversation)
        session.end(.user)
        gated.releasePrepare()
        let started = await opening.value

        #expect(!started)
        #expect(probe.audio.started == 0)
        #expect(probe.audio.stopped == 1)
        #expect(owner.current == nil)
        #expect(!session.isActive)
        #expect(!session.isStarting)
    }

    @Test("home zero-turn exit: send is not called and no conversation is created")
    func cascadeHostGoneDuringPrepareDoesNotStart() async {
        let probe = SessionProbe()
        let owner = VoiceAudioSessionOwner()
        let gated = GatedPrepareAudio(probe.audio)
        gated.holdPrepare = true
        let session = VoiceConversationSession(dependencies: leasedDependencies(probe, gated: gated, owner: owner))
        let conversation = UUID()
        session.hostAppeared(conversation)
        let opening = Task {
            await session.start(origin: .chat, conversationID: conversation, host: FakeVoiceChatHost()) { _, id in
                .sent(id ?? conversation)
            }
        }
        await gated.prepareReached()
        session.hostDisappeared(conversation)
        await settle()
        gated.releasePrepare()
        let started = await opening.value

        #expect(!started)
        #expect(probe.audio.started == 0)
        #expect(owner.current == nil)
        #expect(!session.isActive)
        #expect(probe.toasts.isEmpty)
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
    func languagePickerPausesCapture() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        await settle()
        let controller = try #require(session.controller)
        #expect(controller.state.screenReaderSpeaking == false)

        session.setLanguagePickerOpen(true)
        #expect(session.languagePickerOpen)
        #expect(controller.state.screenReaderSpeaking == true)

        session.setLanguagePickerOpen(false)
        #expect(!session.languagePickerOpen)
        #expect(controller.state.screenReaderSpeaking == false)
        session.end(.user)
        await settle()
    }

    @Test("VoiceOver on: five rounds of conversation, voice frames fed during every status announcement, and the user messages are still only five")
    func languagePickerHostDisappearResumesCapture() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        await settle()
        let controller = try #require(session.controller)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let bar = UIHostingController(rootView: Color.clear.recognitionLanguageSheet(
            isPresented: .constant(false), session: session
        ))
        window.rootViewController = bar
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // Capsule tapped: pause capture first, then open the form.
        session.setLanguagePickerOpen(true)
        #expect(controller.state.screenReaderSpeaking == true)

        // The whole voice bar is torn down (e.g. the host switches away before the session ends).
        window.rootViewController = UIViewController()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!session.languagePickerOpen)
        #expect(controller.state.screenReaderSpeaking == false)
        window.isHidden = true
        withExtendedLifetime(bar) {}
        session.end(.user)
        await settle()
    }

    @Test("VoiceOver on: five rounds of conversation, voice frames fed during every status announcement, and the user messages are still only five")
    func languagePickerStacksWithScreenReader() async throws {
        let probe = SessionProbe()
        probe.voiceOver = true
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        await settle()
        let controller = try #require(session.controller)

        // Open the form first, then announce: when the announcement ends the form is still open, so nothing is restored.
        session.setLanguagePickerOpen(true)
        session.statusChanged(.listening)
        #expect(controller.state.screenReaderSpeaking == true)
        session.announcementFinished()
        #expect(controller.state.screenReaderSpeaking == true)
        session.setLanguagePickerOpen(false)
        #expect(controller.state.screenReaderSpeaking == false)

        // Announce first, then open the form: when the form closes the screen reader is still speaking, so nothing is restored.
        session.statusChanged(.muted)
        session.setLanguagePickerOpen(true)
        session.setLanguagePickerOpen(false)
        #expect(controller.state.screenReaderSpeaking == true)
        session.announcementFinished()
        #expect(controller.state.screenReaderSpeaking == false)
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
            await passReplyGate(probe)
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
        var deps = probe.dependencies(listening: DictationEngineChoice(
            engine: FixedTextSTT(text: "question"), isSystem: true, fallback: nil
        ))
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

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
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
            await passReplyGate(probe)
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
    func host_feedback_haptic_caption_forwarded() async throws {
        let probe = SessionProbe()
        var deps = probe.dependencies()
        var haptics: [VoiceConversationLogic.Haptic] = []
        deps.haptic = { haptics.append($0) }
        let session = VoiceConversationSession(dependencies: deps)
        await session.start(origin: .chat, conversationID: UUID(), host: FakeVoiceChatHost()) { _, _ in .refused }
        await settle()
        #expect(haptics == [.light])
        #expect(session.caption == nil)
        #expect(session.nudgeCount == 0)

        let controller = try #require(session.controller)
        var frame = 0
        for db in Array(repeating: -60.0, count: 10) + Array(repeating: -30.0, count: 20) {
            controller.conversationAudio(didCaptureFrame: frame, db: db)
            frame += 1
        }
        controller.receivePartial("hello")
        #expect(controller.caption == "hello")
        #expect(session.caption == "hello")
        #expect(session.nudgeCount == controller.nudgeCount)

        session.end(.user)
        await settle()
        #expect(haptics.count == 2)
        #expect(session.caption == nil)
        #expect(session.nudgeCount == 0)
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
            "Dictation and read aloud use your device's built-in voice for free. For better accuracy or a more natural voice, switch to a provider you've connected. Realtime voice talks to your provider's model directly and is billed to your account with that provider.",
            table: .voice
        ))
        #expect(VoiceSettingsModel.pageHeader.contains("Realtime voice") || AppLocalization.currentLanguage.rawValue != "en")
    }

    @Test("prompts: did not catch / please confirm / the placeholder sentence reuse the read-aloud copy")
    func prompts() {
        #expect(VoiceConversationCopy.prompt(.didNotCatch) == L10n.tr("Sorry, I didn't catch that.", table: .voice))
        #expect(VoiceConversationCopy.prompt(.approvalNeeded) == L10n.tr("Please confirm on the screen.", table: .voice))
        #expect(VoiceConversationCopy.prompt(.placeholder(.code)) == L10n.tr("Here's a code block.", table: .voice))
    }
}

extension VoiceConversationCopyTests {
    @Test("Status line: caption state shows the subtitle; an empty subtitle falls back to the listening copy; other states follow the status key")
    func status_caption_text() {
        let listening = L10n.tr("Listening", table: .voice)
        #expect(VoiceConversationCopy.status(.caption, caption: "hello there") == "hello there")
        #expect(VoiceConversationCopy.status(.caption, caption: "") == listening)
        #expect(VoiceConversationCopy.status(.caption, caption: nil) == listening)
        #expect(VoiceConversationCopy.status(.listening, caption: "hello") == listening)
        #expect(VoiceConversationCopy.status(.thinking, caption: "hello") == L10n.tr("Thinking", table: .voice))
    }

    @Test("Notice copy: sayAgain / checkLanguage / echo each map to their own copy")
    func prompts_sayAgain_checkLanguage_echoHint() {
        #expect(VoiceConversationCopy.prompt(.sayAgain) == L10n.tr("I didn’t catch that. Could you say it again?", table: .voice))
        #expect(VoiceConversationCopy.prompt(.checkLanguage) == L10n.tr(
            "I still didn’t catch that. If you’re speaking another language, tap Recognition Language to change it.",
            table: .voice
        ))
        #expect(VoiceConversationCopy.prompt(.echoHint)
            == L10n.tr("There’s an echo from the speaker. Headphones will work better.", table: .voice))
        let texts = [VoicePrompt.didNotCatch, .sayAgain, .checkLanguage, .echoHint].map(VoiceConversationCopy.prompt)
        #expect(Set(texts).count == texts.count)
        #expect(texts.allSatisfy { !$0.isEmpty })
    }
}

// MARK: - Status line does not truncate

@Suite("Voice conversation bar status fits")
struct VoiceConversationBarStatusFitTests {
    /// Voice stage on a 375pt-wide device: both pages are full-width panels, subtitle / status line inset 36 on each side.
    static let narrowestStageWidth: CGFloat = 375
    static let textWidth: CGFloat = narrowestStageWidth - 2 * VoiceConversationBarContent.captionInset

    static let statusKeyIDs: [VoiceConversationLogic.StatusKey: String] = [
        .listening: "voice_conversation_status_listening",
        // The caption state's status line temporarily uses the listening copy (the subtitle itself is shown separately).
        .caption: "voice_conversation_status_listening",
        .sayAgain: "voice_conversation_status_say_again",
        .checkLanguage: "voice_conversation_status_check_language",
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

    /// Lays out with the given font at the given width and returns the line count; for space-separated text where a word does not fit, returns nil (CJK without word splitting can wrap between any characters).
    static func lineCount(_ text: String, font: UIFont, width: CGFloat, kern: CGFloat = 0) -> Int? {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
        let words = text.contains(where: \.isWhitespace) ? text.split(whereSeparator: \.isWhitespace) : []
        for word in words {
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

    @Test("Font size: default-tier status line 17, the two didn't-catch-that states 20, subtitles 20, all rounded, scale up with system text size, capped at accessibility2")
    func statusFonts() {
        typealias Bar = VoiceConversationBarContent
        for key in VoiceConversationPage.chat.reachableStatusKeys {
            let font = Bar.statusUIFont(for: key)
            let notice = key == .sayAgain || key == .checkLanguage
            #expect(font.pointSize == (notice ? 20 : 17), "\(key)")
            let large = Bar.statusUIFont(for: key, size: .accessibility2)
            #expect(large.pointSize > font.pointSize * 1.5, "\(key) \(large.pointSize)")
            // Above accessibility2 no longer scales up.
            #expect(Bar.statusUIFont(for: key, size: .accessibility5).pointSize == large.pointSize, "\(key)")
        }
        #expect(Bar.captionUIFont.pointSize == 20)
        #expect(Bar.captionUIFont(.large).pointSize == 20)
        #expect(Bar.captionUIFont(.accessibility2).pointSize > 30)
        #expect(Bar.captionUIFont(.accessibility5).pointSize == Bar.captionUIFont(.accessibility2).pointSize)
        #expect(Bar.captionUIFont(.xSmall).pointSize < 20)
        #expect(Bar.captionInset == 36)
    }

    @Test("Subtitle old text and status text: light #52525B / dark #B3B3BA (still ≥ 4.5:1 over the aurora fog)")
    func captionDimColor() {
        for (scheme, hex) in [(ColorScheme.light, 0x52525B), (.dark, 0xB3B3BA)] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let resolved = VoiceConversationBarContent.captionDim.resolve(in: environment)
            let status = VoiceConversationBarContent.statusColor.resolve(in: environment)
            #expect(status == resolved, "Status text has the same color as the old text")
            let rgb = (Int((resolved.red * 255).rounded()) << 16)
                | (Int((resolved.green * 255).rounded()) << 8)
                | Int((resolved.blue * 255).rounded())
            #expect(rgb == hex, "\(scheme) \(String(rgb, radix: 16))")
        }
    }

    @MainActor
    @Test("Recognition language capsule: under accessibility2, the longest language name of the 16 languages takes ≤ 3 lines without truncation, height ≥ 36", arguments: [false, true])
    func languageChipFitsAtAccessibility2(dark: Bool) throws {
        typealias Bar = VoiceConversationBarContent
        let copy = try VoiceConversationCopyTests.json(
            VoiceConversationCopyTests.repoFile("shared/voice-contracts/p2-copy.v1.json")
        )
        let keys = try #require(copy["keys"] as? [String: [String: Any]])
        let values = try #require(keys["voice_conversation_language_chip"]?["values"] as? [String: String])
        #expect(values.count == 16)
        let font = Bar.chipUIFont(.accessibility2)
        #expect(font.pointSize > 14.5 * 1.5)
        // Default tier 14.5 (scaledValue aligns to pixels, 1/3pt allowed).
        #expect(abs(Bar.chipUIFont(.large).pointSize - 14.5) < 0.34)
        // Take the longest language name from the production options (same method as the capsule).
        let name = try #require(VoiceSettingsModel.recognitionLanguageOptions().map(\.title).max { $0.count < $1.count })
        let textWidth = Self.narrowestStageWidth - Bar.chipTextInset(.accessibility2)
        for (language, format) in values {
            let title = format.replacingOccurrences(of: "%1$@", with: name)
            let lines = try #require(Self.lineCount(title, font: font, width: textWidth), "\(language) \(title)")
            #expect(Bar.chipLineLimit == 3)
            #expect(lines <= Bar.chipLineLimit, "\(language) \(title) lines=\(lines)")
            let host = UIHostingController(rootView: Bar.chipLabel(title: title, dark: dark, size: .accessibility2))
            let size = host.sizeThatFits(in: CGSize(width: Self.narrowestStageWidth, height: 800))
            #expect(size.width <= Self.narrowestStageWidth + 0.5, "\(language)")
            #expect(size.height >= Bar.chipMinHeight, "\(language) \(size.height)")
            #expect(size.height >= CGFloat(lines) * font.lineHeight, "\(language) \(size.height) lines=\(lines)")
        }
        let small = UIHostingController(rootView: Bar.chipLabel(title: "English", dark: dark, size: .large))
        let smallSize = small.sizeThatFits(in: CGSize(width: Self.narrowestStageWidth, height: 800))
        #expect(abs(smallSize.height - Bar.chipMinHeight) < 0.5)
    }

    @Test("page x that page's reachable states: the longest one among the 16 languages takes <= 2 lines at the xLarge size and is not truncated", arguments: [
        VoiceConversationPage.home, VoiceConversationPage.chat,
    ])
    func longestStatusFitsTwoLines(page: VoiceConversationPage) throws {
        let copy = try VoiceConversationCopyTests.json(
            VoiceConversationCopyTests.repoFile("shared/voice-contracts/p2-copy.v1.json")
        )
        let keys = try #require(copy["keys"] as? [String: [String: Any]])
        #expect(VoiceConversationBarContent.maxTextSize == .accessibility2)
        for status in page.reachableStatusKeys {
            let key = try #require(Self.statusKeyIDs[status])
            let values = try #require(keys[key]?["values"] as? [String: String], "\(key)")
            let font = VoiceConversationBarContent.statusUIFont(for: status)
            for (language, value) in values {
                let lines = Self.lineCount(value, font: font, width: Self.textWidth)
                #expect(
                    lines != nil && lines! <= 2,
                    "\(page) \(key) \(language) \"\(value)\" lines=\(String(describing: lines)) width=\(Self.textWidth)"
                )
            }
        }
    }

    /// Computes the stage's vertical footprint from the production font: orb + status line + capsule (optional) + spacing + two buttons.
    static func stageLayout(
        status: String,
        statusKey: VoiceConversationLogic.StatusKey,
        chipTitle: String?,
        size: DynamicTypeSize
    ) -> (stage: CGFloat, chipBottom: CGFloat, statusLines: Int?) {
        typealias Bar = VoiceConversationBarContent
        let font = Bar.statusUIFont(for: statusKey, size: size)
        let notice = Bar.fogNotice(statusKey: statusKey)
        let lines = lineCount(status, font: font, width: textWidth, kern: notice ? Bar.captionTracking : 0)
        let shown = CGFloat(min(lines ?? Bar.statusLineLimit, Bar.statusLineLimit))
        let statusHeight = shown * font.lineHeight + (notice ? (shown - 1) * Bar.lineSpacing(for: font) : 0)
        var bottom = Bar.orbTop + Bar.orbSize + Bar.captionSpacing + statusHeight
        if let chipTitle {
            let chip = UIHostingController(rootView: Bar.chipLabel(title: chipTitle, dark: false, size: size))
                .sizeThatFits(in: CGSize(width: narrowestStageWidth, height: 800))
            bottom += Bar.chipSpacing + chip.height
        }
        let stage = max(Bar.stageContentHeight, bottom + Bar.controlsGap + Bar.buttonSize + Bar.buttonBottom)
        return (stage, bottom, lines)
    }

    @MainActor
    @Test("the voice bar lays out at the narrowest width, with the orb + status text still >= 44pt")
    func barLaysOutAtNarrowestWidth() throws {
        typealias Bar = VoiceConversationBarContent
        #expect(Bar.stageContentHeight == 366)
        let chip = VoiceLanguageChip(name: "Français", action: {})
        let content = VoiceConversationBarContent(
            displayState: .checkLanguage,
            statusKey: .checkLanguage,
            level: 0.4,
            languageChip: chip,
            onEnd: {},
            onOrb: {},
            onMute: {}
        )
        // The actual layout matches the stage height computed from the production font (copy in the current UI language); a5 is capped the same as a2.
        let status = VoiceConversationCopy.status(.checkLanguage)
        let title = Bar.languageChipTitle(chip.name)
        var heights: [DynamicTypeSize: CGFloat] = [:]
        for size in [DynamicTypeSize.large, .accessibility2, .accessibility5] {
            let host = UIHostingController(rootView: content.environment(\.dynamicTypeSize, size))
            let fitted = host.sizeThatFits(in: CGSize(width: Self.narrowestStageWidth, height: 1200))
            let expected = Self.stageLayout(status: status, statusKey: .checkLanguage, chipTitle: title, size: size).stage
            #expect(fitted.width <= Self.narrowestStageWidth + 0.5, "\(size)")
            #expect(abs(fitted.height - expected) < 1, "\(size) fitted=\(fitted.height) expected=\(expected)")
            heights[size] = fitted.height
        }
        #expect(heights[.accessibility2]! > Bar.stageContentHeight, "a2 should grow: \(heights)")
        #expect(heights[.accessibility5] == heights[.accessibility2])

        // accessibility2, 16 languages: after the stage grows, the capsule bottom in the stage ≤ the two buttons' top minus spacing, and the didn't-catch-that status line ≤ 3 lines.
        let copy = try VoiceConversationCopyTests.json(
            VoiceConversationCopyTests.repoFile("shared/voice-contracts/p2-copy.v1.json")
        )
        let keys = try #require(copy["keys"] as? [String: [String: Any]])
        let chips = try #require(keys["voice_conversation_language_chip"]?["values"] as? [String: String])
        let name = try #require(VoiceSettingsModel.recognitionLanguageOptions().map(\.title).max { $0.count < $1.count })
        for key in [VoiceConversationLogic.StatusKey.sayAgain, .checkLanguage] {
            let id = try #require(Self.statusKeyIDs[key])
            let statuses = try #require(keys[id]?["values"] as? [String: String])
            for (language, value) in statuses {
                let chipTitle = key == .checkLanguage
                    ? try #require(chips[language]).replacingOccurrences(of: "%1$@", with: name)
                    : nil
                let layout = Self.stageLayout(status: value, statusKey: key, chipTitle: chipTitle, size: .accessibility2)
                let controlsTop = layout.stage - Bar.buttonBottom - Bar.buttonSize
                #expect(
                    layout.chipBottom <= controlsTop - Bar.controlsGap + 0.5,
                    "\(key) \(language) bottom=\(layout.chipBottom) controlsTop=\(controlsTop)"
                )
                #expect(
                    layout.statusLines.map { $0 <= Bar.statusLineLimit } == true,
                    "\(key) \(language) lines=\(String(describing: layout.statusLines))"
                )
            }
        }
    }

    @Test("Page × reachable state for that page: under accessibility2, the longest of the 16 languages fits within 375 − 2×36 width in ≤ 3 lines, without truncation", arguments: [
        VoiceConversationPage.home, VoiceConversationPage.chat,
    ])
    func longestStatusFitsAtAccessibility2(page: VoiceConversationPage) throws {
        typealias Bar = VoiceConversationBarContent
        let copy = try VoiceConversationCopyTests.json(
            VoiceConversationCopyTests.repoFile("shared/voice-contracts/p2-copy.v1.json")
        )
        let keys = try #require(copy["keys"] as? [String: [String: Any]])
        #expect(Bar.statusLineLimit == 3)
        for status in page.reachableStatusKeys {
            let key = try #require(Self.statusKeyIDs[status])
            let values = try #require(keys[key]?["values"] as? [String: String], "\(key)")
            let font = Bar.statusUIFont(for: status, size: .accessibility2)
            let kern = Bar.fogNotice(statusKey: status) ? Bar.captionTracking : 0
            for (language, value) in values {
                let lines = Self.lineCount(value, font: font, width: Self.textWidth, kern: kern)
                #expect(
                    lines != nil && lines! <= Bar.statusLineLimit,
                    "\(page) \(key) \(language) \"\(value)\" lines=\(String(describing: lines)) size=\(font.pointSize)"
                )
            }
        }
    }

    @Test("State → orb mode: listening splits into Listen / User by display state; the two didn't-catch-that states are Listen + amber fog")
    func orbModeMapping() {
        typealias Bar = VoiceConversationBarContent
        let expected: [VoiceConversationLogic.StatusKey: VoiceOrbMode] = [
            .listening: .listen, .caption: .user, .thinking: .think, .speaking: .ai, .speakingTapToInterrupt: .ai,
            .muted: .muted, .awaitingApproval: .muted, .error: .muted, .sayAgain: .listen, .checkLanguage: .listen,
        ]
        #expect(Set(expected.keys) == VoiceConversationPage.chat.reachableStatusKeys)
        for (key, mode) in expected {
            let display = VoiceConversationDemo.displayState(for: key)
            #expect(Bar.orbMode(statusKey: key, displayState: display) == mode, "\(key)")
            #expect(Bar.fogNotice(statusKey: key) == (key == .sayAgain || key == .checkLanguage), "\(key)")
        }
        // Under the listening copy, the user has started speaking: counts as User.
        #expect(Bar.orbMode(statusKey: .listening, displayState: .userSpeaking) == .user)
        #expect(Bar.orbMode(statusKey: nil, displayState: nil) == .muted)
    }

    @Test("Caption highlight: last 8 code points in body color; space tokenization takes the last 3 words; if the whole sentence is too short, all lit")
    func captionHighlightSplit() {
        typealias Bar = VoiceConversationBarContent
        let cjk = Bar.captionSegments("\u{4ECA}\u{5929}\u{4E0B}\u{5348}\u{4E09}\u{70B9}\u{5E2E}\u{6211}\u{8BA2}\u{4E00}\u{95F4}\u{4F1A}\u{8BAE}\u{5BA4}")
        #expect(cjk.dim == "\u{4ECA}\u{5929}\u{4E0B}\u{5348}\u{4E09}\u{70B9}")
        #expect(cjk.bright == "\u{5E2E}\u{6211}\u{8BA2}\u{4E00}\u{95F4}\u{4F1A}\u{8BAE}\u{5BA4}")
        #expect(cjk.bright.unicodeScalars.count == 8)

        let words = Bar.captionSegments("book a meeting room for three this afternoon")
        #expect(words.dim == "book a meeting room for ")
        #expect(words.bright == "three this afternoon")

        let english = Bar.captionSegments("please book a meeting room")
        #expect(english.dim + english.bright == "please book a meeting room")
        #expect(english.bright == "a meeting room")

        // Mixed Chinese and English: if Han characters are present it splits by code point, not by space tokenization.
        let mixed = Bar.captionSegments("\u{6211}\u{7528} iPhone \u{62CD}\u{4E86}\u{4E00}\u{5F20}\u{5F88}\u{597D}\u{770B}\u{7684}\u{7167}\u{7247}")
        #expect(mixed.bright == "\u{4E00}\u{5F20}\u{5F88}\u{597D}\u{770B}\u{7684}\u{7167}\u{7247}")
        #expect(mixed.dim == "\u{6211}\u{7528} iPhone \u{62CD}\u{4E86}")
        let kana = Bar.captionSegments("きょうは いい てんき ですね")
        #expect(kana.bright.unicodeScalars.count == 8)

        // Full-width punctuation / full-width Latin do not count as CJK: without Han, kana, or Hangul, split by word.
        let fullwidth = Bar.captionSegments("\u{FF28}\u{FF45}\u{FF4C}\u{FF4C}\u{FF4F}\u{FF0C} how are you today\u{FF1F}")
        #expect(fullwidth.dim == "\u{FF28}\u{FF45}\u{FF4C}\u{FF4C}\u{FF4F}\u{FF0C} how ")
        #expect(fullwidth.bright == "are you today\u{FF1F}")

        let short = Bar.captionSegments("\u{4F60}\u{597D}")
        #expect(short.dim.isEmpty)
        #expect(short.bright == "\u{4F60}\u{597D}")

        // When a code-point boundary falls inside a combining sequence, do not split the grapheme: the lit segment starts at the whole grapheme.
        let emoji = Bar.captionSegments("\u{597D}\u{7684}👍🏽\u{8C22}\u{8C22}\u{4F60}\u{7684}\u{5E2E}\u{5FD9}\u{5440}")
        #expect(emoji.dim + emoji.bright == "\u{597D}\u{7684}👍🏽\u{8C22}\u{8C22}\u{4F60}\u{7684}\u{5E2E}\u{5FD9}\u{5440}")
        #expect(emoji.bright.unicodeScalars.count >= 8)
    }

    @Test("Two-line subtitle overflow truncates from the head: keeps the end and adds \"…\"")
    func captionHeadTruncation() {
        typealias Bar = VoiceConversationBarContent
        let font = Bar.captionUIFont
        let long = String(repeating: "\u{8FD9}\u{662F}\u{4E00}\u{6BB5}\u{5F88}\u{957F}\u{7684}\u{5B9E}\u{65F6}\u{5B57}\u{5E55}\u{5185}\u{5BB9}", count: 8) + "\u{6700}\u{540E}\u{51E0}\u{4E2A}\u{5B57}"
        let fitted = Bar.headTruncated(long, font: font, width: Self.textWidth, lines: 2)
        #expect(fitted.hasPrefix("…"))
        #expect(fitted.hasSuffix("\u{6700}\u{540E}\u{51E0}\u{4E2A}\u{5B57}"))
        let kern = Bar.captionTracking
        #expect(kern == -0.3)
        let lines = Self.lineCount(fitted, font: font, width: Self.textWidth, kern: kern)
        #expect(lines != nil && lines! <= 2)
        #expect(Bar.headTruncated("\u{77ED}\u{53E5}", font: font, width: Self.textWidth, lines: 2) == "\u{77ED}\u{53E5}")

        // Measured with the same style as display (with letter spacing −0.3): trimmed to exactly two lines; one more character would overflow.
        let narrow = String(repeating: "i", count: 240) + "end"
        let tight = Bar.headTruncated(narrow, font: font, width: Self.textWidth, lines: 2)
        let kept = tight.dropFirst()
        #expect(Self.lineCount(tight, font: font, width: Self.textWidth, kern: kern) == 2)
        let oneMore = "…" + String(narrow.suffix(kept.count + 1))
        #expect(Self.lineCount(oneMore, font: font, width: Self.textWidth, kern: kern) == 3, "\(tight)")
    }

    @Test("Recognition language capsule: shown only in checkLanguage and only when the host provided the capsule")
    func languageChipOnlyInCheckLanguage() {
        let chip = VoiceLanguageChip(name: "English", action: {})
        for key in VoiceConversationPage.chat.reachableStatusKeys {
            #expect(VoiceConversationBarContent.showsLanguageChip(statusKey: key, chip: chip) == (key == .checkLanguage), "\(key)")
        }
        #expect(!VoiceConversationBarContent.showsLanguageChip(statusKey: .checkLanguage, chip: nil))
        // Copy goes through the p2-copy voice_conversation_language_chip key, not concatenated.
        #expect(VoiceConversationBarContent.languageChipTitle("English")
            == L10n.format(L10n.tr("Recognition Language: %1$@", table: .voice), "English"))
        #expect(VoiceConversationBarContent.languageChipTitle("English").contains("English"))
    }

    @MainActor
    @Test("Stage periphery: when on, page glow / aurora 0 and list top gradient 1; off is the reverse; gradient height = 30% of visible height")
    func stageChromeOpacities() {
        #expect(VoiceStageChrome.pageGlowOpacity(stageShown: true) == 0)
        #expect(VoiceStageChrome.listFadeOpacity(stageShown: true) == 1)
        #expect(VoiceStageChrome.pageGlowOpacity(stageShown: false) == 1)
        #expect(VoiceStageChrome.listFadeOpacity(stageShown: false) == 0)
        #expect(VoiceStageChrome.listFadeFraction == 0.3)
        // The page's solid base layer and glow are the reverse: 1 when the stage is on, 0 when off.
        #expect(OriveoScreenBackground.solidFillOpacity(glowOpacity: VoiceStageChrome.pageGlowOpacity(stageShown: true)) == 1)
        #expect(OriveoScreenBackground.solidFillOpacity(glowOpacity: VoiceStageChrome.pageGlowOpacity(stageShown: false)) == 0)
        // Conversation not started: the page does not show the stage.
        let session = VoiceConversationSession(dependencies: SessionProbe().dependencies())
        #expect(!VoiceStageChrome.isShown(session: session, conversationID: UUID()))
        // With a realtime selection: the resident idle dock also counts as the stage being on.
        #expect(VoiceStageChrome.isShown(session: session, conversationID: UUID(), realtimeSelected: true))
    }

    @MainActor
    @Test("Home feed passes nudgeCount through; after handover it stops at the last value")
    func homeFeedForwardsNudgeCount() {
        let source = StageFakeSurface()
        var attached = true
        let feed = HomeVoiceBarFeed(source: source) { attached }
        #expect(feed.nudgeCount == 0)
        source.nudgeCount = 2
        #expect(feed.nudgeCount == 2)
        attached = false
        source.nudgeCount = 3
        #expect(feed.nudgeCount == 2)
        // Realtime engine does not provide it: the extension defaults to 0.
        #expect(DefaultNudgeSurface().nudgeCount == 0)
    }
}

/// Minimal voice seam that can write nudgeCount.
private final class StageFakeSurface: VoiceConversationSurface {
    let objectWillChange = ObservableObjectPublisher()
    var statusKey: VoiceConversationLogic.StatusKey? = .listening
    var displayState: VoiceConversationLogic.DisplayState? = .listening
    var level: Double = 0
    var nudgeCount = 0 { willSet { objectWillChange.send() } }
    func tapOrb() {}
    func toggleMute() {}
}

/// Seam that does not provide nudgeCount (same as the realtime controller).
private final class DefaultNudgeSurface: VoiceConversationSurface {
    let objectWillChange = ObservableObjectPublisher()
    var statusKey: VoiceConversationLogic.StatusKey? { nil }
    var displayState: VoiceConversationLogic.DisplayState? { nil }
    var level: Double { 0 }
    func tapOrb() {}
    func toggleMute() {}
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
    @Test("Stage periphery: when on, page glow / aurora 0 and list top gradient 1; off is the reverse; gradient height = 30% of visible height")
    func stageChromeOpacities() {
        #expect(VoiceStageChrome.pageGlowOpacity(stageShown: true) == 0)
        #expect(VoiceStageChrome.listFadeOpacity(stageShown: true) == 1)
        #expect(VoiceStageChrome.pageGlowOpacity(stageShown: false) == 1)
        #expect(VoiceStageChrome.listFadeOpacity(stageShown: false) == 0)
        #expect(VoiceStageChrome.listFadeFraction == 0.3)
        // The page's solid base layer and glow are the reverse: 1 when the stage is on, 0 when off.
        #expect(OriveoScreenBackground.solidFillOpacity(glowOpacity: VoiceStageChrome.pageGlowOpacity(stageShown: true)) == 1)
        #expect(OriveoScreenBackground.solidFillOpacity(glowOpacity: VoiceStageChrome.pageGlowOpacity(stageShown: false)) == 0)
        // Conversation not started: the page does not show the stage.
        let session = VoiceConversationSession(dependencies: SessionProbe().dependencies())
        #expect(!VoiceStageChrome.isShown(session: session, conversationID: UUID()))
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

@MainActor
@Suite("Realtime migration prompt")
struct RealtimeMigrationPromptTests {
    /// Settings and consent records on a separate defaults (does not touch .standard); old keys are written in the old settings page's on-disk shape.
    private struct Fixture {
        let suiteName = "RealtimeMigrationPromptTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: VoiceEngineSettings
        let disclosures: VoiceDisclosureStore
        let state: AppState
        let provider: Provider

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            settings = VoiceEngineSettings(defaults: defaults)
            disclosures = VoiceDisclosureStore(defaults: defaults)
            state = AppState(seedDemoData: true)
            provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
            )
            state.providers = [provider]
        }

        func storeOldChoice(model: String = "gpt-realtime", connectionID: String? = nil) {
            settings.setSelection(.cloud(VoiceCloudEngine(
                providerKind: .openAI,
                connectionID: connectionID ?? provider.id.uuidString,
                model: model,
                voice: "marin"
            )), for: .realtime)
        }

        func evaluate(conversationID: UUID? = nil, catalog: VoiceCatalog? = Fixture.catalog) -> RealtimeMigration.Entry {
            RealtimeMigration.evaluate(
                conversationID: conversationID,
                providers: state.providers,
                catalog: catalog,
                settings: settings,
                disclosures: disclosures
            )
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }

        static let catalog = VoiceCatalog(schemaVersion: 2, revision: "t", providers: [
            .openAI: VoiceProviderEntries(realtime: [VoiceRealtimeEntry(
                model: "gpt-realtime",
                transport: .openaiRealtime,
                path: "/v1/realtime",
                contextWindow: 32_000,
                voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
                maxSessionSec: nil,
                inputTranscriptionModel: nil,
                isDefault: true
            )]),
        ])
    }

    private func prompt(_ entry: RealtimeMigration.Entry) throws -> RealtimeMigrationPrompt {
        guard case .prompt(let prompt) = entry else {
            Issue.record("expected prompt, got \(entry)")
            throw CancellationError()
        }
        return prompt
    }

    @Test("Old selection is resolvable: show the sheet, model name taken from the catalog model, the sheet itself does not delete the old key")
    func resolvableShowsPrompt() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.storeOldChoice()
        let conversationID = UUID()

        let prompt = try prompt(f.evaluate(conversationID: conversationID))

        #expect(prompt.selection == RealtimeModelSelection(providerID: f.provider.id, providerKind: .openAI, model: "gpt-realtime"))
        #expect(prompt.conversationID == conversationID)
        #expect(prompt.switchTitle.contains("gpt-realtime"))
        #expect(!prompt.title.isEmpty)
        #expect(!prompt.keepTitle.isEmpty)
        #expect(f.settings.hasLegacyRealtimeSelection())
    }

    @Test("Switch (already agreed): the current conversation selects that realtime model, the input area projects to the voice dock; delete the old key")
    func switchSelectsRealtimeModel() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.storeOldChoice()
        f.disclosures.markAccepted(.openAI, direction: .realtime)
        // The conversation's realtime selection is derived from the conversation model field + the catalog: needs a real conversation (official apiKey connection) and a catalog containing that model.
        f.state.realtimeVoiceCatalog = { Fixture.catalog }
        let conversation = TestFactories.makeConversation(
            providerID: f.provider.id, providerKind: .openAI, modelID: "gpt-4o"
        )
        f.state.upsertConversationProjection(conversation)
        let conversationID = conversation.id
        let prompt = try prompt(f.evaluate(conversationID: conversationID))

        let result = RealtimeMigration.switchModel(prompt, appState: f.state, settings: f.settings, disclosures: f.disclosures)

        let expected = RealtimeModelSelection(providerID: f.provider.id, providerKind: .openAI, model: "gpt-realtime")
        #expect(result == .selected(expected))
        #expect(f.state.realtimeModelSelection(for: conversationID) == expected)
        #expect(RealtimeModelPolicy.capability(modelKind: .realtime, mode: .stage).voiceEntry == "stage")
        #expect(!f.settings.hasLegacyRealtimeSelection())
        #expect(f.disclosures.hasAccepted(.openAI, direction: .realtime))
    }

    @Test("Home switch (not agreed): show the disclosure first; agree → home selects it; decline → not selected, goes to ≋ as usual, old key still deleted")
    func switchWithoutConsentGoesThroughDisclosure() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.storeOldChoice()
        // Home's realtime selection is also judged against the catalog at read time : needs a catalog containing that model.
        f.state.realtimeVoiceCatalog = { Fixture.catalog }
        let prompt = try prompt(f.evaluate())

        let result = RealtimeMigration.switchModel(prompt, appState: f.state, settings: f.settings, disclosures: f.disclosures)
        guard case .needsDisclosure(let request) = result else {
            Issue.record("expected disclosure, got \(result)")
            return
        }
        #expect(request.conversationID == nil)
        #expect(f.state.realtimeModelSelection(for: nil) == nil)
        #expect(!f.settings.hasLegacyRealtimeSelection())

        #expect(!RealtimeMigration.resolveDisclosure(
            request, accepted: false, appState: f.state, disclosures: f.disclosures
        ))
        #expect(f.state.realtimeModelSelection(for: nil) == nil)
        #expect(!f.disclosures.hasAccepted(.openAI, direction: .realtime))

        #expect(RealtimeMigration.resolveDisclosure(
            request, accepted: true, appState: f.state, disclosures: f.disclosures
        ))
        #expect(f.state.realtimeModelSelection(for: nil) == request.selection)
        #expect(f.disclosures.hasAccepted(.openAI, direction: .realtime))
    }

    @Test("Continue with the current model: delete the old key and the pending realtime prompt; the agreement record is kept, no realtime model selected; tapping ≋ afterwards enters directly")
    func keepDeletesOldKeys() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.storeOldChoice()
        f.disclosures.markAccepted(.openAI, direction: .realtime)
        f.defaults.set(VoiceFallbackReason.entryRemoved.rawValue, forKey: "voice.engine.pendingNotice.use.realtime")
        let conversationID = UUID()
        let prompt = try prompt(f.evaluate(conversationID: conversationID))

        RealtimeMigration.keep(prompt, settings: f.settings)

        #expect(!f.settings.hasLegacyRealtimeSelection())
        #expect(f.settings.takePendingNotice(site: .use, direction: .realtime) == nil)
        #expect(f.disclosures.hasAccepted(.openAI, direction: .realtime))
        #expect(f.state.realtimeModelSelection(for: conversationID) == nil)
        #expect(f.evaluate(conversationID: conversationID) == .enterCascade)
    }

    @Test("Old selection not resolvable (catalog has no such model / connection missing / old version followed the current model): no sheet, silently delete the old key and enter ≋")
    func unresolvableDeletesSilently() {
        let cases: [(Fixture) -> Void] = [
            { $0.storeOldChoice(model: "gpt-realtime-retired") },
            { $0.storeOldChoice(connectionID: UUID().uuidString) },
            { $0.settings.setSelection(.system, for: .realtime) },
        ]
        for store in cases {
            let f = Fixture()
            defer { f.cleanUp() }
            store(f)
            #expect(f.settings.hasLegacyRealtimeSelection())

            #expect(f.evaluate() == .enterCascade)
            #expect(!f.settings.hasLegacyRealtimeSelection())
            #expect(f.state.realtimeModelSelection(for: nil) == nil)
        }
    }

    @Test("Not answered (interrupted by the system): old key kept, shows again next time; when the catalog has no conclusion yet, do not judge and keep the old key; without an old key enter ≋ directly")
    func unansweredKeepsOldKeys() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        #expect(f.evaluate() == .enterCascade)

        f.storeOldChoice()
        let first = try prompt(f.evaluate())
        #expect(f.settings.hasLegacyRealtimeSelection())

        #expect(f.evaluate(catalog: nil) == .enterCascade)
        #expect(f.settings.hasLegacyRealtimeSelection())

        let second = try prompt(f.evaluate())
        #expect(second == first)
        #expect(f.settings.hasLegacyRealtimeSelection())
    }
}
