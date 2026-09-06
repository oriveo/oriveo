package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayImageMode
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayWebSearchToolName
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.allowsTemperature
import ai.oriveo.community.core.provider.escapeJsonString

/** The connection effort is an explicit request intent when set; otherwise use chat intent. */
internal fun effectiveRelayReasoningMode(
    requestOptions: ChatRequestOptions,
    chatMode: ReasoningMode,
): ReasoningMode = when (requestOptions.relayRequested?.reasoningEffort) {
    RelayReasoningEffort.Low -> ReasoningMode.Fast
    RelayReasoningEffort.Medium -> ReasoningMode.Balanced
    RelayReasoningEffort.High -> ReasoningMode.Deep
    RelayReasoningEffort.XHigh -> ReasoningMode.Max
    null, RelayReasoningEffort.Automatic -> chatMode
}

internal fun buildResponsesBody(
    modelID: String,
    messages: List<ChatMessage>,
    stream: Boolean,
    // Accepted for signature parity with the other transports; the Responses body always offers the
    // image tool (see the note below), so the flag never changes what is sent.
    @Suppress("UNUSED_PARAMETER") supportsImageGen: Boolean,
    reasoningMode: ReasoningMode,
    webSearchEnabled: Boolean,
    requestOptions: ChatRequestOptions,
    reasoningEffortOverride: String? = null,
    removeTools: Boolean = false,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val effectiveReasoning = effectiveRelayReasoningMode(requestOptions, reasoningMode)
    val resolved = MetadataClient.resolveCatalogModelAcrossProviders(modelID)
    // Relay upstreams normally speak the OpenAI protocol, so the router model is resolved against
    // the OpenAI side of the catalog.
    val activeModel = MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.OpenAI)
    val sections = mutableListOf<String>()
    sections += """"model":"$modelID""""
    sections += """"input":[${MessageBuilder.buildOpenAIResponsesInput(messagesForProjection(messages, capabilityProjection), activeModel)}]"""
    if (stream) sections += """"stream":true"""
    // The Responses transport always advertises the image_generation tool and lets the model decide
    // whether to call it; it is deliberately not gated on a capability toggle or on relayImage being
    // enabled. web_search and image_generation must be able to coexist in the same tools array.
    // Which web-search tool name to emit:
    //  - null (the default) means "web_search", the name OpenAI documents and the one most relays
    //    in the wild actually accept
    //  - WebSearchPreview means "web_search_preview", kept for older relays that only know that name
    //  - Disabled means emit no web-search tool at all, even when webSearchEnabled is true
    // removeTools=true is the retry-without-tools fallback, and it clears the whole tools array
    // rather than just image_generation: a relay that cannot even accept image_generation is
    // unlikely to implement the Responses tool protocol properly, so leaving web_search in place
    // would most likely fail a second time and muddy the attribution of the error.
    if (!removeTools) {
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
        if (webSearchEnabled && permits(capabilityProjection, "web_search")) {
            val webSearchToolName = requestOptions.relayRequested?.webSearchToolName
                ?: relayWebSearchToolNameFromRuntime(
                    RelayRuntimeSupport.webSearchToolName(RelayTransport.OpenAIResponses),
                )
                ?: RelayWebSearchToolName.WebSearch
            if (webSearchToolName != RelayWebSearchToolName.Disabled) {
                val typeName = when (webSearchToolName) {
                    RelayWebSearchToolName.WebSearch -> "web_search"
                    RelayWebSearchToolName.WebSearchPreview -> "web_search_preview"
                    RelayWebSearchToolName.Disabled -> ""
                }
                tools += """{"type":"$typeName"}"""
            }
        }
        if (tools.isNotEmpty()) {
            sections += """"tools":[${tools.joinToString(",")}]"""
        }
    }
    // Codex-style relays speak the OpenAI Responses protocol, where the reasoning summary field is
    // mandatory and has to be sent even in automatic mode. Omit it and the upstream never emits
    // response.reasoning_summary_text.delta, so the thinking trace never reaches the UI.
    val responsesEffort = if (permitsReasoning(capabilityProjection, effectiveReasoning)) {
        reasoningEffortOverride ?: resolveResponsesReasoningEffort(requestOptions, reasoningMode)
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
    if (permitsGeneration(capabilityProjection, "max_output_tokens", "max_tokens")) {
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
    )
}

