package ai.oriveo.community.core.provider

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.concurrent.ConcurrentHashMap

data class LocatedModelControlRejection(
    val source: String,
    val owner: String,
    val recipeRef: String? = null,
    val locatedPointers: List<String>,
)

/** Exact on-device negative cache of model control settings an upstream has actually rejected. Only a located rejection writes here: no auth, network, timeout or text heuristic may. */
object ModelControlRejectionCache {
    private const val TTL_MILLIS = 24L * 60L * 60L * 1000L
    private const val PREFS = "model_control_rejection_cache"
    private const val KEY = "v1"
    private const val MAX_ENTRIES = 300
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    @Serializable
    private data class Entry(
        val connectionId: String,
        val canonicalModelId: String,
        val finalTransport: String,
        val runtimeRevision: String,
        val owner: String,
        val source: String,
        val recipeRef: String? = null,
        val setting: String,
        val observedAt: Long,
        val expiresAt: Long,
    ) {
        val identity: ModelControlRuntimeIdentity get() = ModelControlRuntimeIdentity(
            connectionId,
            canonicalModelId,
            finalTransport,
            runtimeRevision,
        )
    }

    private val entries = ConcurrentHashMap<String, Entry>()
    @Volatile private var readPayload: (() -> String?)? = null
    @Volatile private var writePayload: ((String?) -> Unit)? = null
    @Volatile private var pendingHydration: (() -> Unit)? = null

    /**
     * Android startup entry. Captures the application context only: opening SharedPreferences and
     * decoding the persisted payload (up to [MAX_ENTRIES] JSON entries plus a sort) costs real
     * milliseconds, and Application.onCreate pays them straight out of the first frame. The work
     * itself runs in [prewarm] on a background dispatcher.
     *
     * Until [prewarm] completes the cache reads empty. Every consumer treats "no entry" as "no
     * known rejection", which is the conservative direction: the setting is still sent and an
     * upstream rejection records it again. Writes landing in that window stay in memory (no
     * persistence handle yet) and survive, because [prewarm] merges the decoded payload on top
     * instead of resetting, then flushes once.
     */
    @Synchronized
    fun configure(context: Context) {
        val appContext = context.applicationContext
        pendingHydration = {
            val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val recordedBeforeHydration = entries.isNotEmpty()
            readPayload = { prefs.getString(KEY, null) }
            writePayload = { payload -> prefs.edit().putString(KEY, payload).apply() }
            hydrate()
            if (recordedBeforeHydration) persist()
        }
    }

    /** Runs the decode [configure] deferred. Call from a background scope; idempotent. */
    @Synchronized
    fun prewarm() {
        val pending = pendingHydration ?: return
        pendingHydration = null
        pending()
    }

    @Synchronized
    fun record(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        setting: String,
        recipeRef: String? = null,
        nowMillis: Long = System.currentTimeMillis(),
    ) {
        if (owner !in setOf("web", "reasoning", "generation") || source !in setOf("custom", "provider_recipe") ||
            !setting.startsWith('/') || (source == "provider_recipe" && recipeRef.isNullOrBlank())
        ) return
        val entry = Entry(
            identity.connectionId,
            identity.canonicalModelId,
            identity.finalTransport,
            identity.runtimeRevision,
            owner,
            source,
            recipeRef,
            setting.take(160),
            nowMillis,
            nowMillis + TTL_MILLIS,
        )
        entries[key(identity, owner, source, entry.recipeRef, entry.setting)] = entry
        prune(nowMillis)
        persist()
    }

    fun isRejected(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        nowMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        var changed = false
        val rejected = entries.entries.any { (key, entry) ->
            if (entry.expiresAt <= nowMillis) {
                changed = entries.remove(key, entry) || changed
                false
            } else {
                entry.identity == identity && entry.owner == owner && entry.source == source
            }
        }
        if (changed) persist()
        return rejected
    }

    fun rejectedSettings(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        recipeRef: String? = null,
        nowMillis: Long = System.currentTimeMillis(),
    ): Set<String> {
        var changed = false
        val values = entries.entries.mapNotNull { (key, entry) ->
            if (entry.expiresAt <= nowMillis) {
                changed = entries.remove(key, entry) || changed
                return@mapNotNull null
            }
            entry.setting.takeIf {
                entry.identity == identity && entry.owner == owner && entry.source == source &&
                    (source != "provider_recipe" || entry.recipeRef == recipeRef)
            }
        }.toSet()
        if (changed) persist()
        return values
    }

    fun isRejectedByAnySource(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        nowMillis: Long = System.currentTimeMillis(),
    ): Boolean = isRejected(identity, owner, "custom", nowMillis) ||
        isRejected(identity, owner, "provider_recipe", nowMillis)

    /** Provider deletion invalidates every model/transport/revision variant atomically. */
    @Synchronized
    fun removeConnection(connectionId: String) {
        entries.entries.removeIf { (_, entry) -> entry.connectionId.equals(connectionId, ignoreCase = true) }
        persist()
    }

    /** Explicit reconfirmation clears only this source/owner on the exact runtime identity. */
    @Synchronized
    fun clear(identity: ModelControlRuntimeIdentity, owner: String, source: String) {
        entries.entries.removeIf { (_, entry) ->
            entry.identity == identity && entry.owner == owner && entry.source == source
        }
        persist()
    }

    @Synchronized
    internal fun configurePersistenceForTesting(read: () -> String?, write: (String?) -> Unit) {
        configurePersistence(read, write)
    }

    @Synchronized
    internal fun simulateColdStartForTesting() {
        entries.clear()
        hydrate()
    }

    @Synchronized
    internal fun clearForTesting() {
        entries.clear()
        readPayload = null
        writePayload = null
        pendingHydration = null
    }

    @Synchronized
    private fun configurePersistence(read: () -> String?, write: (String?) -> Unit) {
        pendingHydration = null
        readPayload = read
        writePayload = write
        entries.clear()
        hydrate()
    }

    private fun hydrate() {
        val now = System.currentTimeMillis()
        val restored = readPayload?.invoke()?.let { payload ->
            runCatching { json.decodeFromString<List<Entry>>(payload) }.getOrDefault(emptyList())
        }.orEmpty()
        restored.filter { entry ->
            entry.expiresAt > now && entry.owner in setOf("web", "reasoning", "generation") &&
                entry.source in setOf("custom", "provider_recipe") && entry.setting.startsWith('/') &&
                (entry.source != "provider_recipe" || !entry.recipeRef.isNullOrBlank())
        }.sortedByDescending(Entry::observedAt).take(MAX_ENTRIES).forEach { entry ->
            entries[key(entry.identity, entry.owner, entry.source, entry.recipeRef, entry.setting)] = entry
        }
    }

    private fun prune(nowMillis: Long) {
        entries.entries.removeIf { it.value.expiresAt <= nowMillis }
        while (entries.size > MAX_ENTRIES) {
            entries.minByOrNull { it.value.observedAt }?.key?.let(entries::remove) ?: break
        }
    }

    private fun persist() {
        val payload = entries.values.sortedByDescending(Entry::observedAt).take(MAX_ENTRIES)
            .takeIf { it.isNotEmpty() }
            ?.let { current -> json.encodeToString(current) }
        writePayload?.invoke(payload)
    }

    private fun key(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        recipeRef: String?,
        setting: String,
    ): String = listOf(
        identity.connectionId.lowercase(),
        identity.canonicalModelId,
        identity.finalTransport,
        identity.runtimeRevision,
        owner,
        source,
        recipeRef.orEmpty(),
        setting,
    ).joinToString("\u001f")
}
