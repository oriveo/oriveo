package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

/**
 * Relays (including local engines) have no default model: isDefault in old data is always ignored,
 * and every place that needs "which model does this connection use" goes through the fallback here, with one rule on all platforms
 * (shared fixture `shared/test-fixtures/relay/model-selection.v1.json`). Official providers do not go through here.
 */
object RelayModelFallback {
    fun appliesTo(provider: Provider?): Boolean = provider?.kind == ProviderKind.Relay

    /** Fallback model: if lastUsedModelRef points at this connection and the model is still enabled -> it; otherwise the first enabled model. */
    fun fallbackModel(provider: Provider, lastUsedModelRef: LastUsedModelRef?): AIModel? {
        if (lastUsedModelRef != null && lastUsedModelRef.providerID == provider.id) {
            ModelSelectionUtils.resolveStoredModel(provider.models, lastUsedModelRef.modelID, provider.kind)?.let { return it }
        }
        return provider.models.firstOrNull()
    }

    /** Verification sample: fallback model -> first catalog model -> null (with null no request is sent and the existing missing-model error applies). */
    fun verificationSampleModelID(provider: Provider, lastUsedModelRef: LastUsedModelRef?): String? =
        fallbackModel(provider, lastUsedModelRef)?.id
            ?: provider.catalogModels.firstOrNull()?.id

    /**
     * Session model removed: the non-empty model id stored in a relay session is not among the connection's enabled models.
     * Returns the connection display name (for the banner placeholder); returns null when not removed / not a relay / the session model is empty.
     */
    fun removedConnectionName(provider: Provider?, conversationModelId: String?): String? {
        if (provider == null || !appliesTo(provider)) return null
        val modelId = conversationModelId?.trim().orEmpty()
        if (modelId.isEmpty()) return null
        if (ModelSelectionUtils.resolveStoredModel(provider.models, modelId, provider.kind) != null) return null
        return provider.displayName
    }

    /** Interception rule for the send / retry / continue / regenerate entries: the current selection points at a removed relay model. */
    fun isSelectionRemoved(providers: List<Provider>, providerId: String?, modelId: String?): Boolean {
        val provider = providerId?.let { id -> providers.firstOrNull { it.id == id } } ?: return false
        return removedConnectionName(provider, modelId) != null
    }

    /** Write side: new relay writes never carry a default mark, and relayRequested.modelID is no longer persisted. */
    fun clearingDefaults(provider: Provider): Provider {
        if (!appliesTo(provider)) return provider
        val models = provider.models.map { if (it.isDefault) it.copy(isDefault = false) else it }
        val catalog = provider.catalogModels.map { if (it.isDefault) it.copy(isDefault = false) else it }
        val requested = provider.relayRequested?.let { requested ->
            if (requested.modelID.isNullOrEmpty()) requested else requested.copy(modelID = null)
        }
        return provider.copy(models = models, catalogModels = catalog, relayRequested = requested)
    }
}
