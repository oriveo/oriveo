package ai.oriveo.community.feature.providers.relay

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import java.net.URI


data class RelayEditFailurePresentation(
    val endpoint: String,
    val statusCode: Int?,
    val upstreamJson: String?,
    val automaticRetryCount: Int,
)

object RelayEditFailurePresenter {
    fun present(candidate: Provider, error: Throwable): RelayEditFailurePresentation {
        val credentials = buildList {
            add(candidate.apiKey)
            val requested = candidate.relayRequested
            addAll(
                RelayEndpointPolicy.credentialMaterial(
                    requested?.headers.orEmpty().map { it.key to it.value } +
                        requested?.queryParams.orEmpty().map { it.key to it.value },
                ),
            )
            addAll(endpointCredentialValues(candidate.baseUrlText.orEmpty()))
        }.filter(String::isNotBlank).distinct()
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
