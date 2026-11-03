package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.realtime.RealtimePendingSelection
import ai.oriveo.community.core.voice.realtime.RealtimeSelection
import ai.oriveo.community.feature.modelpicker.enableCatalogModelWithFeedback
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal class ChatModelSelectionCoordinator(
    private val viewModelScope: CoroutineScope,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val providerRepository: ProviderRepository,
    private val conversationRepository: ConversationRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val providers: () -> List<Provider>,
    private val activeProviderId: () -> String?,
    private val activeModelId: () -> String?,
    private val activeConversationId: () -> String?,
    private val onProviderResolutionError: (Throwable) -> Unit = {},
    /** Snapshot of the voice catalog cache (synchronous read); null = realtime models are not recognized. */
    private val voiceCatalog: () -> VoiceCatalog? = { null },
) {
    /** Selection stashed while the catalog is not ready: once the catalog arrives, [resolvePendingSelection] decides whether to write last-used. */
    private val pendingSelection = RealtimePendingSelection()

    /** Original selection to restore when a stashed item turns out unrecognized: recorded and cleared together with the stash. */
    private class RestoreTarget(
        val providerId: String,
        val modelId: String,
        val onSelectionChanged: (String, String) -> Unit,
    )

    private var pendingRestore: RestoreTarget? = null

    fun selectModel(
        providerId: String,
        modelId: String,
        onSelectionChanged: (String, String) -> Unit,
    ) {
        val previousProviderId = activeProviderId()
        val previousModelId = activeModelId()
        val previousProviderKind = previousProviderId
            ?.let { id -> providers().firstOrNull { it.id == id }?.kind }
        val newProviderKind = providers().firstOrNull { it.id == providerId }?.kind
        // Realtime models write only the conversation, not last-used: new chats still fall back to a text model.
        val catalog = voiceCatalog()
        val isRealtime = RealtimeSelection.isRealtime(providers().firstOrNull { it.id == providerId }, modelId, catalog)
        // While the catalog is not ready we cannot tell whether a model is realtime: stash it without writing last-used, and decide once the catalog arrives.
        val deferLastUsed = catalog == null
        if (deferLastUsed) pendingSelection.stash(providerId, modelId) else pendingSelection.clear()
        if (!deferLastUsed) {
            pendingRestore = null
        } else if (pendingRestore == null && previousProviderId != null && previousModelId != null) {
            // Consecutive stashes keep the earliest original selection: restore to the one the user was actually using before the catalog was ready.
            pendingRestore = RestoreTarget(previousProviderId, previousModelId, onSelectionChanged)
        }

        onSelectionChanged(providerId, modelId)
        // Synchronously warm the override so the empty-conversation combine collector and home send read the new selection immediately,
        // rather than being overwritten back to the old model by the async lastUsedModelRef (fixes "the selection only takes effect on the second pick").
        if (!isRealtime && !deferLastUsed) appPreferencesRepository.primeLastUsedModel(providerId, modelId)

        if (previousModelId != null && (previousModelId != modelId || previousProviderId != providerId)) {
        }

        viewModelScope.launch {
            val provider = resolveChatProvider(
                providerRepository = providerRepository,
                providerId = providerId,
                onFailure = onProviderResolutionError,
            ) ?: return@launch
            val realtimeEntry = RealtimeSelection.realtimeEntry(provider, modelId, catalog)
            val selectedModel = if (realtimeEntry != null) null else ProviderSelectionSnapshot.selectedModel(provider, modelId)
            val storedModelId = realtimeEntry?.model
                ?: selectedModel?.let { ModelSelectionUtils.preferredStoredModelIdentifier(it, provider.kind) }
                ?: ModelSelectionUtils.resolvedId(modelId)

            when {
                realtimeEntry != null || deferLastUsed -> Unit
                selectedModel != null -> appPreferencesRepository.setLastUsedModel(providerId, selectedModel, provider.kind)
                else -> appPreferencesRepository.setLastUsedModel(providerId, storedModelId)
            }

            activeConversationId()?.let { convId ->
                conversationRepository.updateProviderAndModel(
                    id = convId,
                    providerId = providerId,
                    providerKind = provider.kind,
                    modelId = storedModelId,
                    relayKind = provider.relayKind,
                )
            }
        }
    }

    /**
     * When the catalog arrives (content changed) the stashed selection is consumed: a realtime model stays in this session only (the selection is already it; the caller recomputes session state),
     * a model present in the connected text list is warmed and written to last-used as usual; if neither side recognizes it, the hint is unavailable and the original selection is restored.
     * Does nothing while the catalog is still not ready or when there is no stashed item.
     */
    fun resolvePendingSelection(catalog: VoiceCatalog?, providers: List<Provider>) {
        val resolution = pendingSelection.resolve(catalog, providers) ?: return
        val restore = pendingRestore
        pendingRestore = null
        when (resolution) {
            is RealtimePendingSelection.Resolution.Text -> writePendingLastUsed(resolution.pending)
            is RealtimePendingSelection.Resolution.Gone -> rejectPendingSelection(resolution.pending, restore, providers)
            is RealtimePendingSelection.Resolution.Realtime -> Unit
        }
    }

    /** Unrecognized stashed item: the hint is unavailable, last-used is not written, and the selection and session model are restored to the original selection. */
    private fun rejectPendingSelection(
        pending: RealtimePendingSelection.Pending,
        restore: RestoreTarget?,
        providers: List<Provider>,
    ) {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(R.string.voice_realtime_failure_model_gone, listOf(pending.modelId)),
                style = GlobalToastStyle.Warning,
            ),
        )
        if (restore == null) return
        if (activeProviderId() != pending.providerId || activeModelId() != pending.modelId) return
        restore.onSelectionChanged(restore.providerId, restore.modelId)
        val provider = providers.firstOrNull { it.id == restore.providerId } ?: return
        val convId = activeConversationId() ?: return
        viewModelScope.launch {
            conversationRepository.updateProviderAndModel(
                id = convId,
                providerId = restore.providerId,
                providerKind = provider.kind,
                modelId = restore.modelId,
                relayKind = provider.relayKind,
            )
        }
    }

    private fun writePendingLastUsed(pending: RealtimePendingSelection.Pending) {
        val (providerId, modelId) = pending
        appPreferencesRepository.primeLastUsedModel(providerId, modelId)
        viewModelScope.launch {
            val provider = resolveChatProvider(
                providerRepository = providerRepository,
                providerId = providerId,
                onFailure = onProviderResolutionError,
            ) ?: return@launch
            val selectedModel = ProviderSelectionSnapshot.selectedModel(provider, modelId)
            if (selectedModel != null) {
                appPreferencesRepository.setLastUsedModel(providerId, selectedModel, provider.kind)
            } else {
                appPreferencesRepository.setLastUsedModel(providerId, ModelSelectionUtils.resolvedId(modelId))
            }
        }
    }

    fun enableModel(providerId: String, modelId: String) {
        viewModelScope.launch {
            enableCatalogModelWithFeedback(providerRepository, globalSnackbarManager, providerId, modelId)
        }
    }
}
