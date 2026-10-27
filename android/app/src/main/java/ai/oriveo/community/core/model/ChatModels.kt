package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import ai.oriveo.community.core.usage.CostPart
import ai.oriveo.community.core.usage.CostParts
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

/**
 * The non-USD part of a message's cost: [currencyCode] is an upper-case ISO 4217 code and is never converted;
 * [costSource] has the same meaning as [ChatMessage.costSource] (a [ai.oriveo.community.core.provider.CostSource] name).
 * When a second non-USD currency shows up on the same message it is recorded as {first currency, 0, UNKNOWN} and the amounts are not added.
 */
@Immutable
@Serializable
data class NonUsdCost(
    val currencyCode: String,
    val amount: Double,
    val costSource: String,
)

/** Target of the "switch to another service" secondary action on an external search error card. */
@Immutable
@Serializable
data class SearchMessageSwitchTarget(val id: String, val name: String)

/** External search error card (finishSearchReply.errorCard plus serviceId); newer fields have defaults so older rows still decode. */
@Immutable
@Serializable
data class SearchMessageErrorCard(
    val errorClass: String,
    val headline: String,
    val primaryAction: String,
    val secondaryAction: String? = null,
    val serviceName: String,
    val serviceId: String? = null,
    val switchTo: SearchMessageSwitchTarget? = null,
)

