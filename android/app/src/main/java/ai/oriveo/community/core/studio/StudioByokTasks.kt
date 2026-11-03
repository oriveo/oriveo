package ai.oriveo.community.core.studio

import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

/**
 * BYOK image task management, pure logic: per-attempt timeout, retry decision, transport error -> phase,
 * split-batch aggregation, the 4-slot round queue reducer and launch reconciliation.
 * Behavior follows byok_image_tasks.v1.
 */
object StudioByokTasks {
    const val DEFAULT_TIMEOUT_SECONDS = 180
    const val MAX_TIMEOUT_SECONDS = 180
    const val MAX_CONCURRENT_ROUNDS = 4
    const val MAX_AUTO_RETRIES = 1

    enum class Phase(val wire: String) {
        PRE_CONNECT("pre_connect"),
        AFTER_SEND("after_send"),
        TIMEOUT("timeout"),
        CANCELLED("cancelled"),
    }

    data class RetryDecision(
        val retry: Boolean,
        val errorKind: StudioImageErrorKind?,
        val retried: Boolean,
        val mayBeBilled: Boolean,
    )

    enum class RoundStatus(val wire: String) {
        COMPLETED("completed"),
        PARTIAL("partial"),
        FAILED("failed"),
        CANCELLED("cancelled"),
    }

    data class BatchResult(val images: Int, val errorKind: StudioImageErrorKind?)

    data class Aggregate(val status: RoundStatus, val delivered: Int, val errorKind: StudioImageErrorKind?)

    data class QueueState(val running: List<String> = emptyList(), val queued: List<String> = emptyList())

    sealed interface QueueEvent {
        val id: String

        data class Submit(override val id: String) : QueueEvent
        data class Finish(override val id: String) : QueueEvent
        data class Cancel(override val id: String) : QueueEvent
        data class Response(override val id: String) : QueueEvent
    }

    sealed interface QueueEffect {
        val id: String

        data class Start(override val id: String) : QueueEffect
        data class Cancelled(override val id: String, val mayBeBilled: Boolean) : QueueEffect
        data class Accept(override val id: String) : QueueEffect
        data class Drop(override val id: String) : QueueEffect
    }

    enum class ReconcileAction(val wire: String) {
        KEEP("keep"),
        PROCESS("process"),
        KEEP_RUNNING("keep_running"),
        INTERRUPTED("interrupted"),
        FAILED_TIMEOUT("failed_timeout"),
    }

    /** Per HTTP attempt total duration: missing or <= 0 -> default; capped. A retry gets a fresh full timeout. */
    fun effectiveTimeoutSeconds(timeoutSeconds: Int?): Int {
        if (timeoutSeconds == null || timeoutSeconds <= 0) return DEFAULT_TIMEOUT_SECONDS
        return minOf(timeoutSeconds, MAX_TIMEOUT_SECONDS)
    }

    /** Only a pre_connect failure on attempt 0 is retried (once); billing is possible once the body may have been sent. */
    fun retryDecision(phase: Phase, attempt: Int): RetryDecision {
        val retried = attempt > 0
        return when (phase) {
            Phase.PRE_CONNECT ->
                if (attempt < MAX_AUTO_RETRIES) {
                    RetryDecision(retry = true, errorKind = null, retried = retried, mayBeBilled = false)
                } else {
                    RetryDecision(retry = false, errorKind = StudioImageErrorKind.NETWORK, retried = retried, mayBeBilled = false)
                }
            Phase.AFTER_SEND -> RetryDecision(retry = false, errorKind = StudioImageErrorKind.NETWORK, retried = retried, mayBeBilled = true)
            Phase.TIMEOUT -> RetryDecision(retry = false, errorKind = StudioImageErrorKind.TIMEOUT, retried = retried, mayBeBilled = true)
            Phase.CANCELLED -> RetryDecision(retry = false, errorKind = null, retried = retried, mayBeBilled = false)
        }
    }

