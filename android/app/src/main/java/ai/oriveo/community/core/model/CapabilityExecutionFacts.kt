package ai.oriveo.community.core.model

import kotlinx.serialization.Serializable

/** Per-message capability execution facts. The domain carrier is transient, so export omits it. */
@Serializable
data class CapabilityExecutionResult(
    val owner: String,
    val state: String,
    val source: String,
    /** Catalog capabilityRuntime revision that authorized this local fact; null only for Relay local profiles. */
    val revision: String? = null,
)

/**
 * Frozen response-evidence signal from the catalog. Keep the producer event and JSON pointer together so a
 * recipe selection cannot silently degrade into a bare event-name match before terminal state is
 * decided. The service parser is responsible for emitting that producer event from the exact
 * protocol/pointer; this collector additionally enforces the catalog's nonEmpty contract.
 */
data class CapabilityResponseEvidenceSignal(
    val producerEvent: String,
    val pointer: String,
    val nonEmpty: Boolean,
)

/** Frozen structured recovery rule from the same runtime envelope that compiled the final body. */
data class CapabilityRejectionRule(
    val status: Int,
    val pointers: Set<String>,
    val rejectedParameter: String,
)

data class LocatedCapabilityRejection(
    val source: String,
    val owner: String,
    val recipeRef: String?,
    val locatedPointers: List<String>,
    val runtimeRevision: String?,
)

/**
 * Builders register pending final-body patches; the final HTTP writer confirms them only when it
 * begins the upstream attempt. Parser events are then matched exclusively to the catalog-bound
 * response evidence kinds. This prevents UI/request intent from claiming execution.
 */
