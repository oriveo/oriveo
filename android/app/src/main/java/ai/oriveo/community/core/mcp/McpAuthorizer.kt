package ai.oriveo.community.core.mcp

import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.security.SecureKeyStore
import java.io.InterruptedIOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Authorization for remote MCP.
//
// Covers: discovery from the 401 `WWW-Authenticate` (RFC 9728, including `resource` validation), authorization server
// metadata (RFC 8414, with strict issuer validation), the three client registration tiers (CIMD / DCR / neither
// supported), PKCE (S256), a mandatory `state`, `resource` (RFC 8707) on both requests, the 2×2 `iss` check (RFC 9207),
// the token exchange, refresh, and serializing concurrent refreshes for the same server.
//
// The browser session and the HTTP transport are both abstracted behind interfaces, with fakes in tests; this file does
// not depend on UI (the Custom Tabs implementation lives in the UI layer). Types that carry the verifier, state, tokens
// or `client_id` all ship a redacting `toString()`, so secrets do not leak when they end up in logs.

// ── Protected resource metadata discovery (RFC 9728) ───────

object McpProtectedResourceDiscovery {
    /**
     * Discovery order: prefer `resource_metadata` from `WWW-Authenticate`; without it, build the well-known URIs in
     * turn, first the one for the MCP endpoint path, then the root one.
     */
    fun candidates(challenge: McpAuthChallenge?, endpoint: String): List<String> {
        val result = mutableListOf<String>()
        challenge?.resourceMetadata?.let(result::add)
        val origin = originString(endpoint)
        if (origin != null) {
            val path = McpOrigin.parse(endpoint)?.rawPath.orEmpty()
            if (path.isNotEmpty() && path != "/") result += "$origin/.well-known/oauth-protected-resource$path"
            result += "$origin/.well-known/oauth-protected-resource"
        }
        return result.distinct()
    }

    /** `scheme://host[:port]` (the port is included only when given explicitly, matching iOS `URLComponents`). */
    fun originString(url: String): String? {
        val uri = McpOrigin.parse(url) ?: return null
        val scheme = uri.scheme ?: return null
        val host = uri.host ?: return null
        return if (uri.port >= 0) "$scheme://$host:${uri.port}" else "$scheme://$host"
    }
}

/**
 * Whether the `resource` in protected resource metadata corresponds to the MCP endpoint we requested (RFC 9728 §3.3).
 */
object McpResourceBinding {
    /**
     * Corresponds = same origin, and the `resource` path equals the endpoint path or is a parent path segment of it
     * (the `resource` of a root well-known document is usually the whole origin or a parent path, covering the
     * endpoints beneath it). A missing `resource`, a non-https one, or one that carries a query string or fragment
     * without being the endpoint itself never counts.
     */
    fun covers(resource: String?, endpoint: String): Boolean {
        if (resource == null || !McpOrigin.isHttps(resource)) return false
        if (McpCanonicalUri.canonical(resource) == McpCanonicalUri.canonical(endpoint)) return true
        val resourceUri = McpOrigin.parse(resource) ?: return false
        val endpointUri = McpOrigin.parse(endpoint) ?: return false
        if (!McpOrigin.isSameOrigin(resource, endpoint) || resourceUri.rawQuery != null || resourceUri.rawFragment != null) {
            return false
        }
        val resourcePath = resourceUri.rawPath.orEmpty()
        val base = if (resourcePath.endsWith("/")) resourcePath.dropLast(1) else resourcePath
        val endpointPath = endpointUri.rawPath.orEmpty()
        return base.isEmpty() || endpointPath == base || endpointPath.startsWith("$base/")
    }
}

/** RFC 9728 protected resource metadata. MUST contain `authorization_servers` (at least one). */
data class McpProtectedResourceMetadata(
    /** The resource this metadata describes. Must pass [McpResourceBinding.covers] before use. */
    val resource: String?,
    val authorizationServers: List<String>,
    val scopesSupported: List<String>,
) {
    companion object {
        fun fromJson(json: JsonElement): McpProtectedResourceMetadata? {
            val servers = json["authorization_servers"].stringList().takeIf { it.isNotEmpty() } ?: return null
            return McpProtectedResourceMetadata(
                resource = json["resource"].stringOrNull,
                authorizationServers = servers,
                scopesSupported = json["scopes_supported"].stringList(),
            )
        }
    }
}

// ── Authorization server metadata (RFC 8414) ───────────────

object McpAuthorizationServerDiscovery {
    /** Two or three well-known locations, in an order that depends on whether the issuer has a path. */
    fun candidates(issuer: String): List<String> {
        val origin = McpProtectedResourceDiscovery.originString(issuer) ?: return emptyList()
        val path = McpOrigin.parse(issuer)?.rawPath.orEmpty()
        if (path.isNotEmpty() && path != "/") {
            return listOf(
                "$origin/.well-known/oauth-authorization-server$path",
                "$origin/.well-known/openid-configuration$path",
                "$origin$path/.well-known/openid-configuration",
            )
        }
        return listOf("$origin/.well-known/oauth-authorization-server", "$origin/.well-known/openid-configuration")
    }
}

data class McpAuthorizationServerMetadata(
    val issuer: String,
    val authorizationEndpoint: String?,
    val tokenEndpoint: String?,
    val registrationEndpoint: String?,
    val scopesSupported: List<String>,
    val clientIdMetadataDocumentSupported: Boolean,
    val authorizationResponseIssParameterSupported: Boolean,
    /** PKCE methods the authorization server declares (`code_challenge_methods_supported`). Empty when not declared. */
    val codeChallengeMethodsSupported: List<String>,
) {
    /**
     * Only S256 is used. The metadata must declare it; if the field is missing or does not list it the flow cannot
     * continue (a MUST in the specification): an authorization server that does not declare it may simply ignore
     * `code_challenge`, leaving the authorization code without PKCE protection.
     */
    val supportsS256: Boolean get() = "S256" in codeChallengeMethodsSupported

    companion object {
        fun fromJson(json: JsonElement): McpAuthorizationServerMetadata? {
            val issuer = json["issuer"].stringOrNull?.takeIf { it.isNotEmpty() } ?: return null
            return McpAuthorizationServerMetadata(
                issuer = issuer,
                // The authorization / token / registration endpoints must be https; a non-https one is treated as
                // absent, and the flow then stops on its own.
                authorizationEndpoint = json["authorization_endpoint"].stringOrNull?.takeIf(McpOrigin::isHttps),
                tokenEndpoint = json["token_endpoint"].stringOrNull?.takeIf(McpOrigin::isHttps),
                registrationEndpoint = json["registration_endpoint"].stringOrNull?.takeIf(McpOrigin::isHttps),
                scopesSupported = json["scopes_supported"].stringList(),
                clientIdMetadataDocumentSupported = json["client_id_metadata_document_supported"].booleanOrNull ?: false,
                authorizationResponseIssParameterSupported =
                json["authorization_response_iss_parameter_supported"].booleanOrNull ?: false,
                codeChallengeMethodsSupported = json["code_challenge_methods_supported"].stringList(),
            )
        }
    }
}