    /**
     * Android transport error -> phase. A canceled call wins; otherwise walk the cause chain from [error] and the
     * first link that matches decides (InterruptedIOException incl. SocketTimeoutException -> timeout, DNS /
     * refused / no route / TLS -> pre_connect). Anything unknown is after_send (never retried).
     */
    fun transportPhase(error: Throwable, callCanceled: Boolean): Phase {
        if (callCanceled) return Phase.CANCELLED
        val seen = HashSet<Throwable>()
        var current: Throwable? = error
        while (current != null && seen.add(current)) {
            when (current) {
                is InterruptedIOException -> return Phase.TIMEOUT
                is UnknownHostException,
                is ConnectException,
                is NoRouteToHostException,
                is SSLHandshakeException,
                is SSLPeerUnverifiedException,
                -> return Phase.PRE_CONNECT
            }
            current = current.cause
        }
        return Phase.AFTER_SEND
    }

    /** Sums each batch's images capped at its size; cancellation drops everything. */
    fun aggregate(n: Int, batches: List<Int>, results: List<BatchResult>, cancelled: Boolean): Aggregate {
        if (cancelled) return Aggregate(RoundStatus.CANCELLED, delivered = 0, errorKind = null)
        val delivered = batches.indices.sumOf { index ->
            val images = results.getOrNull(index)?.images ?: 0
            images.coerceIn(0, maxOf(batches[index], 0))
        }
        if (delivered >= n) return Aggregate(RoundStatus.COMPLETED, delivered = n, errorKind = null)
        // Results past batches.size are ignored.
        val firstKind = results.take(batches.size).firstNotNullOfOrNull { it.errorKind }
        return if (delivered > 0) {
            Aggregate(RoundStatus.PARTIAL, delivered, firstKind ?: StudioImageErrorKind.PARTIAL)
        } else {
            Aggregate(RoundStatus.FAILED, delivered = 0, errorKind = firstKind ?: StudioImageErrorKind.DECODE_FAILED)
        }
    }

    /** Round queue reducer: FIFO, at most [MAX_CONCURRENT_ROUNDS] running; effects in emission order. */
    fun reduce(state: QueueState, event: QueueEvent): Pair<QueueState, List<QueueEffect>> {
        val id = event.id
        return when (event) {
            is QueueEvent.Submit ->
                if (id in state.running || id in state.queued) {
                    state to emptyList()
                } else {
                    promote(state.copy(queued = state.queued + id), emptyList())
                }
            is QueueEvent.Finish ->
                if (id in state.running) promote(state.copy(running = state.running - id), emptyList()) else state to emptyList()
            is QueueEvent.Cancel -> when (id) {
                in state.running ->
                    promote(state.copy(running = state.running - id), listOf(QueueEffect.Cancelled(id, mayBeBilled = true)))
                in state.queued ->
                    state.copy(queued = state.queued - id) to listOf(QueueEffect.Cancelled(id, mayBeBilled = false))
                else -> state to emptyList()
            }
            is QueueEvent.Response ->
                state to listOf(if (id in state.running) QueueEffect.Accept(id) else QueueEffect.Drop(id))
        }
    }

    private fun promote(state: QueueState, effects: List<QueueEffect>): Pair<QueueState, List<QueueEffect>> {
        val free = (MAX_CONCURRENT_ROUNDS - state.running.size).coerceAtLeast(0)
        val started = state.queued.take(free)
        val next = QueueState(running = state.running + started, queued = state.queued.drop(started.size))
        return next to effects + started.map { QueueEffect.Start(it) }
    }

    /** Launch reconciliation of a persisted round; [status] is the persisted status wire value. */
    fun reconcile(
        status: String,
        startedAtMs: Long?,
        nowMs: Long,
        timeoutSeconds: Int?,
        responseReceived: Boolean,
        transferActive: Boolean,
    ): ReconcileAction {
        if (status != STATUS_QUEUED && status != STATUS_RUNNING) return ReconcileAction.KEEP
        if (status == STATUS_QUEUED) return ReconcileAction.INTERRUPTED
        if (responseReceived) return ReconcileAction.PROCESS
        if (transferActive) return ReconcileAction.KEEP_RUNNING
        if (startedAtMs == null || nowMs < startedAtMs) return ReconcileAction.INTERRUPTED
        return if (nowMs - startedAtMs >= effectiveTimeoutSeconds(timeoutSeconds) * 1000L) {
            ReconcileAction.FAILED_TIMEOUT
        } else {
            ReconcileAction.INTERRUPTED
        }
    }

    private const val STATUS_QUEUED = "queued"
    private const val STATUS_RUNNING = "running"
}
