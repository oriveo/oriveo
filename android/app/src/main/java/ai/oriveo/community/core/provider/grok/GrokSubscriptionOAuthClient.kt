package ai.oriveo.community.core.provider.grok

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.URLEncoder

/**
 * One subscription model together with the capabilities upstream declares for it.
 *
 * It carries only facts upstream states outright; anything not declared stays empty and is
 * never guessed from the model id, since local inference like that is forbidden. Capabilities
 * follow the API, so a newly launched model needs nobody to patch client code.
 */
data class GrokModelDescriptor(
    val id: String,
    val displayName: String? = null,
    val supportsWebSearch: Boolean = false,
    val supportsReasoning: Boolean = false,
    val reasoningEfforts: List<String> = emptyList(),
    val defaultReasoningEffort: String? = null,
    val contextWindow: Int? = null,
    val apiBackend: String? = null,
)

/** Upstream's answer to one device code authorization request. */
data class GrokDeviceAuthorization(
    val deviceCode: String,
    val userCode: String,
    /**
     * Authorization page address with the short code already folded into the query, so
     * the user does not have to copy the 8-digit code by hand.
     */
    val verificationUrl: String,
    val expiresIn: Int,
    /** The polling interval upstream asks for; falls back to the configured value when absent. */
    val interval: Int?,
)

/**
 * Subscription credentials held on this device. They stay local and are never uploaded,
 * matching how the existing apiKey is handled (the BYOK principle).
 */
@Serializable
data class GrokSubscriptionTokens(
    val accessToken: String,
    val refreshToken: String? = null,
    /**
     * Upstream sends `expires_in` as a number of seconds; it is converted to an absolute
     * instant (epoch millis) on the way to disk. Absent means upstream did not say, which is
     * treated as "never refresh proactively".
     */
    val expiresAt: Long? = null,
    val scopes: String? = null,
    val obtainedAt: Long = 0L,
) {
    /**
     * Whether it is time to refresh proactively.
     *
     * Refreshing 5 minutes early avoids the window where a token is still valid at check
     * time but expires just as the request reaches upstream - that shows up as a random 401
     * rather than as one predictable refresh.
     */
    fun needsRefresh(now: Long, leewayMillis: Long = DEFAULT_REFRESH_LEEWAY_MS): Boolean {
        val expiry = expiresAt ?: return false
        return now + leewayMillis >= expiry
    }

    companion object {
        const val DEFAULT_REFRESH_LEEWAY_MS: Long = 5 * 60 * 1000L
    }
}

/**
 * The failure meanings along the subscription sign-in route.
 *
 * The four kinds of failure call for completely different remedies. Reporting a blanket
 * "network error" would present "your subscription tier does not cover this" as a fault on
 * our side and push the user in the wrong direction; see the comment on each case.
 */
sealed class GrokSubscriptionError {
    /**
     * Upstream is still waiting for the user to authorize in the browser - a normal
     * intermediate state, so keep polling.
     */
    data object AuthorizationPending : GrokSubscriptionError()

    /** Upstream thinks we are polling too fast and the interval has to grow (RFC 8628). */
    data object SlowDown : GrokSubscriptionError()

    /** The device code went past its `expires_in` without being authorized. */
    data object CodeExpired : GrokSubscriptionError()

    /** The user pressed Deny on the authorization page. */
    data object AccessDenied : GrokSubscriptionError()

    /**
     * HTTP 426: the client version is below xAI's current floor. This is the single early
     * signal that xAI changed something again, so it has to be reported on its own and has
     * to force a configuration refresh; otherwise the only way out is waiting for the 24h
     * cache to expire on its own.
     */
    data object ClientVersionRejected : GrokSubscriptionError()

    /**
     * HTTP 403: the account is not on the allowlist, or the subscription tier does not
     * cover third-party apps. Not our fault, and not retryable.
     */
    data object SubscriptionNotEligible : GrokSubscriptionError()

    /**
     * HTTP 401: the token is invalid. Try one automatic refresh first, and only demand a
     * fresh sign-in when that fails too.
     */
    data object Unauthorized : GrokSubscriptionError()

    /** HTTP 429: this week's usage pool is spent. Do not retry. */
    data object QuotaExhausted : GrokSubscriptionError()

    /** The configuration is missing or invalid, including failing host allow-list checks. */
    data object ConfigurationUnavailable : GrokSubscriptionError()

    data class Transport(val detail: String) : GrokSubscriptionError()

