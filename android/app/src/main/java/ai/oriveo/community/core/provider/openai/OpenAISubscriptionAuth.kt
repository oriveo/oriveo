package ai.oriveo.community.core.provider.openai

import ai.oriveo.community.core.provider.grok.GrokSubscriptionAuthResolver
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.net.URI
import java.net.URLEncoder

/**
 * The raw shape of the Codex (ChatGPT subscription sign-in) parameters as they arrive in the
 * provider catalog: every field is nullable and carries a default.
 *
 * Two reasons stack up here, and dropping either one breaks decoding:
 * 1. kotlinx throws by default when an explicit `null` is assigned to a non-nullable field,
 *    so a single `"disabledNotice": null` in the catalog is enough to make the whole section
 *    fail to decode. That is exactly the shape of a real incident this endpoint has already
 *    produced.
 * 2. All validation is concentrated in [OpenAISubscriptionAuthResolver.resolve]. If decoding
 *    threw over one missing field it would take the configuration of every other provider in
 *    the same snapshot down with it, meaning one extra key upstream could make the entire
 *    catalog undecodable on the client.
 */
@Serializable
data class RawOpenAISubscriptionAuth(
    val enabled: Boolean? = null,
    val flow: String? = null,
    val clientId: String? = null,
    val deviceAuthorizationEndpoint: String? = null,
    /**
     * The polling endpoint of the first leg. It returns an `authorization_code` plus a
     * `code_verifier`, *not* a token.
     */
    val deviceTokenEndpoint: String? = null,
    val tokenEndpoint: String? = null,
    @SerialName("verificationURL") val verificationUrl: String? = null,
    @SerialName("redirectURI") val redirectUri: String? = null,
    val trustedAuthHosts: List<String>? = null,
    val trustedVerificationHosts: List<String>? = null,
    @SerialName("resourceBaseURL") val resourceBaseUrl: String? = null,
    val requiredHeaders: Map<String, String>? = null,
    val modelsPath: String? = null,
    val chatPath: String? = null,
    val pollIntervalSeconds: Int? = null,
    val pollTimeoutSeconds: Int? = null,
    val minAppVersion: Map<String, String>? = null,
    val disabledNotice: String? = null,
)

/** A lenient decoding slice of `protocolFeatures`: only the keys the client actually uses. */
@Serializable
data class RawOpenAIProtocolFeatures(
    val subscriptionAuth: RawOpenAISubscriptionAuth? = null,
)

/**
 * The configuration for signing in to OpenAI Codex with the user's own ChatGPT subscription.
 *
 * The client executes the flow but holds none of the knowledge. Endpoints, client id, required
 * headers, where the model catalog for this path comes from, and the on/off switch all arrive
 * in the provider catalog under `providerConfigs[openAI].protocolFeatures.subscriptionAuth`.
 * The one exception is `chatgpt-account-id`, which is per-user identity derived from the JWT of
 * the sign-in token rather than knowledge about the protocol.
 *
 * This discipline is not fastidiousness. The Codex backend is the undocumented path the
 * open-source Codex client uses, and its floor for `version` has been raised before: a missing
 * or too-low value gets an immediate HTTP 426. A desktop tool can hot-fix that the same day,
 * but changing a constant in a mobile app means app review plus the long tail of users
 * updating, so the window of unavailability would run about a week.
 */
