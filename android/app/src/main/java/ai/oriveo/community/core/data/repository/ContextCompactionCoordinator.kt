package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.CheckpointAction
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.CheckpointFallbackMessage
import ai.oriveo.community.core.context.CheckpointSpanMessage
import ai.oriveo.community.core.context.CompactInput
import ai.oriveo.community.core.context.CompactMessage
import ai.oriveo.community.core.context.CompactOutcome
import ai.oriveo.community.core.context.CompactPrevious
import ai.oriveo.community.core.context.CompactResult
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.trimWhiteSpace
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.context.ContextCompactionBreaker
import ai.oriveo.community.core.context.ContextCompactionEvent
import ai.oriveo.community.core.context.ContextCompactionMode
import ai.oriveo.community.core.context.ContextCompactor
import ai.oriveo.community.core.context.SummaryAttachment
import ai.oriveo.community.core.context.SummaryRequest
import ai.oriveo.community.core.context.SummaryRequestInput
import ai.oriveo.community.core.context.SummaryRequestShape
import ai.oriveo.community.core.context.SummarySpanMessage
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatRole
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class ContextCompactionTrigger {
    PRE_SEND,
    OVERFLOW,
    MANUAL,
}

/**
 * A local history message as the coordinator sees it.
 * [isDirective] is evaluated on first read only: most sends never compact, so the detector must not run per message.
 */
class ContextCompactionMessage(
    val id: String,
    val role: ChatRole,
    val text: String,
    val estTokens: Int,
    directive: () -> Boolean,
    val attachments: List<SummaryAttachment> = emptyList(),
) {
    constructor(
        id: String,
        role: ChatRole,
        text: String,
        estTokens: Int,
        isDirective: Boolean = false,
        attachments: List<SummaryAttachment> = emptyList(),
    ) : this(id, role, text, estTokens, { isDirective }, attachments)

    val isDirective: Boolean by lazy(directive)
}

/** Everything one compaction needs from the current chat plan; `messages` is the full local history. */
data class ContextCompactionContext(
    val messages: List<ContextCompactionMessage>,
    val B: Int,
    val U: Int,
    val rhoHi: Double,
    val prefixTokens: Int,
    val fixedTokens: Int,
    val model: String,
)

/** Contract P3·U3 rule 9 result; `failures` are the per-attempt reasons of the AI path. */
data class ContextCompactionResult(
    val outcome: CompactOutcome,
    val row: ContextCheckpointRecord?,
    val failures: List<List<String>>,
)

/**
 * Produces and stores checkpoint rows (contract P3·U3 rules 1, 2, 4, 5, 8, 9).
 * The summary call and the upload are injected; the breaker is per conversation and in memory only.
 * [summarize] is the default summary call; a caller that knows the session provider passes its own to [compact].
 * [upload] receives the account the row was saved under.
 * [onSaved] receives the conversation and its local row count after a successful local save
 * (contract P3·U4 rule 6: the third-compaction hint counts local rows only).
 */
