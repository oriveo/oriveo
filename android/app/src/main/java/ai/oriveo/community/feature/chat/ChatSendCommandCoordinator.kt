package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.context.MemoryProposeMode
import ai.oriveo.community.core.context.MemoryProposePurpose
import ai.oriveo.community.core.memory.MemoryProposeSendHook
import ai.oriveo.community.core.memory.ProposeMemoryRuntime
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.AttachmentSendPreflight
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.RelayModelFallback
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
    /** Instructions written by the conversation settings while still a draft; stored with the object when the first send creates the conversation. */
    private val pendingDraftInstructions: () -> String = { "" },
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
    /**
     * When a new conversation becomes a real one, moves the MCP server switches flipped while it
     * was a draft over to it. Must complete before the send.
     */
    private val adoptMcpDraft: suspend (conversationId: String) -> Unit = {},
    /** Called when the pre-send check finds this turn's attachments cannot be delivered; no conversation has been created and the composer is untouched. */
    private val onAttachmentsUndeliverable: (ProviderServiceError) -> Unit = {},
    /**
     * The web search and reasoning values this send will actually use outbound, and whether the tool loop may take
     * over. Returns null when unknown, and the pre-send check falls back to blocking only if every possible route
     * fails.
     */
    private val resolveAttachmentSendOptions: (
        provider: Provider,
        modelId: String,
    ) -> AttachmentSendPreflight.SendOptions? = { _, _ -> null },
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
    /**
     * Outbound history: messages produced by the same trimming chain as ChatRepository sending ([ai.oriveo.community.core.data.repository.OutboundHistory]).
     * Preflight uses it to detect video; the default returns it unchanged, and in production the ViewModel injects the real trimming.
     */
    private val outboundHistory: suspend (List<ChatMessage>) -> List<ChatMessage> = { it },
    /** Whether this send from the input box is a plain send or a resend after editing (set after the edit entry refills the input box, reset once sent). */
    private val attemptKind: () -> ai.oriveo.community.feature.chat.ContextConfirmAttempt = {
        ai.oriveo.community.feature.chat.ContextConfirmAttempt.SEND
    },
    /** Judges freshly sent user messages for the "set as instruction" suggestion; null = off. */
    private val directiveSuggestions: DirectiveSuggestionController? = null,
    /** New-message send that reports the persisted user message back; null falls back to [launchSend]. */
    private val launchUserSend: ChatUserSendLauncher? = null,
    /** Turns a fresh user send into a pending memory candidate; null = off. */
    private val memoryCandidates: MemoryCandidateRepository? = null,
    /** Partition the candidate is written to. */
    private val memoryAccountId: () -> String = { "" },
    /** App-level scope for candidate generation, so leaving the chat page does not cancel it. */
    private val memoryScope: CoroutineScope = viewModelScope,
    /** "Save to memory?" bar fed by the generated candidate; null = off. */
    private val memorySuggestions: MemorySuggestionController? = null,
    /**
     * propose_memory mode of a fresh send. Fallback keeps the v1 routing; tool skips it (the model
     * proposes through the tool instead). Null = the real decision ([resolveMemoryProposeMode]).
     */
    private val memoryProposeMode: (suspend (Conversation, Provider, modelId: String) -> MemoryProposeMode)? = null,
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
                // The relay session's model has been removed: no request is sent, and the notice bar guides the user to pick again.
                if (RelayModelFallback.removedConnectionName(provider, modelId) != null) return@launch

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

    /** Background, best-effort: a failure is only logged and never affects the send. */
    /**
     * For a fresh send: memory on for the chat, auto-suggest on for the account, client tools can ride
     * this send (MCP tool predicate, not Moonshot's built-in web search loop) and the pair is not degraded.
     */
    @Suppress("LongParameterList")
    private suspend fun resolveMemoryProposeMode(
        accountId: String,
        conv: Conversation,
        provider: Provider,
        modelId: String,
    ): MemoryProposeMode {
        val repository = memoryCandidates ?: return MemoryProposeMode.FALLBACK
        val model = ProviderSelectionSnapshot.selectedModel(provider, modelId)
        // Unknown web state counts as on: Moonshot's built-in loop then owns the tool list, and Gemini
        // generateContent cannot carry function tools beside its search tool.
        // Relay: web is what actually goes out (chat switch and no user override off), same as ChatRepository.
        val webSearch = model != null &&
            resolveAttachmentSendOptions(provider, modelId)
                ?.webSearchEnabled
                ?.let { on ->
                    if (provider.kind == ProviderKind.Relay) {
                        ai.oriveo.community.core.provider.relay.RelayWebChat.switchOn(provider, model, on)
                    } else {
                        on
                    }
                } ?: true
        val supportsTools = model != null && run {
            ProposeMemoryRuntime.connectionSupportsTools(
                provider = provider,
                model = model,
                memoryVerdict = providerRepository.toolCallMemoryVerdict(provider, model),
                localIdentity = providerRepository.capabilityEvidenceIdentity(provider, modelId),
                moonshotBuiltinSearch = provider.kind == ProviderKind.Moonshot && webSearch,
            )
        }
        return ProposeMemoryRuntime.mode(
            purpose = MemoryProposePurpose.CHAT,
            freshSend = true,
            memoryEnabled = conv.useMemory,
            autoSuggest = repository.autoSuggestEnabled(accountId),
            connectionSupportsTools = supportsTools,
            connectionId = provider.id,
            modelId = modelId,
            geminiWebSearch = ProposeMemoryRuntime.geminiWebSearch(provider, model, webSearch),
            // json_schema on this send conflicts with tools; propose falls back like Gemini web search.
            structuredOutput = ProposeMemoryRuntime.structuredOutputActive(
                generationParameterSettingsStore, provider, model, modelId, conv.id,
            ),
        )
    }

    /** propose_memory callbacks of one fresh send in tool mode, bound to its user message. */
    private inner class ProposeTurn(
        private val accountId: String,
        private val conv: Conversation,
        private val connectionId: String,
        private val modelId: String,
    ) : MemoryProposeSendHook {
        @Volatile private var messageId: String? = null
        @Volatile private var userText: String = ""
        private val calls = java.util.concurrent.atomic.AtomicInteger(0)

        fun bind(messageId: String, text: String) {
            userText = text
            this.messageId = messageId
        }

        override suspend fun onProposeCall(argumentsJson: String) {
            val id = messageId ?: return
            val prior = calls.getAndIncrement()
            val repository = memoryCandidates ?: return
            val candidate = try {
                repository.propose(
                    accountId = accountId,
                    argumentsJson = argumentsJson,
                    priorInTurn = prior,
                    userText = userText,
                    messageId = id,
                    conversationId = conv.id,
                    folderId = conv.folderID,
                )
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("ChatSendCommand", "propose_memory candidate failed: ${e.message}")
                null
            } ?: return
            memorySuggestions?.onProposedCandidate(conv.id, id, candidate)
        }

        override suspend fun onToolsRejected() {
            ProposeMemoryRuntime.markDegraded(connectionId, modelId)
            val id = messageId ?: return
            generateMemoryCandidate(accountId, conv, id, userText, MemoryProposeMode.FALLBACK)
        }
    }

    private fun generateMemoryCandidate(
        accountId: String,
        conv: Conversation,
        messageId: String,
        text: String,
        mode: MemoryProposeMode,
    ) {
        val bars = memorySuggestions
        if (mode == MemoryProposeMode.TOOL) {
            // Tool mode implies memory on; only clear the previous bar, the v1 routing does not run.
            bars?.onUserMessageCreated(conv.id, messageId, text, useMemory = true)
            return
        }
        bars?.onUserMessageCreated(conv.id, messageId, text, useMemory = conv.useMemory)
        val repository = memoryCandidates ?: return
        memoryScope.launch {
            try {
                val candidate = repository.generate(
                    accountId = accountId,
                    text = text,
                    messageId = messageId,
                    conversationId = conv.id,
                    folderId = conv.folderID,
                    useMemory = conv.useMemory,
                    nowMs = System.currentTimeMillis(),
                )
                bars?.onCandidateGenerated(conv.id, messageId, candidate)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("ChatSendCommand", "memory candidate generation failed: ${e.message}")
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

        // This turn's attachments do not fit: do not create a conversation or clear the composer, and leave the text and
        // attachments for the user to adjust. The route is worked out from the web search and reasoning values this send
        // will actually use; when those are unknown, block only if every possible route fails.
        val sendOptions = if (attachments.isNullOrEmpty()) null else {
            resolveAttachmentSendOptions(provider, selectedModel.id)
                ?.let { options ->
                    // Preflight only deals with files; only when there are files does it detect video from the outbound history (same trimming chain as sending, including this turn).
                    if (attachments.none { it.kind == AttachmentKind.File }) options
                    else {
                        val history = currentConversationId()?.let { fetchFullConversationHistory(it) }.orEmpty()
                        val pending = ChatMessage(
                            id = "preflight-pending",
                            role = ChatRole.User,
                            text = text,
                            providerID = provider.id,
                            providerKind = provider.kind,
                            providerName = provider.displayName,
                            modelID = selectedModel.id,
                            modelName = selectedModel.name,
                            state = ChatMessageState.Delivered,
                            attachments = attachments,
                        )
                        options.copy(historyHasVideo = GeminiService.hasVideoAttachment(outboundHistory(history + pending)))
                    }
                }
        }
        AttachmentSendPreflight.undeliverable(provider, selectedModel, text, attachments, sendOptions)?.let { error ->
            onAttachmentsUndeliverable(error)
            return
        }

        val runtimeModelId = selectedModel.id
        val storedModelId = ModelSelectionUtils.preferredStoredModelIdentifier(selectedModel, provider.kind)

        val isNewConversation = currentConversationId() == null
        val conv = if (!isNewConversation) {
            currentConversation()
        } else {
            null
        } ?: conversationRepository.create(
            providerID = providerId,
            providerKind = provider.kind,
            modelID = storedModelId,
            instructions = pendingDraftInstructions(),
        )

        if (isNewConversation) {
            adoptMcpDraft(conv.id)
            val modelControlIdentity = ModelControlRuntimeIdentityResolver.resolve(provider, selectedModel)
            generationParameterSettingsStore?.migrateSession(
                providerID = provider.id,
                modelID = runtimeModelId,
                fromConversationID = generationParameterDraftSessionId(),
                toConversationID = conv.id,
                profileFingerprint = GenerationParameterProfileFingerprint.make(provider, selectedModel),
            )
            // The draft record of the relay web switch moves to the real conversation with the first send.
            ai.oriveo.community.core.provider.RelayWebPreferenceIdentity.resolve(provider, selectedModel)?.let { webIdentity ->
                capabilityPreferenceStore?.migrateDraftConversation(
                    providerID = provider.id,
                    modelID = webIdentity.canonicalModelId,
                    draftSessionID = generationParameterDraftSessionId(),
                    conversationID = conv.id,
                    transportIdentity = webIdentity.storageIdentity,
                )
            }
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
        appPreferencesRepository.setLastUsedModel(providerId, selectedModel, provider.kind)
        if (conv.providerID != providerId || conv.modelID != storedModelId) {
            conversationRepository.updateProviderAndModel(
                id = conv.id,
                providerId = providerId,
                providerKind = provider.kind,
                modelId = storedModelId,
                relayKind = provider.relayKind,
            )
        }
        if (RelayModelFallback.removedConnectionName(provider, modelId) != null) return

        val requestConversation = conv.copy(
            providerID = providerId,
            providerKind = provider.kind,
            modelID = storedModelId,
        )

        onComposerConsumed(conv.id)
        requestPin()

        val fullHistory = fetchFullConversationHistory(conv.id)
        val kind = attemptKind()
        val userSend = launchUserSend
        val suggestions = directiveSuggestions
        // Only a fresh user send is judged; edit-and-resend / retry / regenerate never are.
        val hasUserMessageHook = suggestions != null || memoryCandidates != null || memorySuggestions != null
        if (kind == ai.oriveo.community.feature.chat.ContextConfirmAttempt.SEND && userSend != null && hasUserMessageHook) {
            // Resolve the memory partition at send time; a later account switch must not redirect the candidate.
            val memoryAccount = memoryAccountId()
            val proposeMode = memoryProposeMode?.invoke(requestConversation, provider, runtimeModelId)
                ?: resolveMemoryProposeMode(
                    memoryAccount, requestConversation, provider, runtimeModelId,
                )
            val proposeTurn = if (proposeMode == MemoryProposeMode.TOOL) {
                ProposeTurn(memoryAccount, conv, provider.id, runtimeModelId)
            } else {
                null
            }
            userSend.launch(
                conversation = requestConversation,
                provider = provider,
                modelId = runtimeModelId,
                text = text,
                existingMessages = fullHistory,
                attachments = attachments,
                quoteContext = quoteContext,
                attemptKind = kind,
                onUserMessageCreated = { messageId, messageText ->
                    proposeTurn?.bind(messageId, messageText)
                    suggestions?.onUserMessageCreated(conv.id, messageId, messageText)
                    generateMemoryCandidate(memoryAccount, conv, messageId, messageText, proposeMode)
                },
                memoryPropose = proposeTurn,
            )
            onQuoteConsumed(quoteContext)
            return
        }
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
            attemptKind = kind,
        )
        // The quote is only consumed once the request has actually been handed off. Any earlier
        // setup failure leaves it pending so the user does not lose the selection.
        onQuoteConsumed(quoteContext)
    }

    private suspend fun fetchFullConversationHistory(conversationId: String): List<ChatMessage> =
        conversationRepository.getWithMessages(conversationId)?.messages.orEmpty()
}

/** Fresh user send: like [ChatSendLauncher] for a new message, plus the persisted user message callback. */
internal fun interface ChatUserSendLauncher {
    fun launch(
        conversation: Conversation,
        provider: Provider,
        modelId: String,
        text: String,
        existingMessages: List<ChatMessage>,
        attachments: List<Attachment>?,
        quoteContext: QuoteContext?,
        attemptKind: ai.oriveo.community.feature.chat.ContextConfirmAttempt,
        onUserMessageCreated: (messageId: String, text: String) -> Unit,
        /** Non-null when this fresh send runs in tool mode (the request carries propose_memory). */
        memoryPropose: MemoryProposeSendHook?,
    )
}

/** The notice shown when the pre-send check blocks a send. It uses the same discrimination and copy as the failure card: a count overrun says the maximum number of files, a text overrun names the files that do not fit, and when both apply each gets its own line. */
internal fun attachmentsUndeliverableToast(error: ProviderServiceError): GlobalSnackbarMessage? {
    val message = when (error) {
        is ProviderServiceError.AttachmentCountOverLimit ->
            UiText.Resource(R.string.file_attachment_count_limit_reached, listOf(error.maxFiles))
        is ProviderServiceError.AttachmentTextOverLimit -> {
            val textLine = UiText.Resource(R.string.file_extraction_send_blocked_text_budget, listOf(error.fileNamesText))
            val countLimit = error.countLimit
            if (countLimit == null) {
                textLine
            } else {
                UiText.Lines(
                    listOf(UiText.Resource(R.string.file_attachment_count_limit_reached, listOf(countLimit)), textLine),
                )
            }
        }
        else -> return null
    }
    return GlobalSnackbarMessage(message = message, style = GlobalToastStyle.Error)
}

/** The notice for a plan rejection, in the same style as the pre-send attachment interception. */
internal fun contextRejectToast(reject: ai.oriveo.community.core.context.ContextReject): GlobalSnackbarMessage {
    val resId = when (reject) {
        ai.oriveo.community.core.context.ContextReject.INSTRUCTIONS_TOO_LONG -> R.string.context_reject_instructions_too_long
        ai.oriveo.community.core.context.ContextReject.MESSAGE_TOO_LONG -> R.string.context_reject_message_too_long
    }
    return GlobalSnackbarMessage(message = UiText.Resource(resId), style = GlobalToastStyle.Error)
}
