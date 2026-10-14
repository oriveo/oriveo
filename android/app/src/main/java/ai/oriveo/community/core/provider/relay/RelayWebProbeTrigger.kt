package ai.oriveo.community.core.provider.relay

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/** A model that may be probed: [transport] is the first-send protocol's `RelayTransport.value`, [fragmentHash] is the hash of that protocol's current fragment. */
data class RelayWebProbeCandidate(val modelId: String, val transport: String, val fragmentHash: String)

/** One auto-probe history entry: written only by auto probes before sending (fixture `triggers.dedupeKey` + sentAt, milliseconds). */
data class RelayWebProbeAutoEntry(
    val connectionId: String,
    val modelId: String,
    val transport: String,
    val fragmentHash: String,
    val sentAt: Long,
)

/** Trigger events (fixture `triggerCases[].event.type`). */
sealed interface RelayWebProbeTriggerEvent {
    /** Web Search page saved successfully: the whole save is one event. */
    data object SaveFragment : RelayWebProbeTriggerEvent

    /** Lazy verification after a single enable: [lazyVerifyPassed] = lazy verification actually ran and passed. */
    data class EnableModel(val lazyVerifyPassed: Boolean) : RelayWebProbeTriggerEvent

    /** Manual probe from the capability test panel: no cap, no dedupe, not added to history. */
    data object ManualTest : RelayWebProbeTriggerEvent

    /** Test again on a rejected model in the Web Search page: same as a manual probe. */
    data object Retest : RelayWebProbeTriggerEvent

    /** Any other moment (add connection, re-detect, change key, refresh catalog, startup): never probe. */
    data object Other : RelayWebProbeTriggerEvent
}

/** Selection result: [probe] are sent in order, [untested] were not sent because of the cap; [countsTowardCap] = whether it counts toward the rolling cap (only auto probes do). */
data class RelayWebProbeSelection(
    val probe: List<String>,
    val untested: List<String>,
    val countsTowardCap: Boolean,
) {
    companion object {
        val None = RelayWebProbeSelection(emptyList(), emptyList(), countsTowardCap = false)
    }
}

/**
 * Auto triggering of web probes (fixture `web-probe.v1.json` triggers / triggerCases).
 * Pure functions: the clock is injected by the caller; only the RELAY form is probed.
 */
object RelayWebProbeTrigger {
    const val PER_SAVE = 5
    const val PER_CONNECTION_PER_WINDOW = 10
    const val WINDOW_SECONDS = 86_400L
    const val WINDOW_MILLIS = WINDOW_SECONDS * 1_000L

    /**
     * [candidates] in enable order, already filtered by the caller to models whose first-send protocol has a non-empty stored fragment; [history] is the whole local auto history.
     */
    fun select(
        isRelayForm: Boolean,
        event: RelayWebProbeTriggerEvent,
        candidates: List<RelayWebProbeCandidate>,
        history: List<RelayWebProbeAutoEntry>,
        now: Long,
        connectionId: String,
    ): RelayWebProbeSelection {
        if (!isRelayForm) return RelayWebProbeSelection.None
        return when (event) {
            RelayWebProbeTriggerEvent.Other -> RelayWebProbeSelection.None
            // Manual: no cap, no dedupe, not added to history.
            RelayWebProbeTriggerEvent.ManualTest, RelayWebProbeTriggerEvent.Retest ->
                RelayWebProbeSelection(candidates.map { it.modelId }, emptyList(), countsTowardCap = false)
            is RelayWebProbeTriggerEvent.EnableModel ->
                if (event.lazyVerifyPassed) automatic(candidates, history, now, connectionId) else RelayWebProbeSelection.None
            RelayWebProbeTriggerEvent.SaveFragment -> automatic(candidates, history, now, connectionId)
        }
    }

