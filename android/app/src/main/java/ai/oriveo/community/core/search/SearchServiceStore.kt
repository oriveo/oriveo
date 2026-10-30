package ai.oriveo.community.core.search

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * A search service saved on this device. kind=preset: catalog preset, stores the bound host [boundHost] (checked against the catalog before sending a key);
 * kind=custom: custom (searxng / same_as / manual), same_as / manual store the mapping [mapping] from save time.
 * key source keySource=own (the key is stored in this file) or connection (reuses a model connection, stores only the connection reference [connectionRef], never copies the key).
 */
@Serializable
data class SavedSearchService(
    val id: String,
    val kind: String,
    val serviceId: String? = null,
    val regionId: String? = null,
    val boundHost: String? = null,
    val keySource: String = KEY_SOURCE_OWN,
    val connectionRef: String? = null,
    val name: String? = null,
    val address: String? = null,
    val protocol: String? = null,
    val mapping: JsonObject? = null,
    /** Detail page "Advanced › Results per request" (SearchSettings.RESULT_COUNT_CHOICES); null = default 5. */
    val resultCount: Int? = null,
) {
    companion object {
        const val KIND_PRESET = "preset"
        const val KIND_CUSTOM = "custom"
        const val KEY_SOURCE_OWN = "own"
        const val KEY_SOURCE_CONNECTION = "connection"
    }
}

/**
 * Search service list and keys: a separate EncryptedSharedPreferences file, kept on this device only - not synced, not in app backup
 * (the file name is excluded in data_extraction_rules.xml / backup_rules.xml).
 * Partitioned by account (accountId is used like in SecureKeyStore, the single local partition = LOCAL_PARTITION_ID).
 * A custom service's key is bound to [SearchCustomService.keyBindingOrigin]: if the address origin changes the key is cleared immediately, a path change keeps it.
 * The default service id chosen by the user is stored under a separate key in the same file and partition; the effective default is computed by [SearchSettings.resolveDefaultSearchService].
 */
