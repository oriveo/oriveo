package ai.oriveo.community.core.provider

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.data.remote.MetadataClient

enum class LocalEngineKind { LlamaCpp, Ollama, LmStudio, Vllm, OpenWebUI }
enum class LocalEngineState { Ready, Loading, WrongEngine, ParameterRejected, Unreachable }

data class LocalEngineTemplate(
    val engine: LocalEngineKind,
    val defaultEndpoint: String,
    val probeMethod: String,
    val probePath: String,
    val catalogPath: String,
    val introspectionMethod: String,
    val introspectionPath: String,
    val generationPaths: List<String>,
    /** Candidate paths; support still requires introspection/runtime evidence. */
    val capabilityPaths: Map<String, List<String>>,
)

object LocalEngineContract {
    val templates = mapOf(
        LocalEngineKind.LlamaCpp to LocalEngineTemplate(LocalEngineKind.LlamaCpp, "http://127.0.0.1:8080", "GET", "/health", "/v1/models", "GET", "/props", listOf("/v1/chat/completions", "/v1/messages", "/completion"), mapOf("embedding" to listOf("/embedding", "/v1/embeddings"), "rerank" to listOf("/rerank", "/v1/rerank"))),
        LocalEngineKind.Ollama to LocalEngineTemplate(LocalEngineKind.Ollama, "http://127.0.0.1:11434", "GET", "/api/tags", "/api/tags", "POST", "/api/show", listOf("/api/chat", "/v1/chat/completions"), mapOf("embedding" to listOf("/api/embed", "/api/embeddings"))),
        // LM Studio's three metadata paths must all use /api/v0/models, because classify keys
        // off data[].state, which is the only shape that separates it from vLLM. The
        // OpenAI-compatible /v1/models has no state field and /api/v1/models returns a new
        // models[] shape, so either one makes a real LM Studio come out as WrongEngine.
        LocalEngineKind.LmStudio to LocalEngineTemplate(LocalEngineKind.LmStudio, "http://127.0.0.1:1234", "GET", "/api/v0/models", "/api/v0/models", "GET", "/api/v0/models", listOf("/v1/chat/completions", "/v1/responses"), mapOf("embedding" to listOf("/v1/embeddings"))),
        LocalEngineKind.Vllm to LocalEngineTemplate(LocalEngineKind.Vllm, "http://127.0.0.1:8000", "GET", "/v1/models", "/v1/models", "GET", "/health", listOf("/v1/chat/completions", "/v1/responses"), mapOf("embedding" to listOf("/v1/embeddings"), "rerank" to listOf("/rerank", "/v1/rerank"))),
        LocalEngineKind.OpenWebUI to LocalEngineTemplate(LocalEngineKind.OpenWebUI, "https://127.0.0.1:3000", "GET", "/api/models", "/api/models", "GET", "/api/models", listOf("/api/chat/completions"), mapOf("embedding" to listOf("/api/embeddings"))),
    )

    fun classify(engine: LocalEngineKind, status: Int, contentType: String, body: Any?): LocalEngineState {
        val json = body as? JsonObject ?: return LocalEngineState.WrongEngine
        if (status == 400 && json["error"]?.jsonObject?.get("type")?.jsonPrimitive?.contentOrNull == "invalid_request_error") return LocalEngineState.ParameterRejected
        if (status == 503) return LocalEngineState.Loading
        if (status !in 200..299 || !contentType.contains("json", ignoreCase = true)) return LocalEngineState.WrongEngine
        return when (engine) {
            LocalEngineKind.LlamaCpp -> when (json["status"]?.jsonPrimitive?.contentOrNull) {
                "ok" -> LocalEngineState.Ready
                "loading model" -> LocalEngineState.Loading
                else -> LocalEngineState.WrongEngine
            }
            LocalEngineKind.Ollama -> if (json["models"]?.jsonArray != null) LocalEngineState.Ready else LocalEngineState.WrongEngine
            LocalEngineKind.LmStudio -> if ((json["data"]?.jsonArray ?: return LocalEngineState.WrongEngine).any { "state" in it.jsonObject }) LocalEngineState.Ready else LocalEngineState.WrongEngine
            LocalEngineKind.Vllm -> if ((json["data"]?.jsonArray ?: return LocalEngineState.WrongEngine).all { "id" in it.jsonObject && "state" !in it.jsonObject }) LocalEngineState.Ready else LocalEngineState.WrongEngine
            LocalEngineKind.OpenWebUI -> {
                val rows = json["data"]?.jsonArray ?: json["models"]?.jsonArray ?: return LocalEngineState.WrongEngine
                if (rows.all { "id" in it.jsonObject || "name" in it.jsonObject }) LocalEngineState.Ready else LocalEngineState.WrongEngine
            }
        }
    }

