package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonElement

/** Who wrote a message. */
@Serializable
enum class ChatRole {
    @SerialName("user") User,
    @SerialName("assistant") Assistant;

    /** Stable wire value used by storage and backup files. */
    val rawValue: String
        get() = when (this) {
            User -> "user"
            Assistant -> "assistant"
        }

    companion object {
        fun fromRawValue(raw: String): ChatRole? =
            entries.firstOrNull { it.rawValue == raw }
    }
}

/** Lifecycle of a single message, from the first streamed token to a final outcome. */
@Serializable
enum class ChatMessageState {
    @SerialName("delivered") Delivered,
    @SerialName("generating") Generating,
    @SerialName("interrupted") Interrupted,
    @SerialName("failed") Failed,
}

/** Attachment media class. */
@Serializable
enum class AttachmentKind {
    @SerialName("image") Image,
    @SerialName("video") Video,
    @SerialName("file") File;

    /** Stable wire value used by storage and backup files. */
    val rawValue: String
        get() = when (this) {
            Image -> "image"
            Video -> "video"
            File -> "file"
        }

    companion object {
        fun fromRawValue(raw: String): AttachmentKind? =
            entries.firstOrNull { it.rawValue == raw }
    }
}

/** One file the user attached to a message. */
@Immutable
@Serializable
data class Attachment(
    val id: String,
    val kind: AttachmentKind,
    val fileName: String,
    val mimeType: String,
    /** Extracted text for a document, or inline base64 for a small binary. */
    val base64Data: String? = null,
    /** Key into the on-device attachment store. */
    val localImageId: String? = null,
    /** Small base64 preview, kept under 10KB so a list can render without touching the store. */
    val thumbnailBase64: String? = null,
    val extractedTotalLines: Int? = null,
    val extractedTruncated: Boolean? = null,
    val extractedSizeBytes: Int? = null,
    /** The untouched bytes, kept so a model that can read the file natively gets the real thing. */
    val originalBase64Data: String? = null,
    /** Why extraction failed, when it did. */
    val extractionErrorCode: String? = null,
    /**
     * Pointer to the payload in the attachment store instead of the payload itself.
     *
     * Large bodies must not travel inside the message row: SQLite refuses a row past its blob
     * limit, and a video or a large PDF passes it easily. The store holds the bytes and the row
     * holds this id; [ai.oriveo.community.core.attachments.AttachmentHydrator] puts them back
     * together on read.
     */
    val rawContentRef: String? = null,
)

