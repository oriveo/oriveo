package ai.oriveo.community.core.provider.openai

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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.net.URLEncoder
import java.util.Base64

/**
 * One Codex subscription model together with the capabilities upstream declares for it.
 *
 * Subscription models are not in the metadata catalog and will never have a published
 * capability recipe, but that does not mean they have to be treated as capability-less: Codex's
 * own `/models` response declares `web_search_tool_type`, `supported_reasoning_levels` and
 * `input_modalities` per model. Consuming those fields is not guessing from a model id; it is
 * an explicit statement by upstream, and on this path it is the only legitimate authority on
 * capability. Anything upstream does not declare stays empty. Never infer from the slug.
 */
data class CodexModelDescriptor(
    val slug: String,
    val displayName: String? = null,
    val supportsWebSearch: Boolean = false,
    val supportedReasoningLevels: List<String> = emptyList(),
    val defaultReasoningLevel: String? = null,
    val supportsImageInput: Boolean = false,
    val contextWindow: Int? = null,
) {
    val supportsReasoning: Boolean get() = supportedReasoningLevels.isNotEmpty()
}

/**
 * The Codex subscription credentials held on this device. They stay local and are never synced
 * anywhere, matching how API keys are already handled.
 *
 * [accountId] is the mandatory `chatgpt-account-id` header: it is decoded from the JWT during
 * the token exchange and checked to be non-empty there, and every later use takes that
 * already-resolved value rather than going looking for it again.
 */
@Serializable
data class OpenAISubscriptionTokens(
    val accessToken: String,
    val refreshToken: String? = null,
    val idToken: String? = null,
    /**
     * Absolute expiry instant in epoch millis. Absent means upstream did not say, which is
     * treated as "never refresh proactively".
     */
    val expiresAt: Long? = null,
    val accountId: String,
    val planType: String? = null,
    val obtainedAt: Long = 0L,
) {
    /**
     * Whether it is time to refresh proactively.
     *
     * Refreshing five minutes early avoids the window where a token is still valid at check
     * time but has expired by the moment the request reaches upstream. That shows up as random
     * 401s instead of one predictable refresh.
     */
    fun needsRefresh(now: Long, leewayMillis: Long = DEFAULT_REFRESH_LEEWAY_MS): Boolean {
        val expiry = expiresAt ?: return false
        return now + leewayMillis >= expiry
    }

    companion object {
        const val DEFAULT_REFRESH_LEEWAY_MS: Long = 5 * 60 * 1000L
    }
}

/** The upstream receipt for the first-leg device code authorization request. */
data class OpenAIDeviceAuthorization(
    val deviceAuthId: String,
    val userCode: String,
    /**
     * The authorization page address, taken from the published configuration and already
     * checked against the host allowlist. Codex does not return a `verification_uri_complete`.
     */
    val verificationUrl: String,
    /** The polling interval upstream asks for; falls back to the published value when absent. */
    val interval: Int,
    /**
     * Lifetime of the short code in seconds. When absent the published `pollTimeoutSeconds`
     * stands in, since polling past expiry is nothing but wasted traffic.
     */
    val expiresIn: Int,
)

/**
 * The receipt of a successful first-leg poll. This is *not* a token but the pair of values the
 * PKCE exchange needs.
 */
data class CodexAuthorizationGrant(
    val authorizationCode: String,
    val codeVerifier: String,
)

/**
 * The failure semantics of the Codex subscription sign-in path.
 *
 * The four hard failures call for completely different actions by the user, and flattening them
 * into "network error" turns "your subscription plan does not cover this" into what looks like
 * our own outage and sends the user in the wrong direction. Once, the real cause was that
 * chatgpt.com was unreachable; hidden behind one generic message it cost three rounds of
 * editing code that had been correct all along.
 */
sealed class OpenAISubscriptionError {
    /** Upstream is still waiting for the user to approve in the browser. Keep polling. */
    data object AuthorizationPending : OpenAISubscriptionError()

    /** Upstream considers our polling too fast and requires a longer interval (RFC 8628). */
    data object SlowDown : OpenAISubscriptionError()

    /** The device code went past its `expires_in` without being authorized. */
    data object CodeExpired : OpenAISubscriptionError()