    data class Upstream(val status: Int, val body: String) : GrokSubscriptionError()

    /**
     * Whether this signals that xAI changed something.
     *
     * 426 is the only early signal: receiving it means the configured client version has
     * fallen below upstream's floor. Besides reporting it, the catalog must be force
     * refreshed straight away - the client snapshot has a 24h TTL and refreshes only in the
     * background on a cache hit, so simply waiting for it to expire would leave users up to
     * a day behind a corrected configuration.
     */
    val requiresConfigRefresh: Boolean get() = this is ClientVersionRejected

    /**
     * Whether trying again could plausibly succeed.
     *
     * Only failures where a retry can actually work get a retry button: an unsupported
     * subscription tier is a dead end, and offering a button there just invites the user to
     * tap it over and over for nothing.
     */
    val allowsRetry: Boolean
        get() = when (this) {
            is CodeExpired, is AccessDenied, is Transport, is Upstream,
            is AuthorizationPending, is SlowDown,
            -> true

            is ClientVersionRejected, is SubscriptionNotEligible, is Unauthorized,
            is QuotaExhausted, is ConfigurationUnavailable,
            -> false
        }
}

/** Carrier that lets a [GrokSubscriptionError] travel across a suspend boundary as an exception. */
class GrokSubscriptionException(val error: GrokSubscriptionError) : Exception(error.toString())

/**
 * The pure networking layer of the xAI OAuth device code flow.
 *
 * It touches no UI, no storage and holds no retry policy - those belong to the state
 * machine, [GrokSubscriptionCredentialStore] and the caller respectively. All this does is
 * send requests using the supplied parameters and translate upstream's answer into a
 * definite meaning.
 */