/** One message in a conversation. */
@Immutable
@Serializable
data class ChatMessage(
    val id: String,
    val role: ChatRole,
    val text: String,
    val providerID: String? = null,
    val providerKind: ProviderKind,
    val providerName: String,
    val modelID: String? = null,
    val modelName: String,
    val servedModelID: String? = null,
    val estimatedCost: Double = 0.0,
    val state: ChatMessageState,
    val errorTitle: String? = null,
    val errorDetail: String? = null,
    val attachments: List<Attachment>? = null,
    val quoteContext: QuoteContext? = null,
    val createdAt: Long? = null,
    val reasoningText: String? = null,
    /**
     * How long the model spent thinking. Null when the provider never reported it, in which case
     * the reasoning section shows no duration rather than a zero.
     */
    val reasoningDurationMs: Long? = null,
    /** Sources the model cited. Only ever set on an assistant message. */
    val citations: List<Citation>? = null,
    /** Structured native calls which this connection could not execute. Local-only diagnostics. */
    @kotlinx.serialization.Transient
    val unhandledToolCalls: List<UnhandledToolCall> = emptyList(),
    @kotlinx.serialization.Transient
    val toolFallbackNotice: String? = null,
    /**
     * P5 execution facts are local message diagnostics. Room persists their coarse owner/state
     * facts; @Transient keeps the cloud-sync and export envelopes free of
     * provider response details and custom configuration metadata.
     */
    @kotlinx.serialization.Transient
    val capabilityExecutionResults: List<CapabilityExecutionResult> = emptyList(),
    /**
     * P5 local-only recovery affordance. It is set only for a pre-token upstream HTTP 400 on a
     * request that actually carried a local custom fragment; it deliberately carries no response
     * body, provider, model, pointer, or custom value into sync/export.
     */
    @kotlinx.serialization.Transient
    val customRetryWithoutFieldsAvailable: Boolean = false,
    /** Stable, non-sensitive local diagnostic code for the above affordance. */
    @kotlinx.serialization.Transient
    val customRetryWithoutFieldsCode: String? = null,
    /**
     * Token counts as the provider reported them.
     *
     * Null means "not reported", which is not the same as zero: a cost built on a missing count
     * would silently read as free. See [ai.oriveo.community.core.provider.CostSource] for how the
     * displayed figure was arrived at.
     */
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
    val cachedInputTokens: Int? = null,
    /** Total cache-write tokens, across both of the TTL buckets below. */
    val cacheCreationInputTokens: Int? = null,
    val cacheCreation5mTokens: Int? = null,
    val cacheCreation1hTokens: Int? = null,
    val costSource: String? = null,
) {
    val estimatedCostText: String
        get() = CostFormatter.format(estimatedCost)

    companion object {
        /**
         * Merges two lists of messages by id, keeping the local copy when both sides have one.
         *
         * Used when restoring a backup over an existing conversation: the on-device copy is the
         * one the user just watched stream in, so it wins on visible text, while the restored copy
         * can still fill in token counts the local row never received.
         */
        fun mergeByIdAndCreatedAt(local: List<ChatMessage>, restored: List<ChatMessage>): List<ChatMessage> {
            val seen = mutableSetOf<String>()
            val combined = ArrayList<ChatMessage>(local.size + restored.size)
            for (msg in local) {
                if (seen.add(msg.id)) combined.add(msg)
            }
            for (msg in restored) {
                if (seen.add(msg.id)) {
                    combined.add(msg)
                } else {
                    val index = combined.indexOfFirst { it.id == msg.id }
                    if (index >= 0) {
                        combined[index] = mergeUsage(combined[index], msg)
                    }
                }
            }
            return combined.sortedWith(
                compareBy({ it.createdAt ?: Long.MIN_VALUE }, { it.id })
            )
        }

        private fun mergeUsage(local: ChatMessage, remote: ChatMessage): ChatMessage =
            local.copy(
                quoteContext = local.quoteContext?.takeIf { it.isValid }
                    ?: remote.quoteContext?.takeIf { it.isValid },
            ).withUsage(
                UsageSnapshot.resolve(
                    local = UsageSnapshot.from(local),
                    remote = UsageSnapshot.from(remote),
                ),
            )

        /**
         * Token counts for one message: the plain input and output totals plus the cache-write
         * buckets that some providers bill separately.
         *
         * A message row carries no revision of its own, so the two sides cannot be ordered in
         * time. Merging therefore has to be a rule about the numbers themselves rather than about
         * which copy is newer.
         */
        internal data class UsageSnapshot(
            val inputTokens: Int?,
            val outputTokens: Int?,
            val cachedInputTokens: Int?,
            val cacheCreationInputTokens: Int?,
            val cacheCreation5mTokens: Int?,
            val cacheCreation1hTokens: Int?,
        ) {
            fun isEmpty(): Boolean =
                inputTokens == null && outputTokens == null && cachedInputTokens == null &&
                    cacheCreationInputTokens == null && cacheCreation5mTokens == null &&
                    cacheCreation1hTokens == null

            /** How much of the response was actually accounted for, used to pick the fuller copy. */
            fun accountedTotal(): Long = (inputTokens?.toLong() ?: 0L) + (outputTokens?.toLong() ?: 0L)

            /**
             * Drops cache detail that contradicts the input total.
             *
             * The cache buckets are a breakdown of the input tokens, so their sum can never exceed
             * it. When it does, the two halves came from different responses, and showing a cost
             * built out of both is worse than showing no breakdown at all.
             */
            fun consistentlyTrimmed(): UsageSnapshot {
                if (cachedInputTokens == null && cacheCreationInputTokens == null) return this
                if (inputTokens == null) return this
                val cacheSum = (cachedInputTokens?.toLong() ?: 0L) + (cacheCreationInputTokens?.toLong() ?: 0L)
                if (cacheSum <= inputTokens.toLong()) return this
                return copy(
                    cachedInputTokens = null,
                    cacheCreationInputTokens = null,
                    cacheCreation5mTokens = null,
                    cacheCreation1hTokens = null,
                )
            }

            companion object {
                fun from(message: ChatMessage): UsageSnapshot = UsageSnapshot(
                    inputTokens = message.inputTokens,
                    outputTokens = message.outputTokens,
                    cachedInputTokens = message.cachedInputTokens,
                    cacheCreationInputTokens = message.cacheCreationInputTokens,
                    cacheCreation5mTokens = message.cacheCreation5mTokens,
                    cacheCreation1hTokens = message.cacheCreation1hTokens,
                )

                /** Keeps whichever side accounted for more of the response, never a blend. */
                fun resolve(local: UsageSnapshot, remote: UsageSnapshot): UsageSnapshot {
                    if (remote.isEmpty()) return local.consistentlyTrimmed()
                    if (local.isEmpty()) return remote.consistentlyTrimmed()
                    return (if (remote.accountedTotal() > local.accountedTotal()) remote else local)
                        .consistentlyTrimmed()
                }
            }
        }

        private fun ChatMessage.withUsage(usage: UsageSnapshot): ChatMessage = copy(
            inputTokens = usage.inputTokens,
            outputTokens = usage.outputTokens,
            cachedInputTokens = usage.cachedInputTokens,
            cacheCreationInputTokens = usage.cacheCreationInputTokens,
            cacheCreation5mTokens = usage.cacheCreation5mTokens,
            cacheCreation1hTokens = usage.cacheCreation1hTokens,
        )
    }
}