class ContextCompactionCoordinator(
    private val store: ContextCompactionStore,
    private val accountId: suspend () -> String,
    private val aiSummaryEnabled: suspend () -> Boolean,
    private val remoteCompactionEnabled: () -> Boolean = {
        MetadataClient.isRuntimeFeatureEnabled(REMOTE_FLAG_KEY, defaultValue = true)
    },
    private val summarize: suspend (SummaryRequest) -> String? = { null },
    private val upload: (String, ContextCheckpointRecord, List<String>) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
    private val onSaved: (conversationId: String, localCount: Int) -> Unit = { _, _ -> },
) {
    private val breakers = ConcurrentHashMap<String, ContextCompactionBreaker>()
    private val aiJobs = ConcurrentHashMap<String, Job>()
    private val _aiCompacting = MutableStateFlow<Set<String>>(emptySet())

    /** Contract P3·U4 rule 9: conversations whose AI summary call is running (the fallback is instant and never shows). */
    val aiCompacting: StateFlow<Set<String>> = _aiCompacting.asStateFlow()

    private val flights = ConcurrentHashMap<String, Mutex>()
    private val _sendCompacting = MutableStateFlow<Set<String>>(emptySet())

    /**
     * Conversations whose compaction runs inside a send (pre-send from the send path, or overflow), including the
     * wait for an in-flight compaction. Only these turn the send button into stop; pre-compaction and manual do not.
     */
    val sendCompacting: StateFlow<Set<String>> = _sendCompacting.asStateFlow()

    /**
     * Rule 9: cancels the running AI summary of [conversationId] only. Pre-send / overflow then fall back
     * without counting a failure; manual returns noop and saves nothing.
     */
    fun cancel(conversationId: String) {
        aiJobs[conversationId]?.cancel()
    }

    fun breaker(conversationId: String): ContextCompactionBreaker =
        breakers[conversationId] ?: ContextCompactionBreaker()

    /** Rule 8: every chat send counts one turn. */
    fun recordTurn(conversationId: String) = record(conversationId, ContextCompactionEvent.TURN)

    /** Rule 8: user retry clears the breaker. */
    fun retry(conversationId: String) = record(conversationId, ContextCompactionEvent.RETRY)

    /** Contract rule 6: the newest valid stored row for [history] under the current account; a failed read is null. */
    suspend fun latestValid(conversationId: String, history: List<CheckpointCoveredMessage>): ContextCheckpointRecord? = try {
        store.latestValid(accountId(), conversationId, history)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        android.util.Log.w(LOG_TAG, "latestValid failed: ${e.message}")
        null
    }

    /** Contract P3·U4 rule 10: AI mode for automatic triggers (preference, remote flag and breaker in llm). */
    suspend fun aiMode(conversationId: String): Boolean = useAI(conversationId, ContextCompactionTrigger.PRE_SEND)

    /**
     * [fallback] false (P3·U4 rule 10 pre-compaction): no fallback row when AI is off, fails or is cancelled;
     * the result is noop and the breaker counts as usual.
     * One compaction per conversation at a time: a later call waits for the running one, then re-reads latestValid;
     * when that row already leaves nothing to compact, the result is noop carrying that row.
     */
    suspend fun compact(
        conversationId: String,
        trigger: ContextCompactionTrigger,
        context: ContextCompactionContext,
        summarizeWith: (suspend (SummaryRequest) -> String?)? = null,
        fallback: Boolean = true,
    ): ContextCompactionResult {
        val sending = fallback && trigger != ContextCompactionTrigger.MANUAL
        if (sending) _sendCompacting.update { it + conversationId }
        try {
            val flight = flights.computeIfAbsent(conversationId) { Mutex() }
            val waited = !flight.tryLock()
            if (waited) flight.lock()
            try {
                return compactLocked(conversationId, trigger, context, summarizeWith, fallback, waited)
            } finally {
                flight.unlock()
            }
        } finally {
            if (sending) _sendCompacting.update { it - conversationId }
        }
    }

    private suspend fun compactLocked(
        conversationId: String,
        trigger: ContextCompactionTrigger,
        context: ContextCompactionContext,
        summarizeWith: (suspend (SummaryRequest) -> String?)?,
        fallback: Boolean,
        waited: Boolean,
    ): ContextCompactionResult {
        val account = accountId()
        val history = context.messages
        val previous = latestValid(conversationId, history.map { CheckpointCoveredMessage(it.id, it.text) })
        // Rule 2: an empty span is a noop in every mode; no fallback row is written.
        val span = ContextCheckpoint.selectSpan(
            history.map { CheckpointSpanMessage(it.id, it.role, it.estTokens) },
            context.B,
            previous?.coversTo,
        )
        if (span.action == CheckpointAction.NOOP) {
            // After waiting, the row the other compaction just saved is handed back so the send re-projects with it.
            return ContextCompactionResult(CompactOutcome.NOOP, previous.takeIf { waited }, emptyList())
        }

        var failures: List<List<String>> = emptyList()
        if (useAI(conversationId, trigger)) {
            var cancelled = false
            val ai = try {
                trackAI(conversationId) { summarizeSpan(conversationId, context, previous, summarizeWith ?: summarize) }
            } catch (e: CancellationException) {
                // A stopped send cancels this coroutine too: rethrow. Only a cancelled summary call lands here.
                currentCoroutineContext().ensureActive()
                if (trigger == ContextCompactionTrigger.MANUAL) {
                    return ContextCompactionResult(CompactOutcome.NOOP, null, emptyList())
                }
                cancelled = true
                null
            }
            if (!cancelled) when {
                ai == null || ai.first.outcome == CompactOutcome.NOOP ->
                    return ContextCompactionResult(CompactOutcome.NOOP, null, emptyList())
                ai.first.outcome == CompactOutcome.SUMMARY -> {
                    val row = persist(account, summaryRow(conversationId, context, ai.first, ai.second))
                    // D-137: a failed save is a noop (failures kept) so the caller falls back to P2.
                    return ContextCompactionResult(
                        if (row == null) CompactOutcome.NOOP else CompactOutcome.SUMMARY,
                        row,
                        ai.first.failures.orEmpty(),
                    )
                }
                else -> failures = ai.first.failures.orEmpty()
            }
        }
        if (!fallback) return ContextCompactionResult(CompactOutcome.NOOP, null, failures)

        val row = fallbackRow(conversationId, context, previous)
            ?: return ContextCompactionResult(CompactOutcome.NOOP, null, failures)
        val saved = persist(account, row)
        return ContextCompactionResult(if (saved == null) CompactOutcome.NOOP else CompactOutcome.FALLBACK, saved, failures)
    }

    /** Runs the AI summary as a child job [cancel] can stop, publishing [aiCompacting] meanwhile. */
    private suspend fun <T> trackAI(conversationId: String, block: suspend () -> T): T = coroutineScope {
        val child = async { block() }
        aiJobs[conversationId] = child
        _aiCompacting.update { it + conversationId }
        try {
            child.await()
        } finally {
            aiJobs.remove(conversationId, child)
            if (aiJobs[conversationId] == null) _aiCompacting.update { it - conversationId }
        }
    }

    /** Rule 1: manual ignores the preference and the breaker; only the remote flag forces the fallback. */
    private suspend fun useAI(conversationId: String, trigger: ContextCompactionTrigger): Boolean {
        if (!remoteCompactionEnabled()) return false
        if (trigger == ContextCompactionTrigger.MANUAL) return true
        return aiSummaryEnabled() && breaker(conversationId).mode == ContextCompactionMode.LLM
    }

    /**
     * Rule 2. Returns null on an empty span (noop); otherwise the compact result plus the accepted output.
     * tooLarge returns a fallback result without touching the breaker.
     */
    private suspend fun summarizeSpan(
        conversationId: String,
        context: ContextCompactionContext,
        previous: ContextCheckpointRecord?,
        call: suspend (SummaryRequest) -> String?,
    ): Pair<CompactResult, String?>? {
        val history = context.messages
        val span = ContextCheckpoint.selectSpan(
            history.map { CheckpointSpanMessage(it.id, it.role, it.estTokens) },
            context.B,
            previous?.coversTo,
        )
        if (span.action == CheckpointAction.NOOP) return null
        val spanIds = span.spanIds.toSet()
        val request = ContextCompactor.summaryRequest(
            SummaryRequestInput(
                U = context.U,
                prefixTokens = context.prefixTokens,
                rhoHi = context.rhoHi,
                language = null,
                summaryMax = ContextBudget.derived(context.B.toLong()).summaryMax,
                previousCheckpointText = previous?.text,
                previousSummary = previous?.summary,
                span = history.filter { it.id in spanIds }
                    .map { SummarySpanMessage(it.id, it.role, it.text, it.attachments) },
            ),
        )
        if (request.shape == SummaryRequestShape.TOO_LARGE) {
            return CompactResult(CompactOutcome.FALLBACK, attempts = 0, failures = emptyList()) to null
        }

        val compactPrevious = previous?.let { CompactPrevious(it.coversTo, it.summary) }
        val messages = history.map { CompactMessage(it.id, it.role, it.text, it.estTokens, it.isDirective) }
        val outputs = mutableListOf<String?>()
        var result = CompactResult(CompactOutcome.FALLBACK)
        repeat(ContextCompactor.MAX_SUMMARY_ATTEMPTS) {
            outputs += callSummary(call, request)
            result = ContextCompactor.compact(
                CompactInput(conversationId, context.B, context.rhoHi, messages, compactPrevious, outputs.toList()),
            )
            if (result.outcome != CompactOutcome.FALLBACK) {
                if (result.outcome == CompactOutcome.SUMMARY) record(conversationId, ContextCompactionEvent.LLM_SUCCESS)
                return result to outputs.getOrNull((result.attempts ?: 0) - 1)
            }
        }
        record(conversationId, ContextCompactionEvent.LLM_FAILURE)
        return result to null
    }

    /** A thrown summary call counts as a null output. */
    private suspend fun callSummary(call: suspend (SummaryRequest) -> String?, request: SummaryRequest): String? = try {
        call(request)
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private fun summaryRow(
        conversationId: String,
        context: ContextCompactionContext,
        result: CompactResult,
        output: String?,
    ) = ContextCheckpointRecord(
        conversationId = conversationId,
        checkpointId = result.checkpointId!!,
        kind = ContextCheckpointKind.SUMMARY,
        coversFrom = result.coversFrom!!,
        coversTo = result.coversTo!!,
        coversDigest = result.coversDigest!!,
        messagesCovered = result.messagesCovered!!,
        userMessageIds = result.keptUserIds.orEmpty(),
        text = result.text!!,
        summary = output?.trimWhiteSpace(),
        language = null,
        model = context.model,
        packerVersion = ContextCheckpoint.PACKER_VERSION,
        createdAt = now(),
        cost = null,
    )

    /** Rules 4 and 5: deterministic fallback; null when it yields no checkpoint text. */
    private fun fallbackRow(
        conversationId: String,
        context: ContextCompactionContext,
        previous: ContextCheckpointRecord?,
    ): ContextCheckpointRecord? {
        val history = context.messages
        val fallback = ContextCheckpoint.fallback(
            history.map { CheckpointFallbackMessage(it.id, it.role, it.estTokens, it.text, it.isDirective) },
            context.B,
            context.rhoHi,
            context.fixedTokens,
            oldSummary = previous?.summary,
        )
        val text = fallback.checkpointText ?: return null
        val tailStart = fallback.tailStartId?.let { id -> history.indexOfFirst { it.id == id } } ?: history.size
        val coversIndex = tailStart - 1
        if (coversIndex < 0) return null
        val coversTo = history[coversIndex].id
        return ContextCheckpointRecord(
            conversationId = conversationId,
            checkpointId = ContextCheckpoint.checkpointId(conversationId, coversTo),
            kind = ContextCheckpointKind.FALLBACK,
            coversFrom = history.first().id,
            coversTo = coversTo,
            coversDigest = ContextCheckpoint.coversDigest(
                history.subList(0, coversIndex + 1).map { CheckpointCoveredMessage(it.id, it.text) },
            ),
            messagesCovered = coversIndex + 1,
            userMessageIds = fallback.keptUserIds,
            text = text,
            summary = previous?.summary,
            language = null,
            model = context.model,
            packerVersion = ContextCheckpoint.PACKER_VERSION,
            createdAt = now(),
            cost = null,
        )
    }

    /**
     * Rule 5: save, then upload with every local checkpointId of the conversation.
     * A failed save is logged and returns null (no row, no upload).
     */
    private suspend fun persist(account: String, row: ContextCheckpointRecord): ContextCheckpointRecord? {
        // Rule 9: a stopped send saves nothing.
        currentCoroutineContext().ensureActive()
        try {
            store.save(account, row)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            android.util.Log.w(LOG_TAG, "checkpoint save failed: ${e.message}")
            return null
        }
        val listed = try {
            store.list(account, row.conversationId).map { it.checkpointId }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            android.util.Log.w(LOG_TAG, "checkpoint list failed: ${e.message}")
            null
        }
        // An unknown local count never triggers the hint.
        listed?.let { onSaved(row.conversationId, it.size) }
        upload(account, row, listed ?: listOf(row.checkpointId))
        return row
    }

    private fun record(conversationId: String, event: ContextCompactionEvent) {
        breakers.compute(conversationId) { _, current -> (current ?: ContextCompactionBreaker()).apply(event) }
    }

    companion object {
        const val REMOTE_FLAG_KEY: String = "context_compaction_enabled"
        private const val LOG_TAG = "ContextCompaction"
    }
}
