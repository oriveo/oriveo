package ai.oriveo.community.core.provider

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

    suspend fun connect(
        engine: LocalEngineKind,
        rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        modelHint: String? = null,
        apiKey: String = "",
        certificateFingerprint: String? = null,
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
        val requested = RelayRequestedConfig(
            transport = if (engine == LocalEngineKind.LlamaCpp) RelayTransport.LlamaCppNative else RelayTransport.OpenAIChatCompletions,
            authMode = if (requiresBearer) RelayAuthMode.Bearer else RelayAuthMode.None,
            securityMode = securityMode,
            stream = true,
            resolvedAPIBaseURL = apiBaseUrl(endpoint, engine),
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

        runCatching {
            relayService.pingRelay(apiKey, requested.resolvedAPIBaseURL, selected, requested)
        }.getOrElse { error ->
            if (error is LocalEngineConnectionException) throw error
            throw LocalEngineConnectionException(classifyNetworkFailure(error), error)
        }
        return LocalEngineConnection(
            engine = engine,
            endpoint = endpoint,
            apiBaseUrl = requested.resolvedAPIBaseURL ?: endpoint,
            modelIds = catalogModelIds(discovered, selected),
            runtimeMetadata = runtimeMetadata.ifEmpty {
                mapOf(selected to LocalModelRuntimeMetadata(LocalModelLoadState.Unknown, executionLocality(engine, selected)))
            },
            selectedModelId = selected,
            requested = requested,
        )
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
        if (engine == LocalEngineKind.LlamaCpp) return it
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
            body?.get("data")?.jsonArray.orEmpty().mapNotNull { it.jsonObject["id"]?.jsonPrimitive?.contentOrNull }
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

    private val LocalEngineKind.wireName: String
        get() = when (this) {
            LocalEngineKind.LlamaCpp -> "llamacpp"
            LocalEngineKind.Ollama -> "ollama"
            LocalEngineKind.LmStudio -> "lmstudio"
            LocalEngineKind.Vllm -> "vllm"
            LocalEngineKind.OpenWebUI -> "openwebui"
        }

    internal fun catalogModelIds(discovered: List<String>, selected: String): List<String> =
        if (selected in discovered) discovered else listOf(selected) + discovered

    private data class Snapshot(val status: Int, val contentType: String, val json: JsonObject?)
}
