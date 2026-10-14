package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.RelayModelFamilyLookup
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyAccessOutcome
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.RelayFamilyHeuristics
import ai.oriveo.community.core.security.SecureKeyStore

/**
 * Pure functions for relay multi-key support: key list, model binding, key operations and read model. No I/O.
 * The rules are sourced from `shared/test-fixtures/relay/key-binding.v1.json` (bindCases / opsCases / readCases).
 *
 * Zero migration: a connection without [Provider.relayKeys] is treated as one implicit key [IMPLICIT_KEY_ID];
 * with only one key none of the functions here writes a new field (the list is generated only by user key operations such as [add]).
 */
object RelayKeyBinding {
    const val IMPLICIT_KEY_ID = "initial"

    /** Ordered key list; defaults to one implicit key. The value of the primary key (the first) is read via [ProviderCredentialResolver.keySecret]. */
    fun keys(provider: Provider): List<RelayKey> =
        provider.relayKeys?.takeIf { it.isNotEmpty() } ?: listOf(RelayKey(id = IMPLICIT_KEY_ID))

    fun keyIDs(provider: Provider): List<String> = keys(provider).map { it.id }

    /** Effective key of an enabled model: use `relayKeyID` if it is in the list, otherwise (missing / dangling / model not among the enabled) the primary key. */
    fun effectiveKeyID(provider: Provider, modelID: String?): String =
        effectiveKeyID(keyIDs(provider), provider.models.firstOrNull { it.id == modelID })

    private fun effectiveKeyID(keyIDs: List<String>, model: AIModel?): String =
        model?.relayKeyID?.takeIf { it in keyIDs } ?: keyIDs.first()

    /** Which keys list a catalog entry (in key order); when `relayListedByKeyIDs` is missing the primary key lists it. */
    private fun listingKeyIDs(keyIDs: List<String>, entry: AIModel?): List<String> {
        entry ?: return emptyList()
        val listed = entry.relayListedByKeyIDs ?: listOf(keyIDs.first())
        return keyIDs.filter { it in listed }
    }

    /** Public entry: which keys list the entry [modelID] in the catalog (not in the catalog = no one lists it); the model-library key filter and the key catalog count share this predicate. */
    fun listingKeyIDs(provider: Provider, modelID: String): List<String> =
        listingKeyIDs(keyIDs(provider), provider.catalogModels.firstOrNull { it.id == modelID })

    // ── Binding (bindCases) ──

    /**
     * Picks a key when enabling a catalog model / adding manually; null = write nothing (only one key).
     * Rules: listed by only one key -> that key; listed by several -> the key that is the effective key of the first enabled model of the same family (in enable order) among the listers,
     * otherwise the first lister in key order; listed by none (hand-typed id) -> the effective key of an enabled model of the same family, otherwise the primary key. A null family never matches.
     */
    fun bind(
        keyIDs: List<String>,
        catalog: List<AIModel>,
        enabled: List<AIModel>,
        targetModelID: String,
        family: (String) -> String?,
    ): String? {
        if (keyIDs.size < 2) return null
        val listing = listingKeyIDs(keyIDs, catalog.firstOrNull { it.id == targetModelID })
        if (listing.size == 1) return listing.single()
        val targetFamily = family(targetModelID)
        val sameFamily = if (targetFamily == null) {
            emptyList()
        } else {
            enabled.filter { family(it.id) == targetFamily }.map { effectiveKeyID(keyIDs, it) }
        }
        if (listing.isNotEmpty()) return sameFamily.firstOrNull { it in listing } ?: listing.first()
        return sameFamily.firstOrNull() ?: keyIDs.first()
    }

    /** Production wiring for enabling / manual add: when the connection has 2+ keys, writes the binding onto [model], otherwise returns it unchanged. */
    fun withBinding(provider: Provider, model: AIModel, family: (String) -> String? = ::cachedFamily): AIModel {
        if (provider.kind != ProviderKind.Relay) return model
        val keyID = bind(keyIDs(provider), provider.catalogModels, provider.models, model.id, family) ?: return model
        return model.copy(relayKeyID = keyID)
    }

