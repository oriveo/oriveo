package ai.oriveo.community.core.provider

import android.content.SharedPreferences
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Local-only tool-call memory. Scoped per account, connection, auth mode and model, and it never leaves the device. */
class ToolCallMemoryStore(
    private val prefsProvider: () -> SharedPreferences,
    private val json: Json,
    /** Current modelFactsRevision; a rejection (false) recorded under another revision is void. */
    private val factsRevision: () -> String? = { MetadataClient.modelFactsRevision() },
) {
    @Serializable
    private data class PersistedEntry(
        val partitionId: String,
        val connectionId: String,
        val authMode: String,
        val modelId: String,
        val toolCall: Boolean,
        val observedAt: Long,
        val reason: String,
        /** modelFactsRevision at record time; lookup drops the entry when it differs from the current one. */
        val factsRevision: String? = null,
    )

    private data class Key(
        val partitionId: String,
        val connectionId: String,
        val authMode: String,
        val modelId: String,
    )

    private val lock = Any()
    private var hydrated = false
    private val entries = linkedMapOf<Key, PersistedEntry>()
    private val revisionCounter = AtomicLong(0)
    private val mutableRevision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = mutableRevision

    fun prewarm() {
        synchronized(lock) { hydrateLocked() }
    }

    fun lookup(partitionId: String, provider: Provider, model: AIModel): Boolean? {
        if (!isEligible(provider, model) || partitionId.isBlank()) return null
        val key = key(partitionId, provider, model.id) ?: return null
        return synchronized(lock) {
            hydrateLocked()
            // A changed revision only voids a rejection (false); an observed support (true) is kept.
            entries[key]?.takeIf { it.toolCall || it.factsRevision == factsRevision() }?.toolCall
        }
    }

    fun record(
        partitionId: String,
        provider: Provider,
        model: AIModel,
        observedToolCall: Boolean,
        reason: String,
    ): Boolean {
        if (!isEligible(provider, model) || partitionId.isBlank()) return false
        val key = key(partitionId, provider, model.id) ?: return false
        synchronized(lock) {
            hydrateLocked()
            val previous = entries[key]
            val revision = factsRevision()
            if (
                previous?.toolCall == observedToolCall && previous.reason == reason &&
                previous.factsRevision == revision
            ) return false
            entries[key] = PersistedEntry(
                partitionId = key.partitionId,
                connectionId = key.connectionId,
                authMode = key.authMode,
                modelId = key.modelId,
                toolCall = observedToolCall,
                observedAt = System.currentTimeMillis(),
                reason = reason,
                factsRevision = revision,
            )
            trimLocked()
            persistLocked()
            publishRevision()
            return true
        }
    }

    fun clearConnection(partitionId: String, connectionId: String) {
        if (partitionId.isBlank() || connectionId.isBlank()) return
        synchronized(lock) {
            hydrateLocked()
            val changed = entries.entries.removeIf { (key, _) ->
                key.partitionId == partitionId && key.connectionId == connectionId
            }
            if (changed) {
                persistLocked()
                publishRevision()
            }
        }
    }

    internal fun isEligible(provider: Provider, model: AIModel): Boolean =
        provider.kind == ProviderKind.Relay ||
            CapabilityControlResolution.isSubscriptionLink(provider) ||
            model.isManual

    private fun key(partitionId: String, provider: Provider, modelId: String): Key? {
        val connection = provider.id.trim()
        val model = MetadataClient.normalizeModelFactsID(modelId)
        if (connection.isEmpty() || model.isEmpty()) return null
        return Key(partitionId, connection, provider.authMode.rawValue, model)
    }

    private fun hydrateLocked() {
        if (hydrated) return
        val raw = prefsProvider().getString(KEY_ENTRIES, null)
        val decoded = raw?.let {
            runCatching { json.decodeFromString<List<PersistedEntry>>(it) }.getOrNull()
        }.orEmpty()
        decoded.forEach { entry ->
            if (
                entry.partitionId.isNotBlank() && entry.connectionId.isNotBlank() &&
                entry.authMode.isNotBlank() && entry.modelId.isNotBlank()
            ) {
                entries[Key(entry.partitionId, entry.connectionId, entry.authMode, entry.modelId)] = entry
            }
        }
        hydrated = true
    }

    private fun trimLocked() {
        while (entries.size > MAX_ENTRIES) {
            val oldest = entries.minByOrNull { it.value.observedAt }?.key ?: return
            entries.remove(oldest)
        }
    }

    private fun persistLocked() {
        prefsProvider().edit().putString(KEY_ENTRIES, json.encodeToString(entries.values.toList())).apply()
    }

    private fun publishRevision() {
        mutableRevision.value = revisionCounter.incrementAndGet()
    }

    companion object {
        const val PREFS_NAME = "oriveo_tool_call_memory"
        private const val KEY_ENTRIES = "entries_v1"
        private const val MAX_ENTRIES = 500
    }
}
