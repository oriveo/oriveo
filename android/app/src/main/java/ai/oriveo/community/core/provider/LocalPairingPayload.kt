package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

data class LocalPairingCandidate(val endpoint: String, val securityMode: RelayConnectionSecurityMode)

data class LocalPairingPayload(
    val engine: LocalEngineKind,
    val candidates: List<LocalPairingCandidate>,
    val authMode: RelayAuthMode,
    val name: String?,
    val fingerprint: String?,
) {
    val endpoint get() = candidates.first().endpoint
    val securityMode get() = candidates.first().securityMode

    companion object {
        private val decoder = Json { ignoreUnknownKeys = true }

        fun decode(raw: String): LocalPairingPayload {
            val trimmed = raw.trim()
            if (trimmed.startsWith("oriveo://")) return decodeLegacyUri(trimmed)
            val jsonText = if (trimmed.startsWith("{")) trimmed else String(
                Base64.getUrlDecoder().decode(trimmed),
                StandardCharsets.UTF_8,
            )
            val element = decoder.parseToJsonElement(jsonText)
            require(!containsCredentialKey(element)) { "pairing_payload_contains_secret" }
            val wire = decoder.decodeFromString<Wire>(jsonText)
            require(wire.v == 1 && wire.urls.isNotEmpty()) { "invalid_pairing_payload" }
            val engine = LocalEngineKind.entries.firstOrNull { it.name.equals(wire.engine, ignoreCase = true) }
                ?: error("invalid_pairing_payload")
            val authMode = RelayAuthMode.entries.firstOrNull { it.value == wire.auth }
                ?: error("invalid_pairing_payload")
            return LocalPairingPayload(
                engine = engine,
                candidates = wire.urls.map { candidate(it, wire.fingerprint) },
                authMode = authMode,
                name = wire.name,
                fingerprint = wire.fingerprint,
            )
        }

        private fun decodeLegacyUri(raw: String): LocalPairingPayload {
            val uri = URI(raw)
            require(uri.scheme == "oriveo" && uri.host == "local-provider") { "unsupported_pairing_payload" }
            val values = (uri.rawQuery ?: "").split('&').filter(String::isNotEmpty).associate { part ->
                val pieces = part.split('=', limit = 2)
                decodePart(pieces[0]) to decodePart(pieces.getOrElse(1) { "" })
            }
            require(values.keys.none(::isCredentialName)) { "pairing_payload_contains_secret" }
            require(values["v"] == "1" && values["auth"] == "none") { "invalid_pairing_payload" }
            val mode = RelayConnectionSecurityMode.entries.firstOrNull { it.value == values["mode"] }
            require(mode == RelayConnectionSecurityMode.LocalHttp || mode == RelayConnectionSecurityMode.PrivateVpn)
            val endpoint = values["endpoint"].orEmpty().also { requireCredentialFree(it) }
            val engine = LocalEngineKind.entries.first { it.name.equals(values["engine"], ignoreCase = true) }
            return LocalPairingPayload(engine, listOf(LocalPairingCandidate(endpoint, mode)), RelayAuthMode.None, values["name"], null)
        }

        private fun candidate(endpoint: String, fingerprint: String?): LocalPairingCandidate {
            requireCredentialFree(endpoint)
            val uri = URI(endpoint)
            if (uri.scheme.equals("https", ignoreCase = true)) {
                require(fingerprint?.startsWith("sha256:") == true) { "missing_tofu_fingerprint" }
                return LocalPairingCandidate(endpoint, RelayConnectionSecurityMode.TofuHttps)
            }
            require(uri.scheme.equals("http", ignoreCase = true)) { "invalid_pairing_payload" }
            return LocalPairingCandidate(endpoint, if (isTailscaleHost(uri.host)) RelayConnectionSecurityMode.PrivateVpn else RelayConnectionSecurityMode.LocalHttp)
        }

        private fun requireCredentialFree(endpoint: String) {
            val uri = URI(endpoint)
            require(endpoint.isNotEmpty() && uri.userInfo == null && queryNames(uri).none(::isCredentialName)) {
                "pairing_payload_contains_secret"
            }
        }

        private fun containsCredentialKey(element: JsonElement): Boolean = when (element) {
            is JsonObject -> element.any { isCredentialName(it.key) || containsCredentialKey(it.value) }
            is JsonArray -> element.any(::containsCredentialKey)
            else -> false
        }

        private fun isTailscaleHost(raw: String): Boolean {
            val host = raw.lowercase()
            if (host.startsWith("fd7a:115c:a1e0:")) return true
            val octets = host.split('.').mapNotNull(String::toIntOrNull)
            return octets.size == 4 && octets[0] == 100 && octets[1] in 64..127
        }

        private fun decodePart(value: String): String = URLDecoder.decode(value, StandardCharsets.UTF_8.name())
        private fun queryNames(uri: URI): List<String> = (uri.rawQuery ?: "").split('&').filter(String::isNotEmpty).map { decodePart(it.substringBefore('=')) }
        private fun isCredentialName(raw: String): Boolean {
            val key = raw.lowercase().filter(Char::isLetter)
            return key != "auth" && (key == "key" || key.endsWith("key") || "token" in key
                || "secret" in key || "password" in key || "credential" in key || "authorization" in key)
        }
    }

    @Serializable
    private data class Wire(
        val v: Int,
        val name: String? = null,
        val urls: List<String>,
        val engine: String,
        val auth: String,
        val fingerprint: String? = null,
    )
}
