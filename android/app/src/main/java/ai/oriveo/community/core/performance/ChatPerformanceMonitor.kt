package ai.oriveo.community.core.performance

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.observability.Observability
import ai.oriveo.community.core.observability.ObservabilitySink
import ai.oriveo.community.core.observability.TraceHandle
import ai.oriveo.community.core.observability.TraceStatus

/**
 * Chat critical-path transactions (same contract as iOS ChatPerformanceMonitor; the name source is the fixture mobile-telemetry.v1.json).
 *
 * - `chat.open`: enter the Chat route -> first messages visible (an empty conversation counts once the input is interactive).
 * - `chat.send`: user taps send -> assistant leaves generating.
 * - `chat.firstToken`: user taps send -> first body or reasoning delta is on screen.
 *
 * Terminal semantics (fixture `discard_on` / `report_on`): reaching the end = ok; failure = internal_error + `chat.error_code`;
 * user taps stop = cancelled; not settled after `deadline_s` = deadline_exceeded; superseded / left / backgrounded = discarded, not reported
 * (that wait is not UI latency; recording it as a duration would pollute the distribution with "how long the user stayed away").
 *
 * Reports only go through [ObservabilitySink]; Sentry is not touched. The community build injects a local sink; this class is byte-identical to the hosted source.
 * Threading: the send path runs on the IO thread, UI on the main thread, timeouts fire on the main thread; all state is mutated under [lock].
 */
