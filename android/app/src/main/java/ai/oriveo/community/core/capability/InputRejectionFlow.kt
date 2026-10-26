package ai.oriveo.community.core.capability

import android.content.Context
import ai.oriveo.community.core.attachments.AttachmentRoute
import ai.oriveo.community.core.attachments.AttachmentRouter
import ai.oriveo.community.core.capability.truth.InputNegativeCacheTarget
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.capability.truth.officialInputNegativeCacheTarget
import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.messagesForInputOutbound
import ai.oriveo.community.core.provider.routeImagePlaceholder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * An official connection's upstream rejects media (same semantics as the Web client):
 * the first leg fails before any output, the error matches a narrow signature, and the named input key was really carried this time -> record a v2 negative cache entry.
 * No retry, no change to the error; the next projection of that key is `disabled.rejected_recently` and the outbound swaps in a placeholder,
 * so the failure card's "resend without the image" is an ordinary resend. No signature match, output already started, or a local / network error has no side effects, and the error is shown as is.
 *
 * Official connections only: Relay has its own rejection loop, and subscriptions have no such negative cache.
 * Parameter signatures (param_rejected) go through [recordOfficialParameter]: it records `param:<name>`, and the next outbound omits that parameter via
 * [ai.oriveo.community.core.provider.GenerationParameterResolver] through [rejectedParameters].
 */
object InputRejectionFlow {
    data class Result(val capabilityKey: String, val signatureId: String, val wireFamily: String)

    /**
     * Prefix of the persisted marker for the failure card's "resend without the image / file / video":
     * `input_capability_rejected:<capabilityKey>`, one action per rejected input key.
     */
    const val INPUT_REJECTED_CODE_PREFIX = "input_capability_rejected:"

    /** Marker for a rejected vision input; older messages persisted exactly this value, so it stays compatible. */
    const val RESEND_WITHOUT_IMAGE_CODE = "$INPUT_REJECTED_CODE_PREFIX${CapabilityEvidenceFacade.VISION_INPUT}"

    /** Prefix of the persisted marker for the failure card's "resend without this parameter": `input_parameter_rejected:<parameter>`. */
    const val PARAMETER_REJECTED_CODE_PREFIX = "input_parameter_rejected:"

    private val RESENDABLE_INPUT_KEYS = setOf(
        CapabilityEvidenceFacade.VISION_INPUT,
        CapabilityEvidenceFacade.FILE_INPUT,
        CapabilityEvidenceFacade.VIDEO_INPUT,
    )

    /**
     * The rejection recorded by the failed message itself -> persisted marker: a rejected medium yields a code by capabilityKey, a rejected parameter yields a parameter code, and when both exist the medium wins;
     * when nothing matched (including the case where the negative cache already exists but this time no signature matched) returns null and the failure card offers no one-tap action.
     */
    fun recoveryCode(input: Result?, rejectedParameter: String?): String? {
        input?.capabilityKey?.takeIf { it in RESENDABLE_INPUT_KEYS }?.let { return "$INPUT_REJECTED_CODE_PREFIX$it" }
        return rejectedParameter?.takeIf { it in GATED_PARAMETERS }?.let { "$PARAMETER_REJECTED_CODE_PREFIX$it" }
    }

    /** The rejected input key in a persisted marker; null when it is not a rejected-media marker or the key is unknown. */
    fun rejectedInputKey(code: String?): String? =
        code?.takeIf { it.startsWith(INPUT_REJECTED_CODE_PREFIX) }
            ?.removePrefix(INPUT_REJECTED_CODE_PREFIX)
            ?.takeIf { it in RESENDABLE_INPUT_KEYS }

    /** The rejected parameter name in a persisted marker; null when it is not a rejected-parameter marker or the parameter is not gated. */
    fun rejectedParameter(code: String?): String? =
        code?.takeIf { it.startsWith(PARAMETER_REJECTED_CODE_PREFIX) }
            ?.removePrefix(PARAMETER_REJECTED_CODE_PREFIX)
            ?.takeIf { it in GATED_PARAMETERS }

    /** Signature id used when the existing Relay rejection loop also writes v2 (the same value as the Web `RELAY_CLASSIFIED_REJECTED_SIGNATURE_ID`). */
    const val RELAY_CLASSIFIED_REJECTED_SIGNATURE_ID = "relay.classified_rejected"