@Immutable
@Serializable
data class UnhandledToolCall(
    val id: String,
    val name: String,
    val arguments: String,
)

/** How one generation parameter is resolved: inherited, set to a value, or left out entirely. */
@Serializable
enum class GenerationOverrideState {
    @SerialName("inherit") Inherit,
    @SerialName("value") Value,
    @SerialName("omit") Omit,
}

@Serializable
data class GenerationParameterOverride(
    val state: GenerationOverrideState = GenerationOverrideState.Inherit,
    val value: JsonElement? = null,
)

/** The user's per-parameter choices, keyed by the wire name the provider expects. */
@Serializable
data class GenerationParameterOverrides(
    val values: Map<String, GenerationParameterOverride> = emptyMap(),
)

/** Everything a single chat request needs beyond the messages themselves. */
@Immutable
@Serializable
data class ChatRequestOptions(
    val temperature: Float? = null,
    val maxTokens: Int? = null,
    val systemPrompt: String = "",
    val generationParameters: GenerationParameterOverrides? = null,
    val relayRequested: RelayRequestedConfig? = null,
    val relayImage: RelayImageConfig? = null,
    /** Which capability evidence this request was compiled against, for retry decisions. */
    @kotlinx.serialization.Transient val capabilityEvidenceIdentity: CapabilityEvidenceIdentity? = null,
    /** R3 preference/rejection identity; local-only and never confused with LWW mutation revision. */
    @kotlinx.serialization.Transient val modelControlRuntimeIdentity: ai.oriveo.community.core.provider.ModelControlRuntimeIdentity? = null,
    /** Exact dormant pointers, separated by source. Values are runtime projections, never synced. */
    @kotlinx.serialization.Transient val rejectedRecipeSettings: Map<String, Map<String, Set<String>>> = emptyMap(),
    @kotlinx.serialization.Transient val rejectedCustomSettings: Map<String, Set<String>> = emptyMap(),
    /** Normal sends suppress an entire rejected owner. Only an explicit one-request recipe latch may bypass it. */
    @kotlinx.serialization.Transient val dormantCapabilityOwners: Set<String> = emptySet(),
    @kotlinx.serialization.Transient val activeModel: AIModel? = null,
    /** P3c local-only continuation: populated only by ChatRepository on an explicit continue/retry. */
    @kotlinx.serialization.Transient val localContinuationMessageId: String? = null,
    @kotlinx.serialization.Transient val localContinuationState: JsonObject? = null,
    @kotlinx.serialization.Transient val localContinuationExplicit: Boolean = false,
    /** User-supplied advanced JSON fragment; local-only and compiled by the production builder. */
    @kotlinx.serialization.Transient val localCustomFragment: String? = null,
    @kotlinx.serialization.Transient val localCustomOwner: String = "generation",
    /** P4c owner-scoped local fragments.  Never serialized; Auto/Custom is mutually exclusive per owner. */
    @kotlinx.serialization.Transient val localCustomFragments: Map<String, String> = emptyMap(),
    /** P5 local request lifecycle carrier; never persisted, synced, logged, or serialized. */
    @kotlinx.serialization.Transient val capabilityExecutionCollector: CapabilityExecutionCollector? = null,
    /** P4b typed UI intent. Process-local only; the P3 compiler remains the wire authority. */
    @kotlinx.serialization.Transient val capabilityPreferences: CapabilityPreferenceValues? = null,
    /**
     * Grok subscription context: the chat URL and headers that a subscription sign-in produced.
     *
     * Transient on purpose. These are short-lived credentials for one request; persisting them
     * would leave the user's subscription reachable from a backup file.
     */
    @kotlinx.serialization.Transient
    val grokSubscription: ai.oriveo.community.core.provider.grok.GrokSubscriptionRequestContext? = null,
    /**
     * Codex subscription context, the ChatGPT counterpart to [grokSubscription] and transient for
     * the same reason.
     */
    @kotlinx.serialization.Transient
    val openAISubscription: ai.oriveo.community.core.provider.openai.OpenAISubscriptionRequestContext? = null,
) {
    companion object {
        const val DEFAULT_TEMPERATURE = 1.0f
        const val DEFAULT_MAX_TOKENS = 8192
    }

    val hasCustomizations: Boolean
        get() = temperature != null || maxTokens != null || systemPrompt.isNotBlank() || generationParameters != null

    val effectiveTemperature: Float
        get() = temperature ?: DEFAULT_TEMPERATURE

    val effectiveMaxTokens: Int
        get() = maxTokens ?: DEFAULT_MAX_TOKENS
}