/** Title line of the external search sources card (finishSearchReply.sourcesLine); newer fields have defaults so older rows still decode. */
@Immutable
@Serializable
data class SearchMessageSourcesLine(
    val searchCount: Int,
    val serviceName: String,
    val sourceCount: Int,
    val reused: Boolean = false,
    val custom: Boolean = false,
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
    /**
     * Why the answer ended (v38). Null for old messages; an unrecognized string reads as UNKNOWN. Serialized with
     * backups (null writes no key); does not take part in message state decisions.
     */
    @kotlinx.serialization.Serializable(with = StoredStopReasonSerializer::class)
    val stopReason: ai.oriveo.community.core.context.StopReason? = null,
    /**
     * Ids of the memory items actually injected into this answer's request (v42, in injection order); null when none were injected.
     * Stored in local Room only: @Transient keeps it out of backup export.
     */
    @kotlinx.serialization.Transient
    val memoryItemIds: List<String>? = null,
    /**
     * Placeholder lines appended to the end of [text] when the outbound input-capability gate strips media; the request body builder
     * uses them to move the lines after the file blocks. Exists only on the outbound copy: @Transient keeps it out of storage, and out of export.
     */
    @kotlinx.serialization.Transient
    val outboundPlaceholders: List<String>? = null,
    /**
     * Summaries of the remote MCP tool steps, stored with the message. Raw arguments and results
     * are not here; they live in `mcp_step_payload`.
     */
    val toolSteps: List<ai.oriveo.community.core.mcp.McpToolStep>? = null,
    /** Structured native calls which this connection could not execute. Local-only diagnostics. */
    @kotlinx.serialization.Transient
    val unhandledToolCalls: List<UnhandledToolCall> = emptyList(),
    @kotlinx.serialization.Transient
    val toolFallbackNotice: String? = null,
    /**
     * Error card shown when every external search failed (the whole finishSearchReply.errorCard).
     * Local diagnostics: stored in Room, @Transient keeps it out of sync and export.
     */
    @kotlinx.serialization.Transient
    val searchErrorCard: SearchMessageErrorCard? = null,
    /** One-off external search notice (finishSearchReply.notice, e.g. tools_rejected); local diagnostics, as above. */
    @kotlinx.serialization.Transient
    val searchNotice: String? = null,
    /** Title line of the sources card (finishSearchReply.sourcesLine); local diagnostics: stored in Room, @Transient keeps it out of sync and export. */
    @kotlinx.serialization.Transient
    val searchSourcesLine: SearchMessageSourcesLine? = null,
    /**
     * Execution facts are local message diagnostics. Room persists their coarse owner/state
     * facts; @Transient keeps the cloud-sync and export envelopes free of
     * provider response details and custom configuration metadata.
     */
    @kotlinx.serialization.Transient
    val capabilityExecutionResults: List<CapabilityExecutionResult> = emptyList(),
    /**
     * Local-only recovery affordance. It is set only for a pre-token upstream HTTP 400 on a
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
    /** The non-USD part; [estimatedCost] and [costSource] describe only the USD part. Null = there is no non-USD part. */
    val nonUsdCost: NonUsdCost? = null,
) {
    /** Cost parts for display, per currency: USD first, zero amounts omitted. */
    val costParts: List<CostPart>
        get() = CostParts.messageParts(estimatedCost, nonUsdCost)

    /** Non-USD currencies whose amount is unknown: show the existing "not available" text, never 0. */
    val notAvailableCostCodes: List<String>
        get() = CostParts.messageNotAvailableCodes(nonUsdCost)

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
    /**
     * The transport and API root resolved per model for this outbound request (`RelayEndpointResolver.effectiveTransport` /
     * `effectiveAPIRoot`). The Relay outbound layer dispatches only by them and no longer reads the connection-level single value of [relayRequested].
     */
    @kotlinx.serialization.Transient val relayRouteTransport: RelayTransport? = null,
    @kotlinx.serialization.Transient val relayRouteAPIRoot: String? = null,
    /**
     * Called back with the new transport after a Relay transport-level fallback switched transport and this send succeeded; ChatRepository writes it back as the model's observed value.
     * Set only inside the outbound chain, not serialized.
     */
    @kotlinx.serialization.Transient val relayProtocolSwitched: (suspend (RelayTransport) -> Unit)? = null,
    /** Called back when a transport-level fallback starts switching transport (before the resend); the failure path uses it to skip recording the image negative cache. */
    @kotlinx.serialization.Transient val relayProtocolSwitchStarted: ((RelayTransport) -> Unit)? = null,
    /**
     * Called back when a Relay request carrying native file blocks is rejected for the first time (rejection signal) and the fallback chain did not recover it;
     * ChatRepository uses it to mark the failed message as file-rejected. Set only inside the outbound chain, not serialized.
     */
    @kotlinx.serialization.Transient val relayFileRejected: (() -> Unit)? = null,
    /**
     * Effective web fragments of a relay connection (key = transport value): injected only by the chat send chain; the builder takes one segment by the effective transport
     * and merges it before the extra request body. Auxiliary requests such as capability tests and titles do not inject it.
     */
    @kotlinx.serialization.Transient val relayWebFragments: Map<String, JsonObject> = emptyMap(),
    /** Which capability evidence this request was compiled against, for retry decisions. */
    @kotlinx.serialization.Transient val capabilityEvidenceIdentity: CapabilityEvidenceIdentity? = null,
    /** R3 preference/rejection identity; local-only and never confused with LWW mutation revision. */
    @kotlinx.serialization.Transient val modelControlRuntimeIdentity: ai.oriveo.community.core.provider.ModelControlRuntimeIdentity? = null,
    /** Exact dormant pointers, separated by source. Values are runtime projections, never synced. */
    @kotlinx.serialization.Transient val rejectedRecipeSettings: Map<String, Map<String, Set<String>>> = emptyMap(),
    @kotlinx.serialization.Transient val rejectedCustomSettings: Map<String, Set<String>> = emptyMap(),
    /** Normal sends suppress an entire rejected owner. Only an explicit one-request recipe latch may bypass it. */
    @kotlinx.serialization.Transient val dormantCapabilityOwners: Set<String> = emptySet(),
    /**
     * Parameter names explicitly omitted for this one request by "resend without this parameter" (a subset of the parameter-gate list). It covers only this request and does not change what is persisted;
     * the parameters are omitted even if the negative cache has expired or been cleared, and later ordinary retries still follow the negative cache.
     */
    @kotlinx.serialization.Transient val omitParametersOnce: Set<String> = emptySet(),
    @kotlinx.serialization.Transient val activeModel: AIModel? = null,
    /** This request must not carry original file blocks (the resend after a native file fallback, or a connection already known not to accept them). Set only inside the outbound path. */
    @kotlinx.serialization.Transient val nativeFilesDisabled: Boolean = false,
    /** Local-only continuation: populated only by ChatRepository on an explicit continue/retry. */
    @kotlinx.serialization.Transient val localContinuationMessageId: String? = null,
    @kotlinx.serialization.Transient val localContinuationState: JsonObject? = null,
    @kotlinx.serialization.Transient val localContinuationExplicit: Boolean = false,
    /** Set by the caller when it determines that this round's system / model / checkpoint fingerprint matches the previous leg; the default false = mismatch, so previous_id continuation falls back to the full plan. */
    @kotlinx.serialization.Transient val localContinuationFingerprintMatches: Boolean = false,
    /** User-supplied advanced JSON fragment; local-only and compiled by the production builder. */
    @kotlinx.serialization.Transient val localCustomFragment: String? = null,
    @kotlinx.serialization.Transient val localCustomOwner: String = "generation",
    /** P4c owner-scoped local fragments.  Never serialized; Auto/Custom is mutually exclusive per owner. */
    @kotlinx.serialization.Transient val localCustomFragments: Map<String, String> = emptyMap(),
    /** The additional request body text that actually went out with this request; stays in process, never serialized or sent to telemetry. */
    @kotlinx.serialization.Transient val additionalRequestBody: String? = null,
    /**
     * Chat-path assembler inputs (send / retry / regenerate / edit-and-send). When set, ChatRepository
     * takes system and history from the ContextPlan; [systemPrompt] stays as the fallback for a rejected plan.
     */
    @kotlinx.serialization.Transient val chatContext: ai.oriveo.community.core.context.ChatContextRequest? = null,
    /**
     * The plan's [D] text for this request (the dynamic blocks joined with "\n\n"); it already closes the last
     * user text. Only [ai.oriveo.community.core.data.repository.PlannedChatRequest.transportInput] sets it.
     */
    @kotlinx.serialization.Transient val dynamicText: String? = null,
    /**
     * Client-side function tools for this request (e.g. propose_memory). Every chat body builder writes them in its
     * own protocol shape plus [clientToolChoice]; empty leaves the body byte-identical. Local-only, never serialized.
     */
    @kotlinx.serialization.Transient val clientTools: List<ai.oriveo.community.core.tools.ToolLoopToolDefinition> = emptyList(),
    @kotlinx.serialization.Transient val clientToolChoice: ai.oriveo.community.core.tools.ToolLoopToolChoice =
        ai.oriveo.community.core.tools.ToolLoopToolChoice.Auto,
    /**
     * Chat-path output budget (`plan.budget.oWire`). Services that already send a max-output field use it as the
     * base value instead of their metadata / 8192 fallback; null (non-chat paths) keeps the previous behavior.
     */
    @kotlinx.serialization.Transient val outputTokenBudget: Int? = null,
    /**
     * Called with the transport when an attempt carrying the web fragment is rejected with 400 / 422 before any output and the same-transport
     * resend without the fragment succeeds; ChatRepository writes a rejected record for that transport and attaches a reply notice.
     * Set only inside the outbound chain, never serialized.
     */
    @kotlinx.serialization.Transient val relayWebFragmentDropped: ((RelayTransport) -> Unit)? = null,
    /** Local request lifecycle carrier; never persisted, synced, logged, or serialized. */
    @kotlinx.serialization.Transient val capabilityExecutionCollector: CapabilityExecutionCollector? = null,
    /** Typed UI intent. Process-local only; the recipe compiler remains the wire authority. */
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

/** stopReason in a backup is read and written as its wire text; an unrecognized string (written by another client or a newer version) reads as UNKNOWN instead of failing the whole import. */
internal object StoredStopReasonSerializer : kotlinx.serialization.KSerializer<ai.oriveo.community.core.context.StopReason> {
    override val descriptor: kotlinx.serialization.descriptors.SerialDescriptor =
        kotlinx.serialization.descriptors.PrimitiveSerialDescriptor(
            "ai.oriveo.community.core.model.StoredStopReason",
            kotlinx.serialization.descriptors.PrimitiveKind.STRING,
        )

    override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: ai.oriveo.community.core.context.StopReason) =
        encoder.encodeString(value.wire)

    override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): ai.oriveo.community.core.context.StopReason =
        ai.oriveo.community.core.context.StopReason.fromStored(decoder.decodeString())
            ?: ai.oriveo.community.core.context.StopReason.UNKNOWN
}