    /** The user pressed deny on the authorization page. */
    data object AccessDenied : OpenAISubscriptionError()

    /**
     * HTTP 426: the published `version` has fallen below the Codex backend's floor. This is the
     * only early signal that OpenAI has changed something, so it must be reported separately and
     * must force a configuration refresh; otherwise recovery waits for the 24h cache to expire
     * on its own.
     */
    data object ClientVersionRejected : OpenAISubscriptionError()

    /**
     * HTTP 403 / `usage_not_included`: the account's plan does not allow using Codex from a
     * third-party app. Not our failure.
     */
    data object SubscriptionNotEligible : OpenAISubscriptionError()

    /** HTTP 401: the token is invalid. Refresh once automatically; only ask for a fresh sign-in if that fails. */
    data object Unauthorized : OpenAISubscriptionError()

    /** HTTP 429 / `usage_limit_reached`: the Codex allowance for this period is spent. Do not retry. */
    data object QuotaExhausted : OpenAISubscriptionError()

    /** The published configuration is missing or invalid, including failing host allowlist checks. */
    data object ConfigurationUnavailable : OpenAISubscriptionError()

    data class Transport(val detail: String) : OpenAISubscriptionError()

    data class Upstream(val status: Int, val body: String) : OpenAISubscriptionError()

    /**
     * Whether this signals that OpenAI has changed something.
     *
     * 426 is the only early signal: receiving it means the published `version` is below
     * upstream's floor. Beyond reporting it, the catalog snapshot has to be force-refreshed
     * right away. The client snapshot has a 24h TTL and only refreshes in the background on a
     * cache hit, so waiting for natural expiry would leave users broken for up to a day after
     * the configuration was already fixed.
     */
    val requiresConfigRefresh: Boolean get() = this is ClientVersionRejected

    /**
     * Whether trying again could plausibly succeed.
     *
     * Only failures where a retry can actually work get a retry button. Something like an
     * ineligible plan is a dead end, and offering a button there just invites the user to tap
     * it over and over for nothing.
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

/** Carries an [OpenAISubscriptionError] across a suspend boundary as an exception. */
class OpenAISubscriptionException(val error: OpenAISubscriptionError) : Exception(error.toString())

/**
 * Reads claims out of a Codex JWT.
 *
 * Anything that fails to decode returns null and never throws: a bad token should make one
 * credential unusable, not blow up the whole flow.
 */
object OpenAIJwtClaims {

    /** ChatGPT account information hangs off this namespaced claim in the id_token, not the top level. */
    private const val AUTH_CLAIM_NAMESPACE = "https://api.openai.com/auth"