    /**
     * Enabling several models at once (the two-step add save): [bind] one by one in [orderedModelIDs] order; already-bound ones count as "enabled of the same family" for the later ones.
     * The key chip in step 2 and persistence use the same function, so the two sides cannot diverge. With only one key everything is null.
     */
    fun bindInOrder(
        keyIDs: List<String>,
        catalog: List<AIModel>,
        orderedModelIDs: List<String>,
        family: (String) -> String?,
    ): Map<String, String?> {
        val enabled = mutableListOf<AIModel>()
        return orderedModelIDs.associateWith { id ->
            bind(keyIDs, catalog, enabled, id, family).also { keyID ->
                enabled += AIModel(id = id, name = id, relayKeyID = keyID)
            }
        }
    }

    /** Family = the cached Server by-model vendor family -> the existing [RelayFamilyHeuristics]; fetched synchronously, sends no request. */
    fun cachedFamily(modelID: String): String? =
        RelayModelFamilyLookup.shared.cachedFamily(modelID)
            ?: RelayFamilyHeuristics.infer(modelID)?.name?.lowercase()

    // ── Key operations (opsCases) ──

    /**
     * Adds a key: generates the list, pins all enabled models, and fills in the listers of catalog entries (so later ordering never silently swaps a model's key).
     * Empty or existing id -> rejected (null).
     */
    fun add(provider: Provider, id: String, name: String?, apiKey: String): Provider? {
        val current = keys(provider)
        if (id.isBlank() || current.any { it.id == id }) return null
        return pinned(provider.copy(relayKeys = materialized(current) + RelayKey(id = id, name = name, apiKey = apiKey)), current)
    }

    /** Rename; no key list (implicit single key) or id does not exist -> rejected (null), no field is written. */
    fun rename(provider: Provider, id: String, name: String?): Provider? {
        val list = provider.relayKeys ?: return null
        if (list.none { it.id == id }) return null
        return provider.copy(relayKeys = list.map { if (it.id == id) it.copy(name = name) else it })
    }

    /** Change value: clears that key's state and the no-access marks on models for it; the catalog is untouched (re-fetch belongs to the refresh path). The primary key's value is written to [Provider.apiKey]; id does not exist -> rejected (null). */
    fun replaceSecret(provider: Provider, id: String, apiKey: String): Provider? {
        val list = keys(provider)
        val index = list.indexOfFirst { it.id == id }
        if (index < 0) return null
        val nextKeys = provider.relayKeys?.mapIndexed { i, key ->
            if (i != index) key else key.copy(apiKey = if (i == 0) "" else apiKey, status = null)
        }
        return provider.copy(
            apiKey = if (index == 0) apiKey else provider.apiKey, // key-choke: stored-field
            relayKeys = nextKeys,
            models = provider.models.map { if (it.relayDeniedKeyID == id) it.copy(relayDeniedKeyID = null) else it },
        )
    }

    /** Reorder; when the primary key changes, the values of the two keys are swapped between [Provider.apiKey] and the entries. No key list, id does not exist or target position out of range -> rejected (null). */
    fun move(provider: Provider, id: String, toIndex: Int): Provider? {
        val list = provider.relayKeys ?: return null
        val from = list.indexOfFirst { it.id == id }
        if (from < 0 || toIndex !in list.indices) return null
        val reordered = list.toMutableList().apply { add(toIndex, removeAt(from)) }
        return withPrimary(provider, list, reordered)
    }

