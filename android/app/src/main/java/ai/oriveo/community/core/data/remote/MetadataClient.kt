package ai.oriveo.community.core.data.remote

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
import ai.oriveo.community.core.provider.ModelPricingFormatter
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAuthResolver
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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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

private object HttpUrlConnectionMetadataTransport : MetadataTransport {
    override suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse {
        val baseUrl = metadataBaseUrl() ?: return MetadataTransportResponse(
            statusCode = HttpURLConnection.HTTP_NOT_IMPLEMENTED,
            eTag = null,
            body = null,
            responseBytes = 0L,
        )
        val connection = URL("$baseUrl/api/metadata?view=lean").openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept", "application/json")
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
}

private object HttpUrlConnectionModelFactsTransport : ModelFactsTransport {
    override suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse {
        val baseUrl = metadataBaseUrl() ?: return MetadataTransportResponse(
            statusCode = HttpURLConnection.HTTP_NOT_IMPLEMENTED,
            eTag = null,
            body = null,
            responseBytes = 0L,
        )
        val connection = URL("$baseUrl/api/metadata/model-facts").openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept", "application/json")
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
            } else null
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
}

private class MetadataHttpStatusException(statusCode: Int) :
    Exception("metadata request returned HTTP $statusCode")

internal const val METADATA_FAILURE_MODULE = "metadata_client"

private fun Map<String, String>.tagOrUnknown(key: String): String =
    this[key]?.takeIf { it.isNotBlank() } ?: "unknown"

internal fun metadataFailureMessage(tags: Map<String, String>): String =
    "metadata ${tags.tagOrUnknown("phase")} failed"

internal fun metadataFailureFingerprint(tags: Map<String, String>): List<String> =
    listOf(METADATA_FAILURE_MODULE, tags.tagOrUnknown("phase"), tags.tagOrUnknown("exception_class"))

class MetadataClient internal constructor(
    initialContext: Context? = null,
    private val backgroundScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val metadataCacheDao: MetadataCacheDao? = null,
    private val metadataTransport: MetadataTransport = HttpUrlConnectionMetadataTransport,
    private val modelFactsTransport: ModelFactsTransport = HttpUrlConnectionModelFactsTransport,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val failureReporter: (Map<String, String>) -> Unit = { tags ->
    },
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

        val capabilityEvidenceCandidates: List<CapabilityEvidenceCandidateView>? = null,

        val capabilityEvidenceOwnedKeys: Set<String>? = null,

        val capabilityEvidenceViewMalformed: Boolean? = null,
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
    data class ProviderAttachmentSupport(
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

    @Serializable
    data class PublicProviderConfig(
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
        val attachmentSupport: ProviderAttachmentSupport? = null,
        val regionOptions: List<ProviderRegionOption>? = null,
        val sortOrder: Int? = null,
    )

    @Serializable
    data class RelayTransportEnvelope(
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

    data class RelayRuntimeConfig(
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
        return reference.copy(
            template = template,
            wire = templateDefinition.wire,
            transport = templateDefinition.transport,
            parameters = parameters.map { parameter ->
                val id = parameter.id?.trim()?.takeIf { it.isNotEmpty() } ?: return@map parameter
                val definition = definitions.parameters[id] ?: return@map parameter.copy(id = id)
                parameter.copy(
                    id = id,
                    group = definition.group,
                    valueSchema = definition.valueSchema,
                    range = definition.range,

                    enumValues = parameter.enumValues.ifEmpty { definition.enumValues },
                    fixedValue = definition.fixedValue,
                    defaultDescription = definition.defaultDescription,
                    interactionGroup = definition.interactionGroup,
                    conflictsWith = definition.conflictsWith,
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

        val capabilityEvidenceView: JsonElement? = JsonPrimitive(CAPABILITY_EVIDENCE_ABSENT),
        val capabilityEvidenceCandidates: List<CapabilityEvidenceCandidateView>? = null,
        val capabilityEvidenceOwnedKeys: List<String>? = null,
        val capabilityEvidenceViewMalformed: Boolean? = null,

        val capabilityControls: JsonObject? = null,
    )

    @Serializable
    private data class ProviderData(
        val displayName: String? = null,
        val attachmentSupport: ProviderAttachmentSupport? = null,
        val defaultModelId: String? = null,
        val validation: ProviderValidation? = null,
        val resolveMap: Map<String, String>? = null,
        val models: Map<String, ModelData> = emptyMap(),

        val transport: ProviderTransport? = null,
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

        val capabilityRuntime: JsonObject? = null,
        /** Facts published alongside the catalog; artifactHash is deliberately not decoded. */
        val modelFacts: Map<String, ModelFacts>? = null,
        val modelFactsRevision: String? = null,
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
    )

    @Volatile
    private var evidencePublication = EvidencePublication(null, null, 0)

    @Volatile
    private var pendingRefresh: Job? = null

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
            )
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

    private suspend fun readPersistedPayload(dao: MetadataCacheDao): String? {
        val length = dao.payloadLength() ?: return null
        if (length <= 0) return null
        val builder = StringBuilder(length)
        var readChars = 0
        while (readChars < length) {
            val chunk = dao.payloadChunk(readChars + 1, PAYLOAD_CHUNK_CHARS) ?: return null
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
            if (table != null) return

            val cached = loadPersistedCache(context)
            if (cached != null) {
                // Cache bucketing: a cached contractVersion outside the compatible window
                // [SUPPORTED_CONTRACT_VERSION - 1, SUPPORTED_CONTRACT_VERSION + 1] is discarded
                // and the catalog is fetched again.
                val cachedContract = cached.data.contractVersion
                val inWindow = cachedContract == 0 ||
                    cachedContract in (SUPPORTED_CONTRACT_VERSION - 1)..(SUPPORTED_CONTRACT_VERSION + 1)
                if (!inWindow) {
                    // An out-of-window contract is a cold path: drop the row and the legacy
                    // preferences, then fetch in full without carrying the old ETag.
                    clearPersistedCache(context)
                    fetchMetadata(bypassETag = true)
                    return
                }
                val persistedETag = cached.eTag
                val safeCached = normalizeMetadataEvidenceViews(
                    data = cached.data,
                    metadataRevision = persistedETag,
                    acceptPersistedProjection = true,
                )
                table = safeCached
                _metadataSource = MetadataSource.CachedOffline
                storedETag = persistedETag
                storedModelFactsETag = cached.modelFactsETag
                evidencePublication = EvidencePublication(
                    table = safeCached,
                    metadataRevision = persistedETag,
                    contentRevision = evidencePublication.contentRevision + 1,
                )
                // Emit once after hydrating from the local cache so subscribers can render it
                // before the network round trip finishes.
                _refreshEvents.tryEmit(
                    RefreshEvent(
                        version = safeCached.version,
                        contractVersion = safeCached.contractVersion,
                        contentRevision = evidencePublication.contentRevision,
                    )
                )
                if (nowMillis() - cached.timestamp < CACHE_TTL_MS) {
                    pendingRefresh = backgroundScope.launch {
                        fetchMetadata(bypassETag = false)
                        pendingRefresh = null
                    }
                    return
                }
                fetchMetadata(bypassETag = false)
                return
            }

            // No usable cache is the cold path: no leftover ETag may turn an empty table into a 304.
            fetchMetadata(bypassETag = true)
        }
    }

    suspend fun ensureInitialized() {
        val context = appContext ?: return
        if (table == null) initialize(context)
        // Once the cache has hydrated (table is non-null) the background full refresh is not
        // awaited: otherwise the first message after a cold start would block on the catalog
        // fetch, and a slow or unreachable backend would hold the first token for many seconds.
        if (table == null) pendingRefresh?.join()
    }

    /** Forces a re-fetch from the catalog, for cases such as a provider resync. */
    suspend fun refresh() {
        // Same appContext guard as ensureInitialized()/persistCache(): with no context this
        // instance was never initialized, so fetchMetadata would issue a real request with
        // nowhere to persist the result. In the app there is always a context, so this is a
        // no-op there; in unit tests it stops a fire-and-forget refresh from racing the suite.
        appContext ?: return
        pendingRefresh?.join()
        fetchMetadata(bypassETag = false)
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

    fun resolveCatalogModel(modelID: String, providerKind: ProviderKind): ResolvedModelMetadata? {
        return resolveCatalogModel(table, modelID, providerKind)
    }

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
        val pricingUnit = normalizePricingUnit(model.pricingUnit)
        val pricingStatus = normalizePricingStatus(model, pricing, pricingUnit)
        val promptPerToken = pricing?.promptPerMToken?.div(1_000_000)
        val completionPerToken = pricing?.completionPerMToken?.div(1_000_000)

        return ResolvedModelMetadata(
            canonicalModelId = model.canonicalModelId ?: canonicalId,
            modelRef = model.modelRef?.trim()?.takeIf { it.isNotEmpty() },
            capabilityContractVersion = snapshot?.capabilityContractVersion ?: 0,
            displayName = model.displayName,
            contextLength = model.contextLength,
            maxOutputTokens = model.maxOutputTokens,
            supportsTemperature = model.supportsTemperature,
            billingSku = model.billingSku?.trim()?.takeIf { it.isNotEmpty() },
            pricingUnit = pricingUnit,
            sourceSummary = normalizeSourceSummary(model.sourceSummary),
            pricingStatus = pricingStatus,
            capabilities = capabilities,
            promptPerToken = if (pricingStatus == "unknown" || pricingUnit != "per_token") null else promptPerToken,
            completionPerToken = if (pricingStatus == "unknown" || pricingUnit != "per_token") null else completionPerToken,
            costPerUnit = pricing?.costPerUnit,
            costInputBatches = pricing?.costInputBatches,
            costOutputBatches = pricing?.costOutputBatches,
            costInputPriority = pricing?.costInputPriority,
            costOutputPriority = pricing?.costOutputPriority,
            cacheReadInputPerMToken = pricing?.cacheReadInputPerMToken,
            cacheCreationInputPerMToken = pricing?.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken = pricing?.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken = pricing?.cacheWrite1hPerMToken,
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
            capabilityEvidenceCandidates = model.capabilityEvidenceCandidates,
            capabilityEvidenceOwnedKeys = model.capabilityEvidenceOwnedKeys?.toSet(),
            capabilityEvidenceViewMalformed = model.capabilityEvidenceViewMalformed,
        )
    }

    fun resolveCatalogModelAcrossProviders(modelID: String): ResolvedModelMetadata? {
        ProviderKind.entries.forEach { kind ->
            if (kind == ProviderKind.Relay) return@forEach
            resolveCatalogModel(modelID = modelID, providerKind = kind)?.let { return it }
        }
        return null
    }

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

        for (kind in ordered) {
            val resolved = resolveCatalogModel(modelID = modelID, providerKind = kind) ?: continue
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

    fun relayRuntimeConfig(): RelayRuntimeConfig {
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

    fun validation(providerKind: ProviderKind): ProviderValidation? {
        return providerFor(providerKind)?.validation
    }

    fun providerAttachmentSupport(providerKind: ProviderKind): ProviderAttachmentSupport? {
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
            ?.sortedWith(
                compareBy<PublicProviderConfig> { it.sortOrder ?: Int.MAX_VALUE }
                    .thenBy { providerConfigFallbackOrder(it.kind) }
                    .thenBy { it.kind },
            )
            ?: emptyList()
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
        model: ModelData,
        pricing: ModelPricing?,
        pricingUnit: String,
    ): String {
        val status = model.pricingStatus
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
        if (key in setOf("web_search", "vision_input", "tool_call")) return true
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

    private suspend fun fetchMetadata(bypassETag: Boolean = false) {
        fetchMutex.withLock {
            withContext(ioDispatcher) {
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
                        return@withContext
                    }
                    if (statusCode != HttpURLConnection.HTTP_OK) {
                        reportFailure(
                            phase = phase,
                            startedAtMs = startedAtMs,
                            responseBytes = responseBytes,
                            statusCode = statusCode,
                            error = MetadataHttpStatusException(statusCode),
                        )
                        return@withContext
                    }

                    val body = response.body ?: throw EOFException("metadata response body missing")
                    phase = "decode"
                    val decoded = decodeMetadataPayload(body)
                    publishNetworkSnapshot(decoded, response.eTag)
                    phase = "cache_write"
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
                        persistCache(
                            RoomCacheEnvelope(
                                data = next,
                                timestamp = nowMillis(),
                                eTag = storedETag,
                                modelFactsETag = null,
                            )
                        )
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
                    persistCache(
                        RoomCacheEnvelope(
                            data = next,
                            timestamp = nowMillis(),
                            eTag = storedETag,
                            modelFactsETag = storedModelFactsETag,
                        )
                    )
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
        private const val DATA_FIELD = "data"

        private const val PAYLOAD_CHUNK_CHARS = 200_000
        private const val CAPABILITY_EVIDENCE_ABSENT = "__oriveo_capability_evidence_absent__"
        private const val PUBLIC_CAPABILITY_EVIDENCE_SCHEMA = "capability-evidence-view/v1"
        private val PUBLIC_CAPABILITY_SUPPORT = setOf("supported", "unsupported", "unknown")
        private val PUBLIC_CAPABILITY_SOURCE_GRADE = mapOf(
            "server_typed" to setOf("machine_verified"),
            "server_profile" to setOf("effect_verified", "declared"),
            "operator_override" to setOf("operator"),
        )
        private val PUBLIC_CAPABILITY_SUBKEY = Regex("^[A-Za-z0-9_.-]{1,128}$")

        @Volatile
        var instance: MetadataClient = MetadataClient()

        val FALLBACK_RELAY_RUNTIME_CONFIG: RelayRuntimeConfig = RelayRuntimeConfig(
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
        ): CapabilityRuntimeRequest? = instance.capabilityRuntimeRequest(
            providerKind = providerKind,
            modelID = modelID,
            finalTransport = finalTransport,
            webRequested = webRequested,
            reasoningMode = reasoningMode,
            typedWebIntent = typedWebIntent,
            typedReasoningIntent = typedReasoningIntent,
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

        fun resolveCatalogModelAcrossProvidersWithProvider(
            modelID: String,
            transportPriority: ProviderKind? = null,
        ): RelayCatalogMatchResult? =
            instance.resolveCatalogModelAcrossProvidersWithProvider(modelID, transportPriority)

        fun relayRuntimeConfig(): RelayRuntimeConfig = instance.relayRuntimeConfig()

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

        fun validation(providerKind: ProviderKind): ProviderValidation? =
            instance.validation(providerKind)

        fun providerAttachmentSupport(providerKind: ProviderKind): ProviderAttachmentSupport? =
            instance.providerAttachmentSupport(providerKind)

        fun providerTransport(providerKind: ProviderKind): ProviderTransport? =
            instance.providerTransport(providerKind)

        fun webSearchStreamShape(profileName: String?): StreamShape? =
            instance.webSearchStreamShape(profileName)

        fun webSearchMergeParams(profileName: String?): kotlinx.serialization.json.JsonObject? =
            instance.webSearchMergeParams(profileName)

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

        fun supportedReasoningModes(profileName: String?): List<ReasoningMode> =
            instance.supportedReasoningModes(profileName)

        fun clampReasoningMode(
            mode: ReasoningMode,
            profileName: String?,
        ): ReasoningMode =
            instance.clampReasoningMode(mode, profileName)
    }
}