class SearchServiceStore private constructor(
    private val appContext: Context?,
    initialPrefs: SharedPreferences?,
) {
    constructor(context: Context) : this(context.applicationContext, null)

    /** Unit-test seam; production always uses encrypted preferences via the public constructor. */
    internal constructor(prefs: SharedPreferences) : this(null, prefs)

    @Volatile
    private var prefsRef: SharedPreferences? = initialPrefs

    private val json = Json { ignoreUnknownKeys = true }

    private val revisionFlow = kotlinx.coroutines.flow.MutableStateFlow(0L)

    /**
     * Incremented on every real write (service add / remove / edit, default, key, per-conversation source): the web card panel and the input box chip observe it to recompute, no polling.
     */
    val revision: kotlinx.coroutines.flow.StateFlow<Long> = revisionFlow

    private fun bump() {
        revisionFlow.value += 1
    }
    private val listSerializer = ListSerializer(SavedSearchService.serializer())

    private fun prefs(): SharedPreferences = prefsRef ?: synchronized(this) {
        prefsRef ?: createEncryptedPrefs(requireNotNull(appContext)).also { prefsRef = it }
    }

    private fun createEncryptedPrefs(context: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            PREFS_FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun services(accountId: String): List<SavedSearchService> =
        prefs().getString(servicesName(accountId), null)?.let { raw ->
            runCatching { json.decodeFromString(listSerializer, raw) }.getOrNull()
        }.orEmpty()

    /** Whether this partition has any saved service (used at login to decide "guest has data"). */
    fun hasServices(accountId: String): Boolean = services(accountId).isNotEmpty()

    fun service(accountId: String, id: String): SavedSearchService? = services(accountId).firstOrNull { it.id == id }

    /**
     * Add or update a service. When updating a custom service and the address origin changes (scheme / host / port) → clear the key;
     * when a preset switches to connection reuse → clear the key in this file. Unchanged content writes nothing.
     */
    @Synchronized
    fun save(accountId: String, service: SavedSearchService) {
        val list = services(accountId)
        val old = list.firstOrNull { it.id == service.id }
        val next = if (old == null) list + service else list.map { if (it.id == service.id) service else it }
        val edit = prefs().edit()
        var dirty = false
        if (next != list) {
            edit.putString(servicesName(accountId), json.encodeToString(listSerializer, next))
            dirty = true
        }
        if (old != null && keyMustClear(old, service) && prefs().contains(keyName(accountId, service.id))) {
            edit.remove(keyName(accountId, service.id)).remove(originName(accountId, service.id))
            dirty = true
        }
        if (dirty) {
            edit.apply()
            bump()
        }
    }

    private fun keyMustClear(old: SavedSearchService, next: SavedSearchService): Boolean = when {
        next.keySource != SavedSearchService.KEY_SOURCE_OWN -> true
        next.kind == SavedSearchService.KIND_CUSTOM ->
            SearchCustomService.addressChangeClearsKey(old.address, next.address)
        else -> old.serviceId != next.serviceId || old.regionId != next.regionId
    }

    @Synchronized
    fun remove(accountId: String, id: String) {
        val list = services(accountId)
        val next = list.filterNot { it.id == id }
        val clearsDefault = prefs().getString(defaultName(accountId), null) == id
        if (next == list && !prefs().contains(keyName(accountId, id)) && !clearsDefault) return
        val edit = prefs().edit()
            .putString(servicesName(accountId), json.encodeToString(listSerializer, next))
            .remove(keyName(accountId, id))
            .remove(originName(accountId, id))
        // The deleted one was the default: clear the stored id, and the effective default falls back to the earliest-added remaining service
        if (clearsDefault) edit.remove(defaultName(accountId))
        edit.apply()
        bump()
    }

    /** Effective default service id: the stored one if it still exists, otherwise the earliest in storage order; no service = null. */
    fun defaultServiceId(accountId: String): String? =
        SearchSettings.resolveDefaultSearchService(services(accountId).map { it.id }, prefs().getString(defaultName(accountId), null))

    /** User "set as default": only accepts a service that exists in this partition; the same value writes nothing. */
    @Synchronized
    fun setDefaultServiceId(accountId: String, id: String) {
        if (service(accountId, id) == null) return
        if (prefs().getString(defaultName(accountId), null) == id) return
        prefs().edit().putString(defaultName(accountId), id).apply()
        bump()
    }

    /** Search source of this conversation (key [searchSourceStorageKey], same search partition; not synced, not in backup). Not stored = null. */
    fun conversationSource(accountId: String, conversationId: String): SearchSourceStored? =
        prefs().getString(sourceName(accountId, conversationId), null)?.let { raw ->
            runCatching { SearchSourceStored.fromJson(json.parseToJsonElement(raw)) }.getOrNull()
        }

    /** Write this conversation's search source; null = delete the key. Writes nothing when equal to the stored value. */
    @Synchronized
    fun setConversationSource(accountId: String, conversationId: String, value: SearchSourceStored?) {
        if (conversationSource(accountId, conversationId) == value) return
        val edit = prefs().edit()
        if (value == null) edit.remove(sourceName(accountId, conversationId))
        else edit.putString(sourceName(accountId, conversationId), value.toJson().toString())
        edit.apply()
        bump()
    }

    /** Delete a conversation: this conversation's source key in every account partition is deleted as well (conversation ids are globally unique). Writes nothing if none. */
    @Synchronized
    fun removeConversationSource(conversationId: String) {
        val suffix = "/" + searchSourceStorageKey(conversationId)
        val keys = prefs().all.keys.filter { it.endsWith(suffix) }
        if (keys.isEmpty()) return
        val edit = prefs().edit()
        for (k in keys) edit.remove(k)
        edit.apply()
        bump()
    }

    /** The user confirmed the new host of a preset service: only the bound host changes, the key is kept (the confirmation itself is consent to send the key to the new host). */
    fun rebindPresetHost(accountId: String, id: String, host: String) {
        val s = service(accountId, id)?.takeIf { it.kind == SavedSearchService.KIND_PRESET } ?: return
        save(accountId, s.copy(boundHost = host))
    }

    /**
     * Store a key (only for keySource=own): it first goes through [SearchCustomService.normalizeSearchKey]; if not ok it is not stored and the old key is untouched,
     * returns the normalized result (error = key_empty / key_invalid, or service_missing / key_source_not_own).
     * A custom service also records its binding origin at that time.
     */
    @Synchronized
    fun setKey(accountId: String, id: String, raw: String?): SearchKeyNormalization {
        val normalized = SearchCustomService.normalizeSearchKey(raw)
        if (!normalized.ok) return normalized
        val s = service(accountId, id) ?: return SearchKeyNormalization(false, null, "service_missing")
        if (s.keySource != SavedSearchService.KEY_SOURCE_OWN) return SearchKeyNormalization(false, null, "key_source_not_own")
        val key = normalized.key!!
        val origin = if (s.kind == SavedSearchService.KIND_CUSTOM) SearchCustomService.keyBindingOrigin(s.address) else null
        if (prefs().getString(keyName(accountId, id), null) == key && prefs().getString(originName(accountId, id), null) == origin) {
            return normalized
        }
        prefs().edit().putString(keyName(accountId, id), key).putString(originName(accountId, id), origin).apply()
        bump()
        return normalized
    }

    @Synchronized
    fun clearKey(accountId: String, id: String) {
        if (!prefs().contains(keyName(accountId, id))) return
        prefs().edit().remove(keyName(accountId, id)).remove(originName(accountId, id)).apply()
        bump()
    }

    /** Get the key; if a custom service's current origin differs from the one when the key was stored → not returned (and cleared). */
    fun key(accountId: String, id: String): String? {
        val s = service(accountId, id) ?: return null
        if (s.keySource != SavedSearchService.KEY_SOURCE_OWN) return null
        val key = prefs().getString(keyName(accountId, id), null) ?: return null
        if (s.kind == SavedSearchService.KIND_CUSTOM &&
            prefs().getString(originName(accountId, id), null) != SearchCustomService.keyBindingOrigin(s.address)
        ) {
            clearKey(accountId, id)
            return null
        }
        return key
    }

    /**
     * Moves the services of the [from] partition, with keys / binding origins, to [to]:
     * ones whose id already exists in the target are not overwritten; moved rather than copied, the source partition is emptied. Returns the number merged in.
     */
    @Synchronized
    fun migratePartition(from: String, to: String): Int {
        if (from == to) return 0
        migrateConversationSources(from, to)
        val source = services(from)
        if (source.isEmpty()) return 0
        val target = services(to)
        val incoming = source.filter { s -> target.none { it.id == s.id } }
        val edit = prefs().edit()
        if (incoming.isNotEmpty()) edit.putString(servicesName(to), json.encodeToString(listSerializer, target + incoming))
        for (s in incoming) {
            prefs().getString(keyName(from, s.id), null)?.let { edit.putString(keyName(to, s.id), it) }
            prefs().getString(originName(from, s.id), null)?.let { edit.putString(originName(to, s.id), it) }
        }
        // The default id migrates with the services: carried over only when the target had no services before
        val migrated = SearchSettings.migratedDefaultSearchService(
            accountServiceIds = target.map { it.id },
            guestServiceIds = source.map { it.id },
            guestStoredDefault = prefs().getString(defaultName(from), null),
            migratedIds = incoming.map { it.id },
        )
        if (migrated.set) edit.putString(defaultName(to), migrated.id)
        edit.remove(servicesName(from)).remove(defaultName(from))
        for (s in source) edit.remove(keyName(from, s.id)).remove(originName(from, s.id))
        edit.apply()
        bump()
        return incoming.size
    }

    /** Conversations move with their partition: each conversation's source moves too; existing ones in the target are not overwritten, the source is cleared. */
    private fun migrateConversationSources(from: String, to: String) {
        val prefix = "${partition(from)}/"
        val moving = prefs().all.filterKeys { it.startsWith(prefix) && it.removePrefix(prefix).startsWith(searchSourceStorageKey("")) }
        if (moving.isEmpty()) return
        val edit = prefs().edit()
        for ((key, value) in moving) {
            val target = "${partition(to)}/" + key.removePrefix(prefix)
            if (!prefs().contains(target) && value is String) edit.putString(target, value)
            edit.remove(key)
        }
        edit.apply()
        bump()
    }

    companion object {
        const val PREFS_FILE_NAME = "oriveo_search_services"
        // Partitioned by account, key format follows SecureKeyStore (length prefix avoids concatenation ambiguity)
        private fun partition(accountId: String) = "${accountId.length}:$accountId"
        private fun servicesName(accountId: String) = "services.v1:${partition(accountId)}"
        private fun keyName(accountId: String, id: String) = "key:${partition(accountId)}:$id"
        private fun originName(accountId: String, id: String) = "keyOrigin:${partition(accountId)}:$id"
        private fun defaultName(accountId: String) = "defaultService.v1:${partition(accountId)}"
        private fun sourceName(accountId: String, conversationId: String) =
            "${partition(accountId)}/${searchSourceStorageKey(conversationId)}"
    }
}