    /**
     * Deletes a key; the last key or an id that does not exist -> rejected (null). Models bound to it are rebound to the primary key, and catalog entries listed only by it leave;
     * it is also pruned from the listers of enabled models.
     */
    fun delete(provider: Provider, id: String): Provider? {
        val list = keys(provider)
        if (list.size < 2) return null
        if (list.none { it.id == id }) return null
        val remaining = list.filter { it.id != id }
        val updated = withPrimary(provider, list, remaining)
        val primary = remaining.first().id
        val oldIDs = list.map { it.id }
        return updated.copy(
            models = updated.models.map { model ->
                val rebound = if (effectiveKeyID(oldIDs, model) == id) model.copy(relayKeyID = primary) else model
                val undenied = if (rebound.relayDeniedKeyID == id) rebound.copy(relayDeniedKeyID = null) else rebound
                val listed = undenied.relayListedByKeyIDs
                if (listed == null || id !in listed) undenied else undenied.copy(relayListedByKeyIDs = (listed - id).ifEmpty { null })
            },
            catalogModels = updated.catalogModels.mapNotNull { entry ->
                val listed = listingKeyIDs(oldIDs, entry) - id
                if (listed.isEmpty()) null else entry.copy(relayListedByKeyIDs = listed)
            },
        )
    }

    /**
     * Rebind: clears the model's no-access marks and the `reachable` transport, keeps `user` / `observed`.
     * No key list (implicit single key), or key id or enabled model does not exist -> rejected (null), no field is written.
     */
    fun rebind(provider: Provider, modelID: String, keyID: String): Provider? {
        val list = provider.relayKeys ?: return null
        if (list.none { it.id == keyID } || provider.models.none { it.id == modelID }) return null
        return provider.copy(
            models = provider.models.map { model ->
                if (model.id != modelID) return@map model
                val dropTransport = model.relayTransportSource == RelayTransportSource.Reachable
                model.copy(
                    relayKeyID = keyID,
                    relayDeniedKeyID = null,
                    relayTransport = if (dropTransport) null else model.relayTransport,
                    relayTransportSource = if (dropTransport) null else model.relayTransportSource,
                )
            },
        )
    }

    /** Implicit list becomes explicit: the primary key entry's value is stored empty. */
    private fun materialized(keys: List<RelayKey>): List<RelayKey> =
        keys.mapIndexed { index, key -> if (index == 0) key.copy(apiKey = "") else key }

    private fun pinned(provider: Provider, before: List<RelayKey>): Provider {
        val ids = before.map { it.id }
        return provider.copy(
            models = provider.models.map { it.copy(relayKeyID = effectiveKeyID(ids, it)) },
            catalogModels = provider.catalogModels.map { entry ->
                if (entry.relayListedByKeyIDs != null) entry else entry.copy(relayListedByKeyIDs = listOf(ids.first()))
            },
        )
    }

    /** The list changes from [before] to [after]: when the primary key changes, the value moves to [Provider.apiKey] and the old primary key's value falls back into its entry. */
    private fun withPrimary(provider: Provider, before: List<RelayKey>, after: List<RelayKey>): Provider {
        val oldPrimary = before.first().id
        val newPrimary = after.first().id
        if (oldPrimary == newPrimary) return provider.copy(relayKeys = after)
        val secrets = before.associate { it.id to ProviderCredentialResolver.keySecret(provider, it.id) }
        return provider.copy(
            apiKey = secrets.getValue(newPrimary), // key-choke: stored-field
            relayKeys = after.mapIndexed { index, key ->
                key.copy(apiKey = if (index == 0) "" else secrets.getValue(key.id))
            },
        )
    }

    // ── Per-key catalog fetch (catalogCases) ──

    /** Result of one key's catalog fetch this time. */
    sealed interface CatalogFetch {
        /** Upstream 2xx: the models in upstream order. */
        data class Ok(val models: List<AIModel>) : CatalogFetch
        /** Non-2xx ([status] null = network / decode failure); [outcome] is the result of [RelayKeyAccess.classify]. */
        data class Failed(val status: Int?, val outcome: RelayKeyAccessOutcome) : CatalogFetch
        /** Not fetched this time (for example only the other key's value was changed), or the connection / this key's value changed while in flight. */
        data object Skipped : CatalogFetch
    }

    /** [statuses] contains only keys that have a result this time (skipped ones are absent); checkedAt is set by the writer. */
    data class CatalogMerge(val catalog: List<AIModel>, val statuses: Map<String, RelayKeyStatus>)

