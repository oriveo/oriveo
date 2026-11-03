package ai.oriveo.community.core.observability

/**
 * Observability reporting sink protocol (mirrors iOS `ObservabilitySink`).
 *
 * The measurement core (ChatPerformanceMonitor and friends) only talks to this interface; the community build injects
 * [LocalObservabilitySink] (Logcat + `android.os.Trace`), which needs no remote service.
 *
 * Names are sourced from the shared fixture `shared/observability-contracts/mobile-telemetry.v1.json`: transaction names / op / measurement / tag /
 * metric / issue titles must be literals registered in the fixture; values may only be bucketed numbers or enums, never content or ids.
 */
interface ObservabilitySink {
    /** Opens a critical-path transaction. Implementations must not attach it to a global scope (prevents automatic child spans from extending it). */
    fun beginTransaction(name: String, op: String): TraceHandle

    /** Count metric (e.g. frequency trend of self-healing paths); at most 3 low-cardinality tag keys. */
    fun count(name: String, value: Double = 1.0, tags: Map<String, String> = emptyMap())

    fun distribution(name: String, value: Double, unit: String, tags: Map<String, String> = emptyMap())

    /** Structured low-frequency log: for parameter-level debugging, but a single entry is not worth opening an issue. */
    fun log(level: ObservabilityLevel, message: String, attributes: Map<String, Any> = emptyMap())

    /**
     * A diagnostic that needs someone to act on: [name] is a fixed title (no interpolated variables); variables go into [context].
     *
     * [tags] carries only low-cardinality keys (fixture `tags`); when [mainThreadStack] is non-empty it becomes the event's only main-thread stack (frozen-frame stall point,
     * replacing the reporting call site's own stack); [attachments] are sent with this event.
     */
    fun issue(
        name: String,
        level: ObservabilityLevel,
        fingerprint: List<String>,
        context: Map<String, Any> = emptyMap(),
        tags: Map<String, String> = emptyMap(),
        mainThreadStack: Array<StackTraceElement>? = null,
        attachments: List<ObservabilityAttachment> = emptyList(),
    )

    /** Overrides a named context block (e.g. `oriveo_state`); all subsequent events carry it. */
    fun setContext(key: String, value: Map<String, Any>)

    /** Low-cardinality tag carried by all subsequent events (e.g. `posthog_session`); removed when [value] is null. No-op by default (test doubles need not implement it). */
    fun setGlobalTag(key: String, value: String?) = Unit

    /** First screen content is fully usable (TTFD end point). Business code calls it only through [FullyDisplayedGate]; it takes effect once per Activity instance. */
    fun reportFullyDisplayed()
}

/** An in-flight transaction. Each handle can be closed only once: calls after [finish] or [discard] are all ignored. */
interface TraceHandle {
    fun setTag(key: String, value: String)

    /** [unit] takes the unit literal of the fixture measurement (`millisecond` / `none` …). */
    fun setMeasurement(name: String, value: Double, unit: String)

    fun finish(status: TraceStatus)

    /** Discard without reporting: a wait that was superseded, left, or went to background is not UI latency. */
    fun discard()
}

/** Text attachment sent with a single issue. */
class ObservabilityAttachment(val fileName: String, val contentType: String, val bytes: ByteArray)

/** Fixture `status_values`. */
enum class TraceStatus(val wireValue: String) {
    Ok("ok"),
    InternalError("internal_error"),
    Cancelled("cancelled"),
    DeadlineExceeded("deadline_exceeded"),
}

enum class ObservabilityLevel { Debug, Info, Warning, Error }

/** The currently active sink. Reports nothing by default; injected per build at app startup (see OriveoApplication). */
object Observability {
    @Volatile
    var sink: ObservabilitySink = NoOpObservabilitySink
        private set

    fun install(sink: ObservabilitySink) {
        this.sink = sink
    }
}

object NoOpObservabilitySink : ObservabilitySink {
    private object NoOpTrace : TraceHandle {
        override fun setTag(key: String, value: String) = Unit
        override fun setMeasurement(name: String, value: Double, unit: String) = Unit
        override fun finish(status: TraceStatus) = Unit
        override fun discard() = Unit
    }

    override fun beginTransaction(name: String, op: String): TraceHandle = NoOpTrace
    override fun count(name: String, value: Double, tags: Map<String, String>) = Unit
    override fun distribution(name: String, value: Double, unit: String, tags: Map<String, String>) = Unit
    override fun log(level: ObservabilityLevel, message: String, attributes: Map<String, Any>) = Unit
    override fun issue(
        name: String,
        level: ObservabilityLevel,
        fingerprint: List<String>,
        context: Map<String, Any>,
        tags: Map<String, String>,
        mainThreadStack: Array<StackTraceElement>?,
        attachments: List<ObservabilityAttachment>,
    ) = Unit
    override fun setContext(key: String, value: Map<String, Any>) = Unit
    override fun reportFullyDisplayed() = Unit
}
