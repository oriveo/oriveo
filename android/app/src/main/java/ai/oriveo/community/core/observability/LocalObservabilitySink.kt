package ai.oriveo.community.core.observability

import android.os.Build
import android.os.Trace
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * An [ObservabilitySink] that depends on no remote service: events are written to Logcat, and transactions are written as `android.os.Trace` async sections.
 *
 * Used by the community edition and debug builds. Developers can see the same-named `chat.send` / `chat.firstToken`
 * sections in Perfetto / Android Studio Profiler, and filtering Logcat by [TAG] shows metrics and issues.
 */
object LocalObservabilitySink : ObservabilitySink {
    const val TAG = "OriveoObservability"

    private val nextCookie = AtomicInteger(1)

    override fun beginTransaction(name: String, op: String): TraceHandle {
        val cookie = nextCookie.getAndIncrement()
        // Async sections exist only from API 29; older systems keep Logcat output only.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) Trace.beginAsyncSection(name, cookie)
        return LocalTraceHandle(name, cookie, System.nanoTime())
    }

    override fun count(name: String, value: Double, tags: Map<String, String>) {
        Log.i(TAG, "count $name=$value $tags")
    }

    override fun distribution(name: String, value: Double, unit: String, tags: Map<String, String>) {
        Log.i(TAG, "distribution $name=$value$unit $tags")
    }

    override fun log(level: ObservabilityLevel, message: String, attributes: Map<String, Any>) {
        Log.println(level.priority(), TAG, "$message $attributes")
    }

    override fun issue(
        name: String,
        level: ObservabilityLevel,
        fingerprint: List<String>,
        context: Map<String, Any>,
        tags: Map<String, String>,
        mainThreadStack: Array<StackTraceElement>?,
        attachments: List<ObservabilityAttachment>,
    ) {
        Log.println(
            level.priority(),
            TAG,
            "issue \"$name\" fingerprint=$fingerprint tags=$tags context=$context " +
                "stack=${mainThreadStack?.firstOrNull()} attachments=${attachments.map { it.fileName }}",
        )
    }

    override fun setContext(key: String, value: Map<String, Any>) {
        Log.d(TAG, "context $key=$value")
    }

    override fun setGlobalTag(key: String, value: String?) {
        Log.d(TAG, "tag $key=$value")
    }

    override fun reportFullyDisplayed() {
        Log.i(TAG, "fully displayed")
    }

    private fun ObservabilityLevel.priority(): Int = when (this) {
        ObservabilityLevel.Debug -> Log.DEBUG
        ObservabilityLevel.Info -> Log.INFO
        ObservabilityLevel.Warning -> Log.WARN
        ObservabilityLevel.Error -> Log.ERROR
    }

    private class LocalTraceHandle(
        private val name: String,
        private val cookie: Int,
        private val startedAtNanos: Long,
    ) : TraceHandle {
        private val closed = AtomicBoolean(false)
        private val tags = java.util.concurrent.ConcurrentHashMap<String, String>()
        private val measurements = java.util.concurrent.ConcurrentHashMap<String, String>()

        override fun setTag(key: String, value: String) {
            if (!closed.get()) tags[key] = value
        }

        override fun setMeasurement(name: String, value: Double, unit: String) {
            if (!closed.get()) measurements[name] = "$value$unit"
        }

        override fun finish(status: TraceStatus) = close("finish ${status.wireValue}")

        override fun discard() = close("discard")

        private fun close(outcome: String) {
            if (!closed.compareAndSet(false, true)) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) Trace.endAsyncSection(name, cookie)
            val elapsedMs = (System.nanoTime() - startedAtNanos) / 1_000_000
            Log.i(TAG, "$name $outcome ${elapsedMs}ms tags=$tags measurements=$measurements")
        }
    }
}
