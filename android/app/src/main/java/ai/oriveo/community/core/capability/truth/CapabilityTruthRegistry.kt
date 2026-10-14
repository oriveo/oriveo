package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade

/**
 * Unified interface of the per-form capability truth sources: they only produce candidates; they do not adjudicate, touch the network, read credentials or write any state.
 * Adjudication happens in one place only, [CapabilityEvidenceFacade.resolve].
 */
internal interface CapabilityTruthAdapter {
    /** All inputs needed to fetch candidates once; adapters must not look for context elsewhere. */
    data class Input(
        val provider: Provider,
        val model: AIModel,
        val key: String,
        val queryIdentity: CapabilityEvidenceFacade.QueryIdentity?,
        /** Current publication of the official metadata; the Relay truth is not there, always null. */
        val current: MetadataClient.CurrentCapabilityEvidenceModel?,
        val finalTransport: String?,
        val metadataClient: MetadataClient,
    )

    fun candidates(input: Input): List<CapabilityEvidenceFacade.Candidate>

    /**
     * When no usable evidence exists, whether the user's explicit intent may let the request out (the escape hatch of adjudication).
     * Catalog-based forms are closed-world: the whole request is owned by the Server, and capabilities the catalog does not declare will not be accepted by the other side,
     * so they declare false and the explicit intent is dropped before reaching the facade.
     */
    val acceptsUnverifiedExplicitIntent: Boolean get() = true
}

/** Form -> truth adapter: the single registry (the contract `forms.adapters`). */
internal object CapabilityTruthRegistry {
    // No else branch: when adding a form, its truth source must be stated explicitly here and must not silently fall into some default adapter.
    fun adapterFor(form: ProviderForm): CapabilityTruthAdapter = when (form) {
        ProviderForm.Subscription -> SubscriptionTruthAdapter
        ProviderForm.Relay -> RelayTruthAdapter
        ProviderForm.Official -> OfficialTruthAdapter
    }
}
