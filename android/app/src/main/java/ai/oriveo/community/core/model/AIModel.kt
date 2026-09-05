package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** Reference to a shared generation-parameter profile; without one, no optional parameter is sent. */
@Serializable
data class GenerationProfileRef(
    val template: String? = null,
    val parameters: List<GenerationParameterRef> = emptyList(),
    /** Reference into the catalog's shared parameter tables, resolved when the catalog is read. */
    val parametersRef: String? = null,
    /** Expanded from the shared templates on read; the catalog payload itself carries only refs. */
    val wire: Map<String, String> = emptyMap(),
    val transport: String? = null,
)

/** Unknown support and source strings are kept verbatim so a new catalog value cannot break decoding. */
@Serializable
data class GenerationParameterRef(
    val id: String? = null,
    val support: String? = null,
    val source: String? = null,
    val group: String? = null,
    val valueSchema: String? = null,
    val range: GenerationParameterRange? = null,
    val enumValues: List<JsonElement> = emptyList(),
    val fixedValue: JsonElement? = null,
    val defaultDescription: JsonElement? = null,
    val interactionGroup: String? = null,
    val conflictsWith: List<String> = emptyList(),
    val requires: List<kotlinx.serialization.json.JsonObject> = emptyList(),
    val constraints: List<kotlinx.serialization.json.JsonObject> = emptyList(),
    val portability: String? = null,
    val risk: String? = null,
)

@Serializable
data class GenerationParameterRange(
    val min: Double? = null,
    val max: Double? = null,
    val minExclusive: Double? = null,
    val maxExclusive: Double? = null,
    val step: Double? = null,
)

/** One model offered by a provider. */
@Immutable
@Serializable
data class AIModel(
    val id: String,
    val name: String,
    val capabilities: List<ModelCapability> = emptyList(),
    val reasoningModeAvailable: Boolean = false,
    val isAvailable: Boolean = true,
    val isDefault: Boolean = false,
    val priceTier: String = "",
    val summary: String? = null,
    val contextLength: Int? = null,
    val maxOutputTokens: Int? = null,
    val groupKey: String? = null,
    val groupName: String? = null,
    val createdAt: Double? = null,
    val promptPrice: Double? = null,
    val completionPrice: Double? = null,
    val billingSku: String? = null,
    val pricingUnit: String = "per_token",
    val sourceSummary: ModelSourceSummary? = null,
    val costPerUnit: Double? = null,
    val costInputBatches: Double? = null,
    val costOutputBatches: Double? = null,
    val costInputPriority: Double? = null,
    val costOutputPriority: Double? = null,
    val cacheReadInputPerMToken: Double? = null,
    val cacheCreationInputPerMToken: Double? = null,
    val cacheWrite5mPerMToken: Double? = null,
    val cacheWrite1hPerMToken: Double? = null,
    val supportsPdfInput: Boolean = false,
    val supportsServiceTier: Boolean = false,
    val canonicalModelId: String? = null,
    val isRecommended: Boolean = false,
    val sortRank: Int? = null,
    val badgeOrder: List<ModelCapability>? = null,
    val reasoningProfile: String? = null,
    val webSearchProfile: String? = null,
    val imageGenProfile: String? = null,
    val generationProfile: GenerationProfileRef? = null,
    /**
     * Whether the model can emit tool calls, as the catalog reports it.
     *
     * Three-state: `null` means unknown (the catalog has not loaded, or the field was absent),
     * `false` means confirmed unsupported, `true` means supported. Unknown is not the same as
     * unsupported: collapsing it with `?: false` renders "we have not fetched this yet" as the
     * definite "this model cannot do that" for the whole cold-start window. Every reader must
     * handle all three.
     */
    val toolCall: Boolean? = null,
    /**
     * Whether this model is strong enough to drive an agentic retrieval loop.
     */
    val libraryAgentic: Boolean? = null,
    /**
     * Set when the user typed the model id in by hand rather than picking it from the catalog.
     */
    val isManual: Boolean = false,
    /**
     * Per-model attachment extraction limits. Null falls back to [FileExtractionLimits.DEFAULT];
     * long-context models can be given a higher ceiling through the catalog.
     */
    val attachmentExtraction: AttachmentExtractionLimits? = null,
    /**
     * File MIME types this model can read natively.
     *
     * The attachment router decides between handing over the original bytes and extracting text
     * locally from this list plus the file's size. An empty list means the model cannot take
     * files at all, so everything is extracted.
     */
    val nativeFileMimes: List<String> = emptyList(),
    /**
     * Whether a PDF should go to the model as a file by default, rather than being extracted to
     * text first. Read from the catalog rather than hard-coded per provider, so a model that
     * gains the ability does not need an app update.
     */
    val pdfNativeDefault: Boolean = false,
    /**
     * Reasoning levels the upstream declared for this model on a subscription connection: Codex
     * reports `supported_reasoning_levels`, Grok reports `reasoning_efforts[].value`. Empty means
     * the upstream declared none, in which case no effort parameter is sent at all.
     *
     * Persisted locally. The subscription catalog is only fetched when the connection is created
     * or refreshed, so without persisting it the level picker would be empty after every restart
     * until the user resynced by hand.
     */
    val upstreamReasoningLevels: List<String> = emptyList(),
    /** Subscription `/models` default entry. Local-only, never synced. */
    val upstreamDefaultReasoningLevel: String? = null,
    /** Subscription `/models` protocol declaration (`responses` / `chat`). Local-only. */
    val upstreamApiBackend: String? = null,
    val localLoadState: LocalModelLoadState? = null,
    val executionLocality: ModelExecutionLocality? = null,
)

@Serializable
enum class LocalModelLoadState { Loaded, Loading, Unloaded, Unknown }

@Serializable
enum class ModelExecutionLocality {
    Local,
    @kotlinx.serialization.SerialName("proxied_cloud") ProxiedCloud,
    Unknown,
}

data class LocalModelRuntimeMetadata(
    val loadState: LocalModelLoadState,
    val executionLocality: ModelExecutionLocality,
)

@Immutable
@Serializable
data class ModelSourceSummary(
    val sourceKind: String,
    val sourceName: String,
    val fetchedAt: String,
)

/**
 * Per-model attachment extraction limits. Every field is optional; null falls back to the default.
 */
@Serializable
data class AttachmentExtractionLimits(
    /** Maximum lines read from one file. */
    val maxLines: Int? = null,
    /** Maximum UTF-8 bytes read from one file. */
    val maxBytes: Int? = null,
    /** Maximum extracted bytes across all attachments on one message. */
    val totalCap: Int? = null,
    /** Hard ceiling on the size of an input file, checked before sending. */
    val maxInputFileBytes: Int? = null,
    /** Maximum original bytes across all attachments on one message. */
    val maxTotalAttachmentBytes: Int? = null,
    /** Maximum original attachment bytes across the whole request history. */
    val maxRequestAttachmentBytes: Int? = null,
    /** Maximum number of attachments on one message. */
    val maxAttachments: Int? = null,
)