private fun JsonElement?.stringList(): List<String> = (this as? JsonArray)?.mapNotNull { it.stringOrNull }.orEmpty()

// ── Client registration ────────────────────────────────────

enum class McpClientRegistrationKind(val wireValue: String) {
    /**
     * Client ID Metadata Document (CIMD): `client_id` is a self-hosted https URL, portable across authorization
     * servers.
     */
    Cimd("cimd"),

    /**
     * Dynamic Client Registration (RFC 7591; the specification marks it deprecated, the fallback when CIMD is
     * unavailable).
     */
    Dcr("dcr"),
}

data class McpClientRegistration(
    val kind: McpClientRegistrationKind,
    val clientId: String,
    /**
     * Credentials are bound to the issuer and not reused across authorization servers (except CIMD, which is a
     * self-hosted URL).
     */
    val issuer: String,
) {
    /** A DCR `client_id` is a credential, so it is kept out of the string description. */
    override fun toString(): String = "McpClientRegistration(kind=${kind.wireValue}, issuer=$issuer, clientId=<redacted>)"
}

object McpClientRegistrationDecision {
    /**
     * Priority: pre-registered credentials (this client has none, skipped) → CIMD → DCR → null if neither (meaning
     * "access token required"). CIMD needs a document to point at: with an empty [clientMetadataUrl] it is skipped
     * even when the authorization server supports it.
     */
    fun decide(
        metadata: McpAuthorizationServerMetadata,
        clientMetadataUrl: String = McpClientMetadata.DOCUMENT_URL,
    ): McpClientRegistrationKind? = when {
        metadata.clientIdMetadataDocumentSupported && clientMetadataUrl.isNotEmpty() -> McpClientRegistrationKind.Cimd
        metadata.registrationEndpoint != null -> McpClientRegistrationKind.Dcr
        else -> null
    }
}

/** How this app identifies itself to authorization servers, and where they send the user back. */
object McpClientMetadata {
    /**
     * URL of the client metadata document that identifies this build (it is the `client_id` under the Client ID
     * Metadata Document scheme).
     *
     * Empty by default: nobody hosts such a document for an app you build yourself, so that registration method is
     * skipped and dynamic client registration is used. If you do host one, build with
     * `-PORIVEO_MCP_CLIENT_METADATA_URL=https://your.host/oauth/mcp-client.json`; the document must list
     * [REDIRECT_URI] among its `redirect_uris`.
     */
    val DOCUMENT_URL: String = BuildConfig.MCP_CLIENT_METADATA_URL.trim()
    const val CLIENT_NAME = "Oriveo"

    /** The redirect URI: a custom scheme, received by [McpOAuthRedirectActivity]. */
    const val REDIRECT_URI = "oriveo://mcp/oauth/callback"

    /** Every redirect URI this app registers (dynamic registration sends exactly this list). */
    val REDIRECT_URIS = listOf(REDIRECT_URI)

    /** DCR registration request body (RFC 7591). Native apps MUST specify `application_type: "native"`. */
    fun registrationBody(scope: String?): JsonElement = buildJsonObject {
        put("client_name", CLIENT_NAME)
        put("redirect_uris", JsonArray(REDIRECT_URIS.map(::JsonPrimitive)))
        put("grant_types", JsonArray(listOf(JsonPrimitive("authorization_code"), JsonPrimitive("refresh_token"))))
        put("response_types", JsonArray(listOf(JsonPrimitive("code"))))
        put("token_endpoint_auth_method", "none")
        put("application_type", "native")
        if (!scope.isNullOrEmpty()) put("scope", scope)
    }
}

// ── Canonical URI (RFC 8707) ───────────────────────────────

object McpCanonicalUri {
    /** Lowercase scheme and host, no fragment, and (SHOULD) no trailing slash. */
    fun canonical(url: String): String {
        val uri = McpOrigin.parse(url) ?: return url
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return url
        val host = uri.host?.lowercase(Locale.ROOT) ?: return url
        var path = uri.rawPath.orEmpty()
        if (path.length > 1 && path.endsWith("/")) path = path.dropLast(1)
        val out = StringBuilder("$scheme://")
        uri.rawUserInfo?.let { out.append(it).append('@') }
        out.append(host)
        if (uri.port >= 0) out.append(':').append(uri.port)
        out.append(path)
        uri.rawQuery?.let { out.append('?').append(it) }
        return out.toString()
    }
}

// ── PKCE (S256) and random values ──────────────────────────

object McpPkce {
    /** OAuth 2.1 §7.5.2: `code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))`. */
    fun codeChallenge(verifier: String): String =
        base64Url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))

    fun base64Url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
}

object McpAuthorizationRandom {
    private val random = SecureRandom()
    private const val VERIFIER_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    /** `state` is always used (the specification only says "if used"). */
    fun state(): String = McpPkce.base64Url(ByteArray(16).also(random::nextBytes))

    /** A `code_verifier` of 43 to 128 unreserved characters. */
    fun codeVerifier(): String = String(CharArray(64) { VERIFIER_ALPHABET[random.nextInt(VERIFIER_ALPHABET.length)] })
}

// ── Authorization / token requests (pure functions, easy to replay against fixtures) ──

data class McpFormField(val name: String, val value: String) {
    /**
     * Form values include the authorization code, verifier, refresh token and `client_id`, so none of them enter the
     * string description.
     */
    override fun toString(): String = "McpFormField($name=<redacted>)"
}

/**
 * Percent-encodes every byte outside the RFC 3986 unreserved set (the same rule for forms and the authorization request
 * query string).
 */
object McpPercentEncoding {
    fun encode(value: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val char = (byte.toInt() and 0xFF).toChar()
            if (char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '-' || char == '.' || char == '_' || char == '~') {
                out.append(char)
            } else {
                out.append('%').append(String.format("%02X", byte.toInt() and 0xFF))
            }
        }
        return out.toString()
    }

    /**
     * Percent-decodes (`+` is not a space: the redirect URI is parsed per RFC 3986, not as a form). Malformed escapes
     * are kept as is.
     */
    fun decode(value: String): String {
        val bytes = java.io.ByteArrayOutputStream()
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '%' && index + 2 < value.length) {
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (hex != null) {
                    bytes.write(hex)
                    index += 3
                    continue
                }
            }
            bytes.write(char.toString().toByteArray(Charsets.UTF_8))
            index += 1
        }
        return bytes.toString(Charsets.UTF_8.name())
    }

    fun encodeForm(fields: List<McpFormField>): String =
        fields.joinToString("&") { encode(it.name) + "=" + encode(it.value) }

    /** Query string → ordered key/value pairs (the last occurrence of a repeated key wins). */
    fun parseQuery(rawQuery: String?): Map<String, String> {
        if (rawQuery.isNullOrEmpty()) return emptyMap()
        val result = linkedMapOf<String, String>()
        for (part in rawQuery.split('&')) {
            if (part.isEmpty()) continue
            val equals = part.indexOf('=')
            val name = decode(if (equals >= 0) part.substring(0, equals) else part)
            val value = if (equals >= 0) decode(part.substring(equals + 1)) else ""
            result[name] = value
        }
        return result
    }
}

