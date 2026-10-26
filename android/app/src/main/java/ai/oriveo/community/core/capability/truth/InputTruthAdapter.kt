package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.capability.CapabilityOverrideOp
import ai.oriveo.community.core.capability.CapabilityOverrides
import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentSupportInfo
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.AttachmentTransportResolver
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityConnection
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityOverride
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityProjection
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.relay.RelayFirstSendTransport
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.core.provider.transport.TransportKind
import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Data source for input-capability projections (same semantics as the Web client): collects the official verdict, the Relay connection identity and envelope,
 * this client's protocol table, whether a transport is plain-text only, and the Relay overrides and negative cache into the input of [CapabilityEvidenceFacade.projectInputCapability].
 *
 * - Official: the verdict is `capabilityControls[key]` of the current metadata publication, null for a missing key (projected as unknown); overrides are ignored.
 * - Relay: the vision verdict reads connection evidence (a probe / engine declaration of supported -> auto_available, unsupported -> unavailable / model_capability_absent,
 *   anything else unknown), files / video are always unknown; a hit of the v1 vision negative cache ([RelayNegativeCache] image) feeds the input projection just like a v2 hit;
 *   an envelope with image=false (vision) / nativeFile=false (files), or no connection identity (a technical failure is not a verdict, fail-closed), counts as not implemented by this client,
 *   and no override can flip it; overrides read the effective value of [CapabilityOverrides.normalize] (old fields normalized).
 * - Subscription: the verdict comes from [SubscriptionTruthAdapter.inputVerdict] (first-hand declaration > modelFacts > unknown), projected on the subscription's outbound transport.
 */
internal data class InputCapabilityProjections(
    val vision: InputCapabilityProjection,
    val file: InputCapabilityProjection,
    val video: InputCapabilityProjection,
) {
    operator fun get(key: String): InputCapabilityProjection = when (key) {
        CapabilityEvidenceFacade.VISION_INPUT -> vision
        CapabilityEvidenceFacade.FILE_INPUT -> file
        CapabilityEvidenceFacade.VIDEO_INPUT -> video
        else -> throw IllegalArgumentException("not an input capability key: $key")
    }
}

/**
 * @param relayIdentity The full connection identity of a Relay ([ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter.uiDispatchIdentity]
 *   or dispatchIdentity); null = no identity available, and all three keys are hard-blocked.
 * @param relayAttachmentSupport The Relay connection envelope; resolved from the current connection by default, and failing to resolve does not count as a rejection.
 * @param finalTransport The protocol actually dispatched for the official connection this time; by default the transport of the metadata entry, and when the catalog is at hand but lacks this model, this client's dispatch transport
 *   ([officialDispatchTransport]) -- being outside the catalog does not mean this client has not implemented it; when the catalog has not arrived yet (Pending / Unavailable) the dispatch transport is used as well,
 *   and a missing verdict key is unknown (the catalog staying silent is neither unavailable nor "not implemented by this client").
 * @param storedOverrides The locally stored Relay delta overrides; null = take [AIModel.capabilityOverrides].
 * @param relayNegativeCache The Relay vision v1 negative cache (upstream really rejected an image); keyed by [RelayNegativeCache.keyFor].
 */
