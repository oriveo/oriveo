package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig

internal fun buildRelayQueryPairs(
    protocolQuery: List<Pair<String, String>>,
    requested: RelayRequestedConfig?,
    authMode: RelayAuthMode?,
    apiKey: String?,
    includeCustomQuery: Boolean,
): List<Pair<String, String>> = buildList {
    addAll(protocolQuery)
    if (authMode == RelayAuthMode.None) return@buildList
    if (authMode == RelayAuthMode.QueryKey && apiKey != null) add("key" to apiKey)
    if (includeCustomQuery) {
        requested?.queryParams.orEmpty().forEach { add(it.key to it.value) }
    }
}