class McpAuthorizationRequest(
    /**
     * The full authorization page URL. Its query string carries `state`, `code_challenge` and `client_id`; do not log
     * it whole.
     */
    val url: String,
    val state: String,
    val codeVerifier: String,
    val issuer: String,
    val resource: String,
    val redirectUri: String,
    val clientId: String,
    val scope: String?,
) {
    /** The parsed (decoded) query items, convenient for assertions. */
    val queryItems: Map<String, String> get() = McpPercentEncoding.parseQuery(McpOrigin.parse(url)?.rawQuery)

    /** Reports only the authorization endpoint (without the query string) and the issuer. */
    override fun toString(): String =
        "McpAuthorizationRequest(endpoint=${url.substringBefore('?')}, issuer=$issuer, " +
            "clientId=<redacted>, state=<redacted>, codeVerifier=<redacted>)"
}

/**
 * Token endpoint response. Neither `expires_in` nor `refresh_token` is guaranteed (clients MUST NOT assume a refresh
 * token is issued).
 */
class McpTokenResponse private constructor(
    val accessToken: String,
    /** Seconds. */
    val expiresIn: Double?,
    val refreshToken: String?,
) {
    /** Tokens are kept out of the string description. */
    override fun toString(): String =
        "McpTokenResponse(accessToken=<redacted>, refreshToken=${if (refreshToken == null) "null" else "<redacted>"}, expiresIn=$expiresIn)"

    companion object {
        /** Upper bound for the lifetime: ten years. */
        const val MAX_EXPIRES_IN_SECONDS = 10.0 * 365 * 24 * 3600

        fun fromJson(json: JsonElement): McpTokenResponse? {
            val accessToken = json["access_token"].stringOrNull?.takeIf { it.isNotEmpty() } ?: return null
            // Only `Authorization: Bearer` is ever sent. A token the server explicitly labels as another type (DPoP,
            // MAC, ...) cannot be used as a Bearer token.
            val tokenType = json["token_type"].stringOrNull
            if (tokenType != null && tokenType.lowercase(Locale.ROOT) != "bearer") return null
            // A non-positive lifetime is meaningless and treated as absent (otherwise every call would see "about to
            // expire" and refresh); absurdly large values are capped.
            val expiresIn = json["expires_in"].doubleOrNull?.takeIf { it > 0 }?.let { minOf(it, MAX_EXPIRES_IN_SECONDS) }
            val refreshToken = json["refresh_token"].stringOrNull?.takeIf { it.isNotEmpty() }
            return McpTokenResponse(accessToken, expiresIn, refreshToken)
        }
    }
}

object McpOAuthRequests {
    /**
     * Authorization request: `resource` MUST be present; PKCE uses S256; `state` is mandatory. A query string already
     * on the authorization endpoint is preserved.
     */
    fun authorizationRequest(
        authorizationEndpoint: String,
        clientId: String,
        redirectUri: String,
        state: String,
        codeVerifier: String,
        issuer: String,
        resource: String,
        scope: String?,
    ): McpAuthorizationRequest {
        val fields = mutableListOf(
            McpFormField("response_type", "code"),
            McpFormField("client_id", clientId),
            McpFormField("redirect_uri", redirectUri),
            McpFormField("state", state),
            McpFormField("code_challenge", McpPkce.codeChallenge(codeVerifier)),
            McpFormField("code_challenge_method", "S256"),
            McpFormField("resource", resource),
        )
        if (!scope.isNullOrEmpty()) fields += McpFormField("scope", scope)
        val base = authorizationEndpoint.substringBefore('#')
        val separator = if (base.contains('?')) "&" else "?"
        return McpAuthorizationRequest(
            url = base + separator + McpPercentEncoding.encodeForm(fields),
            state = state,
            codeVerifier = codeVerifier,
            issuer = issuer,
            resource = resource,
            redirectUri = redirectUri,
            clientId = clientId,
            scope = scope,
        )
    }

    /** Token exchange form: `resource` MUST be present, and `code_verifier` matches the S256 challenge. */
    fun tokenExchangeForm(code: String, clientId: String, redirectUri: String, codeVerifier: String, resource: String) = listOf(
        McpFormField("grant_type", "authorization_code"),
        McpFormField("code", code),
        McpFormField("redirect_uri", redirectUri),
        McpFormField("client_id", clientId),
        McpFormField("code_verifier", codeVerifier),
        McpFormField("resource", resource),
    )

    /** Refresh token form: `resource` MUST be present. */
    fun refreshForm(refreshToken: String, clientId: String, resource: String) = listOf(
        McpFormField("grant_type", "refresh_token"),
        McpFormField("refresh_token", refreshToken),
        McpFormField("client_id", clientId),
        McpFormField("resource", resource),
    )
}

// ── Redirect validation ────────────────────────────────────

enum class McpCallbackRejectionReason(val wireValue: String) {
    StateMismatch("state_mismatch"),
    IssMissingWhileDeclaredSupported("iss_missing_while_declared_supported"),
    IssMismatch("iss_mismatch"),
    IssMismatchTrailingSlashNotNormalized("iss_mismatch_trailing_slash_not_normalized"),
    RedirectUriMismatch("redirect_uri_mismatch"),
    AuthorizationError("authorization_error"),
    MissingCode("missing_code"),
}

sealed class McpCallbackValidation {
    class Accepted(val code: String) : McpCallbackValidation() {
        override fun toString(): String = "Accepted(code=<redacted>)"
    }

    data class Rejected(val reason: McpCallbackRejectionReason) : McpCallbackValidation()

    val isAccepted: Boolean get() = this is Accepted
    val rejection: McpCallbackRejectionReason? get() = (this as? Rejected)?.reason
}

object McpRedirectUri {
    /** The redirect must go to the URI we registered (compares scheme / host / path, ignoring the query string). */
    fun matches(callbackUrl: String, registered: String): Boolean {
        val callback = McpOrigin.parse(callbackUrl) ?: return false
        val expected = McpOrigin.parse(registered) ?: return false
        return callback.scheme?.lowercase(Locale.ROOT) == expected.scheme?.lowercase(Locale.ROOT) &&
            callback.host?.lowercase(Locale.ROOT) == expected.host?.lowercase(Locale.ROOT) &&
            normalizedPath(callback.rawPath) == normalizedPath(expected.rawPath)
    }

