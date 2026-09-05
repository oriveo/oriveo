package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.model.GenerationParameterProfileFingerprint
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal class ChatSendCommandCoordinator(
    private val viewModelScope: CoroutineScope,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val providerRepository: ProviderRepository,
    private val conversationRepository: ConversationRepository,
    private val currentConversation: () -> Conversation?,
    private val currentConversationId: () -> String?,
    private val onProviderSelectionError: () -> Unit,
    private val onProviderResolutionError: (Throwable) -> Unit,
    private val onModelSelectionError: () -> Unit,
    private val onDisclosureRequired: (ProviderDisclosurePrompt, PendingDisclosurePayload) -> Unit,
    private val onDisclosureConfirmationFailed: (Throwable) -> Unit = {},
    private val onConversationActivated: (String) -> Unit,
    private val generationParameterSettingsStore: GenerationParameterSettingsStore? = null,
    private val capabilityPreferenceStore: CapabilityPreferenceStore? = null,
    private val localCustomFragmentStore: LocalCapabilityCustomFragmentStore? = null,
    private val generationParameterDraftSessionId: () -> String = { "" },
    private val onComposerConsumed: suspend (String) -> Unit,
    private val onQuoteConsumed: (QuoteContext?) -> Unit = {},
    private val requestPin: () -> Unit,
    /**
     * Called when the setup phase of one send finishes, whether it handed the request to the
     * streaming scope, bailed out early, or threw. The ViewModel uses it to release the in-flight
     * send guard, so every return and throw path has to pass through it: miss one and the guard is
     * never released and the send button stays dead for the rest of the session.
     */
    private val onSendSettled: () -> Unit,
    private val launchSend: ChatSendLauncher,
) {
    fun sendMessage(
        text: String,
        attachments: List<Attachment>?,
        providerId: String?,
        modelId: String?,
        quoteContext: QuoteContext? = null,
    ) {
        if (providerId == null) {
            onProviderSelectionError()
            onSendSettled()
            return
        }
        if (modelId == null) {
            onModelSelectionError()
            onSendSettled()
            return
        }

        viewModelScope.launch {
            try {
                val provider = resolveChatProvider(
                    providerRepository = providerRepository,
                    providerId = providerId,
                    onMissing = onProviderSelectionError,
                    onFailure = onProviderResolutionError,
                ) ?: return@launch

                if (requiresDisclosure(provider.kind)) {
                    onDisclosureRequired(
                        ProviderDisclosurePrompt(
                            kind = provider.kind,
                            displayName = provider.kind.displayName,
                            privacyPolicyUrl = provider.kind.privacyPolicyUrl,
                        ),
                        PendingDisclosurePayload(
                            providerId = providerId,
                            modelId = modelId,
                            text = text,
                            attachments = attachments,
                            quoteContext = quoteContext,
                        ),
                    )
                    return@launch
                }

                sendMessageInternal(provider, modelId, text, attachments, quoteContext)
            } finally {
                // Catch-all reset: a missing provider or model, a disclosure gate, a thrown
                // exception and coroutine cancellation all land here. On the success path
                // launchSend has already handed the request to the streaming scope by now, so the
                // setup phase is over either way.
                onSendSettled()
            }
        }
    }

    fun confirmProviderDisclosure(
        prompt: ProviderDisclosurePrompt?,
        payload: PendingDisclosurePayload?,
        clearPrompt: () -> Unit,
    ) {
        if (prompt == null) {
            onSendSettled()
            return
        }
        viewModelScope.launch {
            try {
                runCatching {
                    appPreferencesRepository.markProviderDisclosureAccepted(prompt.kind)
                }.onFailure { error ->
                    onDisclosureConfirmationFailed(error)
                    return@launch
                }.getOrThrow()
                clearPrompt()
                if (payload != null) {
                    val provider = resolveChatProvider(
                        providerRepository = providerRepository,
                        providerId = payload.providerId,
                        onMissing = onProviderSelectionError,
                        onFailure = onProviderResolutionError,
                    ) ?: return@launch
                    sendMessageInternal(
                        provider = provider,
                        modelId = payload.modelId,
                        text = payload.text,
                        attachments = payload.attachments,
                        quoteContext = payload.quoteContext,
                    )
                }
            } finally {
                // Confirming re-enters the same send path, so it needs the same catch-all reset.
                onSendSettled()
            }
        }
    }

    private suspend fun requiresDisclosure(kind: ProviderKind): Boolean =
        !appPreferencesRepository.hasAcceptedProviderDisclosure(kind)

    private suspend fun sendMessageInternal(
        provider: Provider,
        modelId: String,
        text: String,
        attachments: List<Attachment>?,
        quoteContext: QuoteContext?,
    ) {
        val providerId = provider.id
        val selectedModel = ProviderSelectionSnapshot.currentModel(provider, modelId)
            ?: run {
                onModelSelectionError()
                return
            }

        val runtimeModelId = selectedModel.id
        val storedModelId = ModelSelectionUtils.preferredStoredModelIdentifier(selectedModel)

        val isNewConversation = currentConversationId() == null
        val conv = if (!isNewConversation) {
            currentConversation()
        } else {
            null
        } ?: conversationRepository.create(
            providerID = providerId,
            providerKind = provider.kind,
            modelID = storedModelId,
        )

        if (isNewConversation) {
            val modelControlIdentity = ModelControlRuntimeIdentityResolver.resolve(provider, selectedModel)
            generationParameterSettingsStore?.migrateSession(
                providerID = provider.id,
                modelID = runtimeModelId,
                fromConversationID = generationParameterDraftSessionId(),
                toConversationID = conv.id,
                profileFingerprint = GenerationParameterProfileFingerprint.make(provider, selectedModel),
            )
            modelControlIdentity?.let { identity ->
                capabilityPreferenceStore?.migrateDraftConversation(
                    providerID = provider.id,
                    modelID = identity.canonicalModelId,
                    draftSessionID = generationParameterDraftSessionId(),
                    conversationID = conv.id,
                    transportIdentity = identity.storageIdentity,
                )
                localCustomFragmentStore?.migrateConversation(
                    providerID = provider.id,
                    modelID = identity.canonicalModelId,
                    fromConversationID = generationParameterDraftSessionId(),
                    toConversationID = conv.id,
                    transportIdentity = identity.storageIdentity,
                )
            }
        }

        onConversationActivated(conv.id)
        appPreferencesRepository.setLastUsedModel(providerId, selectedModel)
        if (conv.providerID != providerId || conv.modelID != storedModelId) {
            conversationRepository.updateProviderAndModel(
                id = conv.id,
                providerId = providerId,
                providerKind = provider.kind,
                modelId = storedModelId,
                relayKind = provider.relayKind,
            )
        }

        val requestConversation = conv.copy(
            providerID = providerId,
            providerKind = provider.kind,
            modelID = storedModelId,
        )

        onComposerConsumed(conv.id)
        requestPin()

        val fullHistory = fetchFullConversationHistory(conv.id)
        launchSend.launch(
            conversation = requestConversation,
            provider = provider,
            modelId = runtimeModelId,
            text = text,
            existingMessages = fullHistory,
            attachments = attachments,
            quoteContext = quoteContext,
            persistUserMessage = true,
            appendToAssistant = null,
            userMessageAlreadyInHistory = false,
        )
        // The quote is only consumed once the request has actually been handed off. Any earlier
        // setup failure leaves it pending so the user does not lose the selection.
        onQuoteConsumed(quoteContext)
    }

    private suspend fun fetchFullConversationHistory(conversationId: String): List<ChatMessage> =
        conversationRepository.getWithMessages(conversationId)?.messages.orEmpty()
}
