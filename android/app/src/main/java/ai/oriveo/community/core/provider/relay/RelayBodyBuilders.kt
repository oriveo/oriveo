package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayImageMode
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.MaxOutputTokensPolicy
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.messagesForCapabilityProjection
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.allowsTemperature
import ai.oriveo.community.core.provider.applyClientTools
import ai.oriveo.community.core.provider.escapeJsonString
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolWireProtocol
import ai.oriveo.community.core.tools.ToolWireProtocolAdapter

/**
 * Optional inputs of the chat builders, passed only by "test capability". With every field at its default the builder
 * produces output byte-identical to before.
 * [maxOutputTokens]: goes through the builder's own output-limit channel, unaffected by option normalization and the outbound gate;
 * [functionTool]: `tools` holds only this one function tool (shaped for this platform's chat tool leg), and built-in tools are not merged in;
 * [keepImageAttachments]: keep image attachments even when the capability-evidence gate does not let image input through.
 */
internal data class RelayChatBuildExtras(
    val maxOutputTokens: Int? = null,
    val functionTool: ToolLoopToolDefinition? = null,
    val keepImageAttachments: Boolean = false,
) {
    companion object {
        val None = RelayChatBuildExtras()
    }
}

/** The protocol shape of a function tool is taken from the chat tool leg ([ToolWireProtocolAdapter]); this is the JSON of the whole `tools` array. */
private fun functionToolsJson(protocol: ToolWireProtocol, tool: ToolLoopToolDefinition): String =
    ToolWireProtocolAdapter.toolsJson(protocol, listOf(tool)).toString()