data class OpenAISubscriptionAuthConfig(
    val clientId: String,
    /** First leg: request a device code (`.../deviceauth/usercode`). */
    val deviceAuthorizationEndpoint: String,
    /**
     * Polling endpoint for the first leg. It returns an `authorization_code` plus a
     * `code_verifier`, *not* a token.
     */
    val deviceTokenEndpoint: String,
    /** Second leg: the OAuth token endpoint, shared by the PKCE exchange and by refresh. */
    val tokenEndpoint: String,
    /**
     * Address of the authorization page.
     *
     * This differs from Grok: the Codex usercode receipt does not carry a
     * `verification_uri_complete`, so the authorization page comes from the catalog and is
     * checked against a host allowlist at parse time, while the short code is handed to the
     * user to type into that page themselves.
     */
    val verificationUrl: String,
    /**
     * The `redirect_uri` the PKCE exchange must carry. It has to share a domain with the
     * authorization endpoint or upstream rejects the exchange outright.
     */
    val redirectUri: String,
    val trustedVerificationHosts: List<String>,
    val resourceBaseUrl: String,
    /**
     * Headers every outbound request must carry verbatim (`originator` / `version` /
     * `OpenAI-Beta`). Both the names and the values come from the catalog.
     */
    val requiredHeaders: Map<String, String>,
    val modelsPath: String,
    val chatPath: String,
    /**
     * Full address of the subscription model catalog, without the `client_version` query
     * parameter (see [modelsUrlWithClientVersion]).
     *
     * The general model catalog cannot stand in for this. That catalog describes the
     * pay-as-you-go path on `api.openai.com`, whereas the Codex backend exposes a different set
     * of gpt-5.x builds (sol / terra / luna and friends). Populating a subscription instance
     * from the former means the model the user picked simply does not exist on this path.
     */
    val modelsUrl: String,
    /**
     * Full address of the subscription chat endpoint.
     *
     * Joining base and path happens exactly once, here in configuration parsing.
     * `resourceBaseURL` already ends in `/backend-api/codex` and the path only adds
     * `/responses`; joining a second time on the outbound side would produce
     * `/codex/codex/responses`. Grok has already been bitten by the `/v1/v1` version of this,
     * which shows up as a 404.
     */
    val responsesUrl: String,
    val pollIntervalSeconds: Int,
    val pollTimeoutSeconds: Int,
) {
    /**
     * Whether an authorization page link falls inside the trusted hosts.
     *
     * This stays a separate entry point rather than being checked once at parse time, because a
     * caller could hand-build a config and bypass parsing. That would let a catalog value decide
     * which domain we send the user to, and the path from a tampered configuration to a
     * phishing redirect has to be closed off.
     */
    fun allowsVerificationUrl(raw: String?): Boolean {
        val uri = safeHttpsUri(raw) ?: return false
        val host = uri.host.lowercase()
        return trustedVerificationHosts.any { trusted ->
            val normalized = trusted.lowercase()
            host == normalized || host.endsWith(".$normalized")
        }
    }

    /**
     * Builds the catalog address with `client_version` attached.
     *
     * Measured against a real ChatGPT account: without this query parameter upstream always
     * answers 400 `missing field client_version`. The value is taken from the `version` header
     * in the catalog rather than hardcoded, so when OpenAI raises the floor it is a
     * configuration change instead of an app release. If no version is published we return the
     * URL unchanged rather than inventing a version number on upstream's behalf.
     */
    val modelsUrlWithClientVersion: String
        get() {
            val clientVersion = requiredHeaders["version"]?.trim()?.takeIf { it.isNotEmpty() }
                ?: return modelsUrl
            val separator = if (modelsUrl.contains('?')) "&" else "?"
            return modelsUrl + separator + "client_version=" + URLEncoder.encode(clientVersion, "UTF-8")
        }
}

/**
 * Everything one Codex subscription request needs beyond the body itself.
 *
 * It carries fully joined URLs rather than a base, for the reason given on
 * [OpenAISubscriptionAuthConfig.responsesUrl]. [accountId] is the mandatory
 * `chatgpt-account-id` header: it is decoded once during the token exchange, and every later
 * use takes that already-resolved value instead of digging through the JWT again. Re-deriving
 * it has gone wrong twice, both times showing up as a fresh, successful authorization that
 * then reported it could not list any models.
 */
data class OpenAISubscriptionRequestContext(
    val responsesUrl: String,
    val accountId: String,
    val requiredHeaders: Map<String, String>,
)

/**
 * Whether subscription sign-in is available on this device.
 *
 * Three states rather than a `Boolean`, because "the catalog does not describe it" and
 * "someone deliberately switched it off" are two different things to the user. In the first
 * case nothing should appear at all (an older or incomplete snapshot); in the second, users
 * who are already connected have to be told the real reason instead of watching it fail
 * silently.
 */
