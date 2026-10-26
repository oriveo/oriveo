package ai.oriveo.community.core.context

import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole

/**
 * One history message offered to a realtime session plan. [attachmentKinds] are wire kinds in attachment order
 * (image / file / video / audio; anything else reads as file). [realtimeSessionId] names the realtime session that
 * persisted the message, null for ordinary chat messages.
 */
data class RealtimeSessionMessage(
    val id: String,
    val role: ChatRole,
    val text: String,
    val attachmentKinds: List<String> = emptyList(),
    val realtimeSessionId: String? = null,
)

/**
 * Realtime session opening input: the assemble input shape (no purpose / window / dynamic) plus the realtime
 * [contextWindow] and the [currentSessionId] of the session that is open (null when planning a new one).
 * [history] must already be sanitize-identity (delivered, user first, alternating).
 */
data class RealtimeSessionInput(
    val contextWindow: Int?,
    val rhoHi: Double = ContextBudget.RHO0,
    val conversation: ContextConversation,
    val memoryItems: List<ContextMemoryItem> = emptyList(),
    val history: List<RealtimeSessionMessage>,
    val checkpoint: String? = null,
    val currentSessionId: String? = null,
)

enum class RealtimeSessionReject(val wire: String) {
    INSTRUCTIONS_TOO_LONG("instructions_too_long"),
    UNKNOWN_WINDOW("unknown_window"),
}

data class RealtimeHistoryItem(val role: ChatRole, val text: String)

/** A turn boundary whose fingerprint differs in either field closes the session and opens a new one. */
data class RealtimeSessionFingerprint(val instructionsSha256: String, val lastHistoryId: String?)

data class RealtimeSessionOmitted(
    val knowledge: Int = 0,
    val notes: Int = 0,
    val memory: Int = 0,
    val history: Int = 0,
)

data class RealtimeSessionBudget(
    val B: Int,
    val limit: Int,
    val systemMax: Int,
    val estimatedInstructions: Int,
    val estimatedInjected: Int,
)

/**
 * Realtime session opening plan. On reject [instructions], [history], [historyIds], [fingerprint] and [budget] are null.
 * [historyIds] is null for a checkpoint that stands as its own first item. Only [assembleRealtimeSession] builds it.
 */
class RealtimeSessionPlan private constructor(
    val reject: RealtimeSessionReject?,
    val instructions: String?,
    val history: List<RealtimeHistoryItem>?,
    val historyIds: List<String?>?,
    val fingerprint: RealtimeSessionFingerprint?,
    val segments: List<ContextSegmentKind>,
    val omitted: RealtimeSessionOmitted,
    val memoryIds: List<String>,
    val reminder: Boolean,
    val budget: RealtimeSessionBudget?,
) {
    companion object {
        @Suppress("LongParameterList")
        internal fun make(
            instructions: String,
            history: List<RealtimeHistoryItem>,
            historyIds: List<String?>,
            fingerprint: RealtimeSessionFingerprint,
            segments: List<ContextSegmentKind>,
            omitted: RealtimeSessionOmitted,
            memoryIds: List<String>,
            reminder: Boolean,
            budget: RealtimeSessionBudget,
        ): RealtimeSessionPlan = RealtimeSessionPlan(
            reject = null,
            instructions = instructions,
            history = history,
            historyIds = historyIds,
            fingerprint = fingerprint,
            segments = segments,
            omitted = omitted,
            memoryIds = memoryIds,
            reminder = reminder,
            budget = budget,
        )

        internal fun rejected(reject: RealtimeSessionReject): RealtimeSessionPlan = RealtimeSessionPlan(
            reject = reject,
            instructions = null,
            history = null,
            historyIds = null,
            fingerprint = null,
            segments = emptyList(),
            omitted = RealtimeSessionOmitted(),
            memoryIds = emptyList(),
            reminder = false,
            budget = null,
        )
    }
}

/** Realtime-only constants (identical on every client). */
object RealtimeSessionConstants {
    /** Delivery envelope body of a realtime session; always the last part of the instructions. */
    const val DELIVERY_REALTIME: String =
        "The user is talking with you by voice in real time and hears your spoken replies. Speak naturally in short sentences, usually under 80 words unless the user asks for detail. Do not read out Markdown, code, tables, lists, or emoji; say symbols and units in words. Reply in the language the user is speaking unless the conversation instructions say otherwise."
    const val SYSTEM_MAX_CAP: Int = 32000

    /** One line per attachment, keyed by wire kind; unknown kinds use the file line. */
    val ATTACHMENT_PLACEHOLDERS: Map<String, String> = mapOf(
        "image" to "[Image omitted: this route sends text only]",
        "file" to "[File omitted: this route sends text only]",
        "video" to "[Video omitted: this route sends text only]",
        "audio" to "[Audio omitted: this route sends text only]",
    )

