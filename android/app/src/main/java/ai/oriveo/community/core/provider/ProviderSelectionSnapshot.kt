package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import java.time.Instant

/**
 * Lightweight selection snapshot: it only reads the enabled, current and new-chat fallback models and
 * never falls back to the full catalog.
 */
object ProviderSelectionSnapshot {
    data class PersistedSelection(
        val model: AIModel?,
        val storedModelId: String,
    )

    fun enabledModels(provider: Provider?): List<AIModel> = provider?.models ?: emptyList()

    /**
     * New-chat fallback: catalog defaultModelId > first enabled; both tiers only take usable models
     * (when the catalog is loaded, retired / not-in-catalog models are excluded, judged like [modelRetirement]); returns null when none is usable and never falls back to a retired model.
     * The connection's isDefault is not read: it is mostly written automatically by the client (the first one when the list is fetched, the first hand-entered one), so only list order and the "default" marker keep it.
     */
    fun newChatFallbackModel(
        provider: Provider?,
        metadata: MetadataClient = MetadataClient.instance,
        now: Instant = Instant.now(),
    ): AIModel? {
        val enabled = enabledModels(provider)
        if (enabled.isEmpty()) return null
        fun usable(model: AIModel): Boolean = newChatUsable(provider, model.id, metadata, now)
        if (provider != null && provider.kind != ProviderKind.Relay) {
            val metadataDefaultId = metadata.defaultModelId(provider.kind)
            if (!metadataDefaultId.isNullOrBlank()) {
                ModelSelectionUtils.matchingModel(enabled, metadataDefaultId, provider.kind)
                    ?.takeIf(::usable)
                    ?.let { return it }
            }
        }
        return enabled.firstOrNull(::usable)
    }

    fun selectedModel(
        provider: Provider?,
        modelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): AIModel? = selectedModel(provider, modelId, metadata) { enabled, targetId ->
        ModelSelectionUtils.resolveStoredModel(enabled, targetId, provider?.kind)
    }

    /**
     * [enabledMatch] must return exactly what `ModelSelectionUtils.resolveStoredModel(enabled, targetId, provider.kind)` returns, for
     * example a [ModelSelectionUtils.CatalogMatchIndex] built over the same enabled list, which spares per-row
     * callers a full scan.
     */
    internal fun selectedModel(
        provider: Provider?,
        modelId: String?,
        metadata: MetadataClient,
        enabledMatch: (enabled: List<AIModel>, targetId: String) -> AIModel?,
    ): AIModel? {
        val targetId = modelId?.trim().orEmpty()
        if (provider == null || targetId.isEmpty()) return null

        val enabled = enabledModels(provider)
        if (enabled.isEmpty()) return null

        enabledMatch(enabled, targetId)?.let { return it }

        if (provider.kind != ProviderKind.Relay) {
            val resolved = metadata.resolveCatalogModel(targetId, provider.kind)
            val canonical = resolved?.canonicalModelId
            if (!canonical.isNullOrBlank()) {
                enabledMatch(enabled, canonical)?.let { return it }
                return metadataBackedHistoricalModel(
                    provider = provider,
                    resolved = resolved,
                    fallbackModelId = targetId,
                )
            }
        }

        return null
    }

    /**
     * The conversation's model: falls back to the default when it cannot be resolved; but a conversation judged retired (retired / missing) does not fall back,
     * because switching to the default would silently change the user's model; the hint banner and send block are the caller's job via [modelRetirement].
     * When judged available but unresolvable (catalog not loaded, built-in snapshot state, hand-entered id) a bare model is built from the stored id and sent as is, without switching to the default.
     * For a conversation with an empty modelID: if [lastUsedModelRef] points at this connection and that model is enabled and usable, take it first, then the new-chat fallback.
     */
    fun currentModel(
        provider: Provider?,
        storedModelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
        lastUsedModelRef: LastUsedModelRef? = null,
    ): AIModel? {
        selectedModel(provider, storedModelId, metadata)?.let { return it }
        if (storedModelId.isNullOrBlank() && provider != null && lastUsedModelRef?.providerID == provider.id) {
            ModelSelectionUtils.resolveStoredModel(enabledModels(provider), lastUsedModelRef.modelID, provider.kind)
                ?.takeIf { newChatUsable(provider, it.id, metadata) }
                ?.let { return it }
        }
        val retirement = modelRetirement(provider, storedModelId, metadata)
        return when {
            // An empty id, or a connection that is not judged for retirement, that cannot be resolved falls back along the new-chat chain and does not read the connection's isDefault.
            retirement == null -> newChatFallbackModel(provider, metadata)
            retirement.sendBlocked -> null
            provider == null -> null
            else -> bareStoredModel(provider, retirement.modelIdAfter)
        }
    }

    /** A bare model for the stored id: the name is the id, and capabilities / prices go through the same builder as catalog models (defaults when unresolvable). */
    private fun bareStoredModel(provider: Provider, modelId: String): AIModel =
        CatalogModelBuilder.buildCatalogModel(
            providerKind = provider.kind,
            runtimeModelId = modelId,
            fallbackName = modelId,
        )