    private fun normalizedPath(path: String?): String = if (path.isNullOrEmpty()) "/" else path
}

object McpCallbackValidator {
    /**
     * Validates `iss` against the 2×2 table of RFC 9207 §2.4, **without any normalization before comparing**.
     *
     * | `authorization_response_iss_parameter_supported` | `iss` in the response | Action |
     * |---|---|---|
     * | true | present | string comparison |
     * | true | absent | reject |
     * | false or missing | present | string comparison |
     * | false or missing | absent | accept |
     */
    fun validate(
        params: Map<String, String>,
        expectedState: String,
        expectedIssuer: String,
        issParameterSupported: Boolean,
        callbackUrl: String? = null,
        registeredRedirectUri: String? = null,
    ): McpCallbackValidation {
        // A redirect to anything other than the registered URI is always rejected (at this point there is no token to
        // save yet).
        if (callbackUrl != null && registeredRedirectUri != null && !McpRedirectUri.matches(callbackUrl, registeredRedirectUri)) {
            return McpCallbackValidation.Rejected(McpCallbackRejectionReason.RedirectUriMismatch)
        }
        if (params["state"] != expectedState) return McpCallbackValidation.Rejected(McpCallbackRejectionReason.StateMismatch)
        val iss = params["iss"]
        if (issParameterSupported && iss == null) {
            return McpCallbackValidation.Rejected(McpCallbackRejectionReason.IssMissingWhileDeclaredSupported)
        }
        if (iss != null && iss != expectedIssuer) {
            return McpCallbackValidation.Rejected(
                if (iss == "$expectedIssuer/") {
                    McpCallbackRejectionReason.IssMismatchTrailingSlashNotNormalized
                } else {
                    McpCallbackRejectionReason.IssMismatch
                },
            )
        }
        // When iss does not match, error / error_description / error_uri MUST NOT be acted on or displayed; reaching
        // this line means iss has passed.
        if (params["error"] != null) return McpCallbackValidation.Rejected(McpCallbackRejectionReason.AuthorizationError)
        val code = params["code"]?.takeIf { it.isNotEmpty() } ?: return McpCallbackValidation.Rejected(McpCallbackRejectionReason.MissingCode)
        return McpCallbackValidation.Accepted(code)
    }

    /** Extracts the query parameters from the redirect URL. */
    fun parameters(url: String): Map<String, String> = McpPercentEncoding.parseQuery(McpOrigin.parse(url)?.rawQuery)
}

// ── Scope selection ────────────────────────────────────────

object McpScope {
    /**
     * Prefers the `scope` from the 401; without it, uses `scopes_supported` from the protected resource metadata; adds
     * `offline_access` when the authorization server's `scopes_supported` contains it (clients MAY request refresh
     * tokens).
     */
    fun resolve(challengeScope: String?, resourceScopes: List<String>, authorizationServerScopes: List<String>): String? {
        val parts = if (!challengeScope.isNullOrBlank()) {
            challengeScope.split(' ').filter { it.isNotEmpty() }.toMutableList()
        } else {
            resourceScopes.toMutableList()
        }
        if ("offline_access" in authorizationServerScopes && "offline_access" !in parts) parts += "offline_access"
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" ")
    }
}

// ── Transport and browser session abstractions ─────────────

/**
 * HTTP transport for the OAuth side. Any (non-cancellation) exception thrown by an implementation means "could not
 * connect this time" (network / timeout / refused redirect), which is different from "the server explicitly answered
 * with a status code": the former is transient, only the latter is a conclusion.
 */
interface McpAuthTransport {
    suspend fun get(url: String): McpHttpResponse
    suspend fun postForm(url: String, form: List<McpFormField>): McpHttpResponse
    suspend fun postJson(url: String, body: JsonElement): McpHttpResponse
}

/** The overall deadline expired (not a coroutine cancellation: it is one form of "could not connect this time"). */
class McpAuthTimeoutException : InterruptedIOException("mcp auth request timed out")

/**
 * Production transport. All three constraints are enforced in [McpHttp]:
 * - https only: authorization / token / registration / metadata endpoints that are not https are never requested;
 * - redirects: metadata GETs follow same-origin https only; the token and registration endpoints **never follow
 *   redirects**, because the request body carries the authorization code, verifier and refresh token, and following a
 *   3xx would hand them to another address;
 * - a 1 MB response body limit and an overall deadline.
 */
class McpHttpAuthTransport(
    private val raw: McpRawTransport = KtorMcpRawTransport(),
    private val timeoutMillis: Long = 60_000L,
) : McpAuthTransport {

    override suspend fun get(url: String): McpHttpResponse =
        send(McpHttpRequest(url, "GET", listOf("Accept" to "application/json"), idleTimeoutMillis = idle()), McpRedirectPolicy.SameOriginHttps)

    override suspend fun postForm(url: String, form: List<McpFormField>): McpHttpResponse = send(
        McpHttpRequest(
            url = url,
            method = "POST",
            headers = listOf("Accept" to "application/json"),
            body = McpPercentEncoding.encodeForm(form).toByteArray(Charsets.UTF_8),
            contentType = "application/x-www-form-urlencoded",
            idleTimeoutMillis = idle(),
        ),
        McpRedirectPolicy.Never,
    )

    override suspend fun postJson(url: String, body: JsonElement): McpHttpResponse = send(
        McpHttpRequest(
            url = url,
            method = "POST",
            headers = listOf("Accept" to "application/json"),
            body = McpJson.ordered(body).toByteArray(Charsets.UTF_8),
            contentType = "application/json",
            idleTimeoutMillis = idle(),
        ),
        McpRedirectPolicy.Never,
    )

    private fun idle() = timeoutMillis + McpHttpLimits.IDLE_TIMEOUT_MARGIN_MILLIS

    private suspend fun send(request: McpHttpRequest, redirect: McpRedirectPolicy): McpHttpResponse = try {
        withTimeout(timeoutMillis) { McpHttp.send(request, raw, redirect, McpHttpLimits.MAX_AUTH_RESPONSE_BYTES) }
    } catch (error: TimeoutCancellationException) {
        throw McpAuthTimeoutException()
    }
}

/**
 * Browser session abstraction (the production implementation is Custom Tabs plus a custom-scheme redirect, in the UI
 * layer). Opens [url], waits for the redirect to [redirectUri] and returns the full redirect URL;
 * throws if the user cancels.
 */
interface McpBrowserSession {
    suspend fun authorize(url: String, redirectUri: String): String
}

// ── Errors ─────────────────────────────────────────────────

