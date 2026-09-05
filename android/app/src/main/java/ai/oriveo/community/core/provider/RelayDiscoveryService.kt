package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.provider.relay.RelayHeaderBuilder.applyRelayHeaders
import ai.oriveo.community.core.provider.relay.RelayHeaderBuilder.resolveAuthMode
import ai.oriveo.community.core.provider.relay.buildRelayQueryPairs
import ai.oriveo.community.core.provider.relay.relayLocalSecurityPlugin
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.timeout
import io.ktor.client.request.accept
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.contentType
import java.io.EOFException
import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

enum class RelayDiscoveryFailureKind {
    InvalidEndpoint,
    EmbeddedQuery,
    AuthenticationRejected,
    RouteUnavailable,
    RateLimited,
    TemporaryFailure,
    InvalidResponse,
    Network,
}

enum class RelayDiscoveryAttemptKind { Catalog, GenerationProbe }

enum class RelayDetectionEvidence { Catalog, GenerationProbe }

data class RelayDiscoveryAttempt(
    val candidate: RelayEndpointCandidate,
    val requestUrl: String,
    val statusCode: Int?,
    val failure: RelayDiscoveryFailureKind?,
    val kind: RelayDiscoveryAttemptKind = RelayDiscoveryAttemptKind.Catalog,
    val upstreamMessage: String? = null,
    val retryCount: Int = 0,
)

data class RelayDetectedConfiguration(
    val transport: RelayTransport,
    val authMode: RelayAuthMode,
    val apiBaseUrl: String,
    val modelIDs: List<String>,
    val endpointEvidence: RelayEndpointCandidateEvidence,
    val generationVerified: Boolean,
    val detectionEvidence: RelayDetectionEvidence = RelayDetectionEvidence.Catalog,
) {
    val id: String get() = "${transport.value}|$apiBaseUrl"
}

data class RelayDiscoveryResult(
    val descriptor: RelayEndpointDescriptor,
    val detections: List<RelayDetectedConfiguration>,
    val attempts: List<RelayDiscoveryAttempt>,
    val blockingFailure: RelayDiscoveryFailureKind?,
)

/** Keep compatible non-JSON 2xx responses, but never mistake a web console fallback page for an API hit. */
internal fun isRelayGenerationSuccessResponse(body: String, contentType: String?): Boolean {
    val normalizedType = contentType.orEmpty().lowercase()
    if ("text/html" in normalizedType || "application/xhtml+xml" in normalizedType) return false
    val prefix = body.trimStart('\uFEFF', ' ', '\t', '\r', '\n').lowercase()
    return !prefix.startsWith("<!doctype html") &&
        !prefix.startsWith("<html") &&
        !prefix.startsWith("<head") &&
        !prefix.startsWith("<body")
}

