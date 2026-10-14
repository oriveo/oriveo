package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.LocalModelLoadState
import ai.oriveo.community.core.model.LocalModelRuntimeMetadata
import ai.oriveo.community.core.model.ModelExecutionLocality
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.relay.RELAY_SECURITY_MODE_HEADER
import ai.oriveo.community.core.provider.relay.RELAY_CERTIFICATE_FINGERPRINT_HEADER
import ai.oriveo.community.core.provider.relay.relayLocalSecurityPlugin
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.header
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class LocalEngineConnection(
    val engine: LocalEngineKind,
    val endpoint: String,
    val apiBaseUrl: String,
    val modelIds: List<String>,
    val runtimeMetadata: Map<String, LocalModelRuntimeMetadata>,
    val selectedModelId: String,
    val requested: RelayRequestedConfig,
    /** The engine's capability declaration for each chat model; models without a declaration are not in the table. */
    val engineDeclarations: Map<String, EngineDeclaration> = emptyMap(),
    /** Context length of the default model, taken only from responses already received at connect time (llama.cpp `/props`, LM Studio `/api/v0/models`); null if unavailable. */
    val contextLength: Int? = null,
)

enum class LocalEngineConnectionFailure { InvalidEndpoint, CleartextCredentials, AuthenticationRejected, WrongEngine, Loading, NoModels, EngineStopped, OutOfMemory, ContextExceeded, Timeout, Network }

class LocalEngineConnectionException(val failure: LocalEngineConnectionFailure, cause: Throwable? = null) :
    IllegalStateException(failure.name, cause)

