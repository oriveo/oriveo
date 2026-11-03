package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * The only check that the selected model is realtime: the server voice catalog realtime[] x an official apiKey connection.
 * Never guess from the model id. Relay, hosted-provider and subscription-login connections, and an unloaded catalog, never count.
 */
object RealtimeSelection {
    fun realtimeEntry(provider: Provider?, modelId: String?, catalog: VoiceCatalog?): VoiceRealtimeEntry? {
        val targetId = modelId?.trim().orEmpty()
        if (provider == null || catalog == null || targetId.isEmpty()) return null
        if (RealtimeModel.connectionAuth(provider.kind, provider.authMode) != RealtimeModel.AUTH_API_KEY) return null
        return catalog.entries(provider.kind, VoiceDirection.Realtime)
            .firstOrNull { it.model == targetId } as? VoiceRealtimeEntry
    }

    fun isRealtime(provider: Provider?, modelId: String?, catalog: VoiceCatalog?): Boolean =
        realtimeEntry(provider, modelId, catalog) != null

    /**
     * Synchronous pre-check while the connection is not yet available (the VM's providers are empty when no one subscribes): some provider's realtime[] in the catalog lists this model.
     * Only decides whether to skip prewarming the last-used model until the connection arrives; the final decision still goes through [realtimeEntry].
     */
    fun catalogListsRealtime(modelId: String?, catalog: VoiceCatalog?): Boolean {
        val targetId = modelId?.trim().orEmpty()
        if (catalog == null || targetId.isEmpty()) return false
        return catalog.providers.values.any { provider -> provider.realtime.any { it.model == targetId } }
    }

    /** Synthetic model: id and name are the catalog model; context comes from the catalog contextWindow. Not added to the enabled list and never judged for removal. */
    fun realtimeAIModel(entry: VoiceRealtimeEntry): AIModel = AIModel(
        id = entry.model,
        name = entry.model,
        contextLength = entry.contextWindow.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
    )
}

/**
 * When the realtime judgment must be re-run: emitted only when catalog content differs from the previous one (not ready = null).
 * The first value is always emitted; identical content is not re-emitted.
 * Same shape as scripts/lib/realtime-model.mjs:catalogSequence.
 */
fun Flow<VoiceCatalogState?>.realtimeCatalogChanges(): Flow<VoiceCatalog?> =
    map { (it as? VoiceCatalogState.Available)?.catalog }.distinctUntilChanged()