    /**
     * Reads a string claim, checking the top level first and then the namespace.
     *
     * `chatgpt_account_id` actually lives under the namespace, and only the id_token is
     * guaranteed to carry it; the access token is not. Decoding it from the access token
     * instead has gone wrong before, showing up as a sign-in that succeeds and is immediately
     * followed by a failure to list any models.
     */
    fun string(token: String, claim: String): String? {
        val payload = payload(token) ?: return null
        (payload[claim] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?.takeIf { it.isNotBlank() }
            ?.let { return it }
        val namespaced = payload[AUTH_CLAIM_NAMESPACE] as? JsonObject ?: return null
        return (namespaced[claim] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?.takeIf { it.isNotBlank() }
    }

    /** The `exp` carried by the access token itself, converted to epoch millis. It outranks `expires_in`. */
    fun expirationMillis(token: String): Long? {
        val exp = payload(token)?.get("exp") as? JsonPrimitive ?: return null
        if (exp.isString) return null
        return exp.content.toDoubleOrNull()?.toLong()?.times(1000L)
    }

    private fun payload(token: String): JsonObject? {
        val parts = token.split(".")
        if (parts.size < 2) return null
        val decoded = runCatching {
            String(Base64.getUrlDecoder().decode(parts[1].padded()), Charsets.UTF_8)
        }.getOrNull() ?: return null
        return runCatching { Json.parseToJsonElement(decoded) as? JsonObject }.getOrNull()
    }

    /** base64url may omit padding but the JDK decoder will not accept that, so pad before feeding it. */
    private fun String.padded(): String = this + "=".repeat((4 - length % 4) % 4)
}

/**
 * The pure network layer of the OpenAI Codex device-code flow.
 *
 * It touches neither UI nor storage and implements no retry policy: those belong to the state
 * machine, the credential store and the caller respectively. All this does is send requests
 * according to the published parameters and translate upstream receipts into precise meanings.
 *
 * The biggest difference from Grok is that Codex has two legs. Polling `deviceTokenEndpoint`
 * yields an `authorization_code` plus a `code_verifier` rather than a token, and those still
 * have to be exchanged at `tokenEndpoint` via PKCE. To keep the state machine shaped the same
 * as Grok's (poll then tokens), that exchange is folded inside [pollToken].
 */
class OpenAISubscriptionOAuthClient(
    private val client: HttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Step one: request a device code and get back a `device_auth_id` plus the short code to
     * show the user.
     *
     * The authorization page address does not come from the upstream receipt, since Codex does
     * not return a `verification_uri_complete`. It uses the published, allowlist-checked
     * `config.verificationUrl` instead, and the user confirms the short code on that page.
     */
    suspend fun requestDeviceAuthorization(
        config: OpenAISubscriptionAuthConfig,
    ): OpenAIDeviceAuthorization {
        val (status, body) = send {
            client.post(config.deviceAuthorizationEndpoint) {
                header("Accept", "application/json")
                contentType(ContentType.Application.Json)
                setBody(jsonBody("client_id" to config.clientId))
            }
        }
        if (status != 200) throw OpenAISubscriptionException(mapFailure(status, body))

        val payload = runCatching { json.decodeFromString<DeviceCodeResponse>(body) }.getOrNull()
        if (payload == null || payload.deviceAuthId.isBlank() || payload.userCode.isBlank()) {
            throw OpenAISubscriptionException(OpenAISubscriptionError.Upstream(200, snippet(body)))
        }
        // A caller could hand-build a config and bypass parsing, so run the allowlist once more
        // here: better to do nothing than to send the user to a domain of unknown origin.
        if (!config.allowsVerificationUrl(config.verificationUrl)) {
            throw OpenAISubscriptionException(OpenAISubscriptionError.ConfigurationUnavailable)
        }

        return OpenAIDeviceAuthorization(
            deviceAuthId = payload.deviceAuthId,
            userCode = payload.userCode,
            verificationUrl = config.verificationUrl,
            interval = (payload.resolvedInterval ?: config.pollIntervalSeconds).coerceAtLeast(1),
            expiresIn = payload.expiresIn ?: config.pollTimeoutSeconds,
        )
    }

    /**
     * Step two: poll the authorization state once, and on success immediately complete the PKCE
     * exchange with the `authorization_code` plus `code_verifier` from the receipt, returning
     * usable tokens.
     *
     * `AuthorizationPending` and `SlowDown` are thrown as errors so the caller decides whether
     * to keep waiting or back off. Pacing stays in the state machine; this layer is stateless.
     */
    suspend fun pollToken(
        config: OpenAISubscriptionAuthConfig,
        deviceAuthId: String,
        userCode: String,
    ): OpenAISubscriptionTokens {
        val (status, body) = send {
            client.post(config.deviceTokenEndpoint) {
                header("Accept", "application/json")
                contentType(ContentType.Application.Json)
                setBody(
                    jsonBody(
                        "device_auth_id" to deviceAuthId,
                        "user_code" to userCode,
                    )
                )
            }
        }

        if (status == 200) {
            val grant = decodeAuthorizationGrant(body)
                // A 200 with no code is how upstream says "not authorized yet", so keep polling
                // as pending. Treating it as a parse error would kill the flow before the user
                // has even pressed approve.
                ?: throw OpenAISubscriptionException(OpenAISubscriptionError.AuthorizationPending)
            return exchangeAuthorizationCode(config, grant.authorizationCode, grant.codeVerifier)
        }

        // Not a 200: check the OAuth error code first. When upstream states its case explicitly
        // that wins, and must not be swallowed by the 403/404 fallback below.
        when (errorCode(body)) {
            "authorization_pending", "deviceauth_authorization_pending" ->
                throw OpenAISubscriptionException(OpenAISubscriptionError.AuthorizationPending)
            "slow_down" -> throw OpenAISubscriptionException(OpenAISubscriptionError.SlowDown)
            "expired_token", "device_code_expired" ->
                throw OpenAISubscriptionException(OpenAISubscriptionError.CodeExpired)
            "access_denied" -> throw OpenAISubscriptionException(OpenAISubscriptionError.AccessDenied)
        }
        // During polling, 403 and 404 mean "the user has not approved yet" - the exact opposite
        // of what they mean on every other path. Translating them by the general rule into
        // SubscriptionNotEligible would kill the flow on the spot, showing up as "your account
        // is not supported" the instant the user finished entering the code.
        if (status == 403 || status == 404) {
            throw OpenAISubscriptionException(OpenAISubscriptionError.AuthorizationPending)
        }
        throw OpenAISubscriptionException(mapFailure(status, body))
    }

    /**
     * The PKCE exchange: trade the `authorization_code` plus `code_verifier` from the device
     * poll for real tokens.
     *
     * This one goes out **form-urlencoded**, not as the JSON the device leg uses, and
     * `redirect_uri` is mandatory - upstream rejects the exchange outright without it.
     */
    suspend fun exchangeAuthorizationCode(
        config: OpenAISubscriptionAuthConfig,
        code: String,
        codeVerifier: String,
    ): OpenAISubscriptionTokens {
        val (status, body) = send {
            client.post(config.tokenEndpoint) {
                header("Accept", "application/json")
                contentType(ContentType.Application.FormUrlEncoded)
                setBody(
                    formBody(
                        "grant_type" to "authorization_code",
                        "client_id" to config.clientId,
                        "code" to code,
                        "code_verifier" to codeVerifier,
                        "redirect_uri" to config.redirectUri,
                    )
                )
            }
        }
        if (status != 200) throw OpenAISubscriptionException(mapFailure(status, body))
        return decodeTokens(body, null, null, null)
    }

    /**
     * Exchanges a refresh token for a fresh access token.
     *
     * OpenAI's refresh is also form-encoded, and the response usually carries back neither a
     * refresh_token nor an id_token. Failing to carry the previous values forward wipes out both
     * the ability to refresh again and the account identity: the first shows up as being thrown
     * back to sign-in in the middle of a session, the second as outbound requests missing the
     * `chatgpt-account-id` header and being rejected upstream.
     */
    suspend fun refreshTokens(
        config: OpenAISubscriptionAuthConfig,
        refreshToken: String,
        previousAccountId: String? = null,
        previousPlanType: String? = null,
    ): OpenAISubscriptionTokens {
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
        if (status != 200) throw OpenAISubscriptionException(mapFailure(status, body))
        return decodeTokens(body, refreshToken, previousAccountId, previousPlanType)
    }

    /**
     * Fetches the model catalog for the subscription path.
     *
     * Two conventions are specific to Codex, both confirmed against a real ChatGPT account:
     * 1. `GET /models` must carry the `client_version` query parameter, otherwise it answers 400.
     * 2. Outbound requests must carry `chatgpt-account-id`, using the value decoded during the
     *    token exchange rather than re-decoding the JWT here.
     */
    suspend fun fetchModels(
        config: OpenAISubscriptionAuthConfig,
        accessToken: String,
        accountId: String,
    ): List<CodexModelDescriptor> {
        val (status, body) = send {
            client.get(config.modelsUrlWithClientVersion) {
                header("Accept", "application/json")
                header("Authorization", "Bearer $accessToken")
                header("chatgpt-account-id", accountId)
                config.requiredHeaders.forEach { (name, value) -> header(name, value) }
            }
        }
        if (status != 200) throw OpenAISubscriptionException(mapFailure(status, body))
        return parseModelDescriptors(body)
    }

    /**
     * Parses the Codex `/models` response together with the per-model capabilities upstream
     * declares.
     *
     * The response is shaped `{"models":[{slug,visibility,supported_in_api,...}]}`, *not*
     * OpenAI's public `{"data":[{"id"}]}`; assuming the public shape parses out an empty
     * catalog. Only slugs with `visibility=="list"` and `supported_in_api==true` are accepted:
     * hidden entries (codex-auto-review) and entries that do not work over the API
     * (gpt-5.3-codex-spark) must not reach the user's catalog.
     *
     * Unlike Grok's lenient filtering, the test here is strict equality. Both fields were
     * confirmed to exist by measurement, and accepting a slug with `visibility != list` means
     * handing the user something upstream deliberately hid.
     *
     * Capabilities are copied from the declaration, and anything absent degrades: a
     * `web_search_tool_type` means web search is supported, while an empty string or a missing
     * field means it is not. Never infer from the slug.
     */
    fun parseModelDescriptors(body: String): List<CodexModelDescriptor> {
        val payload = runCatching { json.decodeFromString<ModelsResponse>(body) }.getOrNull()
            ?: throw OpenAISubscriptionException(OpenAISubscriptionError.Upstream(200, snippet(body)))
        return payload.models
            .filter { it.slug.isNotBlank() && it.visibility == "list" && it.supportedInApi == true }
            .map { item ->
                CodexModelDescriptor(
                    slug = item.slug,
                    displayName = item.displayName,
                    supportsWebSearch = !item.webSearchToolType.isNullOrEmpty(),
                    supportedReasoningLevels = readReasoningEfforts(item.supportedReasoningLevels),
                    defaultReasoningLevel = item.defaultReasoningLevel,
                    supportsImageInput = item.inputModalities.orEmpty()
                        .any { it.equals("image", ignoreCase = true) },
                    contextWindow = item.contextWindow,
                )
            }
    }

    /**
     * Extracts the effort values out of the level declaration upstream sends.
     *
     * Both shapes are accepted: an object `{"effort":"low"}` is the current real shape, and a
     * bare string guards against upstream reverting to a flat array. Entries that match neither
     * are skipped, because one bad record should not empty out the whole level table.
     */
    private fun readReasoningEfforts(raw: List<JsonElement>?): List<String> =
        raw.orEmpty().mapNotNull { element ->
            runCatching {
                val primitive = element as? JsonPrimitive
                if (primitive != null && primitive.isString) {
                    primitive.content
                } else {
                    element.jsonObject["effort"]?.jsonPrimitive?.contentOrNull
                }
            }.getOrNull()?.takeIf { it.isNotBlank() }
        }

    // Internals

    private suspend inline fun send(block: () -> HttpResponse): Pair<Int, String> {
        val response = try {
            block()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            throw OpenAISubscriptionException(
                OpenAISubscriptionError.Transport(e.message ?: e::class.java.simpleName)
            )
        }
        val body = runCatching { response.bodyAsText() }.getOrDefault("")
        return response.status.value to body
    }

    private fun decodeAuthorizationGrant(body: String): CodexAuthorizationGrant? {
        val payload = runCatching { json.decodeFromString<DevicePollResponse>(body) }.getOrNull()
            ?: return null
        val code = payload.authorizationCode?.takeIf { it.isNotBlank() } ?: return null
        val verifier = payload.codeVerifier?.takeIf { it.isNotBlank() } ?: return null
        return CodexAuthorizationGrant(authorizationCode = code, codeVerifier = verifier)
    }

    /**
     * Decodes a token response together with the account information carried in the JWT.
     *
     * If `chatgpt_account_id` cannot be obtained the credential is treated as unusable: it would
     * be a credential whose outbound requests always lack the `chatgpt-account-id` header, and
     * keeping it only means the user hits an unactionable error one step later. The failure has
     * to happen at the moment the credential is obtained.
     */
    private fun decodeTokens(
        body: String,
        previousRefreshToken: String?,
        previousAccountId: String?,
        previousPlanType: String?,
    ): OpenAISubscriptionTokens {
        val payload = runCatching { json.decodeFromString<TokenResponse>(body) }.getOrNull()
        if (payload == null || payload.accessToken.isBlank()) {
            throw OpenAISubscriptionException(OpenAISubscriptionError.Upstream(200, snippet(body)))
        }
        val idToken = payload.idToken?.takeIf { it.isNotBlank() }
        // The id_token is what carries chatgpt_account_id; the access_token is only a fallback.
        val claimSource = idToken ?: payload.accessToken
        val accountId = OpenAIJwtClaims.string(claimSource, CLAIM_ACCOUNT_ID)
            ?: previousAccountId?.takeIf { it.isNotBlank() }
            ?: throw OpenAISubscriptionException(
                OpenAISubscriptionError.Upstream(200, "missing chatgpt_account_id")
            )
        val planType = OpenAIJwtClaims.string(claimSource, CLAIM_PLAN_TYPE)
            ?: previousPlanType?.takeIf { it.isNotBlank() }
        val now = System.currentTimeMillis()
        return OpenAISubscriptionTokens(
            accessToken = payload.accessToken,
            refreshToken = payload.refreshToken?.takeIf { it.isNotBlank() } ?: previousRefreshToken,
            idToken = idToken,
            // The access_token carries its own exp, which outranks expires_in. Fall back to
            // expires_in only when it is absent.
            expiresAt = OpenAIJwtClaims.expirationMillis(payload.accessToken)
                ?: payload.expiresIn?.let { now + it * 1000L },
            accountId = accountId,
            planType = planType,
            obtainedAt = now,
        )
    }

    @Serializable
    private data class DeviceCodeResponse(
        @SerialName("device_auth_id") val deviceAuthId: String = "",
        @SerialName("user_code") val userCode: String = "",
        @SerialName("expires_in") val expiresIn: Int? = null,
        // Upstream may send interval as a number or as a numeric string. Accept both.
        val interval: JsonPrimitive? = null,
    ) {
        val resolvedInterval: Int?
            get() = interval?.content?.trim()?.toDoubleOrNull()?.toInt()
    }

    @Serializable
    private data class DevicePollResponse(
        @SerialName("authorization_code") val authorizationCode: String? = null,
        @SerialName("code_verifier") val codeVerifier: String? = null,
    )

    @Serializable
    private data class TokenResponse(
        @SerialName("access_token") val accessToken: String = "",
        @SerialName("refresh_token") val refreshToken: String? = null,
        @SerialName("id_token") val idToken: String? = null,
        @SerialName("expires_in") val expiresIn: Int? = null,
    )

    // The real shape of Codex /models: {"models":[{"slug","visibility","supported_in_api", ...}]}.
    // Every capability field below was confirmed to exist by measurement against a real ChatGPT
    // account. All of them are nullable, and anything absent is treated as unsupported.
    @Serializable
    private data class ModelsResponse(val models: List<Item> = emptyList()) {
        @Serializable
        data class Item(
            val slug: String = "",
            val visibility: String? = null,
            @SerialName("supported_in_api") val supportedInApi: Boolean? = null,
            @SerialName("display_name") val displayName: String? = null,
            @SerialName("web_search_tool_type") val webSearchToolType: String? = null,
            /**
             * Upstream sends an array of objects here,
             * `[{"effort":"low","description":"..."}, ...]`, not bare strings. When measured,
             * sol and terra declared six levels each, luna five, and the 5.5 and 5.4 builds four
             * each. Declaring this as `List<String>` makes the field fail to parse, leaving the
             * level table permanently empty, which surfaces as every subscription model claiming
             * it does not support thinking. Take the raw shape as JsonElement and let
             * [readReasoningEfforts] handle both spellings.
             */
            @SerialName("supported_reasoning_levels") val supportedReasoningLevels: List<JsonElement>? = null,
            @SerialName("default_reasoning_level") val defaultReasoningLevel: String? = null,
            @SerialName("input_modalities") val inputModalities: List<String>? = null,
            @SerialName("context_window") val contextWindow: Int? = null,
        )
    }

    companion object {
        private const val CLAIM_ACCOUNT_ID = "chatgpt_account_id"
        private const val CLAIM_PLAN_TYPE = "chatgpt_plan_type"

        private val errorJson = Json { ignoreUnknownKeys = true; isLenient = true }

        /**
         * Translates an HTTP status plus an OAuth error code into a precise meaning.
         *
         * The intermediate states of the device code flow are expressed through the error code,
         * so looking only at the status turns "the user has not approved yet" into a permanent
         * failure. Note this function serves the paths that are *not* device polling: the PKCE
         * exchange, refresh and models. A 403 here means the plan is ineligible; the 403/404
         * that mean pending during polling are handled separately in [pollToken].
         */
        fun mapFailure(status: Int, body: String): OpenAISubscriptionError {
            when (errorCode(body)) {
                "authorization_pending", "deviceauth_authorization_pending" ->
                    return OpenAISubscriptionError.AuthorizationPending
                "slow_down" -> return OpenAISubscriptionError.SlowDown
                "expired_token", "device_code_expired" -> return OpenAISubscriptionError.CodeExpired
                "access_denied" -> return OpenAISubscriptionError.AccessDenied
                "usage_limit_reached", "rate_limit_exceeded" -> return OpenAISubscriptionError.QuotaExhausted
                "usage_not_included" -> return OpenAISubscriptionError.SubscriptionNotEligible
                "refresh_token_invalidated", "invalid_grant" -> return OpenAISubscriptionError.Unauthorized
            }
            return when (status) {
                401 -> OpenAISubscriptionError.Unauthorized
                403 -> OpenAISubscriptionError.SubscriptionNotEligible
                426 -> OpenAISubscriptionError.ClientVersionRejected
                429 -> OpenAISubscriptionError.QuotaExhausted
                else -> OpenAISubscriptionError.Upstream(status, snippet(body))
            }
        }

        /** The upstream error may be a string or a `{code|type}` object. Accept both. */
        private fun errorCode(body: String): String? {
            val root = runCatching { errorJson.parseToJsonElement(body) as? JsonObject }.getOrNull()
                ?: return null
            when (val error = root["error"]) {
                is JsonPrimitive -> if (error.isString) {
                    error.content.trim().takeIf { it.isNotEmpty() }?.let { return it.lowercase() }
                }

                is JsonObject -> {
                    val detail = stringField(error, "code") ?: stringField(error, "type")
                    if (detail != null) return detail
                }

                else -> Unit
            }
            // On some errors the usercode and token endpoints put the code at the top level
            // instead of inside the error object.
            return stringField(root, "error_code") ?: stringField(root, "code")
        }

        private fun stringField(node: JsonObject, name: String): String? =
            (node[name] as? JsonPrimitive)?.takeIf { it.isString }
                ?.content?.trim()?.takeIf { it.isNotEmpty() }?.lowercase()

        private fun snippet(body: String): String = body.take(400)

        private fun formBody(vararg fields: Pair<String, String>): String =
            fields.joinToString("&") { (name, value) ->
                "${URLEncoder.encode(name, "UTF-8")}=${URLEncoder.encode(value, "UTF-8")}"
            }

        private fun jsonBody(vararg fields: Pair<String, String>): String =
            buildJsonObject { fields.forEach { (name, value) -> put(name, value) } }.toString()
    }
}

/**
 * Maps a thinking mode to the `reasoning.effort` value upstream accepts. It only ever returns a
 * value that actually appears in [declaredLevels].
 *
 * The rule this enforces is that we never send an effort level upstream does not recognize,
 * which is exactly the shape of the Grok reasoning_effort incident. Subscription models are not
 * in the metadata catalog and have no published capability recipe, but Codex's `/models`
 * declares `supported_reasoning_levels` per model, so using that as the admission check
 * achieves the same end: only what upstream recognizes goes out, and if upstream renames its
 * levels the match simply fails rather than continuing to push a stale value.
 *
 * - Empty [declaredLevels] (upstream declared nothing) yields null and nothing is injected.
 * - `automatic` and any unknown mode yield null, deferring to upstream's
 *   `default_reasoning_level`, which is a better choice than one we would make for the user.
 * - Every other mode walks its candidate list for the first level upstream recognizes. That
 *   fallback chain means we still land on a legal value when upstream offers fewer levels than
 *   the product does, instead of silently sending nothing.
 */
fun codexReasoningEffort(mode: String?, declaredLevels: List<String>): String? {
    if (declaredLevels.isEmpty()) return null
    val declared = declaredLevels.map { it.lowercase() }.toSet()
    val candidates = when (mode) {
        "fast" -> listOf("low", "minimal", "medium")
        "balanced" -> listOf("medium", "low", "high")
        "deep" -> listOf("high", "medium")
        "max" -> listOf("xhigh", "high", "medium")
        // 'automatic' and any unknown mode defer to the upstream default rather than guessing
        // on the user's behalf.
        else -> return null
    }
    return candidates.firstOrNull { declared.contains(it) }
}
