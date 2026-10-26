package ai.oriveo.community.core.data.remote

import ai.oriveo.community.core.context.ContinuationInstructionsMode
import android.content.Context
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.error.isTransientNetworkOrCancellation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ModelSourceSummary
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RequestPreferenceResolver
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.ModelPricingFormatter
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAuthResolver
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.core.provider.grok.RawProtocolFeatures
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAuthResolver
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAvailability
import ai.oriveo.community.core.provider.openai.RawOpenAIProtocolFeatures

import java.io.EOFException
import java.io.FilterInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import ai.oriveo.community.core.model.CapabilityResponseEvidenceSignal

fun canonicalCapabilityTransport(value: String?): String = when (value?.lowercase()) {
    "openai_chat" -> "openai_chat_completions"
    else -> value?.lowercase().orEmpty()
}

/**
 * A present responseEvidenceRef must resolve to a complete catalog definition. An empty signal
 * list is valid and deliberately yields unconfirmed after a successful response; a missing or
 * malformed definition is not silently treated as that valid no-evidence case.
 */
private fun responseEvidenceSignals(
    runtime: JsonObject,
    ref: String,
    capability: String,
    finalTransport: String,
    responseParserKind: String?,
): List<CapabilityResponseEvidenceSignal>? {
    val definition = (runtime["responseEvidenceDefinitions"] as? JsonObject)?.get(ref) as? JsonObject ?: return null
    if (
        definition["capability"]?.jsonPrimitive?.contentOrNull != capability ||
        canonicalCapabilityTransport(definition["protocol"]?.jsonPrimitive?.contentOrNull) != canonicalCapabilityTransport(finalTransport) ||
        definition["responseParserKind"]?.jsonPrimitive?.contentOrNull != responseParserKind
    ) return null
    val signals = definition["signals"] as? JsonArray ?: return null
    return signals.map { rawSignal ->
        val signal = rawSignal as? JsonObject ?: return null
        val kind = signal["kind"]?.jsonPrimitive?.contentOrNull
        val producerEvent = signal["producerEvent"]?.jsonPrimitive?.contentOrNull ?: return null
        val pointer = signal["pointer"]?.jsonPrimitive?.contentOrNull ?: return null
        val nonEmpty = signal["nonEmpty"]?.jsonPrimitive?.booleanOrNull
        if (
            kind in setOf("citation", "grounding", "thinking_block", "provider_tool_result") &&
                producerEvent in setOf("citations", "reasoning", "tool_result") &&
                pointer.startsWith('/') && nonEmpty == true
        ) {
            CapabilityResponseEvidenceSignal(
                producerEvent = producerEvent,
                pointer = pointer,
                nonEmpty = nonEmpty,
            )
        } else {
            return null
        }
    }
}

private fun capabilityRuntimeRevision(runtime: JsonObject): String? =
    runtime["revision"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }

internal data class MetadataTransportResponse(
    val statusCode: Int,
    val eTag: String?,
    val body: String?,
    val responseBytes: Long,
)

internal fun interface MetadataTransport {
    suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse
}

internal fun interface ModelFactsTransport {
    suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse
}

private class CountingInputStream(input: InputStream) : FilterInputStream(input) {
    var bytesRead: Long = 0L
        private set

    override fun read(): Int = super.read().also { if (it >= 0) bytesRead += 1 }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        super.read(buffer, offset, length).also { read -> if (read > 0) bytesRead += read }
}

/**
 * Base address of the public model catalog.
 *
 * The catalog is a read-only feed of model capabilities and prices. It carries no credentials and
 * identifies nobody; chat requests always go straight to the user's own provider. Point
 * `ORIVEO_METADATA_BASE_URL` at your own host at build time to serve it yourself, or leave it
 * blank to build without a catalog: nothing is fetched and there is no bundled fallback, so every
 * model then comes from a relay, a local engine, or manual entry.
 */
private fun metadataBaseUrl(): String? =
    BuildConfig.METADATA_BASE_URL.trimEnd('/').takeIf { it.isNotBlank() }

/**
 * The index + per-provider catalog views. Injected separately from [MetadataTransport]: without
 * it the client only uses the lean view (the unit-test default), so nothing reaches the split
 * views by accident.
 */
internal interface MetadataSplitTransport {
    /**
     * When [cacheBust] is non-null the URL carries `fresh=<value>`: used only for the one refetch after a revision mismatch, bypassing the edge cache straight to origin
     * (contract section 5.9); regular fetches pass null.
     */
    suspend fun fetchIndex(ifNoneMatch: String?, cacheBust: String?): MetadataTransportResponse

    /**
     * [revision] is the catalogRevision for this provider announced by the index the caller holds; when non-null the URL carries `rev=<value>`:
     * a new revision is necessarily an edge miss and never returns an old catalog (contract section 5.9); pass null when the index announces none, keeping the old shape.
     */
    suspend fun fetchCatalog(provider: String, ifNoneMatch: String?, revision: String?): MetadataTransportResponse
}

private suspend fun httpGetMetadata(pathAndQuery: String, ifNoneMatch: String?): MetadataTransportResponse =
    httpGetMetadata(pathAndQuery, emptyMap(), ifNoneMatch)

private suspend fun httpGetMetadata(
    pathAndQuery: String,
    headers: Map<String, String>,
    ifNoneMatch: String?,
): MetadataTransportResponse {
    val baseUrl = metadataBaseUrl() ?: return MetadataTransportResponse(
        statusCode = HttpURLConnection.HTTP_NOT_IMPLEMENTED,
        eTag = null,
        body = null,
        responseBytes = 0L,
    )
    val connection = URL("$baseUrl$pathAndQuery").openConnection() as HttpURLConnection
    return try {
        connection.requestMethod = "GET"
        connection.setRequestProperty("Accept", "application/json")
        headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
        ifNoneMatch?.let { connection.setRequestProperty("If-None-Match", it) }
        connection.connectTimeout = 10_000
        connection.readTimeout = 15_000

        val statusCode = connection.responseCode
        var bodyBytes = connection.contentLengthLong.coerceAtLeast(0L)
        val body = if (statusCode == HttpURLConnection.HTTP_OK) {
            val countingStream = CountingInputStream(connection.inputStream)
            countingStream.bufferedReader().use { it.readText() }.also {
                bodyBytes = countingStream.bytesRead
            }
        } else {
            null
        }
        MetadataTransportResponse(
            statusCode = statusCode,
            eTag = connection.getHeaderField("ETag")?.trim()?.takeIf { it.isNotEmpty() },
            body = body,
            responseBytes = bodyBytes,
        )
    } finally {
        connection.disconnect()
    }
}

private object HttpUrlConnectionMetadataTransport : MetadataTransport {
    override suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse =
        httpGetMetadata("/api/metadata?view=lean", ifNoneMatch)
}

/**
 * HTTP implementation of index / catalog. With [requestSchema] >= 2 it sends both a `schema=N` query and the
 * `X-Oriveo-Metadata-Schema: N` header; with 1 the URL and headers keep the historical shape. Lean is always schema 1 and does not go through here.
 */
internal class HttpUrlConnectionMetadataSplitTransport internal constructor(
    private val requestSchema: Int = MetadataClient.METADATA_REQUEST_SCHEMA,
    private val get: suspend (pathAndQuery: String, headers: Map<String, String>, ifNoneMatch: String?) -> MetadataTransportResponse =
        { pathAndQuery, headers, ifNoneMatch -> httpGetMetadata(pathAndQuery, headers, ifNoneMatch) },
) : MetadataSplitTransport {
    private val schemaQuery: String = if (requestSchema >= 2) "&schema=$requestSchema" else ""
    private val schemaHeaders: Map<String, String> =
        if (requestSchema >= 2) mapOf(METADATA_SCHEMA_HEADER to requestSchema.toString()) else emptyMap()

    override suspend fun fetchIndex(ifNoneMatch: String?, cacheBust: String?): MetadataTransportResponse =
        get("/api/metadata?view=index$schemaQuery" + queryParam("fresh", cacheBust), schemaHeaders, ifNoneMatch)

    override suspend fun fetchCatalog(provider: String, ifNoneMatch: String?, revision: String?): MetadataTransportResponse =
        get(
            "/api/metadata?view=catalog&provider=" + java.net.URLEncoder.encode(provider, "UTF-8") + schemaQuery +
                queryParam("rev", revision),
            schemaHeaders,
            ifNoneMatch,
        )

    private fun queryParam(name: String, value: String?): String =
        value?.let { "&$name=" + java.net.URLEncoder.encode(it, "UTF-8") }.orEmpty()

    private companion object {
        const val METADATA_SCHEMA_HEADER = "X-Oriveo-Metadata-Schema"
    }
}

private object HttpUrlConnectionModelFactsTransport : ModelFactsTransport {
    override suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse =
        httpGetMetadata("/api/metadata/model-facts", ifNoneMatch)
}

private object HttpUrlConnectionModelFactsByModelTransport : ModelFactsTransport {
    override suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse =
        withContext(Dispatchers.IO) { httpGetMetadata("/api/metadata/model-facts?view=by-model", ifNoneMatch) }
}

/**
 * Family lookup table for per-model relay probing: `GET /api/metadata/model-facts?view=by-model`.
 *
 * Fetched lazily once, only when a candidate needs the family; a successful result is cached in-process; failure / non-200 / unparsable all count as family unknown and are not cached,
 * and it is fetched again the next time it is needed. Keys use [MetadataClient.normalizeModelFactsID]; on a miss the segment after the last `/` is tried
 * (same rule as the Server's normalizeModelsDevJoinID + modelsDevJoinLastSegment). The family is never guessed from the id text.
 */
class RelayModelFamilyLookup internal constructor(
    private val transport: ModelFactsTransport,
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    private val mutex = Mutex()
    @Volatile private var families: Map<String, String>? = null

    suspend fun family(modelID: String): String? = lookup(loadedFamilies() ?: return null, modelID)

    /** Reads only the cached family table and never sends a request; if it has never been fetched the family is unknown. The add page's ratio bar uses it (no new request is sent just for the ratio bar). */
    fun cachedFamily(modelID: String): String? = lookup(families ?: return null, modelID)

    private fun lookup(table: Map<String, String>, modelID: String): String? {
        val normalized = MetadataClient.normalizeModelFactsID(modelID)
        return table[normalized] ?: table[normalized.substringAfterLast('/')]
    }

    private suspend fun loadedFamilies(): Map<String, String>? = mutex.withLock {
        families?.let { return@withLock it }
        val response = try {
            transport.fetch(null)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            return@withLock null
        }
        val body = response.body?.takeIf { response.statusCode == HttpURLConnection.HTTP_OK } ?: return@withLock null
        val byModel = runCatching {
            ((json.parseToJsonElement(body) as? JsonObject)?.get("data") as? JsonObject)?.get("byModel") as? JsonObject
        }.getOrNull() ?: return@withLock null
        byModel.mapNotNull { (id, entry) ->
            val family = ((entry as? JsonObject)?.get("family") as? JsonPrimitive)
                ?.takeIf { it.isString }?.content?.trim()?.takeIf(String::isNotEmpty)
            family?.let { MetadataClient.normalizeModelFactsID(id) to it }
        }.toMap().also { families = it }
    }

    companion object {
        val shared: RelayModelFamilyLookup by lazy { RelayModelFamilyLookup(HttpUrlConnectionModelFactsByModelTransport) }
    }
}

private class MetadataHttpStatusException(statusCode: Int) :
    Exception("metadata request returned HTTP $statusCode")

internal const val METADATA_FAILURE_MODULE = "metadata_client"

private fun Map<String, String>.tagOrUnknown(key: String): String =
    this[key]?.takeIf { it.isNotBlank() } ?: "unknown"

internal fun metadataFailureMessage(tags: Map<String, String>): String =
    "metadata ${tags.tagOrUnknown("phase")} failed"

/** Verdict of the schema 2 revision monotonic-increase comparison (contract section 7 revisionCases). */
internal enum class MetadataRevisionVerdict { Accept, Unchanged, Reject }

/**
 * Compares schema 2 bodies only: accept when the cache has no revision (schema 1) or the built-in 0; accept newer; treat equal as 304
 * (data unchanged, only the ETag is refreshed); reject older, keeping the cache and reporting.
 */
internal fun compareMetadataRevision(cached: Long?, incoming: Long): MetadataRevisionVerdict = when {
    cached == null || cached <= 0L -> MetadataRevisionVerdict.Accept
    incoming > cached -> MetadataRevisionVerdict.Accept
    incoming == cached -> MetadataRevisionVerdict.Unchanged
    else -> MetadataRevisionVerdict.Reject
}

/** Explicit grouping key so one failure phase is one group regardless of the call site. */
internal fun metadataFailureFingerprint(tags: Map<String, String>): List<String> =
    listOf(METADATA_FAILURE_MODULE, tags.tagOrUnknown("phase"), tags.tagOrUnknown("exception_class"))

/**
 * Catalog tombstone: a retired model (retiredModels[] on an index provider entry, contract model catalog and capability truth section 8).
 * [routedTo] is the successor model id given by the server; the client must still verify it is in the catalog and available before treating it as the successor.
 */
@Serializable
data class RetiredModel(
    val id: String,
    val displayName: String? = null,
    val retiredAt: String? = null,
    val routedTo: String? = null,
)

