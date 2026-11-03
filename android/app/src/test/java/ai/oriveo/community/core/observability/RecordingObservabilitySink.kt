package ai.oriveo.community.core.observability

/** Test sink that records all transactions, metrics, issues and contexts for assertions. */
internal class RecordingObservabilitySink : ObservabilitySink {
    class Trace(val name: String) : TraceHandle {
        val tags = linkedMapOf<String, String>()
        val measurements = linkedMapOf<String, Pair<Double, String>>()
        var outcome: String? = null
        var closeCount = 0

        override fun setTag(key: String, value: String) { if (outcome == null) tags[key] = value }
        override fun setMeasurement(name: String, value: Double, unit: String) { if (outcome == null) measurements[name] = value to unit }
        override fun finish(status: TraceStatus) { if (outcome == null) outcome = status.wireValue; closeCount++ }
        override fun discard() { if (outcome == null) outcome = "discarded"; closeCount++ }
    }

    data class Metric(val kind: String, val name: String, val value: Double, val unit: String?, val tags: Map<String, String>)
    data class Issue(val name: String, val level: ObservabilityLevel, val fingerprint: List<String>, val context: Map<String, Any>, val tags: Map<String, String>)

    val traces = mutableListOf<Trace>()
    val metrics = mutableListOf<Metric>()
    val issues = mutableListOf<Issue>()
    val contexts = linkedMapOf<String, Map<String, Any>>()
    var fullyDisplayedCount = 0

    fun last(name: String) = traces.last { it.name == name }

    override fun beginTransaction(name: String, op: String): TraceHandle = Trace(name).also { traces += it }

    override fun count(name: String, value: Double, tags: Map<String, String>) {
        metrics += Metric("count", name, value, null, tags)
    }

    override fun distribution(name: String, value: Double, unit: String, tags: Map<String, String>) {
        metrics += Metric("distribution", name, value, unit, tags)
    }

    override fun log(level: ObservabilityLevel, message: String, attributes: Map<String, Any>) = Unit

    override fun issue(
        name: String,
        level: ObservabilityLevel,
        fingerprint: List<String>,
        context: Map<String, Any>,
        tags: Map<String, String>,
        mainThreadStack: Array<StackTraceElement>?,
        attachments: List<ObservabilityAttachment>,
    ) {
        issues += Issue(name, level, fingerprint, context, tags)
    }

    override fun setContext(key: String, value: Map<String, Any>) {
        contexts[key] = value
    }

    override fun reportFullyDisplayed() {
        fullyDisplayedCount++
    }
}