    fun modelLocality(engine: LocalEngineKind, modelId: String): String =
        if (engine == LocalEngineKind.Ollama && modelId.lowercase().endsWith(":cloud")) "cloud" else "local"
}

/** Explicit local engine profiles; ordinary Relay never receives this fallback authority. */
object LocalEngineGenerationProfiles {
    fun profile(engineProfile: String?, transport: RelayTransport? = null): GenerationProfileRef? {
        return when (engineProfile) {
            "llamacpp" -> GenerationProfileRef(
                template = "llamacpp_native", parameters = LLAMA_IDS.map { parameter(it) },
                wire = LLAMA_IDS.associateWith { if (it == "max_output_tokens") "n_predict" else it },
                transport = "llamacpp_native",
            )
            "vllm" -> GenerationProfileRef(
                template = "vllm_extra_body", parameters = VLLM_IDS.map { parameter(it) },
                wire = VLLM_IDS.associateWith {
                    when (it) {
                        "max_output_tokens" -> "max_tokens"
                        "top_k", "min_p", "typical_p", "repeat_penalty" -> "extra_body.${if (it == "repeat_penalty") "repetition_penalty" else it}"
                        else -> it
                    }
                },
                transport = "openai_chat_completions",
            )
            "openwebui" -> {
                val ids = listOf("max_output_tokens", "stop", "temperature", "top_p", "frequency_penalty", "presence_penalty", "seed", "response_format", "json_schema", "verbosity", "logprobs", "top_logprobs")
                GenerationProfileRef(
                    template = "openai_chat_completions",
                    parameters = ids.map { parameter(it) },
                    wire = mapOf("max_output_tokens" to "max_tokens", "stop" to "stop", "temperature" to "temperature", "top_p" to "top_p", "frequency_penalty" to "frequency_penalty", "presence_penalty" to "presence_penalty", "seed" to "seed", "response_format" to "response_format", "json_schema" to "response_format", "verbosity" to "verbosity", "logprobs" to "logprobs", "top_logprobs" to "top_logprobs"),
                    transport = "openai_chat_completions",
                )
            }
            else -> genericRelayProfile(transport)
        }
    }

    private fun genericRelayProfile(transport: RelayTransport?): GenerationProfileRef? {
        val (template, ids, wire) = when (transport) {
            RelayTransport.OpenAIChatCompletions -> Triple(
                "openai_chat_completions",
                listOf("max_output_tokens", "stop", "reasoning_effort", "reasoning_budget", "reasoning_mode", "temperature", "top_p", "top_k", "min_p", "frequency_penalty", "presence_penalty", "repeat_penalty", "seed", "logprobs"),
                mapOf("max_output_tokens" to "max_tokens", "stop" to "stop", "reasoning_effort" to "reasoning_effort", "reasoning_budget" to "reasoning_budget", "reasoning_mode" to "reasoning_mode", "temperature" to "temperature", "top_p" to "top_p", "top_k" to "top_k", "min_p" to "min_p", "frequency_penalty" to "frequency_penalty", "presence_penalty" to "presence_penalty", "repeat_penalty" to "repeat_penalty", "seed" to "seed", "logprobs" to "logprobs"),
            )
            RelayTransport.OpenAIResponses -> Triple(
                "openai_responses",
                listOf("max_output_tokens", "reasoning_effort", "temperature", "top_p", "seed", "logprobs"),
                mapOf("max_output_tokens" to "max_output_tokens", "reasoning_effort" to "reasoning.effort", "temperature" to "temperature", "top_p" to "top_p", "seed" to "seed", "logprobs" to "logprobs"),
            )
            RelayTransport.AnthropicMessages -> Triple(
                "anthropic_messages",
                listOf("max_output_tokens", "stop", "temperature", "top_p", "top_k"),
                mapOf("max_output_tokens" to "max_tokens", "stop" to "stop_sequences", "temperature" to "temperature", "top_p" to "top_p", "top_k" to "top_k"),
            )
            RelayTransport.GeminiGenerateContent -> Triple(
                "gemini_generate_content",
                listOf("max_output_tokens", "stop", "temperature", "top_p", "top_k", "presence_penalty", "frequency_penalty", "seed", "logprobs"),
                mapOf("max_output_tokens" to "generationConfig.maxOutputTokens", "stop" to "generationConfig.stopSequences", "temperature" to "generationConfig.temperature", "top_p" to "generationConfig.topP", "top_k" to "generationConfig.topK", "presence_penalty" to "generationConfig.presencePenalty", "frequency_penalty" to "generationConfig.frequencyPenalty", "seed" to "generationConfig.seed", "logprobs" to "generationConfig.responseLogprobs"),
            )
            else -> return null
        }
        return GenerationProfileRef(
            template = template,
            parameters = ids.map { parameter(it, support = "unknown") },
            wire = wire,
            transport = template,
        )
    }