/** Authorizer error. **Carries no text from the server** (so that `error_description` is never surfaced). */
class McpAuthorizerException(
    val kind: Kind,
    val rejection: McpCallbackRejectionReason? = null,
) : Exception(kind.name + (rejection?.let { ":" + it.wireValue } ?: "")) {

    enum class Kind {
        /**
         * The client cannot register automatically (all metadata unavailable / none of the registration mechanisms
         * available); leads to "access token required".
         */
        NotAutoRegisterable,
        RegistrationFailed,

        /**
         * The authorization server considers our client registration invalid (`invalid_client` /
         * `unauthorized_client`). The locally cached DCR registration has been cleared.
         */
        ClientRejected,

        /**
         * The authorization server metadata is **definitively** unavailable (all 404 / not JSON / issuer validation
         * failed).
         */
        MetadataUnavailable,

        /**
         * Could not connect this time (network, timeout, 5xx). **A transient error**: it does not mean the credentials
         * are invalid and must not be used as a reason to ask the user to sign in again.
         */
        TemporarilyUnavailable,

        /** The redirect was rejected. */
        CallbackRejected,
        TokenRequestFailed,

        /**
         * No usable refresh token (the server did not issue one, or it was discarded after being revoked); signing in
         * again is the only option.
         */
        NoRefreshToken,

        /**
         * The credentials could not be written to the device's secure storage. Callers must not treat this sign-in /
         * refresh as persisted.
         */
        CredentialPersistenceFailed,
        Cancelled,
    }

    /** A retryable transient error: the connection state should not move to `needsAuth`. */
    val isTransient: Boolean get() = kind == Kind.TemporarilyUnavailable

    override fun equals(other: Any?): Boolean = other is McpAuthorizerException && other.kind == kind && other.rejection == rejection

    override fun hashCode(): Int = kind.hashCode() * 31 + (rejection?.hashCode() ?: 0)

    companion object {
        fun of(kind: Kind) = McpAuthorizerException(kind)

        fun rejected(reason: McpCallbackRejectionReason) = McpAuthorizerException(Kind.CallbackRejected, reason)
    }
}

// ── Discovery result and authorization attempt ─────────────

/**
 * Product of the discovery phase: **only metadata has been read, nothing has been registered with the authorization
 * server yet**. Registration (DCR) is a write to a third-party server and must wait until the user has agreed to open
 * the browser (see [McpAuthorizer.authorize]).
 */
data class McpAuthorizationPlan(
    val issuer: String,
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val registrationKind: McpClientRegistrationKind,
    /** The DCR registration endpoint (always present when `registrationKind == Dcr`). */
    val registrationEndpoint: String?,
    val scope: String?,
    val resource: String,
    /** `authorization_response_iss_parameter_supported`, needed by the 2×2 table of the redirect validation. */
    val issParameterSupported: Boolean,
) {
    /** Host of the authorization page (shown in the pre-sign-in prompt). */
    val authorizationHost: String? get() = McpOrigin.parse(authorizationEndpoint)?.host

    override fun toString(): String =
        "McpAuthorizationPlan(issuer=$issuer, registration=${registrationKind.wireValue}, resource=<redacted>)"
}

sealed class McpAuthDiscoveryOutcome {
    /** The client can register automatically; the browser may be opened (after the user consents). */
    data class Ready(val plan: McpAuthorizationPlan) : McpAuthDiscoveryOutcome()

    /** Cannot register automatically / metadata definitively unavailable → access token required. */
    data object NeedsToken : McpAuthDiscoveryOutcome()

    /**
     * The metadata could not be fetched this time (network, timeout, 5xx). Not a conclusion that an access token is
     * required; retry later.
     */
    data object TemporarilyUnavailable : McpAuthDiscoveryOutcome()
}

/**
 * Per-request record of one authorization attempt (the PKCE verifier, issuer and state are kept in the same record).
 */
class McpAuthorizationAttempt(
    val request: McpAuthorizationRequest,
    val issuer: String,
    val codeVerifier: String,
    val state: String,
    val redirectUri: String,
    val clientId: String,
    val registrationKind: McpClientRegistrationKind,
    val tokenEndpoint: String,
    val resource: String,
    val issParameterSupported: Boolean,
) {
    /** The verifier, state and `client_id` are all kept out of the string description. */
    override fun toString(): String =
        "McpAuthorizationAttempt(issuer=$issuer, registration=${registrationKind.wireValue}, " +
            "clientId=<redacted>, state=<redacted>, codeVerifier=<redacted>)"
}

// ── Authorizer ─────────────────────────────────────────────

/**
 * OAuth authorizer for remote MCP. The add flow uses it in three steps:
 *
 * 1. [discover]: reads metadata only and decides whether the client can register automatically; **does not register**.
 * 2. The caller shows the pre-sign-in prompt and the user consents.
 * 3. [authorize]: register (reusing the locally cached DCR registration) → open the browser → validate the redirect →
 *    exchange the token → persist (if requested).
 *
 * With `persist = false` the obtained tokens are returned without being stored: the add flow calls [persistCredentials]
 * after the server record is stored, so a process killed between a successful sign-in and the insert leaves no token in
 * secure storage without a server record to claim it.
 */
