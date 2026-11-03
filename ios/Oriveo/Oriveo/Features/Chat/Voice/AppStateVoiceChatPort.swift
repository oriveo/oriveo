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
    /// Tool calls are waiting for user confirmation (the MCP confirmation dialog queue is non-empty); must be observable by Observation (the port observes it with withObservationTracking).
    var hasPendingToolApproval: Bool { get }
    /// This conversation has a send stopped at the pre-send confirmation gate (the over-price-limit context confirmation is pending); other conversations do not count. Likewise must be observable by Observation.
    func hasPendingSendConfirmation(in conversationID: UUID) -> Bool
    /// The message is still in the conversation (the port uses this to tell whether this turn's user message was cancelled by the confirmation gate, or rolled back and deleted by a stop).
    func containsMessage(_ messageID: UUID, in conversationID: UUID) -> Bool
    /// Stops generation.
    func cancelGeneration(in conversationID: UUID)
    /// The ID of the conversation's last user message (the port records this turn's target after send returns).
    func lastUserMessageID(in conversationID: UUID) -> UUID?
    /// Interject while thinking: text is appended to the end of user message messageID (same bubble; nil = the last user message) and the reply after it is regenerated;
    /// empty text = regenerate as is. false = blocked by the gate (no stream stop, no rewrite), or the conversation / user message does not exist, or it could not be sent.
    /// turnText = the original text of this turn recorded by the port: if the target is no longer in the conversation (rolled back), joinAmend(turnText, text) is sent as a new voice message; nil and no rolled-back content = false.
    func amendLastUserMessage(_ text: String, messageID: UUID?, turnText: String?, in conversationID: UUID) async -> Bool
}

extension AppState: VoiceConversationChatHost {
    func lastAssistantMessage(in conversationID: UUID) -> ChatMessage? {
        conversation(for: conversationID)?.messages.last { $0.role == .assistant }
    }

    func lastUserMessageID(in conversationID: UUID) -> UUID? {
        conversation(for: conversationID)?.messages.last { $0.role == .user }?.id
    }

    var hasPendingToolApproval: Bool {
        !mcpConfirmationCoordinator.pending.isEmpty
    }

    func hasPendingSendConfirmation(in conversationID: UUID) -> Bool {
        contextCapConfirmCoordinator.pending(for: conversationID) != nil
    }

    func containsMessage(_ messageID: UUID, in conversationID: UUID) -> Bool {
        conversation(for: conversationID)?.messages.contains { $0.id == messageID } ?? false
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

    /// In-flight send / amend: amend waits for the in-flight send to return before fixing its target (an amend after cancel also waits for the invalidated send to settle); cancel increments the epoch and invalidates both.
    private var inFlightSend: Task<Bool, Never>?
    private var inFlightAmend: Task<Bool, Never>?
    /// Incremented on each beginSend: an in-flight send is cleared only when the latest one settles.
    private var sendSerial = 0
    /// Incremented on each beginAmend: an in-flight amend is cleared only when the latest one settles.
    private var amendSerial = 0
    private var epoch = 0
    /// User message ID produced by this turn's send: an interjection rewrites it, not the previous turn; nil (no successful send yet) means the host takes the last user message.
    private var turnUserMessageID: UUID?
    /// The original text of this turn (recorded at send): after the target is rolled back the host continues from it; nil if send has not happened in this session.
    private var turnText: String?

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
        await beginSend(text).value
    }

