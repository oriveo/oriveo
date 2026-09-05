package ai.oriveo.community.core.provider.grok

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.net.URI

/**
 * Raw shape of the subscription sign-in parameters: every single field is optional.
 *
 * The lack of non-null constraints here is deliberate, with all validation concentrated in
 * [GrokSubscriptionAuthResolver.resolve]. If decoding threw because one field was missing it
 * would take every other provider's config in the same snapshot down with it - one extra key
 * upstream would make the entire provider catalog unparseable, which is wildly out of
 * proportion to the problem.
 */
@Serializable
data class RawGrokSubscriptionAuth(
    val enabled: Boolean? = null,
    val flow: String? = null,
    val clientId: String? = null,
    val scopes: String? = null,
    val deviceAuthorizationEndpoint: String? = null,
    val tokenEndpoint: String? = null,
    val revocationEndpoint: String? = null,
    val trustedAuthHosts: List<String>? = null,
    val trustedVerificationHosts: List<String>? = null,
    @SerialName("resourceBaseURL") val resourceBaseUrl: String? = null,
    val requiredHeaders: Map<String, String>? = null,
    val modelsPath: String? = null,
    val chatPath: String? = null,
    val responsesPath: String? = null,
    val apiBackend: String? = null,
    val pollIntervalSeconds: Int? = null,
    val pollTimeoutSeconds: Int? = null,
    val minAppVersion: Map<String, String>? = null,
    val disabledNotice: String? = null,
)

/** Lenient decoding slice of `protocolFeatures` - only the keys the client consumes. */
@Serializable
data class RawProtocolFeatures(
    val subscriptionAuth: RawGrokSubscriptionAuth? = null,
)

/**
 * Configuration for Grok subscription sign-in.
 *
 * The client executes the flow but holds none of the knowledge. Endpoints, client id,
 * scopes, required headers and the on/off switch all come from
 * `providerConfigs[grok].protocolFeatures.subscriptionAuth` in the bundled provider catalog.
 *
 * That discipline is not fastidiousness. The xAI CLI proxy chain went through several
 * breaking changes inside a single month, and the floor for `x-grok-client-version` was
 * raised more than once - a missing or too-low value gets a flat HTTP 426. Desktop tools
 * hot-fix that the same day, whereas changing a constant on mobile costs a store review plus
 * the long tail of users updating, which is roughly a week of unusable window. Hard-coding
 * these values into the client would be planting a time bomb only a new release can defuse.
 */
data class GrokSubscriptionAuthConfig(
    val clientId: String,
    val scopes: String,
    val deviceAuthorizationEndpoint: String,
    val tokenEndpoint: String,
    val revocationEndpoint: String?,
    val trustedVerificationHosts: List<String>,
    val resourceBaseUrl: String,
    /**
     * Headers every outbound request must carry verbatim (`x-grok-client-version`, for
     * example). Both the key names and the values come from the catalog.
     */
    val requiredHeaders: Map<String, String>,
    /**
     * Full URL of the subscription model directory.
     *
     * The subscription route exposes a completely different model set from the API-key
     * route: when this was measured the subscription directory carried only `grok-4.6` /
     * `grok-4.5`, while the API-key catalog had `grok-4.3` / `grok-code-fast-1`. Populating
     * a subscription instance from the API-key catalog means the model the user picked does
     * not exist on this route at all.
     */
    val modelsUrl: String,
    /**
     * Full URL of the subscription chat endpoint.
     *
     * The joining happens here exactly once. It cannot reuse the `providers.grok.transport`
     * setup: there `baseUrl` is `https://api.x.ai` and the path is `/v1/chat/completions`,
     * whereas the base here already carries `/v1`. Swapping only the base while keeping the
     * path produces `.../v1/v1/chat/completions` and a 404 from upstream - which is exactly
     * how the very first message on a real device failed when this was wired up.
     */
    val chatUrl: String,
    val responsesUrl: String = "$resourceBaseUrl/responses",
    val apiBackend: String? = null,
    val pollIntervalSeconds: Int,
    val pollTimeoutSeconds: Int,
) {
    /**
     * Whether the authorization page URL falls inside the trusted host set.
     *
     * `verification_uri_complete` in the device code response comes from upstream rather
     * than from our own configuration, so handing it straight to a browser would let
     * upstream decide which domain the user lands on. Checking it against the declared
     * allow-list closes the "tampered config leads to a phishing redirect" path.
     */
    fun allowsVerificationUrl(raw: String?): Boolean {
        val uri = safeHttpsUri(raw) ?: return false
        val host = uri.host.lowercase()
        return trustedVerificationHosts.any { trusted ->
            val normalized = trusted.lowercase()
            host == normalized || host.endsWith(".$normalized")
        }
    }
}

