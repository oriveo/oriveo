@file:Suppress("PropertyName")

package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.ChatRole

enum class SummaryAttachmentKind(val wire: String) {
    IMAGE("image"),
    FILE("file");

    companion object {
        fun fromWire(wire: String): SummaryAttachmentKind =
            entries.firstOrNull { it.wire == wire } ?: throw IllegalArgumentException("unknown attachment kind $wire")
    }
}

data class SummaryAttachment(
    val kind: SummaryAttachmentKind,
    val name: String,
)

/** A span message handed to the summary request. */
data class SummarySpanMessage(
    val id: String,
    val role: ChatRole,
    val text: String,
    val attachments: List<SummaryAttachment> = emptyList(),
)

/** Rule 8 input; `U` is the usable input window, `prefixTokens` the session system + tools estimate. */
data class SummaryRequestInput(
    val U: Int,
    val prefixTokens: Int,
    val rhoHi: Double,
    val language: String?,
    val summaryMax: Int,
    val previousCheckpointText: String?,
    val previousSummary: String?,
    val span: List<SummarySpanMessage>,
)

enum class SummaryRequestShape(val wire: String) {
    APPENDED("appended"),
    SERIALIZED("serialized"),
    TOO_LARGE("tooLarge"),
}

data class SummaryRequestMessage(
    val role: ChatRole,
    val text: String,
)

/**
 * Rule 8 result. `system == null` on appended means keep the session system and tools.
 * appended / serialized leave `appendedTokens` / `serializedTokens` null; tooLarge carries only
 * those two, with null system / toolChoice / maxOutputTokens / estInputTokens and no messages.
 */
data class SummaryRequest(
    val shape: SummaryRequestShape,
    val system: String? = null,
    val toolChoice: String? = null,
    val maxOutputTokens: Int? = null,
    val messages: List<SummaryRequestMessage> = emptyList(),
    val estInputTokens: Int? = null,
    val appendedTokens: Int? = null,
    val serializedTokens: Int? = null,
)

/** History message for compaction; `estTokens` is the per-message estimate (text + overhead). */
data class CompactMessage(
    val id: String,
    val role: ChatRole,
    val text: String,
    val estTokens: Int,
    val isDirective: Boolean = false,
)

data class CompactPrevious(
    val coversTo: String,
    val summary: String?,
)

/** Rule 9 input; a null entry in `summaryOutputs` means the summary call failed. */
data class CompactInput(
    val conversationId: String,
    val B: Int,
    val rhoHi: Double,
    val messages: List<CompactMessage>,
    val previous: CompactPrevious?,
    val summaryOutputs: List<String?>,
)

enum class CompactOutcome(val wire: String) {
    SUMMARY("summary"),
    FALLBACK("fallback"),
    NOOP("noop"),
}

/**
 * Rule 9 result; noop carries only `outcome`, fallback adds attempts / failures / spanTokens,
 * and the checkpoint fields are only set on outcome summary.
 */
data class CompactResult(
    val outcome: CompactOutcome,
    val attempts: Int? = null,
    val failures: List<List<String>>? = null,
    val spanTokens: Int? = null,
    val coversFrom: String? = null,
    val coversTo: String? = null,
    val messagesCovered: Int? = null,
    val keptUserIds: List<String>? = null,
    val checkpointId: String? = null,
    val coversDigest: String? = null,
    val text: String? = null,
)

/** LLM checkpoint pieces shared with iOS / Web through `checkpoint.v1.json` (rules 7–9). */
object ContextCompactor {
    const val SUMMARY_PROMPT_TEMPLATE: String =
        "You are writing a CONTEXT CHECKPOINT so this conversation can continue after older messages are removed.\n" +
            "The user's own messages are preserved separately; do not restate them, and do not restate any <oriveo-*> blocks.\n" +
            "Write in {language}. Use EXACTLY these level-2 headings in this order; write \"(none)\" if empty:\n" +
            "## Goal                 — what the user is trying to achieve in this conversation\n" +
            "## Key Facts & Decisions\n" +
            "## Work Produced        — artifacts created so far (e.g. chapters, code, plans): title + 1-line gist each\n" +
            "## Open Threads         — unanswered questions, pending tasks, what the user asked for next\n" +
            "## Style & Language     — language, tone, format conventions in use\n" +
            "Do not invent facts. Do not address the user. Max {S_max} tokens."
    const val LANGUAGE_FALLBACK: String =
        "the language the assistant's answers in this conversation are written in"
    const val SERIALIZED_SYSTEM: String =
        "You write context checkpoints that let a conversation continue after older messages are removed. " +
            "Follow the format given in the user's message exactly."
    const val ATTACHMENT_PLACEHOLDER: String = "[{kind}: {name}]"
    const val MAX_SUMMARY_ATTEMPTS: Int = 2
    const val TOOL_CHOICE_NONE: String = "none"
    const val REASON_CALL_ERROR: String = "callError"