    /// Synchronously claims the epoch and registers as in-flight: a cancel right after the return (send then cancel in a replay batch) invalidates this turn and stops the generation it emitted.
    func beginSend(_ text: String) -> Task<Bool, Never> {
        let epoch = self.epoch
        sendSerial += 1
        let serial = sendSerial
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let sent = await self.performSend(text, epoch: epoch)
            if self.sendSerial == serial { self.inFlightSend = nil }
            return sent
        }
        inFlightSend = task
        return task
    }

    private func performSend(_ text: String, epoch: Int) async -> Bool {
        turnText = text
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
        // The user message is already saved: even if invalidated it counts as this turn, so later interjections attach after it instead of the previous turn.
        turnUserMessageID = host.lastUserMessageID(in: sentConversationID)
        // Cancelled while in flight (conversation ended / replay interrupted): this turn is invalidated, the generation it emitted is stopped, and it is not observed.
        guard epoch == self.epoch else {
            host.cancelGeneration(in: sentConversationID)
            return false
        }
        startWatching(sentConversationID, previousAssistantID: previous)
        return true
    }

    /// Interjection continuation: first wait for the in-flight send to return, then the host rewrites and regenerates by this turn's user message ID (the gate and stream stop both live in the host, the gate first);
    /// reply events follow the same observation rule as send.
    func amend(_ text: String) async -> Bool {
        await beginAmend(text).value
    }

    /// Synchronously claims the epoch and registers as in-flight: a cancel right after the return invalidates this interjection (if not yet handed to the host it is not handed over; if already handed over, its generation is stopped).
    func beginAmend(_ text: String) -> Task<Bool, Never> {
        beginAmend(text, onDelivered: {})
    }

    /// onDelivered is called synchronously before the text is handed to the host to rewrite the message (the delivery point); if invalidated before delivery it is not called.
    func beginAmend(_ text: String, onDelivered: @escaping @MainActor () -> Void) -> Task<Bool, Never> {
        let epoch = self.epoch
        amendSerial += 1
        let serial = amendSerial
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let sent = await self.performAmend(text, epoch: epoch, onDelivered: onDelivered)
            if self.amendSerial == serial { self.inFlightAmend = nil }
            return sent
        }
        inFlightAmend = task
        return task
    }

    private func performAmend(_ text: String, epoch: Int, onDelivered: @MainActor () -> Void) async -> Bool {
        if let pendingSend = inFlightSend { _ = await pendingSend.value }
        guard epoch == self.epoch, let target = conversationID else { return false }
        let previous = host.lastAssistantMessage(in: target)?.id
        stopWatching()
        onDelivered()
        guard await host.amendLastUserMessage(text, messageID: turnUserMessageID, turnText: turnText, in: target) else { return false }
        guard epoch == self.epoch else {
            host.cancelGeneration(in: target)
            return false
        }
        // After this turn is rolled back, the continuation starts a new user message: later interjections follow it.
        turnUserMessageID = host.lastUserMessageID(in: target)
        if let turnText { self.turnText = VoiceConversationLogic.joinAmend(turnText, text) }
        startWatching(target, previousAssistantID: previous)
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

    /// Stops generation and invalidates in-flight send / amend: they neither generate nor observe after returning.
    func cancel() {
        epoch += 1
        inFlightAmend = nil
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
        // The send confirmation is read per conversation: after switching conversations, observation is re-registered under the new ID (callbacks registered earlier are invalidated by the generation token).
        if continuation != nil {
            approvalGeneration += 1
            observeApproval(generation: approvalGeneration)
        }
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
        // This turn's user message was rolled back and deleted (cancelled by the confirmation gate, or stopped at the gate): no reply will come, so report failure instead of staying in 'thinking'.
        // The confirmation dialog was already dequeued before the rollback: first synchronously report pending approval (approvalPending(false)), then report failure; the order is independent of observation callback timing.
        if let turnUserMessageID, !host.containsMessage(turnUserMessageID, in: id) {
            stopWatching()
            checkApproval()
            continuation.yield(.failed(code: "reply_failed"))
            return
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

    /// Reads the pending approval once and registers observation; after a change (willSet) the next tick re-reads and re-registers.
    /// On change, also check the reply: the rollback that comes with a dialog dequeue may not be followed by a stream-end signal, so report the failure as a fallback here.
    private func observeApproval(generation: Int, checksReply: Bool = false) {
        guard continuation != nil, generation == approvalGeneration else { return }
        withObservationTracking {
            _ = pendingApproval
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeApproval(generation: generation, checksReply: true) }
        }
        checkApproval()
        if checksReply { checkReply() }
    }

    // Pending approval = tool approval / library confirmation, or the pre-send confirmation dialog in this conversation is pending: both pause the idle timer.
    private var pendingApproval: Bool {
        let tool = host.hasPendingToolApproval
        let send = conversationID.map { host.hasPendingSendConfirmation(in: $0) } ?? false
        return tool || send
    }

    private func checkApproval() {
        guard let continuation else { return }
        let pending = pendingApproval
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