/**
 * Everything one outbound request in subscription mode needs beyond the usual payload.
 *
 * Only endpoints and headers: the access token still travels through the existing `apiKey`
 * parameter into `Authorization: Bearer` (the subscription route authenticates with a bearer
 * token too), so request building, self-healing and stream parsing need no changes at all.
 * The refresh token deliberately stays out of here - it belongs to credential storage and no
 * outbound request ever needs it.
 *
 * What is carried is fully joined URLs rather than a base; see
 * [GrokSubscriptionAuthConfig.chatUrl] for why.
 */
data class GrokSubscriptionRequestContext(
    val chatUrl: String,
    val responsesUrl: String? = null,
    val requiredHeaders: Map<String, String>,
    val transport: String = ai.oriveo.community.core.provider.transport.TransportKind.OpenAIChat.wireValue,
) {
    val usesResponses: Boolean
        get() = transport == ai.oriveo.community.core.provider.transport.TransportKind.OpenAIResponses.wireValue

    fun withTransport(value: String): GrokSubscriptionRequestContext = copy(transport = value)
}

/**
 * Whether subscription sign-in is available on this device.
 *
 * Three states rather than a `Boolean`: "the catalog carries no such section" and "it was
 * deliberately switched off" are two different things to the user. The first should surface
 * nothing at all (an older catalog snapshot), while the second has to tell an already
 * connected user the real reason instead of failing silently.
 */
sealed class GrokSubscriptionAvailability {
    /** Available, carrying every parameter this run needs. */
    data class Available(val config: GrokSubscriptionAuthConfig) : GrokSubscriptionAvailability()

    /**
     * Switched off by the kill switch, or the running app version is below the declared
     * `minAppVersion`. [notice] is the text that came with the config; when it is absent
     * the UI falls back to a localized message.
     */
    data class Disabled(val notice: String?) : GrokSubscriptionAvailability()

    /**
     * The catalog carries no such section (an older snapshot), so the entry point does
     * not appear at all.
     */
    data object Unavailable : GrokSubscriptionAvailability()
}

object GrokSubscriptionAuthResolver {

    /** This platform's key inside `minAppVersion`. */
    const val PLATFORM_KEY: String = "android"

    /**
     * Contract version marker: an unrecognized flow bows out instead of forcing
     * device-code logic onto a different authorization scheme.
     */
    private const val SUPPORTED_FLOW = "oauth_device_code"

    private const val DEFAULT_MODELS_PATH = "/models"
    private const val DEFAULT_CHAT_PATH = "/chat/completions"
    private const val DEFAULT_RESPONSES_PATH = "/responses"

    fun transportKind(raw: String?): String? = when (raw?.trim()?.lowercase()) {
        "responses" -> ai.oriveo.community.core.provider.transport.TransportKind.OpenAIResponses.wireValue
        "chat", "chat_completions", "chat.completions" ->
            ai.oriveo.community.core.provider.transport.TransportKind.OpenAIChat.wireValue
        else -> null
    }

