import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Production ChatMessage snapshot -> realtimeSessionInput -> assembleRealtimeSession -> PlannedRealtimeSession.
struct PlannedRealtimeSessionTests {
    private static func snapshot(_ messages: [ChatMessage], instructions: String = "") -> ChatRequestSnapshot {
        ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(), useMemory: false, skillID: nil, instructions: instructions
            ),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
    }

    private static func planned(
        _ messages: [ChatMessage],
        contextWindow: Int? = 128_000,
        currentSessionId: String?,
        sessionMessageIds: Set<UUID> = [],
        instructions: String = "",
        checkpoint: ContextCheckpointRecord? = nil
    ) -> (plan: RealtimeSessionPlan, planned: PlannedRealtimeSession?) {
        let input = ChatRequestBuilder.realtimeSessionInput(
            snapshot(messages, instructions: instructions),
            contextWindow: contextWindow,
            currentSessionId: currentSessionId,
            sessionMessageIds: sessionMessageIds,
            checkpoint: checkpoint
        )
        let plan = ContextAssembler.assembleRealtimeSession(input)
        return (plan, PlannedRealtimeSession.from(plan))
    }

    @Test func current_session_transcript_excluded() throws {
        let earlierUser = TestFactories.makeMessage(role: .user, text: "Typed question")
        let earlierReply = TestFactories.makeMessage(role: .assistant, text: "Typed answer")
        let spokenUser = TestFactories.makeMessage(role: .user, text: "Spoken question")
        let spokenReply = TestFactories.makeMessage(role: .assistant, text: "Spoken answer")
        let result = Self.planned(
            [earlierUser, earlierReply, spokenUser, spokenReply],
            currentSessionId: "rt-1",
            sessionMessageIds: [spokenUser.id, spokenReply.id]
        )
        let planned = try #require(result.planned)
        #expect(planned.history.map(\.id) == [earlierUser.id.uuidString, earlierReply.id.uuidString])
        #expect(planned.transportInput().history.map(\.text) == ["Typed question", "Typed answer"])
        #expect(result.plan.fingerprint?.lastHistoryId == earlierReply.id.uuidString)
    }

    /// Sanitize merges adjacent user messages and keeps the later id, so the current session's transcript must be removed before sanitize; only then is an unanswered chat user message kept.
    @Test func unanswered_chat_user_kept_before_session_transcript() throws {
        let earlierUser = TestFactories.makeMessage(role: .user, text: "Typed question")
        let earlierReply = TestFactories.makeMessage(role: .assistant, text: "Typed answer")
        let unanswered = TestFactories.makeMessage(role: .user, text: "Unanswered typed question")
        let spokenUser = TestFactories.makeMessage(role: .user, text: "Spoken question")
        let spokenReply = TestFactories.makeMessage(role: .assistant, text: "Spoken answer")
        let result = Self.planned(
            [earlierUser, earlierReply, unanswered, spokenUser, spokenReply],
            currentSessionId: "rt-1",
            sessionMessageIds: [spokenUser.id, spokenReply.id]
        )
        let planned = try #require(result.planned)
        #expect(planned.history.contains { $0.id == unanswered.id.uuidString })
        #expect(planned.transportInput().history.contains { $0.text == "Unanswered typed question" })
        #expect(!planned.transportInput().history.contains { $0.text.contains("Spoken") })
    }

    @Test func new_session_without_current_id_reads_session_messages() throws {
        let user = TestFactories.makeMessage(role: .user, text: "Spoken question")
        let reply = TestFactories.makeMessage(role: .assistant, text: "Spoken answer")
        let result = Self.planned([user, reply], currentSessionId: nil, sessionMessageIds: [user.id, reply.id])
        let planned = try #require(result.planned)
        #expect(planned.history.map(\.id) == [user.id.uuidString, reply.id.uuidString])
        #expect(planned.transportInput().history.map(\.role) == [.user, .assistant])
    }

    @Test func rejected_plan_not_constructed() {
        let messages = [TestFactories.makeMessage(role: .user, text: "Hi")]
        let unknown = Self.planned(messages, contextWindow: nil, currentSessionId: nil)
        #expect(unknown.plan.reject == .unknownWindow)
        #expect(unknown.planned == nil)

        let tooLong = Self.planned(
            messages, contextWindow: 40, currentSessionId: nil,
            instructions: String(repeating: "Always answer formally. ", count: 40)
        )
        #expect(tooLong.plan.reject == .instructionsTooLong)
        #expect(tooLong.planned == nil)
    }

    @Test func transport_input_only_instructions_and_history() throws {
        let user = TestFactories.makeMessage(role: .user, text: "Hello")
        let reply = TestFactories.makeMessage(role: .assistant, text: "Hi there")
        let result = Self.planned([user, reply], currentSessionId: nil, instructions: "Be brief.")
        let planned = try #require(result.planned)
        let transport = planned.transportInput()

        #expect(Mirror(reflecting: transport).children.map(\.label) == ["instructions", "history"])
        #expect(transport.history.allSatisfy { Mirror(reflecting: $0).children.map(\.label) == ["role", "text"] })
        #expect(transport.instructions == result.plan.instructions)
        #expect(transport.instructions.contains("<oriveo-delivery>\n\(ContextAssembler.deliveryRealtime)\n</oriveo-delivery>"))
        #expect(transport.instructions.contains("Be brief."))
        #expect(result.plan.fingerprint?.instructionsSha256 == MemoryItems.sha256Hex(transport.instructions))
        #expect(transport.history.map(\.text) == ["Hello", "Hi there"])
    }

    @Test func attachment_message_uses_placeholder() throws {
        let image = TestFactories.makeImageAttachment(fileName: "photo.png")
        let file = TestFactories.makeFileAttachment(fileName: "notes.txt", mimeType: "text/plain", base64Data: "aGVsbG8=")
        let user = TestFactories.makeMessage(role: .user, text: "Look at these", attachments: [image, file])
        let imageOnly = TestFactories.makeMessage(role: .user, text: "", attachments: [image])
        let reply = TestFactories.makeMessage(role: .assistant, text: "Nice")
        let result = Self.planned([user, reply, imageOnly], currentSessionId: nil)
        let transport = try #require(result.planned).transportInput()
        #expect(transport.history.map(\.text) == [
            "Look at these\n" + ContextAssembler.realtimeImagePlaceholder + "\n" + ContextAssembler.realtimeFilePlaceholder,
            "Nice",
            ContextAssembler.realtimeImagePlaceholder,
        ])
    }

    /// The snapshot goes through the same sanitize as chat: a failed answer stays out of the opening history, and the transport receives a history that starts with a user turn and alternates roles.
    @Test func failed_message_not_in_history() throws {
        let first = TestFactories.makeMessage(role: .user, text: "First")
        let failed = TestFactories.makeMessage(role: .assistant, text: "partial", state: .failed)
        let second = TestFactories.makeMessage(role: .user, text: "Second")
        let reply = TestFactories.makeMessage(role: .assistant, text: "Answer")
        let result = Self.planned([first, failed, second, reply], currentSessionId: nil)
        let planned = try #require(result.planned)
        #expect(!planned.history.contains { $0.id == failed.id.uuidString })
        #expect(planned.history.map(\.role) == [.user, .assistant])
        #expect(planned.history.last?.id == reply.id.uuidString)
        #expect(planned.transportInput().history.allSatisfy { !$0.text.contains("partial") })
    }

    /// The checkpoint follows the same rules as chat rows: covered messages stay out of the history and the first user message carries the checkpoint prefix.
    @Test func checkpoint_prefixes_first_user_and_drops_covered() throws {
        let coveredUser = TestFactories.makeMessage(role: .user, text: "Old question")
        let coveredReply = TestFactories.makeMessage(role: .assistant, text: "Old answer")
        let user = TestFactories.makeMessage(role: .user, text: "New question")
        let reply = TestFactories.makeMessage(role: .assistant, text: "New answer")
        let text = "<oriveo-context-checkpoint>\n## Goal\n</oriveo-context-checkpoint>"
        let covered = [
            ContextCheckpoint.CoveredMessage(id: coveredUser.id.uuidString, text: coveredUser.text),
            ContextCheckpoint.CoveredMessage(id: coveredReply.id.uuidString, text: coveredReply.text),
        ]
        let row = ContextCheckpointRecord(
            conversationId: "conversation",
            checkpointId: ContextCheckpoint.checkpointId(conversationId: "conversation", coversTo: coveredReply.id.uuidString),
            kind: .summary,
            coversFrom: coveredUser.id.uuidString,
            coversTo: coveredReply.id.uuidString,
            coversDigest: ContextCheckpoint.coversDigest(covered),
            messagesCovered: 2,
            userMessageIds: [coveredUser.id.uuidString],
            text: text,
            summary: "## Goal",
            language: "en",
            model: "model",
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: 1_700_000_000_123,
            cost: nil
        )
        let result = Self.planned([coveredUser, coveredReply, user, reply], currentSessionId: nil, checkpoint: row)
        let planned = try #require(result.planned)
        #expect(planned.history.map(\.id) == [user.id.uuidString, reply.id.uuidString])
        #expect(planned.transportInput().history.map(\.text) == [text + "\n\nNew question", "New answer"])
    }

    /// Opening a realtime session picks the latest valid checkpoint like chat does: the input produced by the ChatManager production path carries the checkpoint and covered messages stay out of the history.
    @MainActor
    @Test func realtime_input_applies_latest_valid_checkpoint() throws {
        let coveredUser = TestFactories.makeMessage(role: .user, text: "Old question")
        let coveredReply = TestFactories.makeMessage(role: .assistant, text: "Old answer")
        let user = TestFactories.makeMessage(role: .user, text: "New question")
        let reply = TestFactories.makeMessage(role: .assistant, text: "New answer")
        let state = AppState(seedDemoData: false, sessionUID: "planned-realtime-checkpoint-\(UUID().uuidString)")
        var conversation = TestFactories.makeConversation(messages: [coveredUser, coveredReply, user, reply])
        conversation.useMemory = false
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        let conversationId = conversation.id.uuidString
        let covered = [
            ContextCheckpoint.CoveredMessage(id: coveredUser.id.uuidString, text: coveredUser.text),
            ContextCheckpoint.CoveredMessage(id: coveredReply.id.uuidString, text: coveredReply.text),
        ]
        let text = "<oriveo-context-checkpoint v=\"1\">\n<note>\(ContextCheckpoint.note)</note>\n"
            + "Earlier turns: the user asked an old question.\n</oriveo-context-checkpoint>"
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        try store.save(ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: ContextCheckpoint.checkpointId(conversationId: conversationId, coversTo: coveredReply.id.uuidString),
            kind: .fallback,
            coversFrom: coveredUser.id.uuidString,
            coversTo: coveredReply.id.uuidString,
            coversDigest: ContextCheckpoint.coversDigest(covered),
            messagesCovered: 2,
            userMessageIds: [coveredUser.id.uuidString],
            text: text,
            summary: nil,
            language: nil,
            model: "model",
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
            cost: nil
        ))

        let input = try #require(state.chatManager.realtimeSessionInput(in: conversation.id, contextWindow: 128_000))
        #expect(input.checkpoint == text)
        #expect(input.history.map(\.id) == [user.id.uuidString, reply.id.uuidString])
        let planned = try #require(PlannedRealtimeSession.from(ContextAssembler.assembleRealtimeSession(input)))
        #expect(planned.transportInput().history.map(\.text) == [text + "\n\nNew question", "New answer"])
    }

    /// Replanning: when the ChatManager entry point assembles with a currentSessionId, transcript already persisted for the current session stays out of the plan and does not change the fingerprint.
    @MainActor
    @Test func current_session_messages_excluded_from_plan() throws {
        let user = TestFactories.makeMessage(role: .user, text: "Typed question")
        let reply = TestFactories.makeMessage(role: .assistant, text: "Typed answer")
        let spokenUser = TestFactories.makeMessage(role: .user, text: "Spoken question")
        let spokenReply = TestFactories.makeMessage(role: .assistant, text: "Spoken answer")
        let state = AppState(seedDemoData: false, sessionUID: "planned-realtime-session-\(UUID().uuidString)")
        var conversation = TestFactories.makeConversation(messages: [user, reply])
        conversation.useMemory = false
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        let opening = try #require(state.chatManager.realtimeSessionInput(
            in: conversation.id, contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: []
        ))
        let openFingerprint = try #require(ContextAssembler.assembleRealtimeSession(opening).fingerprint)

        for message in [spokenUser, spokenReply] {
            #expect(state.chatManager.appendCompletedTextMessage(message, in: conversation.id))
        }
        let own: Set<UUID> = [spokenUser.id, spokenReply.id]
        let input = try #require(state.chatManager.realtimeSessionInput(
            in: conversation.id, contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: own
        ))
        #expect(input.currentSessionId == "rt-1")
        #expect(input.history.map(\.id) == [user.id.uuidString, reply.id.uuidString])
        let plan = ContextAssembler.assembleRealtimeSession(input)
        #expect(plan.fingerprint == openFingerprint)

        // New session (currentSessionId is nil): the same messages count as ordinary history and the fingerprint advances
        let fresh = try #require(state.chatManager.realtimeSessionInput(in: conversation.id, contextWindow: 128_000))
        #expect(fresh.history.map(\.id).last == spokenReply.id.uuidString)
        #expect(ContextAssembler.assembleRealtimeSession(fresh).fingerprint?.lastHistoryId == spokenReply.id.uuidString)
    }

    /// Pending pinned notes from the home screen enter the opening snapshot. The ChatManager entry point resolves them read-only (without committing);
    /// after the first turn is stored, realtimeSessionSource(in:) commits through prepareRequestSnapshot and resolves again, and both instructions are byte-identical with an unchanged fingerprint.
    @MainActor
    @Test func home_pending_pinned_notes_in_opening_snapshot() throws {
        let state = AppState(seedDemoData: false, sessionUID: "planned-realtime-home-pins-\(UUID().uuidString)")
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "gpt-4o")
        let note = try #require(state.noteManager.createNote(
            from: NoteDraft(title: "Trip plan", body: "Leave on Friday at nine.", captureKind: .blank)
        ))
        state.pinNote(note.id, to: nil)
        #expect(state.pendingPinnedNoteIds == [note.id])

        let opening = try #require(state.chatManager.realtimeSessionInputForNewConversation(contextWindow: 128_000))
        let openPlan = ContextAssembler.assembleRealtimeSession(opening)
        #expect(openPlan.instructions?.contains("Leave on Friday at nine.") == true)
        // Read-only: opening the session does not commit the pending pinned notes
        #expect(state.pendingPinnedNoteIds == [note.id])

        let created = try #require(state.createConversationForRealtimeVoice())
        let user = TestFactories.makeMessage(role: .user, text: "Hello from home")
        let reply = TestFactories.makeMessage(role: .assistant, text: "Hi there")
        #expect(state.chatManager.appendCompletedTextMessage(user, in: created))
        #expect(state.chatManager.appendCompletedTextMessage(reply, in: created))
        let replan = try #require(state.chatManager.realtimeSessionSource(in: created)).input(
            contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: [user.id, reply.id]
        )
        #expect(state.pendingPinnedNoteIds.isEmpty)
        #expect(state.pinnedNoteIDs(for: created) == [note.id])
        let replanPlan = ContextAssembler.assembleRealtimeSession(replan)
        #expect(replanPlan.instructions == openPlan.instructions)
        #expect(replanPlan.fingerprint == openPlan.fingerprint)
    }
}
