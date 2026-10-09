package ai.oriveo.community.core.tools

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.network.NativeUserAgent
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.ToolCallTransportResolver
import ai.oriveo.community.core.provider.ToolUnsupportedErrorMatcher
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.SseParser
import ai.oriveo.community.core.provider.allowsTemperature
import ai.oriveo.community.core.provider.capabilityRuntimeContinuationSelection
import ai.oriveo.community.core.provider.reasoningMergeParams
import ai.oriveo.community.core.provider.sseLineReader
import ai.oriveo.community.core.provider.relay.effectiveRelayReasoningMode
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.provider.transport.ProviderTransportDefinition
import ai.oriveo.community.core.provider.transport.TransportEndpoints
import ai.oriveo.community.core.provider.transport.deepMergeJsonObject
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.request
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.URLBuilder
import io.ktor.http.appendPathSegments
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.utils.io.jvm.javaio.toInputStream
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Decides whether a connection can carry a tool loop at all, independent of model capability. */
object ToolLoopTransportAvailability {
    /**
     * Preconditions that are not capabilities: the connection is usable and its wire protocol
     * has an adapter. Whether the model accepts tools is decided by the capability projection,
     * so this must not read raw model fields and become a second, diverging verdict.
     */
    fun supportsToolTransport(
        provider: Provider,
        model: AIModel,
        resolvedTransport: String? = resolvedTransport(provider, model),
    ): Boolean {
        if (provider.status !is ProviderConnectionState.Connected) return false
        return ToolWireProtocolAdapter.supports(resolvedTransport)
    }

    fun resolvedTransport(provider: Provider, model: AIModel): String? = when (provider.kind) {
        ProviderKind.Relay -> when (provider.relayRequested?.transport ?: RelayTransport.Auto) {
            RelayTransport.Auto -> null
            RelayTransport.OpenAIChatCompletions -> ToolWireProtocol.OpenAIChat.wireValue
            RelayTransport.OpenAIResponses -> ToolWireProtocol.OpenAIResponses.wireValue
            RelayTransport.AnthropicMessages -> ToolWireProtocol.AnthropicMessages.wireValue
            RelayTransport.GeminiGenerateContent -> ToolWireProtocol.GeminiGenerate.wireValue
            RelayTransport.LlamaCppNative -> null
        }
        else -> CapabilityControlResolution.subscriptionFinalTransport(provider, model)
            ?: MetadataClient.resolveCatalogModel(model.id, provider.kind)?.transport
            ?: model.generationProfile?.transport
            // A model newly discovered from the provider may not be in the current official
            // catalog yet. Tool capability remains unknown/fail-open for this explicit feature,
            // while the wire protocol is still the concrete Provider service adapter.
            ?: ToolCallTransportResolver.catalogExternalTransport(provider)
                .takeIf { MetadataClient.isSnapshotConfirmed(provider.kind) }
    }
}

/**
 * A deterministic 4xx proved that this connection or model rejects native tools.
 *
 * The loop calls [annotate] before rethrowing so the caller knows which leg failed and whether
 * structured tool calls had already been seen.
 */
class ToolsUnsupportedError(
    val upstream: ProviderServiceError,
    var legIndex: Int = 0,
    var receivedStructuredToolCalls: Boolean = false,
) : Exception("The selected connection rejected native tools."), ToolLoopLegRejection {
    override fun annotate(legIndex: Int, receivedStructuredToolCalls: Boolean) {
        this.legIndex = legIndex
        this.receivedStructuredToolCalls = receivedStructuredToolCalls
    }
}

/**
 * Runs one model leg of a tool loop against a provider, over whichever of the four wire
 * protocols the connection speaks.
 */
