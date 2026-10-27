package ai.oriveo.community.feature.settings.websearch

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.search.SavedSearchService
import ai.oriveo.community.core.search.SearchCatalogRepository
import ai.oriveo.community.core.search.SearchConnectionRef
import ai.oriveo.community.core.search.SearchJson
import ai.oriveo.community.core.search.SearchRowServiceInput
import ai.oriveo.community.core.search.SearchServiceStore
import ai.oriveo.community.core.search.SearchSettings
import kotlinx.serialization.json.JsonObject

/** Saved services with their row states, plus the active catalog entries (catalog order). */
internal data class WebSearchServiceItems(
    val catalogAvailable: Boolean,
    val entries: Map<String, JsonObject>,
    val items: List<WebSearchServiceItem>,
)

/**
 * Model connections a search service can reuse: official BYOK connections (ProviderForm.Official) authenticated with an
 * API key that has a key on this device. Shared by Settings › Web search and the chat web search card.
 */
internal fun webSearchConnections(list: List<Provider>): List<SearchConnectionRef> = list
    .filter {
        // Reusable connection = an official BYOK connection (decided by ProviderForm, not by comparing kind): an API key connection with a key on this device
        ai.oriveo.community.core.capability.truth.ProviderForm.of(it) == ai.oriveo.community.core.capability.truth.ProviderForm.Official &&
            it.authMode == ProviderAuthMode.ApiKey &&
            ProviderCredentialResolver.apiKey(it, null).isNotEmpty()
    }
    .map { p ->
        // Same single entry the request path uses (official site selection included; empty falls back to the default).
        val base = runCatching { EndpointResolver.resolveBaseUrl(p) }.getOrNull()?.takeIf { it.isNotBlank() } ?: p.kind.defaultBaseUrl
        SearchConnectionRef(p.id, p.displayName, webSearchProviderKindId(p), base)
    }

/** Same id the catalog `reuse.providerKind` uses (ProviderKind @SerialName). */
internal fun webSearchProviderKindId(p: Provider): String =
    runCatching { kotlinx.serialization.json.Json.encodeToString(ProviderKind.serializer(), p.kind) }
        .getOrNull()?.trim('"') ?: p.kind.name.lowercase()

/** Store + catalog + connections → list rows. Reads the encrypted store: call off the main thread. */
internal fun webSearchServiceItems(
    store: SearchServiceStore,
    catalog: SearchCatalogRepository,
    accountId: String,
    connections: List<SearchConnectionRef>,
): WebSearchServiceItems {
    val adopted = catalog.current()
    val catalogAvailable = adopted != null && !catalog.presetsWithdrawn()
    val entries = linkedMapOf<String, JsonObject>()
    if (catalogAvailable) {
        for (s in adopted!!.snapshot.services) {
            if (s.status != "active") continue
            catalog.entry(s.id)?.let { entries[s.id] = it }
        }
    }
    val defaultId = store.defaultServiceId(accountId)
    val items = store.services(accountId).map { s ->
        val key = if (s.keySource == SavedSearchService.KEY_SOURCE_OWN) store.key(accountId, s.id) else null
        val entry = s.serviceId?.let { entries[it] }
        val withdrawn = s.serviceId?.let { catalog.serviceState(it)?.status == "withdrawn" } == true
        val row = SearchSettings.searchServiceRowState(
            service = SearchRowServiceInput(
                kind = s.kind,
                serviceId = s.serviceId,
                regionId = s.regionId,
                boundHost = s.boundHost,
                keySource = s.keySource,
                connectionRef = s.connectionRef,
                hasKey = key != null,
            ),
            catalogAvailable = catalogAvailable,
            entry = entry,
            withdrawn = withdrawn,
            connections = connections,
        )
        WebSearchServiceItem(
            saved = s,
            displayName = SearchSettings.searchServiceDisplayName(s.kind, s.name, s.serviceId, SearchJson.string(entry?.get("displayName"))),
            rowState = row,
            isDefault = s.id == defaultId,
            hasKey = key != null,
            keyTail = key?.takeLast(4),
            entry = entry,
        )
    }
    return WebSearchServiceItems(catalogAvailable, entries, items)
}
