package ai.oriveo.community.core.provider.relay

import android.content.Context
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayTransport

/**
 * Local negative cache for the Relay upstream-rejection loop: connection x model x effective transport x tier, expires after 7 days,
 * accepts only the Relay form and never enters cloud sync or backups (excluded in backup_rules / data_extraction_rules).
 * The writer calls [record] only when the "test capability" verdict function judges rejected and no output has been produced yet.
 * Fixture `shared/test-fixtures/relay/negative-cache.v1.json`.
 */
class RelayNegativeCache(
    private val store: Store,
    /** Seconds; injected by tests. */
    private val clock: () -> Long = { System.currentTimeMillis() / 1000L },
) {
    enum class Kind(val value: String) {
        Image("image"),
        File("file"),
        ToolCall("toolCall"),
        /** Thinking tier rejected: `reasoningTier:<tier>`, tier = [RelayReasoningTiers.TIERS]. */
        ReasoningFast("reasoningTier:fast"),
        ReasoningBalanced("reasoningTier:balanced"),
        ReasoningDeep("reasoningTier:deep"),
        ReasoningMax("reasoningTier:max"),
        ;

        /** Tier name for thinking-tier entries; null for other tiers. */
        val reasoningTier: String? get() = value.removePrefix(REASONING_TIER_PREFIX).takeIf { value.startsWith(REASONING_TIER_PREFIX) }

        companion object {
            private const val REASONING_TIER_PREFIX = "reasoningTier:"

            fun reasoningTier(tier: String): Kind? = entries.firstOrNull { it.reasoningTier == tier }
        }
    }

    /** [transport] is `RelayTransport.value` (e.g. `openai_chat_completions`). */
    data class Key(val connectionId: String, val modelId: String, val transport: String)

    data class Entry(val key: Key, val kind: Kind, val recordedAt: Long)

    interface Store {
        fun snapshot(): Map<String, Long>
        fun put(name: String, recordedAt: Long)
        fun remove(names: Collection<String>)
    }

    class MemoryStore : Store {
        private val values = LinkedHashMap<String, Long>()
        @Synchronized override fun snapshot(): Map<String, Long> = values.toMap()
        @Synchronized override fun put(name: String, recordedAt: Long) { values[name] = recordedAt }
        @Synchronized override fun remove(names: Collection<String>) { names.forEach { values.remove(it) } }
    }

    @Synchronized
    fun record(key: Key, kind: Kind, now: Long = clock()) {
        val expired = entries().filter { now - it.recordedAt >= TTL_SECONDS }.map { encode(it.key, it.kind) }
        if (expired.isNotEmpty()) store.remove(expired)
        store.put(encode(key, kind), now)
    }

    /**
     * Rejection signal: written only when the "test capability" verdict function judges rejected; others (including 5xx / 401 / 429 / 413) are not written.
     * The caller guarantees this rejection occurred before any output. Returns whether anything was written.
     */
    @Synchronized
    fun recordIfRejected(key: Key, kind: Kind, status: Int, contentType: String?, body: String, now: Long = clock()): Boolean {
        if (RelayCapabilityTest.classify(status, contentType, body).verdict != RelayCapabilityVerdict.Rejected) return false
        record(key, kind, now)
        return true
    }

    /**
     * Outbound-error variant: when sending, only a non-2xx rejection before any output counts; 2xx error bodies and in-stream error frames are not written (the capability test still honors them),
     * and anything that is not an upstream HTTP error (network, cancellation, etc.) is not written.
     */
    fun recordIfRejected(key: Key, kind: Kind, error: Throwable, now: Long = clock()): Boolean {
        if (!isRejectionSignal(error)) return false
        record(key, kind, now)
        return true
    }

    /** Hit = same key and tier and `now - recordedAt < 7 days`. */
    @Synchronized
    fun isRejected(key: Key, kind: Kind, now: Long = clock()): Boolean {
        val recordedAt = store.snapshot()[encode(key, kind)] ?: return false
        return now - recordedAt < TTL_SECONDS
    }

    /** A "test capability" write-back clears image + toolCall; a user's manual override of a tier clears that tier. */
    @Synchronized
    fun clear(key: Key, kinds: Collection<Kind>) {
        store.remove(kinds.map { encode(key, it) })
    }

    /** Unexpired rejected thinking tiers (tier names). */
    fun rejectedReasoningTiers(key: Key, now: Long = clock()): Set<String> =
        Kind.entries.mapNotNullTo(linkedSetOf()) { kind -> kind.reasoningTier?.takeIf { isRejected(key, kind, now) } }


    /** Re-detection / deleting a connection clears the whole connection. */
    @Synchronized
    fun clearConnection(connectionId: String) {
        store.remove(entries().filter { it.key.connectionId == connectionId }.map { encode(it.key, it.kind) })
    }

    @Synchronized
    fun entries(): List<Entry> = store.snapshot().mapNotNull { (name, at) -> decode(name)?.let { (key, kind) -> Entry(key, kind, at) } }

    private fun encode(key: Key, kind: Kind): String =
        listOf(key.connectionId, key.modelId, key.transport, kind.value).joinToString(SEPARATOR)

    private fun decode(name: String): Pair<Key, Kind>? {
        val parts = name.split(SEPARATOR)
        if (parts.size != 4) return null
        val kind = Kind.entries.firstOrNull { it.value == parts[3] } ?: return null
        return Key(parts[0], parts[1], parts[2]) to kind
    }

    /** Before startup and in unit tests there is no Context: fall back to in-process memory, same semantics but not persisted. */
    private object DefaultStore : Store {
        @Volatile var context: Context? = null
        private val memory = MemoryStore()

        private fun prefs() = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        override fun snapshot(): Map<String, Long> =
            prefs()?.all?.mapNotNull { (name, value) -> (value as? Long)?.let { name to it } }?.toMap()
                ?: memory.snapshot()

        override fun put(name: String, recordedAt: Long) {
            prefs()?.edit()?.putLong(name, recordedAt)?.apply() ?: memory.put(name, recordedAt)
        }

        override fun remove(names: Collection<String>) {
            if (names.isEmpty()) return
            val prefs = prefs() ?: return memory.remove(names)
            prefs.edit().apply { names.forEach { remove(it) } }.apply()
        }
    }

    companion object {
        /** Send-side rejection signal: a non-2xx before any output that classify judges rejected; in-stream error frames and 2xx error bodies do not count. */
        fun isRejectionSignal(error: Throwable): Boolean {
            val status = when (error) {
                is ProviderServiceError.Upstream -> error.statusCode.takeUnless { error.streamErrorFrame }
                is ProviderServiceError.RelayUpstream -> error.statusCode
                else -> null
            } ?: return false
            if (status in 200..299) return false
            // "This key cannot use this model" takes precedence over the capability-rejection loop and does not count as a capability rejection.
            if (RelayKeyAccess.isModelAccessDenied(error)) return false
            return RelayCapabilityTest.classify(status, null, "").verdict == RelayCapabilityVerdict.Rejected
        }

        const val PREFS_NAME = "relay_negative_cache.v1"
        const val TTL_SECONDS = 7L * 24L * 60L * 60L
        private const val SEPARATOR = "\u001F"

        val shared: RelayNegativeCache = RelayNegativeCache(DefaultStore)

        /** Only keeps the application context; SharedPreferences is opened on first read/write. */
        fun configure(context: Context) {
            DefaultStore.context = context.applicationContext
        }

        /**
         * Key shared by reads and writes: connection = provider.id (same value as CapabilityEvidenceIdentity.connectionInstanceId and
         * ModelControlRuntimeIdentity.connectionId), model = the model.id sent upstream, transport = the first-send transport
         * ([RelayFirstSendTransport.resolve]: an unverified Claude family on an auto connection uses Messages, otherwise the same as the effective transport;
         * chat's first send and the advanced page's "Auto =" read the same one). Null for non-Relay forms.
         */
        fun keyFor(provider: Provider, model: AIModel): Key? =
            keyFor(provider, model, RelayFirstSendTransport.resolve(provider, model))

        /** When the transport actually used for this send is known (send-side write-back), the key is computed from it. */
        fun keyFor(provider: Provider, model: AIModel, transport: RelayTransport): Key? {
            if (ProviderForm.of(provider) != ProviderForm.Relay) return null
            return Key(provider.id, model.id, transport.value)
        }
    }
}
