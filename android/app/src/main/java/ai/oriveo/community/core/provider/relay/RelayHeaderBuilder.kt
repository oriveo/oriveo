package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.http.HttpHeaders
import java.util.UUID

internal object RelayHeaderBuilder {
    private const val DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
    private const val CODEX_CLI_VERSION = "0.50.0"
    private const val CODEX_ORIGINATOR = "codex_cli_rs"
    private const val CODEX_OPENAI_BETA = "responses=experimental"

    fun HttpRequestBuilder.applyRelayHeaders(
        apiKey: String,
        requestOptions: ChatRequestOptions,
        transport: RelayTransport,
    ) {
        header("Accept", "application/json")
        headers.remove(RELAY_SECURITY_MODE_HEADER)
        headers.remove(RELAY_CERTIFICATE_FINGERPRINT_HEADER)
        header(
            RELAY_SECURITY_MODE_HEADER,
            requestOptions.relayRequested?.securityMode?.value ?: "remote_https",
        )
        requestOptions.relayRequested?.certificateFingerprint?.let {
            header(RELAY_CERTIFICATE_FINGERPRINT_HEADER, it)
        }
        val authMode = resolveAuthMode(requestOptions, transport)
        when (authMode) {
            RelayAuthMode.None -> Unit
            RelayAuthMode.XApiKey -> header("x-api-key", apiKey)
            RelayAuthMode.XGoogApiKey -> header("x-goog-api-key", apiKey)
            RelayAuthMode.QueryKey -> Unit
            RelayAuthMode.Bearer,
            RelayAuthMode.Auto,
            -> header("Authorization", "Bearer $apiKey")
        }
        if (transport == RelayTransport.AnthropicMessages) {
            header("anthropic-version", DEFAULT_ANTHROPIC_VERSION)
        }
        if (authMode == RelayAuthMode.None) return
        codexIdentityHeaders(transport, requestOptions.relayRequested?.codexCompatIdentity)
            .forEach { (name, value) ->
                headers.remove(name)
                header(name, value)
            }
        requestOptions.relayRequested?.customUserAgent
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { userAgent ->
                headers.remove(HttpHeaders.UserAgent)
                header(HttpHeaders.UserAgent, userAgent)
            }
        requestOptions.relayRequested?.headers.orEmpty().forEach { relayHeader ->
            headers.remove(relayHeader.key)
            header(relayHeader.key, relayHeader.value)
        }
    }

    fun codexIdentityHeaders(
        transport: RelayTransport,
        codexCompatIdentity: Boolean?,
    ): Map<String, String> {
        if (codexCompatIdentity == false) return emptyMap()
        if (RelayRuntimeSupport.codexIdentityDefault(transport)) {
            return mapOf(
                HttpHeaders.UserAgent to "codex_cli_rs/$CODEX_CLI_VERSION (Oriveo Android)",
                "Originator" to CODEX_ORIGINATOR,
                "session_id" to UUID.randomUUID().toString(),
                "OpenAI-Beta" to CODEX_OPENAI_BETA,
            )
        }
        return emptyMap()
    }

    fun resolveAuthMode(requestOptions: ChatRequestOptions, transport: RelayTransport): RelayAuthMode {
        requestOptions.relayRequested?.authMode
            ?.takeIf { it != RelayAuthMode.Auto }
            ?.let { return it }
        RelayRuntimeSupport.defaultAuthMode(transport)?.let { raw ->
            relayAuthModeFromRuntime(raw)?.let { return it }
        }
        return when (transport) {
            RelayTransport.LlamaCppNative -> RelayAuthMode.None
            RelayTransport.AnthropicMessages -> RelayAuthMode.XApiKey
            RelayTransport.GeminiGenerateContent -> RelayAuthMode.XGoogApiKey
            RelayTransport.OpenAIResponses,
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.Auto,
            -> RelayAuthMode.Bearer
        }
    }

    fun relayAuthModeFromRuntime(raw: String): RelayAuthMode? {
        return when (raw) {
            "bearer" -> RelayAuthMode.Bearer
            "none" -> RelayAuthMode.None
            "x_api_key" -> RelayAuthMode.XApiKey
            "x_goog_api_key" -> RelayAuthMode.XGoogApiKey
            "query_key" -> RelayAuthMode.QueryKey
            else -> null
        }
    }
}
