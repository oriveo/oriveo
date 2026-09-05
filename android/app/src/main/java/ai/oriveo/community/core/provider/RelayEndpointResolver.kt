package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import java.net.URI

data class RelayEndpointDescriptor(
    val normalizedInput: String,
    val origin: String,
    val pathPrefix: String,
    val explicitVersion: String?,
    val explicitTransport: RelayTransport?,
    val containsEmbeddedQuery: Boolean,
    val containsFragment: Boolean,
) {
    val hasExplicitTerminalRoute: Boolean get() = explicitTransport != null
}

enum class RelayEndpointCandidateEvidence {
    ExplicitRoute,
    ExplicitVersion,
    DefaultVersion,
    AlternateVersion,
    VersionlessFallback,
}

data class RelayEndpointCandidate(
    val apiBaseUrl: String,
    val transport: RelayTransport,
    val evidence: RelayEndpointCandidateEvidence,
)

/** Structured Relay URL parsing shared by discovery and runtime routing. */
object RelayEndpointResolver {
    private val knownVersions = setOf("v1", "v1beta")

    fun describe(
        raw: String,
        securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
    ): RelayEndpointDescriptor {
        val trimmed = raw.trim()
        val candidate = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        val inputUri = runCatching { URI(candidate) }.getOrElse {
            throw ProviderServiceError.InvalidConfiguration("Invalid Relay request URL.")
        }
        val host = inputUri.host?.takeIf { it.isNotBlank() }
            ?: throw ProviderServiceError.InvalidConfiguration("Invalid Relay request URL.")
        val containsEmbeddedQuery = !inputUri.rawQuery.isNullOrEmpty()
        if (!containsEmbeddedQuery && !inputUri.rawUserInfo.isNullOrEmpty()) {
            throw ProviderServiceError.InvalidConfiguration("Invalid Relay request URL.")
        }
        val requestSafeInput = URI(
            inputUri.scheme,
            null,
            host,
            inputUri.port,
            inputUri.rawPath,
            null,
            null,
        ).toASCIIString()
        val normalized = RelayEndpointPolicy.requireConfigured(requestSafeInput, securityMode)
        val uri = URI(normalized)

        val segments = uri.path.orEmpty()
            .split('/')
            .filter { it.isNotBlank() }
            .toMutableList()
        val explicitTransport = terminalTransportAndTrim(segments)
        val explicitVersion = segments.lastOrNull()?.lowercase()?.takeIf(knownVersions::contains)
        if (explicitVersion != null) segments.removeAt(segments.lastIndex)

        val origin = URI(
            uri.scheme.lowercase(),
            null,
            host,
            uri.port,
            null,
            null,
            null,
        ).toASCIIString().trimEnd('/')

        return RelayEndpointDescriptor(
            normalizedInput = normalized,
            origin = origin,
            pathPrefix = segments.joinToString(separator = "/", prefix = if (segments.isEmpty()) "" else "/"),
            explicitVersion = explicitVersion,
            explicitTransport = explicitTransport,
            containsEmbeddedQuery = containsEmbeddedQuery,
            containsFragment = !inputUri.rawFragment.isNullOrEmpty(),
        )
    }

    fun candidates(
        descriptor: RelayEndpointDescriptor,
        transport: RelayTransport,
    ): List<RelayEndpointCandidate> {
        val result = mutableListOf<RelayEndpointCandidate>()
        fun append(version: String?, evidence: RelayEndpointCandidateEvidence) {
            val parts = listOf(
                descriptor.pathPrefix.trim('/'),
                version.orEmpty(),
            ).filter(String::isNotEmpty)
            val base = if (parts.isEmpty()) descriptor.origin else descriptor.origin + "/" + parts.joinToString("/")
            if (result.none { it.apiBaseUrl == base && it.transport == transport }) {
                result += RelayEndpointCandidate(base, transport, evidence)
            }
        }

        if (descriptor.hasExplicitTerminalRoute && descriptor.explicitVersion == null) {
            append(null, RelayEndpointCandidateEvidence.ExplicitRoute)
        }
        descriptor.explicitVersion?.let {
            append(
                it,
                if (descriptor.hasExplicitTerminalRoute) {
                    RelayEndpointCandidateEvidence.ExplicitRoute
                } else {
                    RelayEndpointCandidateEvidence.ExplicitVersion
                },
            )
        }
        preferredVersions(transport).forEach { version ->
            append(
                version,
                if (descriptor.explicitVersion == null) {
                    RelayEndpointCandidateEvidence.DefaultVersion
                } else {
                    RelayEndpointCandidateEvidence.AlternateVersion
                },
            )
        }
        append(null, RelayEndpointCandidateEvidence.VersionlessFallback)
        return result
    }

    fun endpointUrl(
        apiBaseUrl: String,
        endpointPath: String,
        securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
    ): String {
        val base = RelayEndpointPolicy.requireConfigured(apiBaseUrl, securityMode)
        val uri = URI(base)
        val path = listOf(uri.path.orEmpty().trim('/'), endpointPath.trim('/'))
            .filter(String::isNotEmpty)
            .joinToString(separator = "/", prefix = "/")
        return URI(uri.scheme, null, uri.host, uri.port, path, null, null).toASCIIString()
    }

    fun runtimeApiBaseUrl(
        rawBaseUrl: String,
        relayRequested: RelayRequestedConfig?,
        defaultVersion: String,
        acceptedVersions: Set<String>,
    ): String {
        relayRequested?.resolvedAPIBaseURL?.trim()?.takeIf { it.isNotEmpty() }?.let {
            return RelayEndpointPolicy.requireSecure(it)
        }
        val secureBase = RelayEndpointPolicy.requireSecure(rawBaseUrl)
        val uri = URI(secureBase)
        val segments = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
        if (segments.any(acceptedVersions::contains)) return secureBase
        val path = (segments + defaultVersion).joinToString(separator = "/", prefix = "/")
        return URI(uri.scheme, null, uri.host, uri.port, path, null, null).toASCIIString().trimEnd('/')
    }

    private fun preferredVersions(transport: RelayTransport): List<String> = when (transport) {
        RelayTransport.GeminiGenerateContent -> listOf("v1beta", "v1")
        else -> listOf("v1")
    }

    private fun terminalTransportAndTrim(segments: MutableList<String>): RelayTransport? {
        val lower = segments.map(String::lowercase)
        if (lower.size >= 2 && lower[lower.lastIndex - 1] == "chat" && lower.last() == "completions") {
            repeat(2) { segments.removeAt(segments.lastIndex) }
            return RelayTransport.OpenAIChatCompletions
        }
        if (lower.lastOrNull() == "responses") {
            segments.removeAt(segments.lastIndex)
            return RelayTransport.OpenAIResponses
        }
        if (lower.lastOrNull() == "messages") {
            segments.removeAt(segments.lastIndex)
            return RelayTransport.AnthropicMessages
        }
        if (
            lower.size >= 2 && lower[lower.lastIndex - 1] == "models" &&
            (lower.last().contains(":generatecontent") || lower.last().contains(":streamgeneratecontent"))
        ) {
            repeat(2) { segments.removeAt(segments.lastIndex) }
            return RelayTransport.GeminiGenerateContent
        }
        if (lower.lastOrNull() == "models") segments.removeAt(segments.lastIndex)
        return null
    }
}