class GrokSubscriptionOAuthClient(
    private val client: HttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true }

    /** Step one: request a device code and get the authorization page address to show. */
    suspend fun requestDeviceAuthorization(
        config: GrokSubscriptionAuthConfig,
    ): GrokDeviceAuthorization {
        val (status, body) = send {
            client.post(config.deviceAuthorizationEndpoint) {
                header("Accept", "application/json")
                contentType(ContentType.Application.FormUrlEncoded)
                setBody(
                    formBody(
                        "client_id" to config.clientId,
                        "scope" to config.scopes,
                    )
                )
            }
        }
        if (status != 200) throw GrokSubscriptionException(mapFailure(status, body))

        val payload = runCatching { json.decodeFromString<DeviceCodeResponse>(body) }.getOrNull()
            ?: throw GrokSubscriptionException(GrokSubscriptionError.Upstream(status, snippet(body)))
        val verification = payload.verificationUriComplete ?: payload.verificationUri
        if (payload.deviceCode.isBlank() || !config.allowsVerificationUrl(verification)) {
            // An authorization page outside the trusted host set counts as an unusable
            // configuration: better to do nothing than to send the user to a domain of
            // unknown origin.
            throw GrokSubscriptionException(GrokSubscriptionError.ConfigurationUnavailable)
        }

        return GrokDeviceAuthorization(
            deviceCode = payload.deviceCode,
            userCode = payload.userCode.orEmpty(),
            verificationUrl = verification!!.trim(),
            expiresIn = payload.expiresIn ?: config.pollTimeoutSeconds,
            interval = payload.interval,
        )
    }

    /**
     * Step two: poll the token endpoint once.
     *
     * One request, one translation of the result. `authorization_pending` / `slow_down` are
     * thrown as errors and it is up to the caller to decide whether to keep waiting or back
     * off - pacing lives in the state machine so this layer stays stateless.
     */
    suspend fun pollToken(
        config: GrokSubscriptionAuthConfig,
        deviceCode: String,
    ): GrokSubscriptionTokens {
        val (status, body) = send {
            client.post(config.tokenEndpoint) {
                header("Accept", "application/json")
                contentType(ContentType.Application.FormUrlEncoded)
                setBody(
                    formBody(
                        "grant_type" to DEVICE_CODE_GRANT,
                        "device_code" to deviceCode,
                        "client_id" to config.clientId,
                    )
                )
            }
        }
        if (status != 200) throw GrokSubscriptionException(mapFailure(status, body))
        return decodeTokens(body)
    }

    /**
     * Exchanges a refresh token for a fresh access token.
     *
     * xAI rotates refresh_token on every refresh (confirmed by measurement), so the return
     * value has to be written back to storage as a whole. Keeping only the access token
     * would leave the next renewal holding an already-revoked refresh token.
     */
    suspend fun refreshTokens(
        config: GrokSubscriptionAuthConfig,
        refreshToken: String,
    ): GrokSubscriptionTokens {
        val (status, body) = send {
            client.post(config.tokenEndpoint) {
                header("Accept", "application/json")
                contentType(ContentType.Application.FormUrlEncoded)
                setBody(
                    formBody(
                        "grant_type" to "refresh_token",
                        "refresh_token" to refreshToken,
                        "client_id" to config.clientId,
                    )
                )
            }
        }
        if (status != 200) throw GrokSubscriptionException(mapFailure(status, body))
        val tokens = decodeTokens(body)
            // Some implementations omit refresh_token on a refresh; keep the old one in
            // that case, otherwise the ability to renew at all gets refreshed away.
        return if (tokens.refreshToken == null) tokens.copy(refreshToken = refreshToken) else tokens
    }

    /**
     * Fetches the model directory for the subscription route.
     *
     * The API-key catalog cannot stand in for it: when this was measured the subscription
     * route accepted only `grok-4.6` / `grok-4.5`, while the API-key catalog carried
     * `grok-4.3` / `grok-code-fast-1`. Filling a subscription instance from the latter means
     * the model the user picked does not exist on this route at all and the very first
     * message fails.
     */
    suspend fun fetchModels(
        config: GrokSubscriptionAuthConfig,
        accessToken: String,
    ): List<GrokModelDescriptor> {
        val (status, body) = send {
            client.get(config.modelsUrl) {
                header("Accept", "application/json")
                header("Authorization", "Bearer $accessToken")
                config.requiredHeaders.forEach { (name, value) -> header(name, value) }
            }
        }
        if (status != 200) throw GrokSubscriptionException(mapFailure(status, body))
        return parseModelDescriptors(body)
    }

    /**
     * Parses the subscription directory along with the per-model capabilities upstream
     * declares.
     *
     * The filter is deliberately lenient (`hidden != true && supportedInApi != false`).
     * Whether those two fields are even present in this response has not been confirmed by
     * measurement, and requiring them to be true would filter the entire directory down to
     * nothing the moment one goes missing - a far worse regression than lacking a capability
     * flag. They take effect when present and are waved through when absent.
     */
    fun parseModelDescriptors(body: String): List<GrokModelDescriptor> {
        val payload = runCatching { json.decodeFromString<ModelsResponse>(body) }.getOrNull()
            ?: throw GrokSubscriptionException(GrokSubscriptionError.Upstream(200, snippet(body)))
        return payload.data
            .filter { it.id.isNotBlank() && it.hidden != true && it.supportedInApi != false }
            .map { item ->
                val efforts = item.reasoningEfforts.orEmpty()
                    .mapNotNull { it.value }
                    .filter { it.isNotBlank() }
                GrokModelDescriptor(
                    id = item.id,
                    displayName = item.name,
                    supportsWebSearch = item.supportsBackendSearch ?: false,
                    // Either source being true means supported: some models only report
                    // supports_reasoning_effort, others only a reasoning_efforts list.
                    supportsReasoning = (item.supportsReasoningEffort ?: false) || efforts.isNotEmpty(),
                    reasoningEfforts = efforts,
                    defaultReasoningEffort = item.reasoningEfforts.orEmpty()
                        .firstOrNull { it.default == true }?.value,
                    contextWindow = item.contextWindow,
                    apiBackend = item.apiBackend?.trim(),
                )
            }
    }

    /**
     * Tells upstream to revoke on disconnect. A failure here does not block the local
     * delete: the local credential must go, otherwise the user presses Disconnect and this
     * device still holds a usable token.
     */
    suspend fun revoke(config: GrokSubscriptionAuthConfig, token: String) {
        val endpoint = config.revocationEndpoint ?: return
        runCatching {
            client.post(endpoint) {
                contentType(ContentType.Application.FormUrlEncoded)
                setBody(formBody("token" to token, "client_id" to config.clientId))
            }
        }
    }

    // --- Internals ---

    private suspend inline fun send(block: () -> HttpResponse): Pair<Int, String> {
        val response = try {
            block()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            throw GrokSubscriptionException(
                GrokSubscriptionError.Transport(e.message ?: e::class.java.simpleName)
            )
        }
        val body = runCatching { response.bodyAsText() }.getOrDefault("")
        return response.status.value to body
    }

    private fun decodeTokens(body: String): GrokSubscriptionTokens {
        val payload = runCatching { json.decodeFromString<TokenResponse>(body) }.getOrNull()
        if (payload == null || payload.accessToken.isBlank()) {
            throw GrokSubscriptionException(GrokSubscriptionError.Upstream(200, snippet(body)))
        }
        val now = System.currentTimeMillis()
        return GrokSubscriptionTokens(
            accessToken = payload.accessToken,
            refreshToken = payload.refreshToken,
            expiresAt = payload.expiresIn?.let { now + it * 1000L },
            scopes = payload.scope,
            obtainedAt = now,
        )
    }

    @Serializable
    private data class DeviceCodeResponse(
        @SerialName("device_code") val deviceCode: String = "",
        @SerialName("user_code") val userCode: String? = null,
        @SerialName("verification_uri") val verificationUri: String? = null,
        @SerialName("verification_uri_complete") val verificationUriComplete: String? = null,
        @SerialName("expires_in") val expiresIn: Int? = null,
        val interval: Int? = null,
    )

    @Serializable
    private data class TokenResponse(
        @SerialName("access_token") val accessToken: String = "",
        @SerialName("refresh_token") val refreshToken: String? = null,
        @SerialName("expires_in") val expiresIn: Int? = null,
        val scope: String? = null,
    )

    @Serializable
    private data class ErrorResponse(val error: String? = null)

    // The capability field names come from the directory cache the grok CLI writes to disk
    // (its origin is cli-chat-proxy.grok.com/v1/models, with a grok_version matching the
    // x-grok-client-version we send), so this is the same endpoint serving the same data.
    // The CLI reshapes the response and it is not certain which level each field hangs off,
    // hence everything is nullable: whatever cannot be read degrades to "not declared",
    // which behaves exactly as it did before the field existed. If upstream supplies it,
    // it takes effect automatically and a new model needs no code change.
    @Serializable
    private data class ModelsResponse(val data: List<Item> = emptyList()) {
        @Serializable
        data class Item(
            val id: String = "",
            val name: String? = null,
            @SerialName("supports_backend_search") val supportsBackendSearch: Boolean? = null,
            @SerialName("supports_reasoning_effort") val supportsReasoningEffort: Boolean? = null,
            @SerialName("reasoning_efforts") val reasoningEfforts: List<ReasoningEffort>? = null,
            @SerialName("context_window") val contextWindow: Int? = null,
            @SerialName("api_backend") val apiBackend: String? = null,
            val hidden: Boolean? = null,
            @SerialName("supported_in_api") val supportedInApi: Boolean? = null,
        )

        @Serializable
        data class ReasoningEffort(
            val value: String? = null,
            val default: Boolean? = null,
        )
    }

    companion object {
        const val DEVICE_CODE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

        private val errorJson = Json { ignoreUnknownKeys = true }

        /**
         * Translates an HTTP status plus an OAuth error code into a definite meaning.
         *
         * The device code flow expresses its intermediate states (pending / slow_down) as
         * 400 plus an error code, so the status alone is not enough: reading a bare 400 as
         * failure would treat "the user has not tapped Authorize yet" as permanent and the
         * flow could never complete.
         */
        fun mapFailure(status: Int, body: String): GrokSubscriptionError {
            val code = runCatching { errorJson.decodeFromString<ErrorResponse>(body) }
                .getOrNull()?.error?.lowercase()
            when (code) {
                "authorization_pending" -> return GrokSubscriptionError.AuthorizationPending
                "slow_down" -> return GrokSubscriptionError.SlowDown
                "expired_token" -> return GrokSubscriptionError.CodeExpired
                "access_denied" -> return GrokSubscriptionError.AccessDenied
            }
            return when (status) {
                401 -> GrokSubscriptionError.Unauthorized
                403 -> GrokSubscriptionError.SubscriptionNotEligible
                426 -> GrokSubscriptionError.ClientVersionRejected
                429 -> GrokSubscriptionError.QuotaExhausted
                else -> GrokSubscriptionError.Upstream(status, snippet(body))
            }
        }

        private fun snippet(body: String): String = body.take(400)

        private fun formBody(vararg fields: Pair<String, String>): String =
            fields.joinToString("&") { (name, value) ->
                "${URLEncoder.encode(name, "UTF-8")}=${URLEncoder.encode(value, "UTF-8")}"
            }
    }
}
