package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import java.net.URI
import java.net.InetAddress

/**
 * The single security boundary for a direct relay connection. Local-network addresses are
 * usable, but the transport still has to be validated by the system TLS stack.
 */
object RelayEndpointPolicy {
    const val HTTPS_REQUIRED_MESSAGE =
        "Use an HTTPS endpoint. Local network and VPN addresses are supported when they use a valid TLS certificate."

    private val schemeRegex = Regex("^[a-zA-Z][a-zA-Z0-9+\\-.]*://")

    data class Credentials(
        val authMode: RelayAuthMode? = null,
        val hasKey: Boolean = false,
        val sensitiveHeaders: List<String> = emptyList(),
        val sensitiveQueryKeys: List<String> = emptyList(),
    )

    data class Classification(
        val allowed: Boolean,
        val reason: String,
        val normalized: String? = null,
        val pinnedIPs: List<String> = emptyList(),
    )

    /**
     * Builds a snapshot of the credential material from relayRequested plus what the keystore
     * actually holds.
     *
     * The send path and the save path in the endpoint settings screen must go through this same
     * builder. If they diverge you get zombie connections: the settings screen reports the endpoint
     * saved successfully, and then every request is hard-rejected at send time.
     */
    fun credentialsOf(
        requested: RelayRequestedConfig?,
        hasKey: Boolean,
    ): Credentials = Credentials(
        authMode = requested?.authMode,
        hasKey = hasKey,
        sensitiveHeaders = requested?.headers.orEmpty().map { it.key }.filter(::isSensitiveName),
        sensitiveQueryKeys = requested?.queryParams.orEmpty().map { it.key }.filter(::isSensitiveName),
    )

    /**
     * The one test for "there really is credential material here": a real key, or a sensitive
     * header or query parameter.
     */
    fun hasCredentialMaterial(requested: RelayRequestedConfig?, hasKey: Boolean): Boolean {
        val credentials = credentialsOf(requested, hasKey)
        return credentials.hasKey || credentials.sensitiveHeaders.isNotEmpty() ||
            credentials.sensitiveQueryKeys.isNotEmpty()
    }

    /**
     * The single list of sensitive names for the whole app: redaction on send, the interlock on
     * save, and the masking applied when a failure card or a diagnostic view shows an upstream
     * payload all consult this one function. The display, send and save paths must never each
     * carry their own copy of what counts as a sensitive field.
     */
    fun isSensitiveName(raw: String): Boolean {
        val value = raw.lowercase()
        return value.contains("authorization") || value.contains("token") ||
            value.contains("secret") || value.contains("password") ||
            value.endsWith("key") || value == "api_key" ||
            // Account-identity material: it should not leave the device even over a cleartext
            // connection, and it is masked on every display surface too.
            value == "openai-organization"
    }

    /** The one masking placeholder used on every display surface; there is no reveal toggle. */
    const val REDACTED_PLACEHOLDER = "***hidden"

    /**
     * Every credential a single request actually carries in cleartext: the values of sensitive
     * headers with any `Bearer ` prefix stripped, plus the values of sensitive query parameters.
     * The decision reuses [isSensitiveName] rather than starting a second list. Any non-empty
     * credential must be masked in full; short keys get no exemption.
     */
    fun credentialMaterial(namedValues: Iterable<Pair<String, String>>): List<String> =
        namedValues
            .filter { isSensitiveName(it.first) }
            .map { it.second.removePrefix("Bearer ").trim() }
            .filter(String::isNotBlank)

    /**
     * Replaces every occurrence of a cleartext credential in a piece of text. Upstreams, and
     * self-hosted gateways and relays especially, routinely echo the key they received straight
     * back into the error body (`Invalid API key: sk-...`), which turns failure cards, diagnostic
     * history, screenshots and support chats into a second leak surface. A credential must never
     * appear on a display surface regardless of its length; only empty values are skipped.
     */
    fun redactCredentials(text: String, credentials: Collection<String>): String {
        var output = text
        for (credential in credentials) {
            val trimmed = credential.trim()
            if (trimmed.isEmpty()) continue
            output = output.replace(trimmed, REDACTED_PLACEHOLDER)
        }
        return output
    }

    fun classify(
        raw: String,
        securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
        resolvedIPs: List<String> = emptyList(),
        recheckResolvedIPs: List<String>? = null,
        redirects: List<String> = emptyList(),
        credentials: Credentials? = null,
    ): Classification {
        val trimmed = raw.trim().trimEnd('/').takeIf { it.isNotEmpty() } ?: return denied("invalid_url")
        val localMode = securityMode == RelayConnectionSecurityMode.LocalHttp ||
            securityMode == RelayConnectionSecurityMode.PrivateVpn
        val withScheme = if (schemeRegex.containsMatchIn(trimmed)) trimmed else "${if (localMode) "http" else "https"}://$trimmed"
        return runCatching {
            val uri = URI(withScheme)
            if (uri.host.isNullOrEmpty()) return@runCatching denied("invalid_url")
            if (uri.userInfo != null) return@runCatching denied("userinfo")
            if (uri.rawQuery != null) return@runCatching denied("embedded_query")
            if (uri.scheme.equals("https", ignoreCase = true)) {
                return@runCatching Classification(true, "encrypted_remote", withScheme, resolvedIPs.distinct())
            }
            if (!uri.scheme.equals("http", ignoreCase = true)) return@runCatching denied("unsupported_scheme")
            if (!localMode) return@runCatching denied("cleartext_not_allowed")
            if (credentials != null && (
                    credentials.authMode?.let { it != RelayAuthMode.None } == true || credentials.hasKey ||
                        credentials.sensitiveHeaders.isNotEmpty() || credentials.sensitiveQueryKeys.isNotEmpty()
                )) return@runCatching denied("cleartext_credentials")

            val initialIPs = (resolvedIPs.ifEmpty { literalHostIPs(uri.host) }).distinct()
            val initial = classifyResolvedSet(initialIPs, securityMode)
            if (!initial.first) return@runCatching denied(initial.second)
            if (recheckResolvedIPs != null) {
                val rechecked = recheckResolvedIPs.distinct()
                val result = classifyResolvedSet(rechecked, securityMode)
                if (!result.first || rechecked.toSet() != initialIPs.toSet()) return@runCatching denied("dns_rebinding")
            }
            redirects.forEach { rawRedirect ->
                val redirect = uri.resolve(rawRedirect)
                if (origin(uri) != origin(redirect)) return@runCatching denied("cross_origin_redirect")
                if (!redirect.scheme.equals("http", ignoreCase = true)) return@runCatching denied("redirect_scheme_changed")
            }
            Classification(true, initial.second, withScheme, initialIPs)
        }.getOrElse { denied("invalid_url") }
    }

