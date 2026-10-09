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
        /** The thinking tier actually selected when it was rejected; null means untiered (legacy entries, the automatic tier, capabilities without tiers). */
        val tier: String? = null,
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
        tier: String? = null,
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
            tier?.take(40),
        )
        entries[key(identity, owner, source, entry.recipeRef, entry.setting, entry.tier)] = entry
        prune(nowMillis)
        persist()
    }

    /** A tiered entry counts only when [selectedTier] is exactly that tier; an untiered entry always counts. */
    fun isRejected(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        nowMillis: Long = System.currentTimeMillis(),
        selectedTier: String? = null,
    ): Boolean {
        var changed = false
        val rejected = entries.entries.any { (key, entry) ->
            if (entry.expiresAt <= nowMillis) {
                changed = entries.remove(key, entry) || changed
                false
            } else {
                entry.identity == identity && entry.owner == owner && entry.source == source &&
                    (entry.tier == null || entry.tier == selectedTier)
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

    /** Rejections on one owner plus recipe grouped by tier: [untiered] means an untiered entry exists (a legacy entry or a capability without tiers). */
    data class TierRejections(val untiered: Boolean, val tiers: Set<String>) {
        val isEmpty: Boolean get() = !untiered && tiers.isEmpty()
    }

    fun tierRejections(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        recipeRef: String? = null,
        nowMillis: Long = System.currentTimeMillis(),
    ): TierRejections {
        val matching = liveEntries(identity, owner, source, recipeRef, nowMillis)
        return TierRejections(
            untiered = matching.any { it.tier == null },
            tiers = matching.mapNotNullTo(linkedSetOf()) { it.tier },
        )
    }

    /** Send side: whether the tier selected for this send (null means automatic or no tier) has been rejected; if so the setting is left out as dormant. */
    fun blocksSelection(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        recipeRef: String? = null,
        selectedTier: String?,
        nowMillis: Long = System.currentTimeMillis(),
    ): Boolean = liveEntries(identity, owner, source, recipeRef, nowMillis).any { it.tier == null || it.tier == selectedTier }

    /** Only a recipe's thinking setting is recorded per tier; custom fields and web search are untiered and the automatic tier has no tier. */
    fun rejectedTier(located: LocatedModelControlRejection, reasoningIntent: String?): String? =
        reasoningIntent?.takeIf {
            located.owner == "reasoning" && located.source == "provider_recipe" && it.isNotBlank() && it != "automatic"
        }

    /** Persists a rejection the upstream located; see [rejectedTier] for [tier]. */
    fun recordLocated(identity: ModelControlRuntimeIdentity, located: LocatedModelControlRejection, tier: String?) {
        located.locatedPointers.forEach { pointer ->
            record(identity, located.owner, located.source, pointer, located.recipeRef, tier = tier)
        }
    }

    private fun liveEntries(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        source: String,
        recipeRef: String?,
        nowMillis: Long,
    ): List<Entry> {
        var changed = false
        val values = entries.entries.mapNotNull { (key, entry) ->
            if (entry.expiresAt <= nowMillis) {
                changed = entries.remove(key, entry) || changed
                return@mapNotNull null
            }
            entry.takeIf {
                entry.identity == identity && entry.owner == owner && entry.source == source &&
                    (source != "provider_recipe" || entry.recipeRef == recipeRef)
            }
        }
        if (changed) persist()
        return values
    }

    fun isRejectedByAnySource(
        identity: ModelControlRuntimeIdentity,
        owner: String,
        nowMillis: Long = System.currentTimeMillis(),
        selectedTier: String? = null,
    ): Boolean = isRejected(identity, owner, "custom", nowMillis) ||
        isRejected(identity, owner, "provider_recipe", nowMillis, selectedTier)

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
            entries[key(entry.identity, entry.owner, entry.source, entry.recipeRef, entry.setting, entry.tier)] = entry
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
        tier: String?,
    ): String = listOf(
        identity.connectionId.lowercase(),
        identity.canonicalModelId,
        identity.finalTransport,
        identity.runtimeRevision,
        owner,
        source,
        recipeRef.orEmpty(),
        setting,
        tier.orEmpty(),
    ).joinToString("\u001f")
}