    /**
     * Adapter for conversation-model retirement: only judges official BYOK providers.
     * Relay (goes through [RelayModelFallback]), subscription-login connections and an empty model id return null (not judged).
     * The catalog of an official BYOK provider = that provider's catalog once MetadataClient is Loaded.
     * userModels = the model ids enabled on the connection.
     */
    fun modelRetirement(
        provider: Provider?,
        modelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
        now: Instant = Instant.now(),
    ): ModelRetirement.ConversationModelStatus? {
        val targetId = modelId?.trim().orEmpty()
        if (targetId.isEmpty()) return null
        val judged = retirementInputs(provider, metadata) ?: return null
        return ModelRetirement.conversationStatus(
            catalog = judged.catalog,
            userModels = judged.userModels,
            modelId = targetId,
            storedName = null,
            now = now,
            bundled = judged.bundled,
        )
    }

    /**
     * Usable in a new chat: judged like the catalog and snapshot state of [modelRetirement], and additionally a model that is enabled but not in the catalog (missing) is unusable.
     * Connections not judged for retirement (Relay / subscription login) are always usable.
     */
    fun newChatUsable(
        provider: Provider?,
        modelId: String,
        metadata: MetadataClient = MetadataClient.instance,
        now: Instant = Instant.now(),
    ): Boolean {
        val judged = retirementInputs(provider, metadata) ?: return true
        val canonicalId = provider?.models?.firstOrNull { it.id == modelId }?.canonicalModelId
        return ModelRetirement.isNewChatUsable(judged.catalog, judged.userModels, modelId, now, judged.bundled, canonicalId)
    }

    private class RetirementInputs(
        val catalog: ModelRetirement.Catalog?,
        val userModels: List<String>,
        val bundled: Boolean,
    )

    private fun retirementInputs(provider: Provider?, metadata: MetadataClient): RetirementInputs? {
        if (provider == null) return null
        if (provider.kind == ProviderKind.Relay) return null
        if (provider.authMode == ProviderAuthMode.Subscription) return null
        // The enabled set includes canonical ids: the catalog / conversation often records the canonical id while the enabled one is its dated snapshot.
        val userModels = provider.models.flatMap { listOfNotNull(it.id, it.canonicalModelId?.takeIf(String::isNotBlank)) }.distinct()
        return RetirementInputs(metadata.retirementCatalog(provider.kind), userModels, bundled = metadata.isBundledSnapshotActive)
    }

    fun runtimeModelId(
        provider: Provider?,
        storedModelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): String? = selectedModel(provider, storedModelId, metadata)?.id ?: storedModelId?.trim()?.takeIf { it.isNotEmpty() }

    fun persistedSelection(
        provider: Provider?,
        requestedModelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): PersistedSelection? {
        val targetId = requestedModelId?.trim().orEmpty()
        if (targetId.isEmpty()) return null

        val model = selectedModel(provider, targetId, metadata)
        val storedModelId = model?.let { ModelSelectionUtils.preferredStoredModelIdentifier(it, provider?.kind) }
            ?: ModelSelectionUtils.resolvedId(targetId)

        return PersistedSelection(
            model = model,
            storedModelId = storedModelId,
        )
    }

    private fun metadataBackedHistoricalModel(
        provider: Provider,
        resolved: MetadataClient.ResolvedModelMetadata?,
        fallbackModelId: String,
    ): AIModel? {
        val metadataModel = resolved ?: return null
        val pricing = CatalogModelBuilder.pricePresentation(metadataModel)
        return AIModel(
            id = metadataModel.canonicalModelId,
            name = metadataModel.displayName ?: metadataModel.canonicalModelId,
            capabilities = metadataModel.capabilities.ifEmpty { listOf(ai.oriveo.community.core.model.ModelCapability.Text) },
            reasoningModeAvailable = metadataModel.profiles.reasoning != null,
            isAvailable = true,
            isDefault = metadataModel.isDefault,
            priceTier = pricing.priceTier,
            summary = compactContextText(metadataModel.contextLength),
            contextLength = metadataModel.contextLength,
            groupKey = metadataModel.uiHints?.groupKey,
            groupName = metadataModel.uiHints?.groupName,
            promptPrice = pricing.promptPrice,
            completionPrice = pricing.completionPrice,
            canonicalModelId = metadataModel.canonicalModelId,
            isRecommended = metadataModel.uiHints?.recommended ?: false,
            sortRank = metadataModel.uiHints?.rank,
            badgeOrder = metadataModel.uiHints?.badgeOrder,
            reasoningProfile = metadataModel.profiles.reasoning,
            webSearchProfile = metadataModel.profiles.webSearch,
            imageGenProfile = metadataModel.profiles.imageGen,
            toolCall = metadataModel.toolCall,
        )
    }

    private fun compactContextText(contextLength: Int?): String? {
        val value = contextLength ?: return null
        if (value <= 0) return null
        return when {
            value >= 1_000_000 -> "${value / 1_000_000}M"
            value >= 1_000 -> "${value / 1_000}K"
            else -> value.toString()
        }
    }
}