internal fun buildOpenAIChatBody(
    modelID: String,
    messages: List<ChatMessage>,
    stream: Boolean,
    reasoningMode: ReasoningMode,
    requestOptions: ChatRequestOptions,
    reasoningEffortOverride: String? = null,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val effectiveReasoning = effectiveRelayReasoningMode(requestOptions, reasoningMode)
    val resolved = MetadataClient.resolveCatalogModelAcrossProviders(modelID)
    val sections = mutableListOf<String>()
    sections += """"model":"$modelID""""
    sections += """"stream":$stream"""
    sections += """"messages":[${MessageBuilder.buildOpenAIMessages(messagesForProjection(messages, capabilityProjection), ProviderKind.Relay, options.systemPrompt)}]"""
    (if (permitsReasoning(capabilityProjection, effectiveReasoning)) {
        reasoningEffortOverride ?: resolveChatReasoningEffort(requestOptions, reasoningMode)
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
    if (permitsGeneration(capabilityProjection, "max_tokens", "max_output_tokens")) {
        MessageBuilder.maxTokensJson(options.maxTokens)?.let { sections += it }
    }
    if (stream) {
        sections += """"stream_options":{"include_usage":true}"""
    }
    return GenerationParameterResolver.apply(
        "{${sections.joinToString(",")}}",
        requestOptions,
        resolved,
        capabilityProjection,
    )
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
    )
}

internal fun buildLlamaCppPrompt(messages: List<ChatMessage>, requestOptions: ChatRequestOptions): String =
    buildList {
        requestOptions.systemPrompt.trim().takeIf { it.isNotEmpty() }?.let { add("system: $it") }
        messages.forEach { message ->
            message.text.trim().takeIf { it.isNotEmpty() }?.let { add("${message.role.name.lowercase()}: $it") }
        }
        add("assistant:")
    }.joinToString("\\n")

internal fun buildAnthropicBody(
    modelID: String,
    messages: List<ChatMessage>,
    stream: Boolean,
    reasoningMode: ReasoningMode,
    requestOptions: ChatRequestOptions,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val effectiveReasoning = effectiveRelayReasoningMode(requestOptions, reasoningMode)
    val resolved = MetadataClient.resolveCatalogModelAcrossProviders(modelID)
    val extras = mutableListOf<String>()
    if (permitsReasoning(capabilityProjection, effectiveReasoning)) {
        relayAnthropicThinkingJson(effectiveReasoning, modelID)?.let { extras += it }
    }
    if (resolved.allowsTemperature() && permitsGeneration(capabilityProjection, "temperature")) {
        MessageBuilder.temperatureJson(options.temperature)?.let { extras += it }
    }
    MessageBuilder.anthropicSystemJson(options.systemPrompt)?.let { extras += it }
    val extrasJson = if (extras.isNotEmpty()) "," + extras.joinToString(",") else ""
    val maxTokens = if (permitsGeneration(capabilityProjection, "max_tokens", "max_output_tokens")) {
        MessageBuilder.maxTokensJson(options.maxTokens, key = "max_tokens") ?: """"max_tokens":8192"""
    } else {
        """"max_tokens":8192"""
    }
    // Resolving the router model on the Anthropic side is what turns on cache_control and native
    // PDF handling for this request.
    val activeModel = MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.Anthropic)
    return GenerationParameterResolver.apply(
        """{"model":"$modelID",$maxTokens,"stream":$stream,"messages":[${MessageBuilder.buildAnthropicMessages(messagesForProjection(messages, capabilityProjection), activeModel)}]$extrasJson}""",
        requestOptions,
        resolved,
        capabilityProjection,
    )
}