internal fun resolveInputCapabilityProjections(
    provider: Provider,
    model: AIModel,
    relayIdentity: CapabilityEvidenceFacade.QueryIdentity? = null,
    relayAttachmentSupport: AttachmentSupportInfo? = null,
    finalTransport: String? = null,
    storedOverrides: JsonElement? = null,
    metadataClient: MetadataClient = MetadataClient.instance,
    negativeCache: InputNegativeCache = InputNegativeCache.shared,
    relayNegativeCache: RelayNegativeCache = RelayNegativeCache.shared,
    now: Instant = Instant.now(),
): InputCapabilityProjections? {
    val form = ProviderForm.of(provider)
    when (form) {
        ProviderForm.Subscription -> return mapKeys { key -> subscriptionProjection(provider, model, key, finalTransport, metadataClient) }
        ProviderForm.Official, ProviderForm.Relay -> Unit
    }
    val relay = form == ProviderForm.Relay
    val officialMetadata = if (relay) null else metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)?.metadata
    val transport = if (relay) {
        relayTransport(RelayFirstSendTransport.resolve(provider, model))
    } else {
        officialTransport(provider, finalTransport, officialMetadata?.transport)
    }
    val envelope = if (relay) {
        relayAttachmentSupport ?: RelayRuntimeSupport.attachmentSupport(provider, MetadataClient.relayRuntimeConfig(), model)
    } else {
        null
    }

    val verdicts = INPUT_KEYS.associateWith { key ->
        val lineFamily = WIRE_FAMILY_BY_TRANSPORT.getValue(key)[transport]
        when {
            !relay -> officialVerdict(officialMetadata?.capabilityControls, key)
            else -> relayInputVerdict(provider, model, key, lineFamily, relayIdentity, metadataClient)
        }
    }
    // The v1 negative cache covers vision only (upstream really rejected an image); native files still go through the envelope + RelayNegativeCache chain and are not read here.
    val relayImageRejected = relay && RelayNegativeCache.keyFor(provider, model)
        ?.let { relayNegativeCache.isRejected(it, RelayNegativeCache.Kind.Image) } == true
    val overrides = if (relay) {
        CapabilityOverrides.normalize(
            connection = "relay",
            legacy = model.relayCapabilityOverrides,
            // When the caller gives none explicitly, read the deltas already stored on the model.
            stored = storedOverrides ?: model.capabilityOverrides,
            serverVerdict = verdicts.mapValues { (_, verdict) -> verdict?.state ?: "unknown" },
            now = now.toString(),
        ).effective
    } else {
        emptyMap()
    }

    return mapKeys { key ->
        val verdict = verdicts[key]
        val wireFamily = verdict?.wireFamily ?: WIRE_FAMILY_BY_TRANSPORT.getValue(key)[transport]
        // The envelope has only two bits, vision and native file: image=false blocks vision, nativeFile=false blocks file_input (same as Web);
        // video has no envelope bit, so it is not blocked here and is left to the outbound transport resolver.
        val relayBlocked = relay && (
            relayIdentity == null ||
                (key == CapabilityEvidenceFacade.VISION_INPUT && envelope?.image == false) ||
                (key == CapabilityEvidenceFacade.FILE_INPUT && envelope?.nativeFile == false)
            )
        val endImplements = CapabilityEvidenceFacade.endImplementsWireFamily(wireFamily) &&
            transport !in TEXT_ONLY_TRANSPORTS && !relayBlocked
        // The negative cache is looked up by (connection, model, protocol family, key), and its revision uses the same verdict as the write side: official takes this verdict; Relay takes the one with connection evidence,
        // [relayInputVerdict], the same one used when [relayInputNegativeCacheTarget] writes (same as Web).
        val cacheVerdict = verdict
        val v2Hit = wireFamily != null && negativeCache.isHit(
            connectionId = provider.id,
            modelId = model.id,
            wireFamily = wireFamily,
            capabilityKey = key,
            verdict = cacheVerdict?.let { InputNegativeCache.Verdict(it.state, it.reasonCode, it.wireFamily, it.sourceRefs) },
            now = now.epochSecond,
        )
        val negativeCacheHit = v2Hit || (key == CapabilityEvidenceFacade.VISION_INPUT && relayImageRejected)
        CapabilityEvidenceFacade.projectInputCapability(
            key = key,
            verdict = verdict?.let { CapabilityEvidenceFacade.InputCapabilityVerdict(it.state, it.reasonCode, it.wireFamily) },
            endImplements = endImplements,
            override = when (overrides[key]) {
                CapabilityOverrideOp.Add -> InputCapabilityOverride.ADD
                CapabilityOverrideOp.Remove -> InputCapabilityOverride.REMOVE
                null -> null
            },
            negativeCacheHit = negativeCacheHit,
            connection = if (relay) InputCapabilityConnection.RELAY else InputCapabilityConnection.OFFICIAL,
        )
    }
}

/**
 * Write target of the official connection's negative cache v2: the verdict used for the key and revision is the same one the official branch of [resolveInputCapabilityProjections] uses when it looks up the cache
 * (same metadata entry, same way of getting the transport, same protocol family table), so an entry just written hits on the next projection.
 * [transport] is the canonical transport name, used by the signature table to choose the protocol.
 */
internal data class InputNegativeCacheTarget(
    val connectionId: String,
    val modelId: String,
    val wireFamily: String,
    val capabilityKey: String,
    val verdict: InputNegativeCache.Verdict?,
    val transport: String?,
)