    /**
     * When the existing Relay logic writes the v1 `image` / `file` negative cache it also writes a v2 entry (same semantics as the Web `recordRelayInputRejectionV2`):
     * the key and revision come from [ai.oriveo.community.core.capability.truth.relayInputNegativeCacheTarget], so behavior is unchanged once readers switch to v2.
     * The Relay verdict still reads v1. No wire family recognized (a null target) writes nothing.
     */
    internal fun recordRelay(target: InputNegativeCacheTarget?, negativeCache: InputNegativeCache = InputNegativeCache.shared) {
        target ?: return
        negativeCache.record(
            connectionId = target.connectionId,
            modelId = target.modelId,
            wireFamily = target.wireFamily,
            capabilityKey = target.capabilityKey,
            signatureId = RELAY_CLASSIFIED_REJECTED_SIGNATURE_ID,
            verdict = target.verdict,
        )
    }

    /** Normalized transport -> protocol name of the signature table. */
    private val SIGNATURE_PROTOCOL_BY_TRANSPORT = mapOf(
        "openai_chat" to "openai_chat",
        "openai_responses" to "openai_responses",
        "anthropic_messages" to "anthropic",
        "gemini_generate_content" to "gemini",
    )

    @Volatile private var context: Context? = null
    @Volatile private var loadedTable: RejectionSignatureTable? = null

    /** Only keeps the application context; the signature table reads its asset on the first judgement. */
    fun configure(context: Context) {
        this.context = context.applicationContext
    }

    private fun sharedTable(): RejectionSignatureTable? =
        loadedTable ?: context?.let(RejectionSignatures::load)?.also { loadedTable = it }

    /**
     * Called after the first leg fails: a matching media signature writes a v2 negative cache entry and returns the match; otherwise returns null and writes nothing.
     * [messages] must be the messages after the outbound gate ([outboundMessages]): "carried this time" counts only native parts really in the request body;
     * images / videos already swapped for a placeholder and files sent through text injection do not count.
     * [finalTransport] is the same one as the outbound projection uses (by default the transport of the metadata entry).
     */
    fun recordOfficial(
        provider: Provider,
        model: AIModel,
        messages: List<ChatMessage>,
        error: Throwable,
        outputStarted: Boolean,
        finalTransport: String? = null,
        table: RejectionSignatureTable? = sharedTable(),
        negativeCache: InputNegativeCache = InputNegativeCache.shared,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): Result? {
        if (outputStarted || table == null) return null
        val upstream = error as? ProviderServiceError.Upstream ?: return null
        // An in-stream error frame and a failure on a 2xx are not upstream rejecting the request body (blocked / empty result).
        if (upstream.streamErrorFrame || upstream.statusCode in 200..299) return null
        val targets = carriedKeys(messages, provider, model).mapNotNull { key ->
            officialInputNegativeCacheTarget(provider, model, key, finalTransport, metadataClient)?.let { key to it }
        }.toMap()
        if (targets.isEmpty()) return null
        val protocol = SIGNATURE_PROTOCOL_BY_TRANSPORT[targets.values.first().transport] ?: return null
        val match = table.match(
            protocol = protocol,
            wireFamilies = targets.values.map { it.wireFamily },
            httpStatus = upstream.statusCode,
            body = upstream.rawBody ?: upstream.detail,
        ) ?: return null
        if (match.kind != "input_rejected") return null
        val target = targets[match.capabilityKey] ?: return null
        negativeCache.record(
            connectionId = target.connectionId,
            modelId = target.modelId,
            wireFamily = target.wireFamily,
            capabilityKey = target.capabilityKey,
            signatureId = match.signatureId,
            verdict = target.verdict,
        )
        return Result(target.capabilityKey, match.signatureId, target.wireFamily)
    }

    /** Parameters managed by the parameter gate (the signature table's `parameter` names); other parameter signatures (tools / enable_search) are not handled here. */
    val GATED_PARAMETERS = setOf("temperature", "top_p", "structured_output", "thinking")

