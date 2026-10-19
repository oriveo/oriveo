package ai.oriveo.community.feature.chat

import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextDisplayInput
import ai.oriveo.community.core.context.ContextDisplayKind
import ai.oriveo.community.core.context.ContextDisplayTone
import ai.oriveo.community.core.context.ContextManifest
import ai.oriveo.community.core.context.ContextSegmentKind
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.data.dao.ContextLedgerDao
import ai.oriveo.community.core.data.repository.ChatContextProjector
import ai.oriveo.community.core.data.repository.ContextCompactionStore
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.onStart

/** usage.v1 display: `none` hides the ring and the panel says usage appears after the first send. */
enum class ContextUsageDisplay(val wire: String) {
    PERCENT("percent"),
    UNAVAILABLE("unavailable"),
    NONE("none"),
}

enum class ContextUsageReason(val wire: String) {
    NEVER_OBSERVED("never_observed"),
    WINDOW_UNKNOWN("window_unknown"),
    COMPACTED_SINCE("compacted_since"),
    CLEARED_SINCE("cleared_since"),
}

/**
 * usage.v1 `input.currentB` with the key present: [B] is the limit recomputed now from the current cap and
 * window (null = window unknown without a custom cap). An absent value (null wrapper) keeps the manifest's B.
 */
data class ContextCurrentB(val B: Int?)

/** Latest valid checkpoint as the summary sees it; [latestSummaryTokens] is estimateMessage of its text. */
data class ContextUsageCheckpoint(
    val count: Int,
    /** Epoch milliseconds. */
    val latestCreatedAt: Long,
    val latestSummaryTokens: Int,
)

data class ContextUsageRingLabel(val label: String, val tone: ContextDisplayTone)

data class ContextUsageSegments(
    val conversation: Int,
    val library: Int,
    val summary: Int,
    val instructions: Int,
    val memory: Int,
    val free: Int,
)

data class ContextUsageOmitted(val notes: Int, val knowledge: Int, val memory: Int)

/** Composer ring / context panel model (contract P4·U4 rule 1, `usage.v1.json`). */
data class ContextUsageSummary(
    val display: ContextUsageDisplay,
    val reason: ContextUsageReason? = null,
    val percent: Int? = null,
    val estimatedPercent: Int? = null,
    val tone: ContextDisplayTone? = null,
    val ring: ContextUsageRingLabel? = null,
    val basis: ContextBasis? = null,
    val used: Int? = null,
    val B: Int? = null,
    val W: Int? = null,
    val segments: ContextUsageSegments? = null,
    val omitted: ContextUsageOmitted? = null,
    /** Not part of usage.v1; the panel reads count / summary from it. */
    val checkpoint: ContextUsageCheckpoint? = null,
) {
    companion object {
        val NONE = ContextUsageSummary(display = ContextUsageDisplay.NONE)
    }
}

/** Usage summary tagged with the conversation it was computed for. */
data class ContextUsageResult(val conversationId: String, val summary: ContextUsageSummary) {
    /** The summary when it belongs to [currentId]; null while a switched-to conversation is still computing. */
    fun forConversation(currentId: String?): ContextUsageSummary? = summary.takeIf { conversationId == currentId }
}

/** Ring accessibility text: string resource plus its format args. */
data class ContextUsageRingAccessibility(@param:StringRes val resId: Int, val args: List<Any>)

object ContextUsagePresentation {

    private const val BANG = "!"
    private val instructionKinds = setOf(
        ContextSegmentKind.SKILL,
        ContextSegmentKind.INSTRUCTIONS,
        ContextSegmentKind.STANDING_INSTRUCTIONS,
        ContextSegmentKind.PURPOSE_SYSTEM,
        ContextSegmentKind.TOOL_SAFETY,
    )
    private val libraryKinds = setOf(ContextSegmentKind.NOTES, ContextSegmentKind.KNOWLEDGE)

