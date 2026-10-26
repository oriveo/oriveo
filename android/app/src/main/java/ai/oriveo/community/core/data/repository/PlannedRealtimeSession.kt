package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextSanitizer
import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.context.RealtimeSessionInput
import ai.oriveo.community.core.context.RealtimeSessionMessage
import ai.oriveo.community.core.context.RealtimeSessionPlan
import ai.oriveo.community.core.context.assembleRealtimeSession
import ai.oriveo.community.core.data.repository.ChatContextProjector.toContextMessage
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.QuotePromptBuilder

/** The only input the realtime transport receives: the opening instructions and a plain-text history. */
internal class RealtimeTransportInput internal constructor(
    val instructions: String,
    val history: List<RealtimeHistoryItem>,
)

/**
 * A realtime session opening plan that was not rejected.
 * The constructor is private: it can only be obtained from a plan through [from]; a rejected plan yields null, so no session is opened from it.
 */
internal class PlannedRealtimeSession private constructor(
    val plan: RealtimeSessionPlan,
    private val instructions: String,
    private val history: List<RealtimeHistoryItem>,
) {
    /** Gives only {instructions, history}; the other plan fields never reach the transport. */
    fun transportInput(): RealtimeTransportInput = RealtimeTransportInput(instructions = instructions, history = history)

    companion object {
        fun from(plan: RealtimeSessionPlan): PlannedRealtimeSession? {
            if (plan.reject != null) return null
            val instructions = plan.instructions ?: return null
            val history = plan.history ?: return null
            return PlannedRealtimeSession(plan, instructions, history)
        }
    }
}

/** Projection of app messages into a realtime session opening plan: it only maps and assembles, and never touches the network or the database. */
internal object RealtimeSessionProjector {
    /**
     * The plan of a realtime session: the checkpoint is fetched the same way as in chat ([latestValid] is the coordinator's latestValid, computing the
     * digest over the stored history after quote expansion; realtime has no pending user message for this turn, so the last message is not dropped), and without one it is simply omitted.
     * Opening a new session passes null for [currentSessionId]; re-planning at a turn boundary passes the open session and its already stored transcript [sessionMessageIds]
     * (see [project]), and the checkpoint is fetched the same way.
     */
    suspend fun projectOpening(
        request: ChatContextRequest,
        conversationId: String,
        rawMessages: List<ChatMessage>,
        contextWindow: Int?,
        latestValid: suspend (String, List<CheckpointCoveredMessage>) -> ContextCheckpointRecord?,
        currentSessionId: String? = null,
        sessionMessageIds: Set<String> = emptySet(),
    ): RealtimeSessionPlan {
        val covered = QuotePromptBuilder.applyToMessages(rawMessages).map { CheckpointCoveredMessage(it.id, it.text) }
        return project(
            request = request,
            rawMessages = rawMessages,
            contextWindow = contextWindow,
            currentSessionId = currentSessionId,
            sessionMessageIds = sessionMessageIds,
            checkpoint = latestValid(conversationId, covered),
        )
    }

    /**
     * [rawMessages] = the messages already stored for the conversation (no pending user message for this turn); quote expansion and sanitize follow the main chat path.
     * [sessionMessageIds] = the set of message ids stored during this session, held in the host's memory and never persisted: when [currentSessionId] is non-null
     * these messages are removed before sanitize, so history never carries a realtimeSessionId; when [currentSessionId] is null they are read in as usual.
     * Memory is fetched the same way as [ChatContextProjector.project]: from the conversation and memoryItems of [request].
     * [checkpoint] = the valid stored row (same rules as chat): it applies only when coversTo is among the raw messages, messages up to and including coversTo stay out of history,
     * and the row text goes to the assembler; the split is done on the raw messages first, then quotes are expanded and sanitize runs. It does not borrow the chat plan to split (a snapshot ending with an assistant message cannot form chat messages).
     */
    fun project(
        request: ChatContextRequest,
        rawMessages: List<ChatMessage>,
        contextWindow: Int?,
        currentSessionId: String?,
        sessionMessageIds: Set<String>,
        rhoHi: Double = ContextBudget.RHO0,
        checkpoint: ContextCheckpointRecord? = null,
    ): RealtimeSessionPlan {
        val coversIndex = checkpoint?.let { row -> rawMessages.indexOfFirst { it.id == row.coversTo } } ?: -1
        val applied = checkpoint?.takeIf { coversIndex >= 0 }
        val tail = if (applied != null) rawMessages.subList(coversIndex + 1, rawMessages.size) else rawMessages
        val quoted = QuotePromptBuilder.applyToMessages(tail)
        // This session's transcript must be removed before sanitize: sanitize keeps the later id when it merges adjacent user messages, so merging first would exclude an unanswered chat user message too.
        val outside = if (currentSessionId == null) quoted else quoted.filterNot { it.id in sessionMessageIds }
        val sanitized = ContextSanitizer.sanitize(outside.map { it.toContextMessage() })
        val history = sanitized.map { message ->
            RealtimeSessionMessage(
                id = message.id,
                role = message.role,
                text = message.text,
                attachmentKinds = message.attachments.map { it.kind.rawValue },
            )
        }
        return assembleRealtimeSession(
            RealtimeSessionInput(
                contextWindow = contextWindow,
                rhoHi = rhoHi,
                conversation = request.conversation,
                memoryItems = request.memoryItems,
                history = history,
                checkpoint = applied?.text,
                currentSessionId = currentSessionId,
            ),
        )
    }
}
