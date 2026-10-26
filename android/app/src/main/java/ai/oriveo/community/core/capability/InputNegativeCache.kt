package ai.oriveo.community.core.capability

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonPrimitive

/**
 * Negative cache v2 of input capabilities across all connections:
 * key = connection x model x effective protocol family x capability key (parameters are written as `param:<name>`), value = recorded time (seconds) + rejection signature id + the verdict revision at record time.
 * Expires after 7 days; a current verdict revision that differs from the entry is a miss and the entry is deleted. Local only; v1 ([ai.oriveo.community.core.provider.relay.RelayNegativeCache]) is neither read nor migrated.
 * Fixture `shared/test-fixtures/capability/negative-cache.v1.json`.
 */
class InputNegativeCache(
    private val store: Store,
    /** Seconds; injected by tests. */
    private val clock: () -> Long = { System.currentTimeMillis() / 1000L },
) {
    /** The verdict fields that take part in the revision. */
    data class Verdict(
        val state: String,
        val reasonCode: String? = null,
        val wireFamily: String? = null,
        val sourceRefs: List<String>? = null,
    )

    data class Key(val connectionId: String, val modelId: String, val wireFamily: String, val capabilityKey: String)

    data class Value(val recordedAt: Long, val signatureId: String, val verdictRevision: String)

    interface Store {
        fun snapshot(): Map<String, String>
        /** Single-key read; reading one entry does not copy the whole table. */
        fun get(name: String): String?
        fun put(name: String, value: String)
        fun remove(names: Collection<String>)
    }

    class MemoryStore : Store {
        private val values = LinkedHashMap<String, String>()
        @Synchronized override fun snapshot(): Map<String, String> = values.toMap()
        @Synchronized override fun get(name: String): String? = values[name]
        @Synchronized override fun put(name: String, value: String) { values[name] = value }
        @Synchronized override fun remove(names: Collection<String>) { names.forEach { values.remove(it) } }
    }

    private val _revision = MutableStateFlow(0L)

    /**
     * Local revision: advances when a rejection is recorded or a connection is cleared; the UI uses it as the key for recomputing projections (after a rejection the "not sent" marker must refresh with it).
     * Deleting an expired entry does not advance it: an expired entry never hit anyway, so the outcome is unchanged.
     */
    val revision: StateFlow<Long> = _revision.asStateFlow()

    /** Records one rejection; the same key is overwritten, and expired entries are dropped along the way. */
    @Synchronized
    fun record(
        connectionId: String,
        modelId: String,
        wireFamily: String?,
        capabilityKey: String,
        signatureId: String,
        verdict: Verdict?,
        now: Long = clock(),
    ) {
        val expired = entries().filter { now - it.second.recordedAt >= TTL_SECONDS }.map { encodeKey(it.first) }
        if (expired.isNotEmpty()) store.remove(expired)
        val key = Key(connectionId, modelId, wireFamily.orEmpty(), capabilityKey)
        store.put(encodeKey(key), encodeValue(Value(now, signatureId, verdictRevision(verdict))))
        _revision.value += 1
    }

    /** A hit = same key, `now - recordedAt < 7 days` and the revision equals the current verdict; an expired entry or a different revision deletes the entry. */
    @Synchronized
    fun isHit(
        connectionId: String,
        modelId: String,
        wireFamily: String?,
        capabilityKey: String,
        verdict: Verdict?,
        now: Long = clock(),
    ): Boolean = read(connectionId, modelId, wireFamily, capabilityKey, verdict, now) != null

    /** Same as [isHit], returning the entry value on a hit. */
    @Synchronized
    fun read(
        connectionId: String,
        modelId: String,
        wireFamily: String?,
        capabilityKey: String,
        verdict: Verdict?,
        now: Long = clock(),
    ): Value? {
        val name = encodeKey(Key(connectionId, modelId, wireFamily.orEmpty(), capabilityKey))
        val raw = store.get(name) ?: return null
        val value = decodeValue(raw)
        if (value == null || now - value.recordedAt >= TTL_SECONDS) {
            store.remove(listOf(name))
            return null
        }
        // A differing revision only reads as a miss and does not delete the entry (same as Web): a read surface with incomplete context computes the revision from another verdict,
        // and deleting would make the context-carrying send side lose the rejection record.
        if (value.verdictRevision != verdictRevision(verdict)) return null
        return value
    }

    /** Re-detection / deleting a connection clears the whole connection. */
    @Synchronized
    fun clearConnection(connectionId: String) {
        val names = entries().filter { it.first.connectionId == connectionId }.map { encodeKey(it.first) }
        if (names.isEmpty()) return
        store.remove(names)
        _revision.value += 1
    }

    @Synchronized
    fun entries(): List<Pair<Key, Value>> = store.snapshot().mapNotNull { (name, raw) ->
        val key = decodeKey(name) ?: return@mapNotNull null
        val value = decodeValue(raw) ?: return@mapNotNull null
        key to value
    }

    private fun encodeKey(key: Key): String =
        listOf(key.connectionId, key.modelId, key.wireFamily, key.capabilityKey).joinToString(SEPARATOR)

    private fun decodeKey(name: String): Key? {
        val parts = name.split(SEPARATOR)
        if (parts.size != 4) return null
        return Key(parts[0], parts[1], parts[2], parts[3])
    }

    private fun encodeValue(value: Value): String =
        listOf(value.recordedAt.toString(), value.signatureId, value.verdictRevision).joinToString(SEPARATOR)

    private fun decodeValue(raw: String): Value? {
        val parts = raw.split(SEPARATOR)
        if (parts.size != 3) return null
        val recordedAt = parts[0].toLongOrNull() ?: return null
        return Value(recordedAt, parts[1], parts[2])
    }

    /** Before startup and in unit tests there is no Context: falls back to process memory, with the same semantics but nothing persisted. */
    private object DefaultStore : Store {
        @Volatile var context: Context? = null
        private val memory = MemoryStore()

        private fun prefs() = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        override fun snapshot(): Map<String, String> =
            prefs()?.all?.mapNotNull { (name, value) -> (value as? String)?.let { name to it } }?.toMap()
                ?: memory.snapshot()

        override fun get(name: String): String? {
            val prefs = prefs() ?: return memory.get(name)
            // A non-string value under the same key (leftover of an old write) counts as no entry, consistent with snapshot accepting strings only.
            return runCatching { prefs.getString(name, null) }.getOrNull()
        }

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
        const val PREFS_NAME = "capability_negative_cache.v2"
        const val TTL_SECONDS = 7L * 24L * 60L * 60L
        private const val SEPARATOR = "\u001F"

        val shared: InputNegativeCache = InputNegativeCache(DefaultStore)

        /** Only keeps the application context; SharedPreferences is opened on the first read or write. */
        fun configure(context: Context) {
            DefaultStore.context = context.applicationContext
        }

        /** Parameter capability key. */
        fun paramCapabilityKey(name: String): String = "param:$name"

        /** Canonical JSON: only the four fields, keys in lexicographic order, null omitted, sourceRefs ascending, no whitespace; a null verdict is `{"state":"unknown"}`. */
        fun canonicalVerdictJson(verdict: Verdict?): String {
            val source = verdict ?: Verdict(state = "unknown")
            val fields = buildList {
                source.reasonCode?.let { add("\"reasonCode\":" + quote(it)) }
                source.sourceRefs?.let { refs -> add("\"sourceRefs\":[" + refs.sorted().joinToString(",") { quote(it) } + "]") }
                add("\"state\":" + quote(source.state))
                source.wireFamily?.let { add("\"wireFamily\":" + quote(it)) }
            }
            return fields.joinToString(",", prefix = "{", postfix = "}")
        }

        /** Verdict revision: FNV-1a 32-bit over the UTF-8 bytes of the canonical JSON, as 8 lowercase hex digits. */
        fun verdictRevision(verdict: Verdict?): String {
            var hash = 0x811c9dc5L
            for (byte in canonicalVerdictJson(verdict).toByteArray(Charsets.UTF_8)) {
                hash = hash xor (byte.toLong() and 0xffL)
                hash = (hash * 0x01000193L) and 0xffffffffL
            }
            return hash.toString(16).padStart(8, '0')
        }

        private fun quote(text: String): String = JsonPrimitive(text).toString()
    }
}
