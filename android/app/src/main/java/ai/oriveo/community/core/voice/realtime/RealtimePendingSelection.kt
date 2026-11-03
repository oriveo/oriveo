package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.voice.VoiceCatalog

/**
 * Holds the user's selection while the voice catalog is not ready. Realtime-ness cannot be judged yet, so last-used is not written.
 * Once the catalog arrives, the stash is judged once: realtime stays in this session only, text models in the connection list
 * still write last-used as usual, and a model neither side recognizes is not written; the caller shows "no longer available".
 * Only the most recent selection is kept; a new selection overwrites the old one.
 */
class RealtimePendingSelection {
    data class Pending(val providerId: String, val modelId: String)

    /** Result of judging the stashed selection. */
    sealed interface Resolution {
        val pending: Pending

        /** Realtime model: set as the session's realtime selection; last-used is not written. */
        data class Realtime(override val pending: Pending) : Resolution

        /** Text model: last-used is written as usual. */
        data class Text(override val pending: Pending) : Resolution

        /** Neither the realtime catalog nor the connection's text list recognizes it: not written; the caller shows it is no longer available. */
        data class Gone(override val pending: Pending) : Resolution
    }

    private var pending: Pending? = null

    val current: Pending? get() = pending

    fun stash(providerId: String, modelId: String) {
        pending = Pending(providerId, modelId)
    }

    fun clear() {
        pending = null
    }

    /**
     * Returns null while the catalog is not ready or nothing is stashed (the stash is kept); otherwise consumes the stash and returns a judgment.
     * [providers] are used to find the stash's connection, since realtime judgment depends on connection kind and auth mode.
     */
    fun resolve(catalog: VoiceCatalog?, providers: List<Provider>): Resolution? {
        val item = pending ?: return null
        if (catalog == null) return null
        pending = null
        val provider = providers.firstOrNull { it.id == item.providerId }
        return when {
            RealtimeSelection.isRealtime(provider, item.modelId, catalog) -> Resolution.Realtime(item)
            provider?.models.orEmpty().any { it.id == item.modelId } -> Resolution.Text(item)
            else -> Resolution.Gone(item)
        }
    }
}
