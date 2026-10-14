package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
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
    private val versionSegment = Regex("v\\d+(?:alpha|beta)?\\d*")

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

    /**
     * The protocol this request actually uses: the model-level protocol takes priority, otherwise the connection default is followed; `Auto` and unconfigured fall back to Chat Completions.
     *
     * Pure function with no I/O and no write-back. The protocol for all outbound / attachment / tool / evidence paths is obtained through it (the single choke point).
     */
    fun effectiveTransport(provider: Provider, model: AIModel?): RelayTransport =
        effectiveTransport(provider.relayRequested, model)

    /** Same as [effectiveTransport], for outbound layers that only have a copy of the connection config (the relayRequested carried in request options). */
    fun effectiveTransport(requested: RelayRequestedConfig?, model: AIModel?): RelayTransport =
        declaredTransport(requested, model) ?: RelayTransport.OpenAIChatCompletions

    /**
     * The protocol explicitly chosen by the model or the connection; null when neither layer chose one (missing or `Auto`).
     *
     * For display / identity decisions that need to distinguish "explicitly chosen" from "following auto"; outbound dispatch always uses [effectiveTransport].
     */
    fun declaredTransport(provider: Provider, model: AIModel?): RelayTransport? =
        declaredTransport(provider.relayRequested, model)

    fun declaredTransport(requested: RelayRequestedConfig?, model: AIModel?): RelayTransport? =
        model?.relayTransport?.takeIf { it != RelayTransport.Auto }
            ?: requested?.transport?.takeIf { it != RelayTransport.Auto }

    /**
     * API root for this request: the root registered per protocol (blank counts as absent) -> the legacy single-value root (which was probed for the connection default protocol
     * and is usable only when the actual protocol equals the connection default) -> the connection address completed with that protocol's standard version segment.
     * Returns null when the connection address is empty or cannot be parsed.
     *
     * Pure function with no I/O and no write-back, and it does no security policy validation (that is the outbound caller's job).
     */
    fun effectiveAPIRoot(provider: Provider, model: AIModel?): String? =
        effectiveAPIRoot(provider.relayRequested, provider.baseUrlText, model)

    /** Same as [effectiveAPIRoot], with the connection address supplied by the caller (the outbound layer gets a baseUrl that already passed security validation). */
    fun effectiveAPIRoot(requested: RelayRequestedConfig?, baseUrlText: String?, model: AIModel?): String? {
        val transport = effectiveTransport(requested, model)
        requested?.resolvedAPIBaseURLs?.get(transport.value)?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
        if (transport == effectiveTransport(requested, null)) {
            requested?.resolvedAPIBaseURL?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
        }
        return completedApiRoot(baseUrlText, transport)
    }

    /**
     * The address shown as "Will request ..." on the add page: describe(input) strips the terminal route and then completes the version like [effectiveAPIRoot],
     * taking the protocol from the explicit terminal route, otherwise Chat Completions. Returns null when it cannot become a request-safe address (empty, with credentials, with a query, remote plaintext http).
     */
    fun previewAPIRoot(
        input: String,
        securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
    ): String? {
        if (input.isBlank()) return null
        val descriptor = runCatching { describe(input, securityMode) }.getOrNull() ?: return null
        if (descriptor.containsEmbeddedQuery) return null
        return versionCompletedRoot(descriptor, descriptor.explicitTransport ?: RelayTransport.OpenAIChatCompletions)
    }

    fun catalogAPIRoot(provider: Provider): String? =
        catalogAPIRoot(provider.relayRequested, provider.baseUrlText)

    /**
     * Connection-level root for the catalog GET (shared by refresh, per-key fetches and extra keys at add time): a verified root takes priority
     * (same as [effectiveAPIRoot] without a model), otherwise the connection address is stripped of its terminal route and completed with the version of the connection protocol.
     */
    fun catalogAPIRoot(requested: RelayRequestedConfig?, baseUrlText: String?): String? {
        val transport = effectiveTransport(requested, null)
        requested?.resolvedAPIBaseURLs?.get(transport.value)?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
        requested?.resolvedAPIBaseURL?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
        val raw = baseUrlText?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val descriptor = runCatching {
            describe(raw, requested?.securityMode ?: RelayConnectionSecurityMode.RemoteHttps)
        }.getOrNull() ?: return null
        return versionCompletedRoot(descriptor, transport)
    }

    /** Same version rule as [completedApiRoot]: if any path segment is already a version segment it is kept as is, llama.cpp native gets nothing added, otherwise the protocol's standard version is appended. */
    private fun versionCompletedRoot(descriptor: RelayEndpointDescriptor, transport: RelayTransport): String {
        val segments = descriptor.pathPrefix.split('/').filter(String::isNotEmpty) +
            listOfNotNull(descriptor.explicitVersion)
        val keepAsIs = transport == RelayTransport.LlamaCppNative ||
            segments.any { versionSegment.matches(it.lowercase()) }
        val path = if (keepAsIs) segments else segments + preferredVersions(transport).first()
        return if (path.isEmpty()) descriptor.origin else descriptor.origin + "/" + path.joinToString("/")
    }

    private fun completedApiRoot(rawBaseUrl: String?, transport: RelayTransport): String? {
        val trimmed = rawBaseUrl?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val candidate = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        return runCatching {
            val uri = URI(candidate)
            val host = uri.host?.takeIf(String::isNotBlank) ?: return null
            val segments = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
            // llama.cpp native endpoints hang directly off the root and have no version segment.
            val version = if (transport == RelayTransport.LlamaCppNative) null else preferredVersions(transport).first()
            // Addresses that already carry a version segment (v1 / v1beta / v2 / v4 ...) are used as is.
            val completed = if (version == null || segments.any { versionSegment.matches(it.lowercase()) }) {
                segments
            } else {
                segments + version
            }
            val path = if (completed.isEmpty()) null else completed.joinToString(separator = "/", prefix = "/")
            URI(uri.scheme, null, host, uri.port, path, null, null).toASCIIString().trimEnd('/')
        }.getOrNull()
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