    fun placeholder(kind: String): String = ATTACHMENT_PLACEHOLDERS[kind] ?: ATTACHMENT_PLACEHOLDERS.getValue("file")
}

/** Message text, then one placeholder line per attachment, joined by \n. */
internal fun projectRealtimeText(message: RealtimeSessionMessage): String =
    (listOfNotNull(message.text.takeIf { it.isNotEmpty() }) + message.attachmentKinds.map(RealtimeSessionConstants::placeholder))
        .joinToString("\n")

/** Kept history with the checkpoint applied; [checkpointAlone] marks a checkpoint that is its own first item. */
private class RealtimeKept(val messages: List<ContextMessage>, val checkpointAlone: Boolean) {
    fun ids(): List<String?> = messages.mapIndexed { i, m -> if (checkpointAlone && i == 0) null else m.id }
}

@Suppress("LongMethod", "ReturnCount")
fun assembleRealtimeSession(input: RealtimeSessionInput): RealtimeSessionPlan {
    val b = input.contextWindow?.takeIf { it >= 1 } ?: return rejected(RealtimeSessionReject.UNKNOWN_WINDOW)
    val rhoHi = input.rhoHi
    val limit = b / 2
    val systemMax = minOf(b / 4, RealtimeSessionConstants.SYSTEM_MAX_CAP)
    // Long arithmetic: 3 * B overflows Int for windows above ~715M tokens
    val reminderAt = (b.toLong() * 3) / 10

    // ---- system: assemble layout 0-4 and 11, never toolSafety ----
    val conversation = input.conversation
    val instructionsBody = conversation.instructions?.trimWhiteSpace()?.takeIf { it.isNotEmpty() }
    val memory = if (conversation.useMemory) {
        input.memoryItems.filter { ContextPlan.eligible(it, conversation.id) }
    } else {
        emptyList()
    }
    // Blank memory bodies render nothing but stay in the shrink pool, so dropping one counts as an omission.
    fun hasBody(item: ContextMemoryItem) = item.content.trimWhiteSpace().isNotEmpty()
    val (standingItems, factItems) = memory.partition { it.kind in ContextPlan.STANDING_KINDS }
    val factPool = ContextPlan.pinnedFirst(factItems).toMutableList()
    fun renderedFacts() = factPool.filter(::hasBody).map { Triple(ContextPlan.entry(it.content), it.pinned, it.id) }
    // Blank notes / knowledge files likewise stay in their shrink pools: rendering skips them, dropping one counts.
    val notePool = conversation.pinnedNotes.toMutableList()
    val knowledgePool = conversation.knowledgeFiles.toMutableList()
    fun renderedNotes() = notePool.filter { it.text.trimWhiteSpace().isNotEmpty() }
        .map { ContextPlan.entry(it.text, "title" to it.title) }
    fun renderedKnowledge() = knowledgePool.filter { it.text.trimWhiteSpace().isNotEmpty() }
        .map { ContextPlan.entry(it.text, "name" to it.name) }
    val parts = ContextPlan.Companion.SystemParts(
        skill = conversation.skillPrompt?.trimWhiteSpace()?.takeIf { it.isNotEmpty() },
        instructions = instructionsBody?.let { ContextAssembler.INSTRUCTIONS_HEADER + "\n" + it },
        standing = ContextPlan.pinnedFirst(standingItems.filter(::hasBody)).map { ContextPlan.entry(it.content) to it.id },
        facts = renderedFacts().toMutableList(),
        notes = renderedNotes().toMutableList(),
        knowledge = renderedKnowledge().toMutableList(),
        toolSafety = null,
    )
    var omittedKnowledge = 0
    var omittedNotes = 0
    var omittedMemory = 0
    while (estimateOptional(parts.system(), rhoHi) > systemMax) {
        val lastUnpinned = factPool.indexOfLast { !it.pinned }
        when {
            knowledgePool.isNotEmpty() -> {
                knowledgePool.removeAt(knowledgePool.lastIndex)
                parts.knowledge.clear()
                parts.knowledge += renderedKnowledge()
                omittedKnowledge++
            }
            notePool.isNotEmpty() -> {
                notePool.removeAt(notePool.lastIndex)
                parts.notes.clear()
                parts.notes += renderedNotes()
                omittedNotes++
            }
            lastUnpinned >= 0 -> {
                factPool.removeAt(lastUnpinned)
                parts.facts.clear()
                parts.facts += renderedFacts()
                omittedMemory++
            }
            else -> break
        }
    }
    val system = parts.system()

    // ---- history projection: the open session's own transcripts stay out ----
    val history = input.history.filter { input.currentSessionId == null || it.realtimeSessionId != input.currentSessionId }
    val items = history
        .map { ContextMessage(it.id, it.role, projectRealtimeText(it), ChatMessageState.Delivered) }
        .filter { it.text.isNotEmpty() }
        .dropWhile { it.role != ChatRole.User }
    val checkpoint = input.checkpoint?.takeIf { it.isNotEmpty() }
    fun withCheckpoint(kept: List<ContextMessage>): RealtimeKept = when {
        checkpoint == null -> RealtimeKept(kept, checkpointAlone = false)
        kept.none { it.role == ChatRole.User } ->
            RealtimeKept(listOf(ContextMessage("", ChatRole.User, checkpoint, ChatMessageState.Delivered)) + kept, checkpointAlone = true)
        else -> RealtimeKept(ContextPlan.prefixCheckpoint(kept, checkpoint), checkpointAlone = false)
    }

    // ---- [D]: reminder (chat rule, counted before projection), then the delivery envelope ----
    val userCount = history.count { it.role == ChatRole.User }
    val beforeDynamic = estimateOptional(system, rhoHi) + ContextPlan.estimateMessages(withCheckpoint(items).messages, rhoHi)
    val reminder = conversation.reminderEnabled && instructionsBody != null &&
        (userCount >= ContextAssembler.REMINDER_MIN_USER_MESSAGES || beforeDynamic >= reminderAt)
    val dynamicParts = mutableListOf<String>()
    if (reminder && instructionsBody != null) {
        val body = if (ContextBudget.estimateText(instructionsBody, rhoHi) <= ContextAssembler.REMINDER_FULL_TEXT_MAX_TOKENS) {
            ContextSanitizer.escapeXml(instructionsBody)
        } else {
            ContextAssembler.REMINDER_POINTER
        }
        val tag = ContextAssembler.TAG_REMINDER
        dynamicParts += "<$tag>\n<note>${ContextAssembler.ENVELOPE_NOTES.getValue(tag)}</note>\n$body\n</$tag>"
    }
    dynamicParts += "<${ContextAssembler.TAG_DELIVERY}>\n${RealtimeSessionConstants.DELIVERY_REALTIME}\n</${ContextAssembler.TAG_DELIVERY}>"
    val dynamicText = dynamicParts.joinToString("\n\n")
    val instructions = if (system != null) "$system\n\n$dynamicText" else dynamicText

    // ---- budget: instructions (+ checkpoint) must fit; then drop the oldest whole messages ----
    val estimatedInstructions = ContextBudget.estimateMessage(instructions, rhoHi)
    if (estimatedInstructions + ContextPlan.estimateMessages(withCheckpoint(emptyList()).messages, rhoHi) > limit) {
        return rejected(RealtimeSessionReject.INSTRUCTIONS_TOO_LONG)
    }
    var start = 0
    var kept = withCheckpoint(items)
    while (estimatedInstructions + ContextPlan.estimateMessages(kept.messages, rhoHi) > limit && start < items.size) {
        start++
        while (start < items.size && items[start].role != ChatRole.User) start++
        kept = withCheckpoint(items.subList(start, items.size))
    }
    val ids = kept.ids()
    return RealtimeSessionPlan.make(
        instructions = instructions,
        history = kept.messages.map { RealtimeHistoryItem(it.role, it.text) },
        historyIds = ids,
        fingerprint = RealtimeSessionFingerprint(mcpSha256Hex(instructions), ids.lastOrNull()),
        segments = parts.segments().map { it.first },
        omitted = RealtimeSessionOmitted(omittedKnowledge, omittedNotes, omittedMemory, items.size - (kept.messages.size - if (kept.checkpointAlone) 1 else 0)),
        memoryIds = parts.memoryIds(),
        reminder = reminder,
        budget = RealtimeSessionBudget(
            B = b,
            limit = limit,
            systemMax = systemMax,
            estimatedInstructions = estimatedInstructions,
            estimatedInjected = estimatedInstructions + ContextPlan.estimateMessages(kept.messages, rhoHi),
        ),
    )
}

/** Whether a turn boundary reopens the session: either fingerprint field changed. */
fun shouldReopen(prev: RealtimeSessionFingerprint, next: RealtimeSessionFingerprint): Boolean = prev != next

/** est message(text), 0 for an absent text. */
private fun estimateOptional(text: String?, rhoHi: Double): Int =
    if (text == null) 0 else ContextBudget.estimateMessage(text, rhoHi)

private fun rejected(reject: RealtimeSessionReject): RealtimeSessionPlan = RealtimeSessionPlan.rejected(reject)