class ChatPerformanceMonitor(
    private val sink: () -> ObservabilitySink = { Observability.sink },
    private val clock: () -> Long = SystemClock::elapsedRealtime,
    scheduler: DeadlineScheduler? = null,
) {
    /** Timeout callback scheduler. Production uses a main-thread Handler; unit tests inject a fake clock. */
    fun interface DeadlineScheduler {
        /** Returns a cancel function. */
        fun schedule(delayMs: Long, action: () -> Unit): () -> Unit
    }

    enum class OpenKind(val wireValue: String) { Existing("existing"), New("new") }

    enum class FirstOutput(val wireValue: String) { Text("text"), Reasoning("reasoning") }

    /** Outcome of one send, given by the streaming manager when the assistant leaves generating. */
    sealed interface SendOutcome {
        /** Reached the end. [outputChars] is the visible body character count added this turn. */
        data class Completed(val outputChars: Int) : SendOutcome
        data class Failed(val errorCode: String) : SendOutcome
        /** Superseded / left / system-interrupted / ended before generation started: discard. */
        data object Discarded : SendOutcome
    }

    /** Receipt from [beginChatSend]: every later settle uses it, so the previous turn's teardown cannot settle a newer send in the same conversation. */
    class SendToken internal constructor(internal val conversationId: String)

    private class OpenTrace(val entryKey: String, val handle: TraceHandle, val cancelDeadline: () -> Unit)

    private class SendTrace(
        val token: SendToken,
        val startedAtMs: Long,
        val send: TraceHandle,
        val firstToken: TraceHandle,
        val cancelSendDeadline: () -> Unit,
        val cancelFirstTokenDeadline: () -> Unit,
    ) {
        var firstTokenClosed = false
        var ttftMs: Long? = null
    }

    private val lock = Any()
    private val scheduler: DeadlineScheduler by lazy { scheduler ?: MainThreadDeadlineScheduler() }
    private var openTrace: OpenTrace? = null
    /** Route entries that already started timing: Activity recreation reruns the enter effect, so the same entry is not counted twice. */
    private var lastBegunOpenEntry: String? = null
    private val sendTraces = HashMap<String, SendTrace>()

    // ── chat.open ──────────────────────────────────────────────

    fun beginChatOpen(entryKey: String, kind: OpenKind) = synchronized(lock) {
        if (lastBegunOpenEntry == entryKey) return@synchronized
        lastBegunOpenEntry = entryKey
        openTrace?.let(::discardOpen)
        val handle = sink().beginTransaction(CHAT_OPEN, CHAT_OPEN)
        handle.setTag(TAG_OPEN_KIND, kind.wireValue)
        val cancel = scheduler.schedule(CHAT_OPEN_DEADLINE_MS) { expireOpen(entryKey) }
        openTrace = OpenTrace(entryKey, handle, cancel)
    }

    /** First messages have been drawn (empty conversation: input is interactive). Does nothing when no open is in flight. */
    fun finishChatOpen(messageCount: Int) = synchronized(lock) {
        val trace = openTrace ?: return@synchronized
        openTrace = null
        trace.cancelDeadline()
        trace.handle.setTag(TAG_MESSAGE_COUNT_BUCKET, ObservabilityBuckets.count(messageCount.toLong()))
        trace.handle.finish(TraceStatus.Ok)
    }

    /** Left this route entry before the first screen was shown: discard. */
    fun discardChatOpen(entryKey: String) = synchronized(lock) {
        val trace = openTrace?.takeIf { it.entryKey == entryKey } ?: return@synchronized
        discardOpen(trace)
    }

    private fun discardOpen(trace: OpenTrace) {
        openTrace = null
        trace.cancelDeadline()
        trace.handle.discard()
    }

    private fun expireOpen(entryKey: String) = synchronized(lock) {
        val trace = openTrace?.takeIf { it.entryKey == entryKey } ?: return@synchronized
        openTrace = null
        trace.handle.finish(TraceStatus.DeadlineExceeded)
    }

    // ── chat.send / chat.firstToken ────────────────────────────

    fun beginChatSend(conversationId: String, providerKind: ProviderKind): SendToken = synchronized(lock) {
        // The previous turn in this conversation has not settled yet: this send supersedes it.
        sendTraces.remove(conversationId)?.let(::discardSend)
        val token = SendToken(conversationId)
        val tags = mapOf(
            TAG_ROUTE to routeOf(providerKind),
            TAG_PROVIDER_KIND to providerKind.name.lowercase(),
        )
        val send = sink().beginTransaction(CHAT_SEND, CHAT_SEND)
        val firstToken = sink().beginTransaction(CHAT_FIRST_TOKEN, CHAT_FIRST_TOKEN)
        tags.forEach { (key, value) ->
            send.setTag(key, value)
            firstToken.setTag(key, value)
        }
        sendTraces[conversationId] = SendTrace(
            token = token,
            startedAtMs = clock(),
            send = send,
            firstToken = firstToken,
            cancelSendDeadline = scheduler.schedule(CHAT_SEND_DEADLINE_MS) { expireSend(token) },
            cancelFirstTokenDeadline = scheduler.schedule(CHAT_FIRST_TOKEN_DEADLINE_MS) { expireFirstToken(token) },
        )
        token
    }

    /**
     * Send was tapped but blocked before the request left (the only exit for `chat_send_blocked` is `trackChatSendBlocked`, which lands here):
     * opens a chat.send / chat.firstToken pair right away and ends it with internal_error. `chat.error_code` takes the block reason as is;
     * `other` records `refused` (same convention as iOS `failChatSendBeforeDelivery`).
     * Does not touch in-flight [sendTraces]: nothing was sent, so this does not supersede the turn already generating in the conversation.
     * Duration is about 0: this pair measures the refusal rate, not latency.
     */
    fun recordSendBlocked(providerKind: ProviderKind?, reason: String) = synchronized(lock) {
        val errorCode = blockedErrorCode(reason)
        listOf(CHAT_SEND, CHAT_FIRST_TOKEN).forEach { name ->
            val handle = sink().beginTransaction(name, name)
            providerKind?.let {
                handle.setTag(TAG_ROUTE, routeOf(it))
                handle.setTag(TAG_PROVIDER_KIND, it.name.lowercase())
            }
            handle.setTag(TAG_ERROR_CODE, errorCode)
            handle.finish(TraceStatus.InternalError)
        }
    }

    fun markFirstOutputVisible(token: SendToken, output: FirstOutput) = synchronized(lock) {
        val trace = activeSend(token) ?: return@synchronized
        if (trace.firstTokenClosed) return@synchronized
        trace.firstTokenClosed = true
        trace.cancelFirstTokenDeadline()
        trace.ttftMs = clock() - trace.startedAtMs
        trace.firstToken.setTag(TAG_FIRST_OUTPUT, output.wireValue)
        trace.firstToken.finish(TraceStatus.Ok)
    }

    /** User tapped stop: the in-flight segments of this turn are reported as cancelled (duration = how long the user waited before giving up). */
    fun markChatSendStopped(conversationId: String) = synchronized(lock) {
        val trace = sendTraces.remove(conversationId) ?: return@synchronized
        closeSend(trace, TraceStatus.Cancelled, errorCode = null)
    }

    fun finishChatSend(token: SendToken, outcome: SendOutcome) = synchronized(lock) {
        val trace = activeSend(token) ?: return@synchronized
        sendTraces.remove(token.conversationId)
        when (outcome) {
            is SendOutcome.Completed -> {
                trace.cancelSendDeadline()
                trace.ttftMs?.let { trace.send.setMeasurement(MEASUREMENT_TTFT_MS, it.toDouble(), UNIT_MILLISECOND) }
                trace.send.setMeasurement(MEASUREMENT_OUTPUT_CHARS, outcome.outputChars.toDouble(), UNIT_NONE)
                trace.send.finish(TraceStatus.Ok)
                // Ended with no visible body or reasoning (e.g. image-only): no first-token sample, so discard.
                if (!trace.firstTokenClosed) {
                    trace.firstTokenClosed = true
                    trace.cancelFirstTokenDeadline()
                    trace.firstToken.discard()
                }
            }
            is SendOutcome.Failed -> closeSend(trace, TraceStatus.InternalError, outcome.errorCode)
            SendOutcome.Discarded -> discardSend(trace)
        }
    }

    /** Went to background: discard every in-flight transaction (wall-clock time while suspended is not UI latency). */
    fun discardAll() = synchronized(lock) {
        openTrace?.let(::discardOpen)
        sendTraces.values.toList().forEach(::discardSend)
        sendTraces.clear()
    }

    private fun activeSend(token: SendToken): SendTrace? =
        sendTraces[token.conversationId]?.takeIf { it.token === token }

    private fun closeSend(trace: SendTrace, status: TraceStatus, errorCode: String?) {
        trace.cancelSendDeadline()
        errorCode?.let { trace.send.setTag(TAG_ERROR_CODE, it) }
        trace.send.finish(status)
        if (!trace.firstTokenClosed) {
            trace.firstTokenClosed = true
            trace.cancelFirstTokenDeadline()
            errorCode?.let { trace.firstToken.setTag(TAG_ERROR_CODE, it) }
            trace.firstToken.finish(status)
        }
    }

    private fun discardSend(trace: SendTrace) {
        trace.cancelSendDeadline()
        trace.send.discard()
        if (!trace.firstTokenClosed) {
            trace.firstTokenClosed = true
            trace.cancelFirstTokenDeadline()
            trace.firstToken.discard()
        }
    }

    private fun expireSend(token: SendToken) = synchronized(lock) {
        val trace = activeSend(token) ?: return@synchronized
        sendTraces.remove(token.conversationId)
        closeSend(trace, TraceStatus.DeadlineExceeded, errorCode = null)
    }

    private fun expireFirstToken(token: SendToken) = synchronized(lock) {
        val trace = activeSend(token) ?: return@synchronized
        if (trace.firstTokenClosed) return@synchronized
        trace.firstTokenClosed = true
        trace.firstToken.finish(TraceStatus.DeadlineExceeded)
    }

    private class MainThreadDeadlineScheduler : DeadlineScheduler {
        private val handler = Handler(Looper.getMainLooper())

        override fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
            val runnable = Runnable { action() }
            handler.postDelayed(runnable, delayMs)
            return { handler.removeCallbacks(runnable) }
        }
    }

    companion object {
        val shared: ChatPerformanceMonitor by lazy { ChatPerformanceMonitor() }

        // Fixture transactions[].name (= op)
        const val CHAT_OPEN = "chat.open"
        const val CHAT_SEND = "chat.send"
        const val CHAT_FIRST_TOKEN = "chat.firstToken"

        // Fixture transactions[].deadline_s
        const val CHAT_OPEN_DEADLINE_MS = 15_000L
        const val CHAT_SEND_DEADLINE_MS = 300_000L
        const val CHAT_FIRST_TOKEN_DEADLINE_MS = 60_000L

        // Fixture transactions[].tags
        const val TAG_OPEN_KIND = "chat.open.kind"
        const val TAG_MESSAGE_COUNT_BUCKET = "chat.message_count_bucket"
        const val TAG_ROUTE = "chat.route"
        const val TAG_PROVIDER_KIND = "chat.provider_kind"
        const val TAG_ERROR_CODE = "chat.error_code"
        const val TAG_FIRST_OUTPUT = "chat.first_output"

        // Fixture transactions[].measurements
        const val MEASUREMENT_TTFT_MS = "chat.ttft_ms"
        const val MEASUREMENT_OUTPUT_CHARS = "chat.output_chars"
        const val UNIT_MILLISECOND = "millisecond"
        const val UNIT_NONE = "none"

        /** Refused `chat.error_code`: takes the `chat_send_blocked.reason` value as is; the fallback reason `other` records `refused`, as on iOS. */
        const val ERROR_CODE_REFUSED = "refused"

        /** Fallback `chat_send_blocked.reason` value, the only one that maps to [ERROR_CODE_REFUSED]. */
        private const val REASON_OTHER = "other"

        fun blockedErrorCode(reason: String): String =
            if (reason == REASON_OTHER) ERROR_CODE_REFUSED else reason

        /** Fixture `chat.route` enum; the community build only has user-supplied keys, so every send is byok. */
        fun routeOf(@Suppress("UNUSED_PARAMETER") kind: ProviderKind): String = "byok"
    }
}

/** Fixture `buckets` count table for `chat.message_count_bucket`; only the count bucket is needed here. */
private object ObservabilityBuckets {
    private val COUNT_EDGES = listOf(0.0, 1.0, 10.0, 50.0, 200.0, 1000.0)
    private val COUNT_LABELS = listOf("0", "1-9", "10-49", "50-199", "200-999", "1000+")

    fun count(value: Long): String {
        val index = COUNT_EDGES.indexOfLast { value.toDouble() >= it }
        return COUNT_LABELS[index.coerceAtLeast(0)]
    }
}