/** Returns null for a non-official form, or when the protocol family of the key is not recognized (not implemented by this client). */
internal fun officialInputNegativeCacheTarget(
    provider: Provider,
    model: AIModel,
    key: String,
    finalTransport: String? = null,
    metadataClient: MetadataClient = MetadataClient.instance,
): InputNegativeCacheTarget? {
    if (ProviderForm.of(provider) != ProviderForm.Official) return null
    val metadata = metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)?.metadata
    val transport = officialTransport(provider, finalTransport, metadata?.transport)
    val verdict = officialVerdict(metadata?.capabilityControls, key)
    val wireFamily = verdict?.wireFamily ?: WIRE_FAMILY_BY_TRANSPORT.getValue(key)[transport] ?: return null
    return InputNegativeCacheTarget(
        connectionId = provider.id,
        modelId = model.id,
        wireFamily = wireFamily,
        capabilityKey = key,
        verdict = verdict?.let { InputNegativeCache.Verdict(it.state, it.reasonCode, it.wireFamily, it.sourceRefs) },
        transport = transport,
    )
}

/**
 * Write target of the Relay negative cache v2 (same convention as the Relay branch of the Web `inputNegativeCacheTarget`): the verdict used for the key and revision is the same one
 * the Relay branch of [resolveInputCapabilityProjections] uses when it looks up the cache ([relayInputVerdict]: vision reads connection evidence, the protocol family follows this time's protocol).
 * The connection in the key = [Provider.id], the model = [AIModel.id]; [transport] is the protocol value in the v1 key ([RelayTransport.value]);
 * [relayIdentity] is the same connection identity as the projection ([relayInputIdentity]). Returns null when the protocol is not recognized or the protocol has no protocol family for the key.
 */
internal fun relayInputNegativeCacheTarget(
    provider: Provider,
    model: AIModel,
    transport: String,
    key: String,
    relayIdentity: CapabilityEvidenceFacade.QueryIdentity? = null,
    metadataClient: MetadataClient = MetadataClient.instance,
): InputNegativeCacheTarget? {
    val relayTransport = RelayTransport.entries.firstOrNull { it.value == transport } ?: return null
    val normalized = relayTransport(relayTransport)
    val verdict = relayInputVerdict(
        provider, model, key, WIRE_FAMILY_BY_TRANSPORT.getValue(key)[normalized], relayIdentity, metadataClient,
    )
    val wireFamily = verdict.wireFamily ?: return null
    return InputNegativeCacheTarget(
        connectionId = provider.id,
        modelId = model.id,
        wireFamily = wireFamily,
        capabilityKey = key,
        verdict = InputNegativeCache.Verdict(verdict.state, verdict.reasonCode, verdict.wireFamily, verdict.sourceRefs),
        transport = normalized,
    )
}

private val INPUT_KEYS = listOf(
    CapabilityEvidenceFacade.VISION_INPUT,
    CapabilityEvidenceFacade.FILE_INPUT,
    CapabilityEvidenceFacade.VIDEO_INPUT,
)

/** The protocol family each input key uses on a canonical transport; an unrecognized transport, or a transport with no matching family, counts as not implemented by this client. */
private val WIRE_FAMILY_BY_TRANSPORT: Map<String, Map<String, String>> = mapOf(
    CapabilityEvidenceFacade.VISION_INPUT to mapOf(
        "openai_chat" to "openai_chat.image_url",
        "openai_responses" to "openai_responses.input_image",
        "anthropic_messages" to "anthropic.image",
        "gemini_generate_content" to "gemini.inline_data",
    ),
    CapabilityEvidenceFacade.FILE_INPUT to mapOf(
        "openai_chat" to "openai_chat.file",
        "openai_responses" to "openai_responses.input_file",
        "anthropic_messages" to "anthropic.document",
        "gemini_generate_content" to "gemini.inline_data",
    ),
    CapabilityEvidenceFacade.VIDEO_INPUT to mapOf(
        "openai_chat" to "openai_chat.video_url",
        "gemini_generate_content" to "gemini.inline_data",
    ),
)

/** Transports that can only send plain text (not implemented at the transport level). */
private val TEXT_ONLY_TRANSPORTS = setOf("llamacpp_native", "gemini_interactions", "dashscope_native")

/** The verdict fields that take part in the projection and the negative-cache revision. */
private data class Verdict(
    val state: String,
    val reasonCode: String? = null,
    val wireFamily: String? = null,
    val sourceRefs: List<String>? = null,
)

/** Collapses the various spellings of a metadata / dispatch protocol into one canonical name. */
private fun normalizedTransport(raw: String?): String? = when (raw?.trim()?.lowercase()) {
    null, "" -> null
    "openai", "openai_compatible", "openai_chat", "openai_chat_completions" -> "openai_chat"
    "openai_responses" -> "openai_responses"
    "anthropic", "anthropic_messages" -> "anthropic_messages"
    "gemini", "gemini_generate", "gemini_generate_content" -> "gemini_generate_content"
    else -> raw.trim().lowercase()
}