sealed class OpenAISubscriptionAvailability {
    /** Available, carrying every parameter this attempt needs. */
    data class Available(val config: OpenAISubscriptionAuthConfig) : OpenAISubscriptionAvailability()

    /**
     * Switched off by the kill switch, or the running app version is below the published
     * `minAppVersion`. [notice] is the text from the catalog; when it is absent the UI falls
     * back to a localized default.
     */
    data class Disabled(val notice: String?) : OpenAISubscriptionAvailability()

    /** The catalog does not carry this section at all, so the entry point never appears. */
    data object Unavailable : OpenAISubscriptionAvailability()
}

object OpenAISubscriptionAuthResolver {

    /** This platform's key inside `minAppVersion`. A missing key means no gate at all. */
    const val PLATFORM_KEY: String = "android"

    /**
     * The contract version marker. An unrecognized flow bows out rather than driving a new
     * authorization scheme with two-leg device code logic that was never meant for it.
     */
    private const val SUPPORTED_FLOW = "codex_device_code"

    private const val DEFAULT_MODELS_PATH = "/models"
    private const val DEFAULT_CHAT_PATH = "/responses"
    private const val DEFAULT_POLL_INTERVAL_SECONDS = 5
    private const val DEFAULT_POLL_TIMEOUT_SECONDS = 900

    /**
     * The only legitimate host for the Codex backend.
     *
     * The allowlist has exactly one entry and requires an exact match: `resourceBaseURL`
     * decides where we send the access token, so a single rewritten catalog value is a
     * credential leak. Allowing subdomains here has no legitimate use.
     */
    private const val CODEX_RESOURCE_HOST = "chatgpt.com"

    /**
     * Resolves the raw published configuration into a usable one.
     *
     * Any missing or invalid required field degrades to
     * [OpenAISubscriptionAvailability.Unavailable] rather than assembling a best-effort partial
     * configuration: one absent endpoint means the flow cannot complete, and bowing out early
     * is more honest than letting the user tap in and get stuck halfway.
     */
    fun resolve(
        raw: RawOpenAISubscriptionAuth?,
        appVersion: String,
    ): OpenAISubscriptionAvailability {
        if (raw == null) return OpenAISubscriptionAvailability.Unavailable

        if (raw.flow != SUPPORTED_FLOW) return OpenAISubscriptionAvailability.Unavailable

        if (raw.enabled != true) return OpenAISubscriptionAvailability.Disabled(raw.disabledNotice)

        val minimum = raw.minAppVersion?.get(PLATFORM_KEY)?.takeIf { it.isNotBlank() }
        if (minimum != null && GrokSubscriptionAuthResolver.compareVersions(appVersion, minimum) < 0) {
            // The version gate exists to shut out older clients carrying known-bad logic;
            // letting them keep hammering upstream would poison our standing with OpenAI.
            return OpenAISubscriptionAvailability.Disabled(raw.disabledNotice)
        }

        val clientId = raw.clientId?.trim()?.takeIf { it.isNotEmpty() }
            ?: return OpenAISubscriptionAvailability.Unavailable

        val resourceBaseUrl = normalizedHttpsUrl(raw.resourceBaseUrl)
            ?: return OpenAISubscriptionAvailability.Unavailable
        // Where the access token goes gets no approximate matching: evil.chatgpt.com and
        // chatgpt.com.evil.test both have to be rejected.
        if (safeHttpsUri(resourceBaseUrl)?.host?.lowercase() != CODEX_RESOURCE_HOST) {
            return OpenAISubscriptionAvailability.Unavailable
        }

        val trustedAuthHosts = (raw.trustedAuthHosts ?: emptyList())
            .filter { it.isNotBlank() }
            .map { it.lowercase() }
        if (trustedAuthHosts.isEmpty()) return OpenAISubscriptionAvailability.Unavailable

        val deviceAuthorizationEndpoint = trustedHttpsUrl(raw.deviceAuthorizationEndpoint, trustedAuthHosts)
            ?: return OpenAISubscriptionAvailability.Unavailable
        val deviceTokenEndpoint = trustedHttpsUrl(raw.deviceTokenEndpoint, trustedAuthHosts)
            ?: return OpenAISubscriptionAvailability.Unavailable
        val tokenEndpoint = trustedHttpsUrl(raw.tokenEndpoint, trustedAuthHosts)
            ?: return OpenAISubscriptionAvailability.Unavailable
        val redirectUri = trustedHttpsUrl(raw.redirectUri, trustedAuthHosts)
            ?: return OpenAISubscriptionAvailability.Unavailable

        val verificationHosts = (raw.trustedVerificationHosts ?: emptyList())
            .filter { it.isNotBlank() }
            .map { it.lowercase() }
        if (verificationHosts.isEmpty()) return OpenAISubscriptionAvailability.Unavailable
        val verificationUrl = trustedHttpsUrl(raw.verificationUrl, verificationHosts)
            ?: return OpenAISubscriptionAvailability.Unavailable

        val modelsPath = normalizedPath(raw.modelsPath, DEFAULT_MODELS_PATH)
        val chatPath = normalizedPath(raw.chatPath, DEFAULT_CHAT_PATH)

        return OpenAISubscriptionAvailability.Available(
            OpenAISubscriptionAuthConfig(
                clientId = clientId,
                deviceAuthorizationEndpoint = deviceAuthorizationEndpoint,
                deviceTokenEndpoint = deviceTokenEndpoint,
                tokenEndpoint = tokenEndpoint,
                verificationUrl = verificationUrl,
                redirectUri = redirectUri,
                trustedVerificationHosts = verificationHosts,
                resourceBaseUrl = resourceBaseUrl,
                requiredHeaders = raw.requiredHeaders ?: emptyMap(),
                modelsPath = modelsPath,
                chatPath = chatPath,
                modelsUrl = joinUrl(resourceBaseUrl, modelsPath),
                responsesUrl = joinUrl(resourceBaseUrl, chatPath),
                // These polling fallbacks apply only when the catalog does not specify them.
                // An interval returned in an upstream receipt takes precedence (see the
                // slow_down handling).
                pollIntervalSeconds = (raw.pollIntervalSeconds ?: DEFAULT_POLL_INTERVAL_SECONDS).coerceAtLeast(1),
                pollTimeoutSeconds = (raw.pollTimeoutSeconds ?: DEFAULT_POLL_TIMEOUT_SECONDS).coerceAtLeast(60),
            )
        )
    }