class CapabilityExecutionCollector(

    private val onWebSearchDispatched: () -> Unit = {},
    private val onDispatched: suspend (List<CapabilityExecutionResult>) -> Unit = {},
) {
    private data class Pending(
        val owner: String,
        val source: String,
        val evidenceSignals: List<CapabilityResponseEvidenceSignal>,
        val revision: String?,
        val recipeRef: String? = null,
        val ownedPointers: Set<String> = emptySet(),
        val rejectionRules: List<CapabilityRejectionRule> = emptyList(),
        val includeExecutionFact: Boolean = true,
    )
    private val pending = linkedMapOf<String, Pending>()
    private val confirmed = linkedMapOf<String, Pending>()
    private val observedSignals = linkedSetOf<String>()
    private var dispatchConfirmed = false
    private var legacyWebSearchDispatched = false

    private data class DispatchSnapshot(
        val requested: List<CapabilityExecutionResult>,
        val webSearchDispatched: Boolean,
    )

    @Synchronized fun noteLegacyWebSearchDispatched() {
        legacyWebSearchDispatched = true
    }

    @Synchronized fun recordCompiled(
        owner: String,
        evidenceSignals: List<CapabilityResponseEvidenceSignal>,
        revision: String,
        recipeRef: String? = null,
        rejectionRules: List<CapabilityRejectionRule> = emptyList(),
        includeExecutionFact: Boolean = true,
    ) {
        pending[owner] = Pending(
            owner,
            "provider_recipe",
            evidenceSignals,
            revision,
            recipeRef,
            emptySet(),
            rejectionRules,
            includeExecutionFact,
        )
    }

    @Synchronized fun recordCustom(owner: String, revision: String?, appliedPointers: Set<String>) {
        pending[owner] = Pending(
            owner = owner,
            source = "custom",
            evidenceSignals = emptyList(),
            revision = revision,
            ownedPointers = appliedPointers,
        )
    }

    suspend fun confirmDispatched() {
        val snapshot = synchronized(this) {
            if (dispatchConfirmed) return
            dispatchConfirmed = true
            confirmed.putAll(pending)
            DispatchSnapshot(
                requested = confirmed.values.filter(Pending::includeExecutionFact)
                    .map { CapabilityExecutionResult(it.owner, "requested", it.source, it.revision) },

                webSearchDispatched = legacyWebSearchDispatched ||
                    confirmed.values.any { it.owner == WEB_CAPABILITY_OWNER },
            )
        }
        if (snapshot.webSearchDispatched) {

            try {
                onWebSearchDispatched()
            } catch (_: Exception) {
            }
        }
        // The request has been prepared and is about to start. A local Room/UI write failure must
        // not prevent the actual upstream attempt or turn a sent request into a false non-send.
        try {
            onDispatched(snapshot.requested)
        } catch (_: Exception) {
            // Best-effort local display persistence must not block the actual upstream request.
        }
    }

    @Synchronized fun observe(event: StreamEvent) {
        val producerEvent = when (event) {
            is StreamEvent.Citations -> event.takeIf { citation ->
                citation.citations.any { it.url.isNotBlank() }
            }?.let { "citations" }
            is StreamEvent.Reasoning -> event.takeIf { it.text.isNotBlank() }?.let { "reasoning" }
            is StreamEvent.ToolResult -> event.takeIf { it.tool.isNotBlank() && it.summary.isNotBlank() }
                ?.let { "tool_result" }
            else -> null
        } ?: return
        // A definition that ever permits non-empty=false must still not turn a blank carrier into
        // observed. Current catalog definitions require true; retaining the field makes that
        // contract explicit and fail-closed for future definitions.
        if (confirmed.values.any { pending ->
                pending.evidenceSignals.any { signal ->
                    signal.producerEvent == producerEvent && signal.nonEmpty
                }
            }
        ) {
            observedSignals += producerEvent
        }
    }

    /**
     * Accepts only a structured parameter field and an exact rule frozen by the production
     * compiler. Prose, an undispatched compile, another runtime revision, and an empty locator
     * roster all fail closed.
     */
    @Synchronized fun locateProviderRecipeRejection(
        statusCode: Int,
        rejectedParameter: String?,
    ): LocatedCapabilityRejection? {
        if (!dispatchConfirmed || statusCode != 400 || rejectedParameter.isNullOrBlank()) return null
        return confirmed.values.mapNotNull { fact ->
            val rule = fact.rejectionRules.singleOrNull { candidate ->
                candidate.status == statusCode && candidate.rejectedParameter == rejectedParameter
            } ?: return@mapNotNull null
            LocatedCapabilityRejection(
                source = fact.source,
                owner = fact.owner,
                recipeRef = fact.recipeRef,
                locatedPointers = rule.pointers.sorted(),
                runtimeRevision = fact.revision,
            )
        }.singleOrNull()
    }

    /** Custom recovery is bound to pointers actually emitted by the production compiler. */
    @Synchronized fun locateCustomRejection(
        statusCode: Int,
        rejectedParameter: String?,
    ): LocatedCapabilityRejection? {
        if (!dispatchConfirmed || statusCode != 400 || rejectedParameter.isNullOrBlank()) return null
        val normalizedPointer = "/" + rejectedParameter.split('.').joinToString("/") { segment ->
            segment.replace("~", "~0").replace("/", "~1")
        }
        return confirmed.values.mapNotNull { fact ->
            if (fact.source != "custom" || normalizedPointer !in fact.ownedPointers) return@mapNotNull null
            LocatedCapabilityRejection(
                source = "custom",
                owner = fact.owner,
                recipeRef = null,
                locatedPointers = listOf(normalizedPointer),
                runtimeRevision = fact.revision,
            )
        }.singleOrNull()
    }

    /** Sent facts for unsuccessful/cancelled attempts: no response outcome is inferred. */
    @Synchronized fun requestedResults(): List<CapabilityExecutionResult> = confirmed.values
        .filter(Pending::includeExecutionFact)
        .map { fact -> CapabilityExecutionResult(fact.owner, "requested", fact.source, fact.revision) }

    /** Guards error reporters: a final-wire control never leaks its rich context into them. */
    @Synchronized fun hasConfirmedFacts(): Boolean = confirmed.values.any(Pending::includeExecutionFact)

    /** Only a normally completed response may settle sent facts to observed or unconfirmed. */
    @Synchronized fun successfulTerminalResults(): List<CapabilityExecutionResult> = confirmed.values
        .filter(Pending::includeExecutionFact)
        .map { fact ->
        val state = when {
            fact.source == "custom" -> "unconfirmed"
            fact.evidenceSignals.any { signal ->
                signal.nonEmpty && signal.producerEvent in observedSignals
            } -> "observed"
            else -> "unconfirmed"
        }
            CapabilityExecutionResult(fact.owner, state, fact.source, fact.revision)
        }

    companion object {

        const val WEB_CAPABILITY_OWNER = "web"
    }
}
