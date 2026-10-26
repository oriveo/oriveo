package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.ModelRetirement
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.RelayModelFallback
import java.time.Instant

@Immutable
data class ActiveModelSelection(
    val provider: Provider,
    val model: AIModel,
    /** Non-null when the preferred (last-used) model for a new chat was retired or unavailable and [model] was used instead; callers show a one-time notice per device. */
    val hint: ModelRetirement.NewChatHint? = null,
    /** When [hint] is non-null, the original last-used model id that was replaced (the key of the one-time notice; not the alias-resolved id). */
    val replacedModelId: String? = null,
    /** When [hint] is non-null, the id of the connection the last-used model belonged to (the key of the one-time notice; not the fallback connection). */
    val replacedProviderId: String? = null,
)

/**
 * Resolves the model for a new chat; every new-chat entry point calls it.
 * Order: last used (on any connection, as long as it is available and enabled) > the primary connection's catalog default > its first available model >
 * the next connection that has an available model ... > null when there is none (a chat is never opened with an empty id, nor is a last-used ref written).
 * Available = in the catalog and not retired (a model missing from the catalog is unavailable, except while the bundled snapshot is active).
 * Connection order: unavailable connections (meaning only a missing credential, see [isMissingCredentialForNewChat]) are dropped before every tier,
 * including the last-used tier (a last-used model on a connection missing its credential is neither adopted nor announced); a connection in an error state is kept in its list position;
 * the connection of the last-used model is tried first and the rest follow list order; without a last-used model the first available connection in the list is tried first;
 * entries scoped to one connection (the detail page) do not come through here and never cross connections.
 */
fun resolveActiveModel(
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
    metadata: MetadataClient = MetadataClient.instance,
    now: Instant = Instant.now(),
): ActiveModelSelection? = resolveNewChat(providers, lastUsedModelRef, metadata, now).selection

/** Full result of [resolveActiveModel]: when nothing is available [selection] is null and [hint] still says the last-used model was retired. */
internal data class NewChatResolution(
    val selection: ActiveModelSelection?,
    val hint: ModelRetirement.NewChatHint?,
)

internal fun resolveNewChat(
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
    metadata: MetadataClient = MetadataClient.instance,
    now: Instant = Instant.now(),
): NewChatResolution {
    // Connections missing a credential are dropped before every tier: the last-used tier also searches only the remaining list.
    val candidates = providers.filterNot { it.isMissingCredentialForNewChat() }
    if (candidates.isEmpty()) return NewChatResolution(null, null)

    // The last-used connection was judged to have no usable model: skip it when crossing connections and carry "last used was retired" onto the selected result.
    var exhaustedProviderId: String? = null
    var carriedHint: ModelRetirement.NewChatHint? = null
    var replacedModelId: String? = null
    var replacedProviderId: String? = null
    if (lastUsedModelRef != null) {
        val provider = candidates.firstOrNull { it.id == lastUsedModelRef.providerID }
        if (provider != null) {
            val storedModel = ModelSelectionUtils.resolveStoredModel(provider.models, lastUsedModelRef.modelID, provider.kind)
            val userModels = provider.models.map { it.id }
            // Judge by the stored id when it is enabled as-is; otherwise use the enabled model its alias resolves to.
            val preferredId = lastUsedModelRef.modelID.takeIf { it in userModels } ?: storedModel?.id ?: lastUsedModelRef.modelID
            when (val judged = newChatChoiceOf(provider, preferredId, metadata, now, lastUsedModelRef.modelID)) {
                NewChatJudgement.NotJudged -> {
                    val model = storedModel ?: fallbackModelOf(provider, metadata)
                    if (model != null) return NewChatResolution(ActiveModelSelection(provider, model), null)
                }
                is NewChatJudgement.NoUsable -> {
                    exhaustedProviderId = provider.id
                    carriedHint = judged.hint
                    replacedModelId = lastUsedModelRef.modelID.takeIf { judged.hint != null }
                    replacedProviderId = provider.id.takeIf { judged.hint != null }
                }
                is NewChatJudgement.Chosen -> {
                    val selection = judged.selection
                    return NewChatResolution(
                        if (selection.hint != null) {
                            selection.copy(replacedModelId = lastUsedModelRef.modelID, replacedProviderId = provider.id)
                        } else {
                            selection
                        },
                        selection.hint,
                    )
                }
            }
        }
    }

    val ordered = candidates
        .sortedByDescending { it.id == lastUsedModelRef?.providerID }
    for (candidate in ordered) {
        if (candidate.id == exhaustedProviderId) continue
        // Once the catalog is loaded this uses the same judgement as the preferred tier (catalog default > first available); connections that are not judged (relays, or catalog not loaded) fall back.
        val selection = when (val judged = newChatChoiceOf(candidate, preferredModelId = null, metadata, now)) {
            NewChatJudgement.NotJudged -> fallbackModelOf(candidate, metadata)?.let { ActiveModelSelection(candidate, it) }
            is NewChatJudgement.NoUsable -> null
            is NewChatJudgement.Chosen -> judged.selection
        } ?: continue
        if (carriedHint == null) return NewChatResolution(selection, null)
        return NewChatResolution(
            selection.copy(hint = carriedHint, replacedModelId = replacedModelId, replacedProviderId = replacedProviderId),
            carriedHint,
        )
    }
    return NewChatResolution(null, carriedHint)
}