/**
 * The canonical transport name of the official connection this time, shared by the projection and the negative-cache write target: an explicit dispatch value first, then the metadata entry,
 * and when both are missing (a model outside the catalog) [officialDispatchTransport].
 */
private fun officialTransport(
    provider: Provider,
    finalTransport: String?,
    metadataTransport: String?,
): String? = normalizedTransport(finalTransport ?: metadataTransport ?: officialDispatchTransport(provider))

/**
 * The outbound transport this client would use for an official connection when the model cannot be found in the catalog (outside the catalog, or the catalog has not arrived / failed to load) (same convention as the official dispatch of [AttachmentTransportResolver],
 * with a default catalog entry and default request options): OpenAI's official endpoint Responses, a custom endpoint Chat Completions; Anthropic Messages;
 * Gemini generateContent (Interactions is chosen only when the catalog says so); other OpenAI-compatible vendors Chat Completions.
 */
private fun officialDispatchTransport(provider: Provider): String? {
    // A catalog that is not ready only means the catalog has not spoken: take the transport from this client's dispatch, and whether it is implemented still depends only on that transport's protocol family.
    return when (provider.kind) {
        ProviderKind.OpenAI -> AttachmentTransportResolver.openAIOfficialTransport(
            usesOfficialApi = OpenAIService.usesOfficialOpenAIApi(OfficialEndpointSource.effectiveBaseUrlText(provider)),
            catalogTransport = null,
        )
        ProviderKind.Anthropic -> TransportKind.AnthropicMessages
        ProviderKind.Gemini -> TransportKind.GeminiGenerate
        else -> AttachmentTransportResolver.openAICompatibleTransport(subscriptionTransport = null, catalogTransport = null)
    }.wireValue
}

/** Relay by first-send protocol; Auto follows the envelope and uses Chat Completions. */
private fun relayTransport(transport: RelayTransport): String = when (transport) {
    RelayTransport.Auto, RelayTransport.OpenAIChatCompletions -> "openai_chat"
    RelayTransport.OpenAIResponses -> "openai_responses"
    RelayTransport.AnthropicMessages -> "anthropic_messages"
    RelayTransport.GeminiGenerateContent -> "gemini_generate_content"
    RelayTransport.LlamaCppNative -> "llamacpp_native"
}

/** Official verdict: capabilityControls[key] is taken as the verdict as is; null when the key is missing or the shape is wrong. */
private fun officialVerdict(controls: JsonObject?, key: String): Verdict? {
    val control = controls?.get(key) as? JsonObject ?: return null
    val state = control.string("state") ?: return null
    return Verdict(
        state = state,
        reasonCode = control.string("reasonCode"),
        wireFamily = control.string("wireFamily"),
        sourceRefs = (control["sourceRefs"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content },
    )
}

/**
 * The server verdict state of this Relay input key right now (used as the baseVerdict when writing a delta override), the same one as the projection: vision reads connection evidence
 * ([relayIdentity] takes [relayInputIdentity]), files / video are always unknown.
 */
internal fun relayInputServerVerdict(
    provider: Provider,
    model: AIModel,
    key: String,
    relayIdentity: CapabilityEvidenceFacade.QueryIdentity? = null,
    metadataClient: MetadataClient = MetadataClient.instance,
): String = relayInputVerdict(provider, model, key, null, relayIdentity, metadataClient).state

/**
 * The facade support level of Relay vision: supported / unsupported as is, an unverified declaration (catalog or model declaration, user override) is accepted,
 * anything else null. The "vision not confirmed" decision reads it ([relayIdentity] takes [relayInputIdentity]).
 */
internal fun relayVisionInputSupport(
    provider: Provider,
    model: AIModel,
    relayIdentity: CapabilityEvidenceFacade.QueryIdentity?,
    metadataClient: MetadataClient = MetadataClient.instance,
): String? {
    val resolution = CapabilityEvidenceProductionAdapter.capabilityProjection(
        provider = provider,
        model = model,
        identity = relayIdentity,
        keys = setOf(CapabilityEvidenceFacade.VISION_INPUT),
        metadataClient = metadataClient,
    ).decision(CapabilityEvidenceFacade.VISION_INPUT)?.resolution ?: return null
    return CapabilityEvidenceProductionAdapter.inputSupportLevel(resolution)
}

/**
 * The connection identity used by the Relay input projection (same convention as ChatModelCapabilityResolver): taken by the declared protocol; when the protocol follows auto, by the first-send protocol
 * ([RelayFirstSendTransport.resolve], read the same way as the chat first send). Null when no local identity is available.
 */
internal fun relayInputIdentity(
    provider: Provider,
    model: AIModel,
    localIdentity: CapabilityEvidenceIdentity?,
): CapabilityEvidenceFacade.QueryIdentity? {
    localIdentity ?: return null
    return CapabilityEvidenceProductionAdapter.uiDispatchIdentity(provider, model, localIdentity)
        ?: CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider,
            model.copy(relayTransport = RelayFirstSendTransport.resolve(provider, model)),
            localIdentity,
        )
}

