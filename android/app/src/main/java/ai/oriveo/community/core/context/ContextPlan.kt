@file:Suppress("PropertyName")

package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatRole

/** `text` carries the message itself; `dynamic` is the per-turn [D] block on the last message. */
enum class ContextBlockKind(val wire: String) {
    TEXT("text"),
    DYNAMIC("dynamic"),
}

data class ContextPlanBlock(val kind: ContextBlockKind, val text: String)

/** One outbound message; attachments are the sanitized ones. */
data class ContextPlanMessage(
    val id: String,
    val role: ChatRole,
    val blocks: List<ContextPlanBlock>,
    val attachments: List<Attachment>,
)

/** System segment: estimated text tokens, entry count for enveloped segments, dropped entries when > 0. */
data class ContextPlanSegment(
    val kind: ContextSegmentKind,
    val tokens: Int,
    val items: Int? = null,
    val omitted: Int? = null,
)

/** Entries dropped by the system shrink. */
data class ContextOmitted(
    val knowledge: Int = 0,
    val notes: Int = 0,
    val memory: Int = 0,
)

data class ContextPlanBudget(
    val W: Int?,
    val B: Int?,
    val oWire: Int,
    val estimatedInput: Int?,
)

enum class ContextCompactionAdvice(val wire: String) {
    NONE("none"),
    PRE_SUGGESTED("preSuggested"),
    REQUIRED("required"),
}

enum class ContextPlanWarning(val wire: String) {
    INSTRUCTIONS_AND_SKILL_OVER_SHARE("instructionsAndSkillOverShare"),
}

enum class ContextReject(val wire: String) {
    INSTRUCTIONS_TOO_LONG("instructions_too_long"),
    MESSAGE_TOO_LONG("message_too_long"),
}

data class ContextPinnedNote(val title: String, val text: String)

data class ContextKnowledgeFile(val name: String, val text: String)

/** Conversation-level inputs: skill prompt, conversation instructions, pinned notes, skill knowledge. */
data class ContextConversation(
    val id: String,
    val useMemory: Boolean,
    val skillPrompt: String? = null,
    val instructions: String? = null,
    val pinnedNotes: List<ContextPinnedNote> = emptyList(),
    val knowledgeFiles: List<ContextKnowledgeFile> = emptyList(),
    /** Remote flag context_reminder_enabled; false only drops the reminder, instructions stay in the system. */
    val reminderEnabled: Boolean = true,
)

/** `type` is global or conversation; `id` names the conversation for conversation scope. */
data class ContextMemoryScope(val type: String, val id: String? = null)

/** Memory item; null layer / status / scope read as semantic / active / global. */
data class ContextMemoryItem(
    val id: String,
    val kind: String,
    val content: String,
    val pinned: Boolean = false,
    val layer: String? = null,
    val status: String? = null,
    val scope: ContextMemoryScope? = null,
)

/** One library excerpt; `citation` / `title` become entry attributes, `truncated` marks a partial document. */
data class ContextLibraryEntry(
    val citation: Int? = null,
    val title: String? = null,
    val truncated: Boolean = false,
    val text: String,
)

/** One ranked L3 recall hit for [D]; `date` (YYYY-MM-DD) becomes the entry attribute, `id` is never rendered. */
data class ContextRecallEntry(val id: String, val text: String, val date: String? = null)

/**
 * Per-turn host texts that go into the [D] block (chat and tool-loop legs).
 * `library` null means no library lookup; an empty list means the lookup found nothing.
 */
data class ContextDynamicInput(
    /** Ranked L3 hits; kept in rank order while the envelope fits recallMax. */
    val recall: List<ContextRecallEntry> = emptyList(),
    val library: List<ContextLibraryEntry>? = null,
    val attachmentGuide: String? = null,
    /** null renders exactly as before; VOICE appends <oriveo-delivery> last in [D]. */
    val delivery: ContextDelivery? = null,
)

/** Reply-style envelope at the end of [D]; only voice for now. */
enum class ContextDelivery { VOICE }

data class ContextAssembleInput(
    val purpose: RequestPurpose,
    val window: ContextWindowInput,
    val rhoHi: Double = ContextBudget.RHO0,
    val conversation: ContextConversation,
    val memoryItems: List<ContextMemoryItem> = emptyList(),
    val history: List<ContextMessage>,
    /** Latest user message text; continue replaces it with the fixed prompt. */
    val current: String? = null,
    /** Id of the current message in the plan. */
    val currentId: String = "current",
    val currentAttachments: List<Attachment> = emptyList(),
    /** Retry / continue target: kept by sanitize even when failed. */
    val keepAssistantId: String? = null,
    val dynamic: ContextDynamicInput? = null,
    val toolSafety: String? = null,
    val purposeSystem: String? = null,
    /**
     * Serialized context checkpoint; prefixed raw (no escaping) to the first user text block after sanitize.
     * Not counted by the reject check; null keeps the plan byte-identical to the no-checkpoint layout.
     */
    val checkpoint: String? = null,
)
