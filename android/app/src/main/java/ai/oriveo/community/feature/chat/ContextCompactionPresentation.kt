package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextCompactNumber
import ai.oriveo.community.core.data.repository.ContextCheckpointKind
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole

/**
 * Separator row shown after [anchorMessageId] (contract P3·U4 rule 1).
 * Summary rows carry [before] / [after] token estimates; both kinds carry [kept].
 */
data class ContextCompactionSeparator(
    val kind: ContextCheckpointKind,
    /** Summary: messages covered. Fallback: assistant replies among the covered messages. */
    val count: Int,
    val before: Int?,
    val after: Int?,
    /** Number of user messages kept verbatim (userMessageIds), on both kinds. */
    val kept: Int?,
    val model: String,
    val anchorMessageId: String,
)

/** Cost line state of the detail sheet (contract P3·U4 rule 2). */
sealed interface ContextCompactionCost {
    /** Fallback rows never call a model. */
    data object NoExtraCost : ContextCompactionCost

    /** Summary row without a recorded cost. */
    data object Unavailable : ContextCompactionCost

    data class Amount(val value: Double) : ContextCompactionCost
}

/** Read-only detail sheet model (contract P3·U4 rule 2). */
data class ContextCompactionDetail(
    /** Shown only when non-blank. */
    val summary: String?,
    val kept: Int,
    val model: String,
    val cost: ContextCompactionCost,
    /** Epoch milliseconds. */
    val createdAt: Long,
)

object ContextCompactionPresentation {

    /**
     * Builds the separator for the latestValid row [record]; null when there is no row or its coversTo is not
     * among the loaded [messages]. Token counts are estimated at display time with [rhoHi] (same source as send).
     * [modelName] maps the row's model id to its catalog display name; a missing or blank name shows the id.
     */
    fun separator(
        record: ContextCheckpointRecord?,
        messages: List<ChatMessage>,
        rhoHi: Double,
        modelName: (String) -> String? = { null },
    ): ContextCompactionSeparator? {
        if (record == null) return null
        val model = modelName(record.model)?.takeIf { it.isNotBlank() } ?: record.model
        val anchorIndex = messages.indexOfFirst { it.id == record.coversTo }
        if (anchorIndex < 0) return null
        val covered = messages.subList(0, anchorIndex + 1).takeLast(record.messagesCovered.coerceAtLeast(0))
        return when (record.kind) {
            ContextCheckpointKind.SUMMARY -> ContextCompactionSeparator(
                kind = record.kind,
                count = record.messagesCovered,
                before = covered.sumOf { ContextBudget.estimateMessage(it.text, rhoHi) },
                after = ContextBudget.estimateMessage(record.text, rhoHi),
                kept = record.userMessageIds.size,
                model = model,
                anchorMessageId = record.coversTo,
            )
            ContextCheckpointKind.FALLBACK -> ContextCompactionSeparator(
                kind = record.kind,
                count = covered.count { it.role == ChatRole.Assistant },
                before = null,
                after = null,
                kept = record.userMessageIds.size,
                model = record.model,
                anchorMessageId = record.coversTo,
            )
        }
    }

    fun detail(record: ContextCheckpointRecord): ContextCompactionDetail = ContextCompactionDetail(
        summary = record.summary?.takeIf { it.isNotBlank() },
        kept = record.userMessageIds.size,
        model = record.model,
        cost = when {
            record.kind == ContextCheckpointKind.FALLBACK -> ContextCompactionCost.NoExtraCost
            record.cost == null -> ContextCompactionCost.Unavailable
            else -> ContextCompactionCost.Amount(record.cost)
        },
        createdAt = record.createdAt,
    )

    /** Compact token count in the app language [locale] (shared table, rounds down); null for missing or 0. */
    fun compactTokenCount(tokens: Int?, locale: String): String? {
        val value = tokens?.takeIf { it > 0 } ?: return null
        return ContextCompactNumber.format(value.toLong(), locale)
    }

    /** Transcript separator token text: a measured 0 shows "0"; null only when not measured (caller shows "not available"). */
    fun separatorTokenText(tokens: Int?, locale: String): String? {
        val value = tokens?.takeIf { it >= 0 } ?: return null
        return ContextCompactNumber.format(value.toLong(), locale)
    }
}