class LocalEngineConnector(
    client: HttpClient,
    private val json: Json,
    private val relayService: RelayService,
) {
    companion object {
        internal fun supportsSecurityMode(mode: RelayConnectionSecurityMode): Boolean = mode in setOf(
            RelayConnectionSecurityMode.RemoteHttps,
            RelayConnectionSecurityMode.LocalHttp,
            RelayConnectionSecurityMode.PrivateVpn,
            RelayConnectionSecurityMode.TofuHttps,
        )

        internal fun configurationFailure(error: Throwable): LocalEngineConnectionFailure =
            if ((error as? ProviderServiceError.InvalidConfiguration)?.detail == "cleartext_credentials") {
                LocalEngineConnectionFailure.CleartextCredentials
            } else {
                LocalEngineConnectionFailure.InvalidEndpoint
            }
    }

    private val client = client.config {
        followRedirects = false
        expectSuccess = false
        install(relayLocalSecurityPlugin())
    }

    /**
     * Local engine fingerprint: send the five read-only GETs of [LocalEngineFingerprintRules.requests] to [rawEndpoint],
     * and return engine / generic / manual by the criteria. An address that violates the connection policy, or all requests failing, yields manual without throwing.
     */
    suspend fun fingerprint(
        rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        certificateFingerprint: String? = null,
    ): LocalEngineFingerprint {
        if (!supportsSecurityMode(securityMode)) return LocalEngineFingerprint.manual
        val endpoint = runCatching {
            RelayEndpointPolicy.requireConfigured(
                rawEndpoint,
                securityMode,
                RelayEndpointPolicy.Credentials(authMode = RelayAuthMode.None, hasKey = false),
            )
        }.getOrElse { return LocalEngineFingerprint.manual }
        val requested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.None,
            securityMode = securityMode,
            certificateFingerprint = certificateFingerprint,
        )
        val responses = LocalEngineFingerprintRules.requests.mapNotNull { path ->
            // Any path failing (including 401/403 and network errors) only means this criterion does not match.
            val snapshot = try {
                get(endpoint, path, requested, apiKey = "")
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
            val body = snapshot?.json?.takeIf { snapshot.status in 200..299 }
            body?.let { path to it }
        }.toMap()
        return LocalEngineFingerprintRules.decide(responses)
    }

    suspend fun connect(
        engine: LocalEngineKind,
        rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        modelHint: String? = null,
        apiKey: String = "",
        certificateFingerprint: String? = null,
        channel: RelayTransport = RelayTransport.OpenAIChatCompletions,
    ): LocalEngineConnection {
        val inspected = inspect(engine, rawEndpoint, securityMode, modelHint, apiKey, certificateFingerprint, channel)
        val requested = inspected.requested
        val selected = inspected.selectedModelId
        runCatching {
            relayService.pingRelay(apiKey, requested.resolvedAPIBaseURL, selected, requested)
        }.getOrElse { error ->
            if (error is LocalEngineConnectionException) throw error
            throw LocalEngineConnectionException(classifyNetworkFailure(error), error)
        }
        return inspected
    }

    /**
     * For re-detect: only re-read the engine's read-only metadata and parse per-model declarations, sending no generation request and probing no protocol.
     * Failure throws [LocalEngineConnectionException] the same way as [connect].
     */
    suspend fun declarations(
        engine: LocalEngineKind,
        rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        modelHint: String? = null,
        apiKey: String = "",
        certificateFingerprint: String? = null,
    ): Map<String, EngineDeclaration> =
        inspect(engine, rawEndpoint, securityMode, modelHint, apiKey, certificateFingerprint).engineDeclarations

    /** Fingerprint, catalog, introspection, declarations; [connect] then does one 1-token verification after it. */
    private suspend fun inspect(
        engine: LocalEngineKind,
        rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        modelHint: String?,
        apiKey: String,
        certificateFingerprint: String?,
        channel: RelayTransport = RelayTransport.OpenAIChatCompletions,
    ): LocalEngineConnection {
        if (!supportsSecurityMode(securityMode)) {
            throw LocalEngineConnectionException(LocalEngineConnectionFailure.InvalidEndpoint)
        }
        val requiresBearer = engine == LocalEngineKind.OpenWebUI
        if (requiresBearer && apiKey.isBlank()) throw LocalEngineConnectionException(LocalEngineConnectionFailure.InvalidEndpoint)
        val endpoint = runCatching {
            RelayEndpointPolicy.requireConfigured(
                rawEndpoint,
                securityMode,
                RelayEndpointPolicy.Credentials(authMode = if (requiresBearer) RelayAuthMode.Bearer else RelayAuthMode.None, hasKey = requiresBearer),
            )
        }.getOrElse { throw LocalEngineConnectionException(configurationFailure(it), it) }
        val template = LocalEngineContract.templates.getValue(engine)
        // The channel is taken only from the candidates in channels.byEngine; anything not among the candidates falls back to chat.
        val effectiveChannel = channel.takeIf { LocalEngineChannels.candidates(engine.wireName)?.contains(it) == true }
            ?: RelayTransport.OpenAIChatCompletions
        val requested = RelayRequestedConfig(
            transport = effectiveChannel,
            authMode = if (requiresBearer) RelayAuthMode.Bearer else RelayAuthMode.None,
            securityMode = securityMode,
            stream = true,
            // The llama.cpp native endpoint sits at the root with no version segment (same rule as RelayEndpointResolver).
            resolvedAPIBaseURL = if (effectiveChannel == RelayTransport.LlamaCppNative) {
                endpoint.trimEnd('/')
            } else {
                apiBaseUrl(endpoint, engine)
            },
            engineProfile = engine.wireName,
            certificateFingerprint = certificateFingerprint,
        )

        val fingerprint = get(endpoint, template.probePath, requested, apiKey)
        when (LocalEngineContract.classify(engine, fingerprint.status, fingerprint.contentType, fingerprint.json)) {
            LocalEngineState.Ready -> Unit
            LocalEngineState.Loading -> throw LocalEngineConnectionException(LocalEngineConnectionFailure.Loading)
            else -> throw LocalEngineConnectionException(LocalEngineConnectionFailure.WrongEngine)
        }
        val catalog = if (template.catalogPath == template.probePath) fingerprint
        else get(endpoint, template.catalogPath, requested, apiKey)
        val discovered = modelIds(engine, catalog.json)
        val runtimeMetadata = modelRuntimeMetadata(engine, catalog.json, discovered)
        val selected = modelHint?.trim()?.takeIf(String::isNotEmpty) ?: discovered.firstOrNull()
            ?: throw LocalEngineConnectionException(LocalEngineConnectionFailure.NoModels)

        val introspection = request(
            endpoint = endpoint,
            method = template.introspectionMethod,
            path = template.introspectionPath,
            body = if (engine == LocalEngineKind.Ollama) JsonObject(mapOf("model" to JsonPrimitive(selected))).toString() else null,
            requested = requested,
            apiKey = apiKey,
        )
        if (!introspectionMatches(engine, introspection)) {
            throw LocalEngineConnectionException(LocalEngineConnectionFailure.WrongEngine)
        }
        val catalogModelIds = catalogModelIds(discovered, selected)
        // The llama.cpp declaration comes from the GET /props just fetched (introspection), so no extra request is sent.
        val engineDeclarations = LocalEngineDeclarations.parse(
            engine = engine,
            catalog = catalog.json,
            props = introspection.json.takeIf { engine == LocalEngineKind.LlamaCpp },
            modelIds = catalogModelIds,
        )
        return LocalEngineConnection(
            engine = engine,
            endpoint = endpoint,
            apiBaseUrl = requested.resolvedAPIBaseURL ?: endpoint,
            modelIds = catalogModelIds,
            runtimeMetadata = runtimeMetadata.ifEmpty {
                mapOf(selected to LocalModelRuntimeMetadata(LocalModelLoadState.Unknown, executionLocality(engine, selected)))
            },
            selectedModelId = selected,
            requested = requested,
            engineDeclarations = engineDeclarations,
            contextLength = contextLength(engine, catalog.json, introspection.json, selected),
        )
    }

    /** Reads only responses already received and sends no extra request: n_ctx from llama.cpp `/props`, max_context_length from the LM Studio catalog row. */
    private fun contextLength(engine: LocalEngineKind, catalog: JsonObject?, props: JsonObject?, selected: String): Int? {
        fun JsonObject?.positiveInt(key: String): Int? =
            (this?.get(key) as? JsonPrimitive)?.takeIf { !it.isString }?.contentOrNull?.toIntOrNull()?.takeIf { it > 0 }
        return when (engine) {
            LocalEngineKind.LlamaCpp -> props.positiveInt("n_ctx")
                ?: (props?.get("default_generation_settings") as? JsonObject).positiveInt("n_ctx")
            LocalEngineKind.LmStudio -> catalog?.get("data")?.jsonArray.orEmpty()
                .mapNotNull { it as? JsonObject }
                .firstOrNull { (it["id"] as? JsonPrimitive)?.contentOrNull == selected }
                .positiveInt("max_context_length")
            else -> null
        }
    }

    private suspend fun get(endpoint: String, path: String, requested: RelayRequestedConfig, apiKey: String): Snapshot {
        return request(endpoint, "GET", path, null, requested, apiKey)
    }

    private suspend fun request(endpoint: String, method: String, path: String, body: String?, requested: RelayRequestedConfig, apiKey: String): Snapshot {
        val url = endpoint.trimEnd('/') + "/" + path.trimStart('/')
        return runCatching {
            val response = if (method == "POST") client.post(url) {
                header(RELAY_SECURITY_MODE_HEADER, requested.securityMode.value)
                requested.certificateFingerprint?.let { header(RELAY_CERTIFICATE_FINGERPRINT_HEADER, it) }
                if (requested.authMode == RelayAuthMode.Bearer) header(HttpHeaders.Authorization, "Bearer $apiKey")
                header(HttpHeaders.ContentType, "application/json")
                if (body != null) setBody(body)
            } else client.get(url) {
                header(RELAY_SECURITY_MODE_HEADER, requested.securityMode.value)
                requested.certificateFingerprint?.let { header(RELAY_CERTIFICATE_FINGERPRINT_HEADER, it) }
                if (requested.authMode == RelayAuthMode.Bearer) header(HttpHeaders.Authorization, "Bearer $apiKey")
            }
            val body = response.bodyAsText()
            Snapshot(
                status = response.status.value,
                contentType = response.headers[HttpHeaders.ContentType].orEmpty(),
                json = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull(),
            ).also { snapshot ->
                if (snapshot.status == 401 || snapshot.status == 403) {
                    throw LocalEngineConnectionException(LocalEngineConnectionFailure.AuthenticationRejected)
                }
            }
        }.getOrElse { error ->
            if (error is LocalEngineConnectionException) throw error
            throw LocalEngineConnectionException(classifyNetworkFailure(error), error)
        }
    }

    private fun introspectionMatches(engine: LocalEngineKind, snapshot: Snapshot): Boolean {
        if (snapshot.status !in 200..299) return false
        if (engine == LocalEngineKind.Vllm) return true
        val body = snapshot.json ?: return false
        return when (engine) {
            LocalEngineKind.LlamaCpp -> body["default_generation_settings"] is JsonObject
            LocalEngineKind.Ollama -> body["capabilities"] != null || body["parameters"] != null
            LocalEngineKind.LmStudio -> body["data"] != null || body["models"] != null
            LocalEngineKind.Vllm -> true
            LocalEngineKind.OpenWebUI -> body["data"] != null || body["models"] != null
        }
    }

    private fun apiBaseUrl(endpoint: String, engine: LocalEngineKind): String = endpoint.trimEnd('/').let {
        if (engine == LocalEngineKind.OpenWebUI) return "$it/api"
        if (it.endsWith("/v1", ignoreCase = true)) it else "$it/v1"
    }

    private fun modelIds(engine: LocalEngineKind, body: JsonObject?): List<String> {
        val values = if (engine == LocalEngineKind.Ollama) {
            body?.get("models")?.jsonArray.orEmpty().mapNotNull { it.jsonObject["name"]?.jsonPrimitive?.contentOrNull }
        } else if (engine == LocalEngineKind.OpenWebUI) {
            (body?.get("data")?.jsonArray.orEmpty() + body?.get("models")?.jsonArray.orEmpty()).mapNotNull {
                it.jsonObject["id"]?.jsonPrimitive?.contentOrNull ?: it.jsonObject["name"]?.jsonPrimitive?.contentOrNull
            }
        } else {
            body?.get("data")?.jsonArray.orEmpty()
                .filter { LocalEngineDeclarations.isChatModel(engine, it.jsonObject) }
                .mapNotNull { it.jsonObject["id"]?.jsonPrimitive?.contentOrNull }
        }
        return values.map(String::trim).filter(String::isNotEmpty).distinct()
    }

    private fun modelRuntimeMetadata(
        engine: LocalEngineKind,
        body: JsonObject?,
        modelIds: List<String>,
    ): Map<String, LocalModelRuntimeMetadata> {
        val rows = when (engine) {
            LocalEngineKind.Ollama -> body?.get("models")?.jsonArray.orEmpty()
            LocalEngineKind.OpenWebUI -> body?.get("data")?.jsonArray.orEmpty() + body?.get("models")?.jsonArray.orEmpty()
            else -> body?.get("data")?.jsonArray.orEmpty()
        }
        return modelIds.associateWith { modelId ->
            val row = rows.map { it.jsonObject }.firstOrNull {
                val rowId = if (engine == LocalEngineKind.Ollama) {
                    it["name"]?.jsonPrimitive?.contentOrNull
                } else {
                    it["id"]?.jsonPrimitive?.contentOrNull ?: it["name"]?.jsonPrimitive?.contentOrNull
                }
                rowId == modelId
            }
            val state = when (row?.get("state")?.jsonPrimitive?.contentOrNull?.lowercase()) {
                "loaded" -> LocalModelLoadState.Loaded
                "loading" -> LocalModelLoadState.Loading
                "unloaded" -> LocalModelLoadState.Unloaded
                else -> if (engine == LocalEngineKind.Vllm || engine == LocalEngineKind.OpenWebUI) LocalModelLoadState.Loaded else LocalModelLoadState.Unknown
            }
            LocalModelRuntimeMetadata(state, executionLocality(engine, modelId))
        }
    }

    private fun executionLocality(engine: LocalEngineKind, modelId: String): ModelExecutionLocality =
        if (LocalEngineContract.modelLocality(engine, modelId) == "cloud") ModelExecutionLocality.ProxiedCloud
        else ModelExecutionLocality.Local

    private fun classifyNetworkFailure(error: Throwable): LocalEngineConnectionFailure {
        val message = error.message.orEmpty().lowercase()
        return when {
            "401" in message || "403" in message || "unauthorized" in message || "forbidden" in message ->
                LocalEngineConnectionFailure.AuthenticationRejected
            "timed out" in message || "timeout" in message -> LocalEngineConnectionFailure.Timeout
            "out of memory" in message || "oom" in message -> LocalEngineConnectionFailure.OutOfMemory
            "context" in message && ("length" in message || "window" in message || "too long" in message) -> LocalEngineConnectionFailure.ContextExceeded
            "connect" in message || "refused" in message || "unreachable" in message -> LocalEngineConnectionFailure.EngineStopped
            else -> LocalEngineConnectionFailure.Network
        }
    }

    internal fun catalogModelIds(discovered: List<String>, selected: String): List<String> =
        if (selected in discovered) discovered else listOf(selected) + discovered

    private data class Snapshot(val status: Int, val contentType: String, val json: JsonObject?)
}