/** Bounded, serial Relay discovery. It never sends credentials to a different origin. */
class RelayDiscoveryService(
    client: HttpClient,
    private val json: Json,
    private val retryBackoffMs: List<Long> = listOf(400L, 1_200L),
) {
    companion object {
        const val SENTINEL_PROBE_MODEL_ID = "oriveo-endpoint-probe-no-such-model"
        private const val REQUEST_TIMEOUT_MS = 12_000L
    }

    private val client = client.config {
        followRedirects = false
        expectSuccess = false
        install(relayLocalSecurityPlugin())
    }

    suspend fun discover(
        endpoint: String,
        apiKey: String,
        modelHint: String?,
        forcedTransport: RelayTransport? = null,
        includeGenerationProbe: Boolean = true,
        relayRequested: RelayRequestedConfig? = null,
    ): RelayDiscoveryResult {
        val requestedForPolicy = relayRequested ?: RelayRequestedConfig()
        val safeEndpoint = try {
            RelayEndpointPolicy.requireConfigured(
                baseUrl = endpoint,
                securityMode = requestedForPolicy.securityMode,
                credentials = RelayEndpointPolicy.credentialsOf(
                    requestedForPolicy,
                    hasKey = hasStoredCredential(apiKey),
                ),
            )
        } catch (error: ProviderServiceError.InvalidConfiguration) {
            return invalidEndpointResult(
                endpoint,
                if (error.detail == "embedded_query") {
                    RelayDiscoveryFailureKind.EmbeddedQuery
                } else {
                    RelayDiscoveryFailureKind.InvalidEndpoint
                },
            )
        } catch (_: Exception) {
            return invalidEndpointResult(endpoint)
        }
        val descriptor = try {
            RelayEndpointResolver.describe(safeEndpoint, requestedForPolicy.securityMode)
        } catch (_: Exception) {
            return invalidEndpointResult(endpoint)
        }
        if (descriptor.containsEmbeddedQuery) {
            return RelayDiscoveryResult(descriptor, emptyList(), emptyList(), RelayDiscoveryFailureKind.EmbeddedQuery)
        }

        val attempts = mutableListOf<RelayDiscoveryAttempt>()
        val transports = forcedTransport?.let(::listOf)
            ?: transportOrder(descriptor, modelHint, apiKey)
        for (transport in transports) {
            for (candidate in RelayEndpointResolver.candidates(descriptor, transport)) {
                val requestUrl = RelayEndpointResolver.endpointUrl(
                    candidate.apiBaseUrl,
                    "/models",
                    requestedForPolicy.securityMode,
                )
                val snapshot = try {
                    executeWithRetry(HttpMethod.Get, requestUrl, apiKey, transport, null, requestedForPolicy)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    attempts += RelayDiscoveryAttempt(
                        candidate = candidate,
                        requestUrl = requestUrl,
                        statusCode = null,
                        failure = RelayDiscoveryFailureKind.Network,
                        upstreamMessage = networkFailureSummary(error),
                        retryCount = if (isTransientNetworkFailure(error)) retryBackoffMs.size else 0,
                    )
                    return result(descriptor, attempts, RelayDiscoveryFailureKind.Network)
                }

                when (snapshot.statusCode) {
                    in 200..299 -> {
                        val modelIDs = parseModelIDs(snapshot.body, transport)
                        if (modelIDs == null) {
                            attempts += attempt(candidate, requestUrl, snapshot, RelayDiscoveryFailureKind.InvalidResponse)
                            continue
                        }
                        attempts += attempt(candidate, requestUrl, snapshot, null)
                        val detectedTransports = if (
                            descriptor.explicitTransport == null &&
                            transport == RelayTransport.OpenAIChatCompletions
                        ) {
                            listOf(RelayTransport.OpenAIChatCompletions, RelayTransport.OpenAIResponses)
                        } else {
                            listOf(transport)
                        }
                        return RelayDiscoveryResult(
                            descriptor = descriptor,
                            detections = detectedTransports.map { detected ->
                                RelayDetectedConfiguration(
                                    transport = detected,
                                    authMode = resolveAuthMode(
                                        ChatRequestOptions(relayRequested = requestedForPolicy.copy(transport = detected)),
                                        detected,
                                    ),
                                    apiBaseUrl = candidate.apiBaseUrl,
                                    modelIDs = modelIDs,
                                    endpointEvidence = candidate.evidence,
                                    generationVerified = false,
                                )
                            },
                            attempts = attempts,
                            blockingFailure = null,
                        )
                    }
                    401, 403 -> {
                        attempts += attempt(candidate, requestUrl, snapshot, RelayDiscoveryFailureKind.AuthenticationRejected)
                        return result(descriptor, attempts, RelayDiscoveryFailureKind.AuthenticationRejected)
                    }
                    404, 405 -> attempts += attempt(
                        candidate,
                        requestUrl,
                        snapshot,
                        RelayDiscoveryFailureKind.RouteUnavailable,
                    )
                    429 -> {
                        attempts += attempt(candidate, requestUrl, snapshot, RelayDiscoveryFailureKind.RateLimited)
                        return result(descriptor, attempts, RelayDiscoveryFailureKind.RateLimited)
                    }
                    in 500..599 -> {
                        attempts += attempt(candidate, requestUrl, snapshot, RelayDiscoveryFailureKind.TemporaryFailure)
                        return result(descriptor, attempts, RelayDiscoveryFailureKind.TemporaryFailure)
                    }
                    else -> {
                        attempts += attempt(candidate, requestUrl, snapshot, RelayDiscoveryFailureKind.InvalidResponse)
                        return result(descriptor, attempts, RelayDiscoveryFailureKind.InvalidResponse)
                    }
                }
            }
        }

        if (includeGenerationProbe) {
            probeGenerationRoutes(descriptor, apiKey, modelHint, attempts, requestedForPolicy)?.let { return it }
        }
        val exhausted = if (attempts.any { it.failure == RelayDiscoveryFailureKind.InvalidResponse }) {
            RelayDiscoveryFailureKind.InvalidResponse
        } else {
            RelayDiscoveryFailureKind.RouteUnavailable
        }
        return result(descriptor, attempts, exhausted)
    }

    private suspend fun probeGenerationRoutes(
        descriptor: RelayEndpointDescriptor,
        apiKey: String,
        modelHint: String?,
        attempts: MutableList<RelayDiscoveryAttempt>,
        relayRequested: RelayRequestedConfig,
    ): RelayDiscoveryResult? {
        val userModel = modelHint?.trim().orEmpty()
        val usesUserModel = userModel.isNotEmpty()
        val modelID = userModel.ifEmpty { SENTINEL_PROBE_MODEL_ID }
        for (transport in probeTransportOrder(descriptor, modelHint, apiKey)) {
            val spec = probeSpec(transport, modelID) ?: continue
            for (candidate in RelayEndpointResolver.candidates(descriptor, transport)) {
                val requestUrl = RelayEndpointResolver.endpointUrl(
                    candidate.apiBaseUrl,
                    spec.first,
                    relayRequested.securityMode,
                )
                val snapshot = try {
                    executeWithRetry(HttpMethod.Post, requestUrl, apiKey, transport, spec.second, relayRequested)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    attempts += RelayDiscoveryAttempt(
                        candidate = candidate,
                        requestUrl = requestUrl,
                        statusCode = null,
                        failure = RelayDiscoveryFailureKind.Network,
                        kind = RelayDiscoveryAttemptKind.GenerationProbe,
                        upstreamMessage = networkFailureSummary(error),
                        retryCount = if (isTransientNetworkFailure(error)) retryBackoffMs.size else 0,
                    )
                    return result(descriptor, attempts, RelayDiscoveryFailureKind.Network)
                }

                fun record(failure: RelayDiscoveryFailureKind?) {
                    attempts += attempt(
                        candidate,
                        requestUrl,
                        snapshot,
                        failure,
                        RelayDiscoveryAttemptKind.GenerationProbe,
                    )
                }
                fun hit(verified: Boolean): RelayDiscoveryResult {
                    return RelayDiscoveryResult(
                        descriptor = descriptor,
                        detections = listOf(
                            RelayDetectedConfiguration(
                                transport = transport,
                                authMode = resolveAuthMode(
                                    ChatRequestOptions(relayRequested = relayRequested.copy(transport = transport)),
                                    transport,
                                ),
                                apiBaseUrl = candidate.apiBaseUrl,
                                modelIDs = emptyList(),
                                endpointEvidence = candidate.evidence,
                                generationVerified = verified,
                                detectionEvidence = RelayDetectionEvidence.GenerationProbe,
                            ),
                        ),
                        attempts = attempts,
                        blockingFailure = null,
                    )
                }

                when (snapshot.statusCode) {
                    in 200..299 -> {
                        if (!isRelayGenerationSuccessResponse(snapshot.body, snapshot.contentType)) {
                            record(RelayDiscoveryFailureKind.InvalidResponse)
                            continue
                        }
                        record(null)
                        return hit(usesUserModel)
                    }
                    400, 422 -> {
                        record(null)
                        return hit(false)
                    }
                    401, 403 -> {
                        record(RelayDiscoveryFailureKind.AuthenticationRejected)
                        return result(descriptor, attempts, RelayDiscoveryFailureKind.AuthenticationRejected)
                    }
                    429 -> {
                        record(RelayDiscoveryFailureKind.RateLimited)
                        return result(descriptor, attempts, RelayDiscoveryFailureKind.RateLimited)
                    }
                    in 500..599 -> {
                        record(RelayDiscoveryFailureKind.TemporaryFailure)
                        return result(descriptor, attempts, RelayDiscoveryFailureKind.TemporaryFailure)
                    }
                    else -> record(RelayDiscoveryFailureKind.RouteUnavailable)
                }
            }
        }
        return null
    }

    private suspend fun executeWithRetry(
        method: HttpMethod,
        requestUrl: String,
        apiKey: String,
        transport: RelayTransport,
        body: String?,
        relayRequested: RelayRequestedConfig,
    ): ResponseSnapshot {
        var lastError: Exception? = null
        for (attemptIndex in 0..retryBackoffMs.size) {
            try {
                return executeFollowingSameOriginRedirects(
                    method, requestUrl, apiKey, transport, body, relayRequested,
                )
                    .copy(retryCount = attemptIndex)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                lastError = error
                if (!isTransientNetworkFailure(error) || attemptIndex >= retryBackoffMs.size) throw error
                delay(retryBackoffMs[attemptIndex])
            }
        }
        throw lastError ?: IllegalStateException("Relay request failed")
    }

    private suspend fun executeFollowingSameOriginRedirects(
        method: HttpMethod,
        requestUrl: String,
        apiKey: String,
        transport: RelayTransport,
        body: String?,
        relayRequested: RelayRequestedConfig,
    ): ResponseSnapshot {
        val requestOptions = ChatRequestOptions(relayRequested = relayRequested.copy(transport = transport))
        val authMode = resolveAuthMode(requestOptions, transport)
        val requestQuery = buildRelayQueryPairs(
            protocolQuery = emptyList(),
            requested = relayRequested,
            authMode = authMode,
            apiKey = apiKey.takeIf { authMode == RelayAuthMode.QueryKey },
            includeCustomQuery = true,
        )
        val requestWithQuery = appendQuery(requestUrl, requestQuery)
        val original = URI(requestWithQuery)
        var current = original
        repeat(5) {
            val response = client.request(current.toASCIIString()) {
                this.method = method
                timeout { requestTimeoutMillis = REQUEST_TIMEOUT_MS }
                accept(ContentType.Application.Json)
                applyRelayHeaders(apiKey.trim(), requestOptions, transport)
                if (body != null) {
                    contentType(ContentType.Application.Json)
                    setBody(body)
                }
            }
            val responseBody = response.bodyAsText()
            if (response.status.value !in 300..399) {
                return ResponseSnapshot(response.status.value, responseBody, response.contentType()?.toString())
            }
            val location = response.headers[HttpHeaders.Location]
                ?: return ResponseSnapshot(response.status.value, responseBody, response.contentType()?.toString())
            val redirected = current.resolve(location)
            if (!sameOrigin(original, redirected)) {
                return ResponseSnapshot(response.status.value, responseBody, response.contentType()?.toString())
            }
            current = redirected
        }
        return ResponseSnapshot(310, "Too many redirects")
    }

    private fun appendQuery(url: String, pairs: List<Pair<String, String>>): String {
        if (pairs.isEmpty()) return url
        val encoded = pairs.joinToString("&") { (key, value) ->
            "${URLEncoder.encode(key, StandardCharsets.UTF_8.name())}=" +
                URLEncoder.encode(value, StandardCharsets.UTF_8.name())
        }
        return "$url${if ('?' in url) "&" else "?"}$encoded"
    }

    private fun parseModelIDs(body: String, transport: RelayTransport): List<String>? {
        val root = runCatching { json.parseToJsonElement(body) }.getOrNull() ?: return null
        val items = when (root) {
            is JsonArray -> root
            is JsonObject -> {
                val preferred = if (transport == RelayTransport.GeminiGenerateContent) root["models"] else root["data"]
                (preferred ?: root["models"]) as? JsonArray
            }
            else -> null
        } ?: return null
        val seen = linkedSetOf<String>()
        items.forEach { item ->
            val raw = when (item) {
                is JsonPrimitive -> item.contentOrNull
                is JsonObject -> item["id"]?.jsonPrimitive?.contentOrNull
                    ?: item["name"]?.jsonPrimitive?.contentOrNull
                else -> null
            }?.trim().orEmpty()
            if (raw.isNotEmpty()) {
                val normalized = if (
                    transport == RelayTransport.GeminiGenerateContent && raw.startsWith("models/")
                ) raw.removePrefix("models/") else raw
                seen += normalized
            }
        }
        return seen.toList()
    }

    private fun transportOrder(
        descriptor: RelayEndpointDescriptor,
        modelHint: String?,
        apiKey: String,
    ): List<RelayTransport> {
        descriptor.explicitTransport?.let { return listOf(it) }
        val hint = modelHint?.trim()?.lowercase().orEmpty()
        val key = apiKey.trim().lowercase()
        return when {
            descriptor.explicitVersion == "v1beta" || "gemini" in hint || key.startsWith("aiza") ->
                listOf(RelayTransport.GeminiGenerateContent, RelayTransport.OpenAIChatCompletions, RelayTransport.AnthropicMessages)
            "claude" in hint || key.startsWith("sk-ant-") ->
                listOf(RelayTransport.AnthropicMessages, RelayTransport.OpenAIChatCompletions, RelayTransport.GeminiGenerateContent)
            else -> listOf(RelayTransport.OpenAIChatCompletions, RelayTransport.AnthropicMessages, RelayTransport.GeminiGenerateContent)
        }
    }

    private fun probeTransportOrder(
        descriptor: RelayEndpointDescriptor,
        modelHint: String?,
        apiKey: String,
    ): List<RelayTransport> {
        descriptor.explicitTransport?.let { return listOf(it) }
        val ordered = transportOrder(descriptor, modelHint, apiKey).toMutableList()
        val chatIndex = ordered.indexOf(RelayTransport.OpenAIChatCompletions)
        ordered.add(if (chatIndex >= 0) chatIndex + 1 else ordered.size, RelayTransport.OpenAIResponses)
        return ordered
    }

    private fun probeSpec(transport: RelayTransport, modelID: String): Pair<String, String>? {
        val body = when (transport) {
            RelayTransport.LlamaCppNative -> buildJsonObject {
                put("prompt", "ping")
                put("n_predict", 1)
            }
            RelayTransport.OpenAIChatCompletions -> buildJsonObject {
                put("model", modelID)
                put("messages", buildJsonArray { add(buildJsonObject { put("role", "user"); put("content", "ping") }) })
                put("max_tokens", 1)
            }
            RelayTransport.OpenAIResponses -> buildJsonObject {
                put("model", modelID); put("input", "ping"); put("max_output_tokens", 1); put("store", false)
            }
            RelayTransport.AnthropicMessages -> buildJsonObject {
                put("model", modelID); put("max_tokens", 1)
                put("messages", buildJsonArray { add(buildJsonObject { put("role", "user"); put("content", "ping") }) })
            }
            RelayTransport.GeminiGenerateContent -> buildJsonObject {
                put("contents", buildJsonArray {
                    add(buildJsonObject {
                        put("role", "user")
                        put("parts", buildJsonArray { add(buildJsonObject { put("text", "ping") }) })
                    })
                })
                put("generationConfig", buildJsonObject { put("maxOutputTokens", 1) })
            }
            RelayTransport.Auto -> return null
        }
        val path = when (transport) {
            RelayTransport.LlamaCppNative -> "/completion"
            RelayTransport.OpenAIChatCompletions -> "/chat/completions"
            RelayTransport.OpenAIResponses -> "/responses"
            RelayTransport.AnthropicMessages -> "/messages"
            RelayTransport.GeminiGenerateContent -> "/models/$modelID:generateContent"
            RelayTransport.Auto -> return null
        }
        return path to body.toString()
    }

    private fun defaultAuthMode(transport: RelayTransport): RelayAuthMode = when (transport) {
        RelayTransport.LlamaCppNative -> RelayAuthMode.None
        RelayTransport.AnthropicMessages -> RelayAuthMode.XApiKey
        RelayTransport.GeminiGenerateContent -> RelayAuthMode.XGoogApiKey
        else -> RelayAuthMode.Bearer
    }

    private fun attempt(
        candidate: RelayEndpointCandidate,
        requestUrl: String,
        snapshot: ResponseSnapshot,
        failure: RelayDiscoveryFailureKind?,
        kind: RelayDiscoveryAttemptKind = RelayDiscoveryAttemptKind.Catalog,
    ) = RelayDiscoveryAttempt(
        candidate = candidate,
        requestUrl = requestUrl,
        statusCode = snapshot.statusCode,
        failure = failure,
        kind = kind,
        upstreamMessage = upstreamSummary(snapshot.body),
        retryCount = snapshot.retryCount,
    )

    private fun result(
        descriptor: RelayEndpointDescriptor,
        attempts: List<RelayDiscoveryAttempt>,
        failure: RelayDiscoveryFailureKind,
    ) = RelayDiscoveryResult(descriptor, emptyList(), attempts.toList(), failure)

    private fun invalidEndpointResult(
        endpoint: String,
        failure: RelayDiscoveryFailureKind = RelayDiscoveryFailureKind.InvalidEndpoint,
    ): RelayDiscoveryResult {
        val safe = RelayEndpointDescriptor(endpoint.trim(), "", "", null, null, false, false)
        return RelayDiscoveryResult(safe, emptyList(), emptyList(), failure)
    }

    private fun isTransientNetworkFailure(error: Throwable): Boolean {
        if (error is SSLException) return false
        return error is HttpRequestTimeoutException ||
            error is SocketTimeoutException ||
            error is UnknownHostException ||
            error is ConnectException ||
            error is EOFException ||
            error is SocketException ||
            error.cause?.let(::isTransientNetworkFailure) == true
    }

    private fun networkFailureSummary(error: Throwable): String {
        val root = generateSequence(error) { it.cause }.last()
        return root.localizedMessage?.takeIf { it.isNotBlank() } ?: root::class.java.simpleName
    }

    private fun upstreamSummary(body: String, limit: Int = 300): String? {
        val condensed = body.lineSequence().map(String::trim).filter(String::isNotEmpty).joinToString(" ").trim()
        if (condensed.isEmpty()) return null
        return if (condensed.length <= limit) condensed else condensed.take(limit) + "..."
    }

    private fun sameOrigin(lhs: URI, rhs: URI): Boolean =
        lhs.scheme.equals(rhs.scheme, ignoreCase = true) &&
            lhs.host.equals(rhs.host, ignoreCase = true) &&
            effectivePort(lhs) == effectivePort(rhs)

    private fun effectivePort(uri: URI): Int = when {
        uri.port >= 0 -> uri.port
        uri.scheme.equals("https", ignoreCase = true) -> 443
        else -> 80
    }

    private data class ResponseSnapshot(
        val statusCode: Int,
        val body: String,
        val contentType: String? = null,
        val retryCount: Int = 0,
    )
}