    private fun parameter(id: String, support: String = "accepted_unverified"): GenerationParameterRef {
        val (schema, range) = when (id) {
            "max_output_tokens" -> "integer" to GenerationParameterRange(min = 1.0)
            "top_k" -> "integer" to GenerationParameterRange(min = 0.0)
            "seed" -> "integer" to null
            "top_p", "min_p", "typical_p", "xtc_probability", "xtc_threshold" -> "number" to GenerationParameterRange(min = 0.0, max = 1.0)
            "mirostat", "repeat_last_n", "dry_allowed_length", "dry_penalty_last_n", "min_keep", "n_keep", "n_indent", "t_max_predict_ms", "n_probs" -> "integer" to null
            "samplers" -> "string-list" to null
            "ignore_eos", "post_sampling_probs", "logprobs" -> "boolean" to null
            "json_schema" -> "json-schema" to null
            "temperature" -> "number" to null
            "repeat_penalty" -> "number" to GenerationParameterRange(min = 0.0)
            "stop" -> "string-list" to null
            else -> "string" to null
        }
        return GenerationParameterRef(
            id = id,
            support = support,
            source = "user_declared",
            group = when (id) {
                "reasoning_effort", "reasoning_budget", "reasoning_mode" -> "reasoning"
                "frequency_penalty", "presence_penalty", "repeat_penalty" -> "repetition"
                "seed" -> "reproducibility"
                "max_output_tokens", "stop" -> "budget"
                "json_schema", "logprobs" -> "output_contract"
                else -> "sampling"
            },
            valueSchema = schema,
            range = range,
            portability = if (id in setOf("top_k", "min_p", "repeat_penalty")) "engine_scoped" else "transport_scoped",
            risk = if (id in setOf("top_k", "min_p")) "experimental" else "normal",
        )
    }

    private val LLAMA_IDS = listOf(
        "max_output_tokens", "stop", "temperature", "top_p", "top_k", "min_p", "typical_p",
        "repeat_penalty", "repeat_last_n", "mirostat", "mirostat_tau", "mirostat_eta",
        "dry_multiplier", "dry_base", "dry_allowed_length", "dry_penalty_last_n",
        "xtc_probability", "xtc_threshold", "samplers", "ignore_eos", "top_n_sigma",
        "dynatemp_range", "dynatemp_exponent", "min_keep", "n_keep", "n_indent",
        "t_max_predict_ms", "n_probs", "post_sampling_probs", "seed", "json_schema", "logprobs",
    )
    private val VLLM_IDS = listOf(
        "max_output_tokens", "stop", "temperature", "top_p", "top_k", "min_p", "typical_p",
        "presence_penalty", "frequency_penalty", "repeat_penalty", "seed", "json_schema", "logprobs", "top_logprobs",
    )
}

/** The two scopes a generation-parameter entry point can have: the chat-page chip (this
 *  session) and the provider detail panel (this connection's defaults). */
enum class GenerationParameterEntryScope { Session, ConnectionDefaults }

/** Whether the user is allowed to manage the engine runtime for this connection scope. When it
 *  cannot be determined, this fails safe to closed rather than assuming true. */
data class GenerationAccess(val canManageRuntime: Boolean = false)

/**
 * Official models trust only the published catalog; Relay is the only kind allowed to use the
 * engine and transport profile of the current connection.
 *
 * Visibility is decided by three named predicates and nothing is ever inlined again.
 *
 * The point is **not** "one function", it is "three named functions". The session scope and the
 * connection scope use deliberately different rules - which group reasoning belongs to is a
 * settled product decision - and flattening them into one function would be quietly re-deciding
 * that. No UI file may inline a predicate such as `support != "unsupported"`.
 *
 * The rules come from the shared contract
 * `shared/model-contracts/generation_parameter_contract.v1.json#availabilityRules`, which every
 * platform consumes from the same table.
 */
