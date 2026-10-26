package ai.oriveo.community.core.context

/**
 * Chat-path assembler inputs carried from the send coordinator to ChatRepository
 * (send / retry / regenerate / edit-and-send). Continue and the other purposes leave it null.
 */
data class ChatContextRequest(
    val conversation: ContextConversation,
    val memoryItems: List<ContextMemoryItem> = emptyList(),
    /** Attachment guidance for this turn; goes into the [D] block of the current user message. */
    val attachmentGuide: String? = null,
    /**
     * Ranked L3 hits for the user message this turn answers (memory-recall.v1 rule 9); computed once per send
     * and reused by every leg, retry projection and overflow re-projection of that turn.
     */
    val recall: List<ContextRecallEntry> = emptyList(),
    /**
     * Reply-style envelope of this turn: VOICE for a voice-conversation send, carried by every leg and
     * continue of the turn; null keeps the plan byte-identical to a typed send.
     */
    val delivery: ContextDelivery? = null,
) {
    companion object {
        /**
         * Local memory items injected into this conversation; nothing when the conversation switch is off.
         * Goes through [MemoryItems.injectable] (active semantic, unexpired, in scope): standing instructions
         * first, then memory facts, each pinned first. Scope is already resolved here, so none is passed on.
         */
        fun memoryItems(
            useMemory: Boolean,
            items: List<MemoryItem>,
            conversationId: String,
            folderId: String?,
            now: java.time.Instant,
        ): List<ContextMemoryItem> {
            if (!useMemory || items.isEmpty()) return emptyList()
            val injection = MemoryItems.injectable(items, conversationId, folderId, now)
            return (injection.standingInstructions + injection.memory).map { item ->
                ContextMemoryItem(
                    id = item.id,
                    kind = item.kind.wire,
                    content = item.content,
                    pinned = item.pinned,
                    layer = item.layer.wire,
                    status = item.status.wire,
                )
            }
        }
    }
}