internal fun buildResponsesBody(
    modelID: String,
    messages: List<ChatMessage>,
    stream: Boolean,
    // Accepted for signature parity with the other transports; the Responses body always offers the
    // image tool (see the note below), so the flag never changes what is sent.
    @Suppress("UNUSED_PARAMETER") supportsImageGen: Boolean,
    reasoningMode: ReasoningMode,
    @Suppress("UNUSED_PARAMETER") webSearchEnabled: Boolean,
    requestOptions: ChatRequestOptions,
    reasoningEffortOverride: String? = null,
    removeTools: Boolean = false,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    extras: RelayChatBuildExtras = RelayChatBuildExtras.None,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val effectiveReasoning = reasoningMode
    val resolved = relayRequestCatalog(modelID, RelayTransport.OpenAIResponses, requestOptions)
    // Relay upstreams normally speak the OpenAI protocol, so the router model is resolved against
    // the OpenAI side of the catalog.
    val activeModel = relayRouterModel(modelID, ProviderKind.OpenAI, requestOptions.activeModel)
    val sections = mutableListOf<String>()
    sections += """"model":"$modelID""""
    sections += """"input":[${MessageBuilder.buildOpenAIResponsesInput(messagesForProjection(messages, capabilityProjection, extras), activeModel, relayAttachmentTransport(AttachmentTransportProfile.RelayOpenAIResponses, requestOptions))}]"""
    if (stream) sections += """"stream":true"""
    // The Responses transport always advertises the image_generation tool and lets the model decide
    // whether to call it; it is deliberately not gated on a capability toggle or on relayImage being
    // enabled.
    // Web search no longer adds a tool from the chat preference: the connection-level web fragment is merged after the builder produces its output.
    //
    // removeTools=true is the retry-without-tools fallback, and it clears the whole tools array
    // rather than just image_generation: a relay that cannot even accept image_generation is
    // unlikely to implement the Responses tool protocol properly.
    if (extras.functionTool != null) {
        sections += """"tools":${functionToolsJson(ToolWireProtocol.OpenAIResponses, extras.functionTool)}"""
    } else if (!removeTools) {
        val tools = mutableListOf<String>()
        val toolModel = requestOptions.relayImage
            ?.takeIf { it.mode == RelayImageMode.ToolModel }
            ?.toolModelID
            ?.trim()
        // image_generation is an image-generation transport feature, not H2 tool_call.
        // Keep it independent from governed function/library tools.
        tools += if (!toolModel.isNullOrEmpty()) {
            """{"type":"image_generation","model":"$toolModel"}"""
        } else {
            """{"type":"image_generation"}"""
        }
        if (tools.isNotEmpty()) {
            sections += """"tools":[${tools.joinToString(",")}]"""
        }
    }
    // Codex-style relays speak the OpenAI Responses protocol, where the reasoning summary field is
    // mandatory and has to be sent even in automatic mode. Omit it and the upstream never emits
    // response.reasoning_summary_text.delta, so the thinking trace never reaches the UI.
    val responsesEffort = if (permitsReasoning(capabilityProjection, effectiveReasoning)) {
        reasoningEffortOverride ?: reasoningMode.relayOpenAIEffort()
    } else {
        null
    }
    sections += if (responsesEffort != null) {
        """"reasoning":{"effort":"$responsesEffort","summary":"auto"}"""
    } else {
        """"reasoning":{"summary":"auto"}"""
    }
    requestOptions.relayRequested?.serviceTier
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { sections += """"service_tier":"$it"""" }
    if (requestOptions.relayRequested?.disableResponseStorage == true) {
        sections += """"store":false"""
    }
    if (resolved.allowsTemperature() && permitsGeneration(capabilityProjection, "temperature")) {
        MessageBuilder.temperatureJson(options.temperature)?.let { sections += it }
    }
    if (extras.maxOutputTokens != null) {
        sections += MessageBuilder.maxTokensJson(extras.maxOutputTokens, key = "max_output_tokens")!!
    } else if (permitsGeneration(capabilityProjection, "max_output_tokens", "max_tokens")) {
        MessageBuilder.maxTokensJson(options.maxTokens, key = "max_output_tokens")?.let { sections += it }
    }
    if (options.systemPrompt.isNotBlank()) {
        sections += """"instructions":${escapeJsonString(options.systemPrompt)}"""
    }
    return GenerationParameterResolver.apply(
        "{${sections.joinToString(",")}}",
        requestOptions,
        resolved,
        capabilityProjection,
    ).let { RelayWebFragments.applyTo(it, RelayTransport.OpenAIResponses, requestOptions) }
        .let { applyClientTools(it, ToolWireProtocol.OpenAIResponses, requestOptions) }
        .let { AdditionalRequestBody.apply(it, requestOptions.additionalRequestBody) }
        .let { body ->
            // Last step: a same-named key already written by the user's custom parameters is not overwritten.
            if (!RelayHeaderBuilder.injectsCodexIdentity(requestOptions, RelayTransport.OpenAIResponses)) {
                body
            } else {
                RelayRuntimeSupport.withPromptCacheKey(
                    body,
                    RelayRuntimeSupport.promptCacheKey(
                        model = modelID,
                        instructions = options.systemPrompt.takeIf { it.isNotBlank() }.orEmpty(),
                        firstUserText = messages.firstOrNull { it.role == ChatRole.User }?.text.orEmpty(),
                    ),
                )
            }
        }
}

internal fun buildOpenAIChatBody(
    modelID: String,
    messages: List<ChatMessage>,
    stream: Boolean,
    reasoningMode: ReasoningMode,
    requestOptions: ChatRequestOptions,
    reasoningEffortOverride: String? = null,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    extras: RelayChatBuildExtras = RelayChatBuildExtras.None,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val effectiveReasoning = reasoningMode
    val resolved = relayRequestCatalog(modelID, RelayTransport.OpenAIChatCompletions, requestOptions)
    val sections = mutableListOf<String>()
    sections += """"model":"$modelID""""
    sections += """"stream":$stream"""
    sections += """"messages":[${MessageBuilder.buildOpenAIMessages(messagesForProjection(messages, capabilityProjection, extras), ProviderKind.Relay, options.systemPrompt, requestOptions.activeModel)}]"""
    (if (permitsReasoning(capabilityProjection, effectiveReasoning)) {
        reasoningEffortOverride ?: reasoningMode.relayOpenAIEffort()
    } else null)?.let { effort ->
        sections += """"reasoning_effort":"$effort""""
    }
    requestOptions.relayRequested?.serviceTier
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { sections += """"service_tier":"$it"""" }
    if (resolved.allowsTemperature() && permitsGeneration(capabilityProjection, "temperature")) {
        MessageBuilder.temperatureJson(options.temperature)?.let { sections += it }
    }
    if (extras.maxOutputTokens != null) {
        sections += MessageBuilder.maxTokensJson(extras.maxOutputTokens)!!
    } else if (permitsGeneration(capabilityProjection, "max_tokens", "max_output_tokens")) {
        MessageBuilder.maxTokensJson(options.maxTokens)?.let { sections += it }
    }
    if (stream) {
        sections += """"stream_options":{"include_usage":true}"""
    }
    extras.functionTool?.let { tool ->
        sections += """"tools":${functionToolsJson(ToolWireProtocol.OpenAIChat, tool)}"""
    }
    return GenerationParameterResolver.apply(
        "{${sections.joinToString(",")}}",
        requestOptions,
        resolved,
        capabilityProjection,
    ).let { RelayWebFragments.applyTo(it, RelayTransport.OpenAIChatCompletions, requestOptions) }
        .let { applyClientTools(it, ToolWireProtocol.OpenAIChat, requestOptions) }
        .let { AdditionalRequestBody.apply(it, requestOptions.additionalRequestBody) }
}

/** llama.cpp native `/completion` uses a plain prompt and `n_predict`, not OpenAI messages/model. */
internal fun buildLlamaCppNativeBody(
    messages: List<ChatMessage>,
    stream: Boolean,
    requestOptions: ChatRequestOptions,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
): String {
    val prompt = buildLlamaCppPrompt(messagesForProjection(messages, capabilityProjection), requestOptions)
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val sections = mutableListOf(
        "\"prompt\":${escapeJsonString(prompt)}",
        "\"stream\":$stream",
    )
    if (permitsGeneration(capabilityProjection, "n_predict", "max_tokens", "max_output_tokens")) {
        options.maxTokens?.let { sections += "\"n_predict\":$it" }
    }
    if (permitsGeneration(capabilityProjection, "temperature")) {
        options.temperature?.let { sections += "\"temperature\":$it" }
    }
    return GenerationParameterResolver.apply(
        "{${sections.joinToString(",")}}",
        requestOptions,
        MetadataClient.resolveCatalogModelAcrossProviders(""),
        capabilityProjection,
    ).let { AdditionalRequestBody.apply(it, requestOptions.additionalRequestBody) }
}

internal fun buildLlamaCppPrompt(messages: List<ChatMessage>, requestOptions: ChatRequestOptions): String {
    val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
    return buildList {
        requestOptions.systemPrompt.trim().takeIf { it.isNotEmpty() }?.let { add("system: $it") }
        messages.forEachIndexed { index, message ->
            // The prompt is plain text: an image leaves a one-line placeholder, files are injected as text, and a
            // current-turn file that does not fit blocks the send.
            val attachments = message.attachments.orEmpty()
            val imagePlaceholders = attachments
                .filter { it.kind == AttachmentKind.Image }
                .mapNotNull { AttachmentTransportProfile.LlamaCppNative.imagePlaceholderText }
            val plan = AttachmentDelivery.plan(
                baseText = (listOfNotNull(message.text.trim().takeIf { it.isNotEmpty() }) + imagePlaceholders)
                    .joinToString("\n\n"),
                attachments = attachments,
                model = requestOptions.activeModel,
                transport = AttachmentTransportProfile.LlamaCppNative,
            )
            AttachmentDelivery.requireDeliverable(plan, isCurrentTurn = index == currentTurnIndex)
            plan.text.takeIf { it.isNotEmpty() }?.let { add("${message.role.name.lowercase()}: $it") }
        }
        add("assistant:")
        // A real newline: escapeJsonString escapes the request body, so an escape sequence here would reach the
        // model as a literal backslash followed by n.
    }.joinToString("\n")
}

/**
 * Whether this request to a relay Anthropic-compatible connection sends thinking, and at which tier: shared by the builder and the advanced-settings thinking preview,
 * so the preview can never disagree with the real request body. Null means nothing is sent (automatic tier, or the outbound gate does not allow it).
 */
internal fun relayAnthropicThinkingFields(
    modelID: String,
    reasoningMode: ReasoningMode,
    requestOptions: ChatRequestOptions,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection?,
): String? {
    val effectiveReasoning = reasoningMode
    if (!permitsReasoning(capabilityProjection, effectiveReasoning)) return null
    return relayAnthropicThinkingJson(effectiveReasoning, modelID)
}

internal fun buildAnthropicBody(
    modelID: String,
    messages: List<ChatMessage>,
    stream: Boolean,
    reasoningMode: ReasoningMode,
    requestOptions: ChatRequestOptions,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    buildExtras: RelayChatBuildExtras = RelayChatBuildExtras.None,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val resolved = relayRequestCatalog(modelID, RelayTransport.AnthropicMessages, requestOptions)
    val extras = mutableListOf<String>()
    relayAnthropicThinkingFields(modelID, reasoningMode, requestOptions, capabilityProjection)?.let { extras += it }
    if (resolved.allowsTemperature() && permitsGeneration(capabilityProjection, "temperature")) {
        MessageBuilder.temperatureJson(options.temperature)?.let { extras += it }
    }
    MessageBuilder.anthropicSystemJson(options.systemPrompt)?.let { extras += it }
    buildExtras.functionTool?.let { tool ->
        extras += """"tools":${functionToolsJson(ToolWireProtocol.AnthropicMessages, tool)}"""
    }
    val extrasJson = if (extras.isNotEmpty()) "," + extras.joinToString(",") else ""
    val maxTokens = if (buildExtras.maxOutputTokens != null) {
        MessageBuilder.maxTokensJson(buildExtras.maxOutputTokens, key = "max_tokens")!!
    } else {
        // Explicit value (including the main chat path base value plan.budget.oWire) > catalog model maxOutputTokens > protocol default 8192 (when the catalog has no value).
        val explicit = if (permitsGeneration(capabilityProjection, "max_tokens", "max_output_tokens")) {
            options.maxTokens ?: options.outputTokenBudget
        } else {
            options.outputTokenBudget
        }
        """"max_tokens":${MaxOutputTokensPolicy.anthropicMessages(explicit, resolved?.maxOutputTokens)}"""
    }
    // Resolving the router model on the Anthropic side turns on native PDF handling for this request.
    // Cache breakpoints: the relay sends no top-level cache_control, only one breakpoint on the last
    // content block of the last user message.
    val activeModel = relayRouterModel(modelID, ProviderKind.Anthropic, requestOptions.activeModel)
    return GenerationParameterResolver.apply(
        """{"model":"$modelID",$maxTokens,"stream":$stream,"messages":[${MessageBuilder.buildAnthropicMessages(messagesForProjection(messages, capabilityProjection, buildExtras), activeModel, relayAttachmentTransport(AttachmentTransportProfile.RelayAnthropicMessages, requestOptions), cacheLastUserBlock = true, dynamicText = options.dynamicText)}]$extrasJson}""",
        requestOptions,
        resolved,
        capabilityProjection,
        outboundTemplate = "anthropic_messages",
    ).let { RelayWebFragments.applyTo(it, RelayTransport.AnthropicMessages, requestOptions) }
        .let { applyClientTools(it, ToolWireProtocol.AnthropicMessages, requestOptions) }
        .let { AdditionalRequestBody.apply(it, requestOptions.additionalRequestBody) }
}

internal fun buildGeminiBody(
    messages: List<ChatMessage>,
    modelID: String,
    supportsImageGen: Boolean,
    reasoningMode: ReasoningMode,
    @Suppress("UNUSED_PARAMETER") webSearchEnabled: Boolean,
    requestOptions: ChatRequestOptions,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    extras: RelayChatBuildExtras = RelayChatBuildExtras.None,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val effectiveReasoning = reasoningMode
    val resolved = relayRequestCatalog(modelID, RelayTransport.GeminiGenerateContent, requestOptions)
    // Resolving the router model on the Gemini side is what makes every PDF take the native path
    // when the catalog entry sets pdfNativeDefault.
    val activeModel = relayRouterModel(modelID, ProviderKind.Gemini, requestOptions.activeModel)
    val sections = mutableListOf<String>()
    sections += """"contents":[${MessageBuilder.buildGeminiContents(messagesForProjection(messages, capabilityProjection, extras), activeModel, relayAttachmentTransport(AttachmentTransportProfile.RelayGeminiGenerateContent, requestOptions))}]"""
    MessageBuilder.geminiSystemInstructionJson(options.systemPrompt)?.let { sections += it }

    val generationConfig = mutableListOf<String>()
    if (supportsImageGen) generationConfig += """"responseModalities":["TEXT","IMAGE"]"""
    if (permitsReasoning(capabilityProjection, effectiveReasoning)) {
        relayGeminiThinkingJson(effectiveReasoning, modelID)?.let { generationConfig += it }
    }
    if (resolved.allowsTemperature() && permitsGeneration(capabilityProjection, "temperature")) {
        MessageBuilder.temperatureJson(options.temperature)?.let { generationConfig += it }
    }
    if (extras.maxOutputTokens != null) {
        generationConfig += MessageBuilder.maxTokensJson(extras.maxOutputTokens, key = "maxOutputTokens")!!
    } else if (permitsGeneration(capabilityProjection, "max_output_tokens", "max_tokens")) {
        MessageBuilder.maxTokensJson(options.maxTokens, key = "maxOutputTokens")?.let { generationConfig += it }
    }
    if (generationConfig.isNotEmpty()) {
        sections += """"generationConfig":{${generationConfig.joinToString(",")}}"""
    }
    if (extras.functionTool != null) {
        sections += """"tools":${functionToolsJson(ToolWireProtocol.GeminiGenerate, extras.functionTool)}"""
    }
    return GenerationParameterResolver.apply(
        "{${sections.joinToString(",")}}",
        requestOptions,
        resolved,
        capabilityProjection,
    ).let { RelayWebFragments.applyTo(it, RelayTransport.GeminiGenerateContent, requestOptions) }
        .let { applyClientTools(it, ToolWireProtocol.GeminiGenerate, requestOptions) }
        .let { AdditionalRequestBody.apply(it, requestOptions.additionalRequestBody) }
}

/** A projection must exist in production Relay dispatch; an absent final scope is fail-closed. */
private fun permits(
    projection: CapabilityEvidenceProductionAdapter.Projection?,
    key: String,
): Boolean = projection?.permitsOutbound(key) == true

private fun permitsReasoning(
    projection: CapabilityEvidenceProductionAdapter.Projection?,
    mode: ReasoningMode,
): Boolean = mode != ReasoningMode.Automatic && permits(projection, "reasoning_level/${mode.rawValue}")

private fun permitsGeneration(
    projection: CapabilityEvidenceProductionAdapter.Projection?,
    vararg ids: String,
): Boolean = projection?.let { current ->
    ids.any { id -> current.permitsOutbound("generation_parameter/$id") }
} ?: false

/**
 * Final request boundary input gate: images with outbound=placeholder are replaced by route
 * placeholder lines; files keep the native-file fallback chain. The vision probe
 * ([RelayChatBuildExtras.keepImageAttachments]) is sent as-is. A missing projection fails closed on images.
 */
private fun messagesForProjection(
    messages: List<ChatMessage>,
    projection: CapabilityEvidenceProductionAdapter.Projection?,
    extras: RelayChatBuildExtras = RelayChatBuildExtras.None,
): List<ChatMessage> = when {
    extras.keepImageAttachments -> messages
    projection != null -> messagesForCapabilityProjection(messages, projection)
    else -> messages.map { message ->
        message.copy(attachments = message.attachments?.filter { it.kind != AttachmentKind.Image })
    }
}

/** The attachment transport this relay request uses: on a fallback resend, or when the connection is known not to accept file blocks, the same transport without file blocks. */
internal fun relayAttachmentTransport(
    transport: AttachmentTransportProfile,
    requestOptions: ChatRequestOptions,
): AttachmentTransportProfile = if (requestOptions.nativeFilesDisabled) transport.withoutNativeFiles() else transport

/**
 * The attachment-routing model that a relay send looks up from the official catalog. When the model's protocol is only a 1-token
 * reachability check (reachable), it does not inherit the official catalog's native-file allowlist: nativeFileMimes is emptied and
 * pdfNativeDefault = false, while everything else (attachmentExtraction, capabilities, etc.) is carried as is; observed / user /
 * follow-connection stay as they were. When that protocol's envelope does not accept native files, all three (including
 * attachmentExtraction) are emptied (see the chat attachment delivery contract). Only this one catalog family [catalogKind] is queried,
 * so a cross-family hit naturally carries no allowlist. The model-level file override is the only place that strips or merges the
 * allowlist, and it does not take effect when the envelope does not accept native files.
 */
internal fun relayRouterModel(modelID: String, catalogKind: ProviderKind, relayModel: AIModel?): AIModel? {
    val fileOverride = relayModel?.relayCapabilityOverrides?.file
    // The override acts on the model itself: when the catalog has no model of that name, file On uses the local model as the base.
    // Match by the canonicalModelId the model already inherited first (same match as pricing / capability inheritance), then by the literal id.
    val canonical = relayModel?.canonicalModelId?.trim()?.takeIf { it.isNotEmpty() }
    val official = canonical?.let { MetadataClient.resolveAIModelForRouter(it, catalogKind) }
        ?: MetadataClient.resolveAIModelForRouter(modelID, catalogKind)
        ?: relayModel?.takeIf { fileOverride == true }
        ?: return null
    if (relayEnvelopeRejectsNativeFile(catalogKind)) {
        return official.copy(nativeFileMimes = emptyList(), pdfNativeDefault = false, attachmentExtraction = null)
    }
    // File override: On = the allowlist merges in PDF and PDF defaults to native; Off = always text. It outranks the reachable narrowing.
    when (fileOverride) {
        true -> return official.copy(
            nativeFileMimes = (official.nativeFileMimes + PDF_MIME).distinct(),
            pdfNativeDefault = true,
        )
        false -> return official.copy(nativeFileMimes = emptyList(), pdfNativeDefault = false)
        null -> Unit
    }
    val reachableOnly = relayModel?.relayTransport != null &&
        relayModel.relayTransportSource == RelayTransportSource.Reachable
    return if (reachableOnly) official.copy(nativeFileMimes = emptyList(), pdfNativeDefault = false) else official
}

private const val PDF_MIME = "application/pdf"

/**
 * The official catalog entry used for request building: the same match as pricing and capability inheritance
 * ([relayCatalogMatch]: the canonicalModelId already inherited by the active model first, then the literal id,
 * preferring the transport's family), instead of a cross-family lookup by literal id only.
 */
private fun relayRequestCatalog(
    modelID: String,
    transport: RelayTransport,
    requestOptions: ChatRequestOptions,
): MetadataClient.ResolvedModelMetadata? =
    relayCatalogMatch(modelID, requestOptions.activeModel?.canonicalModelId, transport)?.metadata

/**
 * Whether a relay dispatches image generation: the model-level imageGeneration override wins, otherwise it depends on whether the model's
 * capabilities include image generation. Non-relay providers look at capabilities only. The send entry and the image-generation precheck of attachment
 * route resolution share this one place.
 */
internal fun relayDispatchesImageGeneration(provider: ai.oriveo.community.core.model.Provider, model: AIModel): Boolean {
    if (provider.kind == ProviderKind.Relay) {
        model.relayCapabilityOverrides?.imageGeneration?.let { return it }
    }
    return ai.oriveo.community.core.model.ModelCapability.ImageGen in model.capabilities
}

/** The three relay lanes that carry native file blocks map one to one onto the catalog families (see RelayTransportCoordinator.nativeFileLane). */
private fun relayEnvelopeRejectsNativeFile(catalogKind: ProviderKind): Boolean {
    val key = when (catalogKind) {
        ProviderKind.OpenAI -> RelayRuntimeSupport.TransportKey.OPENAI_RESPONSES
        ProviderKind.Anthropic -> RelayRuntimeSupport.TransportKey.ANTHROPIC_MESSAGES
        ProviderKind.Gemini -> RelayRuntimeSupport.TransportKey.GEMINI_GENERATE_CONTENT
        else -> return false
    }
    return MetadataClient.relayRuntimeConfig().transportEnvelopes[key]?.nativeFile == false
}