/**
 * Model choice when a chat starts from a skill: the skill's suggested model > a capability match (the last-used connection first) > [resolveActiveModel];
 * the first two tiers take only enabled, available models (retired or missing-from-catalog ones are not picked).
 * Connections missing a credential and connections with no enabled model do not take part.
 */
fun resolveSkillModel(
    skill: Skill,
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
    metadata: MetadataClient = MetadataClient.instance,
    now: Instant = Instant.now(),
): ActiveModelSelection? {
    val providerList = providers.filter { !it.isMissingCredentialForNewChat() && it.models.isNotEmpty() }
    if (providerList.isEmpty()) return null
    fun usable(provider: Provider, model: AIModel): Boolean =
        ProviderSelectionSnapshot.newChatUsable(provider, model.id, metadata, now)

    val suggestedProviderId = skill.suggestedProviderId
    val suggestedModelId = skill.suggestedModelId
    if (suggestedModelId != null && suggestedProviderId != null) {
        val suggestedProvider = providerList.firstOrNull {
            it.id == suggestedProviderId || it.kind.rawValue == suggestedProviderId
        }
        val suggestedModel = suggestedProvider?.let { provider ->
            ModelSelectionUtils.matchingModel(provider.models, suggestedModelId, provider.kind)
                ?.takeIf { usable(provider, it) }
        }
        if (suggestedProvider != null && suggestedModel != null) {
            return ActiveModelSelection(suggestedProvider, suggestedModel)
        }
    }

    if (skill.modelCapabilityHint != "any") {
        val activeProviderId = resolveActiveModel(providers, lastUsedModelRef, metadata, now)?.provider?.id
        for (provider in providerList.sortedByDescending { it.id == activeProviderId }) {
            val model = provider.models.firstOrNull {
                matchesCapabilityHint(provider, it, skill.modelCapabilityHint) && usable(provider, it)
            }
            if (model != null) return ActiveModelSelection(provider, model)
        }
    }

    return resolveActiveModel(providerList, lastUsedModelRef, metadata, now)
}

/**
 * The single criterion for an "unavailable connection" in a new chat: it means only a missing credential, a missing key on an official provider or relay, or a signed-out subscription.
 * Either source is enough: this device has no stored credential ([effectiveStatusKind] = NeedsKey, covering a backup restore awaiting setup, a migration that lost the key,
 * or a relay whose key was deleted; a subscription sign-in's access token is also kept in the apiKey slot and is judged as the credential itself);
 * or the typed reason of an Issue is a missing credential.
 * Error states (failed validation, rate limits, upstream errors and so on) do not count and the connection takes part as usual.
 * The home screen, skills and the detail page share it through the new-chat resolver.
 */
fun Provider.isMissingCredentialForNewChat(): Boolean =
    effectiveStatusKind == ProviderEffectiveStatusKind.NeedsKey ||
        (status as? ProviderConnectionState.Issue)?.reason?.isMissingCredential == true

private fun matchesCapabilityHint(provider: Provider, model: AIModel, hint: String): Boolean = when (hint) {
    "reasoning" -> CapabilityEvidenceProductionAdapter.supportedReasoningModes(provider, model).isNotEmpty()
    "vision" -> ModelCapability.Image in
        CapabilityEvidenceProductionAdapter.governedMetadataCapabilities(provider, model)
    "fast" -> model.priceTier == "$" ||
        model.name.contains("mini", ignoreCase = true) ||
        model.name.contains("haiku", ignoreCase = true) ||
        model.name.contains("flash", ignoreCase = true)
    "large-context" -> (model.contextLength ?: 0) >= 128_000
    else -> false
}

private sealed interface NewChatJudgement {
    /** Relays, subscription sign-ins, or a catalog that is not loaded: not judged, the original resolution applies. */
    data object NotJudged : NewChatJudgement
    /** Judged, but no available model among the enabled ones; a non-null [hint] means the preferred model was retired. */
    data class NoUsable(val hint: ModelRetirement.NewChatHint?) : NewChatJudgement
    data class Chosen(val selection: ActiveModelSelection) : NewChatJudgement
}