internal fun buildGeminiBody(
    messages: List<ChatMessage>,
    modelID: String,
    supportsImageGen: Boolean,
    reasoningMode: ReasoningMode,
    webSearchEnabled: Boolean,
    requestOptions: ChatRequestOptions,
    capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
): String {
    val options = MessageBuilder.normalizeRequestOptions(requestOptions)
    val effectiveReasoning = effectiveRelayReasoningMode(requestOptions, reasoningMode)
    val resolved = MetadataClient.resolveCatalogModelAcrossProviders(modelID)
    // Resolving the router model on the Gemini side is what makes every PDF take the native path
    // when the catalog entry sets pdfNativeDefault.
    val activeModel = MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.Gemini)
    val sections = mutableListOf<String>()
    sections += """"contents":[${MessageBuilder.buildGeminiContents(messagesForProjection(messages, capabilityProjection), activeModel)}]"""
    MessageBuilder.geminiSystemInstructionJson(options.systemPrompt)?.let { sections += it }

    val generationConfig = mutableListOf<String>()
    if (supportsImageGen) generationConfig += """"responseModalities":["TEXT","IMAGE"]"""
    if (permitsReasoning(capabilityProjection, effectiveReasoning)) {
        relayGeminiThinkingJson(effectiveReasoning, modelID)?.let { generationConfig += it }
    }
    if (resolved.allowsTemperature() && permitsGeneration(capabilityProjection, "temperature")) {
        MessageBuilder.temperatureJson(options.temperature)?.let { generationConfig += it }
    }
    if (permitsGeneration(capabilityProjection, "max_output_tokens", "max_tokens")) {
        MessageBuilder.maxTokensJson(options.maxTokens, key = "maxOutputTokens")?.let { generationConfig += it }
    }
    if (generationConfig.isNotEmpty()) {
        sections += """"generationConfig":{${generationConfig.joinToString(",")}}"""
    }
    if (webSearchEnabled && permits(capabilityProjection, "web_search")) {
        sections += """"tools":[{"googleSearch":{}}]"""
    }
    return GenerationParameterResolver.apply(
        "{${sections.joinToString(",")}}",
        requestOptions,
        resolved,
        capabilityProjection,
    )
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

/** Final request boundary: only image input is governed by vision_input; files/text stay intact. */
private fun messagesForProjection(
    messages: List<ChatMessage>,
    projection: CapabilityEvidenceProductionAdapter.Projection?,
): List<ChatMessage> = if (permits(projection, "vision_input")) {
    messages
} else {
    messages.map { message ->
        message.copy(attachments = message.attachments?.filter { it.kind != AttachmentKind.Image })
    }
}

internal fun relayWebSearchToolNameFromRuntime(raw: String?): RelayWebSearchToolName? {
    return when (raw) {
        "web_search" -> RelayWebSearchToolName.WebSearch
        "web_search_preview" -> RelayWebSearchToolName.WebSearchPreview
        "disabled" -> RelayWebSearchToolName.Disabled
        else -> null
    }
}

internal fun resolveResponsesReasoningEffort(
    requestOptions: ChatRequestOptions,
    reasoningMode: ReasoningMode,
): String? {
    requestOptions.relayRequested?.reasoningEffort
        ?.takeIf { it != RelayReasoningEffort.Automatic }
        ?.let { return it.value }
    return reasoningMode.relayOpenAIEffort()
}

internal fun resolveChatReasoningEffort(
    requestOptions: ChatRequestOptions,
    reasoningMode: ReasoningMode,
): String? {
    requestOptions.relayRequested?.reasoningEffort
        ?.takeIf { it != RelayReasoningEffort.Automatic }
        ?.let { return it.value }
    return reasoningMode.relayOpenAIEffort()
}
