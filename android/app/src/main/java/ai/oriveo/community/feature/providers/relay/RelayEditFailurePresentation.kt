package ai.oriveo.community.feature.providers.relay

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import java.net.URI

data class RelayEditFailurePresentation(
    val endpoint: String,
    val statusCode: Int?,
    val upstreamJson: String?,
    val automaticRetryCount: Int,
    /** Raw text of the local exception (`<class name>: <message>`, redacted); present only when persistence itself failed, always null for a verification failure. */
    val localErrorDetail: String? = null,
)

object RelayEditFailurePresenter {
    /**
     * Persistence itself failed (a local exception, not an upstream rejection): the raw exception text is carried alongside [present], using the same redaction list;
     * the raw text, like the upstream body, is technical original text and is not translated.
     */
    fun presentLocalFailure(candidate: Provider, error: Throwable): RelayEditFailurePresentation {
        val raw = "${error::class.simpleName ?: "Exception"}: ${error.message.orEmpty()}"
        return present(candidate, error).copy(
            localErrorDetail = RelayEndpointPolicy.redactCredentials(raw, credentials(candidate)).trim(),
        )
    }

    fun present(candidate: Provider, error: Throwable): RelayEditFailurePresentation {
        val credentials = credentials(candidate)
        val providerError = error as? ProviderServiceError
        val statusCode = when (providerError) {
            is ProviderServiceError.Upstream -> providerError.statusCode
            is ProviderServiceError.RelayUpstream -> providerError.statusCode
            else -> null
        }
        val rawDetail = when (providerError) {
            is ProviderServiceError.Upstream -> providerError.detail
            is ProviderServiceError.RelayUpstream -> providerError.detail
            else -> null
        }
        val redactedDetail = rawDetail
            ?.let { RelayEndpointPolicy.redactCredentials(it, credentials) }
            ?.trim()
            ?.takeIf { it.startsWith("{") || it.startsWith("[") }
        return RelayEditFailurePresentation(
            endpoint = RelayEndpointPolicy.redactCredentials(
                candidate.baseUrlText.orEmpty(),
                credentials,
            ),
            statusCode = statusCode,
            upstreamJson = redactedDetail,

            automaticRetryCount = 0,
        )
    }

    private fun credentials(candidate: Provider): List<String> = buildList {
        // List assembled from the connection: all keys of the connection (multi-key relay) must be redacted.
        addAll(ProviderCredentialResolver.allApiKeys(candidate))
        val requested = candidate.relayRequested
        addAll(
            RelayEndpointPolicy.credentialMaterial(
                requested?.headers.orEmpty().map { it.key to it.value } +
                    requested?.queryParams.orEmpty().map { it.key to it.value },
            ),
        )
        // A custom User-Agent often carries account / channel identifiers; when upstream echoes it back it likewise must not reach the failure card.
        requested?.customUserAgent?.trim()?.let(::add)
        addAll(endpointCredentialValues(candidate.baseUrlText.orEmpty()))
    }.filter(String::isNotBlank).distinct()

    private fun endpointCredentialValues(raw: String): List<String> = runCatching {
        val uri = URI(if (raw.contains("://")) raw else "https://$raw")
        buildList {
            uri.userInfo?.substringAfter(':', "")?.takeIf(String::isNotBlank)?.let(::add)
            uri.rawQuery.orEmpty().split('&').forEach { item ->
                val name = item.substringBefore('=')
                val value = item.substringAfter('=', "")
                if (RelayEndpointPolicy.isSensitiveName(name) && value.isNotBlank()) add(value)
            }
        }
    }.getOrDefault(emptyList())
}