/**
 * New-chat model judgement: applies only to official BYOK providers; the catalog is obtained and the snapshot state handled as in
 * [ai.oriveo.community.core.provider.ProviderSelectionSnapshot.modelRetirement].
 */
private fun newChatChoiceOf(
    provider: Provider,
    preferredModelId: String?,
    metadata: MetadataClient,
    now: Instant,
    /** The raw id stored as last used ([preferredModelId] may be the enabled model its alias resolved to); used by the notice criterion. */
    rawPreferredModelId: String? = null,
): NewChatJudgement {
    if (provider.kind == ProviderKind.Relay) return NewChatJudgement.NotJudged
    if (provider.authMode == ProviderAuthMode.Subscription) return NewChatJudgement.NotJudged
    val catalog = metadata.retirementCatalog(provider.kind) ?: return NewChatJudgement.NotJudged
    val userModels = provider.models.map { it.id }
    val choice = ModelRetirement.newChatModel(
        catalog = catalog,
        userModels = userModels,
        preferredModelId = preferredModelId,
        now = now,
        bundled = metadata.isBundledSnapshotActive,
        canonicalIds = provider.models.mapNotNull { model ->
            model.canonicalModelId?.takeIf { it.isNotBlank() }?.let { model.id to it }
        }.toMap(),
    )
    // Notice criterion: show it when the raw id is retired or missing in the catalog, whether or not it is still enabled and whether or not an alias resolved it to another enabled model.
    val hint = choice.hint ?: rawPreferredModelId
        ?.takeIf { it != preferredModelId && it !in userModels }
        ?.takeIf { raw ->
            !ModelRetirement.isNewChatUsable(
                catalog = catalog,
                userModels = userModels + raw,
                modelId = raw,
                now = now,
                bundled = metadata.isBundledSnapshotActive,
                canonicalId = preferredModelId?.let { id -> canonicalIdOf(provider, id) ?: id },
            )
        }
        ?.let { ModelRetirement.NewChatHint.LastUsedRetired }
    val chosen = provider.models.firstOrNull { it.id == choice.modelId } ?: return NewChatJudgement.NoUsable(hint)
    return NewChatJudgement.Chosen(ActiveModelSelection(provider, chosen, hint = hint))
}

private fun canonicalIdOf(provider: Provider, modelId: String): String? =
    provider.models.firstOrNull { it.id == modelId }?.canonicalModelId?.takeIf { it.isNotBlank() }

/** Relays fall back only to enabled models, never to un-enabled catalog models; everything else uses the new-chat fallback (catalog default > first enabled, never the connection's isDefault). */
private fun fallbackModelOf(provider: Provider, metadata: MetadataClient): AIModel? =
    if (RelayModelFallback.appliesTo(provider)) {
        RelayModelFallback.fallbackModel(provider, lastUsedModelRef = null)
    } else {
        ProviderSelectionSnapshot.newChatFallbackModel(provider, metadata)
    }

/** Provider issue info, shown in the Hero section. */
@Immutable
data class ProviderIssueInfo(
    val providerID: String,
    val providerName: String,
    val message: String,
)

/**
 * Resolves the provider issue to show.
 *
 * It first takes the issue from the active model's provider; when no active model can be resolved,
 * it looks back at the provider [lastUsedModelRef] points to (the missing-key case after a restore).
 */
fun resolveProviderIssue(
    providers: List<Provider>,
    lastUsedModelRef: LastUsedModelRef?,
): ProviderIssueInfo? {
    val activeModel = resolveActiveModel(providers, lastUsedModelRef)
    if (activeModel != null) {
        val status = activeModel.provider.status
        return if (status is ProviderConnectionState.Issue) {
            ProviderIssueInfo(activeModel.provider.id, activeModel.provider.displayName, status.message)
        } else null
    }
    // Look back: when no active model can be resolved, check the provider lastUsedModelRef points to.
    if (lastUsedModelRef != null) {
        val provider = providers.firstOrNull { it.id == lastUsedModelRef.providerID }
        if (provider != null) {
            val status = provider.status
            if (status is ProviderConnectionState.Issue) {
                return ProviderIssueInfo(provider.id, provider.displayName, status.message)
            }
        }
    }
    // Fallback: when lastUsedModelRef is also empty (first sync on a new device), take the first provider that has an issue.
    val fallback = providers.firstOrNull { it.status is ProviderConnectionState.Issue }
    if (fallback != null) {
        val status = fallback.status as ProviderConnectionState.Issue
        return ProviderIssueInfo(fallback.id, fallback.displayName, status.message)
    }
    return null
}