object GenerationParameterAvailability {
    fun profile(
        provider: Provider,
        model: AIModel,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): GenerationProfileRef? = if (provider.kind == ProviderKind.Relay) {
        model.generationProfile ?: run {
            val requestedTransport = provider.relayRequested?.transport ?: RelayTransport.Auto
            val effectiveTransport = if (requestedTransport == RelayTransport.Auto) {
                RelayTransport.OpenAIChatCompletions
            } else requestedTransport
            LocalEngineGenerationProfiles.profile(
                provider.relayRequested?.engineProfile,
                effectiveTransport,
            )
        }
    } else {
        metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)?.metadata?.profiles?.generation
    }

    /**
     * The set the session scope can act on: a non-empty wire mapping, a support value inside the
     * outbound allowlist, and an exact profile identity - and **the reasoning group is excluded**,
     * because the one place a session-level reasoning effort is written is the chat page's own
     * reasoning chip.
     *
     * The allowlist references the same constant the outbound gate uses, so the editable set in
     * the panel is always a subset of what will actually be sent.
     */
    internal fun sessionActionable(
        provider: Provider,
        model: AIModel,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection = generationProjection(provider, model),
    ): List<GenerationParameterRef> {
        val profile = profile(provider, model) ?: return emptyList()
        return profile.parameters.filter { parameter ->
            val id = parameter.id ?: return@filter false
            if (profile.wire[id].isNullOrEmpty()) return@filter false
            if (isReasoningParameter(parameter)) return@filter false
            capabilityProjection.decision("generation_parameter/$id")?.editable == true
        }
    }

    /**
     * The set the connection scope renders: rows are not dropped by support value, only by the
     * access filter, and **the reasoning group is kept** - a connection-level reasoning default
     * really is sent, it is not a read-only projection.
     *
     * A non-empty wire mapping is not required here: a row with no wire mapping still renders,
     * but [isEditable] returns false for it, which shows the truth rather than hiding it.
     */
    internal fun connectionConfigurable(
        provider: Provider,
        model: AIModel,
        access: GenerationAccess,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection = generationProjection(provider, model),
    ): List<GenerationParameterRef> {
        val profile = profile(provider, model) ?: return emptyList()
        return profile.parameters.filter { parameter ->
            val id = parameter.id ?: return@filter false
            if (capabilityProjection.decision("generation_parameter/$id")?.visible != true) return@filter false
            parameter.group != "engine_runtime" || access.canManageRuntime
        }
    }

    /** An entry point is visible exactly when its scope's set is non-empty. Every entry point
     *  must ask this one function. */
    internal fun entryVisible(
        provider: Provider,
        model: AIModel,
        scope: GenerationParameterEntryScope,
        access: GenerationAccess = GenerationAccess(),
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection = generationProjection(provider, model),
    ): Boolean = when (scope) {
        GenerationParameterEntryScope.Session -> sessionActionable(provider, model, capabilityProjection).isNotEmpty()
        GenerationParameterEntryScope.ConnectionDefaults ->
            connectionConfigurable(provider, model, access, capabilityProjection).isNotEmpty()
    }

    /** Whether a control is writable: a non-empty wire mapping and a support value inside the
     *  outbound allowlist. This is the UI-side landing point of that same rule. */
    internal fun isEditable(
        provider: Provider,
        profile: GenerationProfileRef?,
        parameter: GenerationParameterRef,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection = generationProjection(provider, modelFromProfile(profile)),
    ): Boolean {
        val id = parameter.id ?: return false
        if (profile == null || profile.wire[id].isNullOrEmpty()) return false
        return capabilityProjection.decision("generation_parameter/$id")?.editable == true
    }

    /** Which parameters belong to the reasoning group: group first, id prefix as a fallback for
     *  older snapshots that did not publish a group. */
    fun isReasoningParameter(parameter: GenerationParameterRef): Boolean =
        parameter.group == "reasoning" || parameter.id?.startsWith("reasoning_") == true

    private fun generationProjection(
        provider: Provider,
        model: AIModel,
    ): CapabilityEvidenceProductionAdapter.Projection =
        CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
            provider = provider,
            model = model,
            localIdentity = null,
            parameters = profile(provider, model)?.parameters.orEmpty(),
            values = ai.oriveo.community.core.model.GenerationParameterOverrides(),
        )

    private fun modelFromProfile(profile: GenerationProfileRef?): AIModel =
        AIModel(id = "generation-profile", name = "generation-profile", generationProfile = profile)
}