    /**
     * Catalog merge with two or more keys (a single key takes the original path and does not come here): in key order, a successful key contributes its entries from this time (upstream order),
     * a failed or skipped key contributes the entries it listed last time (last order); for the same id first come first served. Listers = successful keys that listed it this time +
     * failed / skipped keys that listed it last time (in key order); entries listed by no one leave the catalog (enabled and manual models are covered by the existing retention logic).
     * A failure never clears the entries that key listed last time.
     */
    fun mergeCatalog(keyIDs: List<String>, previous: List<AIModel>, results: Map<String, CatalogFetch>): CatalogMerge {
        val fetched = keyIDs.associateWith { (results[it] as? CatalogFetch.Ok)?.models }
        val previousListing = previous.associate { it.id to listingKeyIDs(keyIDs, it) }
        val ordered = LinkedHashMap<String, AIModel>()
        for (keyID in keyIDs) {
            val contributed = fetched[keyID] ?: previous.filter { keyID in previousListing.getValue(it.id) }
            contributed.forEach { ordered.putIfAbsent(it.id, it) }
        }
        val catalog = ordered.values.mapNotNull { model ->
            val listed = keyIDs.filter { keyID ->
                val ok = fetched[keyID]
                if (ok != null) ok.any { it.id == model.id } else keyID in previousListing[model.id].orEmpty()
            }
            if (listed.isEmpty()) null else model.copy(relayListedByKeyIDs = listed)
        }
        val statuses = keyIDs.mapNotNull { keyID -> results[keyID]?.let(::statusOf)?.let { keyID to it } }.toMap()
        return CatalogMerge(catalog, statuses)
    }

    /** One catalog fetch writes back that key's state; skipped -> null (nothing written). A single-key refresh and a multi-key merge use the same rule. */
    fun statusOf(result: CatalogFetch): RelayKeyStatus? = when (result) {
        is CatalogFetch.Ok -> RelayKeyStatus("ok")
        is CatalogFetch.Failed -> RelayKeyStatus(failedState(result), result.status)
        CatalogFetch.Skipped -> null
    }

    private fun failedState(result: CatalogFetch.Failed): String = when {
        result.outcome == RelayKeyAccessOutcome.KeyInvalid -> "invalid"
        result.outcome == RelayKeyAccessOutcome.KeyLimited -> "limited"
        result.status == 403 -> "denied"
        else -> "failed"
    }

    // ── Read model (readCases, used by the detail board; no UI) ──

    data class KeyRow(
        val id: String,
        val name: String?,
        val isPrimary: Boolean,
        /** Status word (`ok` / `invalid` / ...); null = not checked. */
        val status: String?,
        val catalogCount: Int,
        val enabledCount: Int,
        val maskedSecret: String,
    )

    data class ModelKeyState(
        val boundKeyID: String,
        val alternateKeyIDs: List<String>,
        val deniedOnCurrentKey: Boolean,
    )

    fun showsKeyUI(provider: Provider): Boolean = keys(provider).size >= 2

    fun rows(provider: Provider): List<KeyRow> {
        val list = keys(provider)
        val ids = list.map { it.id }
        return list.mapIndexed { index, key ->
            KeyRow(
                id = key.id,
                name = key.name,
                isPrimary = index == 0,
                status = key.status?.state,
                catalogCount = provider.catalogModels.count { key.id in listingKeyIDs(ids, it) },
                enabledCount = provider.models.count { effectiveKeyID(ids, it) == key.id },
                maskedSecret = SecureKeyStore.maskApiKey(ProviderCredentialResolver.keySecret(provider, key.id)),
            )
        }
    }

    fun modelState(provider: Provider, modelID: String): ModelKeyState {
        val ids = keyIDs(provider)
        val model = provider.models.firstOrNull { it.id == modelID }
        val bound = effectiveKeyID(ids, model)
        return ModelKeyState(
            boundKeyID = bound,
            alternateKeyIDs = listingKeyIDs(ids, provider.catalogModels.firstOrNull { it.id == modelID }) - bound,
            deniedOnCurrentKey = model?.relayDeniedKeyID != null && model.relayDeniedKeyID == bound,
        )
    }
}