    /** Generation parameter id -> signature table parameter name: structured output is `json_schema` on the panel. */
    fun gatedParameterName(generationParameterId: String): String =
        if (generationParameterId == "json_schema") "structured_output" else generationParameterId

    /**
     * Called after the first leg fails: the error of an official connection matches a param_rejected narrow signature and the named parameter is one of [GATED_PARAMETERS] ->
     * record a negative cache entry `param:<name>` and return the parameter name; otherwise returns null and writes nothing. No retry, no change to the error.
     * Key: connection x model x the transport actually dispatched this time (canonical name) x `param:<name>`; the revision is computed from the verdict of that model's metadata
     * `parameterSupport[<name>]` (unknown by default); when parameterSupport changes the cache no longer hits (same as Web).
     * When the transport is unavailable ([dispatchTransport] is null) nothing is recorded: the outbound read side only trusts the dispatch transport too, so it could not be found anyway.
     */
    fun recordOfficialParameter(
        provider: Provider,
        model: AIModel,
        error: Throwable,
        outputStarted: Boolean,
        dispatchTransport: String?,
        table: RejectionSignatureTable? = sharedTable(),
        negativeCache: InputNegativeCache = InputNegativeCache.shared,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): String? {
        if (outputStarted || table == null) return null
        if (ProviderForm.of(provider) != ProviderForm.Official) return null
        val upstream = error as? ProviderServiceError.Upstream ?: return null
        if (upstream.streamErrorFrame || upstream.statusCode in 200..299) return null
        val transport = normalizedParameterTransport(dispatchTransport) ?: return null
        val protocol = SIGNATURE_PROTOCOL_BY_TRANSPORT[transport] ?: return null
        val match = table.match(
            protocol = protocol,
            wireFamilies = emptyList(),
            httpStatus = upstream.statusCode,
            body = upstream.rawBody ?: upstream.detail,
        ) ?: return null
        if (match.kind != "param_rejected") return null
        val parameter = match.parameter?.takeIf { it in GATED_PARAMETERS } ?: return null
        negativeCache.record(
            connectionId = provider.id,
            modelId = model.id,
            wireFamily = transport,
            capabilityKey = InputNegativeCache.paramCapabilityKey(parameter),
            signatureId = match.signatureId,
            verdict = parameterSupportVerdict(provider.kind, model.id, parameter, metadataClient),
        )
        return parameter
    }

    /**
     * Outbound read side: parameter names (a subset of [GATED_PARAMETERS]) recently rejected on an official connection for this request.
     * The connection id comes from the request identity and the transport from the dispatch transport (the same ones as [recordOfficialParameter]);
     * for non-official forms (Relay / subscription), or when the identity or transport is missing, the negative-cache part is an empty set.
     * The one-shot omit list from the user's "resend without this parameter" ([ChatRequestOptions.omitParametersOnce] ∩ [GATED_PARAMETERS])
     * is always merged in, regardless of whether the negative cache still hits and regardless of form: every transport (including each vendor's hand-built body) reads only this one entry point.
     */
    fun rejectedParameters(
        options: ChatRequestOptions,
        modelId: String?,
        negativeCache: InputNegativeCache = InputNegativeCache.shared,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): Set<String> {
        val once = options.omitParametersOnce.filterTo(mutableSetOf()) { it in GATED_PARAMETERS }
        return once + cachedRejectedParameters(options, modelId, negativeCache, metadataClient)
    }

    /** The negative-cache part of [rejectedParameters]: can be non-empty only for an official connection with both identity and transport. */
    private fun cachedRejectedParameters(
        options: ChatRequestOptions,
        modelId: String?,
        negativeCache: InputNegativeCache,
        metadataClient: MetadataClient,
    ): Set<String> {
        val identity = options.capabilityEvidenceIdentity ?: return emptySet()
        val kind = ProviderKind.fromRawValue(identity.providerKind) ?: return emptySet()
        if (ProviderForm.of(kind, ProviderAuthMode.fromRawValue(identity.authMode)) != ProviderForm.Official) return emptySet()
        val connectionId = identity.connectionInstanceId.takeIf(String::isNotBlank) ?: return emptySet()
        val model = modelId?.takeIf(String::isNotBlank) ?: return emptySet()
        val transport = normalizedParameterTransport(options.capabilityExecutionCollector?.inputDispatchTransport)
            ?: return emptySet()
        return GATED_PARAMETERS.filterTo(mutableSetOf()) { name ->
            negativeCache.isHit(
                connectionId = connectionId,
                modelId = model,
                wireFamily = transport,
                capabilityKey = InputNegativeCache.paramCapabilityKey(name),
                verdict = parameterSupportVerdict(kind, model, name, metadataClient),
            )
        }
    }

