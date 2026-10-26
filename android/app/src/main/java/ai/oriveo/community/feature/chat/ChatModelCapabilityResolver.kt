package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.capability.truth.InputCapabilityProjections
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.AttachmentInputGate
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.feature.chat.composer.ComposerAttachmentEntryModel

/**
 * Given a set of models and a capability, picks out the ones for which that capability is
 * automatically available on the current connection.
 *
 * ModelControlsSheet uses this to offer a "show models that support this" action when the selected
 * model reports unavailable, unknown or custom-only. It is a pure function with an injected lookup,
 * so it stays decoupled from the [MetadataClient] singleton and can be tested on its own. A
 * candidate survives only when its state is auto_available and its recipe transport and model
 * transport agree once normalized by [canonicalCapabilityTransport].
 */
object CapabilityControlActionCandidates {
    data class ModelCapabilityLookup(
        val state: String?,
        val recipeTransport: String?,
        val modelTransport: String?,
    )

    fun <T> supportingModels(
        capability: String,
        models: List<T>,
        lookup: (T) -> ModelCapabilityLookup,
    ): List<T> {
        return models.filter { model ->
            val info = lookup(model)
            if (info.state != "auto_available") return@filter false
            val recipeTransport = info.recipeTransport ?: return@filter false
            val modelTransport = info.modelTransport ?: return@filter false
            canonicalCapabilityTransport(recipeTransport) == canonicalCapabilityTransport(modelTransport)
        }
    }
}