    /**
     * Resolves the raw configuration into a usable one.
     *
     * Any required field that is missing or malformed degrades the whole thing to
     * [GrokSubscriptionAvailability.Unavailable] instead of assembling a partial config:
     * one absent endpoint means the flow cannot complete, and bowing out early is more
     * honest than letting the user tap in and get stuck halfway.
     */
    fun resolve(
        raw: RawGrokSubscriptionAuth?,
        appVersion: String,
    ): GrokSubscriptionAvailability {
        if (raw == null) return GrokSubscriptionAvailability.Unavailable

        // flow is the contract version marker: if xAI ever switches authorization scheme
        // (to PKCE authorization code, say), an older client that does not recognize the
        // new flow should bow out instead of forcing device-code logic onto it.
        if (raw.flow != SUPPORTED_FLOW) return GrokSubscriptionAvailability.Unavailable

        if (raw.enabled != true) return GrokSubscriptionAvailability.Disabled(raw.disabledNotice)

        val minimum = raw.minAppVersion?.get(PLATFORM_KEY)?.takeIf { it.isNotBlank() }
        if (minimum != null && compareVersions(appVersion, minimum) < 0) {
            // The version gate exists to shut out clients carrying known-broken logic;
            // letting them keep hammering upstream would sour the relationship with xAI.
            return GrokSubscriptionAvailability.Disabled(raw.disabledNotice)
        }

        val clientId = raw.clientId?.trim()?.takeIf { it.isNotEmpty() }
            ?: return GrokSubscriptionAvailability.Unavailable
        val scopes = raw.scopes?.trim()?.takeIf { it.isNotEmpty() }
            ?: return GrokSubscriptionAvailability.Unavailable
        val resourceBaseUrl = normalizedHttpsUrl(raw.resourceBaseUrl)
            ?: return GrokSubscriptionAvailability.Unavailable

        val trustedAuthHosts = (raw.trustedAuthHosts ?: emptyList()).map { it.lowercase() }
        if (trustedAuthHosts.isEmpty()) return GrokSubscriptionAvailability.Unavailable
        val deviceEndpoint = trustedHttpsUrl(raw.deviceAuthorizationEndpoint, trustedAuthHosts)
            ?: return GrokSubscriptionAvailability.Unavailable
        val tokenEndpoint = trustedHttpsUrl(raw.tokenEndpoint, trustedAuthHosts)
            ?: return GrokSubscriptionAvailability.Unavailable

        val verificationHosts = raw.trustedVerificationHosts?.filter { it.isNotBlank() } ?: emptyList()
        if (verificationHosts.isEmpty()) return GrokSubscriptionAvailability.Unavailable

        return GrokSubscriptionAvailability.Available(
            GrokSubscriptionAuthConfig(
                clientId = clientId,
                scopes = scopes,
                deviceAuthorizationEndpoint = deviceEndpoint,
                tokenEndpoint = tokenEndpoint,
                // The revocation endpoint is optional: without one the credential is just
                // deleted locally, rather than one optional endpoint disabling the flow.
                revocationEndpoint = trustedHttpsUrl(raw.revocationEndpoint, trustedAuthHosts),
                trustedVerificationHosts = verificationHosts,
                resourceBaseUrl = resourceBaseUrl,
                requiredHeaders = raw.requiredHeaders ?: emptyMap(),
                modelsUrl = joinUrl(resourceBaseUrl, normalizedPath(raw.modelsPath, DEFAULT_MODELS_PATH)),
                chatUrl = joinUrl(resourceBaseUrl, normalizedPath(raw.chatPath, DEFAULT_CHAT_PATH)),
                responsesUrl = joinUrl(resourceBaseUrl, normalizedPath(raw.responsesPath, DEFAULT_RESPONSES_PATH)),
                apiBackend = raw.apiBackend?.trim()?.takeIf { it.isNotEmpty() },
                // The polling fallbacks come from the RFC 8628 recommendation and from
                // measured xAI device code responses, and apply only when the config
                // omits them; an interval returned by upstream wins (see slow_down).
                pollIntervalSeconds = (raw.pollIntervalSeconds ?: 5).coerceAtLeast(1),
                pollTimeoutSeconds = (raw.pollTimeoutSeconds ?: 1800).coerceAtLeast(60),
            )
        )
    }

    /**
     * Falls back to the default relative path when the config omits one, rather than
     * making the whole route unusable.
     */
    private fun normalizedPath(raw: String?, fallback: String): String {
        val trimmed = raw?.trim().orEmpty()
        val path = trimmed.ifEmpty { fallback }
        return if (path.startsWith("/")) path else "/$path"
    }

    /**
     * The base already carries `/v1` and the path only supplies `/models` or
     * `/chat/completions` - joining happens in this one place and nowhere else.
     */
    private fun joinUrl(base: String, path: String): String = base.trimEnd('/') + path

    /**
     * The host must be in the declared allow-list, the scheme must be https, and the URL
     * may not smuggle credentials or override the port.
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

    /**
     * Compares versions segment by segment as numbers. `1.2.10` > `1.2.9`, which a plain
     * string comparison gets backwards; when the segment counts differ the missing ones
     * count as 0. A suffix such as `1.2.7-beta` contributes only its leading digits.
     */
    fun compareVersions(lhs: String, rhs: String): Int {
        val left = lhs.split(".").map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        val right = rhs.split(".").map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        for (index in 0 until maxOf(left.size, right.size)) {
            val l = left.getOrElse(index) { 0 }
            val r = right.getOrElse(index) { 0 }
            if (l != r) return if (l < r) -1 else 1
        }
        return 0
    }
}

/**
 * Returns the URI only when all four hold: the scheme is https, there is no port, there is
 * no user or password, and the host is non-empty.
 *
 * `port` and `userInfo` have to be blocked as well: the host of
 * `https://user:pass@auth.x.ai/...` is still `auth.x.ai`, so comparing hosts alone would
 * treat a credential-smuggling address as trusted.
 */
internal fun safeHttpsUri(raw: String?): URI? {
    val trimmed = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
    if (!"https".equals(uri.scheme, ignoreCase = true)) return null
    if (uri.port != -1) return null
    if (!uri.userInfo.isNullOrEmpty()) return null
    val host = uri.host
    if (host.isNullOrEmpty()) return null
    return uri
}