class McpAuthorizer(
    private val transport: McpAuthTransport,
    private val browser: McpBrowserSession,
    private val credentialStore: McpCredentialStore,
    private val now: () -> Long = System::currentTimeMillis,
    /** See [McpClientMetadata.DOCUMENT_URL]; empty means this client has no metadata document. */
    private val clientMetadataUrl: String = McpClientMetadata.DOCUMENT_URL,
) {
    /**
     * Shared refresh / registration tasks run here: cancelling the caller that started one must not cut off another
     * caller waiting on it.
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val tasksLock = Mutex()

    /**
     * Serializes concurrent refreshes for the same server: the key is the credential key, the value the refresh in
     * flight.
     */
    private val refreshTasks = ConcurrentHashMap<String, Deferred<McpCredentials>>()

    /** Serializes concurrent registrations for the same `uid + issuer`, so two flows do not each register once. */
    private val registrationTasks = ConcurrentHashMap<String, Deferred<McpClientRegistration>>()

    // ── Discovery ──────────────────────────────────────────

    /**
     * Discovers the authorization server and decides whether the client can register automatically. **Sends GETs only;
     * registers nothing and writes to no storage.**
     */
    suspend fun discover(challenge: McpAuthChallenge?, endpoint: String): McpAuthDiscoveryOutcome {
        val candidates = McpProtectedResourceDiscovery.candidates(challenge, endpoint)
        val protected = when (val fetched = fetchProtectedResourceMetadata(candidates, endpoint)) {
            is Fetched.Found -> fetched.value
            Fetched.Absent -> return McpAuthDiscoveryOutcome.NeedsToken
            Fetched.Transient -> return McpAuthDiscoveryOutcome.TemporarilyUnavailable
        }
        // With several authorization servers the first usable one is taken (RFC 9728 §7.6 leaves the choice to the
        // client); the issuer must be https.
        val issuer = protected.authorizationServers.firstOrNull(McpOrigin::isHttps) ?: return McpAuthDiscoveryOutcome.NeedsToken
        val metadata = when (val fetched = fetchAuthorizationServerMetadata(issuer)) {
            is Fetched.Found -> fetched.value
            // All three well-known locations unavailable / issuer validation failed → "cannot register the client
            // automatically"; no default endpoints are guessed.
            Fetched.Absent -> return McpAuthDiscoveryOutcome.NeedsToken
            Fetched.Transient -> return McpAuthDiscoveryOutcome.TemporarilyUnavailable
        }
        // An authorization server that does not declare S256 gets no browser sign-in and ends up where "cannot register
        // automatically" does: access token required.
        val authorizationEndpoint = metadata.authorizationEndpoint
        val tokenEndpoint = metadata.tokenEndpoint
        val kind = McpClientRegistrationDecision.decide(metadata, clientMetadataUrl)
        if (!metadata.supportsS256 || authorizationEndpoint == null || tokenEndpoint == null || kind == null) {
            return McpAuthDiscoveryOutcome.NeedsToken
        }
        return McpAuthDiscoveryOutcome.Ready(
            McpAuthorizationPlan(
                issuer = metadata.issuer,
                authorizationEndpoint = authorizationEndpoint,
                tokenEndpoint = tokenEndpoint,
                registrationKind = kind,
                registrationEndpoint = if (kind == McpClientRegistrationKind.Dcr) metadata.registrationEndpoint else null,
                scope = McpScope.resolve(challenge?.scope, protected.scopesSupported, metadata.scopesSupported),
                resource = McpCanonicalUri.canonical(endpoint),
                issParameterSupported = metadata.authorizationResponseIssParameterSupported,
            ),
        )
    }

    // ── Registration ───────────────────────────────────────

    /**
     * Obtains the client registration on this authorization server. CIMD needs no registration; DCR checks the local
     * cache first (keyed by `uid + issuer`) and registers with the authorization server only when nothing is cached,
     * then stores the result, so the same authorization server does not accumulate a pile of clients from repeated
     * registrations.
     *
     * **When to call: after the user has agreed to open the browser.** The discovery phase never calls it.
     */
    suspend fun register(plan: McpAuthorizationPlan, uid: String): McpClientRegistration {
        if (plan.registrationKind == McpClientRegistrationKind.Cimd) {
            return McpClientRegistration(McpClientRegistrationKind.Cimd, clientMetadataUrl, plan.issuer)
        }
        // An old registration whose redirect URIs have since changed (after an app update) can no longer be used;
        // register again.
        credentialStore.loadClientRegistration(plan.issuer, uid)?.takeIf { it.redirectUris == McpClientMetadata.REDIRECT_URIS }?.let {
            return McpClientRegistration(McpClientRegistrationKind.Dcr, it.clientId, it.issuer)
        }
        return shared(registrationTasks, McpCredentialStore.registrationKey(plan.issuer, uid)) { registerDynamically(plan, uid) }
    }

    private suspend fun registerDynamically(plan: McpAuthorizationPlan, uid: String): McpClientRegistration {
        val endpoint = plan.registrationEndpoint ?: throw McpAuthorizerException.of(McpAuthorizerException.Kind.RegistrationFailed)
        val response = transportCall { transport.postJson(endpoint, McpClientMetadata.registrationBody(plan.scope)) }
        if (isTransientStatus(response.status)) throw McpAuthorizerException.of(McpAuthorizerException.Kind.TemporarilyUnavailable)
        val clientId = if (response.status in 200..299) McpJson.parseOrNull(response.body)?.get("client_id").stringOrNull else null
        if (clientId.isNullOrEmpty()) throw McpAuthorizerException.of(McpAuthorizerException.Kind.RegistrationFailed)
        // Client credentials are bound to the issuer and not reused across authorization servers; they live only in the
        // device's secure storage.
        try {
            credentialStore.saveClientRegistration(McpStoredClientRegistration(clientId, plan.issuer, McpClientMetadata.REDIRECT_URIS), uid)
        } catch (error: McpCredentialStoreException) {
            throw McpAuthorizerException.of(McpAuthorizerException.Kind.CredentialPersistenceFailed)
        }
        return McpClientRegistration(McpClientRegistrationKind.Dcr, clientId, plan.issuer)
    }

    /**
     * Clears the local cache when the authorization server considers the registration invalid, so the next attempt
     * registers afresh. Only clears "the very one used this time".
     */
    private fun discardRejectedRegistration(clientId: String, issuer: String, uid: String) {
        if (credentialStore.loadClientRegistration(issuer, uid)?.clientId != clientId) return
        credentialStore.deleteClientRegistration(issuer, uid)
    }

    // ── Authorization ──────────────────────────────────────

    /**
     * Full browser sign-in: register → open the browser → validate the redirect → exchange the token → persist (when
     * [persist] is true).
     *
     * [plan] is the result of [discover]; discovery is not repeated here. If the authorization server considers the
     * cached DCR registration invalid, it is cleared, registered again, and the flow runs once more (once only).
     */
    suspend fun authorize(
        plan: McpAuthorizationPlan,
        serverId: String,
        uid: String,
        redirectUri: String = McpClientMetadata.REDIRECT_URI,
        persist: Boolean = true,
    ): McpCredentials {
        var retriesLeft = if (plan.registrationKind == McpClientRegistrationKind.Dcr) 1 else 0
        while (true) {
            val attempt = beginAuthorization(plan, uid, redirectUri)
            val callback = try {
                browser.authorize(attempt.request.url, attempt.redirectUri)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                throw McpAuthorizerException.of(McpAuthorizerException.Kind.Cancelled)
            }
            try {
                return completeAuthorization(attempt, callback, serverId, uid, persist)
            } catch (error: McpAuthorizerException) {
                if (error.kind != McpAuthorizerException.Kind.ClientRejected || retriesLeft <= 0) throw error
                retriesLeft -= 1
            }
        }
    }

    /**
     * Registers and assembles the authorization request, leaving a per-request record. Tests can inject a deterministic
     * [state] / [codeVerifier].
     */
    suspend fun beginAuthorization(
        plan: McpAuthorizationPlan,
        uid: String,
        redirectUri: String = McpClientMetadata.REDIRECT_URI,
        state: String = McpAuthorizationRandom.state(),
        codeVerifier: String = McpAuthorizationRandom.codeVerifier(),
    ): McpAuthorizationAttempt {
        val registration = register(plan, uid)
        val request = McpOAuthRequests.authorizationRequest(
            authorizationEndpoint = plan.authorizationEndpoint,
            clientId = registration.clientId,
            redirectUri = redirectUri,
            state = state,
            codeVerifier = codeVerifier,
            issuer = plan.issuer,
            resource = plan.resource,
            scope = plan.scope,
        )
        return McpAuthorizationAttempt(
            request = request,
            issuer = plan.issuer,
            codeVerifier = codeVerifier,
            state = state,
            redirectUri = redirectUri,
            clientId = registration.clientId,
            registrationKind = registration.kind,
            tokenEndpoint = plan.tokenEndpoint,
            resource = plan.resource,
            issParameterSupported = plan.issParameterSupported,
        )
    }

    /**
     * The token is exchanged only after the redirect passes validation. Every rejection returns before the token
     * exchange, and **no token is saved**.
     */
    suspend fun completeAuthorization(
        attempt: McpAuthorizationAttempt,
        callbackUrl: String,
        serverId: String,
        uid: String,
        persist: Boolean = true,
    ): McpCredentials {
        val params = McpCallbackValidator.parameters(callbackUrl)
        val validation = McpCallbackValidator.validate(
            params = params,
            expectedState = attempt.state,
            expectedIssuer = attempt.issuer,
            issParameterSupported = attempt.issParameterSupported,
            callbackUrl = callbackUrl,
            registeredRedirectUri = attempt.redirectUri,
        )
        val code = when (validation) {
            is McpCallbackValidation.Accepted -> validation.code
            is McpCallbackValidation.Rejected -> {
                // Reaching AuthorizationError means the redirect URI, state and iss have all passed validation, so
                // `error` can be trusted.
                if (validation.reason == McpCallbackRejectionReason.AuthorizationError &&
                    attempt.registrationKind == McpClientRegistrationKind.Dcr &&
                    isClientRejection(params["error"])
                ) {
                    discardRejectedRegistration(attempt.clientId, attempt.issuer, uid)
                    throw McpAuthorizerException.of(McpAuthorizerException.Kind.ClientRejected)
                }
                throw McpAuthorizerException.rejected(validation.reason)
            }
        }
        val form = McpOAuthRequests.tokenExchangeForm(code, attempt.clientId, attempt.redirectUri, attempt.codeVerifier, attempt.resource)
        val response = transportCall { transport.postForm(attempt.tokenEndpoint, form) }
        if (isTransientStatus(response.status)) throw McpAuthorizerException.of(McpAuthorizerException.Kind.TemporarilyUnavailable)
        val json = McpJson.parseOrNull(response.body)
        val tokens = if (response.status in 200..299 && json != null) McpTokenResponse.fromJson(json) else null
        if (tokens == null) {
            if (attempt.registrationKind == McpClientRegistrationKind.Dcr && isClientRejection(json?.get("error").stringOrNull)) {
                discardRejectedRegistration(attempt.clientId, attempt.issuer, uid)
                throw McpAuthorizerException.of(McpAuthorizerException.Kind.ClientRejected)
            }
            throw McpAuthorizerException.of(McpAuthorizerException.Kind.TokenRequestFailed)
        }
        // Signing in again replaces only the OAuth group of fields; a token the user pasted is kept as is.
        val previous = credentialStore.load(serverId, uid)
        val credentials = McpCredentials(
            accessToken = tokens.accessToken,
            refreshToken = tokens.refreshToken,
            expiresAtMillis = tokens.expiresIn?.let { now() + (it * 1000).toLong() },
            issuer = attempt.issuer,
            clientId = attempt.clientId,
            resource = attempt.resource,
            pastedToken = previous?.pastedToken,
        )
        if (persist) persistCredentials(credentials, serverId, uid)
        return credentials
    }

    // ── Refresh ────────────────────────────────────────────

    /**
     * Refreshes the access token. **Concurrent refreshes for the same server are serialized**: two concurrent calls
     * trigger a single refresh.
     *
     * `TemporarilyUnavailable` means "could not connect this time" (retryable, credentials kept as they are); only
     * `NoRefreshToken` / `TokenRequestFailed` / `MetadataUnavailable` mean the user has to sign in again.
     */
    suspend fun refresh(serverId: String, uid: String): McpCredentials =
        shared(refreshTasks, SecureKeyStore.mcpCredentialKey(uid, serverId)) { performRefresh(serverId, uid) }

    /**
     * Returns a usable access token before a call, refreshing first when it is about to expire. If the refresh hits a
     * transient error while the access token has in fact not expired yet, the current token is returned as usual: one
     * network hiccup should not fail the call.
     */
    suspend fun validAccessToken(serverId: String, uid: String, expirySkewMillis: Long = 60_000L): String? {
        val credentials = credentialStore.load(serverId, uid) ?: return null
        val accessToken = credentials.accessToken ?: return credentials.pastedToken
        val expiresAt = credentials.expiresAtMillis
        if (expiresAt == null || expiresAt - now() >= expirySkewMillis || credentials.refreshToken == null) return accessToken
        return try {
            refresh(serverId, uid).accessToken
        } catch (error: McpAuthorizerException) {
            if (error.isTransient && expiresAt > now()) accessToken else throw error
        }
    }

    /**
     * Stores an access token the user pasted (the "access token" sign-in method). Throws `CredentialPersistenceFailed`
     * if it cannot be written to secure storage.
     *
     * Also **clears the OAuth group** (access token, refresh token, expiry, issuer, `client_id`, `resource`):
     * [validAccessToken] prefers the OAuth access token, so leaving it in place would mean the freshly pasted token is
     * never used.
     */
    fun storePastedToken(token: String, serverId: String, uid: String) {
        persistCredentials(McpCredentials(pastedToken = token), serverId, uid)
    }

    /**
     * Writes the credentials to secure storage. Throws `CredentialPersistenceFailed` if that fails (callers must not
     * treat them as saved).
     */
    fun persistCredentials(credentials: McpCredentials, serverId: String, uid: String) {
        try {
            credentialStore.save(credentials, serverId, uid)
        } catch (error: McpCredentialStoreException) {
            throw McpAuthorizerException.of(McpAuthorizerException.Kind.CredentialPersistenceFailed)
        }
    }

    private suspend fun performRefresh(serverId: String, uid: String): McpCredentials {
        // "No refresh token" and "metadata temporarily unavailable" are different things: the former requires signing
        // in again, the latter only a later retry.
        val existing = credentialStore.load(serverId, uid)
        val refreshToken = existing?.refreshToken?.takeIf { it.isNotEmpty() }
        val issuer = existing?.issuer
        val clientId = existing?.clientId
        val resource = existing?.resource
        if (existing == null || refreshToken == null || issuer == null || clientId == null || resource == null) {
            throw McpAuthorizerException.of(McpAuthorizerException.Kind.NoRefreshToken)
        }
        val metadata = when (val fetched = fetchAuthorizationServerMetadata(issuer)) {
            is Fetched.Found -> fetched.value
            Fetched.Transient -> throw McpAuthorizerException.of(McpAuthorizerException.Kind.TemporarilyUnavailable)
            Fetched.Absent -> throw McpAuthorizerException.of(McpAuthorizerException.Kind.MetadataUnavailable)
        }
        val tokenEndpoint = metadata.tokenEndpoint ?: throw McpAuthorizerException.of(McpAuthorizerException.Kind.MetadataUnavailable)
        val response = transportCall {
            transport.postForm(tokenEndpoint, McpOAuthRequests.refreshForm(refreshToken, clientId, resource))
        }
        if (isTransientStatus(response.status)) throw McpAuthorizerException.of(McpAuthorizerException.Kind.TemporarilyUnavailable)
        val json = McpJson.parseOrNull(response.body)
        val tokens = if (response.status in 200..299 && json != null) McpTokenResponse.fromJson(json) else null
        if (tokens == null) {
            val oauthError = json?.get("error").stringOrNull
            if (oauthError == "invalid_grant") {
                // Re-read before writing: if the refresh token in storage is no longer the one just sent, something
                // else (another process, a new sign-in) has just rotated it. The revoked one is the old token, so the
                // new credentials must not be wiped and are adopted directly.
                val latest = credentialStore.load(serverId, uid)
                if (latest != null && latest.refreshToken != refreshToken) {
                    if (latest.accessToken != null) return latest
                    throw McpAuthorizerException.of(McpAuthorizerException.Kind.TokenRequestFailed)
                }
                // Still the one that was sent: the refresh token is revoked → drop the tokens, keep the client
                // registration (issuer / clientId / resource), and the connection state moves to needsAuth (fixture
                // auth/token.error.json).
                persistCredentials(
                    McpCredentials(issuer = issuer, clientId = clientId, resource = resource, pastedToken = latest?.pastedToken ?: existing.pastedToken),
                    serverId,
                    uid,
                )
            } else if (isClientRejection(oauthError)) {
                // The registration itself was judged invalid: clear the cached DCR registration; signing in again will
                // register afresh.
                discardRejectedRegistration(clientId, issuer, uid)
            }
            throw McpAuthorizerException.of(McpAuthorizerException.Kind.TokenRequestFailed)
        }
        val updated = McpCredentials(
            accessToken = tokens.accessToken,
            refreshToken = tokens.refreshToken ?: refreshToken,
            expiresAtMillis = tokens.expiresIn?.let { now() + (it * 1000).toLong() },
            issuer = issuer,
            clientId = clientId,
            resource = resource,
            pastedToken = existing.pastedToken,
        )
        // Persist immediately after a successful refresh. If the write fails, report an error instead of handing out
        // the in-memory tokens as if they were saved.
        persistCredentials(updated, serverId, uid)
        return updated
    }

    // ── Internals: shared tasks, transport classification, metadata fetching ──

    /**
     * Only one [block] runs per [key] at a time; later callers wait for the same result. The task runs in the
     * authorizer's own scope, so cancelling the initiator does not cut off the run others are waiting on.
     *
     * The task is removed from the map only **when it finishes on its own** (`invokeOnCompletion`), not by the
     * initiator's `finally`: when the initiator is cancelled the task is still running, and removing it at that moment
     * would let the next caller send a second request. The same refresh token would be used twice, and an authorization
     * server that rotates refresh tokens would revoke both.
     */
    private suspend fun <T> shared(tasks: ConcurrentHashMap<String, Deferred<T>>, key: String, block: suspend () -> T): T {
        val deferred = tasksLock.withLock {
            tasks[key]?.takeIf { it.isActive } ?: scope.async { block() }.also { created ->
                tasks[key] = created
                created.invokeOnCompletion { tasks.remove(key, created) }
            }
        }
        return deferred.await()
    }

    /**
     * Classifies errors thrown by the transport: coroutine cancellation propagates as usual, everything else is "could
     * not connect this time".
     */
    private suspend fun transportCall(block: suspend () -> McpHttpResponse): McpHttpResponse = try {
        block()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        throw McpAuthorizerException.of(McpAuthorizerException.Kind.TemporarilyUnavailable)
    }

    /**
     * The three outcomes of fetching metadata. "Definitively absent" and "could not connect this time" must stay
     * separate: the former is a conclusion, the latter only a transient error.
     */
    private sealed class Fetched<out T> {
        class Found<T>(val value: T) : Fetched<T>()
        data object Absent : Fetched<Nothing>()
        data object Transient : Fetched<Nothing>()
    }

    private suspend fun fetchProtectedResourceMetadata(candidates: List<String>, endpoint: String): Fetched<McpProtectedResourceMetadata> {
        var sawTransient = false
        for (url in candidates.filter(McpOrigin::isHttps)) {
            val response = tryGet(url)
            if (response == null || isTransientStatus(response.status)) {
                sawTransient = true
                continue
            }
            if (response.status != 200) continue
            val metadata = McpJson.parseOrNull(response.body)?.let(McpProtectedResourceMetadata::fromJson) ?: continue
            // RFC 9728 §3.3: the `resource` in the document must correspond to the MCP endpoint we requested, otherwise
            // the metadata MUST NOT be used; without this check anyone's metadata could steer us to an authorization
            // server of its choosing.
            if (!McpResourceBinding.covers(metadata.resource, endpoint)) continue
            return Fetched.Found(metadata)
        }
        return if (sawTransient) Fetched.Transient else Fetched.Absent
    }

    private suspend fun fetchAuthorizationServerMetadata(issuer: String): Fetched<McpAuthorizationServerMetadata> {
        if (!McpOrigin.isHttps(issuer)) return Fetched.Absent
        var sawTransient = false
        for (url in McpAuthorizationServerDiscovery.candidates(issuer)) {
            val response = tryGet(url)
            if (response == null || isTransientStatus(response.status)) {
                sawTransient = true
                continue
            }
            if (response.status != 200) continue
            val metadata = McpJson.parseOrNull(response.body)?.let(McpAuthorizationServerMetadata::fromJson) ?: continue
            // RFC 8414 §3.3: the `issuer` in the document MUST be **identical** to the identifier used to build the
            // URL; if it differs the document is rejected.
            if (metadata.issuer != issuer) continue
            return Fetched.Found(metadata)
        }
        return if (sawTransient) Fetched.Transient else Fetched.Absent
    }

    private suspend fun tryGet(url: String): McpHttpResponse? = try {
        transport.get(url)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        null
    }

    private fun isTransientStatus(status: Int) = status >= 500 || status == 429 || status == 408

    private fun isClientRejection(oauthError: String?) = oauthError == "invalid_client" || oauthError == "unauthorized_client"
}
