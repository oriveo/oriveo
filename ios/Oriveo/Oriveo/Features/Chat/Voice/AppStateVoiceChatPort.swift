import Combine
import Foundation
import Observation

/// The side of chat state that a voice conversation reads; AppState in production, a stand-in in tests.
@MainActor
protocol VoiceConversationChatHost: AnyObject {
    func streamingText(in conversationID: UUID) -> String
    func streamingTextDidChange(in conversationID: UUID) -> AnyPublisher<Void, Never>
    /// Stream-finished signal (completed / failed / stopped); when received, isBusyStreaming is already false and the last assistant message is in a terminal state.
    func streamingDidFinish(in conversationID: UUID) -> AnyPublisher<Void, Never>
    func isBusyStreaming(in conversationID: UUID) -> Bool
    /// The conversation's last assistant message (its state tells completed from failed).
    func lastAssistantMessage(in conversationID: UUID) -> ChatMessage?
    /// A tool call is waiting for user confirmation (the MCP confirmation queue is non-empty); must be trackable by Observation (the port watches it with withObservationTracking).
    var hasPendingToolApproval: Bool { get }
    /// The existing stop-generation action.
    func cancelGeneration(in conversationID: UUID)
}

extension AppState: VoiceConversationChatHost {
    func lastAssistantMessage(in conversationID: UUID) -> ChatMessage? {
        conversation(for: conversationID)?.messages.last { $0.role == .assistant }
    }

    var hasPendingToolApproval: Bool {
        !mcpConfirmationCoordinator.pending.isEmpty
    }
}

/// Task context for a voice send: when AppState creates a conversation for a `delivery: .voice` first sentence, it calls back synchronously with the new id before presentChat.
enum VoiceSendContext {
    @TaskLocal static var onConversationCreated: (@MainActor @Sendable (UUID) -> Void)?
}

/// AppState bridge for `VoiceConversationChatPort`: sending goes through `sendMessageOutcome(…, delivery: .voice)`,
/// reply events are driven by the streaming-text and stream-finished signals (reading the last assistant message's state), and approval observes the MCP confirmation queue; no polling.
/// When entered from the home page the conversation id is nil: AppState creates the conversation on the first send, and the port then follows the new id.
@MainActor
final class AppStateVoiceChatPort: VoiceConversationChatPort {
    /// Sends one voice transcript; when conversationID is nil AppState creates a new conversation. The host is responsible for passing delivery: .voice.
    typealias Send = @MainActor (_ text: String, _ conversationID: UUID?) async -> ChatSendOutcome

    private(set) var conversationID: UUID?
    /// The first send (which creates the conversation) is in flight: during the home → chat page handoff the host must not treat the page leaving as a return.
    private(set) var isCreatingConversation = false
    /// Number of turns completed normally (delivered) in this conversation (analytics turn_count); interrupted ones do not count.
    private(set) var completedTurns = 0
    /// The conversation id changed (the home page's first send created the conversation).
    var onConversationChanged: ((UUID) -> Void)?
    /// The home page's first send hands the conversation off: fires synchronously inside the create-conversation callback, before the id is written back and before the chat page opens, once per session.
    var onHandedOff: (() -> Void)?
    private var handedOff = false

    private let host: VoiceConversationChatHost
    private let sendMessage: Send

    private var continuation: AsyncStream<VoiceConversationReplyEvent>.Continuation?
    private var watch: Watch?

    /// Observation of one reply: from a successful send to completion / failure.
    private final class Watch {
        let conversationID: UUID
        /// The last assistant message before the send: completion only counts a message newer than it.
        let previousAssistantID: UUID?
        var subscriptions: [AnyCancellable] = []
        var lastText = ""
        init(conversationID: UUID, previousAssistantID: UUID?) {
            self.conversationID = conversationID
            self.previousAssistantID = previousAssistantID
        }
    }

    private var approvalPending = false
    /// One generation token per reply event stream: observation callbacks from an old stream are dropped by it.
    private var approvalGeneration = 0

    init(
        host: VoiceConversationChatHost,
        conversationID: UUID?,
        send: @escaping Send
    ) {
        self.host = host
        self.conversationID = conversationID
        self.sendMessage = send
    }

