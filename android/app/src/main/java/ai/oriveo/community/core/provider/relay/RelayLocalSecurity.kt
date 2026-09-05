package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import io.ktor.client.plugins.api.SendingRequest
import io.ktor.client.plugins.api.createClientPlugin
import io.ktor.http.Url
import io.ktor.http.HttpHeaders
import io.ktor.util.AttributeKey
import java.net.InetAddress
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal const val RELAY_SECURITY_MODE_HEADER = "X-Oriveo-Internal-Relay-Security-Mode"
internal const val RELAY_CERTIFICATE_FINGERPRINT_HEADER = "X-Oriveo-Internal-Relay-Certificate-Fingerprint"

private val pinnedAddressesKey = AttributeKey<Set<String>>("OriveoRelayPinnedAddresses")
private val logicalUrlKey = AttributeKey<Url>("OriveoRelayLogicalUrl")
private val securityModeKey = AttributeKey<RelayConnectionSecurityMode>("OriveoRelaySecurityMode")
private val certificateFingerprintKey = AttributeKey<String>("OriveoRelayCertificateFingerprint")
internal fun relayLocalSecurityPlugin() = createClientPlugin("RelayLocalSecurity") {
    onRequest { request, _ ->
        val mode = request.attributes.getOrNull(securityModeKey)
            ?: modeFrom(request.headers[RELAY_SECURITY_MODE_HEADER])
        val certificateFingerprint = request.attributes.getOrNull(certificateFingerprintKey)
            ?: request.headers[RELAY_CERTIFICATE_FINGERPRINT_HEADER]
        val url = request.attributes.getOrNull(logicalUrlKey) ?: request.url.build()
        requireAllowedURL(url, mode)
        request.attributes.put(securityModeKey, mode)
        request.attributes.put(logicalUrlKey, url)
        certificateFingerprint?.let { request.attributes.put(certificateFingerprintKey, it) }
        if (mode == RelayConnectionSecurityMode.TofuHttps) {
            require(url.protocol.name == "https" && validFingerprint(certificateFingerprint)) { "tofu_fingerprint_required" }
            request.attributes.put(pinnedAddressesKey, resolveAndClassify(url, mode))
            verifyTlsPin(url, requireNotNull(certificateFingerprint))
        } else if (mode != RelayConnectionSecurityMode.RemoteHttps) {
            requireNoSensitiveMaterial(request.headers.entries().map { it.key }, url.parameters.names())
            val pinned = resolveAndClassify(url, mode)
            request.attributes.put(pinnedAddressesKey, pinned)
            request.url.host = pinned.sorted().first()
            request.headers[HttpHeaders.Host] = if (url.port == url.protocol.defaultPort) url.host else "${url.host}:${url.port}"
        }
    }

    on(SendingRequest) { request, _ ->
        val mode = request.attributes.getOrNull(securityModeKey)
            ?: modeFrom(request.headers[RELAY_SECURITY_MODE_HEADER])
        val certificateFingerprint = request.attributes.getOrNull(certificateFingerprintKey)
            ?: request.headers[RELAY_CERTIFICATE_FINGERPRINT_HEADER]
        request.headers.remove(RELAY_SECURITY_MODE_HEADER)
        request.headers.remove(RELAY_CERTIFICATE_FINGERPRINT_HEADER)
        val physicalUrl = request.url.build()
        val logicalUrl = request.attributes.getOrNull(logicalUrlKey) ?: physicalUrl
        requireAllowedURL(logicalUrl, mode)
        if (mode == RelayConnectionSecurityMode.TofuHttps) {
            val pinned = request.attributes.getOrNull(pinnedAddressesKey)
                ?: throw IllegalArgumentException("tofu_dns_pin_missing")
            require(resolveAndClassify(logicalUrl, mode) == pinned) { "tofu_dns_rebinding_blocked" }
            verifyTlsPin(logicalUrl, requireNotNull(certificateFingerprint))
        } else if (mode != RelayConnectionSecurityMode.RemoteHttps) {
            requireNoSensitiveMaterial(request.headers.entries().map { it.key }, logicalUrl.parameters.names())
            val pinned = request.attributes.getOrNull(pinnedAddressesKey)
                ?: throw IllegalArgumentException("local_dns_pin_missing")
            require(resolveAndClassify(logicalUrl, mode) == pinned) { "local_dns_rebinding_blocked" }
            require(physicalUrl.host.substringBefore('%') in pinned) { "local_dns_pin_changed" }
        }
    }
}

private fun modeFrom(raw: String?): RelayConnectionSecurityMode =
    RelayConnectionSecurityMode.entries.firstOrNull { it.value == raw }
        ?: RelayConnectionSecurityMode.RemoteHttps

private fun requireAllowedURL(url: Url, mode: RelayConnectionSecurityMode) {
    if (mode == RelayConnectionSecurityMode.RemoteHttps) {
        val parsed = URI(url.toString())
        val transportLocation = URI(
            parsed.scheme,
            parsed.rawUserInfo,
            parsed.host,
            parsed.port,
            parsed.rawPath,
            null,
            null,
        ).toASCIIString()
        require(RelayEndpointPolicy.classify(transportLocation, mode).allowed) { "cleartext_not_allowed" }
    }
}

private fun requireNoSensitiveMaterial(headers: Iterable<String>, queryNames: Iterable<String>) {
    require(
        headers.none(RelayEndpointPolicy::isSensitiveName) &&
            queryNames.none(RelayEndpointPolicy::isSensitiveName),
    ) {
        "local_http_sensitive_credential_blocked"
    }
}

private fun validFingerprint(raw: String?): Boolean {
    val value = normalizeFingerprint(raw ?: return false)
    return value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
}

private fun normalizeFingerprint(raw: String): String = raw.lowercase()
    .removePrefix("sha256:")
    .replace(":", "")
    .filterNot(Char::isWhitespace)

private suspend fun verifyTlsPin(url: Url, expected: String) = withContext(Dispatchers.IO) {
    val connection = URL(url.toString()).openConnection() as HttpsURLConnection
    connection.instanceFollowRedirects = false
    connection.requestMethod = "HEAD"
    connection.connectTimeout = 12_000
    connection.readTimeout = 12_000
    try {
        connection.connect()
        val leaf = connection.serverCertificates.first().encoded
        val actual = MessageDigest.getInstance("SHA-256").digest(leaf).joinToString("") { "%02x".format(it) }
        require(actual == normalizeFingerprint(expected)) { "tofu_fingerprint_mismatch" }
    } finally {
        connection.disconnect()
    }
}

private suspend fun resolveAndClassify(url: Url, mode: RelayConnectionSecurityMode): Set<String> =
    withContext(Dispatchers.IO) {
        val addresses = InetAddress.getAllByName(url.host).mapTo(linkedSetOf()) {
            requireNotNull(it.hostAddress) { "local_dns_non_numeric" }.substringBefore('%')
        }
        require(addresses.isNotEmpty()) { "local_dns_empty" }
        val result = RelayEndpointPolicy.classify(
            raw = url.toString(),
            securityMode = mode,
            resolvedIPs = addresses.toList(),
        )
        require(result.allowed) { result.reason }
        addresses
    }