/** Read-only view of a schema 2 model lifecycle: only decodes the state / shutdownAt / routedTo that retirement checks need. */
data class ModelLifecycle(
    val state: String?,
    val shutdownAt: String?,
    val routedTo: String?,
) {
    companion object {
        /** Preserved lifecycle JsonObject to view; null when missing or not an object. */
        fun from(raw: JsonObject?): ModelLifecycle? {
            if (raw == null) return null
            fun field(key: String): String? =
                (raw[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull?.takeIf { it.isNotBlank() }
            return ModelLifecycle(state = field("state"), shutdownAt = field("shutdownAt"), routedTo = field("routedTo"))
        }
    }
}

class MetadataClient internal constructor(
    initialContext: Context? = null,
    private val backgroundScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val metadataCacheDao: MetadataCacheDao? = null,
    private val metadataTransport: MetadataTransport = HttpUrlConnectionMetadataTransport,
    /** When injected, the index + per-provider catalog views come first; lean is used only when an older server rejects view=index with 400. */
    private val metadataSplitTransport: MetadataSplitTransport? = null,
    private val modelFactsTransport: ModelFactsTransport = HttpUrlConnectionModelFactsTransport,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val failureReporter: (Map<String, String>) -> Unit = { tags ->
    },
    /**
     * Text of the shared metadata_payload.v2.schema.json; when null it is read once from the APK asset
     * [METADATA_PAYLOAD_SCHEMA_ASSET] on first use and cached. Injected in unit tests to avoid depending on Context.assets.
     */
    private val metadataPayloadSchemaText: String? = null,
    /**
     * Whether to adopt the schema 2 snapshot bundled in the APK ([BundledMetadata]) when a cold start has no cache and the fetch fails.
     * Follows the request schema by default (enabled when >= 2).
     */
    private val bundledFallbackEnabled: Boolean = METADATA_REQUEST_SCHEMA >= 2,
) {
    private val nonAutoReasoningModes = listOf(
        ReasoningMode.Fast,
        ReasoningMode.Balanced,
        ReasoningMode.Deep,
        ReasoningMode.Max,
    )

    data class ResolvedModelMetadata(
        val canonicalModelId: String,

        val modelRef: String? = null,

        val capabilityContractVersion: Int = 0,
        val displayName: String? = null,
        val contextLength: Int? = null,
        val maxOutputTokens: Int? = null,
        val supportsTemperature: Boolean? = null,
        val billingSku: String? = null,
        val pricingUnit: String = "per_token",
        val sourceSummary: ModelSourceSummary? = null,
        val pricingStatus: String = "unknown",
        val capabilities: List<ModelCapability> = emptyList(),
        val promptPerToken: Double? = null,
        val completionPerToken: Double? = null,
        val costPerUnit: Double? = null,
        val costInputBatches: Double? = null,
        val costOutputBatches: Double? = null,
        val costInputPriority: Double? = null,
        val costOutputPriority: Double? = null,
        val cacheReadInputPerMToken: Double? = null,
        val cacheCreationInputPerMToken: Double? = null,

        val cacheWrite5mPerMToken: Double? = null,

        val cacheWrite1hPerMToken: Double? = null,
        val profiles: ProfileRefs = ProfileRefs(),
        val supportsPdfInput: Boolean = false,
        val supportsServiceTier: Boolean = false,
        val uiHints: UIHints? = null,
        val isDefault: Boolean = false,
        val vendorKey: String? = null,
        val vendorName: String? = null,

        val toolCall: Boolean? = null,

        val transport: String? = null,

        val nativeFileMimes: List<String> = emptyList(),

        val pdfNativeDefault: Boolean = false,
        /** Attachment limits the catalog sets for this model (lines / bytes per file, total text, input file size); null when not set. */
        val attachmentExtraction: ai.oriveo.community.core.model.AttachmentExtractionLimits? = null,

        val capabilityEvidenceCandidates: List<CapabilityEvidenceCandidateView>? = null,

        val capabilityEvidenceOwnedKeys: Set<String>? = null,

        val capabilityEvidenceViewMalformed: Boolean? = null,
        /** The model entry's v2 `capabilityControls` is carried through unchanged and belongs to the same publication as the evidence candidates. */
        val capabilityControls: JsonObject? = null,
        /**
         * Long-context surcharge tier (pricing.longContext); null when the shape is bad or thresholdTokens is not a positive integer.
         * Only the window factory looks the threshold up on demand; it is never written into AIModel, Room, or backups.
         */
        val longContext: LongContextPricing? = null,
        /**
         * The model entry's `promptCache.policyRef`; null when missing or not a string.
         * Only used for outbound breakpoint decisions (official Anthropic applies cache_control only for `anthropic.explicit`); never written into AIModel or backups.
         */
        val promptCachePolicyRef: String? = null,
        /** The schema 2 parameter support table as is (parameter name -> {state, reasonCode, sourceRefs}); only used to compute the verdict revision for the param negative cache. */
        val parameterSupport: JsonObject? = null,
        /**
         * Model-level pricing v2; null when missing or malformed. Only used by
         * [ai.oriveo.community.core.provider.CostCalculator.calcCost] for local estimates; never written into AIModel or the Room projection.
         */
        val pricingV2: ai.oriveo.community.core.provider.PricingV2? = null,
        /** Model-level price currency (ISO 4217, as is); null when missing (= USD). */
        val currencyCode: String? = null,
        /**
         * Prices for other regions (contract section 5.7 regionPricing); bad entries are already dropped at decode. Only
         * [ai.oriveo.community.core.provider.RegionPricingSelector] replaces the five price keys by the connection's effective region.
         */
        val regionPricing: List<RegionPricingEntry> = emptyList(),
    ) {
        /** Replaces the five price keys wholesale with [price] (an entry without pricingV2 clears it); other fields are untouched. */
        fun withPrice(price: PriceKeys): ResolvedModelMetadata = copy(
            currencyCode = price.currencyCode,
            pricingStatus = price.pricingStatus,
            pricingUnit = price.pricingUnit,
            promptPerToken = price.promptPerToken,
            completionPerToken = price.completionPerToken,
            costPerUnit = price.costPerUnit,
            costInputBatches = price.costInputBatches,
            costOutputBatches = price.costOutputBatches,
            costInputPriority = price.costInputPriority,
            costOutputPriority = price.costOutputPriority,
            cacheReadInputPerMToken = price.cacheReadInputPerMToken,
            cacheCreationInputPerMToken = price.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken = price.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken = price.cacheWrite1hPerMToken,
            longContext = price.longContext,
            pricingV2 = price.pricingV2,
        )
    }

    /** The five price keys (currencyCode / pricingStatus / pricingUnit / pricing / pricingV2) after parsing; the model level and region entries share one convention. */
    data class PriceKeys(
        val currencyCode: String?,
        val pricingStatus: String,
        val pricingUnit: String,
        val promptPerToken: Double?,
        val completionPerToken: Double?,
        val costPerUnit: Double?,
        val costInputBatches: Double?,
        val costOutputBatches: Double?,
        val costInputPriority: Double?,
        val costOutputPriority: Double?,
        val cacheReadInputPerMToken: Double?,
        val cacheCreationInputPerMToken: Double?,
        val cacheWrite5mPerMToken: Double?,
        val cacheWrite1hPerMToken: Double?,
        val longContext: LongContextPricing?,
        val pricingV2: ai.oriveo.community.core.provider.PricingV2?,
    )

    /** One regionPricing entry: the [regionScope] region replaces the model-level price with [price]. */
    data class RegionPricingEntry(val regionScope: String, val price: PriceKeys)

    /** Once the input exceeds [thresholdTokens], the whole request is priced at this tier (USD per 1M tokens). */
    data class LongContextPricing(
        val thresholdTokens: Int,
        val promptPerMToken: Double,
        val completionPerMToken: Double,
        val cacheReadPerMToken: Double? = null,
    )

    data class CapabilityRecipeSelection(
        val id: String,

        val providerKind: String,
        val capability: String,
        val executionKind: String,
        val selectedIntent: String? = null,
        val availableIntents: List<String>? = null,
        val requestOps: List<CapabilityRecipeOperation>,
        val continuationKind: String? = null,
        val continuationVariant: String? = null,
        /** How `instructions` is handled when continuing with previous_id: resend | omit; null when missing or unknown (= send the full plan). */
        val continuationInstructionsMode: String? = null,
        val responseParserKind: String? = null,
        val responseEvidenceSignals: List<CapabilityResponseEvidenceSignal> = emptyList(),
        val runtimeRevision: String = "",
        val maxToolLoops: Int? = null,
        val route: JsonObject? = null,
        val formula: JsonObject? = null,
    )

    data class CapabilityRecipeOperation(
        val op: String,
        val pointer: String? = null,
        val intent: String? = null,
        val value: JsonElement? = null,
    )

    @Serializable
    data class CapabilityEvidenceCandidateView(
        val key: String,
        val support: String,
        val source: String,
        val grade: String,
        val scope: String,
        val providerKind: String,
        val modelId: String,
        val transport: String,
        val metadataRevision: String? = null,
        val generationRevision: String? = null,
        val evidenceRevision: String? = null,
        val observedAt: Long? = null,
        val expiresAt: Long? = null,
    )

    data class CurrentCapabilityEvidenceModel(
        val metadata: ResolvedModelMetadata,
        val metadataRevision: String?,

        val generationRevision: String?,
        val declaredReasoningLevels: Set<String>,
        val contentRevision: Long,
    )

    data class RefreshEvent(
        val version: Int,
        val contractVersion: Int,
        val contentRevision: Long = 0,
    )

    data class ProfileRefs(
        val reasoning: String? = null,
        val webSearch: String? = null,
        val imageGen: String? = null,
        val generation: GenerationProfileRef? = null,
    )

    data class UIHints(
        val groupKey: String? = null,
        val groupName: String? = null,
        val rank: Int? = null,
        val recommended: Boolean = false,
        val badgeOrder: List<ModelCapability>? = null,
    )

    @Serializable
    internal data class ProviderAttachmentSupport(
        val image: Boolean = false,
        val video: Boolean = false,
        val nativeFile: Boolean = false,
        val textFileInline: Boolean = false,
    )

    @Serializable
    data class ProviderRegionOption(
        val id: String,
        val label: String,
        val baseURL: String,
        val privacyPolicyURL: String? = null,
        val apiKeyHelpURL: String? = null,
    )

    /** Extra values the official setup page asks the user to fill; the client only recognizes a closed set of ids (`workspaceId`) and ignores the rest at the point of use. */
    @Serializable
    data class ProviderSetupField(
        val id: String = "",
        val required: Boolean = false,
    )

    @Serializable
    data class PublicProviderConfig internal constructor(
        val kind: String,
        val displayName: String,
        val shortName: String? = null,
        val selectionLabel: String? = null,
        val autoFillNote: String? = null,
        val defaultBaseURL: String,
        val apiKeyPlaceholder: String? = null,
        val apiKeyHelpURL: String? = null,
        val apiProtocol: String? = null,
        val protocolFeatures: kotlinx.serialization.json.JsonObject? = null,
        val category: String? = null,
        val supportsAutoSync: Boolean? = null,
        internal val attachmentSupport: ProviderAttachmentSupport? = null,
        val regionOptions: List<ProviderRegionOption>? = null,
        val sortOrder: Int? = null,
        /** Trusted host suffixes of this provider. Missing is the same as empty: only the registrable domain of the built-in fallback address is trusted. */
        val trustedHosts: List<String>? = null,
        /** Extra fields of the setup page. Missing is the same as null: none. */
        val setupFields: List<ProviderSetupField>? = null,
    )

    @Serializable
    internal data class RelayTransportEnvelope(
        val image: Boolean = false,
        val nativeFile: Boolean = false,
        val textFileInline: Boolean = false,
        val webSearch: Boolean = false,
        val imageGeneration: Boolean = false,
        val reasoning: Boolean = false,
    )

    @Serializable
    private data class RawRelayTransportEnvelope(
        val image: Boolean? = null,
        val nativeFile: Boolean? = null,
        val textFileInline: Boolean? = null,
        val webSearch: Boolean? = null,
        val imageGeneration: Boolean? = null,
        val reasoning: Boolean? = null,
    )

    data class RelayTransportRule(
        val providerPriority: String?,
        val defaultAuthMode: String,
        val defaultVersion: String,
        val acceptedVersions: List<String>,
        val headerProfile: String,
        val codexIdentityDefault: Boolean,
        val webSearchToolName: String,
        val imageRoute: String,
        val forceStreamForImageGeneration: Boolean,
        /** Codex CLI version issued by the Server (only openai_responses carries it); unvalidated, consumers go through [ai.oriveo.community.core.provider.RelayRuntimeSupport.codexClientVersion]. */
        val codexClientVersion: String? = null,
    )

    @Serializable
    private data class RawRelayTransportRule(
        val providerPriority: String? = null,
        val defaultAuthMode: String? = null,
        val defaultVersion: String? = null,
        val acceptedVersions: List<String>? = null,
        val headerProfile: String? = null,
        val codexIdentityDefault: Boolean? = null,
        val webSearchToolName: String? = null,
        val imageRoute: String? = null,
        val forceStreamForImageGeneration: Boolean? = null,
        val codexClientVersion: String? = null,
    )

    @Serializable
    data class RelayVerificationPolicy(
        val hardFailedExpiryDays: Int = 7,
        val softFailedRetryAfterSeconds: Int = 60,
        val verifiedCacheDays: Int = 30,
    )

    @Serializable
    data class RelayFeatureGatingPolicy(
        val showActualModelIdHint: Boolean = true,
        val showSoftFailHint: Boolean = true,
    )

    /**
     * Relay runtime rules. Clients only consume them; missing config or fields fall back field by field to [FALLBACK_RELAY_RUNTIME_CONFIG].
     * Change-driven: after the backend bumps [version], the next /api/metadata refresh takes effect.
     */
    internal data class RelayRuntimeConfig(
        val version: String,
        val officialProviderWhitelist: List<String>,
        val transportEnvelopes: Map<String, RelayTransportEnvelope>,
        val transportRules: Map<String, RelayTransportRule>,
        val verificationPolicy: RelayVerificationPolicy,
        val featureGatingPolicy: RelayFeatureGatingPolicy,
    )

    @Serializable
    private data class RawRelayRuntimeConfig(
        val version: String? = null,
        val officialProviderWhitelist: List<String>? = null,
        val transportEnvelopes: Map<String, RawRelayTransportEnvelope>? = null,
        val transportRules: Map<String, RawRelayTransportRule>? = null,
        val verificationPolicy: RelayVerificationPolicy? = null,
        val featureGatingPolicy: RelayFeatureGatingPolicy? = null,
    )

    enum class RelayCatalogMatchSource(val value: String) {
        TransportFirst("transport_first"),
        CrossProvider("cross_provider"),
    }

    data class RelayCatalogMatchResult(
        val matchedProviderKind: ProviderKind,
        val canonicalModelId: String,
        val metadata: ResolvedModelMetadata,
        val source: RelayCatalogMatchSource,
    )

    @Serializable
    private data class ModelPricing(
        val promptPerMToken: Double? = null,
        val completionPerMToken: Double? = null,
        val cachedInputPerMToken: Double? = null,
        val costPerUnit: Double? = null,
        val costInputBatches: Double? = null,
        val costOutputBatches: Double? = null,
        val costInputPriority: Double? = null,
        val costOutputPriority: Double? = null,
        val cacheReadInputPerMToken: Double? = null,
        val cacheCreationInputPerMToken: Double? = null,

        val cacheWrite5mPerMToken: Double? = null,
        val cacheWrite1hPerMToken: Double? = null,
        // The long-context tier is received as a raw JsonElement and parsed leniently by [decodeLongContext]:
        // a bad shape drops only this one field instead of failing the whole model (or the whole metadata payload).
        val longContext: JsonElement? = null,
    )

    @Serializable
    private data class ModelProfileRefs(
        val reasoning: String? = null,
        val webSearch: String? = null,
        val imageGen: String? = null,
        val generation: GenerationProfileRef? = null,
    )

    @Serializable
    private data class ModelUIHints(
        val groupKey: String? = null,
        val groupName: String? = null,
        val rank: Int? = null,
        val recommended: Boolean? = null,
        val badgeOrder: List<String>? = null,
    )

    @Serializable
    data class StreamShape(
        val reasoningDeltaPath: String? = null,
        val citationsBlockType: String? = null,
        val citationsArrayPath: String? = null,
        val citationUrlField: String? = null,
        val citationTitleField: String? = null,
        val citationSnippetField: String? = null,
        val imageDataPath: String? = null,
    )

    @Serializable
    data class TransportEndpoints(
        val chat: String? = null,
        val responses: String? = null,
        val images: String? = null,
        val embeddings: String? = null,
        val files: String? = null,
    )

    @Serializable
    data class ProviderTransport(
        val baseUrl: String,
        val endpoints: TransportEndpoints = TransportEndpoints(),
    )

    @Serializable
    private data class ReasoningProfileDefinition(
        val transport: String? = null,
        val fallbackProfile: String? = null,
        val levels: List<String>? = null,

        val defaultLevel: String? = null,
        val params: Map<String, JsonObject>? = null,
        val streamShape: StreamShape? = null,
    )

    @Serializable
    private data class WebSearchProfileDefinition(
        val mergeParams: kotlinx.serialization.json.JsonObject? = null,
        val streamShape: StreamShape? = null,
        val maxToolLoops: Int? = null,
    )

    @Serializable
    private data class ImageGenProfileDefinition(

        val route: String? = null,
        val mergeParams: kotlinx.serialization.json.JsonObject? = null,
        val requestDefaults: kotlinx.serialization.json.JsonObject? = null,
        val streamShape: StreamShape? = null,
    )

    @Serializable
    private data class ProfileDefinitions(
        val reasoning: Map<String, ReasoningProfileDefinition> = emptyMap(),

        val webSearch: Map<String, WebSearchProfileDefinition> = emptyMap(),
        val imageGen: Map<String, ImageGenProfileDefinition> = emptyMap(),
        val generation: GenerationProfileDefinitions? = null,
    )

    @Serializable
    private data class GenerationProfileDefinitions(
        val version: Int? = null,
        val parameters: Map<String, GenerationParameterDefinition> = emptyMap(),
        val templates: Map<String, GenerationTemplateDefinition> = emptyMap(),
    )

    @Serializable
    private data class GenerationParameterDefinition(
        val group: String? = null,
        val valueSchema: String? = null,
        val range: GenerationParameterRange? = null,
        val enumValues: List<kotlinx.serialization.json.JsonElement> = emptyList(),
        val fixedValue: kotlinx.serialization.json.JsonElement? = null,
        val defaultDescription: kotlinx.serialization.json.JsonElement? = null,
        val interactionGroup: String? = null,
        val conflictsWith: List<String> = emptyList(),
        val requires: List<kotlinx.serialization.json.JsonObject> = emptyList(),
        val constraints: List<kotlinx.serialization.json.JsonObject> = emptyList(),
        val portability: String? = null,
        val risk: String? = null,
    )

    @Serializable
    private data class GenerationTemplateDefinition(
        val transport: String? = null,
        val wire: Map<String, String> = emptyMap(),
    )

    private fun resolveGenerationProfile(
        reference: GenerationProfileRef?,
        definitions: GenerationProfileDefinitions?,
        parameterTables: Map<String, List<GenerationParameterRef>>?,
    ): GenerationProfileRef? {
        val template = reference?.template?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val templateDefinition = definitions?.templates?.get(template) ?: return null
        if (templateDefinition.wire.isEmpty()) return null

        val parameters = if (reference.parametersRef != null) {
            val parametersRef = reference.parametersRef.trim().takeIf { it.isNotEmpty() }
            parametersRef?.let { parameterTables?.get(it) }.orEmpty()
        } else {
            reference.parameters
        }
        // A model-level wire path replaces the template path for that one model only; when it is
        // invalid the parameter has no write path at all and never falls back to the template.
        val wire = templateDefinition.wire.toMutableMap()
        parameters.forEach { parameter ->
            val id = parameter.id?.trim()?.takeIf { it.isNotEmpty() } ?: return@forEach
            val override = parameter.wire?.trim()?.takeIf { it.isNotEmpty() } ?: return@forEach
            val rejection = GenerationParameterResolver.wireRejectionReason(override)
            if (rejection == null) {
                wire[id] = override
            } else {
                wire.remove(id)
                GenerationParameterResolver.recordWireRejection(id, override, rejection, dedupe = true)
            }
        }
        return reference.copy(
            template = template,
            wire = wire,
            transport = templateDefinition.transport,
            parameters = parameters.map { parameter ->
                val id = parameter.id?.trim()?.takeIf { it.isNotEmpty() } ?: return@map parameter
                val definition = definitions.parameters[id] ?: return@map parameter.copy(id = id)
                parameter.copy(
                    id = id,
                    group = definition.group,
                    valueSchema = definition.valueSchema,
                    // A model-level range / conflictsWith replaces the platform one as a whole (no
                    // per-key merge); when absent the platform value applies.
                    range = parameter.range ?: definition.range,

                    enumValues = parameter.enumValues.ifEmpty { definition.enumValues },
                    fixedValue = definition.fixedValue,
                    defaultDescription = definition.defaultDescription,
                    interactionGroup = definition.interactionGroup,
                    conflictsWith = parameter.conflictsWith.ifEmpty { definition.conflictsWith },
                    requires = definition.requires,
                    constraints = definition.constraints,
                    portability = definition.portability,
                    risk = definition.risk,
                )
            },
        )
    }

    @Serializable
    private data class ModelData(
        val canonicalModelId: String? = null,
        val modelRef: String? = null,
        val aliases: List<String>? = null,
        val displayName: String? = null,
        val contextLength: Int? = null,
        val maxOutputTokens: Int? = null,
        val supportsTemperature: Boolean? = null,
        val billingSku: String? = null,
        val pricingUnit: String? = null,
        val sourceSummary: ModelSourceSummary? = null,
        val pricing: ModelPricing? = null,
        val pricingStatus: String? = null,
        val capabilities: List<ModelCapability>? = null,
        val supportsPdfInput: Boolean? = null,
        val supportsServiceTier: Boolean? = null,
        val profiles: ModelProfileRefs? = null,
        val uiHints: ModelUIHints? = null,

        val vendorKey: String? = null,
        val vendorName: String? = null,
        val toolCall: Boolean? = null,

        val transport: String? = null,

        val nativeFileMimes: List<String>? = null,

        val pdfNativeDefault: Boolean? = null,
        /** Per-model attachment limit overrides; every field is optional. */
        val attachmentExtraction: ai.oriveo.community.core.model.AttachmentExtractionLimits? = null,

        val capabilityEvidenceView: JsonElement? = JsonPrimitive(CAPABILITY_EVIDENCE_ABSENT),
        val capabilityEvidenceCandidates: List<CapabilityEvidenceCandidateView>? = null,
        val capabilityEvidenceOwnedKeys: List<String>? = null,
        val capabilityEvidenceViewMalformed: Boolean? = null,

        val capabilityControls: JsonObject? = null,
        /** Schema 2: model lifecycle (state / shutdownAt / signal), kept as is so it survives a Room round trip. */
        val lifecycle: JsonObject? = null,
        /** Schema 2: parameter support table, kept as is so it survives a Room round trip. */
        val parameterSupport: JsonObject? = null,
        /** Prompt cache policy (policyRef -> cachePolicies); kept as is so it survives a Room round trip, only serves outbound breakpoints. */
        val promptCache: JsonObject? = null,
        /** Pricing v2 is received as a raw JsonElement and parsed leniently by [ai.oriveo.community.core.provider.PricingV2Estimator.parse]: a bad shape drops only this one field. */
        val pricingV2: JsonElement? = null,
        /** Model-level price currency; missing = USD. */
        val currencyCode: String? = null,
        /** Prices for other regions are received as a raw JsonElement and parsed leniently per entry: a bad entry drops only itself (contract section 5.7). */
        val regionPricing: JsonElement? = null,
    ) {
        /** Read-only view of lifecycle state / shutdownAt / routedTo (used for retirement checks). */
        fun lifecycleInfo(): ModelLifecycle? = ModelLifecycle.from(lifecycle)
    }

    @Serializable
    private data class ProviderData(
        val displayName: String? = null,
        val attachmentSupport: ProviderAttachmentSupport? = null,
        val defaultModelId: String? = null,
        val validation: ProviderValidation? = null,
        val resolveMap: Map<String, String>? = null,
        val models: Map<String, ModelData> = emptyMap(),

        val transport: ProviderTransport? = null,
        /** Catalog tombstones (only sent under index provider entries, merged as is by assembleLeanData); empty by default. */
        val retiredModels: List<RetiredModel>? = null,
    )

    @Serializable
    data class SelfHealPattern(
        val pattern: String = "",
        val flags: String? = null,
        val param: String? = null,
    )

    @Serializable
    private data class RuntimeConfig(
        val featureFlags: Map<String, Boolean>? = null,
        val selfHealPatterns: List<SelfHealPattern> = emptyList(),
    )

    @Serializable
    data class ProviderValidation(

        val probe: String? = null,

        val probePath: String? = null,

        val authMode: String? = null,

        /** Auth used for chat requests. Gemini sends `x_goog_api_key`; when present the probe uses that header. */
        val chatAuthMode: String? = null,

        val headerProfile: String? = null,

        val invalidKeySignals: List<InvalidKeySignal> = emptyList(),
    )

    @Serializable
    data class InvalidKeySignal(
        val status: Int? = null,

        val bodyIncludes: List<String> = emptyList(),
    )

    @Serializable
    private data class MetadataResponse(
        val version: Int = 0,

        val view: String? = null,

        val contractVersion: Int = 0,

        val capabilityContractVersion: Int = 0,
        val updatedAt: String? = null,
        val profiles: ProfileDefinitions = ProfileDefinitions(),
        val generationParameterTables: Map<String, List<GenerationParameterRef>>? = null,
        val providers: Map<String, ProviderData> = emptyMap(),
        val providerConfigs: List<PublicProviderConfig>? = null,
        val relayRuntimeConfig: RawRelayRuntimeConfig? = null,
        val runtimeConfig: RuntimeConfig? = null,
        /**
         * Runtime limits for remote MCP. Kept as is; `McpRuntimeConfig.fromJson` clamps each
         * field to its bounds when it is read.
         */
        val mcpRuntimeConfig: JsonObject? = null,

        val capabilityRuntime: JsonObject? = null,
        /** Facts published alongside the catalog; artifactHash is deliberately not decoded. */
        val modelFacts: Map<String, ModelFacts>? = null,
        val modelFactsRevision: String? = null,
        /** Schema 2 revision field; null when missing (schema 1), and not written when encoding to keep the historical byte shape. */
        val metadataSchema: Int? = null,
        /**
         * Wire name `metadataRevision` (the server-published revision). The property is named differently to avoid confusion with the
         * client's own ETag-derived `metadataRevision` identity.
         */
        @SerialName("metadataRevision")
        val payloadRevision: Long? = null,
        val generatedAt: String? = null,
        val rollbackOf: Long? = null,
    )

    @Serializable
    data class ModelFacts(
        val toolCall: Boolean? = null,
        val reasoning: Boolean? = null,
        val reasoningEfforts: List<String>? = null,
        val reasoningToggle: Boolean? = null,
        val modalities: ModelFactsModalities? = null,
        val attachment: Boolean? = null,
        val source: String? = null,
    )

    @Serializable
    data class ModelFactsModalities(
        val input: List<String>? = null,
        val output: List<String>? = null,
    )

    /** Optional wrapper around a bundled [MetadataResponse]. */
    @Serializable
    private data class WrappedResponse(
        val data: MetadataResponse,
    )

    @Serializable
    private data class ModelFactsEndpointData(
        val revision: String,
        val facts: Map<String, ModelFacts>,
    )

    @Serializable
    private data class WrappedModelFactsResponse(
        val data: ModelFactsEndpointData,
    )

    @Serializable
    private data class CacheEntry(
        val data: MetadataResponse,
        val timestamp: Long,
    )

    @Serializable
    private data class RoomCacheEnvelope(
        val data: MetadataResponse,
        val timestamp: Long,
        val eTag: String? = null,
        val modelFactsETag: String? = null,
    )

    /** The `index` row: the index data as served plus its ETag; the row's updatedAtMs is the timestamp. */
    @Serializable
    private data class SplitIndexCacheEnvelope(
        val eTag: String? = null,
        val data: JsonObject,
    )

    /**
     * A `catalog:<provider>` row: the catalog data as served. Refs are validated again on read,
     * so the cache itself is never trusted.
     */
    @Serializable
    private data class CatalogCacheEnvelope(
        val eTag: String? = null,
        val data: JsonObject,
        /** metadataRevision of a schema 2 body; null for schema 1 / old rows. Written atomically in the same row as the snapshot and ETag. */
        val payloadRevision: Long? = null,
        /**
         * The source body's metadataSchema: recorded as 2 in data after schema 3 expansion, so cross-schema decisions rely on this;
         * an old row without it counts as 2 (before upgrade only schema 1 / 2 were stored, and schema 1 has no revision and does not take part in comparison).
         */
        val payloadSchema: Int? = null,
    )

    /** In split mode the model-facts sidecar has its own row instead of riding along with the snapshot. */
    @Serializable
    private data class ModelFactsCacheEnvelope(
        val eTag: String? = null,
        val revision: String? = null,
        val facts: Map<String, ModelFacts>? = null,
    )

    private data class JsonKeyScan(
        val nextIndex: Int,
        val matchesData: Boolean,
    )

    private val PREFS_NAME = "oriveo_metadata"
    private val PREFS_KEY = "oriveo:metadataCache"
    private val ETAG_KEY = "oriveo:metadataETag"
    private val CACHE_TTL_MS = 24 * 60 * 60 * 1000L

    private val VALID_CAPABILITIES = setOf(
        ModelCapability.Reasoning,
        ModelCapability.Text,
        ModelCapability.Image,
        ModelCapability.Video,
        ModelCapability.File,
        ModelCapability.Web,
        ModelCapability.ImageGen,
    )
    private val SNAPSHOT_DATE_PATTERNS = listOf(
        Regex("-\\d{8}$"),
        Regex("-\\d{4}-\\d{2}-\\d{2}$"),
    )

    private val kindMap = mapOf(
        "openAI" to "openAI",
        "anthropic" to "anthropic",
        "gemini" to "gemini",
        "deepseek" to "deepseek",
        "grok" to "grok",
        "openRouter" to "openRouter",
        "groq" to "groq",
        "together" to "togetherAI",
        "fireworks" to "fireworksAI",
        "miniMax" to "miniMax",
        "zhipu" to "zhipu",
        "qwen" to "qwen",
        "moonshot" to "moonshot",
        "mistral" to "mistral",
        "siliconFlow" to "siliconFlow",
    )

    private val initMutex = Mutex()
    private val fetchMutex = Mutex()
    private val modelFactsFetchMutex = Mutex()

    private val _refreshEvents = MutableSharedFlow<RefreshEvent>(
        replay = 1,
        extraBufferCapacity = 4,
    )

    val refreshEvents: Flow<RefreshEvent> = _refreshEvents.asSharedFlow()

    @Volatile
    private var table: MetadataResponse? = null

    @Volatile
    private var storedETag: String? = null

    @Volatile
    private var storedModelFactsETag: String? = null

    private data class EvidencePublication(
        val table: MetadataResponse?,
        val metadataRevision: String?,
        val contentRevision: Long,
        /**
         * Providers (backend keys) whose model catalog is actually present in this snapshot.
         * null = a lean snapshot where everything is loaded. Non-null = a split snapshot: a
         * provider listed in `providers` but missing here has a catalog that is not loaded yet
         * (pending), which must never be read as "the model is not in the catalog". Published
         * together with [table].
         */
        val loadedProviderKeys: Set<String>? = null,
    )

    @Volatile
    private var evidencePublication = EvidencePublication(null, null, 0)

    @Volatile
    private var pendingRefresh: Job? = null

    // Index + per-provider catalog state; written only while holding fetchMutex.

    private class SplitIndexState(
        val data: JsonObject,
        val eTag: String?,
        val catalogRevisions: Map<String, String>,
    )

    private class LoadedCatalog(
        val eTag: String?,
        val catalog: MetadataCatalogAssembly.ExpandedCatalog,
        val payloadRevision: Long? = null,
        /** Same as [CatalogCacheEnvelope.payloadSchema]. */
        val payloadSchema: Int? = null,
    )

    @Volatile
    private var splitIndex: SplitIndexState? = null

    /** Validated catalogs (last good), keyed by backend provider key. */
    private val loadedCatalogs = java.util.concurrent.ConcurrentHashMap<String, LoadedCatalog>()

    /**
     * The older single-row lean cache (or a full payload from the lean fallback), kept as last
     * good after switching to split: a provider whose catalog has not arrived yet uses its models
     * from here until every needed catalog is in, then this is dropped.
     */
    @Volatile
    private var legacyLeanFallback: MetadataResponse? = null

    /** Catalogs confirmed with the server this session (200, 304, or revision equal to a confirmed index). */
    private val confirmedCatalogKeys: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

    /** Providers needed ad hoc this session (being added, restored, pending on a route); merged into later syncs. */
    private val sessionRequestedCatalogKeys: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

    /** Dedupes pending-triggered single fetches: at most one automatic fetch per provider per refresh round, no spinning on failure. */
    private val autoRequestedCatalogKeys: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

    /** Where the needed catalog set comes from: the configured providers and whether a relay exists (supplied at app start). */
    data class CatalogDemand(
        val providerKinds: Set<ProviderKind>,
        val hasRelay: Boolean,
    )

    @Volatile
    var catalogDemandSupplier: (suspend () -> CatalogDemand)? = null

    /** Load state of one provider's catalog. Only when [Loaded] does "not found" mean "not in the catalog". */
    enum class CatalogLoadState {
        /** No metadata snapshot at all yet (cold start in progress or loading failed): the usual "metadata unavailable". */
        Unavailable,
        /** The index says this provider has a catalog but it has not arrived; a fetch of just this provider has been started. */
        Pending,
        Loaded,
        /** The current snapshot has no such provider (relay, or not served). */
        Absent,
    }

    @Volatile
    private var appContext: Context? = initialContext?.applicationContext

    @Volatile
    private var _snapshotConfirmedThisSession = false

    val version: Int get() = table?.version ?: 0

    val contractVersion: Int get() = table?.contractVersion ?: 0

    val capabilityContractVersion: Int get() = table?.capabilityContractVersion ?: 0

    val isContractVersionSupported: Boolean
        get() {
            val version = contractVersion

            if (version == 0) return true
            return version in (SUPPORTED_CONTRACT_VERSION - 1)..(SUPPORTED_CONTRACT_VERSION + 1)
        }

    val isContractVersionDegraded: Boolean
        get() {
            val version = contractVersion
            if (version == 0) return false
            return version >= SUPPORTED_CONTRACT_VERSION + 2
        }

    enum class MetadataSource {

        Unknown,

        CachedOffline,

        FreshNetwork,
    }

    @Volatile
    private var _metadataSource: MetadataSource = MetadataSource.Unknown

    val metadataSource: MetadataSource get() = _metadataSource

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true

        coerceInputValues = true
    }

    private fun reportFailure(
        phase: String,
        startedAtMs: Long,
        responseBytes: Long,
        statusCode: Int?,
        error: Throwable,
        /** Extra tags for schema 2 entry-level reports (reason / provider_kind / model_id / instance_path / keyword); locations only, no values. */
        extraTags: Map<String, String> = emptyMap(),
    ) {

        if (error.isTransientNetworkOrCancellation()) return
        failureReporter(
            mapOf(
                "phase" to phase,
                "duration_ms" to (nowMillis() - startedAtMs).coerceAtLeast(0L).toString(),
                "response_bytes" to responseBytes.coerceAtLeast(0L).toString(),
                "status" to (statusCode?.toString() ?: "none"),
                "exception_class" to error.javaClass.simpleName.ifBlank { error.javaClass.name },

                "has_snapshot" to (table != null).toString(),
            ) + extraTags
        )
    }

    private val payloadSchemaLock = Any()

    @Volatile
    private var payloadSchemaValidator: MetadataPayloadSchemaValidator? = null

    /** Schema 2 validator: the schema text is read only once; failing to read or parse throws, and the caller treats it as a decode failure (keeping last-good). */
    private fun payloadSchemaValidator(): MetadataPayloadSchemaValidator {
        payloadSchemaValidator?.let { return it }
        return synchronized(payloadSchemaLock) {
            payloadSchemaValidator ?: run {
                val text = metadataPayloadSchemaText
                    ?: (appContext ?: throw IllegalStateException("metadata payload schema unavailable"))
                        .assets.open(METADATA_PAYLOAD_SCHEMA_ASSET).bufferedReader().use { it.readText() }
                MetadataPayloadSchemaValidator(json.parseToJsonElement(text)).also { payloadSchemaValidator = it }
            }
        }
    }

    /** Schema 2 and 3 both go through the shared schema check and revision: 3 is just the compact form (the catalog is expanded to 2 first, the index only lacks retiredModels). */
    private fun isMetadataSchemaV2(data: JsonObject): Boolean =
        (data["metadataSchema"] as? JsonPrimitive)?.intOrNull in 2..3

    /** Entry-level schema failure: drops only that entry and reports; tags carry only provider / modelId / the first instancePath + keyword. */
    private fun reportEntryInvalid(
        code: String,
        phase: String,
        startedAtMs: Long,
        responseBytes: Long,
        statusCode: Int?,
        provider: String,
        modelId: String?,
        error: MetadataPayloadSchemaValidator.SchemaError,
    ) {
        val tags = linkedMapOf(
            "reason" to code,
            "provider_kind" to catalogProviderKindLabel(provider),
            "instance_path" to error.instancePath,
            "keyword" to error.keyword,
        )
        modelId?.let { tags["model_id"] = it }
        reportFailure(phase, startedAtMs, responseBytes, statusCode, MetadataEntryInvalidException(code), tags)
    }

    /** Lowercase provider label of the catalog diagnostics: the catalog key mapped to its ProviderKind name, `index` kept as is, unknown keys lowercased. */
    private fun catalogProviderKindLabel(provider: String): String =
        if (provider == INDEX_REVISION_PROVIDER) {
            provider
        } else {
            ProviderKind.entries.firstOrNull { catalogKeyFor(it) == provider }?.name?.lowercase() ?: provider.lowercase()
        }

    private class MetadataEntryInvalidException(code: String) : IllegalStateException("metadata $code")

    private class MetadataRevisionRegressedException(provider: String) :
        IllegalStateException("metadata $REVISION_REGRESSED: $provider")

    /** The body's metadataSchema; null when missing (schema 1). */
    private fun bodyMetadataSchema(data: JsonObject): Int? = (data["metadataSchema"] as? JsonPrimitive)?.intOrNull

    private fun schemaV2Revision(data: JsonObject): Long? =
        if (isMetadataSchemaV2(data)) (data["metadataRevision"] as? JsonPrimitive)?.longOrNull else null

    /** Revision regression: reject and keep the cache, report revision_regressed (index-level provider is `index`). */
    private fun reportRevisionRegressed(
        phase: String,
        startedAtMs: Long,
        responseBytes: Long,
        statusCode: Int?,
        provider: String,
    ) {
        reportFailure(
            phase, startedAtMs, responseBytes, statusCode,
            MetadataRevisionRegressedException(provider),
            mapOf("reason" to REVISION_REGRESSED, "provider_kind" to catalogProviderKindLabel(provider)),
        )
    }

    private fun legacyPreferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun decodeLegacyCache(context: Context): RoomCacheEnvelope? {
        val prefs = legacyPreferences(context)
        val encoded = prefs.getString(PREFS_KEY, null) ?: return null
        val startedAtMs = nowMillis()
        return try {
            val entry = json.decodeFromString<CacheEntry>(encoded)
            RoomCacheEnvelope(
                data = entry.data,
                timestamp = entry.timestamp,
                eTag = prefs.getString(ETAG_KEY, null),
            )
        } catch (error: Exception) {
            reportFailure("cache_decode", startedAtMs, encoded.length.toLong(), null, error)
            null
        } catch (error: Error) {
            reportFailure("cache_decode", startedAtMs, encoded.length.toLong(), null, error)
            throw error
        }
    }

    private fun decodeRoomCache(payload: String): RoomCacheEnvelope? {
        val startedAtMs = nowMillis()
        return try {
            json.decodeFromString<RoomCacheEnvelope>(payload)
        } catch (error: Exception) {
            reportFailure("cache_decode", startedAtMs, payload.length.toLong(), null, error)
            null
        } catch (error: Error) {
            reportFailure("cache_decode", startedAtMs, payload.length.toLong(), null, error)
            throw error
        }
    }

    private suspend fun readPersistedPayload(
        dao: MetadataCacheDao,
        key: String = MetadataCacheEntity.SINGLETON_KEY,
    ): String? {
        val length = dao.payloadLength(key) ?: return null
        if (length <= 0) return null
        val builder = StringBuilder(length)
        var readChars = 0
        while (readChars < length) {
            val chunk = dao.payloadChunk(readChars + 1, PAYLOAD_CHUNK_CHARS, key) ?: return null
            if (chunk.isEmpty()) break
            builder.append(chunk)
            readChars += chunk.codePointCount(0, chunk.length)
        }
        val payload = builder.toString()
        return payload.takeIf { it.codePointCount(0, it.length) == length }
    }

    private fun clearLegacyPreferences(context: Context) {
        legacyPreferences(context).edit().remove(PREFS_KEY).remove(ETAG_KEY).apply()
    }

    private suspend fun loadPersistedCache(context: Context): RoomCacheEnvelope? {
        val dao = metadataCacheDao ?: return decodeLegacyCache(context)
        val startedAtMs = nowMillis()
        val roomPayload = try {
            readPersistedPayload(dao)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_read", startedAtMs, 0L, null, error)
            return decodeLegacyCache(context)
        } catch (error: Error) {
            reportFailure("cache_read", startedAtMs, 0L, null, error)
            throw error
        }

        roomPayload?.let { payload ->
            decodeRoomCache(payload)?.let { cached ->
                clearLegacyPreferences(context)
                return cached
            }
            try {
                dao.clear()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                reportFailure("cache_clear", startedAtMs, 0L, null, error)
            } catch (error: Error) {
                reportFailure("cache_clear", startedAtMs, 0L, null, error)
                throw error
            }
        }

        val legacy = decodeLegacyCache(context)
        if (legacy == null) {
            clearLegacyPreferences(context)
            return null
        }

        return try {
            persistCache(legacy)
            clearLegacyPreferences(context)
            legacy
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {

            reportFailure("cache_migration", startedAtMs, 0L, null, error)
            legacy
        } catch (error: Error) {
            reportFailure("cache_migration", startedAtMs, 0L, null, error)
            throw error
        }
    }

    private suspend fun clearPersistedCache(context: Context) {
        val startedAtMs = nowMillis()
        try {
            metadataCacheDao?.clear()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {

            try {
                reportFailure("cache_clear", startedAtMs, 0L, null, error)
            } catch (reportingFailure: Throwable) {
                error.addSuppressed(reportingFailure)
            }
        } catch (error: Error) {
            try {
                reportFailure("cache_clear", startedAtMs, 0L, null, error)
            } catch (reportingFailure: Throwable) {
                error.addSuppressed(reportingFailure)
            }
            throw error
        }
        clearLegacyPreferences(context)
    }

    suspend fun initialize(context: Context) {
        appContext = context.applicationContext

        initMutex.withLock {
            // The bundled snapshot is only a placeholder: still refetch via the cold path, any online response may override it.
            if (table != null && !bundledSnapshotActive) return

            val splitCache = if (metadataSplitTransport != null) loadSplitCache() else null
            val cached = loadPersistedCache(context)
            if (splitCache == null && cached == null) {
                // No usable cache is the cold path: no leftover ETag may turn an empty table into a 304.
                fetchMetadata(bypassETag = true)
                adoptBundledSnapshotIfEmpty(context)
                return
            }
            // Cache bucketing: a cached contractVersion outside the compatible window
            // [SUPPORTED_CONTRACT_VERSION - 1, SUPPORTED_CONTRACT_VERSION + 1] is discarded
            // and the catalog is fetched again.
            val primaryContract = splitCache?.contractVersion ?: cached!!.data.contractVersion
            if (!isCachedContractInWindow(primaryContract)) {
                // An out-of-window contract is a cold path: drop the rows and the legacy
                // preferences, then fetch in full without carrying the old ETag.
                clearPersistedCache(context)
                fetchMetadata(bypassETag = true)
                return
            }
            val safeCached = cached
                ?.takeIf { isCachedContractInWindow(it.data.contractVersion) }
                ?.let { legacy ->
                    normalizeMetadataEvidenceViews(
                        data = legacy.data,
                        metadataRevision = legacy.eTag,
                        acceptPersistedProjection = true,
                    )
                }
            val cachedAtMs: Long
            val hydratedSplit = splitCache != null && hydrateSplitCache(splitCache, cached, safeCached)
            if (hydratedSplit) {
                cachedAtMs = splitCache.updatedAtMs
            } else {
                val legacy = cached
                val safe = safeCached
                if (legacy == null || safe == null) {
                    fetchMetadata(bypassETag = true)
                    return
                }
                val persistedETag = legacy.eTag
                table = safe
                _metadataSource = MetadataSource.CachedOffline
                storedETag = persistedETag
                storedModelFactsETag = legacy.modelFactsETag
                evidencePublication = EvidencePublication(
                    table = safe,
                    metadataRevision = persistedETag,
                    contentRevision = evidencePublication.contentRevision + 1,
                )
                // Emit once after hydrating from the local cache so subscribers can render it
                // before the network round trip finishes.
                _refreshEvents.tryEmit(
                    RefreshEvent(
                        version = safe.version,
                        contractVersion = safe.contractVersion,
                        contentRevision = evidencePublication.contentRevision,
                    )
                )
                // A 304 refreshes only the row's updatedAtMs, not the timestamp inside the
                // envelope, so take the newer of the two.
                cachedAtMs = maxOf(legacy.timestamp, legacyRowUpdatedAtMs())
            }
            if (nowMillis() - cachedAtMs < CACHE_TTL_MS) {
                pendingRefresh = backgroundScope.launch {
                    fetchMetadata(bypassETag = false)
                    pendingRefresh = null
                }
                return
            }
            fetchMetadata(bypassETag = false)
        }
    }

    /** The split cache wins; the older lean row only covers providers whose catalog is still missing. A bad cache never blocks startup. */
    private suspend fun hydrateSplitCache(
        splitCache: SplitCacheSnapshot,
        cached: RoomCacheEnvelope?,
        safeCached: MetadataResponse?,
    ): Boolean {
        splitIndex = splitCache.index
        loadedCatalogs.putAll(splitCache.catalogs)
        legacyLeanFallback = safeCached
        val facts = splitCache.modelFacts
        storedModelFactsETag = if (facts != null) facts.eTag else cached?.modelFactsETag
        val startedAtMs = nowMillis()
        return try {
            publishSplitSnapshot(
                index = splitCache.index,
                indexConfirmed = false,
                modelFacts = if (facts != null) facts.facts else safeCached?.modelFacts,
                modelFactsRevision = if (facts != null) facts.revision else safeCached?.modelFactsRevision,
            )
            true
        } catch (error: Exception) {
            reportFailure("cache_decode", startedAtMs, 0L, null, error)
            splitIndex = null
            loadedCatalogs.clear()
            legacyLeanFallback = null
            storedModelFactsETag = null
            metadataCacheDao?.let { dao ->
                try {
                    dao.deleteAllExcept(MetadataCacheEntity.SINGLETON_KEY)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (clearError: Exception) {
                    reportFailure("cache_clear", startedAtMs, 0L, null, clearError)
                }
            }
            false
        }
    }

    /** Whether the current table comes from the APK bundled snapshot (not confirmed online, not written to Room). Any online publication clears it. */
    @Volatile
    private var bundledSnapshotActive = false

    /**
     * After a cold-path fetch fails and there is still no table, adopt the bundled snapshot: not written to Room, not counted as confirmed this session, no cache timestamp set,
     * source recorded as [MetadataSource.Unknown]. If the asset cannot be read or fails validation it is not adopted and we keep waiting for online data.
     */
    internal suspend fun adoptBundledSnapshotIfEmpty(context: Context) {
        if (!bundledFallbackEnabled || table != null) return
        val startedAtMs = nowMillis()
        val decoded = try {
            val text = BundledMetadata.readAsset(context) ?: return
            val data = BundledMetadata.validated(text, json, payloadSchemaValidator()) ?: return
            json.decodeFromJsonElement(MetadataResponse.serializer(), data)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("bundled_decode", startedAtMs, 0L, null, error)
            return
        }
        val safe = normalizeMetadataEvidenceViews(
            data = decoded,
            metadataRevision = null,
            acceptPersistedProjection = false,
        )
        // Parsing happens outside the lock; assignment and online publication are both inside fetchMutex, so re-check under the lock: yield if online data was published while parsing.
        val nextRevision = fetchMutex.withLock {
            if (table != null) return
            val next = evidencePublication.contentRevision + 1
            evidencePublication = EvidencePublication(safe, null, next)
            table = safe
            bundledSnapshotActive = true
            next
        }
        _refreshEvents.tryEmit(
            RefreshEvent(
                version = safe.version,
                contractVersion = safe.contractVersion,
                contentRevision = nextRevision,
            )
        )
    }

    internal val isBundledSnapshotActiveForTesting: Boolean get() = bundledSnapshotActive

    private fun isCachedContractInWindow(contract: Int): Boolean =
        contract == 0 || contract in (SUPPORTED_CONTRACT_VERSION - 1)..(SUPPORTED_CONTRACT_VERSION + 1)

    private suspend fun legacyRowUpdatedAtMs(): Long {
        val dao = metadataCacheDao ?: return 0L
        return try {
            dao.updatedAtMs(MetadataCacheEntity.SINGLETON_KEY) ?: 0L
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            0L
        }
    }

    suspend fun ensureInitialized() {
        val context = appContext ?: return
        if (table == null || bundledSnapshotActive) initialize(context)
        // Once the cache has hydrated (table is non-null) the background full refresh is not awaited: otherwise the first message after a cold start would block on the catalog
        // fetch, and a slow or unreachable backend would hold the first token for many seconds.
        if (table == null) pendingRefresh?.join()
    }

    /** Forces a re-fetch from the catalog, for cases such as a provider resync. */
    suspend fun refresh() = refresh(emptySet())

    /**
     * Conditionally re-fetches the index, then syncs every catalog in "the needed set plus
     * [kinds]" whose revision changed. Unchanged catalogs cost no request; in lean mode (no split
     * transport, or an older server) this is a conditional refresh of the whole payload.
     */
    suspend fun refresh(kinds: Set<ProviderKind>) {
        // Same appContext guard as ensureInitialized()/persistCache(): with no context this
        // instance was never initialized, so fetchMetadata would issue a real request with
        // nowhere to persist the result. In the app there is always a context, so this is a
        // no-op there; in unit tests it stops a fire-and-forget refresh from racing the suite.
        appContext ?: return
        pendingRefresh?.join()
        fetchMetadata(bypassETag = false, requestedKeys = kinds.mapNotNull(::catalogKeyFor).toSet())
    }

    /** Only off-catalog and subscription models need the facts table; a cold start skips it. */
    suspend fun ensureModelFactsLoaded() {
        ensureInitialized()
        // An older full cache can supply facts, but it has no sidecar ETag, so the first real
        // use still has to revalidate.
        if (table?.modelFacts != null && storedModelFactsETag != null) return
        fetchModelFacts()
    }

    suspend fun refreshModelFacts() {
        ensureInitialized()
        fetchModelFacts()
    }

    /**
     * O(1) lookup through resolveMap.
     *
     * On a miss it also checks whether this provider's catalog is merely not loaded yet; if so,
     * just that provider is fetched in the background (deduplicated, never a full reload). The
     * return value is still null: callers that must tell pending from a miss read [catalogLoadState].
     */
    fun resolveCatalogModel(modelID: String, providerKind: ProviderKind): ResolvedModelMetadata? {
        return resolveCatalogModel(table, modelID, providerKind)
            ?: run {
                catalogLoadState(providerKind)
                null
            }
    }

    /**
     * Whether this provider's catalog can back a conclusion right now (pending is not a miss).
     * [CatalogLoadState.Pending] has already started a background fetch of just this provider.
     */
    fun catalogLoadState(providerKind: ProviderKind): CatalogLoadState {
        val publication = evidencePublication
        val snapshot = table ?: return CatalogLoadState.Unavailable
        val key = catalogKeyFor(providerKind) ?: return CatalogLoadState.Absent
        val loaded = publication.loadedProviderKeys
            ?: return if (snapshot.providers.containsKey(key)) CatalogLoadState.Loaded else CatalogLoadState.Absent
        if (key in loaded) return CatalogLoadState.Loaded
        if (!snapshot.providers.containsKey(key)) return CatalogLoadState.Absent
        requestCatalogInBackground(key)
        return CatalogLoadState.Pending
    }

    fun isCatalogPending(providerKind: ProviderKind): Boolean =
        catalogLoadState(providerKind) == CatalogLoadState.Pending

    /**
     * "Confirmed with the server this session", per provider. In split mode a confirmed index
     * only proves provider-level fields are fresh; a negative conclusion about model capabilities
     * also needs this provider's catalog confirmed this session. A provider without a catalog
     * (relay) goes by the index. In lean mode this equals [snapshotConfirmedThisSession].
     */
    fun isSnapshotConfirmed(providerKind: ProviderKind): Boolean {
        if (!_snapshotConfirmedThisSession) return false
        val publication = evidencePublication
        publication.loadedProviderKeys ?: return true
        val key = catalogKeyFor(providerKind) ?: return true
        if (table?.providers?.containsKey(key) != true) return true
        return key in confirmedCatalogKeys
    }

    /** Source per provider: in split mode each catalog is fresh or cached on its own; a catalog not loaded is Unknown. */
    fun metadataSource(providerKind: ProviderKind): MetadataSource {
        val publication = evidencePublication
        val loaded = publication.loadedProviderKeys ?: return _metadataSource
        val key = catalogKeyFor(providerKind) ?: return _metadataSource
        if (table?.providers?.containsKey(key) != true) return _metadataSource
        if (key !in loaded) return MetadataSource.Unknown
        return if (_snapshotConfirmedThisSession && key in confirmedCatalogKeys) {
            MetadataSource.FreshNetwork
        } else {
            MetadataSource.CachedOffline
        }
    }

    /** ProviderKind to the provider key in the metadata response; a relay has no official catalog. */
    private fun catalogKeyFor(kind: ProviderKind): String? =
        if (kind == ProviderKind.Relay) null else kindMap[kind.rawValue] ?: kind.rawValue

    fun currentMetadataRevision(): String? = evidencePublication.metadataRevision

    /**
     * Applied capability-runtime revision used by R3 model-control persistence identity.
     * A present but invalid envelope is not an identity: callers must keep existing preferences
     * dormant and send plain chat rather than borrowing an LWW revision or a legacy profile.
     */
    fun currentCapabilityRuntimeRevision(): String? {
        val runtime = table?.capabilityRuntime ?: return null
        val envelope = JsonObject(mapOf("capabilityRuntime" to runtime))
        if (!RequestPreferenceResolver.validateEnvelope(envelope).applied) return null
        return capabilityRuntimeRevision(runtime)
    }

    data class CapabilityRuntimeRequest(
        val runtime: JsonObject,
        val selections: List<CapabilityRecipeSelection>,
    )

    /** Atomic custom-control authorization result: owners and revision share one metadata snapshot. */
    data class CapabilityCustomControlAuthority(
        val owners: Map<String, String>,
        val runtimeRevision: String,

        val riskTiers: List<String> = emptyList(),
    )

    /** Exact runtime projection for presentation. Relay has no official automatic recipe. */
    data class CapabilityControlPresentation(
        /** Catalog verdict after the exact runtime resolver, never inferred from legacy profiles. */
        val state: String,
        val automaticAvailable: Boolean,
        val recipeRef: String? = null,
        val availableIntents: List<String> = emptyList(),
        /** Catalog-supplied reason for a non-automatic control, preserved for an honest UI. */
        val reasonCode: String? = null,
        /** Local resolver's validation reason (for example a dangling recipe reference). */
        val reason: String? = null,
    )

    /**
     * Projects controls only for the final request transport.  A catalog match alone is not
     * sufficient: a recipe for `openai_responses` must never light an entry that will dispatch
     * through `openai_chat`.  Relay has no official catalog recipe and therefore remains empty.
     */
    fun capabilityControlPresentation(
        providerKind: ProviderKind,
        modelID: String,
        finalTransport: String,
    ): Map<String, CapabilityControlPresentation> {
        if (providerKind == ProviderKind.Relay) return emptyMap()
        if (finalTransport.isBlank()) return emptyMap()
        val snapshot = table ?: return emptyMap()
        val runtime = snapshot.capabilityRuntime ?: return emptyMap()
        if (!RequestPreferenceResolver.validateEnvelope(JsonObject(mapOf("capabilityRuntime" to runtime))).applied) return emptyMap()
        val provider = providerFor(providerKind, snapshot) ?: return emptyMap()
        val resolved = resolveCatalogModel(snapshot, modelID, providerKind) ?: return emptyMap()
        if (canonicalCapabilityTransport(resolved.transport) != canonicalCapabilityTransport(finalTransport)) return emptyMap()
        val model = provider.models.entries.firstOrNull { (key, value) -> key == resolved.canonicalModelId || value.canonicalModelId == resolved.canonicalModelId }?.value ?: return emptyMap()
        val rawControls = model.capabilityControls ?: return emptyMap()
        val recipes = runtime["recipes"] as? JsonObject ?: return emptyMap()
        val sourceIndex = runtime["sourceIndex"] as? JsonObject ?: return emptyMap()
        val entries = rawControls.mapNotNull { (capability, raw) ->
            val control = raw as? JsonObject ?: return@mapNotNull null
            val state = control["state"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            capability to RequestPreferenceResolver.ControlEntry(
                state, control["recipeRef"]?.jsonPrimitive?.contentOrNull, control["reasonCode"]?.jsonPrimitive?.contentOrNull,
                (control["sourceRefs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                (control["availableIntents"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                (control["customControlRefs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
            )
        }.toMap()
        val backendKind = kindMap[providerKind.rawValue] ?: providerKind.rawValue
        val outcomes = RequestPreferenceResolver.resolveControls(
            backendKind, entries, recipes.keys.toList(), sourceIndex.keys, controlDefinitionOwners(runtime),
        ).results
        return entries.mapValues { (capability, entry) ->
            val result = outcomes[capability]
            CapabilityControlPresentation(
                state = result?.state ?: "unknown",
                automaticAvailable = result?.action == "apply_recipe",
                recipeRef = entry.recipeRef,
                availableIntents = entry.availableIntents.orEmpty(),
                reasonCode = entry.reasonCode,
                reason = result?.reason,
            )
        }
    }

    data class CapabilityActionLookup(
        val state: String?,
        val recipeTransport: String?,
        val modelTransport: String?,
    )

    fun capabilityActionLookup(
        providerKind: ProviderKind,
        modelID: String,
        capability: String,
    ): CapabilityActionLookup? {
        val snapshot = table ?: return null
        val resolved = resolveCatalogModel(snapshot, modelID, providerKind) ?: return null
        val provider = providerFor(providerKind, snapshot) ?: return null
        val model = provider.models.entries.firstOrNull { (key, value) ->
            key == resolved.canonicalModelId || value.canonicalModelId == resolved.canonicalModelId
        }?.value ?: return CapabilityActionLookup(state = null, recipeTransport = null, modelTransport = resolved.transport)
        val control = (model.capabilityControls?.get(capability) as? JsonObject)
            ?: return CapabilityActionLookup(state = null, recipeTransport = null, modelTransport = resolved.transport)
        val state = control["state"]?.jsonPrimitive?.contentOrNull
        val recipeRef = control["recipeRef"]?.jsonPrimitive?.contentOrNull
        val recipes = snapshot.capabilityRuntime?.get("recipes") as? JsonObject
        val recipeTransport = recipeRef?.let { ref ->
            ((recipes?.get(ref) as? JsonObject)?.get("transport") as? JsonObject)
                ?.get("protocol")?.jsonPrimitive?.contentOrNull
        }
        return CapabilityActionLookup(state = state, recipeTransport = recipeTransport, modelTransport = resolved.transport)
    }

    fun capabilityRuntimeRequest(
        providerKind: ProviderKind,
        modelID: String,
        finalTransport: String,
        webRequested: Boolean,
        reasoningMode: ReasoningMode,
        typedWebIntent: String? = null,
        typedReasoningIntent: String? = null,
        // Used only by the Gemini Interactions builder: the auto tier also selects a thinking recipe and compiles the base op with intent=null;
        // the generic auto tier still does not select reasoning.
        includeAutomaticReasoning: Boolean = false,
    ): CapabilityRuntimeRequest? {
        val snapshot = table ?: return null
        val runtime = snapshot.capabilityRuntime ?: return null
        val envelope = JsonObject(mapOf("capabilityRuntime" to runtime))
        // Runtime presence is authoritative even when its envelope is invalid. Returning an
        // empty selection preserves fail-closed semantics; null is reserved for truly absent
        // runtime so only that case may use the legacy generation/profile path.
        if (!RequestPreferenceResolver.validateEnvelope(envelope).applied) {
            return CapabilityRuntimeRequest(runtime, emptyList())
        }
        val runtimeRevision = capabilityRuntimeRevision(runtime)
            ?: return CapabilityRuntimeRequest(runtime, emptyList())

        val provider = providerFor(providerKind, snapshot) ?: return CapabilityRuntimeRequest(runtime, emptyList())
        val resolved = resolveCatalogModel(snapshot, modelID, providerKind)
            ?: return CapabilityRuntimeRequest(runtime, emptyList())
        val model = provider.models.entries.firstOrNull { (key, value) ->
            key == resolved.canonicalModelId || value.canonicalModelId == resolved.canonicalModelId
        }?.value ?: return CapabilityRuntimeRequest(runtime, emptyList())
        val controls = model.capabilityControls ?: return CapabilityRuntimeRequest(runtime, emptyList())
        val recipes = runtime["recipes"] as? JsonObject ?: return CapabilityRuntimeRequest(runtime, emptyList())
        val sourceIndex = runtime["sourceIndex"] as? JsonObject ?: return CapabilityRuntimeRequest(runtime, emptyList())

        val entries = controls.mapNotNull { (capability, value) ->
            val control = value as? JsonObject ?: return@mapNotNull null
            val state = control["state"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            capability to RequestPreferenceResolver.ControlEntry(
                state = state,
                recipeRef = control["recipeRef"]?.jsonPrimitive?.contentOrNull,
                reasonCode = control["reasonCode"]?.jsonPrimitive?.contentOrNull,
                sourceRefs = (control["sourceRefs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                availableIntents = (control["availableIntents"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                customControlRefs = (control["customControlRefs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
            )
        }.toMap()
        val backendKind = kindMap[providerKind.rawValue] ?: providerKind.rawValue
        val outcomes = RequestPreferenceResolver.resolveControls(
            providerKind = backendKind,
            capabilityControls = entries,
            recipes = recipes.keys.toList(),
            sourceIndexKeys = sourceIndex.keys,
            controlDefinitionOwners = controlDefinitionOwners(runtime),
        ).results

        val requested = buildList {
            // Generation is an always-present request concern when the catalog published an exact
            // control. Its recipe may intentionally be an empty legacy-template bridge, but it
            // still owns custom-fragment path/transport validation and suppresses client guesses.

            if ("generation" in entries) add("generation" to null)
            if (webRequested) add("web" to typedWebIntent)
            val requestedReasoning = typedReasoningIntent ?: reasoningMode.intentValue
            if (requestedReasoning != null) {
                add("reasoning" to requestedReasoning)
            } else if (includeAutomaticReasoning) {
                add("reasoning" to null)
            }
        }
        val selections = requested.mapNotNull { (capability, intent) ->
            val control = entries[capability] ?: return@mapNotNull null
            val outcome = outcomes[capability]
            if (outcome?.valid != true || outcome.action != "apply_recipe") return@mapNotNull null
            val recipeRef = control.recipeRef ?: return@mapNotNull null
            val recipe = recipes[recipeRef] as? JsonObject ?: return@mapNotNull null
            val recipeProvider = recipe["providerKind"]?.jsonPrimitive?.contentOrNull
            val recipeCapability = recipe["capability"]?.jsonPrimitive?.contentOrNull
            val recipeTransport = (recipe["transport"] as? JsonObject)
                ?.get("protocol")?.jsonPrimitive?.contentOrNull
            val executionKind = recipe["executionKind"]?.jsonPrimitive?.contentOrNull
            val requestOps = recipe["requestOps"] as? JsonArray
            val responseEvidenceRef = recipe["responseEvidenceRef"]?.jsonPrimitive?.contentOrNull
            val evidenceSignals = responseEvidenceRef?.let { ref ->
                responseEvidenceSignals(
                    runtime = runtime,
                    ref = ref,
                    capability = capability,
                    finalTransport = finalTransport,
                    responseParserKind = recipe["responseParserKind"]?.jsonPrimitive?.contentOrNull,
                )
            }
            if (responseEvidenceRef != null && evidenceSignals == null) return@mapNotNull null
            if (recipeProvider != backendKind || recipeCapability != capability ||
                canonicalCapabilityTransport(recipeTransport) != canonicalCapabilityTransport(finalTransport) ||
                executionKind == null || requestOps == null
            ) return@mapNotNull null
            CapabilityRecipeSelection(
                id = recipeRef,
                providerKind = backendKind,
                capability = capability,
                executionKind = executionKind,
                selectedIntent = intent,
                availableIntents = control.availableIntents,
                requestOps = requestOps.mapNotNull { operation ->
                    val raw = operation as? JsonObject ?: return@mapNotNull null
                    val op = raw["op"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                    CapabilityRecipeOperation(
                        op = op,
                        pointer = raw["pointer"]?.jsonPrimitive?.contentOrNull,
                        intent = raw["intent"]?.jsonPrimitive?.contentOrNull,
                        value = raw["value"],
                    )
                },
                continuationKind = recipe["continuationKind"]?.jsonPrimitive?.contentOrNull,
                continuationVariant = recipe["continuationVariant"]?.jsonPrimitive?.contentOrNull,
                continuationInstructionsMode = ContinuationInstructionsMode.fromWire(
                    recipe["continuationInstructionsMode"]?.jsonPrimitive?.contentOrNull,
                )?.wire,
                responseParserKind = recipe["responseParserKind"]?.jsonPrimitive?.contentOrNull,
                responseEvidenceSignals = evidenceSignals.orEmpty(),
                runtimeRevision = runtimeRevision,
                maxToolLoops = recipe["maxToolLoops"]?.jsonPrimitive?.intOrNull,
                route = recipe["route"] as? JsonObject,
                formula = recipe["formula"] as? JsonObject,
            ).takeIf { selected -> selected.requestOps.size == requestOps.size }
        }
        return CapabilityRuntimeRequest(runtime, selections)
    }

    /**
     * Result definitions replace the former broad text-based unsupported-parameter retry.
     * Presence alone is sufficient to close that escape hatch: a malformed payload must
     * surface the upstream error, never fall back to an older heuristic.
     */
    fun hasP5CapabilityResultRuntime(): Boolean = table?.capabilityRuntime?.let { runtime ->
        "responseEvidenceDefinitions" in runtime || "errorRecoveryDefinitions" in runtime
    } == true

    /**
     * Documentation is a catalog authority chain, not a provider-name lookup: exact selected
     * generation recipe -> its sourceRefs -> sourceIndex official HTTPS entry.  Missing evidence
     * intentionally yields no link.
     */
    fun capabilityOfficialGenerationDocumentationURL(
        providerKind: ProviderKind,
        modelID: String,
        finalTransport: String,
    ): String? {
        val request = capabilityRuntimeRequest(
            providerKind = providerKind,
            modelID = modelID,
            finalTransport = finalTransport,
            webRequested = false,
            reasoningMode = ReasoningMode.Automatic,
        ) ?: return null
        val selection = request.selections.singleOrNull { it.capability == "generation" } ?: return null
        val recipe = (request.runtime["recipes"] as? JsonObject)?.get(selection.id) as? JsonObject ?: return null
        val sourceIndex = request.runtime["sourceIndex"] as? JsonObject ?: return null
        return (recipe["sourceRefs"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?.mapNotNull { ref -> sourceIndex[ref] as? JsonObject }
            ?.mapNotNull { source ->
                val kind = (source["kind"] as? JsonPrimitive)?.contentOrNull
                val url = (source["url"] as? JsonPrimitive)?.contentOrNull
                url?.takeIf { kind == "official_doc" && it.startsWith("https://") }
            }
            ?.firstOrNull()
    }

    private fun controlDefinitionOwners(runtime: JsonObject): Map<String, String> =
        (runtime["controlDefinitions"] as? JsonObject)?.mapNotNull { (ref, raw) ->
            val owner = ((raw as? JsonObject)?.get("owner") as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
            ref to owner
        }?.toMap().orEmpty()

    fun capabilityCustomControlAuthority(
        providerKind: ProviderKind,
        modelID: String,
        finalTransport: String,
        owner: String,
    ): CapabilityCustomControlAuthority? {
        if (providerKind == ProviderKind.Relay || owner !in setOf("web", "reasoning", "generation")) return null
        val snapshot = table ?: return null
        val runtime = snapshot.capabilityRuntime ?: return null
        val runtimeRevision = capabilityRuntimeRevision(runtime) ?: return null
        if (!RequestPreferenceResolver.validateEnvelope(JsonObject(mapOf("capabilityRuntime" to runtime))).applied) return null
        val provider = providerFor(providerKind, snapshot) ?: return null
        val resolved = resolveCatalogModel(snapshot, modelID, providerKind) ?: return null
        if (canonicalCapabilityTransport(resolved.transport) != canonicalCapabilityTransport(finalTransport)) return null
        val model = provider.models.entries.firstOrNull { (key, value) ->
            key == resolved.canonicalModelId || value.canonicalModelId == resolved.canonicalModelId
        }?.value ?: return null
        val control = (model.capabilityControls ?: return null)[owner] as? JsonObject ?: return null
        val refs = (control["customControlRefs"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?.distinct()
            ?.takeIf { it.isNotEmpty() } ?: return null
        val definitions = runtime["controlDefinitions"] as? JsonObject ?: return null
        val sources = runtime["sourceIndex"] as? JsonObject ?: return null
        val owners = linkedMapOf<String, String>()
        val riskTiers = linkedSetOf<String>()
        refs.forEach { ref ->
            val definition = definitions[ref] as? JsonObject ?: return null

            (definition["riskTier"] as? JsonPrimitive)?.contentOrNull
                ?.takeIf { it in setOf("cost_impacting", "privacy_impacting") }
                ?.let(riskTiers::add)
            if ((definition["id"] as? JsonPrimitive)?.contentOrNull != ref ||
                (definition["owner"] as? JsonPrimitive)?.contentOrNull != owner) return null
            val pointer = (definition["targetPointer"] as? JsonPrimitive)?.contentOrNull ?: return null
            val sourceRefs = (definition["sourceRefs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                ?.takeIf { it.isNotEmpty() } ?: return null
            if (!sourceRefs.all { source ->
                val entry = sources[source] as? JsonObject
                (entry?.get("kind") as? JsonPrimitive)?.contentOrNull == "official_doc" &&
                    ((entry["url"] as? JsonPrimitive)?.contentOrNull?.startsWith("https://") == true)
            }) return null
            val safe = RequestPreferenceResolver.validateOverlay(RequestPreferenceResolver.OverlayIntent(
                channel = "body_fragment",
                metrics = RequestPreferenceResolver.OverlayMetrics(bytes = 1, depth = 1, nodes = 1),
                operations = listOf(RequestPreferenceResolver.OverlayOperation(owner, "set", pointer, JsonPrimitive(true))),
                declaredOwners = mapOf(pointer to owner),
            ))
            if (!safe.accepted || owners.put(pointer, owner) != null) return null
        }
        return owners.takeIf { it.isNotEmpty() }?.let {
            CapabilityCustomControlAuthority(
                owners = it,
                runtimeRevision = runtimeRevision,
                riskTiers = listOf("privacy_impacting", "cost_impacting").filter(riskTiers::contains),
            )
        }
    }

    fun currentCapabilityEvidenceModel(
        modelID: String,
        providerKind: ProviderKind,
    ): CurrentCapabilityEvidenceModel? {
        val current = evidencePublication
        val resolved = resolveCatalogModel(current.table, modelID, providerKind) ?: return null
        return CurrentCapabilityEvidenceModel(
            metadata = resolved,
            metadataRevision = current.metadataRevision,
            generationRevision = resolved.capabilityEvidenceCandidates
                .orEmpty()
                .asSequence()
                .filter { it.key.startsWith("generation_parameter/") }
                .mapNotNull { it.generationRevision }
                .distinct()
                .toList()
                .singleOrNull()
                ?: current.metadataRevision,
            declaredReasoningLevels = resolved.profiles.reasoning
                ?.let { profile -> current.table?.profiles?.reasoning?.get(profile)?.levels }
                .orEmpty()
                .filter { it.isNotBlank() }
                .toSet(),
            contentRevision = current.contentRevision,
        )
    }

    /** Exact catalog-external lookup. Missing data is unknown, never unsupported. */
    fun modelFacts(providerKind: ProviderKind, modelID: String): ModelFacts? {
        val providerKey = kindMap[providerKind.rawValue] ?: return null
        val normalized = normalizeModelFactsID(modelID)
        if (normalized.isEmpty()) return null
        return table?.modelFacts?.get("$providerKey/$normalized")
    }

    fun modelFactsRevision(): String? = table?.modelFactsRevision

    private fun resolveCatalogModel(
        snapshot: MetadataResponse?,
        modelID: String,
        providerKind: ProviderKind,
    ): ResolvedModelMetadata? {
        val provider = providerFor(providerKind, snapshot) ?: return null
        val resolveMap = provider.resolveMap ?: return null

        val canonicalId = lookupCandidates(modelID)
            .asSequence()
            .mapNotNull { candidate ->
                resolveMap[candidate] ?: candidate.takeIf { provider.models.containsKey(it) }
            }
            .firstOrNull()
            ?: return null
        val model = provider.models[canonicalId] ?: return null

        val pricing = model.pricing
        val profiles = normalizeProfiles(model.profiles).let { normalized ->
            normalized.copy(
                generation = resolveGenerationProfile(
                    normalized.generation,
                    snapshot?.profiles?.generation,
                    snapshot?.generationParameterTables,
                ),
            )
        }
        val uiHints = normalizeUIHints(model.uiHints)
        val capabilities = normalizeCapabilities(model.capabilities, uiHints?.badgeOrder)
        val price = resolvePriceKeys(model.currencyCode, model.pricingStatus, model.pricingUnit, pricing, model.pricingV2)

        return ResolvedModelMetadata(
            canonicalModelId = model.canonicalModelId ?: canonicalId,
            modelRef = model.modelRef?.trim()?.takeIf { it.isNotEmpty() },
            capabilityContractVersion = snapshot?.capabilityContractVersion ?: 0,
            displayName = model.displayName,
            contextLength = model.contextLength,
            maxOutputTokens = model.maxOutputTokens,
            supportsTemperature = model.supportsTemperature,
            billingSku = model.billingSku?.trim()?.takeIf { it.isNotEmpty() },
            pricingUnit = price.pricingUnit,
            sourceSummary = normalizeSourceSummary(model.sourceSummary),
            pricingStatus = price.pricingStatus,
            capabilities = capabilities,
            promptPerToken = price.promptPerToken,
            completionPerToken = price.completionPerToken,
            costPerUnit = price.costPerUnit,
            costInputBatches = price.costInputBatches,
            costOutputBatches = price.costOutputBatches,
            costInputPriority = price.costInputPriority,
            costOutputPriority = price.costOutputPriority,
            cacheReadInputPerMToken = price.cacheReadInputPerMToken,
            cacheCreationInputPerMToken = price.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken = price.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken = price.cacheWrite1hPerMToken,
            profiles = profiles,
            supportsPdfInput = model.supportsPdfInput == true,
            supportsServiceTier = model.supportsServiceTier == true,
            uiHints = uiHints,
            isDefault = provider.defaultModelId == canonicalId,
            vendorKey = model.vendorKey?.takeIf { it.isNotBlank() },
            vendorName = model.vendorName?.takeIf { it.isNotBlank() },

            toolCall = model.toolCall,
            transport = model.transport?.takeIf { it.isNotBlank() },
            nativeFileMimes = model.nativeFileMimes.orEmpty(),
            pdfNativeDefault = model.pdfNativeDefault ?: false,
            attachmentExtraction = model.attachmentExtraction,
            capabilityEvidenceCandidates = model.capabilityEvidenceCandidates,
            capabilityEvidenceOwnedKeys = model.capabilityEvidenceOwnedKeys?.toSet(),
            capabilityEvidenceViewMalformed = model.capabilityEvidenceViewMalformed,
            capabilityControls = model.capabilityControls,
            parameterSupport = model.parameterSupport,
            longContext = price.longContext,
            promptCachePolicyRef = (model.promptCache?.get("policyRef") as? JsonPrimitive)
                ?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() },
            pricingV2 = price.pricingV2,
            currencyCode = price.currencyCode,
            regionPricing = decodeRegionPricing(model.regionPricing),
        )
    }

    /** Price key parsing: the model level and every regionPricing entry share this convention. */
    private fun resolvePriceKeys(
        currencyCode: String?,
        rawStatus: String?,
        rawUnit: String?,
        pricing: ModelPricing?,
        rawPricingV2: JsonElement?,
    ): PriceKeys {
        val pricingUnit = normalizePricingUnit(rawUnit)
        val pricingStatus = normalizePricingStatus(rawStatus, pricing, pricingUnit)
        val tokenPriced = pricingStatus != "unknown" && pricingUnit == "per_token"
        return PriceKeys(
            currencyCode = currencyCode?.trim()?.takeIf { it.isNotEmpty() },
            pricingStatus = pricingStatus,
            pricingUnit = pricingUnit,
            promptPerToken = if (tokenPriced) pricing?.promptPerMToken?.div(1_000_000) else null,
            completionPerToken = if (tokenPriced) pricing?.completionPerMToken?.div(1_000_000) else null,
            costPerUnit = pricing?.costPerUnit,
            costInputBatches = pricing?.costInputBatches,
            costOutputBatches = pricing?.costOutputBatches,
            costInputPriority = pricing?.costInputPriority,
            costOutputPriority = pricing?.costOutputPriority,
            // Cache read price: new field > legacy cachedInputPerMToken; if both are missing leave it empty and CostCalculator falls back to input price x 0.5.
            cacheReadInputPerMToken = pricing?.cacheReadInputPerMToken ?: pricing?.cachedInputPerMToken,
            cacheCreationInputPerMToken = pricing?.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken = pricing?.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken = pricing?.cacheWrite1hPerMToken,
            longContext = decodeLongContext(pricing?.longContext),
            pricingV2 = ai.oriveo.community.core.provider.PricingV2Estimator.parse(rawPricingV2),
        )
    }

    @Serializable
    private data class RegionPricingData(
        val regionScope: String,
        val currencyCode: String,
        val pricingStatus: String,
        val pricingUnit: String,
        val pricing: ModelPricing?,
        val pricingV2: JsonElement? = null,
    )

    /**
     * regionPricing is parsed leniently per entry (contract section 5.7): a non-array is an empty list; a single entry with a bad shape (missing required keys, pricing not an object, ...)
     * drops only that entry, unknown keys are ignored. Under schema 2 the validator already removed bad entries first; this also covers schema 1 and the cache.
     */
    private fun decodeRegionPricing(raw: JsonElement?): List<RegionPricingEntry> =
        (raw as? JsonArray).orEmpty().mapNotNull { element ->
            val entry = runCatching { json.decodeFromJsonElement(RegionPricingData.serializer(), element) }.getOrNull()
                ?: return@mapNotNull null
            val scope = entry.regionScope.trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            RegionPricingEntry(
                regionScope = scope,
                price = resolvePriceKeys(entry.currencyCode, entry.pricingStatus, entry.pricingUnit, entry.pricing, entry.pricingV2),
            )
        }

    /**
     * The four pricing.longContext fields: thresholdTokens (positive integer), promptPerMToken, completionPerMToken are required,
     * cacheReadPerMToken may be omitted; any field with a wrong shape makes the whole tier count as missing (contract long-context rule 3).
     */
    private fun decodeLongContext(raw: JsonElement?): LongContextPricing? {
        val fields = raw as? JsonObject ?: return null
        fun number(key: String): JsonPrimitive? =
            (fields[key] as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }
        fun price(key: String): Double? = number(key)?.content?.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
        // Contract long-context rule 3: an integer value (including forms like 200000.0) with 1 <= t <= Int.MAX_VALUE; parse as a number first, then convert exactly.
        val threshold = number("thresholdTokens")?.content?.toDoubleOrNull()
            ?.takeIf { it.isFinite() && it == Math.floor(it) && it >= 1.0 && it <= Int.MAX_VALUE.toDouble() }
            ?.toInt() ?: return null
        val prompt = price("promptPerMToken") ?: return null
        val completion = price("completionPerMToken") ?: return null
        val cacheRead = if (fields["cacheReadPerMToken"].let { it == null || it is JsonNull }) {
            null
        } else {
            price("cacheReadPerMToken") ?: return null
        }
        return LongContextPricing(
            thresholdTokens = threshold,
            promptPerMToken = prompt,
            completionPerMToken = completion,
            cacheReadPerMToken = cacheRead,
        )
    }

    /**
     * Cross-provider lookup for display (e.g. the price badge on the usage page): scans only **already loaded** official catalogs and never triggers a fetch.
     * It does not take part in request construction; relay requests always go through the whitelist of [resolveCatalogModelAcrossProviders].
     */
    fun resolveCatalogModelInLoadedCatalogs(modelID: String): ResolvedModelMetadata? {
        val snapshot = table
        ProviderKind.entries.forEach { kind ->
            if (kind == ProviderKind.Relay) return@forEach
            resolveCatalogModel(snapshot, modelID, kind)?.let { return it }
        }
        return null
    }

    /**
     * Official-catalog match used to build relay requests: scans only
     * relayRuntimeConfig.officialProviderWhitelist. A miss still returns null and the caller
     * fails open.
     */
    fun resolveCatalogModelAcrossProviders(modelID: String): ResolvedModelMetadata? =
        resolveCatalogModelAcrossProvidersWithProvider(modelID)?.metadata

    fun resolveCatalogModelAcrossProvidersWithProvider(
        modelID: String,
        transportPriority: ProviderKind? = null,
    ): RelayCatalogMatchResult? {
        val runtime = relayRuntimeConfig()
        val whitelist = runtime.officialProviderWhitelist
        val priorityBackendKey = transportPriority?.let { kindMap[providerKindSerialName(it)] ?: providerKindSerialName(it) }

        val ordered = mutableListOf<ProviderKind>()
        if (priorityBackendKey != null && whitelist.contains(priorityBackendKey)) {
            backendKeyToProviderKind[priorityBackendKey]?.let { ordered.add(it) }
        }
        for (backendKey in whitelist) {
            if (backendKey == priorityBackendKey) continue
            val kind = backendKeyToProviderKind[backendKey] ?: continue
            if (!ordered.contains(kind)) ordered.add(kind)
        }

        // The cross-provider scan reads only catalogs that are already loaded and never fetches
        // one per whitelisted provider: when a relay exists the whitelist is already in the needed
        // set, and a caller without a relay should not download those catalogs for this.
        val snapshot = table
        for (kind in ordered) {
            val resolved = resolveCatalogModel(snapshot, modelID, kind) ?: continue
            val source = if (priorityBackendKey != null && ordered.first() == kind) {
                RelayCatalogMatchSource.TransportFirst
            } else {
                RelayCatalogMatchSource.CrossProvider
            }
            return RelayCatalogMatchResult(
                matchedProviderKind = kind,
                canonicalModelId = resolved.canonicalModelId,
                metadata = resolved,
                source = source,
            )
        }
        return null
    }

    /**
     * Runtime limits for remote MCP. A catalog without this block (an older cached copy, a
     * self-hosted catalog, or no catalog at all) yields the built-in defaults; the feature is
     * not disabled because of that. With `enabled = false` the entry points are hidden and
     * requests carry no MCP tools, while stored servers are kept.
     */
    fun mcpRuntimeConfig(): ai.oriveo.community.core.mcp.McpRuntimeConfig =
        ai.oriveo.community.core.mcp.McpRuntimeConfig.fromJson(table?.mcpRuntimeConfig)

    internal fun relayRuntimeConfig(): RelayRuntimeConfig {
        val remote = table?.relayRuntimeConfig ?: return FALLBACK_RELAY_RUNTIME_CONFIG
        return mergeRelayRuntimeConfig(remote)
    }

    fun isRuntimeFeatureEnabled(key: String, defaultValue: Boolean = true): Boolean {
        val normalizedKey = key.trim().takeIf { it.isNotEmpty() } ?: return defaultValue
        return table?.runtimeConfig?.featureFlags?.get(normalizedKey) ?: defaultValue
    }

    fun selfHealPatterns(): List<SelfHealPattern> =
        table?.runtimeConfig?.selfHealPatterns.orEmpty()

    private fun mergeRelayRuntimeConfig(remote: RawRelayRuntimeConfig): RelayRuntimeConfig {
        val fallback = FALLBACK_RELAY_RUNTIME_CONFIG
        val whitelist = remote.officialProviderWhitelist?.takeIf { it.isNotEmpty() }
            ?: fallback.officialProviderWhitelist
        val envelopes = fallback.transportEnvelopes.toMutableMap()
        remote.transportEnvelopes?.forEach { (key, override) ->
            val base = envelopes[key] ?: return@forEach
            envelopes[key] = RelayTransportEnvelope(
                image = override.image ?: base.image,
                nativeFile = override.nativeFile ?: base.nativeFile,
                textFileInline = override.textFileInline ?: base.textFileInline,
                webSearch = override.webSearch ?: base.webSearch,
                imageGeneration = override.imageGeneration ?: base.imageGeneration,
                reasoning = override.reasoning ?: base.reasoning,
            )
        }
        val rules = fallback.transportRules.toMutableMap()
        remote.transportRules?.forEach { (key, override) ->
            val base = rules[key] ?: return@forEach
            rules[key] = RelayTransportRule(
                providerPriority = override.providerPriority ?: base.providerPriority,
                defaultAuthMode = override.defaultAuthMode ?: base.defaultAuthMode,
                defaultVersion = override.defaultVersion ?: base.defaultVersion,
                acceptedVersions = override.acceptedVersions?.takeIf { it.isNotEmpty() } ?: base.acceptedVersions,
                headerProfile = override.headerProfile ?: base.headerProfile,
                codexIdentityDefault = override.codexIdentityDefault ?: base.codexIdentityDefault,
                webSearchToolName = override.webSearchToolName ?: base.webSearchToolName,
                imageRoute = override.imageRoute ?: base.imageRoute,
                forceStreamForImageGeneration = override.forceStreamForImageGeneration ?: base.forceStreamForImageGeneration,
                codexClientVersion = override.codexClientVersion ?: base.codexClientVersion,
            )
        }
        return RelayRuntimeConfig(
            version = remote.version?.takeIf { it.isNotEmpty() } ?: fallback.version,
            officialProviderWhitelist = whitelist,
            transportEnvelopes = envelopes,
            transportRules = rules,
            verificationPolicy = remote.verificationPolicy ?: fallback.verificationPolicy,
            featureGatingPolicy = remote.featureGatingPolicy ?: fallback.featureGatingPolicy,
        )
    }

    private fun providerKindSerialName(kind: ProviderKind): String = when (kind) {
        ProviderKind.OpenAI -> "openAI"
        ProviderKind.Anthropic -> "anthropic"
        ProviderKind.Gemini -> "gemini"
        ProviderKind.DeepSeek -> "deepseek"
        ProviderKind.Grok -> "grok"
        ProviderKind.OpenRouter -> "openRouter"
        ProviderKind.Groq -> "groq"
        ProviderKind.Together -> "together"
        ProviderKind.Fireworks -> "fireworks"
        ProviderKind.MiniMax -> "miniMax"
        ProviderKind.Zhipu -> "zhipu"
        ProviderKind.Qwen -> "qwen"
        ProviderKind.Moonshot -> "moonshot"
        ProviderKind.Mistral -> "mistral"
        ProviderKind.SiliconFlow -> "siliconFlow"
        ProviderKind.Relay -> "relay"
    }

    private val backendKeyToProviderKind: Map<String, ProviderKind> = mapOf(
        "openAI" to ProviderKind.OpenAI,
        "anthropic" to ProviderKind.Anthropic,
        "gemini" to ProviderKind.Gemini,
        "deepseek" to ProviderKind.DeepSeek,
        "grok" to ProviderKind.Grok,
        "openRouter" to ProviderKind.OpenRouter,
        "groq" to ProviderKind.Groq,
        "togetherAI" to ProviderKind.Together,
        "fireworksAI" to ProviderKind.Fireworks,
        "miniMax" to ProviderKind.MiniMax,
        "zhipu" to ProviderKind.Zhipu,
        "qwen" to ProviderKind.Qwen,
        "moonshot" to ProviderKind.Moonshot,
        "mistral" to ProviderKind.Mistral,
        "siliconFlow" to ProviderKind.SiliconFlow,
        "relay" to ProviderKind.Relay,
    )

    fun lookupPricing(modelID: String, providerKind: ProviderKind): Pair<Double, Double>? {
        val metadata = resolveCatalogModel(modelID, providerKind) ?: return null
        if (metadata.pricingStatus == "unknown" || metadata.pricingUnit != "per_token") return null
        val prompt = metadata.promptPerToken ?: return null
        val completion = metadata.completionPerToken ?: return null
        return prompt to completion
    }

    fun lookupCapabilities(modelID: String, providerKind: ProviderKind): List<ModelCapability>? {
        val metadata = resolveCatalogModel(modelID, providerKind) ?: return null
        return metadata.capabilities.takeIf { it.isNotEmpty() }
    }

    /**
     * Whether a catalog response has been confirmed this session, either a fresh 200 or a 304.
     *
     * Callers use it to tell "the catalog says nothing about this" apart from "we have not
     * managed to ask yet", which are two different answers to show a user.
     */
    val snapshotConfirmedThisSession: Boolean get() = _snapshotConfirmedThisSession

    fun resolveAIModelForRouter(modelID: String, providerKind: ProviderKind): ai.oriveo.community.core.model.AIModel? {
        val metadata = resolveCatalogModel(modelID, providerKind) ?: return null
        return ai.oriveo.community.core.model.AIModel(
            id = metadata.canonicalModelId,
            name = metadata.displayName ?: metadata.canonicalModelId,
            capabilities = metadata.capabilities,
            priceTier = metadata.pricingStatus,
            nativeFileMimes = metadata.nativeFileMimes,
            pdfNativeDefault = metadata.pdfNativeDefault,
            attachmentExtraction = metadata.attachmentExtraction,
            toolCall = metadata.toolCall,
        )
    }

    fun estimateCost(
        modelID: String,
        providerKind: ProviderKind,
        promptTokens: Int,
        completionTokens: Int,
    ): Double {
        val metadata = resolveCatalogModel(modelID, providerKind) ?: return 0.0
        if (metadata.pricingStatus == "free") return 0.0
        if (metadata.pricingStatus == "unknown") return 0.0
        if (metadata.pricingUnit != "per_token") {
            return metadata.costPerUnit ?: 0.0
        }

        val pricing = lookupPricing(modelID, providerKind) ?: return 0.0
        return pricing.first * promptTokens + pricing.second * completionTokens
    }

    fun priceTier(modelID: String, providerKind: ProviderKind): String {
        val metadata = resolveCatalogModel(modelID, providerKind) ?: return ""
        return when (metadata.pricingStatus) {
            "free" -> "Free"
            "unknown" -> "Price unknown"
            "priced" -> {
                if (metadata.pricingUnit != "per_token") {
                    "Non-standard billing"
                } else {
                    ModelPricingFormatter.formatPerMillion(
                        metadata.promptPerToken,
                        metadata.completionPerToken,
                    )
                }
            }
            else -> "Price unknown"
        }
    }

    fun providerModelIds(providerKind: ProviderKind): List<String> {
        return providerFor(providerKind)?.models?.keys?.sorted() ?: emptyList()
    }

    fun defaultModelId(providerKind: ProviderKind): String? {
        return providerFor(providerKind)?.defaultModelId
    }

    /** Catalog tombstones (retired models) of this provider; empty when the catalog sent none or omitted them. */
    fun retiredModels(providerKind: ProviderKind): List<RetiredModel> {
        return providerFor(providerKind)?.retiredModels.orEmpty()
    }

    /**
     * Catalog view for retirement checks (contract model catalog and capability truth section 8): model id + display name + lifecycle, tombstones, resolveMap, default model.
     * Only given when this provider's catalog is [CatalogLoadState.Loaded]; otherwise null (checks always say available, never treating "not loaded yet" as "not in the catalog").
     */
    fun retirementCatalog(providerKind: ProviderKind): ai.oriveo.community.core.provider.ModelRetirement.Catalog? {
        if (catalogLoadState(providerKind) != CatalogLoadState.Loaded) return null
        val provider = providerFor(providerKind) ?: return null
        return ai.oriveo.community.core.provider.ModelRetirement.Catalog(
            models = provider.models.map { (id, model) ->
                ai.oriveo.community.core.provider.ModelRetirement.CatalogModel(
                    id = id,
                    displayName = model.displayName,
                    lifecycle = model.lifecycleInfo(),
                )
            },
            retiredModels = provider.retiredModels.orEmpty(),
            resolveMap = provider.resolveMap.orEmpty(),
            defaultModelId = provider.defaultModelId,
        )
    }

    /** Whether the current table is the APK bundled snapshot (fallback when a cold-start fetch fails): "not in the catalog" cannot be trusted then. */
    val isBundledSnapshotActive: Boolean get() = bundledSnapshotActive

    /**
     * BYOK key validation contract (probe / probePath / authMode / headerProfile / invalidKeySignals).
     * When missing, callers fall back to the most common shape (list_models + bearer + 401 signal).
     */
    fun validation(providerKind: ProviderKind): ProviderValidation? {
        return providerFor(providerKind)?.validation
    }

    internal fun providerAttachmentSupport(providerKind: ProviderKind): ProviderAttachmentSupport? {
        return providerFor(providerKind)?.attachmentSupport
    }

    fun providerTransport(providerKind: ProviderKind): ProviderTransport? {
        return providerFor(providerKind)?.transport
    }

    fun webSearchStreamShape(profileName: String?): StreamShape? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.webSearch?.get(profileName)?.streamShape
    }

    fun webSearchMergeParams(profileName: String?): kotlinx.serialization.json.JsonObject? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.webSearch?.get(profileName)?.mergeParams
    }

    /**
     * Used for read-time mapping of legacy relay fields: if the profile is in the issued metadata, its mergeParams (empty object if none);
     * if the profile is not in metadata, null, and the caller falls back to the no-profile case.
     */
    fun webSearchDeclaredMergeParams(profileName: String): kotlinx.serialization.json.JsonObject? {
        val profile = table?.profiles?.webSearch?.get(profileName) ?: return null
        return profile.mergeParams ?: kotlinx.serialization.json.JsonObject(emptyMap())
    }

    fun webSearchMaxToolLoops(profileName: String?): Int? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.webSearch?.get(profileName)?.maxToolLoops
    }

    fun reasoningStreamShape(profileName: String?): StreamShape? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.reasoning?.get(profileName)?.streamShape
    }

    fun reasoningMergeParams(profileName: String?, mode: ReasoningMode): JsonObject? {
        if (profileName.isNullOrBlank()) return null
        val profile = table?.profiles?.reasoning?.get(profileName)
        val normalized = clampReasoningMode(mode, profileName)

        val effectiveLevel = if (normalized == ReasoningMode.Automatic) {
            profile?.defaultLevel?.takeIf { it.isNotBlank() } ?: return null
        } else {
            normalized.rawValue
        }
        return profile?.params?.get(effectiveLevel)
    }

    fun imageGenStreamShape(profileName: String?): StreamShape? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.imageGen?.get(profileName)?.streamShape
    }

    fun imageGenMergeParams(profileName: String?): kotlinx.serialization.json.JsonObject? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.imageGen?.get(profileName)?.mergeParams
    }

    fun imageGenRoute(profileName: String?): String? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.imageGen?.get(profileName)?.route
    }

    fun imageGenRequestDefaults(profileName: String?): kotlinx.serialization.json.JsonObject? {
        if (profileName.isNullOrBlank()) return null
        return table?.profiles?.imageGen?.get(profileName)?.requestDefaults
    }

    fun hasPublicProviderConfigSource(): Boolean {
        return table?.providerConfigs != null
    }

    fun grokSubscriptionAvailability(
        appVersion: String = BuildConfig.VERSION_NAME,
    ): GrokSubscriptionAvailability {
        val features = table?.providerConfigs
            ?.firstOrNull { it.kind == ProviderKind.Grok.rawValue }
            ?.protocolFeatures
            ?: return GrokSubscriptionAvailability.Unavailable
        val raw = runCatching {
            json.decodeFromJsonElement(RawProtocolFeatures.serializer(), features)
        }.getOrNull()?.subscriptionAuth
        return GrokSubscriptionAuthResolver.resolve(raw = raw, appVersion = appVersion)
    }

    fun openAISubscriptionAvailability(
        appVersion: String = BuildConfig.VERSION_NAME,
    ): OpenAISubscriptionAvailability {
        val features = table?.providerConfigs
            ?.firstOrNull { it.kind == ProviderKind.OpenAI.rawValue }
            ?.protocolFeatures
            ?: return OpenAISubscriptionAvailability.Unavailable
        val raw = runCatching {
            json.decodeFromJsonElement(RawOpenAIProtocolFeatures.serializer(), features)
        }.getOrNull()?.subscriptionAuth
        return OpenAISubscriptionAuthResolver.resolve(raw = raw, appVersion = appVersion)
    }

    fun listPublicProviderConfigs(): List<PublicProviderConfig> {
        return table?.providerConfigs
            ?.map(::withTrustedRegionOptions)
            ?.sortedWith(
                compareBy<PublicProviderConfig> { it.sortOrder ?: Int.MAX_VALUE }
                    .thenBy { providerConfigFallbackOrder(it.kind) }
                    .thenBy { it.kind },
            )
            ?: emptyList()
    }

    /** Public config issued for a provider (unfiltered); Relay connections have no such row. */
    fun publicProviderConfig(kind: ProviderKind): PublicProviderConfig? {
        if (kind == ProviderKind.Relay) return null
        val backendKind = kindMap[kind.rawValue] ?: kind.rawValue
        return table?.providerConfigs?.firstOrNull { it.kind == backendKind }
    }

    /** Public config issued for a provider, with region options already passed through the trusted table and template placeholder rules (same filtering as [listPublicProviderConfigs]). */
    fun trustedPublicProviderConfig(kind: ProviderKind): PublicProviderConfig? =
        publicProviderConfig(kind)?.let(::withTrustedRegionOptions)

    /** Raw trusted host suffixes issued for a provider; shape validation and default fallback live in [EndpointResolver.trustedHostSuffixes]. */
    fun trustedHosts(kind: ProviderKind): List<String>? = publicProviderConfig(kind)?.trustedHosts

    /** Raw outbound protocol issued for a provider (`providerConfigs[].apiProtocol`); null when not issued. */
    fun apiProtocol(kind: ProviderKind): String? = publicProviderConfig(kind)?.apiProtocol

    /**
     * Region options and base addresses pass the same trusted table: filtered item by item at the layer that decodes into provider configs,
     * so the new-provider page, detail page and region picker all receive the filtered table.
     */
    private fun withTrustedRegionOptions(config: PublicProviderConfig): PublicProviderConfig {
        val kind = ProviderKind.entries.firstOrNull { (kindMap[it.rawValue] ?: it.rawValue) == config.kind }
            ?: return config
        val trusted = EndpointResolver.trustedHostSuffixes(kind, config.trustedHosts)
        // Address template: placeholders must be in the closed set and declared in setupFields; substitute `a` and then pass the trusted table; templates without placeholders are unchanged.
        val declared = OfficialEndpointSource.declaredSetupFieldIds(config.setupFields)
        // A default address that is a template goes through the same filter; if unusable it is cleared, which is treated as not issued, and each consumer falls back to the built-in default.
        val defaultBase = config.defaultBaseURL
        val keepDefault = !(defaultBase.contains('{') || defaultBase.contains('}')) ||
            OfficialEndpointSource.isAcceptableTemplate(defaultBase.trim().trimEnd('/'), declared, trusted)
        val options = config.regionOptions
        val filtered = options?.filter { OfficialEndpointSource.isAcceptableTemplate(it.baseURL, declared, trusted) }
        if (keepDefault && filtered?.size == options?.size) return config
        return config.copy(
            defaultBaseURL = if (keepDefault) defaultBase else "",
            regionOptions = filtered,
        )
    }

    fun supportedReasoningModes(profileName: String?): List<ReasoningMode> {
        if (profileName.isNullOrBlank()) {
            return ReasoningMode.entries
        }

        val levels = table?.profiles?.reasoning?.get(profileName)?.levels
        if (levels.isNullOrEmpty()) {
            return listOf(ReasoningMode.Automatic)
        }

        val supported = nonAutoReasoningModes.filter { mode ->
            levels.contains(mode.rawValue)
        }
        return if (supported.isEmpty()) {
            listOf(ReasoningMode.Automatic)
        } else {
            listOf(ReasoningMode.Automatic) + supported
        }
    }

    fun clampReasoningMode(
        mode: ReasoningMode,
        profileName: String?,
    ): ReasoningMode {
        val supported = supportedReasoningModes(profileName)
        if (supported.contains(mode)) {
            return mode
        }

        val modeIndex = ReasoningMode.entries.indexOf(mode)
        for (index in (modeIndex - 1) downTo 0) {
            val candidate = ReasoningMode.entries[index]
            if (supported.contains(candidate)) {
                return candidate
            }
        }

        return ReasoningMode.Automatic
    }

    // ── Private helpers ──

    private fun providerFor(
        providerKind: ProviderKind,
        currentTable: MetadataResponse? = table,
    ): ProviderData? {
        currentTable ?: return null
        val backendKind = kindMap[providerKind.rawValue] ?: providerKind.rawValue
        return currentTable.providers[backendKind]
    }

    private fun providerConfigFallbackOrder(kind: String): Int {
        return when (kind) {
            "openAI" -> 0
            "anthropic" -> 1
            "gemini" -> 2
            "openRouter" -> 3
            "deepseek" -> 4
            "grok" -> 5
            "moonshot" -> 6
            "mistral" -> 7
            "siliconFlow" -> 8
            "groq" -> 9
            "togetherAI" -> 10
            "fireworksAI" -> 11
            "miniMax" -> 12
            "zhipu" -> 13
            "qwen" -> 14
            else -> Int.MAX_VALUE
        }
    }

    private fun lookupCandidates(modelID: String): List<String> {
        val trimmed = modelID.trim()
        if (trimmed.isEmpty()) return emptyList()

        val normalized = SNAPSHOT_DATE_PATTERNS.fold(trimmed) { current, pattern ->
            current.replace(pattern, "")
        }

        return if (normalized == trimmed) listOf(trimmed) else listOf(trimmed, normalized)
    }

    private fun normalizeCapabilities(
        capabilities: List<ModelCapability>?,
        badgeOrder: List<ModelCapability>?,
    ): List<ModelCapability> {
        if (capabilities.isNullOrEmpty()) return emptyList()

        val mapped = capabilities.filter { it in VALID_CAPABILITIES }
        if (badgeOrder.isNullOrEmpty()) return mapped

        val hasText = ModelCapability.Text in mapped
        val nonText = mapped.filter { it != ModelCapability.Text }.toMutableList()
        nonText.sortWith { left, right ->
            val leftIndex = badgeOrder.indexOf(left)
            val rightIndex = badgeOrder.indexOf(right)
            when {
                leftIndex == -1 && rightIndex == -1 -> 0
                leftIndex == -1 -> 1
                rightIndex == -1 -> -1
                else -> leftIndex - rightIndex
            }
        }

        return if (hasText) listOf(ModelCapability.Text) + nonText else nonText
    }

    private fun normalizeProfiles(profiles: ModelProfileRefs?): ProfileRefs {
        return ProfileRefs(
            reasoning = profiles?.reasoning?.takeIf { it.isNotBlank() },
            webSearch = profiles?.webSearch?.takeIf { it.isNotBlank() },
            imageGen = profiles?.imageGen?.takeIf { it.isNotBlank() },
            generation = profiles?.generation?.takeIf { it.template?.isNotBlank() == true },
        )
    }

    private fun normalizePricingStatus(
        status: String?,
        pricing: ModelPricing?,
        pricingUnit: String,
    ): String {
        if (status == "priced" || status == "free" || status == "unknown") {
            return status
        }

        if (pricingUnit != "per_token") {
            val costPerUnit = pricing?.costPerUnit
            if (costPerUnit != null) {
                return if (costPerUnit > 0.0) "priced" else "free"
            }
            return "unknown"
        }

        val promptPerMToken = pricing?.promptPerMToken
        val completionPerMToken = pricing?.completionPerMToken

        if ((promptPerMToken != null && promptPerMToken > 0.0) || (completionPerMToken != null && completionPerMToken > 0.0)) {
            return "priced"
        }

        if (promptPerMToken == 0.0 && completionPerMToken == 0.0) {
            return "free"
        }

        return "unknown"
    }

    private fun normalizePricingUnit(value: String?): String {
        val trimmed = value?.trim().orEmpty()
        return if (trimmed.isNotEmpty()) trimmed else "per_token"
    }

    private fun normalizeSourceSummary(summary: ModelSourceSummary?): ModelSourceSummary? {
        val sourceKind = summary?.sourceKind?.trim().orEmpty()
        val sourceName = summary?.sourceName?.trim().orEmpty()
        if (sourceKind.isEmpty() || sourceName.isEmpty()) return null
        return summary
    }

    private fun normalizeUIHints(hints: ModelUIHints?): UIHints? {
        if (hints == null) return null

        val badgeOrder = hints.badgeOrder
            ?.mapNotNull { capStr ->
                runCatching {
                    ModelCapability.entries.firstOrNull { cap ->
                        cap.name.equals(capStr, ignoreCase = true) ||
                            cap.serialName() == capStr
                    }
                }.getOrNull()
            }
            ?.filter { it in VALID_CAPABILITIES && it != ModelCapability.Text }

        if (hints.groupKey == null && hints.groupName == null &&
            hints.rank == null && hints.recommended == null &&
            badgeOrder.isNullOrEmpty()
        ) {
            return null
        }

        return UIHints(
            groupKey = hints.groupKey,
            groupName = hints.groupName,
            rank = hints.rank,
            recommended = hints.recommended ?: false,
            badgeOrder = badgeOrder,
        )
    }

    private fun normalizeMetadataEvidenceViews(
        data: MetadataResponse,
        metadataRevision: String?,
        acceptPersistedProjection: Boolean,
    ): MetadataResponse = data.copy(
        providers = data.providers.mapValues { (providerKind, provider) ->
            provider.copy(
                models = provider.models.mapValues { (mapModelId, model) ->
                    normalizeModelEvidence(
                        model = model,
                        providerKind = providerKind,
                        projectedProviderKind = kindMap.entries
                            .firstOrNull { it.value == providerKind }?.key ?: providerKind,
                        mapModelId = mapModelId,
                        metadataRevision = metadataRevision,
                        allowsLeanIdentityFallback = data.view == "lean",
                        acceptPersistedProjection = acceptPersistedProjection,
                    )
                },
            )
        },
    )

    private fun normalizeModelEvidence(
        model: ModelData,
        providerKind: String,
        projectedProviderKind: String,
        mapModelId: String,
        metadataRevision: String?,
        allowsLeanIdentityFallback: Boolean,
        acceptPersistedProjection: Boolean,
    ): ModelData {
        val canonicalModelId = model.canonicalModelId?.takeIf(::isSafeEvidenceString) ?: mapModelId
        val transport = model.transport?.takeIf(::isSafeEvidenceString)
        val raw = model.capabilityEvidenceView
        val rawAbsent = raw is JsonPrimitive && raw.contentOrNull == CAPABILITY_EVIDENCE_ABSENT

        if (!rawAbsent) {
            val view = raw as? JsonObject
            val rawCandidates = view?.get("candidates") as? JsonArray
            val rawSchema = view?.get("schema")
            val schemaValid = when {
                rawSchema != null -> rawSchema.jsonPrimitive.contentOrNull == PUBLIC_CAPABILITY_EVIDENCE_SCHEMA
                else -> allowsLeanIdentityFallback
            }
            if (!schemaValid || rawCandidates == null) {
                return model.copy(
                    capabilityEvidenceView = JsonPrimitive(CAPABILITY_EVIDENCE_ABSENT),
                    capabilityEvidenceCandidates = emptyList(),
                    capabilityEvidenceOwnedKeys = emptyList(),
                    capabilityEvidenceViewMalformed = true,
                )
            }
            val ownedKeys = rawCandidates.mapNotNull(::rawEvidenceKey).distinct()
            val candidates = if (transport == null || !isSafeEvidenceString(providerKind) || !isSafeEvidenceString(canonicalModelId)) {
                emptyList()
            } else {
                rawCandidates.mapNotNull { element ->
                    decodePublicEvidenceCandidate(
                        element = element,
                        providerKind = providerKind,
                        projectedProviderKind = projectedProviderKind,
                        canonicalModelId = canonicalModelId,
                        transport = transport,
                        metadataRevision = metadataRevision,
                        allowsLeanIdentityFallback = allowsLeanIdentityFallback,
                    )
                }
            }
            return model.copy(
                capabilityEvidenceView = JsonPrimitive(CAPABILITY_EVIDENCE_ABSENT),
                capabilityEvidenceCandidates = candidates,
                capabilityEvidenceOwnedKeys = ownedKeys,
                capabilityEvidenceViewMalformed = false,
            )
        }

        if (!acceptPersistedProjection ||
            (model.capabilityEvidenceCandidates == null &&
                model.capabilityEvidenceOwnedKeys == null &&
                model.capabilityEvidenceViewMalformed == null)
        ) {
            return model.copy(
                capabilityEvidenceView = JsonPrimitive(CAPABILITY_EVIDENCE_ABSENT),
                capabilityEvidenceCandidates = null,
                capabilityEvidenceOwnedKeys = null,
                capabilityEvidenceViewMalformed = null,
            )
        }

        val persistedCandidates = if (transport == null) {
            emptyList()
        } else {
            model.capabilityEvidenceCandidates.orEmpty().mapNotNull { candidate ->
                validatePersistedEvidenceCandidate(
                    candidate = candidate,
                    providerKind = projectedProviderKind,
                    canonicalModelId = canonicalModelId,
                    transport = transport,
                    metadataRevision = metadataRevision,
                )
            }
        }
        val owned = model.capabilityEvidenceOwnedKeys.orEmpty()
            .filter(::isPublicCapabilityEvidenceKey)
            .distinct()
        return model.copy(
            capabilityEvidenceView = JsonPrimitive(CAPABILITY_EVIDENCE_ABSENT),
            capabilityEvidenceCandidates = persistedCandidates,
            capabilityEvidenceOwnedKeys = owned,

            capabilityEvidenceViewMalformed = model.capabilityEvidenceViewMalformed ?: true,
        )
    }

    private fun rawEvidenceKey(element: JsonElement): String? =
        (element as? JsonObject)
            ?.get("key")
            ?.let { it as? JsonPrimitive }
            ?.contentOrNull
            ?.takeIf(::isPublicCapabilityEvidenceKey)

    private fun decodePublicEvidenceCandidate(
        element: JsonElement,
        providerKind: String,
        projectedProviderKind: String,
        canonicalModelId: String,
        transport: String,
        metadataRevision: String?,
        allowsLeanIdentityFallback: Boolean,
    ): CapabilityEvidenceCandidateView? {
        val raw = element as? JsonObject ?: return null
        val key = raw.string("key")?.takeIf(::isPublicCapabilityEvidenceKey) ?: return null
        val support = raw.string("support")?.takeIf { it in PUBLIC_CAPABILITY_SUPPORT } ?: return null
        val source = raw.string("source") ?: return null
        val grade = raw.string("grade") ?: return null
        if (grade !in PUBLIC_CAPABILITY_SOURCE_GRADE[source].orEmpty()) return null
        if (!raw.matchesLeanIdentity("scope", "provider_model_transport", allowsLeanIdentityFallback)) return null
        if (!raw.matchesLeanIdentity("providerKind", providerKind, allowsLeanIdentityFallback)) return null
        if (!raw.matchesLeanIdentity("modelId", canonicalModelId, allowsLeanIdentityFallback)) return null
        if (!raw.matchesLeanIdentity("transport", transport, allowsLeanIdentityFallback)) return null

        val observedAt = raw.positiveLong("observedAt")
        val expiresAt = raw.positiveLong("expiresAt")

        if ((raw.containsKey("observedAt") && observedAt == null) ||
            (raw.containsKey("expiresAt") && expiresAt == null) ||
            (observedAt != null && expiresAt != null && expiresAt <= observedAt)
        ) return null
        if (source == "server_typed" && (observedAt == null || expiresAt == null)) return null

        return CapabilityEvidenceCandidateView(
            key = key,
            support = support,
            source = source,
            grade = grade,
            scope = "provider_model_transport",
            providerKind = projectedProviderKind,
            modelId = canonicalModelId,
            transport = transport,
            metadataRevision = metadataRevision?.takeIf(::isSafeEvidenceString),
            generationRevision = raw.string("generationRevision")?.takeIf(::isSafeEvidenceString),
            evidenceRevision = raw.string("evidenceRevision")?.takeIf(::isSafeEvidenceString),
            observedAt = observedAt,
            expiresAt = expiresAt,
        )
    }

    private fun validatePersistedEvidenceCandidate(
        candidate: CapabilityEvidenceCandidateView,
        providerKind: String,
        canonicalModelId: String,
        transport: String,
        metadataRevision: String?,
    ): CapabilityEvidenceCandidateView? {
        if (!isPublicCapabilityEvidenceKey(candidate.key) || candidate.support !in PUBLIC_CAPABILITY_SUPPORT) return null
        if (candidate.grade !in PUBLIC_CAPABILITY_SOURCE_GRADE[candidate.source].orEmpty()) return null
        if (candidate.scope != "provider_model_transport" ||
            candidate.providerKind != providerKind || candidate.modelId != canonicalModelId ||
            candidate.transport != transport
        ) return null
        if ((candidate.observedAt != null && candidate.observedAt <= 0) ||
            (candidate.expiresAt != null && candidate.expiresAt <= 0) ||
            (candidate.observedAt != null && candidate.expiresAt != null && candidate.expiresAt <= candidate.observedAt) ||
            (candidate.source == "server_typed" && (candidate.observedAt == null || candidate.expiresAt == null))
        ) return null
        return candidate.copy(metadataRevision = metadataRevision?.takeIf(::isSafeEvidenceString))
    }

    private fun JsonObject.string(key: String): String? =
        (get(key) as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.matchesLeanIdentity(
        key: String,
        expected: String,
        fallbackAllowed: Boolean,
    ): Boolean = if (containsKey(key)) string(key) == expected else fallbackAllowed

    private fun JsonObject.positiveLong(key: String): Long? =
        (get(key) as? JsonPrimitive)?.longOrNull?.takeIf { it > 0 }

    private fun isPublicCapabilityEvidenceKey(key: String): Boolean {
        if (key in setOf("web_search", CapabilityEvidenceFacade.VISION_INPUT, "tool_call")) return true
        val separator = key.indexOf('/')
        if (separator <= 0 || separator == key.lastIndex) return false
        val prefix = key.substring(0, separator)
        val subkey = key.substring(separator + 1)
        return prefix in setOf("reasoning_level", "generation_parameter") &&
            PUBLIC_CAPABILITY_SUBKEY.matches(subkey)
    }

    private fun isSafeEvidenceString(value: String): Boolean = value.isNotEmpty() && value.length <= 256

    private fun ModelCapability.serialName(): String = this.raw

    internal fun handleNotModified() {
        val wasConfirmed = _snapshotConfirmedThisSession
        _snapshotConfirmedThisSession = true
        // A 304 means the server confirmed this cached copy is current, so the source becomes
        // network-confirmed too. If only a 200 set FreshNetwork, days when the catalog did not change
        // (a 304 every time) would keep the CachedOffline left by cold-start hydration forever, and
        // provider detail would keep showing "Showing results from the last sync".
        // Set it before the emit below so subscribers read the new source when the refresh arrives.
        if (table != null) _metadataSource = MetadataSource.FreshNetwork
        if (!wasConfirmed) {
            val current = evidencePublication
            evidencePublication = current.copy(contentRevision = current.contentRevision + 1)
        }
        table?.let { current ->
            _refreshEvents.tryEmit(
                RefreshEvent(
                    version = current.version,
                    contractVersion = current.contractVersion,
                    contentRevision = evidencePublication.contentRevision,
                )
            )
        }
    }

    private suspend fun fetchMetadata(
        bypassETag: Boolean = false,
        requestedKeys: Set<String> = emptySet(),
    ) {
        fetchMutex.withLock {
            withContext(ioDispatcher) {
                val split = metadataSplitTransport
                if (split == null) {
                    fetchLeanLocked(bypassETag)
                } else {
                    refreshSplitLocked(split, bypassETag, requestedKeys)
                }
            }
        }
    }

    /** The whole-payload lean path: no split transport injected, or an older server answered view=index with 400. */
    private suspend fun fetchLeanLocked(bypassETag: Boolean) {
        val startedAtMs = nowMillis()
        var phase = "fetch"
        var responseBytes = 0L
        var statusCode: Int? = null
        try {
            val response = metadataTransport.fetch(
                ifNoneMatch = storedETag.takeUnless { bypassETag },
            )
            statusCode = response.statusCode
            responseBytes = response.responseBytes
            if (statusCode == HttpURLConnection.HTTP_NOT_MODIFIED) {
                handleNotModified()
                phase = "cache_write"
                // A 304 refreshes the timestamp only instead of rewriting the whole payload.
                // The body is written again only when the row is missing (for example the last
                // Room write failed and the snapshot lives only in memory).
                val touched = metadataCacheDao?.touch(MetadataCacheEntity.SINGLETON_KEY, nowMillis()) ?: 1
                if (touched == 0) {
                    evidencePublication.table?.let { safeSnapshot ->
                        persistCache(
                            RoomCacheEnvelope(
                                data = safeSnapshot,
                                timestamp = nowMillis(),
                                eTag = storedETag,
                                modelFactsETag = storedModelFactsETag,
                            )
                        )
                    }
                }
                return
            }
            if (statusCode != HttpURLConnection.HTTP_OK) {
                reportFailure(
                    phase = phase,
                    startedAtMs = startedAtMs,
                    responseBytes = responseBytes,
                    statusCode = statusCode,
                    error = MetadataHttpStatusException(statusCode),
                )
                return
            }

            val body = response.body ?: throw EOFException("metadata response body missing")
            phase = "decode"
            val decoded = decodeMetadataPayload(body)
            // Older server or rollback: lean becomes the only source, and the split state and rows
            // go with it, or the next cold start would let a stale index override this newer payload.
            val leavingSplit = splitIndex != null || loadedCatalogs.isNotEmpty()
            splitIndex = null
            loadedCatalogs.clear()
            confirmedCatalogKeys.clear()
            legacyLeanFallback = null
            publishNetworkSnapshot(decoded, response.eTag)
            phase = "cache_write"
            if (leavingSplit) metadataCacheDao?.deleteAllExcept(MetadataCacheEntity.SINGLETON_KEY)
            persistCache(
                RoomCacheEnvelope(
                    data = evidencePublication.table ?: decoded,
                    timestamp = nowMillis(),
                    eTag = response.eTag,
                    modelFactsETag = storedModelFactsETag,
                )
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure(phase, startedAtMs, responseBytes, statusCode, error)
        } catch (error: Error) {
            try {
                reportFailure(phase, startedAtMs, responseBytes, statusCode, error)
            } catch (reportingFailure: Throwable) {
                error.addSuppressed(reportingFailure)
            }
            throw error
        }
    }

    private suspend fun fetchModelFacts() {
        modelFactsFetchMutex.withLock {
            withContext(ioDispatcher) {
                val startedAtMs = nowMillis()
                var responseBytes = 0L
                var statusCode: Int? = null
                try {
                    val response = modelFactsTransport.fetch(storedModelFactsETag)
                    statusCode = response.statusCode
                    responseBytes = response.responseBytes
                    if (statusCode == HttpURLConnection.HTTP_NOT_MODIFIED) return@withContext
                    if (statusCode == HttpURLConnection.HTTP_NOT_FOUND) {
                        storedModelFactsETag = null
                        val current = evidencePublication.table ?: return@withContext
                        val next = current.copy(modelFacts = null, modelFactsRevision = null)
                        val nextContentRevision = evidencePublication.contentRevision + 1
                        evidencePublication = evidencePublication.copy(
                            table = next,
                            contentRevision = nextContentRevision,
                        )
                        table = next
                        _refreshEvents.tryEmit(
                            RefreshEvent(
                                version = next.version,
                                contractVersion = next.contractVersion,
                                contentRevision = nextContentRevision,
                            )
                        )
                        persistModelFacts(next)
                        return@withContext
                    }
                    if (statusCode != HttpURLConnection.HTTP_OK) {
                        reportFailure(
                            phase = "model_facts_fetch",
                            startedAtMs = startedAtMs,
                            responseBytes = responseBytes,
                            statusCode = statusCode,
                            error = MetadataHttpStatusException(statusCode),
                        )
                        return@withContext
                    }
                    val body = response.body ?: throw EOFException("model facts response body missing")
                    val payload = json.decodeFromString<WrappedModelFactsResponse>(body).data
                    val current = evidencePublication.table ?: return@withContext
                    val next = current.copy(
                        modelFacts = payload.facts,
                        modelFactsRevision = payload.revision,
                    )
                    val nextContentRevision = evidencePublication.contentRevision + 1
                    evidencePublication = evidencePublication.copy(
                        table = next,
                        contentRevision = nextContentRevision,
                    )
                    table = next
                    storedModelFactsETag = response.eTag
                    _refreshEvents.tryEmit(
                        RefreshEvent(
                            version = next.version,
                            contractVersion = next.contractVersion,
                            contentRevision = nextContentRevision,
                        )
                    )
                    persistModelFacts(next)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    reportFailure("model_facts_fetch", startedAtMs, responseBytes, statusCode, error)
                } catch (error: Error) {
                    reportFailure("model_facts_fetch", startedAtMs, responseBytes, statusCode, error)
                    throw error
                }
            }
        }
    }

    // Index + per-provider catalog.

    private sealed interface IndexFetch {
        /** An older server answered view=index with 400: fall back to lean. */
        data object Unsupported : IndexFetch
        data object Failed : IndexFetch
        data object NotModified : IndexFetch
        class Fetched(val index: SplitIndexState) : IndexFetch
        /** The schema 2 revision equals the cache's: data is reused from [index] (only the ETag changed, already persisted), handled as a 304. */
        class Unchanged(val index: SplitIndexState) : IndexFetch
    }

    private enum class CatalogSyncResult { Current, Adopted, Mismatch, Failed }

    private class CatalogRejectedException(reason: String) :
        IllegalStateException("metadata catalog rejected: $reason")

    private class CatalogRevisionMismatchException(provider: String) :
        IllegalStateException("metadata $REVISION_MISMATCH: $provider")

    /** The catalog revision still disagrees with the index registration after the refetch: keep last-good and report revision_mismatch. */
    private fun reportRevisionMismatch(provider: String) {
        reportFailure(
            CATALOG_SYNC_PHASE, nowMillis(), 0L, null,
            CatalogRevisionMismatchException(provider),
            mapOf("reason" to REVISION_MISMATCH, "provider_kind" to catalogProviderKindLabel(provider)),
        )
    }

    private suspend fun refreshSplitLocked(
        split: MetadataSplitTransport,
        bypassETag: Boolean,
        requestedKeys: Set<String>,
    ) {
        // Each explicit refresh lets pending providers trigger once more, but never spins within a round.
        autoRequestedCatalogKeys.clear()
        sessionRequestedCatalogKeys.addAll(requestedKeys)
        val previous = splitIndex
        val index: SplitIndexState
        var indexChanged = false
        when (val fetched = fetchIndexLocked(split, previous?.eTag.takeUnless { bypassETag }, previous, bypassEdgeCache = false)) {
            IndexFetch.Unsupported -> {
                // The client shipped before the server: a cold start must not fail because of it.
                fetchLeanLocked(bypassETag = bypassETag || previous != null)
                return
            }
            IndexFetch.Failed -> return
            IndexFetch.NotModified -> index = previous ?: return
            is IndexFetch.Unchanged -> {
                index = fetched.index
                splitIndex = index
            }
            is IndexFetch.Fetched -> {
                index = fetched.index
                indexChanged = true
            }
        }
        if (previous == null && evidencePublication.loadedProviderKeys == null) {
            // First switch from a full lean payload (old cache or lean fallback) to split: keep it as each provider's last good.
            // The bundled snapshot is not used as last-good: build-time data must not mix into the online catalog.
            table?.takeUnless { bundledSnapshotActive }?.let { legacyLeanFallback = it }
        }
        val (needed, demandKnown) = neededCatalogKeys(index, requestedKeys)
        syncAndPublishLocked(
            split = split,
            initialIndex = index,
            keys = needed,
            indexChanged = indexChanged,
            indexConfirmed = true,
            firstSplitPublication = previous == null,
            demandComplete = demandKnown,
        )
    }

    /**
     * Syncs a set of catalogs and publishes one snapshot if anything changed. When a catalog's
     * revision differs from the index (a snapshot activated mid-sync), the index is fetched once
     * more and the catalog retried; if it still differs, last good is kept and a redacted
     * diagnostic is reported.
     */
    private suspend fun syncAndPublishLocked(
        split: MetadataSplitTransport,
        initialIndex: SplitIndexState,
        keys: Set<String>,
        indexChanged: Boolean,
        indexConfirmed: Boolean,
        firstSplitPublication: Boolean,
        /** Whether [keys] covers the full needed set; only then may the legacy lean snapshot retire. */
        demandComplete: Boolean,
    ) {
        var index = initialIndex
        var changed = indexChanged
        var results = syncCatalogsLocked(split, index, keys)
        val mismatched = results.filterValues { it == CatalogSyncResult.Mismatch }.keys
        if (mismatched.isNotEmpty()) {
            // The edge cache may serve a new index with an old catalog, and refetching the index at the same URL hits the same edge copy: this time pass fresh to go straight to origin.
            val refetched = fetchIndexLocked(split, index.eTag, index, bypassEdgeCache = true)
            if (refetched is IndexFetch.Fetched) {
                index = refetched.index
                changed = true
            } else if (refetched is IndexFetch.Unchanged) {
                index = refetched.index
                if (!changed) splitIndex = index
            }
            val retried = syncCatalogsLocked(split, index, mismatched)
            results = results + retried
            // Still out of step after refetching the index: report revision_mismatch once per provider per sync round.
            retried.filterValues { it == CatalogSyncResult.Mismatch }.keys.forEach { key ->
                reportRevisionMismatch(key)
            }
        }
        if (changed) {
            val previousIndex = splitIndex
            splitIndex = index
            // After the index changes, a last good whose revision no longer matches is no longer confirmed this session.
            confirmedCatalogKeys.removeAll { key ->
                loadedCatalogs[key]?.catalog?.catalogRevision != index.catalogRevisions[key]
            }
            persistSplitIndexWithRetiredBackfill(previous = previousIndex, next = index)
        }
        val adopted = results.values.any { it == CatalogSyncResult.Adopted }
        val retiredLegacy = demandComplete && retireLegacyLeanIfComplete(keys)
        if (changed || adopted || retiredLegacy || firstSplitPublication) {
            if (publishSplitSnapshotReporting(index, indexConfirmed) && indexConfirmed) storedETag = null
        } else if (indexConfirmed) {
            handleNotModified()
        }
    }

    private suspend fun fetchIndexLocked(
        split: MetadataSplitTransport,
        ifNoneMatch: String?,
        /** Baseline for revision comparison: the current index the caller holds (may not yet be written back to [splitIndex]). */
        cached: SplitIndexState?,
        /** True only for the one refetch after a revision mismatch (contract section 5.9). */
        bypassEdgeCache: Boolean,
    ): IndexFetch {
        val startedAtMs = nowMillis()
        var phase = "index_fetch"
        var responseBytes = 0L
        var statusCode: Int? = null
        return try {
            val response = split.fetchIndex(ifNoneMatch, cacheBust = if (bypassEdgeCache) ai.oriveo.community.core.util.generateUuidString() else null)
            statusCode = response.statusCode
            responseBytes = response.responseBytes
            when (statusCode) {
                HttpURLConnection.HTTP_NOT_MODIFIED -> if (ifNoneMatch != null && splitIndex != null) {
                    touchRow(MetadataCacheEntity.INDEX_KEY)
                    IndexFetch.NotModified
                } else {
                    reportFailure(phase, startedAtMs, responseBytes, statusCode, MetadataHttpStatusException(statusCode))
                    IndexFetch.Failed
                }
                HttpURLConnection.HTTP_BAD_REQUEST -> IndexFetch.Unsupported
                HttpURLConnection.HTTP_OK -> {
                    phase = "index_decode"
                    val body = response.body ?: throw EOFException("metadata index body missing")
                    val rawData = MetadataCatalogAssembly.unwrapData(json.parseToJsonElement(body))
                        ?.takeIf { (it["view"] as? JsonPrimitive)?.contentOrNull == "index" }
                        ?: throw IllegalStateException("metadata index view missing")
                    var droppedProviders = emptyList<MetadataPayloadSchemaValidator.DroppedProvider>()
                    val data = if (isMetadataSchemaV2(rawData)) {
                        // Schema 2: a bad envelope rejects the whole payload (falls into catch -> Failed, keeping last-good); a bad provider drops only that provider,
                        // but entry reports wait until the revision decision adopts it (same order as Web: rejected / 304-treated responses report no entries).
                        val result = payloadSchemaValidator().decode(rawData)
                        result.envelopeError?.let {
                            throw IllegalStateException("metadata index schema rejected: ${it.keyword} at ${it.instancePath}")
                        }
                        droppedProviders = result.droppedProviders
                        val droppedIds = result.droppedProviders.mapTo(hashSetOf()) { it.providerId }
                        val providers = rawData["providers"] as? JsonObject
                        if (droppedIds.isEmpty() || providers == null) rawData
                        else JsonObject(rawData + ("providers" to JsonObject(providers - droppedIds)))
                    } else {
                        rawData
                    }
                    // Revisions are compared only within one schema: schema 2 and 3 share metadataRevision, and across schemas (e.g. the cache is still a schema 2 index after an upgrade)
                    // the new data is always accepted and replaces the old, otherwise the old index's catalogRevision would never match the new catalog.
                    val sameSchema = cached?.data?.let(::bodyMetadataSchema) == bodyMetadataSchema(rawData)
                    val incomingRevision = schemaV2Revision(rawData)?.takeIf { sameSchema }
                    val cachedRevision = cached?.data?.let { (it["metadataRevision"] as? JsonPrimitive)?.longOrNull }
                    when (incomingRevision?.let { compareMetadataRevision(cachedRevision, it) }) {
                        MetadataRevisionVerdict.Reject -> {
                            reportRevisionRegressed(phase, startedAtMs, responseBytes, statusCode, INDEX_REVISION_PROVIDER)
                            return IndexFetch.Failed
                        }
                        MetadataRevisionVerdict.Unchanged -> if (cached != null) {
                            // Equal is treated as 304: data unchanged, the ETag is refreshed with the data in one upsert.
                            val refreshed = SplitIndexState(cached.data, response.eTag, cached.catalogRevisions)
                            persistSplitIndex(refreshed)
                            return IndexFetch.Unchanged(refreshed)
                        }
                        else -> Unit
                    }
                    droppedProviders.forEach { dropped ->
                        reportEntryInvalid(
                            MODEL_ENTRY_INVALID, phase, startedAtMs, responseBytes, statusCode,
                            dropped.providerId, null, dropped.error,
                        )
                    }
                    IndexFetch.Fetched(
                        SplitIndexState(
                            data = data,
                            eTag = response.eTag,
                            catalogRevisions = MetadataCatalogAssembly.indexCatalogRevisions(data),
                        ),
                    )
                }
                else -> {
                    reportFailure(phase, startedAtMs, responseBytes, statusCode, MetadataHttpStatusException(statusCode))
                    IndexFetch.Failed
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure(phase, startedAtMs, responseBytes, statusCode, error)
            IndexFetch.Failed
        }
    }

    private suspend fun syncCatalogsLocked(
        split: MetadataSplitTransport,
        index: SplitIndexState,
        keys: Set<String>,
    ): Map<String, CatalogSyncResult> = coroutineScope {
        keys.filter { it in index.catalogRevisions }
            .map { key -> key to async { syncOneCatalog(split, index, key) } }
            .associate { (key, result) -> key to result.await() }
    }

    private suspend fun syncOneCatalog(
        split: MetadataSplitTransport,
        index: SplitIndexState,
        key: String,
    ): CatalogSyncResult {
        val expectedRevision = index.catalogRevisions.getValue(key)
        val cached = loadedCatalogs[key]
        if (cached != null && cached.catalog.catalogRevision == expectedRevision) {
            // Revision equals the index: already current, no request.
            confirmedCatalogKeys.add(key)
            return CatalogSyncResult.Current
        }
        val startedAtMs = nowMillis()
        var phase = "catalog_fetch"
        var responseBytes = 0L
        var statusCode: Int? = null
        try {
            val response = split.fetchCatalog(key, cached?.eTag, revision = expectedRevision)
            statusCode = response.statusCode
            responseBytes = response.responseBytes
            when (statusCode) {
                // 304: the bytes on hand are still the current catalog, yet their revision differs from the index.
                HttpURLConnection.HTTP_NOT_MODIFIED ->
                    return if (cached != null) CatalogSyncResult.Mismatch else {
                        reportFailure(phase, startedAtMs, responseBytes, statusCode, MetadataHttpStatusException(statusCode))
                        CatalogSyncResult.Failed
                    }
                HttpURLConnection.HTTP_OK -> Unit
                else -> {
                    // A 404 is never an empty catalog: keep last good, so this provider stays pending or on its old catalog.
                    reportFailure(phase, startedAtMs, responseBytes, statusCode, MetadataHttpStatusException(statusCode))
                    return CatalogSyncResult.Failed
                }
            }
            phase = "catalog_decode"
            val body = response.body ?: throw EOFException("metadata catalog body missing")
            val rawData = MetadataCatalogAssembly.unwrapData(json.parseToJsonElement(body))
                ?: throw CatalogRejectedException("body")
            // A schema 3 compact catalog is first expanded to its schema 2 equivalent; validation, expansion and persistence all happen after expansion; an unresolved ref rejects the whole catalog.
            val data = when (val compact = MetadataCatalogAssembly.expandCompactCatalog(rawData)) {
                is MetadataCatalogAssembly.CompactExpansion.Rejected -> throw CatalogRejectedException(compact.reason)
                is MetadataCatalogAssembly.CompactExpansion.Expanded -> compact.data
            }
            // Schema 2: a bad envelope rejects the whole payload (keeping last-good); a bad model drops only that entry and is reported one by one after adoption.
            val droppedModels = if (isMetadataSchemaV2(data)) {
                val result = payloadSchemaValidator().decode(data)
                result.envelopeError?.let { throw CatalogRejectedException("schema ${it.keyword} at ${it.instancePath}") }
                result.droppedModels
            } else {
                emptyList()
            }
            val incomingRevision = schemaV2Revision(data)
            // Same as the index: compare revisions only against a cache from the same source schema; across schemas accept the new data.
            val incomingSchema = bodyMetadataSchema(rawData)
            val sameSchema = cached == null || (cached.payloadSchema ?: 2) == incomingSchema
            when (incomingRevision?.takeIf { sameSchema }?.let { compareMetadataRevision(cached?.payloadRevision, it) }) {
                MetadataRevisionVerdict.Reject -> {
                    reportRevisionRegressed(phase, startedAtMs, responseBytes, statusCode, key)
                    return CatalogSyncResult.Failed
                }
                MetadataRevisionVerdict.Unchanged -> if (cached != null) {
                    // Equal: upsert only the new ETag together with this provider's cache row in one step; handled like a 304 as far as out-of-step generations go.
                    loadedCatalogs[key] = LoadedCatalog(response.eTag, cached.catalog, cached.payloadRevision, cached.payloadSchema)
                    refreshCatalogRowETag(key, response.eTag)
                    return CatalogSyncResult.Mismatch
                }
                else -> Unit
            }
            val droppedIds = droppedModels.mapTo(linkedSetOf()) { it.modelId }
            val expansion = when (val result = MetadataCatalogAssembly.expandCatalog(data, key, droppedIds)) {
                is MetadataCatalogAssembly.Expansion.Rejected -> throw CatalogRejectedException(result.reason)
                is MetadataCatalogAssembly.Expansion.Accepted -> result
            }
            // Tombstone snapshot (section 9.8): schema 3 uses the catalog's own; schema 1 / 2 take this provider's retiredModels from the index at the moment of adoption.
            val catalog = expansion.catalog.let { expanded ->
                if (expanded.retiredModels != null) expanded
                else expanded.copy(retiredModels = indexRetiredModels(index.data, key))
            }
            if (catalog.catalogRevision != expectedRevision) return CatalogSyncResult.Mismatch
            droppedModels.forEach { dropped ->
                reportEntryInvalid(
                    MODEL_ENTRY_INVALID, phase, startedAtMs, responseBytes, statusCode,
                    key, dropped.modelId, dropped.error,
                )
            }
            // The shared schema check cannot see parametersRef (profile -> generationParameters); it is only dropped during expansion, so report it here.
            expansion.droppedRefs.forEach { dropped ->
                reportEntryInvalid(
                    MODEL_ENTRY_INVALID, phase, startedAtMs, responseBytes, statusCode,
                    key, dropped.modelId,
                    MetadataPayloadSchemaValidator.SchemaError("/${dropped.reason}", UNRESOLVED_REF_KEYWORD),
                )
            }
            loadedCatalogs[key] = LoadedCatalog(
                eTag = response.eTag,
                catalog = catalog,
                payloadRevision = incomingRevision,
                payloadSchema = incomingSchema,
            )
            confirmedCatalogKeys.add(key)
            phase = "cache_write"
            // What is persisted is the copy with bad entries already dropped: a cold-start replay from the cache skips schema validation, so bad entries must not sneak back in.
            persistCatalogRow(
                key,
                response.eTag,
                withRetiredSnapshot(MetadataCatalogAssembly.withoutModels(data, droppedIds), catalog.retiredModels),
                incomingRevision,
                incomingSchema,
            )
            return CatalogSyncResult.Adopted
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure(phase, startedAtMs, responseBytes, statusCode, error)
            return if (phase == "cache_write") CatalogSyncResult.Adopted else CatalogSyncResult.Failed
        }
    }

    /**
     * The needed set = configured official providers, plus the official whitelist when a relay
     * exists, plus providers requested ad hoc; limited to providers the index lists a catalog for.
     */
    private suspend fun neededCatalogKeys(
        index: SplitIndexState,
        requestedKeys: Set<String>,
    ): Pair<Set<String>, Boolean> {
        val demand = try {
            catalogDemandSupplier?.invoke()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
        val keys = linkedSetOf<String>()
        demand?.providerKinds?.forEach { kind -> catalogKeyFor(kind)?.let(keys::add) }
        if (demand?.hasRelay == true) {
            keys += MetadataCatalogAssembly.relayWhitelist(index.data)
                ?: FALLBACK_RELAY_RUNTIME_CONFIG.officialProviderWhitelist
        }
        keys += requestedKeys
        keys += sessionRequestedCatalogKeys
        return keys.filterTo(linkedSetOf()) { it in index.catalogRevisions } to (demand != null)
    }

    /** Fetches one pending provider in the background; touches nothing else and never triggers a full reload. */
    private fun requestCatalogInBackground(key: String) {
        val split = metadataSplitTransport ?: return
        appContext ?: return
        if (splitIndex == null) return
        if (!autoRequestedCatalogKeys.add(key)) return
        sessionRequestedCatalogKeys.add(key)
        backgroundScope.launch {
            fetchMutex.withLock {
                withContext(ioDispatcher) {
                    val index = splitIndex ?: return@withContext
                    if (key in evidencePublication.loadedProviderKeys.orEmpty()) return@withContext
                    syncAndPublishLocked(
                        split = split,
                        initialIndex = index,
                        keys = setOf(key),
                        indexChanged = false,
                        indexConfirmed = false,
                        firstSplitPublication = false,
                        demandComplete = false,
                    )
                }
            }
        }
    }

    /** Once every needed catalog is in, the legacy single-row lean snapshot retires (model facts move to their own row first). */
    private suspend fun retireLegacyLeanIfComplete(neededKeys: Set<String>): Boolean {
        legacyLeanFallback ?: return false
        if (!neededKeys.all { loadedCatalogs.containsKey(it) }) return false
        legacyLeanFallback = null
        val dao = metadataCacheDao ?: return true
        val startedAtMs = nowMillis()
        try {
            table?.takeIf { it.modelFacts != null }?.let { current -> persistModelFactsRow(current) }
            dao.delete(MetadataCacheEntity.SINGLETON_KEY)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_write", startedAtMs, 0L, null, error)
        }
        return true
    }

    /**
     * Assembles the index and loaded catalogs into a lean-shaped snapshot and publishes it, still
     * through the lean decode and evidence normalization. A provider without a catalog yet uses
     * the legacy lean cache as last good when it has one, and stays pending otherwise.
     */
    private fun publishSplitSnapshotReporting(index: SplitIndexState, indexConfirmed: Boolean): Boolean {
        val startedAtMs = nowMillis()
        return try {
            publishSplitSnapshot(index, indexConfirmed)
            true
        } catch (error: Exception) {
            reportFailure("decode", startedAtMs, 0L, null, error)
            false
        }
    }

    private fun publishSplitSnapshot(
        index: SplitIndexState,
        indexConfirmed: Boolean,
        modelFacts: Map<String, ModelFacts>? = table?.modelFacts,
        modelFactsRevision: String? = table?.modelFactsRevision,
    ) {
        val catalogs = loadedCatalogs
            .filterKeys { it in index.catalogRevisions }
            .mapValues { it.value.catalog }
        val assembled = MetadataCatalogAssembly.assembleLeanData(index.data, catalogs)
        val decoded = json.decodeFromJsonElement(MetadataResponse.serializer(), assembled).copy(
            modelFacts = modelFacts,
            modelFactsRevision = modelFactsRevision,
        )
        val normalized = normalizeMetadataEvidenceViews(
            data = decoded,
            metadataRevision = index.eTag,
            acceptPersistedProjection = false,
        )
        val legacy = legacyLeanFallback
        val overlayKeys = legacy?.providers.orEmpty()
            .filter { (key, provider) ->
                key !in catalogs && key in normalized.providers && provider.models.isNotEmpty()
            }
            .keys
        // Tombstones for the lean fallback follow the same convention as the catalog snapshot (section 9.8): a schema 3 index carries no tombstones, so the provider's retiredModels in the lean row is the snapshot.
        val compactIndex = bodyMetadataSchema(index.data) == 3
        val safe = if (legacy == null || overlayKeys.isEmpty()) normalized else normalized.copy(
            providers = normalized.providers.mapValues { (key, provider) ->
                val old = legacy.providers[key]
                if (key in overlayKeys && old != null) {
                    provider.copy(
                        resolveMap = old.resolveMap,
                        models = old.models,
                        retiredModels = if (compactIndex) old.retiredModels else provider.retiredModels,
                    )
                } else {
                    provider
                }
            },
            generationParameterTables = legacy.generationParameterTables.orEmpty() +
                normalized.generationParameterTables.orEmpty(),
        )
        val nextRevision = evidencePublication.contentRevision + 1
        evidencePublication = EvidencePublication(
            table = safe,
            metadataRevision = index.eTag,
            contentRevision = nextRevision,
            loadedProviderKeys = catalogs.keys + overlayKeys,
        )
        table = safe
        bundledSnapshotActive = false
        if (indexConfirmed) {
            _metadataSource = MetadataSource.FreshNetwork
            _snapshotConfirmedThisSession = true
        } else if (_metadataSource == MetadataSource.Unknown) {
            _metadataSource = MetadataSource.CachedOffline
        }
        _refreshEvents.tryEmit(
            RefreshEvent(
                version = safe.version,
                contractVersion = safe.contractVersion,
                contentRevision = nextRevision,
            )
        )
    }

    private class SplitCacheSnapshot(
        val index: SplitIndexState,
        val catalogs: Map<String, LoadedCatalog>,
        val modelFacts: ModelFactsCacheEnvelope?,
        val updatedAtMs: Long,
        val contractVersion: Int,
    )

    /** Reads the split cache back; a bad row drops only that row and never blocks startup. */
    private suspend fun loadSplitCache(): SplitCacheSnapshot? {
        val dao = metadataCacheDao ?: return null
        val startedAtMs = nowMillis()
        val indexPayload = try {
            readPersistedPayload(dao, MetadataCacheEntity.INDEX_KEY)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_read", startedAtMs, 0L, null, error)
            return null
        } ?: return null
        val indexData = decodeCacheRow(dao, MetadataCacheEntity.INDEX_KEY, indexPayload) {
            json.decodeFromString<SplitIndexCacheEnvelope>(it)
        }?.takeIf { (it.data["view"] as? JsonPrimitive)?.contentOrNull == "index" } ?: return null
        val index = SplitIndexState(
            data = indexData.data,
            eTag = indexData.eTag,
            catalogRevisions = MetadataCatalogAssembly.indexCatalogRevisions(indexData.data),
        )
        val catalogs = linkedMapOf<String, LoadedCatalog>()
        for (key in index.catalogRevisions.keys) {
            val rowKey = MetadataCacheEntity.CATALOG_KEY_PREFIX + key
            val payload = try {
                readPersistedPayload(dao, rowKey)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                reportFailure("cache_read", startedAtMs, 0L, null, error)
                null
            } ?: continue
            val envelope = decodeCacheRow(dao, rowKey, payload) {
                json.decodeFromString<CatalogCacheEnvelope>(it)
            } ?: continue
            when (val expansion = MetadataCatalogAssembly.expandCatalog(envelope.data, key)) {
                is MetadataCatalogAssembly.Expansion.Accepted ->
                    catalogs[key] = LoadedCatalog(
                        eTag = envelope.eTag,
                        catalog = expansion.catalog,
                        payloadRevision = envelope.payloadRevision,
                        payloadSchema = envelope.payloadSchema,
                    )
                is MetadataCatalogAssembly.Expansion.Rejected -> {
                    reportFailure("cache_decode", startedAtMs, payload.length.toLong(), null, CatalogRejectedException(expansion.reason))
                    deleteRowQuietly(dao, rowKey)
                }
            }
        }
        val facts = try {
            readPersistedPayload(dao, MetadataCacheEntity.MODEL_FACTS_KEY)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }?.let { payload ->
            decodeCacheRow(dao, MetadataCacheEntity.MODEL_FACTS_KEY, payload) {
                json.decodeFromString<ModelFactsCacheEnvelope>(it)
            }
        }
        val updatedAtMs = try {
            dao.updatedAtMs(MetadataCacheEntity.INDEX_KEY) ?: 0L
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            0L
        }
        return SplitCacheSnapshot(
            index = index,
            catalogs = catalogs,
            modelFacts = facts,
            updatedAtMs = updatedAtMs,
            contractVersion = (indexData.data["contractVersion"] as? JsonPrimitive)?.intOrNull ?: 0,
        )
    }

    private suspend fun <T> decodeCacheRow(
        dao: MetadataCacheDao,
        key: String,
        payload: String,
        decode: (String) -> T,
    ): T? {
        val startedAtMs = nowMillis()
        return try {
            decode(payload)
        } catch (error: Exception) {
            reportFailure("cache_decode", startedAtMs, payload.length.toLong(), null, error)
            deleteRowQuietly(dao, key)
            null
        }
    }

    private suspend fun deleteRowQuietly(dao: MetadataCacheDao, key: String) {
        try {
            dao.delete(key)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_clear", nowMillis(), 0L, null, error)
        }
    }

    /** A 304 refreshes the timestamp only and never rewrites the body. */
    private suspend fun touchRow(key: String) {
        val dao = metadataCacheDao ?: return
        val startedAtMs = nowMillis()
        try {
            dao.touch(key, nowMillis())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_write", startedAtMs, 0L, null, error)
        }
    }

    private fun splitIndexEntity(index: SplitIndexState) = MetadataCacheEntity(
        key = MetadataCacheEntity.INDEX_KEY,
        payload = json.encodeToString(
            SplitIndexCacheEnvelope.serializer(),
            SplitIndexCacheEnvelope(eTag = index.eTag, data = index.data),
        ),
        version = (index.data["version"] as? JsonPrimitive)?.intOrNull ?: 0,
        contractVersion = (index.data["contractVersion"] as? JsonPrimitive)?.intOrNull ?: 0,
        updatedAtMs = nowMillis(),
    )

    private suspend fun persistSplitIndex(index: SplitIndexState) {
        val dao = metadataCacheDao ?: return
        val startedAtMs = nowMillis()
        try {
            dao.upsert(splitIndexEntity(index))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_write", startedAtMs, 0L, null, error)
        }
    }

    /** The provider's retiredModels in the index; recorded as an empty array when none (the snapshot was taken, there are just no tombstones). */
    private fun indexRetiredModels(indexData: JsonObject, key: String): JsonElement =
        ((indexData["providers"] as? JsonObject)?.get(key) as? JsonObject)?.get("retiredModels")
            ?.takeUnless { it is JsonNull }
            ?: JsonArray(emptyList())

    private fun withRetiredSnapshot(data: JsonObject, snapshot: JsonElement?): JsonObject =
        if (snapshot == null) data else JsonObject(data + ("retiredModels" to snapshot))

    /**
     * Writes the next-generation index. On the first switch from a schema 2 index to a schema 3 index, backfills a snapshot for old cache rows without a tombstone snapshot:
     * take the tombstones of this provider from the replaced old index (it is the index generation those catalogs were adopted under). The backfilled catalog rows and the new index row
     * are written in the same Room transaction; if any fails everything rolls back and the persisted index does not advance (the next cold start still takes tombstones from the schema 2 index);
     * in memory this session uses the new index and the backfilled snapshots as usual.
     */
    private suspend fun persistSplitIndexWithRetiredBackfill(previous: SplitIndexState?, next: SplitIndexState) {
        val transition = previous != null && bodyMetadataSchema(next.data) == 3 && bodyMetadataSchema(previous.data) != 3
        val backfill = if (!transition) emptyMap() else loadedCatalogs.toMap()
            .filterValues { it.catalog.retiredModels == null }
            .mapValues { (key, _) -> indexRetiredModels(checkNotNull(previous).data, key) }
        if (backfill.isEmpty()) {
            persistSplitIndex(next)
            return
        }
        for ((key, snapshot) in backfill) {
            loadedCatalogs.computeIfPresent(key) { _, loaded ->
                LoadedCatalog(loaded.eTag, loaded.catalog.copy(retiredModels = snapshot), loaded.payloadRevision, loaded.payloadSchema)
            }
        }
        val dao = metadataCacheDao ?: return
        val startedAtMs = nowMillis()
        try {
            val rows = backfill.mapNotNull { (key, snapshot) ->
                val payload = readPersistedPayload(dao, MetadataCacheEntity.CATALOG_KEY_PREFIX + key) ?: return@mapNotNull null
                val envelope = json.decodeFromString<CatalogCacheEnvelope>(payload)
                catalogRowEntity(
                    key, envelope.eTag, withRetiredSnapshot(envelope.data, snapshot), envelope.payloadRevision, envelope.payloadSchema,
                )
            }
            dao.upsertAllInTransaction(rows + splitIndexEntity(next))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_write", startedAtMs, 0L, null, error)
        }
    }

    /** When the revision is equal only the ETag changes: read back this provider's cache row and upsert the same data with the new ETag. */
    private suspend fun refreshCatalogRowETag(key: String, eTag: String?) {
        val dao = metadataCacheDao ?: return
        val startedAtMs = nowMillis()
        try {
            val payload = readPersistedPayload(dao, MetadataCacheEntity.CATALOG_KEY_PREFIX + key) ?: return
            val envelope = json.decodeFromString<CatalogCacheEnvelope>(payload)
            persistCatalogRow(key, eTag, envelope.data, envelope.payloadRevision, envelope.payloadSchema)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure("cache_write", startedAtMs, 0L, null, error)
        }
    }

    private suspend fun persistCatalogRow(
        key: String,
        eTag: String?,
        data: JsonObject,
        payloadRevision: Long?,
        payloadSchema: Int?,
    ) {
        val dao = metadataCacheDao ?: return
        dao.upsert(catalogRowEntity(key, eTag, data, payloadRevision, payloadSchema))
    }

    private fun catalogRowEntity(
        key: String,
        eTag: String?,
        data: JsonObject,
        payloadRevision: Long?,
        payloadSchema: Int?,
    ): MetadataCacheEntity {
        val index = splitIndex
        return MetadataCacheEntity(
            key = MetadataCacheEntity.CATALOG_KEY_PREFIX + key,
            payload = json.encodeToString(
                CatalogCacheEnvelope.serializer(),
                CatalogCacheEnvelope(eTag = eTag, data = data, payloadRevision = payloadRevision, payloadSchema = payloadSchema),
            ),
            version = (index?.data?.get("version") as? JsonPrimitive)?.intOrNull ?: 0,
            contractVersion = (index?.data?.get("contractVersion") as? JsonPrimitive)?.intOrNull ?: 0,
            updatedAtMs = nowMillis(),
        )
    }

    /** Split mode writes the separate model_facts row; lean mode keeps the single-row envelope. */
    private suspend fun persistModelFacts(next: MetadataResponse) {
        if (splitIndex != null) {
            persistModelFactsRow(next)
        } else {
            persistCache(
                RoomCacheEnvelope(
                    data = next,
                    timestamp = nowMillis(),
                    eTag = storedETag,
                    modelFactsETag = storedModelFactsETag,
                )
            )
        }
    }

    private suspend fun persistModelFactsRow(next: MetadataResponse) {
        val dao = metadataCacheDao ?: return
        dao.upsert(
            MetadataCacheEntity(
                key = MetadataCacheEntity.MODEL_FACTS_KEY,
                payload = json.encodeToString(
                    ModelFactsCacheEnvelope.serializer(),
                    ModelFactsCacheEnvelope(
                        eTag = storedModelFactsETag,
                        revision = next.modelFactsRevision,
                        facts = next.modelFacts,
                    ),
                ),
                version = next.version,
                contractVersion = next.contractVersion,
                updatedAtMs = nowMillis(),
            )
        )
    }

    private fun publishNetworkSnapshot(decoded: MetadataResponse, responseETag: String?) {
        val decodedWithFacts = if (decoded.view == "lean" && decoded.modelFacts == null) {
            decoded.copy(
                modelFacts = table?.modelFacts,
                modelFactsRevision = table?.modelFactsRevision,
            )
        } else decoded
        val safe = normalizeMetadataEvidenceViews(
            data = decodedWithFacts,
            metadataRevision = responseETag,
            acceptPersistedProjection = false,
        )
        val nextRevision = evidencePublication.contentRevision + 1

        evidencePublication = EvidencePublication(safe, responseETag, nextRevision)
        table = safe
        bundledSnapshotActive = false
        storedETag = responseETag
        _metadataSource = MetadataSource.FreshNetwork
        _snapshotConfirmedThisSession = true

        _refreshEvents.tryEmit(
            RefreshEvent(
                version = safe.version,
                contractVersion = safe.contractVersion,
                contentRevision = nextRevision,
            )
        )
    }

    internal fun loadNetworkPayloadForTesting(rawJson: String, responseETag: String?) {
        val decoded = decodeMetadataPayload(rawJson)
        publishNetworkSnapshot(decoded, responseETag?.trim()?.takeIf { it.isNotEmpty() })
    }

    private fun decodeMetadataPayload(rawJson: String): MetadataResponse =
        if (hasTopLevelDataField(rawJson)) {
            json.decodeFromString<WrappedResponse>(rawJson).data
        } else {
            json.decodeFromString<MetadataResponse>(rawJson)
        }

    private fun hasTopLevelDataField(rawJson: String): Boolean {
        var index = skipJsonWhitespace(rawJson, 0)
        if (rawJson.getOrNull(index) != '{') return false
        index += 1

        while (index < rawJson.length) {
            index = skipJsonWhitespace(rawJson, index)
            if (rawJson.getOrNull(index) == '}') return false
            val key = scanJsonKey(rawJson, index) ?: return false
            index = key.nextIndex

            index = skipJsonWhitespace(rawJson, index)
            if (rawJson.getOrNull(index) != ':') return false
            index = skipJsonWhitespace(rawJson, index + 1)
            if (key.matchesData) return true

            index = skipJsonValue(rawJson, index)
            index = skipJsonWhitespace(rawJson, index)
            when (rawJson.getOrNull(index)) {
                ',' -> index += 1
                '}' -> return false
                else -> return false
            }
        }
        return false
    }

    private fun scanJsonKey(rawJson: String, start: Int): JsonKeyScan? {
        if (rawJson.getOrNull(start) != '"') return null
        var index = start + 1
        var decodedLength = 0
        var matchesData = true
        while (index < rawJson.length) {
            var decoded = rawJson[index++]
            if (decoded == '"') {
                return JsonKeyScan(
                    nextIndex = index,
                    matchesData = matchesData && decodedLength == DATA_FIELD.length,
                )
            }
            if (decoded == '\\') {
                val escape = rawJson.getOrNull(index++) ?: return null
                decoded = when (escape) {
                    '"', '\\', '/' -> escape
                    'b' -> '\b'
                    'f' -> '\u000C'
                    'n' -> '\n'
                    'r' -> '\r'
                    't' -> '\t'
                    'u' -> {
                        if (index + 4 > rawJson.length) return null
                        val codePoint = rawJson.substring(index, index + 4).toIntOrNull(16) ?: return null
                        index += 4
                        codePoint.toChar()
                    }
                    else -> return null
                }
            }
            if (decodedLength >= DATA_FIELD.length || decoded != DATA_FIELD[decodedLength]) {
                matchesData = false
            }
            decodedLength += 1
        }
        return null
    }

    private fun skipJsonWhitespace(rawJson: String, start: Int): Int {
        var index = start
        while (rawJson.getOrNull(index)?.isWhitespace() == true) index += 1
        return index
    }

    private fun skipJsonValue(rawJson: String, start: Int): Int {
        if (rawJson.getOrNull(start) == '"') return skipJsonString(rawJson, start)
        val first = rawJson.getOrNull(start)
        if (first != '{' && first != '[') {
            var index = start
            while (index < rawJson.length && rawJson[index] != ',' && rawJson[index] != '}') index += 1
            return index
        }

        var index = start
        var objectDepth = 0
        var arrayDepth = 0
        while (index < rawJson.length) {
            when (rawJson[index]) {
                '"' -> index = skipJsonString(rawJson, index)
                '{' -> {
                    objectDepth += 1
                    index += 1
                }
                '}' -> {
                    objectDepth -= 1
                    index += 1
                }
                '[' -> {
                    arrayDepth += 1
                    index += 1
                }
                ']' -> {
                    arrayDepth -= 1
                    index += 1
                }
                else -> index += 1
            }
            if (objectDepth == 0 && arrayDepth == 0) return index
        }
        return index
    }

    private fun skipJsonString(rawJson: String, start: Int): Int {
        var index = start + 1
        while (index < rawJson.length) {
            when (rawJson[index++]) {
                '\\' -> if (index < rawJson.length) index += 1
                '"' -> return index
            }
        }
        return index
    }

    internal suspend fun fetchMetadataForTesting(bypassETag: Boolean = false) {
        fetchMetadata(bypassETag)
    }

    internal suspend fun fetchModelFactsForTesting() {
        fetchModelFacts()
    }

    internal fun encodedCachePayloadForTesting(): String? = evidencePublication.table?.let { safe ->
        json.encodeToString(
            CacheEntry.serializer(),
            CacheEntry(data = safe, timestamp = 1),
        )
    }

    private suspend fun persistCache(cache: RoomCacheEnvelope) {
        val dao = metadataCacheDao ?: return
        val encoded = json.encodeToString(RoomCacheEnvelope.serializer(), cache)
        dao.upsert(
            MetadataCacheEntity(
                payload = encoded,
                version = cache.data.version,
                contractVersion = cache.data.contractVersion,
                updatedAtMs = cache.timestamp,
            )
        )
    }

    companion object {
        /**
         * Metadata schema of index / catalog requests. 3: sends both the request header and `?schema=3` (compact catalog),
         * and the bundled snapshot fallback is enabled accordingly (>= 2). Responses are always decoded by the body's metadataSchema (1 / 2 / 3).
         */
        internal const val METADATA_REQUEST_SCHEMA = 3
        private const val DATA_FIELD = "data"
        /** Copied into the APK from the shared model-contracts by :app's syncMetadataContractAssets at build time. */
        internal const val METADATA_PAYLOAD_SCHEMA_ASSET = "model-contracts/metadata_payload.v2.schema.json"
        private const val MODEL_ENTRY_INVALID = "model_entry_invalid"
        private const val REVISION_REGRESSED = "revision_regressed"
        private const val REVISION_MISMATCH = "revision_mismatch"
        private const val CATALOG_SYNC_PHASE = "catalog_sync"
        private const val UNRESOLVED_REF_KEYWORD = "unresolved_ref"
        /** The provider label used when reporting an index-level revision regression. */
        private const val INDEX_REVISION_PROVIDER = "index"

        private const val PAYLOAD_CHUNK_CHARS = 200_000
        private const val CAPABILITY_EVIDENCE_ABSENT = "__oriveo_capability_evidence_absent__"
        private const val PUBLIC_CAPABILITY_EVIDENCE_SCHEMA = "capability-evidence-view/v1"
        private val PUBLIC_CAPABILITY_SUPPORT = setOf("supported", "unsupported", "unknown")
        private val PUBLIC_CAPABILITY_SOURCE_GRADE = mapOf(
            // declared: tool-call support taken from models.dev rather than a provider machine field.
            "server_typed" to setOf("machine_verified", "declared"),
            "server_profile" to setOf("effect_verified", "declared"),
            "operator_override" to setOf("operator"),
        )
        private val PUBLIC_CAPABILITY_SUBKEY = Regex("^[A-Za-z0-9_.-]{1,128}$")

        @Volatile
        var instance: MetadataClient = MetadataClient()

        /**
         * Built-in default Relay runtime rules of the client. Only used when the backend /api/metadata sends no relayRuntimeConfig;
         * any change must be mirrored in the server's DefaultRelayRuntimeConfig.
         */
        internal val FALLBACK_RELAY_RUNTIME_CONFIG: RelayRuntimeConfig = RelayRuntimeConfig(
            version = "fallback",
            officialProviderWhitelist = listOf(
                "openAI", "anthropic", "gemini", "deepseek", "miniMax", "zhipu", "qwen", "moonshot",
            ),
            transportEnvelopes = mapOf(
                "openai_responses" to RelayTransportEnvelope(
                    image = true, nativeFile = true, textFileInline = true,
                    webSearch = true, imageGeneration = true, reasoning = true,
                ),
                "openai_chat_completions" to RelayTransportEnvelope(
                    image = true, nativeFile = false, textFileInline = true,
                    webSearch = false, imageGeneration = false, reasoning = true,
                ),
                "anthropic_messages" to RelayTransportEnvelope(
                    image = true, nativeFile = true, textFileInline = true,
                    webSearch = false, imageGeneration = false, reasoning = true,
                ),
                "gemini_generate_content" to RelayTransportEnvelope(
                    image = true, nativeFile = true, textFileInline = true,
                    webSearch = true, imageGeneration = true, reasoning = true,
                ),
            ),
            transportRules = mapOf(
                "openai_responses" to RelayTransportRule(
                    providerPriority = "openAI",
                    defaultAuthMode = "bearer",
                    defaultVersion = "v1",
                    acceptedVersions = listOf("v1"),
                    headerProfile = "codex_responses",
                    codexIdentityDefault = true,
                    webSearchToolName = "web_search",
                    imageRoute = "inline_responses_tool",
                    forceStreamForImageGeneration = true,
                ),
                "openai_chat_completions" to RelayTransportRule(
                    providerPriority = "openAI",
                    defaultAuthMode = "bearer",
                    defaultVersion = "v1",
                    acceptedVersions = listOf("v1"),
                    headerProfile = "none",
                    codexIdentityDefault = false,
                    webSearchToolName = "disabled",
                    imageRoute = "images_endpoint",
                    forceStreamForImageGeneration = false,
                ),
                "anthropic_messages" to RelayTransportRule(
                    providerPriority = "anthropic",
                    defaultAuthMode = "x_api_key",
                    defaultVersion = "v1",
                    acceptedVersions = listOf("v1"),
                    headerProfile = "anthropic_v2023_06_01",
                    codexIdentityDefault = false,
                    webSearchToolName = "disabled",
                    imageRoute = "unsupported",
                    forceStreamForImageGeneration = false,
                ),
                "gemini_generate_content" to RelayTransportRule(
                    providerPriority = "gemini",
                    defaultAuthMode = "x_goog_api_key",
                    defaultVersion = "v1beta",
                    acceptedVersions = listOf("v1", "v1beta"),
                    headerProfile = "gemini_key",
                    codexIdentityDefault = false,
                    webSearchToolName = "google_search",
                    imageRoute = "gemini_modality",
                    forceStreamForImageGeneration = false,
                ),
            ),
            verificationPolicy = RelayVerificationPolicy(),
            featureGatingPolicy = RelayFeatureGatingPolicy(),
        )

        const val SUPPORTED_CONTRACT_VERSION: Int = 1

        val refreshEvents: Flow<RefreshEvent> get() = instance.refreshEvents
        val version: Int get() = instance.version
        val contractVersion: Int get() = instance.contractVersion
        val capabilityContractVersion: Int get() = instance.capabilityContractVersion
        val isContractVersionSupported: Boolean get() = instance.isContractVersionSupported
        val isContractVersionDegraded: Boolean get() = instance.isContractVersionDegraded
        val metadataSource: MetadataSource get() = instance.metadataSource

        suspend fun initialize(context: Context) = instance.initialize(context)
        suspend fun ensureInitialized() = instance.ensureInitialized()
        suspend fun refresh() = instance.refresh()
        suspend fun refresh(kinds: Set<ProviderKind>) = instance.refresh(kinds)

        fun catalogLoadState(providerKind: ProviderKind): CatalogLoadState =
            instance.catalogLoadState(providerKind)

        fun isSnapshotConfirmed(providerKind: ProviderKind): Boolean =
            instance.isSnapshotConfirmed(providerKind)

        fun metadataSource(providerKind: ProviderKind): MetadataSource =
            instance.metadataSource(providerKind)
        suspend fun ensureModelFactsLoaded() = instance.ensureModelFactsLoaded()
        suspend fun refreshModelFacts() = instance.refreshModelFacts()

        fun resolveCatalogModel(modelID: String, providerKind: ProviderKind): ResolvedModelMetadata? =
            instance.resolveCatalogModel(modelID, providerKind)

        fun modelFacts(providerKind: ProviderKind, modelID: String): ModelFacts? =
            instance.modelFacts(providerKind, modelID)

        fun modelFactsRevision(): String? = instance.modelFactsRevision()

        /** Mirrors catalog normalizeModelsDevJoinID; transformation order is contractual. */
        fun normalizeModelFactsID(modelID: String): String {
            var value = modelID.trim().lowercase()
            listOf("accounts/fireworks/models/", "accounts/fireworks/routers/", "pro/").forEach { prefix ->
                if (value.startsWith(prefix)) value = value.removePrefix(prefix)
            }
            value = value.replace(Regex("(?:-\\d{8}|-\\d{4}-\\d{2}-\\d{2})$"), "")
            return value.replace(Regex("(\\d)p(\\d)"), "${'$'}1.${'$'}2")
        }

        fun capabilityRuntimeRequest(
            providerKind: ProviderKind,
            modelID: String,
            finalTransport: String,
            webRequested: Boolean,
            reasoningMode: ReasoningMode,
            typedWebIntent: String? = null,
            typedReasoningIntent: String? = null,
            includeAutomaticReasoning: Boolean = false,
        ): CapabilityRuntimeRequest? = instance.capabilityRuntimeRequest(
            providerKind = providerKind,
            modelID = modelID,
            finalTransport = finalTransport,
            webRequested = webRequested,
            reasoningMode = reasoningMode,
            typedWebIntent = typedWebIntent,
            typedReasoningIntent = typedReasoningIntent,
            includeAutomaticReasoning = includeAutomaticReasoning,
        )

        fun hasP5CapabilityResultRuntime(): Boolean = instance.hasP5CapabilityResultRuntime()

        fun grokSubscriptionAvailability(): GrokSubscriptionAvailability =
            instance.grokSubscriptionAvailability()

        fun openAISubscriptionAvailability(): OpenAISubscriptionAvailability =
            instance.openAISubscriptionAvailability()

        fun capabilityOfficialGenerationDocumentationURL(
            providerKind: ProviderKind,
            modelID: String,
            finalTransport: String,
        ): String? = instance.capabilityOfficialGenerationDocumentationURL(providerKind, modelID, finalTransport)

        fun capabilityCustomControlAuthority(
            providerKind: ProviderKind,
            modelID: String,
            finalTransport: String,
            owner: String,
        ): CapabilityCustomControlAuthority? = instance.capabilityCustomControlAuthority(providerKind, modelID, finalTransport, owner)

        fun resolveCatalogModelAcrossProviders(modelID: String): ResolvedModelMetadata? =
            instance.resolveCatalogModelAcrossProviders(modelID)

        fun resolveCatalogModelInLoadedCatalogs(modelID: String): ResolvedModelMetadata? =
            instance.resolveCatalogModelInLoadedCatalogs(modelID)

        fun resolveCatalogModelAcrossProvidersWithProvider(
            modelID: String,
            transportPriority: ProviderKind? = null,
        ): RelayCatalogMatchResult? =
            instance.resolveCatalogModelAcrossProvidersWithProvider(modelID, transportPriority)

        internal fun relayRuntimeConfig(): RelayRuntimeConfig = instance.relayRuntimeConfig()
        fun mcpRuntimeConfig(): ai.oriveo.community.core.mcp.McpRuntimeConfig = instance.mcpRuntimeConfig()

        /** See [MetadataClient.snapshotConfirmedThisSession]. */
        val snapshotConfirmedThisSession: Boolean get() = instance.snapshotConfirmedThisSession

        fun isRuntimeFeatureEnabled(key: String, defaultValue: Boolean = true): Boolean =
            instance.isRuntimeFeatureEnabled(key, defaultValue)

        fun selfHealPatterns(): List<SelfHealPattern> = instance.selfHealPatterns()

        fun lookupPricing(modelID: String, providerKind: ProviderKind): Pair<Double, Double>? =
            instance.lookupPricing(modelID, providerKind)

        fun lookupCapabilities(modelID: String, providerKind: ProviderKind): List<ModelCapability>? =
            instance.lookupCapabilities(modelID, providerKind)

        fun resolveAIModelForRouter(
            modelID: String,
            providerKind: ProviderKind,
        ): ai.oriveo.community.core.model.AIModel? =
            instance.resolveAIModelForRouter(modelID, providerKind)

        fun estimateCost(
            modelID: String,
            providerKind: ProviderKind,
            promptTokens: Int,
            completionTokens: Int,
        ): Double =
            instance.estimateCost(modelID, providerKind, promptTokens, completionTokens)

        fun priceTier(modelID: String, providerKind: ProviderKind): String =
            instance.priceTier(modelID, providerKind)

        fun providerModelIds(providerKind: ProviderKind): List<String> =
            instance.providerModelIds(providerKind)

        fun defaultModelId(providerKind: ProviderKind): String? =
            instance.defaultModelId(providerKind)

        fun retiredModels(providerKind: ProviderKind): List<RetiredModel> =
            instance.retiredModels(providerKind)

        fun validation(providerKind: ProviderKind): ProviderValidation? =
            instance.validation(providerKind)

        internal fun providerAttachmentSupport(providerKind: ProviderKind): ProviderAttachmentSupport? =
            instance.providerAttachmentSupport(providerKind)

        fun providerTransport(providerKind: ProviderKind): ProviderTransport? =
            instance.providerTransport(providerKind)

        fun webSearchStreamShape(profileName: String?): StreamShape? =
            instance.webSearchStreamShape(profileName)

        fun webSearchMergeParams(profileName: String?): kotlinx.serialization.json.JsonObject? =
            instance.webSearchMergeParams(profileName)

        fun webSearchDeclaredMergeParams(profileName: String): kotlinx.serialization.json.JsonObject? =
            instance.webSearchDeclaredMergeParams(profileName)

        fun webSearchMaxToolLoops(profileName: String?): Int? =
            instance.webSearchMaxToolLoops(profileName)

        fun reasoningStreamShape(profileName: String?): StreamShape? =
            instance.reasoningStreamShape(profileName)

        fun reasoningMergeParams(profileName: String?, mode: ReasoningMode): JsonObject? =
            instance.reasoningMergeParams(profileName, mode)

        fun imageGenStreamShape(profileName: String?): StreamShape? =
            instance.imageGenStreamShape(profileName)

        fun imageGenMergeParams(profileName: String?): kotlinx.serialization.json.JsonObject? =
            instance.imageGenMergeParams(profileName)

        fun imageGenRoute(profileName: String?): String? =
            instance.imageGenRoute(profileName)

        fun imageGenRequestDefaults(profileName: String?): kotlinx.serialization.json.JsonObject? =
            instance.imageGenRequestDefaults(profileName)

        fun hasPublicProviderConfigSource(): Boolean =
            instance.hasPublicProviderConfigSource()

        fun listPublicProviderConfigs(): List<PublicProviderConfig> =
            instance.listPublicProviderConfigs()

        fun publicProviderConfig(kind: ProviderKind): PublicProviderConfig? =
            instance.publicProviderConfig(kind)

        fun trustedPublicProviderConfig(kind: ProviderKind): PublicProviderConfig? =
            instance.trustedPublicProviderConfig(kind)

        fun trustedHosts(kind: ProviderKind): List<String>? =
            instance.trustedHosts(kind)

        fun apiProtocol(kind: ProviderKind): String? =
            instance.apiProtocol(kind)

        fun supportedReasoningModes(profileName: String?): List<ReasoningMode> =
            instance.supportedReasoningModes(profileName)

        fun clampReasoningMode(
            mode: ReasoningMode,
            profileName: String?,
        ): ReasoningMode =
            instance.clampReasoningMode(mode, profileName)
    }
}