class ProviderToolLegRunner(
    private val client: HttpClient,
    provider: Provider,
    private val model: AIModel,
    private val modelId: String,
    reasoningMode: ReasoningMode,
    private val json: Json,
    requestOptions: ChatRequestOptions = ChatRequestOptions(),
    relayRuntimeConfig: MetadataClient.RelayRuntimeConfig = MetadataClient.relayRuntimeConfig(),
) : ToolLoopLegRunning {
    private data class Configuration(
        val protocol: ToolWireProtocol,
        val endpoint: String,
        val apiKey: String,
        val providerKind: ProviderKind,
        val authMode: RelayAuthMode,
        val headers: List<RelayKeyValue>,
        val serviceTier: String?,
        val reasoningParams: JsonObject?,
        val relayReasoningEffort: String?,
        val temperature: Float?,
        val maxTokens: Int?,
        val generationOptions: ChatRequestOptions,
        val resolvedMetadata: MetadataClient.ResolvedModelMetadata?,
        val capabilityProjection: CapabilityEvidenceProductionAdapter.Projection?,
        val openAIReasoningParserKind: String?,
    )

    private val configuration: Configuration

    init {
        if (provider.apiKey.isBlank()) {
            throw ProviderServiceError.InvalidConfiguration("Missing API key.")
        }
        // Temperature and max_tokens follow exactly the rules of a plain chat request:
        // normalizeRequestOptions treats a value equal to the default as unset, and temperature
        // also passes the catalog's supportsTemperature gate (a relay has no catalog entry, so
        // it is allowed). Relays often require max_tokens, and parameters the user tuned for
        // chat must not silently stop applying once a tool leg runs.
        val options = MessageBuilder.normalizeRequestOptions(requestOptions)
        val requestModel = model.copy(
            generationProfile = GenerationParameterAvailability.profile(provider, model),
        )
        val resolvedMetadata = if (provider.kind == ProviderKind.Relay) {
            null
        } else {
            MetadataClient.resolveCatalogModel(modelId, provider.kind)
        }
        val protocol = resolveProtocol(
            provider,
            resolvedMetadata?.transport
                ?: CapabilityControlResolution.subscriptionFinalTransport(provider, model)
                ?: model.generationProfile?.transport
                ?: ToolCallTransportResolver.catalogExternalTransport(provider).takeIf { model.isManual },
        )
            ?: throw ProviderServiceError.InvalidConfiguration("This connection has no tool-call adapter.")
        val authMode = resolveAuthMode(provider, relayRuntimeConfig, protocol)
        if (!ToolLoopTransportAvailability.supportsToolTransport(
                provider = provider,
                model = model,
                resolvedTransport = protocol.wireValue,
            )
        ) {
            throw ProviderServiceError.InvalidConfiguration("This model or provider cannot run tool calls.")
        }
        val endpoint = resolveEndpoint(provider, authMode, relayRuntimeConfig, protocol, modelId)
        val effectiveReasoning = if (provider.kind == ProviderKind.Relay) {
            effectiveRelayReasoningMode(options, reasoningMode)
        } else {
            MetadataClient.clampReasoningMode(reasoningMode, resolvedMetadata?.profiles?.reasoning)
        }
        val projection = if (provider.kind == ProviderKind.Relay) {
            val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
                localIdentity = requestOptions.capabilityEvidenceIdentity,
                model = requestModel,
                effectiveTransport = RelayTransport.OpenAIChatCompletions,
                finalUrl = endpoint,
            )
            val generationKeys = requestModel.generationProfile?.parameters.orEmpty()
                .mapNotNull { it.id?.takeIf(String::isNotBlank) }
                .mapTo(linkedSetOf()) { "generation_parameter/$it" }
                .apply {
                    add("tool_call")
                    add("generation_parameter/temperature")
                    add("generation_parameter/max_tokens")
                    add("generation_parameter/max_output_tokens")
                    if (effectiveReasoning != ReasoningMode.Automatic) {
                        add("reasoning_level/${effectiveReasoning.rawValue}")
                    }
                }
            val explicitKeys = options.generationParameters?.values.orEmpty()
                .filterValues { it.state != ai.oriveo.community.core.model.GenerationOverrideState.Inherit }
                .keys
                .mapTo(linkedSetOf()) { "generation_parameter/$it" }
                .apply {
                    // Relay `toolCall=true` is the persisted user acceptance of this model's
                    // declaration. The tool leg itself is the corresponding explicit tools
                    // request; without this, an accepted declaration is incorrectly treated as
                    // an automatic default and every Relay tool leg fails closed.
                    if (requestModel.toolCall == true) add("tool_call")
                    if (effectiveReasoning != ReasoningMode.Automatic) {
                        add("reasoning_level/${effectiveReasoning.rawValue}")
                    }
                    if (options.temperature != null) add("generation_parameter/temperature")
                    if (options.maxTokens != null) {
                        add("generation_parameter/max_tokens")
                        add("generation_parameter/max_output_tokens")
                    }
                }
            CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
                model = requestModel,
                relayRequested = provider.relayRequested,
                identity = identity,
                keys = generationKeys,
                explicitKeys = explicitKeys,
            )
        } else {
            CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider = provider,
                model = requestModel,
                keys = buildSet {
                    add("tool_call")
                    add("generation_parameter/temperature")
                    add("generation_parameter/max_tokens")
                    add("generation_parameter/max_output_tokens")
                    if (effectiveReasoning != ReasoningMode.Automatic) {
                        add("reasoning_level/${effectiveReasoning.rawValue}")
                    }
                    requestModel.generationProfile?.parameters.orEmpty().forEach { parameter ->
                        parameter.id?.takeIf(String::isNotBlank)?.let { add("generation_parameter/$it") }
                    }
                },
                explicitKeys = options.generationParameters?.values.orEmpty()
                    .filterValues { it.state != ai.oriveo.community.core.model.GenerationOverrideState.Inherit }
                    .keys
                    .mapTo(linkedSetOf()) { "generation_parameter/$it" }
                    .apply { add("tool_call") },
                finalTransport = protocol.wireValue,
            )
        }
        if (!projection.permitsOutbound("tool_call")) {
            throw ProviderServiceError.InvalidConfiguration("This model or provider cannot run tool calls.")
        }
        configuration = Configuration(
            protocol = protocol,
            endpoint = endpoint,
            apiKey = provider.apiKey,
            providerKind = provider.kind,
            authMode = authMode,
            headers = provider.relayRequested?.headers.orEmpty(),
            serviceTier = provider.relayRequested?.serviceTier?.trim()?.takeIf { it.isNotEmpty() },
            reasoningParams = (if (provider.kind == ProviderKind.Relay) {
                // Relay's profile is the current connection-local declaration carried by the
                // active model. Official legs must never read this persisted field: they use
                // resolvedMetadata from the current publication above.
                MetadataClient.reasoningMergeParams(requestModel.reasoningProfile, effectiveReasoning)
            } else {
                reasoningMergeParams(resolvedMetadata, effectiveReasoning)
            })
                ?.takeIf {
                    effectiveReasoning != ReasoningMode.Automatic &&
                        projection.permitsOutbound("reasoning_level/${effectiveReasoning.rawValue}")
                },
            relayReasoningEffort = provider.relayRequested?.reasoningEffort
                ?.takeUnless { it == ai.oriveo.community.core.model.RelayReasoningEffort.Automatic }
                ?.value
                ?.takeIf {
                    effectiveReasoning != ReasoningMode.Automatic &&
                        projection.permitsOutbound("reasoning_level/${effectiveReasoning.rawValue}")
                },
            temperature = options.temperature?.takeIf {
                resolvedMetadata.allowsTemperature() &&
                    projection.permitsOutbound("generation_parameter/temperature")
            },
            maxTokens = options.maxTokens?.takeIf {
                projection.permitsOutbound("generation_parameter/max_tokens") ||
                    projection.permitsOutbound("generation_parameter/max_output_tokens")
            },
            generationOptions = options.copy(activeModel = requestModel),
            resolvedMetadata = resolvedMetadata,
            capabilityProjection = projection,
            openAIReasoningParserKind = if (protocol == ToolWireProtocol.OpenAIChat && provider.kind != ProviderKind.Relay) {
                capabilityRuntimeContinuationSelection(
                    providerKind = provider.kind,
                    modelID = modelId,
                    finalTransport = protocol.wireValue,
                    webRequested = false,
                    reasoningMode = effectiveReasoning,
                )?.takeIf { it.continuationKind == "replay_reasoning" }?.responseParserKind
            } else {
                null
            },
        )
    }

    override fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent> = flow {
        val statement = client.preparePost(configuration.endpoint) {
            contentType(ContentType.Application.Json)
            header(HttpHeaders.Accept, ContentType.Application.Json.toString())
            header(HttpHeaders.UserAgent, NativeUserAgent.current())
            applyAuthentication(configuration.authMode, configuration.apiKey)
            if (configuration.protocol == ToolWireProtocol.AnthropicMessages) {
                header("anthropic-version", "2023-06-01")
            }
            if (configuration.providerKind == ProviderKind.OpenRouter) {
                header("HTTP-Referer", "https://github.com/oriveo/oriveo")
                header("X-Title", "Oriveo")
            }
            configuration.headers.filter { it.key.isNotBlank() }.forEach { custom ->
                header(custom.key, custom.value)
            }
            setBody(buildRequestBody(request).toString())
        }

        statement.execute { response ->
            if (!response.status.isSuccess()) {
                val body = runCatching {
                    response.bodyAsChannel().toInputStream().bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
                }.getOrDefault("")
                val credentials = RelayEndpointPolicy.credentialMaterial(
                    response.request.headers.entries().flatMap { entry ->
                        entry.value.map { entry.key to it }
                    } + response.request.url.parameters.entries().flatMap { entry ->
                        entry.value.map { entry.key to it }
                    },
                )
                val mapped = SseParser.mapHttpError(response.status.value, body, credentials)
                if (ToolUnsupportedErrorMatcher.matches(response.status.value, body)) {
                    throw ToolsUnsupportedError(mapped)
                }
                throw mapped
            }
            val decoder = ToolWireStreamDecoder(
                configuration.protocol,
                json,
                configuration.openAIReasoningParserKind,
            )
            when (configuration.protocol) {
                ToolWireProtocol.OpenAIChat -> {
                    SseParser.parseOpenAICompatiblePayloads(response, json).collect { payload ->
                        decoder.parse(null, payload).forEach { emit(it) }
                    }
                }
                ToolWireProtocol.AnthropicMessages -> {
                    var currentEvent: String? = null
                    response.bodyAsChannel().toInputStream().sseLineReader().use { reader ->
                        while (true) {
                            val line = reader.readLine() ?: break
                            when {
                                line.startsWith("event:") -> currentEvent = line.substringAfter("event:").trim()
                                line.startsWith("data:") -> {
                                    val payload = line.substringAfter("data:").trim()
                                    if (payload.isNotBlank()) decoder.parse(currentEvent, payload).forEach { emit(it) }
                                    currentEvent = null
                                }
                            }
                        }
                    }
                }
                ToolWireProtocol.GeminiGenerate -> {
                    response.bodyAsChannel().toInputStream().sseLineReader().use { reader ->
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (!line.startsWith("data:")) continue
                            val payload = line.substringAfter("data:").trim()
                            if (payload.isNotBlank()) decoder.parse(null, payload).forEach { emit(it) }
                        }
                    }
                }
                ToolWireProtocol.OpenAIResponses -> {
                    var currentEvent: String? = null
                    response.bodyAsChannel().toInputStream().sseLineReader().use { reader ->
                        while (true) {
                            val line = reader.readLine() ?: break
                            when {
                                line.startsWith("event:") -> currentEvent = line.substringAfter("event:").trim()
                                line.startsWith("data:") -> {
                                    val payload = line.substringAfter("data:").trim()
                                    if (payload.isNotBlank() && payload != "[DONE]") {
                                        decoder.parse(currentEvent, payload).forEach { emit(it) }
                                    }
                                    currentEvent = null
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private fun buildRequestBody(request: ToolLoopLegRequest): JsonObject {
        val adapted = ToolWireProtocolAdapter.buildBody(configuration.protocol, modelId, request)
        val base = when (configuration.protocol) {
            ToolWireProtocol.OpenAIChat,
            ToolWireProtocol.AnthropicMessages,
            -> JsonObject(adapted + buildJsonObject {
                configuration.serviceTier?.let { put("service_tier", it) }
                configuration.temperature?.let { put("temperature", it) }
                configuration.maxTokens?.let { put("max_tokens", it) }
            })
            ToolWireProtocol.OpenAIResponses -> JsonObject(adapted + buildJsonObject {
                configuration.serviceTier?.let { put("service_tier", it) }
                configuration.temperature?.let { put("temperature", it) }
                configuration.maxTokens?.let { put("max_output_tokens", it) }
            })
            ToolWireProtocol.GeminiGenerate -> {
                val generation = buildJsonObject {
                    configuration.temperature?.let { put("temperature", it) }
                    configuration.maxTokens?.let { put("maxOutputTokens", it) }
                }
                if (generation.isEmpty()) adapted else JsonObject(adapted + ("generationConfig" to generation))
            }
        }
        val profiled = configuration.reasoningParams?.let { deepMergeJsonObject(base, it) } ?: base
        val withRelayReasoning = configuration.relayReasoningEffort?.let { effort ->
            JsonObject(profiled + ("reasoning_effort" to JsonPrimitive(effort)))
        } ?: profiled
        // Every leg is a model request too, so it goes through the same generation resolver as
        // plain chat. Otherwise a conversation would lose model defaults or per-chat overrides
        // around a tool call, or bypass the profile's capability gate.
        return GenerationParameterResolver.apply(
            body = withRelayReasoning.toString(),
            options = configuration.generationOptions,
            resolved = configuration.resolvedMetadata,
            capabilityProjection = configuration.capabilityProjection,
        ).let { json.parseToJsonElement(it).jsonObject }
    }

    internal fun parseEvents(payload: String): List<ToolLoopLegEvent> {
        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrElse {
            throw ProviderServiceError.Network("The provider returned an invalid streaming event.")
        }
        (root["error"] as? JsonObject)?.let { error ->
            throw ProviderServiceError.Upstream(
                statusCode = 500,
                detail = error["message"]?.jsonPrimitive?.contentOrNull
                    ?: "The provider returned a streaming error.",
            )
        }

        val events = mutableListOf<ToolLoopLegEvent>()
        (root["usage"] as? JsonObject)?.let { usage ->
            events += ToolLoopLegEvent.Usage(ToolLoopUsage(
                promptTokens = usage["prompt_tokens"]?.jsonPrimitive?.intOrNull,
                completionTokens = usage["completion_tokens"]?.jsonPrimitive?.intOrNull,
                totalTokens = usage["total_tokens"]?.jsonPrimitive?.intOrNull,
            ))
        }
        val delta = ((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)
            ?.get("delta") as? JsonObject ?: return events

        when (val content = delta["content"]) {
            is JsonPrimitive -> content.contentOrNull?.takeIf { it.isNotEmpty() }
                ?.let { events += ToolLoopLegEvent.TextDelta(it) }
            is JsonArray -> content.mapNotNull { block ->
                val objectBlock = block as? JsonObject ?: return@mapNotNull null
                val type = objectBlock["type"]?.jsonPrimitive?.contentOrNull
                if (type == "text" || type == "output_text") {
                    objectBlock["text"]?.jsonPrimitive?.contentOrNull
                } else null
            }.joinToString("").takeIf { it.isNotEmpty() }
                ?.let { events += ToolLoopLegEvent.TextDelta(it) }
            else -> Unit
        }

        (delta["tool_calls"] as? JsonArray)?.takeIf { it.isNotEmpty() }?.let { calls ->
            events += ToolLoopLegEvent.ToolCallDeltas(calls.mapIndexedNotNull { offset, element ->
                val call = element as? JsonObject ?: return@mapIndexedNotNull null
                val function = call["function"] as? JsonObject
                ToolLoopToolCallDelta(
                    index = call["index"]?.jsonPrimitive?.intOrNull ?: offset,
                    id = call["id"]?.jsonPrimitive?.contentOrNull,
                    type = call["type"]?.jsonPrimitive?.contentOrNull,
                    name = function?.get("name")?.jsonPrimitive?.contentOrNull,
                    arguments = function?.get("arguments")?.jsonPrimitive?.contentOrNull,
                )
            })
        }
        return events
    }

    private fun io.ktor.client.request.HttpRequestBuilder.applyAuthentication(
        mode: RelayAuthMode,
        apiKey: String,
    ) {
        when (mode) {
            RelayAuthMode.None -> Unit
            RelayAuthMode.Auto,
            RelayAuthMode.Bearer -> header(HttpHeaders.Authorization, "Bearer $apiKey")
            RelayAuthMode.XApiKey -> header("x-api-key", apiKey)
            RelayAuthMode.XGoogApiKey -> header("x-goog-api-key", apiKey)
            RelayAuthMode.QueryKey -> Unit
        }
    }

    private companion object {
        const val RELAY_CHAT_TRANSPORT = "openai_chat_completions"

        fun resolveAuthMode(
            provider: Provider,
            runtime: MetadataClient.RelayRuntimeConfig,
            protocol: ToolWireProtocol,
        ): RelayAuthMode {
            if (provider.kind != ProviderKind.Relay) return when (protocol) {
                ToolWireProtocol.AnthropicMessages -> RelayAuthMode.XApiKey
                ToolWireProtocol.GeminiGenerate -> RelayAuthMode.XGoogApiKey
                ToolWireProtocol.OpenAIChat,
                ToolWireProtocol.OpenAIResponses,
                -> RelayAuthMode.Bearer
            }
            provider.relayRequested?.authMode?.takeIf { it != RelayAuthMode.Auto }?.let { return it }
            val transport = provider.relayRequested?.transport?.value ?: RELAY_CHAT_TRANSPORT
            val fallback = runtime.transportRules[transport]?.defaultAuthMode ?: "bearer"
            return RelayAuthMode.entries.firstOrNull { it.value == fallback } ?: RelayAuthMode.Bearer
        }

        fun resolveProtocol(
            provider: Provider,
            metadataTransport: String?,
        ): ToolWireProtocol? = if (provider.kind == ProviderKind.Relay) {
            when (provider.relayRequested?.transport ?: RelayTransport.Auto) {
                RelayTransport.OpenAIChatCompletions -> ToolWireProtocol.OpenAIChat
                RelayTransport.OpenAIResponses -> ToolWireProtocol.OpenAIResponses
                RelayTransport.AnthropicMessages -> ToolWireProtocol.AnthropicMessages
                RelayTransport.GeminiGenerateContent -> ToolWireProtocol.GeminiGenerate
                RelayTransport.Auto,
                RelayTransport.LlamaCppNative,
                -> null
            }
        } else {
            ToolWireProtocol.fromWireValue(metadataTransport)
        }

        fun resolveEndpoint(
            provider: Provider,
            authMode: RelayAuthMode,
            runtime: MetadataClient.RelayRuntimeConfig,
            protocol: ToolWireProtocol,
            modelId: String,
        ): String {
            if (provider.kind != ProviderKind.Relay) {
                val metadata = MetadataClient.providerTransport(provider.kind)?.let { transport ->
                    ProviderTransportDefinition(
                        baseUrl = transport.baseUrl,
                        endpoints = TransportEndpoints(
                            chat = transport.endpoints.chat,
                            responses = transport.endpoints.responses,
                            images = transport.endpoints.images,
                            embeddings = transport.endpoints.embeddings,
                            files = transport.endpoints.files,
                        ),
                    )
                }
                return when (protocol) {
                    ToolWireProtocol.OpenAIChat,
                    ToolWireProtocol.AnthropicMessages,
                    -> EndpointResolver.resolveEndpoint(provider, EndpointResolver.EndpointKind.CHAT, metadata)
                    ToolWireProtocol.OpenAIResponses ->
                        EndpointResolver.resolveEndpoint(provider, EndpointResolver.EndpointKind.RESPONSES, metadata)
                    ToolWireProtocol.GeminiGenerate -> {
                        val base = EndpointResolver.resolveEndpoint(provider, EndpointResolver.EndpointKind.CHAT, metadata)
                            .trimEnd('/')
                        "$base/$modelId:streamGenerateContent?alt=sse"
                    }
                }
            }

            val base = provider.baseUrlText?.trim()?.takeIf { it.isNotEmpty() }
                ?: throw ProviderServiceError.InvalidConfiguration("Missing Relay base URL.")
            val relayTransport = when (protocol) {
                ToolWireProtocol.OpenAIChat -> RelayTransport.OpenAIChatCompletions.value
                ToolWireProtocol.OpenAIResponses -> RelayTransport.OpenAIResponses.value
                ToolWireProtocol.AnthropicMessages -> RelayTransport.AnthropicMessages.value
                ToolWireProtocol.GeminiGenerate -> RelayTransport.GeminiGenerateContent.value
            }
            val rule = runtime.transportRules[relayTransport]
                ?: throw ProviderServiceError.InvalidConfiguration("Missing Relay transport runtime rule.")
            val normalizedBase = if (base.contains("://")) base else "https://$base"
            val builder = URLBuilder(normalizedBase)
            val existingSegments = builder.build().segments.filter { it.isNotEmpty() }
            if (existingSegments.none { it in rule.acceptedVersions }) {
                builder.appendPathSegments(rule.defaultVersion)
            }
            when (protocol) {
                ToolWireProtocol.OpenAIChat -> builder.appendPathSegments("chat", "completions")
                ToolWireProtocol.OpenAIResponses -> builder.appendPathSegments("responses")
                ToolWireProtocol.AnthropicMessages -> builder.appendPathSegments("messages")
                ToolWireProtocol.GeminiGenerate -> builder.appendPathSegments(
                    "models",
                    "$modelId:streamGenerateContent",
                )
            }
            if (protocol == ToolWireProtocol.GeminiGenerate) builder.parameters.append("alt", "sse")
            if (authMode == RelayAuthMode.QueryKey) builder.parameters.append("key", provider.apiKey)
            provider.relayRequested?.queryParams.orEmpty().filter { it.key.isNotBlank() }.forEach { item ->
                builder.parameters.append(item.key, item.value)
            }
            return builder.buildString()
        }
    }
}

/**
 * Converts chat messages into the loop's neutral messages.
 *
 * Leg requests must build messages through the same path as plain chat
 * ([MessageBuilder.buildChatCompletionsMessages]); bypassing it skips provider-specific
 * shaping such as DeepSeek accepting only string content, and a leg carrying attachments
 * would be rejected.
 */
fun toolLoopMessagesFrom(
    messages: List<ChatMessage>,
    provider: Provider,
    activeModel: AIModel?,
    json: Json,
): List<ToolLoopMessage> {
    // The model decides the attachment limits; without it the default limits apply, and the verdict can differ from
    // the one plain chat reaches for the same message.
    val encoded = MessageBuilder.buildChatCompletionsMessages(messages, provider.kind, activeModel = activeModel)
    val array = json.parseToJsonElement("[$encoded]").jsonArray
    return array.mapNotNull { element ->
        val objectValue = element as? JsonObject ?: return@mapNotNull null
        val role = objectValue["role"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
        ToolLoopMessage(role = role, content = objectValue["content"])
    }
}