    /**
     * Falls back to a default relative path when none is published, instead of disabling the
     * whole flow over one missing value.
     */
    private fun normalizedPath(raw: String?, fallback: String): String {
        val trimmed = raw?.trim().orEmpty()
        val path = trimmed.ifEmpty { fallback }
        return if (path.startsWith("/")) path else "/$path"
    }

    /**
     * The base already ends in `/backend-api/codex` and the path only supplies `/models` or
     * `/responses`. Joining happens here and nowhere else.
     */
    private fun joinUrl(base: String, path: String): String = base.trimEnd('/') + path

    /**
     * The host must match the published allowlist exactly. This is the gate against a tampered
     * configuration turning into a phishing redirect.
     */
    private fun trustedHttpsUrl(raw: String?, hosts: List<String>): String? {
        val normalized = normalizedHttpsUrl(raw) ?: return null
        val host = safeHttpsUri(normalized)?.host?.lowercase() ?: return null
        return if (hosts.contains(host)) normalized else null
    }

    private fun normalizedHttpsUrl(raw: String?): String? {
        val trimmed = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return if (safeHttpsUri(trimmed) != null) trimmed else null
    }
}

/**
 * Returns a URI only when all four hold: https scheme, no port, no user or password, and a
 * non-empty host.
 *
 * `port` and `userInfo` have to be rejected too, because the host of
 * `https://user:pass@auth.openai.com/...` is still `auth.openai.com`. Checking the host alone
 * would treat an address smuggling credentials as trusted.
 */
private fun safeHttpsUri(raw: String?): URI? {
    val trimmed = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
    if (!"https".equals(uri.scheme, ignoreCase = true)) return null
    if (uri.port != -1) return null
    if (!uri.userInfo.isNullOrEmpty()) return null
    val host = uri.host
    if (host.isNullOrEmpty()) return null
    return uri
}