    fun normalize(
        raw: String,
        securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
    ): String? {
        val result = classify(raw, securityMode)
        return result.normalized.takeIf { result.allowed }
    }

    fun requireSecure(baseUrl: String?): String = normalize(baseUrl.orEmpty())
        ?: throw ProviderServiceError.InvalidConfiguration(HTTPS_REQUIRED_MESSAGE)

    fun requireConfigured(
        baseUrl: String?,
        securityMode: RelayConnectionSecurityMode,
        credentials: Credentials? = null,
    ): String {
        val structuralResolution = if (securityMode == RelayConnectionSecurityMode.RemoteHttps) emptyList()
        else resolveHostIPs(baseUrl.orEmpty())
        val result = classify(
            raw = baseUrl.orEmpty(),
            securityMode = securityMode,
            resolvedIPs = structuralResolution,
            credentials = credentials,
        )
        return result.normalized.takeIf { result.allowed }
            ?: throw ProviderServiceError.InvalidConfiguration(result.reason)
    }

    /**
     * The shared DNS evidence entry point for both the save-time check and the runtime path.
     * If the host cannot be resolved this returns empty; it never fabricates a loopback answer.
     */
    fun resolveHostIPs(raw: String): List<String> {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return emptyList()
        val withScheme = if (schemeRegex.containsMatchIn(trimmed)) trimmed else "http://$trimmed"
        val host = runCatching { URI(withScheme).host }.getOrNull()?.takeIf(String::isNotBlank)
            ?: return emptyList()
        literalHostIPs(host).takeIf { it.isNotEmpty() }?.let { return it }
        return runCatching {
            InetAddress.getAllByName(host).mapNotNull { it.hostAddress?.substringBefore('%') }.distinct()
        }.getOrDefault(emptyList())
    }

    private fun classifyResolvedSet(
        ips: List<String>,
        securityMode: RelayConnectionSecurityMode,
    ): Pair<Boolean, String> {
        if (ips.isEmpty()) return false to "unknown_address"
        val results = ips.map { classifyIP(it, securityMode) }
        val allowed = results.filter { it.first }
        if (allowed.isNotEmpty() && allowed.size != results.size) return false to "mixed_resolution"
        if (allowed.isEmpty()) return false to "public_address"
        val reasons = allowed.map { it.second }.toSet()
        return true to when {
            "private_vpn" in reasons -> "private_vpn"
            "link_local" in reasons -> "link_local"
            "private_lan" in reasons -> "private_lan"
            else -> "loopback"
        }
    }

    private fun classifyIP(raw: String, securityMode: RelayConnectionSecurityMode): Pair<Boolean, String> {
        val value = raw.lowercase().trim('[', ']')
        val octets = value.split('.').mapNotNull(String::toIntOrNull)
        if (octets.size == 4 && octets.all { it in 0..255 }) {
            val (a, b) = octets
            if (a == 127) return true to "loopback"
            if (a == 10 || (a == 172 && b in 16..31) || (a == 192 && b == 168)) return true to "private_lan"
            if (a == 169 && b == 254) return true to "link_local"
            if (a == 100 && b in 64..127 && securityMode == RelayConnectionSecurityMode.PrivateVpn) return true to "private_vpn"
            return false to "public_address"
        }
        if (value == "::1") return true to "loopback"
        if (value.startsWith("fd7a:115c:a1e0:")) {
            return if (securityMode == RelayConnectionSecurityMode.PrivateVpn) true to "private_vpn" else false to "public_address"
        }
        if (value.startsWith("fc") || value.startsWith("fd")) return true to "private_lan"
        if (listOf("fe8", "fe9", "fea", "feb").any(value::startsWith)) return true to "link_local"
        return false to "public_address"
    }

    private fun literalHostIPs(host: String): List<String> =
        host.trim('[', ']').takeIf { it.contains(':') || it.split('.').size == 4 }?.let(::listOf).orEmpty()

    private fun origin(uri: URI): Triple<String, String, Int> = Triple(
        uri.scheme.lowercase(),
        uri.host.lowercase(),
        if (uri.port != -1) uri.port else if (uri.scheme.equals("https", true)) 443 else 80,
    )

    private fun denied(reason: String) = Classification(false, reason)
}
