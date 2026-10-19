@file:Suppress("PropertyName")

package ai.oriveo.community.core.context

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Closed set of request purposes; the assembler and the manifest share it. */
@Serializable
enum class RequestPurpose(val wire: String) {
    @SerialName("chat") CHAT("chat"),
    @SerialName("continue") CONTINUE("continue"),
    @SerialName("toolLoopLeg") TOOL_LOOP_LEG("toolLoopLeg"),
    @SerialName("imageGeneration") IMAGE_GENERATION("imageGeneration"),
    @SerialName("crosscheck") CROSSCHECK("crosscheck"),
    @SerialName("compaction") COMPACTION("compaction"),
    @SerialName("memoryExtraction") MEMORY_EXTRACTION("memoryExtraction"),
}

/** Closed set of system-prompt segment kinds. */
@Serializable
enum class ContextSegmentKind(val wire: String) {
    @SerialName("skill") SKILL("skill"),
    @SerialName("instructions") INSTRUCTIONS("instructions"),
    @SerialName("standingInstructions") STANDING_INSTRUCTIONS("standingInstructions"),
    @SerialName("memory") MEMORY("memory"),
    @SerialName("notes") NOTES("notes"),
    @SerialName("knowledge") KNOWLEDGE("knowledge"),
    @SerialName("toolSafety") TOOL_SAFETY("toolSafety"),
    @SerialName("purposeSystem") PURPOSE_SYSTEM("purposeSystem"),
}

@Serializable
data class ContextManifestSegment(
    val kind: ContextSegmentKind,
    val tokens: Int,
    val items: Int? = null,
    val omitted: Int? = null,
)

/** What was sent for one request: window, basis, per-segment token counts. */
@Serializable
data class ContextManifest(
    val requestId: String,
    val conversationId: String,
    val purpose: RequestPurpose,
    val transport: String,
    val model: String,
    val W: Int?,
    val O: Int,
    val B: Int?,
    val basis: ContextBasis,
    val estimatedInput: Int,
    val observedInput: Int? = null,
    val segments: List<ContextManifestSegment>,
    val checkpointId: String? = null,
    val tailFrom: String? = null,
    val unansweredMerged: Int,
    val reminder: Boolean,
    val stopReason: StopReason? = null,
    val createdAt: Long,
)

/** Manifests per conversation, oldest first, keeping only the latest MAX_PER_CONVERSATION. */
@Serializable
data class ContextManifestLog(
    val byConversation: Map<String, List<ContextManifest>> = emptyMap(),
) {
    fun manifests(conversationId: String): List<ContextManifest> = byConversation[conversationId].orEmpty()

    /** Newest manifest of the conversation, or null when none was logged. */
    fun latest(conversationId: String): ContextManifest? = manifests(conversationId).lastOrNull()

    fun appending(manifest: ContextManifest): ContextManifestLog {
        val list = (manifests(manifest.conversationId) + manifest).takeLast(MAX_PER_CONVERSATION)
        return copy(byConversation = byConversation + (manifest.conversationId to list))
    }

    companion object {
        const val MAX_PER_CONVERSATION: Int = 50
    }
}