    /** Deduplicated ones take no slot; of the rest take min(perSave, remaining in the window) in enable order, the others are untested. */
    private fun automatic(
        candidates: List<RelayWebProbeCandidate>,
        history: List<RelayWebProbeAutoEntry>,
        now: Long,
        connectionId: String,
    ): RelayWebProbeSelection {
        val ofConnection = history.filter { it.connectionId == connectionId }
        val sentKeys = ofConnection.map { Triple(it.modelId, it.transport, it.fragmentHash) }.toSet()
        val fresh = candidates.filter { Triple(it.modelId, it.transport, it.fragmentHash) !in sentKeys }.map { it.modelId }
        val inWindow = ofConnection.count { now - it.sentAt < WINDOW_MILLIS }
        val slots = minOf(PER_SAVE, PER_CONNECTION_PER_WINDOW - inWindow).coerceAtLeast(0)
        return RelayWebProbeSelection(fresh.take(slots), fresh.drop(slots), countsTowardCap = true)
    }
}

/**
 * Local auto-probe history `relay_web_probe_auto_history.v1`: at the same level as probe records, stored on this device only, excluded from backup, and cleared with the whole connection when it is deleted.
 * Key = connection x model x protocol x fragment hash, value = {sentAt}.
 */
class RelayWebProbeAutoHistory(private val store: RelayWebProbeRecordStore.Store) {
    @Synchronized
    fun entries(): List<RelayWebProbeAutoEntry> = store.snapshot().mapNotNull { (name, value) -> decode(name, value) }

    @Synchronized
    fun add(entry: RelayWebProbeAutoEntry) {
        store.put(encode(entry), buildJsonObject { put("sentAt", entry.sentAt) }.toString())
    }

    @Synchronized
    fun clearConnection(connectionId: String) {
        store.remove(entries().filter { it.connectionId == connectionId }.map(::encode))
    }

    /** Prune on save: delete entries of this connection that are outside the window and whose (protocol, hash) is not the current fragment. [current] = protocol to current fragment hash. */
    @Synchronized
    fun prune(connectionId: String, now: Long, current: Map<String, String>) {
        store.remove(
            entries().filter {
                it.connectionId == connectionId &&
                    now - it.sentAt >= RelayWebProbeTrigger.WINDOW_MILLIS &&
                    current[it.transport] != it.fragmentHash
            }.map(::encode),
        )
    }

    private fun encode(entry: RelayWebProbeAutoEntry): String =
        listOf(entry.connectionId, entry.modelId, entry.transport, entry.fragmentHash).joinToString(SEPARATOR)

    private fun decode(name: String, value: String): RelayWebProbeAutoEntry? {
        val parts = name.split(SEPARATOR)
        if (parts.size != 4) return null
        val sentAt = runCatching { ((Json.parseToJsonElement(value) as JsonObject).getValue("sentAt") as JsonPrimitive).long }
            .getOrNull() ?: return null
        return RelayWebProbeAutoEntry(parts[0], parts[1], parts[2], parts[3], sentAt)
    }

    /** Before startup and in unit tests there is no Context: fall back to in-process memory, with the same semantics but nothing persisted. */
    private object DefaultStore : RelayWebProbeRecordStore.Store {
        @Volatile var context: Context? = null
        private val memory = RelayWebProbeRecordStore.MemoryStore()

        private fun prefs() = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        override fun snapshot(): Map<String, String> =
            prefs()?.all?.mapNotNull { (name, value) -> (value as? String)?.let { name to it } }?.toMap()
                ?: memory.snapshot()

        override fun put(name: String, value: String) {
            prefs()?.edit()?.putString(name, value)?.apply() ?: memory.put(name, value)
        }

        override fun remove(names: Collection<String>) {
            if (names.isEmpty()) return
            val prefs = prefs() ?: return memory.remove(names)
            prefs.edit().apply { names.forEach { remove(it) } }.apply()
        }
    }

    companion object {
        const val PREFS_NAME = "relay_web_probe_auto_history.v1"
        private const val SEPARATOR = "\u001F"

        val shared: RelayWebProbeAutoHistory = RelayWebProbeAutoHistory(DefaultStore)

        fun configure(context: Context) {
            DefaultStore.context = context.applicationContext
        }
    }
}