    /**
     * Rule 7: `language` is resolved by the caller; null or White_Space-only uses [LANGUAGE_FALLBACK].
     * `{S_max}` is substituted first so a language name is inserted literally.
     */
    fun summaryPrompt(language: String?, summaryMax: Int): String =
        SUMMARY_PROMPT_TEMPLATE
            .replace("{S_max}", summaryMax.toString())
            .replace("{language}", language.presentOrNull() ?: LANGUAGE_FALLBACK)

    /** Rule 8: appended when it fits U, else serialized when that fits, else tooLarge. */
    fun summaryRequest(input: SummaryRequestInput): SummaryRequest {
        val prompt = summaryPrompt(input.language, input.summaryMax)
        val bodies = input.span.map(::messageBody)
        val previousCheckpointText = input.previousCheckpointText.presentOrNull()
        val previousSummary = input.previousSummary.presentOrNull()

        val appended = input.span.mapIndexed { i, m ->
            val text = if (i == 0 && previousCheckpointText != null) {
                previousCheckpointText + "\n\n" + bodies[i]
            } else {
                bodies[i]
            }
            SummaryRequestMessage(m.role, text)
        }.toMutableList()
        val last = appended.lastOrNull()
        if (last != null && last.role == ChatRole.User) {
            appended[appended.lastIndex] = last.copy(text = last.text + "\n\n" + prompt)
        } else {
            appended += SummaryRequestMessage(ChatRole.User, prompt)
        }
        val appendedInput = input.prefixTokens +
            appended.sumOf { ContextBudget.estimateMessage(it.text, input.rhoHi) }
        val appendedTokens = appendedInput + input.summaryMax
        if (appendedTokens <= input.U) {
            return SummaryRequest(
                shape = SummaryRequestShape.APPENDED,
                system = null,
                toolChoice = TOOL_CHOICE_NONE,
                maxOutputTokens = input.summaryMax,
                messages = appended,
                estInputTokens = appendedInput,
            )
        }

        val lines = mutableListOf("<transcript>")
        previousSummary?.let {
            lines += "<previous-summary>\n${ContextSanitizer.escapeXml(it)}\n</previous-summary>"
        }
        input.span.forEachIndexed { i, m ->
            lines += "<message id=\"${m.id}\" role=\"${m.role.rawValue}\">${ContextSanitizer.escapeXml(bodies[i])}</message>"
        }
        lines += "</transcript>"
        val user = lines.joinToString("\n") + "\n\n" + prompt
        val serializedInput = ContextBudget.estimateMessage(SERIALIZED_SYSTEM, input.rhoHi) +
            ContextBudget.estimateMessage(user, input.rhoHi)
        val serializedTokens = serializedInput + input.summaryMax
        if (serializedTokens <= input.U) {
            return SummaryRequest(
                shape = SummaryRequestShape.SERIALIZED,
                system = SERIALIZED_SYSTEM,
                toolChoice = TOOL_CHOICE_NONE,
                maxOutputTokens = input.summaryMax,
                messages = listOf(SummaryRequestMessage(ChatRole.User, user)),
                estInputTokens = serializedInput,
            )
        }
        return SummaryRequest(
            shape = SummaryRequestShape.TOO_LARGE,
            appendedTokens = appendedTokens,
            serializedTokens = serializedTokens,
        )
    }