    /**
     * Rule 1: [manifests] oldest first, [checkpoint] the latest valid one (null when none).
     * Cleared: the latest manifest was sent on a checkpoint and no valid checkpoint is left (cleared, or its
     * messages edited away); that measurement no longer applies, so the summary is unavailable (hint: usage
     * shows after the next send) until a newer manifest arrives.
     * [currentB]: the limit recomputed from the current cap and window; when present it replaces the manifest's
     * B (its null B = window unknown); absent (not wired, conversation / connection unresolved) keeps the manifest's.
     */
    fun summary(
        manifests: List<ContextManifest>,
        checkpoint: ContextUsageCheckpoint?,
        currentB: ContextCurrentB? = null,
    ): ContextUsageSummary {
        val latest = manifests.lastOrNull() ?: return ContextUsageSummary.NONE.copy(checkpoint = checkpoint)
        val b = if (currentB != null) currentB.B else latest.B
        if (latest.checkpointId != null && checkpoint == null) {
            return ContextUsageSummary(
                display = ContextUsageDisplay.UNAVAILABLE,
                reason = ContextUsageReason.CLEARED_SINCE,
                B = b,
                W = latest.W,
                checkpoint = checkpoint,
            )
        }
        if (checkpoint != null && checkpoint.latestCreatedAt > latest.createdAt) {
            return ContextUsageSummary(
                display = ContextUsageDisplay.UNAVAILABLE,
                reason = ContextUsageReason.COMPACTED_SINCE,
                B = b,
                W = latest.W,
                checkpoint = checkpoint,
            )
        }
        val observed = latest.observedInput
        val used = observed ?: latest.estimatedInput
        val basis = if (observed != null) ContextBasis.OBSERVED else ContextBasis.ESTIMATED
        val omitted = ContextUsageOmitted(
            notes = latest.omittedOf(ContextSegmentKind.NOTES),
            knowledge = latest.omittedOf(ContextSegmentKind.KNOWLEDGE),
            memory = latest.omittedOf(ContextSegmentKind.MEMORY),
        )
        if (b == null || b <= 0) {
            return ContextUsageSummary(
                display = ContextUsageDisplay.UNAVAILABLE,
                reason = ContextUsageReason.WINDOW_UNKNOWN,
                basis = basis,
                used = used,
                B = b,
                W = latest.W,
                omitted = omitted,
                checkpoint = checkpoint,
            )
        }
        val instructions = latest.segments.filter { it.kind in instructionKinds }.sumOf { it.tokens }
        val memory = latest.segments.filter { it.kind == ContextSegmentKind.MEMORY }.sumOf { it.tokens }
        val library = latest.segments.filter { it.kind in libraryKinds }.sumOf { it.tokens }
        val summaryTokens = checkpoint?.latestSummaryTokens ?: 0
        val segments = ContextUsageSegments(
            conversation = maxOf(0, used - instructions - memory - library - summaryTokens),
            library = library,
            summary = summaryTokens,
            instructions = instructions,
            memory = memory,
            free = maxOf(0, b - used),
        )
        val display = ContextBudget.display(
            ContextDisplayInput(
                windowKnown = true,
                pHat = used,
                B = b,
                basis = basis,
                observedEver = manifests.any { it.observedInput != null },
                overflowed = latest.stopReason == StopReason.CONTEXT_WINDOW_EXCEEDED,
            ),
        )
        val base = ContextUsageSummary(
            display = ContextUsageDisplay.UNAVAILABLE,
            basis = basis,
            used = used,
            B = b,
            W = latest.W,
            segments = segments,
            omitted = omitted,
            checkpoint = checkpoint,
        )
        val percent = display.percent
        val tone = display.tone
        if (display.display != ContextDisplayKind.PERCENT || percent == null || tone == null) {
            return base.copy(reason = ContextUsageReason.NEVER_OBSERVED, estimatedPercent = display.estimatedPercent)
        }
        val ring = if (tone == ContextDisplayTone.ERROR || percent >= 100) {
            ContextUsageRingLabel(BANG, ContextDisplayTone.ERROR)
        } else {
            ContextUsageRingLabel(percent.toString(), tone)
        }
        return base.copy(display = ContextUsageDisplay.PERCENT, percent = percent, tone = tone, ring = ring)
    }

    /** Rule 2: spoken text of the ring; null when the ring is hidden. */
    fun ringAccessibility(summary: ContextUsageSummary, locale: String): ContextUsageRingAccessibility? {
        val ring = summary.ring ?: return null
        val percent = summary.percent ?: return null
        if (summary.display != ContextUsageDisplay.PERCENT) return null
        if (ring.label == BANG) return ContextUsageRingAccessibility(R.string.context_usage_ring_over_a11y, emptyList())
        val limit = ContextCompactionPresentation.compactTokenCount(summary.B, locale) ?: return null
        return ContextUsageRingAccessibility(R.string.context_usage_ring_a11y, listOf(percent, limit))
    }

