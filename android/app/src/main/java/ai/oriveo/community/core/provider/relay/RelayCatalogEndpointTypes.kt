package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.provider.RelayEndpointResolver
import java.util.concurrent.ConcurrentHashMap

/**
 * The `supported_endpoint_types` from the most recent raw `/models` response of each Relay catalog.
 * Kept in memory only, keyed by catalog API root, and invalid once the process ends; both the add-discovery and catalog-refresh parsing paths write here,
 * and lazy verification / re-detection look up by [catalogRoot], using the same key function as the catalog refresh write.
 * If nothing is found, take the family path; do not guess.
 */
object RelayCatalogEndpointTypes {
    private val latest = ConcurrentHashMap<String, Map<String, List<String>>>()

    /** Connection-level catalog root: shared by catalog sync and cache lookup (the only way to obtain it is [RelayEndpointResolver.catalogAPIRoot]). */
    fun catalogRoot(relayRequested: RelayRequestedConfig?, baseUrl: String?): String? =
        RelayEndpointResolver.catalogAPIRoot(relayRequested, baseUrl) ?: baseUrl

    fun key(apiRoot: String): String = apiRoot.trim().trimEnd('/')

    /** Replace this root's record wholesale with the latest catalog (models not in the catalog become invalid). */
    fun record(apiRoot: String, endpointTypes: Map<String, List<String>>) {
        val cacheKey = key(apiRoot)
        if (cacheKey.isEmpty()) return
        latest[cacheKey] = endpointTypes
    }

    fun lookup(apiRoot: String?, modelID: String): List<String>? {
        val cacheKey = apiRoot?.let(::key)?.takeIf(String::isNotEmpty) ?: return null
        return latest[cacheKey]?.get(modelID)
    }
}