    /** `{state, reasonCode, sourceRefs}` of the model metadata `parameterSupport[<name>]`; null when the entry is missing (the revision is computed as unknown). */
    private fun parameterSupportVerdict(
        kind: ProviderKind,
        modelId: String,
        parameter: String,
        metadataClient: MetadataClient,
    ): InputNegativeCache.Verdict? {
        val support = metadataClient.currentCapabilityEvidenceModel(modelId, kind)?.metadata?.parameterSupport
        val entry = support?.get(parameter) as? JsonObject ?: return null
        fun string(key: String) = (entry[key] as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content
        val state = string("state") ?: return null
        return InputNegativeCache.Verdict(
            state = state,
            reasonCode = string("reasonCode"),
            sourceRefs = (entry["sourceRefs"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content },
        )
    }

    /** Various spellings of a dispatch transport collapsed to the canonical name the signature table recognizes (the same convention as the input negative cache). */
    private fun normalizedParameterTransport(raw: String?): String? = when (raw?.trim()?.lowercase()) {
        null, "" -> null
        "openai", "openai_compatible", "openai_chat", "openai_chat_completions" -> "openai_chat"
        "openai_responses" -> "openai_responses"
        "anthropic", "anthropic_messages" -> "anthropic_messages"
        "gemini", "gemini_generate", "gemini_generate_content" -> "gemini_generate_content"
        else -> raw.trim().lowercase()
    }

    /**
     * The messages after the outbound gate: the same projection and the same rewrite as the server outbound gate (the three-key branch of messagesForCapabilityProjection) --
     * the projection is resolved by [provider] (its connection id must match the request identity) and the transport actually dispatched this time, [dispatchTransport].
     * Returns null when the transport is unavailable or the projection is not the official three-key one: without the post-gate result the caller would rather not record.
     */
    internal fun outboundMessages(
        provider: Provider,
        model: AIModel,
        messages: List<ChatMessage>,
        dispatchTransport: String?,
        metadataClient: MetadataClient = MetadataClient.instance,
        negativeCache: InputNegativeCache = InputNegativeCache.shared,
    ): List<ChatMessage>? {
        val transport = dispatchTransport?.takeIf(String::isNotBlank) ?: return null
        if (ProviderForm.of(provider) != ProviderForm.Official) return null
        val inputs = resolveInputCapabilityProjections(
            provider,
            model,
            finalTransport = transport,
            metadataClient = metadataClient,
            negativeCache = negativeCache,
        ) ?: return null
        return messagesForInputOutbound(messages, inputs, routeImagePlaceholder(provider.kind.rawValue))
    }

    /**
     * The input keys really carried this time (same semantics as the Web `carriedKeys`, counting only outbound parts): an image / video counts only if it still carries bytes and will send a native part
     * (the builder sends nothing when it cannot get the bytes); a file counts only if [AttachmentRouter.decide] judges it Native (text injection is not file_input).
     */
    private fun carriedKeys(messages: List<ChatMessage>, provider: Provider, model: AIModel): Set<String> = buildSet {
        for (message in messages) {
            for (attachment in message.attachments.orEmpty()) {
                when (attachment.kind) {
                    AttachmentKind.Image -> if ((attachment.base64Data ?: attachment.thumbnailBase64) != null) {
                        add(CapabilityEvidenceFacade.VISION_INPUT)
                    }
                    AttachmentKind.Video -> if (attachment.base64Data != null) add(CapabilityEvidenceFacade.VIDEO_INPUT)
                    AttachmentKind.File -> if (AttachmentRouter.decide(attachment, provider.kind, model) == AttachmentRoute.Native) {
                        add(CapabilityEvidenceFacade.FILE_INPUT)
                    }
                }
            }
        }
    }
}