    // MARK: VoiceConversationChatPort

    func send(_ text: String) async -> Bool {
        let target = conversationID
        let previous = target.flatMap { host.lastAssistantMessage(in: $0)?.id }
        stopWatching()
        let outcome: ChatSendOutcome
        if target == nil {
            isCreatingConversation = true
            // Receive the new id on the same tick the conversation is created (before presentChat); the send closure comes from the page, so the callback travels via a task-local and its signature stays unchanged.
            outcome = await VoiceSendContext.$onConversationCreated.withValue({ [weak self] id in
                self?.handOff()
                self?.adoptConversation(id)
            }) {
                await sendMessage(text, target)
            }
        } else {
            outcome = await sendMessage(text, target)
        }
        isCreatingConversation = false
        guard case .sent(let sentConversationID) = outcome else { return false }
        // The send closure did not go through the create-conversation callback (the task-local did not propagate): hand off here at .sent, still before the id is written back.
        if target == nil { handOff() }
        adoptConversation(sentConversationID)
        startWatching(sentConversationID, previousAssistantID: previous)
        return true
    }

    func makeReplyEvents() -> AsyncStream<VoiceConversationReplyEvent> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream<VoiceConversationReplyEvent>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.streamTerminated() }
        }
        approvalPending = false
        approvalGeneration += 1
        observeApproval(generation: approvalGeneration)
        return stream
    }

    func cancel() {
        guard let conversationID else { return }
        host.cancelGeneration(in: conversationID)
    }

    private func handOff() {
        guard !handedOff else { return }
        handedOff = true
        onHandedOff?()
    }

    /// Follows the new conversation id: the same id is announced only once.
    private func adoptConversation(_ id: UUID) {
        guard conversationID != id else { return }
        conversationID = id
        onConversationChanged?(id)
    }

    // MARK: Observation

    /// Checks once immediately (besides the streaming and finished signals; tests and the host can call it directly).
    func refresh() {
        checkApproval()
        checkReply()
    }

    private func startWatching(_ conversationID: UUID, previousAssistantID: UUID?) {
        let watch = Watch(conversationID: conversationID, previousAssistantID: previousAssistantID)
        self.watch = watch
        let signals = [host.streamingTextDidChange(in: conversationID), host.streamingDidFinish(in: conversationID)]
        watch.subscriptions = signals.map {
            $0.sink { [weak self] in
                MainActor.assumeIsolated { self?.checkReply() }
            }
        }
        checkReply()
    }

    private func stopWatching() {
        watch?.subscriptions.forEach { $0.cancel() }
        watch = nil
    }

    private func checkReply() {
        guard let watch, let continuation else { return }
        let id = watch.conversationID
        let streaming = host.streamingText(in: id)
        if !streaming.isEmpty, streaming != watch.lastText {
            watch.lastText = streaming
            continuation.yield(.text(streaming))
        }
        guard !host.isBusyStreaming(in: id),
              let last = host.lastAssistantMessage(in: id),
              last.id != watch.previousAssistantID,
              last.state != .generating
        else { return }
        stopWatching()
        switch last.state {
        case .failed:
            continuation.yield(.failed(code: "reply_failed"))
        case .delivered, .interrupted, .generating:
            if last.text != watch.lastText { continuation.yield(.text(last.text)) }
            if last.state == .delivered { completedTurns += 1 }
            continuation.yield(.completed)
        }
    }

    /// Reads the pending approval once and registers an observation; after a change (willSet) it re-reads on the next tick and registers again.
    private func observeApproval(generation: Int) {
        guard continuation != nil, generation == approvalGeneration else { return }
        withObservationTracking {
            _ = host.hasPendingToolApproval
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeApproval(generation: generation) }
        }
        checkApproval()
    }

    private func checkApproval() {
        guard let continuation else { return }
        let pending = host.hasPendingToolApproval
        guard pending != approvalPending else { return }
        approvalPending = pending
        continuation.yield(.approvalPending(pending))
    }

    private func streamTerminated() {
        continuation = nil
        approvalGeneration += 1
        stopWatching()
    }
}