    private fun ContextManifest.omittedOf(kind: ContextSegmentKind): Int =
        segments.filter { it.kind == kind }.sumOf { it.omitted ?: 0 }
}

/**
 * Reads the conversation's ledger manifests and its latest valid checkpoint (contract P4·U4 rules 1 and 3).
 * The checkpoint is validated against the same full-history projection the transcript separator uses.
 */
class ContextUsageSource(
    private val ledger: ContextLedgerDao,
    private val store: ContextCompactionStore,
    private val accountId: () -> String,
    private val loadConversation: suspend (String) -> Conversation?,
    private val rhoHi: suspend (Conversation) -> Double,
    /** Limit B from the conversation's current cap and window, as the send computes it; null = use the manifest's. */
    private val currentB: suspend (String) -> ContextCurrentB? = { null },
) {
    suspend fun summary(conversationId: String): ContextUsageSummary {
        val manifests = ledger.manifests(conversationId).map { it.manifest }
        return ContextUsagePresentation.summary(
            manifests = manifests,
            checkpoint = checkpoint(conversationId),
            currentB = currentB(conversationId),
        )
    }

    private suspend fun checkpoint(conversationId: String): ContextUsageCheckpoint? {
        val account = accountId()
        // Without checkpoint rows there is nothing to validate; skip loading the full history.
        val count = store.list(account, conversationId).size
        if (count == 0) return null
        val conversation = loadConversation(conversationId) ?: return null
        val rho = rhoHi(conversation)
        val history = ChatContextProjector.compactionHistory(conversation.messages, rho)
            .map { CheckpointCoveredMessage(it.id, it.text) }
        val row = store.latestValid(account, conversationId, history) ?: return null
        return ContextUsageCheckpoint(
            count = count,
            latestCreatedAt = row.createdAt,
            latestSummaryTokens = ContextBudget.estimateMessage(row.text, rho),
        )
    }

    /**
     * Rule 3: recomputes on conversation switch, on [messagesChanged], on [capChanged] (the conversation cap or
     * the global default, so B follows the new limit right away), and on every checkpoint change of the
     * current conversation. A draft without a conversation id shows nothing (null).
     * Each result carries its conversation id so a stale one can be dropped after a switch.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun flow(
        conversationId: Flow<String?>,
        messagesChanged: Flow<Any?>,
        capChanged: Flow<Any?> = flowOf(Unit),
    ): Flow<ContextUsageResult?> =
        combine(conversationId, messagesChanged, capChanged) { id, _, _ -> id }
            .flatMapLatest { id ->
                if (id == null) {
                    flowOf(null)
                } else {
                    store.changes
                        .filter { it == id }
                        .map { }
                        .onStart { emit(Unit) }
                        .mapLatest { ContextUsageResult(id, summary(id)) }
                }
            }
            // Room reads and the history digest stay off the main thread.
            .flowOn(Dispatchers.IO)
}

/** Rule 2: fixed 28dp ring at the trailing end of the capability bar; shown only for percent display. */
@Composable
fun ContextUsageRing(
    summary: ContextUsageSummary?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ring = summary?.ring ?: return
    val accessibility = ContextUsagePresentation.ringAccessibility(summary, LocalConfiguration.current.locales[0].toLanguageTag()) ?: return
    val colors = OriveoTheme.colors
    val tint = when (ring.tone) {
        ContextDisplayTone.NEUTRAL -> colors.textSecondary
        ContextDisplayTone.WARM -> colors.warning
        ContextDisplayTone.ERROR -> colors.danger
    }
    val description = stringResource(accessibility.resId, *accessibility.args.toTypedArray())
    val fraction = ((summary.percent ?: 0).coerceIn(0, 100)) / 100f
    Box(
        modifier = modifier
            .size(28.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .clearAndSetSemantics {
                contentDescription = description
                role = Role.Button
                onClick { onClick(); true }
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.size(24.dp)) {
            val stroke = 2.5.dp.toPx()
            val inset = stroke / 2
            val arcSize = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
            val topLeft = androidx.compose.ui.geometry.Offset(inset, inset)
            drawArc(
                color = tint.copy(alpha = 0.2f),
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = stroke),
            )
            drawArc(
                color = tint,
                startAngle = -90f,
                sweepAngle = 360f * fraction,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
        Text(
            text = ring.label,
            color = tint,
            style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 10.sp, fontWeight = FontWeight.Medium),
            maxLines = 1,
        )
    }
}