class ChatModelCapabilityResolver internal constructor(
    private val metadata: MetadataClient = MetadataClient.instance,
    private val runtimeConfigProvider: () -> MetadataClient.RelayRuntimeConfig = metadata::relayRuntimeConfig,
    private val negativeCache: RelayNegativeCache = RelayNegativeCache.shared,
) {
    data class ModelControls(
        val webAvailable: Boolean = false,
        val webForceAvailable: Boolean = false,
        val reasoningIntents: List<String> = emptyList(),
        val generationAvailable: Boolean = false,
        val webState: String = "unknown",
        val reasoningState: String = "unknown",
        val generationState: String = "unknown",
        val webReasonCode: String? = null,
        val reasoningReasonCode: String? = null,
        val generationReasonCode: String? = null,
    )
    data class CapabilitySelection(
        val reasoningMode: ReasoningMode,
        val webSearchEnabled: Boolean,
    )

    fun activeProvider(
        conversationProvider: Provider?,
        providers: List<Provider>,
        activeProviderId: String?,
    ): Provider? = conversationProvider ?: providers.find { it.id == activeProviderId }

    fun activeModelCapabilities(model: AIModel?): List<ModelCapability> =
        model?.capabilities ?: emptyList()

    fun supportsImage(
        provider: Provider?,
        model: AIModel?,
        localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity? = null,
    ): Boolean = attachmentInputGate(provider, model, localIdentity).image

    /**
     * The single set of facts behind the attachment entries and the import decision: image / native file / video read the
     * editable flag of [resolveInputCapabilityProjections] (unknown can still be attached); inline text files are not gated
     * by file_input, see [textFileInline]. When a Relay connection identity is unavailable the three keys fail closed
     * (the negative-cache and override keys are incomplete), so both the entries and the import must pass [localIdentity].
     */
    fun attachmentInputGate(
        provider: Provider?,
        model: AIModel?,
        localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity? = null,
    ): AttachmentInputGate = attachmentInputFacts(provider, model, localIdentity).first

    /** The attachment menu model: the same projection as [attachmentInputGate], with a reason on every disabled item. */
    internal fun attachmentEntryModel(
        provider: Provider?,
        model: AIModel?,
        localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity? = null,
    ): ComposerAttachmentEntryModel = attachmentInputFacts(provider, model, localIdentity)
        .let { (gate, projections) -> ComposerAttachmentEntryModel.from(projections, gate) }

    private fun attachmentInputFacts(
        provider: Provider?,
        model: AIModel?,
        localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity?,
    ): Pair<AttachmentInputGate, InputCapabilityProjections?> {
        if (provider == null || model == null) return AttachmentInputGate.NONE to null
        val relay = ProviderForm.of(provider) == ProviderForm.Relay
        val envelope = relayRuntimeAttachmentSupport(provider, model)
        val relayIdentity = if (relay) relayIdentity(provider, model, localIdentity) else null
        val projections = resolveInputCapabilityProjections(
            provider = provider,
            model = model,
            relayIdentity = relayIdentity,
            relayAttachmentSupport = envelope,
            metadataClient = metadata,
            relayNegativeCache = negativeCache,
        ) ?: return AttachmentInputGate.NONE to null
        val textFileInline = textFileInline(provider, relay, envelope)
        return AttachmentInputGate(
            image = projections.vision.editable,
            nativeFile = projections.file.editable,
            textFileInline = textFileInline,
            video = projections.video.editable,
        ) to projections
    }

    fun supportsWeb(provider: Provider?, model: AIModel?): Boolean {
        if (provider?.kind != ProviderKind.Relay) {
            val transport = finalTransport(provider, model)
            return modelControls(provider, model, transport).webAvailable
        }
        if (!hasGovernedMetadataCapability(provider, model, ModelCapability.Web)) return false
        // Relay transport envelope is a capability-specific eligibility gate, not a second
        // source of support truth. The facade has already decided support/source/grade.
        return provider.takeIf { it.kind == ProviderKind.Relay }?.let {
            RelayRuntimeSupport.supportsWebSearch(
                provider = it,
                runtimeConfig = runtimeConfigProvider(),
                model = model,
            )
        } ?: true
    }

    fun supportsReasoning(provider: Provider?, model: AIModel?): Boolean =
        supportedReasoningModes(provider, model).any { it != ReasoningMode.Automatic }

    fun supportedReasoningModes(provider: Provider?, model: AIModel?): List<ReasoningMode> {
        val actualProvider = provider ?: return listOf(ReasoningMode.Automatic)
        val actualModel = model ?: return listOf(ReasoningMode.Automatic)
        if (actualProvider.kind != ProviderKind.Relay) {
            val intents = modelControls(actualProvider, actualModel, finalTransport(actualProvider, actualModel))
                .reasoningIntents
            return listOf(ReasoningMode.Automatic) +
                intents.mapNotNull(ReasoningMode::fromIntentOrNull).distinct()
        }
        return listOf(ReasoningMode.Automatic) +
            CapabilityEvidenceProductionAdapter.supportedReasoningModes(
            provider = actualProvider,
            model = actualModel,
            metadataClient = metadata,
        )
    }

    fun normalizedCapabilitySelection(
        provider: Provider?,
        model: AIModel?,
        reasoningMode: ReasoningMode,
        webSearchEnabled: Boolean,
    ): CapabilitySelection {
        val supportedModes = supportedReasoningModes(provider, model)
        val normalizedReasoning = if (reasoningMode in supportedModes && provider?.kind == ProviderKind.Relay && model != null) {
            CapabilityEvidenceProductionAdapter.effectiveReasoningMode(
                provider = provider,
                model = model,
                requested = reasoningMode,
                metadataClient = metadata,
            )
        } else if (reasoningMode in supportedModes) {
            reasoningMode
        } else {
            ReasoningMode.Automatic
        }
        val normalizedWebSearch = webSearchEnabled && supportsWeb(provider, model)

        return CapabilitySelection(
            reasoningMode = normalizedReasoning,
            webSearchEnabled = normalizedWebSearch,
        )
    }

    /**
     * The catalog transport is the only authoritative final carrier available before dispatch.
     * Relay deliberately returns null: its user directory is not a catalog official recipe.
     */
    fun finalTransport(provider: Provider?, model: AIModel?): String? {
        val actualProvider = provider ?: return null
        val actualModel = model ?: return null
        if (actualProvider.kind == ProviderKind.Relay) return null
        return metadata.resolveCatalogModel(actualModel.id, actualProvider.kind)
            ?.transport
            ?.takeIf { it.isNotBlank() }
    }

    /** The UI renders exact runtime controls only; there is no evidence/profile/model-id fallback. */
    fun modelControls(provider: Provider?, model: AIModel?, finalTransport: String?): ModelControls {
        val actualProvider = provider ?: return ModelControls()
        val actualModel = model ?: return ModelControls()
        val controls = finalTransport?.let {
            metadata.capabilityControlPresentation(actualProvider.kind, actualModel.id, it)
        }.orEmpty()
        // Web and reasoning go through one resolution: only an exact reviewed recipe makes a
        // capability available. Unknown, or a missing recipe, always means no automatic
        // configuration.
        val webVerdict = CapabilityControlResolution
            .resolve(actualProvider, actualModel, "web", metadata, finalTransport)
        val reasoningVerdict = CapabilityControlResolution
            .resolve(actualProvider, actualModel, "reasoning", metadata, finalTransport)
        val web = controls["web"]
        val generation = controls["generation"]
        return ModelControls(
            webAvailable = webVerdict.isAvailable,
            // "Search every time" has to come from an exact recipe as well.
            webForceAvailable = web?.automaticAvailable == true && "force" in web.availableIntents,
            reasoningIntents = reasoningVerdict.intents.takeIf { reasoningVerdict.isAvailable }.orEmpty(),
            generationAvailable = generation?.automaticAvailable == true,
            webState = webVerdict.state,
            reasoningState = reasoningVerdict.state,
            generationState = generation?.state ?: "unknown",
            webReasonCode = webVerdict.reasonCode,
            reasoningReasonCode = reasoningVerdict.reasonCode,
            generationReasonCode = generation?.reasonCode ?: generation?.reason,
        )
    }

    /**
     * The candidate catalog behind the model-controls sheet's primary action.
     *
     * Candidates come from the enabled models only (`provider.models`). Offering the whole catalog
     * via `provider.allModels` is a dead end: a catalog model has to be enabled on the connection
     * before it can be selected, so the user taps "switch" and nothing happens. A relay catalog
     * always reports custom_only, so it never produces candidates here anyway.
     */
    fun supportedModelCandidates(provider: Provider, capability: String): List<AIModel> =
        CapabilityControlActionCandidates.supportingModels(
            capability = capability,
            models = provider.models,
        ) { candidate ->
            val lookup = metadata.capabilityActionLookup(provider.kind, candidate.id, capability)
            CapabilityControlActionCandidates.ModelCapabilityLookup(
                state = lookup?.state,
                recipeTransport = lookup?.recipeTransport,
                modelTransport = lookup?.modelTransport,
            )
        }

    /**
     * auto / no configuration does not count as an incomplete identity (agreed across all three platforms): the connection
     * identity is taken from the first-send protocol (read the same way as the chat's first send).
     */
    private fun relayIdentity(
        provider: Provider,
        model: AIModel,
        localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity?,
    ): CapabilityEvidenceFacade.QueryIdentity? {
        localIdentity ?: return null
        return CapabilityEvidenceProductionAdapter.uiDispatchIdentity(provider, model, localIdentity)
            ?: CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider,
                model.copy(relayTransport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model)),
                localIdentity,
            )
    }

    /**
     * Inline text is the client injecting text into the prompt, which every form can take: a Relay reads its envelope and,
     * with no envelope (Auto protocol), counts as attachable; subscription and official connections read the provider
     * envelope's text bit, and file_input only governs native files.
     */
    private fun textFileInline(
        provider: Provider,
        relay: Boolean,
        envelope: ai.oriveo.community.core.model.AttachmentSupportInfo?,
    ): Boolean = when {
        relay -> envelope?.textFileInline ?: true
        else -> MessageBuilder.providerAttachmentEnvelope(provider.kind).textFileInline
    }

    private fun relayRuntimeAttachmentSupport(provider: Provider?, model: AIModel?) =
        provider
            ?.takeIf { it.kind == ProviderKind.Relay }
            ?.let {
                RelayRuntimeSupport.attachmentSupport( // capability-lint-allow R1: the Relay envelope is only passed as a parameter to resolveInputCapabilityProjections
                    provider = it,
                    runtimeConfig = runtimeConfigProvider(),
                    model = model,
                )
            }

    /** Core presentation owns all governed capability key mappings. */
    private fun hasGovernedMetadataCapability(
        provider: Provider?,
        model: AIModel?,
        capability: ModelCapability,
        identity: ai.oriveo.community.core.provider.CapabilityEvidenceFacade.QueryIdentity? = null,
    ): Boolean {
        val actualProvider = provider ?: return false
        val actualModel = model ?: return false
        return capability in CapabilityEvidenceProductionAdapter.governedMetadataCapabilities(
            provider = actualProvider,
            model = actualModel,
            identity = identity,
            metadataClient = metadata,
        )
    }
}