/** The verdict of a Relay input key: vision reads connection evidence ([relayVisionVerdict]), other keys have no evidence and are unknown; shared by the projection, negative cache reads / writes and baseVerdict. */
private fun relayInputVerdict(
    provider: Provider,
    model: AIModel,
    key: String,
    lineFamily: String?,
    relayIdentity: CapabilityEvidenceFacade.QueryIdentity?,
    metadataClient: MetadataClient,
): Verdict = if (key == CapabilityEvidenceFacade.VISION_INPUT) {
    relayVisionVerdict(relayVisionSupport(provider, model, relayIdentity, metadataClient), lineFamily)
} else {
    relayVerdict(key, lineFamily)
}

/**
 * Connection evidence for Relay vision (tested probe, engine declaration): supported / unsupported / other; without a connection identity there is no evidence (the projection blocks it separately as not implemented by this client).
 */
private fun relayVisionSupport(
    provider: Provider,
    model: AIModel,
    identity: CapabilityEvidenceFacade.QueryIdentity?,
    metadataClient: MetadataClient,
): String? {
    identity ?: return null
    return CapabilityEvidenceProductionAdapter.capabilityProjection(
        provider = provider,
        model = model,
        identity = identity,
        keys = setOf(CapabilityEvidenceFacade.VISION_INPUT),
        metadataClient = metadataClient,
    ).decision(CapabilityEvidenceFacade.VISION_INPUT)?.resolution?.support
}

/** Relay vision verdict (same as the Web `relayVisionVerdict`): supported -> auto_available, unsupported -> unavailable / model_capability_absent, anything else unknown. */
private fun relayVisionVerdict(support: String?, lineFamily: String?): Verdict = when (support) {
    "supported" -> Verdict(state = CapabilityControlResolution.STATE_AUTO_AVAILABLE, wireFamily = lineFamily)
    "unsupported" -> Verdict(state = "unavailable", reasonCode = "model_capability_absent", wireFamily = lineFamily)
    else -> relayVerdict(CapabilityEvidenceFacade.VISION_INPUT, lineFamily)
}

/** The verdict unknown for a Relay with no connection evidence (same shape as Web: vision has no reasonCode, files / video are catalog_silent); the protocol family follows the transport. */
private fun relayVerdict(key: String, lineFamily: String?): Verdict = Verdict(
    state = "unknown",
    reasonCode = if (key == CapabilityEvidenceFacade.VISION_INPUT) null else "catalog_silent",
    wireFamily = lineFamily,
)

/**
 * Subscription (Codex / Grok subscriptions): the verdict comes from [SubscriptionTruthAdapter.inputVerdict] (first-hand declaration > modelFacts > unknown),
 * the transport is the subscription's outbound protocol, and the entry is closed when that transport has no protocol family for the key or the family is not implemented by this client; no overrides, no negative cache.
 */
private fun subscriptionProjection(
    provider: Provider,
    model: AIModel,
    key: String,
    finalTransport: String?,
    metadataClient: MetadataClient,
): InputCapabilityProjection {
    val transport = normalizedTransport(finalTransport ?: CapabilityControlResolution.subscriptionFinalTransport(provider, model))
    val wireFamily = WIRE_FAMILY_BY_TRANSPORT.getValue(key)[transport]
    return CapabilityEvidenceFacade.projectInputCapability(
        key = key,
        verdict = SubscriptionTruthAdapter.inputVerdict(provider, model, key, wireFamily, metadataClient),
        endImplements = CapabilityEvidenceFacade.endImplementsWireFamily(wireFamily) && transport !in TEXT_ONLY_TRANSPORTS,
        override = null,
        negativeCacheHit = false,
        connection = InputCapabilityConnection.OFFICIAL,
    )
}

private inline fun mapKeys(project: (String) -> InputCapabilityProjection) = InputCapabilityProjections(
    vision = project(CapabilityEvidenceFacade.VISION_INPUT),
    file = project(CapabilityEvidenceFacade.FILE_INPUT),
    video = project(CapabilityEvidenceFacade.VIDEO_INPUT),
)

private fun JsonObject.string(name: String): String? =
    (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