    /**
     * Rule 9: select the span, keep user messages before the tail, try up to [MAX_SUMMARY_ATTEMPTS]
     * outputs; the first valid one becomes the checkpoint, otherwise the caller runs the fallback.
     */
    fun compact(input: CompactInput): CompactResult {
        val spanSelection = ContextCheckpoint.selectSpan(
            input.messages.map { CheckpointSpanMessage(it.id, it.role, it.estTokens) },
            input.B,
            input.previous?.coversTo,
        )
        if (spanSelection.action == CheckpointAction.NOOP) return CompactResult(CompactOutcome.NOOP)

        val tailStart = spanSelection.tailStartId
            ?.let { id -> input.messages.indexOfFirst { it.id == id } }
            ?: input.messages.size
        val covered = input.messages.subList(0, tailStart)
        val spanIds = spanSelection.spanIds.toSet()
        val spanTokens = input.messages.filter { it.id in spanIds }.sumOf { it.estTokens } +
            (input.previous?.summary.presentOrNull()?.let { ContextBudget.estimateText(it, input.rhoHi) } ?: 0)
        val summaryMax = ContextBudget.derived(input.B.toLong()).summaryMax

        val failures = mutableListOf<List<String>>()
        var attempts = 0
        for (output in input.summaryOutputs.take(MAX_SUMMARY_ATTEMPTS)) {
            attempts++
            if (output == null) {
                failures += listOf(REASON_CALL_ERROR)
                continue
            }
            val summary = ContextCheckpoint.normalizeHeadings(output)
            val validation = ContextCheckpoint.validateSummary(summary, summaryMax, spanTokens, input.rhoHi)
            if (!validation.valid) {
                failures += validation.reasons
                continue
            }
            val kept = ContextCheckpoint.pickUserMessages(
                covered.filter { it.role == ChatRole.User }
                    .map { CheckpointCandidate(it.id, it.text, it.isDirective) },
                input.B,
                input.rhoHi,
            )
            val coversFrom = spanSelection.coversFrom!!
            val coversTo = spanSelection.coversTo!!
            return CompactResult(
                outcome = CompactOutcome.SUMMARY,
                attempts = attempts,
                failures = failures,
                spanTokens = spanTokens,
                coversFrom = coversFrom,
                coversTo = coversTo,
                messagesCovered = spanSelection.messagesCovered,
                keptUserIds = kept.map { it.id },
                checkpointId = ContextCheckpoint.checkpointId(input.conversationId, coversTo),
                coversDigest = ContextCheckpoint.coversDigest(covered.map { CheckpointCoveredMessage(it.id, it.text) }),
                text = ContextCheckpoint.serialize(coversFrom, coversTo, spanSelection.messagesCovered, kept, summary),
            )
        }
        return CompactResult(
            outcome = CompactOutcome.FALLBACK,
            attempts = attempts,
            failures = failures,
            spanTokens = spanTokens,
        )
    }

    /** Null or White_Space-only counts as absent. */
    private fun String?.presentOrNull(): String? = this?.takeIf { it.trimWhiteSpace().isNotEmpty() }

    /** Message text followed by one placeholder line per attachment; empty parts dropped. */
    private fun messageBody(message: SummarySpanMessage): String =
        (listOf(message.text) + message.attachments.map(::placeholder))
            .filter { it.isNotEmpty() }
            .joinToString("\n")

    private fun placeholder(attachment: SummaryAttachment): String =
        ATTACHMENT_PLACEHOLDER
            .replace("{kind}", attachment.kind.wire)
            .replace("{name}", attachment.name)
}

enum class ContextCompactionEvent(val wire: String) {
    LLM_FAILURE("llmFailure"),
    LLM_SUCCESS("llmSuccess"),
    TURN("turn"),
    RETRY("retry");

    companion object {
        fun fromWire(wire: String): ContextCompactionEvent =
            entries.firstOrNull { it.wire == wire } ?: throw IllegalArgumentException("unknown breaker event $wire")
    }
}

enum class ContextCompactionMode(val wire: String) {
    LLM("llm"),
    FALLBACK_ONLY("fallbackOnly"),
}

/**
 * Rule 10 circuit breaker (value type). Manual compaction ignores [mode] but still reports
 * llmFailure / llmSuccess.
 */
data class ContextCompactionBreaker(
    val failures: Int = 0,
    val turnsLeft: Int = 0,
) {
    val mode: ContextCompactionMode
        get() = if (turnsLeft > 0) ContextCompactionMode.FALLBACK_ONLY else ContextCompactionMode.LLM

    fun apply(event: ContextCompactionEvent): ContextCompactionBreaker = when (event) {
        ContextCompactionEvent.LLM_FAILURE ->
            if (failures + 1 >= FAILURES_TO_TRIP) copy(failures = 0, turnsLeft = FALLBACK_TURNS) else copy(failures = failures + 1)
        ContextCompactionEvent.LLM_SUCCESS -> copy(failures = 0)
        ContextCompactionEvent.TURN -> copy(turnsLeft = maxOf(0, turnsLeft - 1))
        ContextCompactionEvent.RETRY -> ContextCompactionBreaker()
    }

    companion object {
        const val FAILURES_TO_TRIP: Int = 2
        const val FALLBACK_TURNS: Int = 10
    }
}
