package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.data.repository.chat.MessageWindowLoader
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.resolvedForRequest
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.provider.ModelSelectionUtils

import ai.oriveo.community.core.provider.ProviderSelectionSnapshot

import ai.oriveo.community.core.util.normalizeUuid
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckOption
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import ai.oriveo.community.core.util.generateUuidString

private data class ConversationStateBundle(
    val meta: Conversation?,
    val windowState: MessageWindowLoader.State,
)

class ConversationRenderState(
    val conversation: Conversation?,
    val windowState: MessageWindowLoader.State = MessageWindowLoader.State(),
)

@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class ChatViewModel(
    savedStateHandle: SavedStateHandle,
    private val context: Context,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val providerRepository: ProviderRepository,
    private val conversationRepository: ConversationRepository,
    private val noteRepository: NoteRepository,
    private val chatStreamingManager: ChatStreamingManager,
    private val skillRepository: SkillRepository,
    private val attachmentProcessor: AttachmentProcessor,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val applicationScope: CoroutineScope,
) : ViewModel() {
    val generationParameterDraftSessionId: String = generateUuidString()
    private val generationParameterSettingsStore = GenerationParameterSettingsStore.from(context)
    private val capabilityPreferenceStore = CapabilityPreferenceStore.from(context)
    private val localCustomFragmentStore = LocalCapabilityCustomFragmentStore.from(context)

    private val initialConversationId: String? =
        (savedStateHandle.get<String>("conversationId"))?.let(::normalizeUuid)
    
    private var pendingHeroAutoSend: Boolean = savedStateHandle.get<Boolean>("autoSend") == true
    private val activeConversationId = MutableStateFlow(initialConversationId)

    private val messageWindowLoader: MessageWindowLoader =
        conversationRepository.createMessageWindowLoader()
    
    private val messageWindowScope: CoroutineScope = messageWindowLoaderScope(viewModelScope)
    private val capabilityResolver = ChatModelCapabilityResolver()
    private val providerResolutionErrorReporter = ChatProviderResolutionErrorReporter(context, globalSnackbarManager)
    private val promptInjectionBuilder = ChatPromptInjectionBuilder(
        skillProvider = skillRepository::getById,
        providersProvider = { providers.value },
        untitledNoteFallback = context.getString(R.string.notes_untitled),
    )
    private val sendCoordinator = ChatSendCoordinator(
        appPreferencesRepository = appPreferencesRepository,
        chatStreamingManager = chatStreamingManager,
        applicationScope = applicationScope,
        promptInjectionBuilder = promptInjectionBuilder,
        currentAntiForgetEnabled = { currentAntiForgetEnabled.value },
        currentAntiForgetText = { currentAntiForgetText.value },
        pinnedNotesResolver = { ids -> noteRepository.getActiveNotesByIds(ids) },
        pendingPinnedNoteIds = { noteCoordinator.pendingPinnedNoteIds },
        generationParameterSettingsStore = generationParameterSettingsStore,
        capabilityPreferenceStore = capabilityPreferenceStore,
        localCustomFragmentStore = localCustomFragmentStore,
        capabilityEvidencePartition = providerRepository::currentCapabilityPartitionId,
        capabilityEvidenceIdentity = { provider, modelId, partitionId ->
            providerRepository.capabilityEvidenceIdentity(provider, modelId, partitionId)
        },
    )
    private val attachmentCoordinator = ChatAttachmentCoordinator(
        attachmentProcessor = attachmentProcessor,
        globalSnackbarManager = globalSnackbarManager,
        activeProviderKind = ::activeProviderKind,
        activeModel = { conversationState.model },
        pendingAttachments = { pendingAttachments },
        addAttachment = ::addAttachment,
        presentAttachmentSizeLimitDialog = ::presentAttachmentSizeLimitDialog,
    )
    private val sendLauncher = ChatSendLauncher { conversation, provider, modelId, text, existingMessages, attachments,
        persistUserMessage, appendToAssistant, userMessageAlreadyInHistory, quoteContext ->
        sendCoordinator.launchSend(
            conversation = conversation,
            provider = provider,
            modelId = modelId,
            text = text,
            memoryText = currentMemoryText.value.trim(),
            existingMessages = existingMessages,
            attachments = attachments,
            quoteContext = quoteContext,
            persistUserMessage = persistUserMessage,
            appendToAssistant = appendToAssistant,
            userMessageAlreadyInHistory = userMessageAlreadyInHistory,
        )
    }
    private val retryCoordinator = ChatRetryCoordinator(
        viewModelScope = viewModelScope,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        chatStreamingManager = chatStreamingManager,
        currentConversation = { currentConversation },
        activeProviderId = { activeProviderId },
        activeModelId = { activeModelId },
        requestPin = { pinRequested = true },
        launchSend = sendLauncher,
        onProviderResolutionError = ::showProviderResolutionError,
    )
    private val exportCoordinator = ChatExportCoordinator(
        viewModelScope = viewModelScope,
        conversationRepository = conversationRepository,
        globalSnackbarManager = globalSnackbarManager,
        currentConversation = { currentConversation },
    )
    private val modelSelectionCoordinator = ChatModelSelectionCoordinator(
        viewModelScope = viewModelScope,
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        globalSnackbarManager = globalSnackbarManager,
        providers = { providers.value },
        activeProviderId = { activeProviderId },
        activeModelId = { activeModelId },
        activeConversationId = { activeConversationId.value },
        onProviderResolutionError = ::showProviderResolutionError,
    )
    private val draftCoordinator = ChatDraftCoordinator(
        viewModelScope = viewModelScope,
        conversationRepository = conversationRepository,
    )
    private val conversationActions = ChatConversationActions(
        viewModelScope = viewModelScope,
        applicationScope = applicationScope,
        conversationRepository = conversationRepository,
        chatStreamingManager = chatStreamingManager,
        globalSnackbarManager = globalSnackbarManager,
        currentConversationId = { activeConversationId.value },
        generationParameterSettingsStore = generationParameterSettingsStore,
        capabilityPreferenceStore = capabilityPreferenceStore,
        localCustomFragmentStore = localCustomFragmentStore,
    )
    private val quoteCoordinator = ChatQuoteCoordinator()
    private val sendCommandCoordinator = ChatSendCommandCoordinator(
        viewModelScope = viewModelScope,
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        currentConversation = { currentConversation },
        currentConversationId = { activeConversationId.value },
        onProviderSelectionError = ::showProviderSelectionError,
        onProviderResolutionError = ::showProviderResolutionError,
        onModelSelectionError = ::showModelSelectionError,
        onDisclosureRequired = { prompt, payload ->
            providerDisclosurePrompt = prompt
            pendingDisclosurePayload = payload
        },
        onDisclosureConfirmationFailed = ::showProviderDisclosureConfirmationError,
        onConversationActivated = { convId ->
            activeConversationId.value = convId
            messageWindowLoader.bind(messageWindowScope, convId)
            noteCoordinator.flushPendingPinnedNotes(convId)
        },
        generationParameterSettingsStore = generationParameterSettingsStore,
        capabilityPreferenceStore = capabilityPreferenceStore,
        localCustomFragmentStore = localCustomFragmentStore,
        generationParameterDraftSessionId = { generationParameterDraftSessionId },
        onQuoteConsumed = quoteCoordinator::consume,
        onComposerConsumed = { conversationId ->
            inputText = ""
            pendingAttachments = emptyList()
            draftCoordinator.cancelPendingFlush()
            conversationRepository.updateDraft(conversationId, "")
        },
        requestPin = { pinRequested = true },
        onSendSettled = { isSendSetupInFlight = false },
        launchSend = sendLauncher,
    )

    
    val conversation: StateFlow<ConversationRenderState> = activeConversationId
        .flatMapLatest { conversationId ->
            if (conversationId == null) {
                messageWindowLoader.stop()
                flowOf(ConversationStateBundle(meta = null, windowState = MessageWindowLoader.State()))
            } else {
                messageWindowLoader.bind(messageWindowScope, conversationId)
                combine(
                    conversationRepository.observeMetadata(conversationId),
                    messageWindowLoader.state,
                ) { meta, windowState ->
                    ConversationStateBundle(meta = meta, windowState = windowState)
                }
            }
        }
        .map { bundle ->
            val merged = bundle.meta?.copy(messages = bundle.windowState.messages)
            ConversationRenderState(conversation = merged, windowState = bundle.windowState)
        }
        .stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5000),
            ConversationRenderState(conversation = null),
        )

    
    
    
    
    
    
    
    val hasMoreAbove: StateFlow<Boolean> = conversation
        .map { it.windowState.hasMoreAbove }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    
    val isLoadingAbove: StateFlow<Boolean> = conversation
        .map { it.windowState.isLoadingAbove }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    
    val hasMoreBelow: StateFlow<Boolean> = conversation
        .map { it.windowState.hasMoreBelow }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    
    val isLoadingBelow: StateFlow<Boolean> = conversation
        .map { it.windowState.isLoadingBelow }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    
    val isInitialLoading: StateFlow<Boolean> = conversation
        .map { it.windowState.isInitialLoading }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    
    fun loadMoreAbove() {
        messageWindowScope.launch { messageWindowLoader.extendUpward() }
    }

    fun loadMoreBelow() {
        messageWindowScope.launch { messageWindowLoader.extendDownward() }
    }

    
    fun loadFocusMessageWindow(messageId: String) {
        val conversationId = activeConversationId.value ?: return
        viewModelScope.launch {
            if (messageWindowLoader.loadAroundMessage(conversationId, messageId)) return@launch
            val hydrated = conversationRepository.hydrateRemoteMessageWindowAround(
                conversationId = conversationId,
                messageId = messageId,
            )
            if (hydrated) {
                messageWindowLoader.loadAroundMessage(conversationId, messageId)
            }
        }
    }

    
    val providers: StateFlow<List<Provider>> = providerRepository.observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val lastUsedModelRef = appPreferencesRepository.lastUsedModelRef
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    
    val currentSkill: StateFlow<Skill?> = conversation
        .map { state ->
            val skillId = state.conversation?.skillId ?: return@map null
            skillRepository.getById(skillId)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    
    val streamingText: StateFlow<String> = combine(
        activeConversationId,
        chatStreamingManager.sessionsVersion,
    ) { convId, _ -> convId }
        .flatMapLatest { convId ->
            if (convId == null) flowOf("")
            else chatStreamingManager.streamingText(convId)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val streamingMessageId: StateFlow<String?> = combine(
        activeConversationId,
        chatStreamingManager.sessionsVersion,
    ) { convId, _ -> convId }
        .flatMapLatest { convId ->
            if (convId == null) flowOf(null)
            else chatStreamingManager.streamingMessageId(convId)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    
    val streamingReasoning: StateFlow<String> = combine(
        activeConversationId,
        chatStreamingManager.sessionsVersion,
    ) { convId, _ -> convId }
        .flatMapLatest { convId ->
            if (convId == null) flowOf("")
            else chatStreamingManager.streamingReasoning(convId)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    
    val streamingReasoningActive: StateFlow<Boolean> = chatStreamingManager
        .reasoningActiveFlow(activeConversationId)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    
    var inputText: String by mutableStateOf("")

    /** Single pending Ask snapshot; a later selection replaces it. */
    val pendingQuoteContext get() = quoteCoordinator.pending

    
    var activeProviderId: String? by mutableStateOf(null)
        private set
    var activeModelId: String? by mutableStateOf(null)
        private set

    
    var hasMissingInitialConversation: Boolean by mutableStateOf(false)
        private set

    
    var isUserInitiatedExit: Boolean by mutableStateOf(false)
        private set

    
    var bootstrapConversation: Conversation? by mutableStateOf(null)
        private set

    
    private val conversationLoadCoordinator = ChatConversationLoadCoordinator(
        viewModelScope = viewModelScope,
        requestedConversationId = initialConversationId,
        currentConversation = { currentConversation },
        hasMissingInitialConversation = { hasMissingInitialConversation },
    )

    internal val chatLoadState: ChatLoadState
        get() = conversationLoadCoordinator.chatLoadState

    
    fun retryConversationLoad() = conversationLoadCoordinator.retry()

    
    val isGenerating: Boolean
        get() = streamingMessageId.value != null

    
    var expensiveModelHint: ExpensiveModelHint? by mutableStateOf(null)
        private set

    
    var showModelSwitcher: Boolean by mutableStateOf(false)

    
    var conversationState: ChatConversationState by mutableStateOf(
        ChatConversationState(provider = null, model = null),
    )
        private set

     
    var pendingPinUserMessageId: String? by mutableStateOf(null)
        private set

    
    private var pinRequested: Boolean = false

    
    private var isSendSetupInFlight: Boolean = false

    /** C20: Reasoning mode */
    var reasoningMode: ReasoningMode by mutableStateOf(ReasoningMode.Automatic)
        private set

    
    private fun disableWebSearchPreference() {
        val provider = activeProvider() ?: return
        val model = conversationState.model ?: return
        val conversationID = currentConversation?.id ?: generationParameterDraftSessionId
        val isExisting = currentConversation != null
        val modelControlIdentity = ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
            .resolve(provider, model) ?: return
        val transportIdentity = modelControlIdentity.storageIdentity
        val current = capabilityPreferenceStore.resolvedForRequest(
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = modelControlIdentity.canonicalModelId,
            conversationID = conversationID,
            skillID = currentConversation?.skillId,
            transportIdentity = transportIdentity,
            isExistingConversation = isExisting,
        )
        if (current.web == CapabilityWebPreference.Off) return
        
        
        
        
        
        val existing = capabilityPreferenceStore.scopeValues(
            providerID = provider.id,
            modelID = modelControlIdentity.canonicalModelId,
            conversationID = conversationID,
            skillID = currentConversation?.skillId,
            transportIdentity = transportIdentity,
            isDraftConversation = !isExisting,
        ).conversation
        val next = existing?.copy(web = CapabilityWebPreference.Off)
            ?: CapabilityPreferenceValues(web = CapabilityWebPreference.Off, reasoningIntent = null)
        if (isExisting) {
            capabilityPreferenceStore.setConversation(
                next,
                provider.id,
                modelControlIdentity.canonicalModelId,
                conversationID,
                transportIdentity,
            )
        } else {
            capabilityPreferenceStore.setDraftConversation(
                next,
                provider.id,
                modelControlIdentity.canonicalModelId,
                conversationID,
                transportIdentity,
            )
        }
    }

    fun selectReasoningMode(mode: ReasoningMode) {
        if (mode == reasoningMode) return
        reasoningMode = mode
    }

    
    val currentMemoryText: StateFlow<String> = appPreferencesRepository.memoryText
        .stateIn(viewModelScope, SharingStarted.Eagerly, "")

    private val currentAntiForgetEnabled = appPreferencesRepository.memoryAntiForgetEnabled
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    private val currentAntiForgetText = appPreferencesRepository.memoryAntiForgetText
        .stateIn(viewModelScope, SharingStarted.Eagerly, "")

    val showMemoryIndicator: StateFlow<Boolean> = combine(
        currentMemoryText,
        conversation,
    ) { memoryText, conversationState ->
        memoryText.isNotBlank() && (conversationState.conversation?.useMemory ?: true)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    
    var pendingAttachments: List<Attachment> by mutableStateOf(emptyList())
        private set

    var showAttachmentSizeLimitDialog: Boolean by mutableStateOf(false)
        private set

    var providerDisclosurePrompt: ProviderDisclosurePrompt? by mutableStateOf(null)
        private set

    private var pendingDisclosurePayload: PendingDisclosurePayload? = null

    val canSendMessages: Boolean
        get() = !conversationState.isReadOnly

    private var lastBoundConversationId: String? = null
    private var lastConversationSelection: Pair<String, String>? = null
    private var lastDraftConversationId: String? = null
    private val currentConversation: Conversation?
        get() = conversation.value.conversation ?: bootstrapConversation

    
    val noteCoordinator = ChatNoteCoordinator(
        scope = viewModelScope,
        noteRepository = noteRepository,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        globalSnackbarManager = globalSnackbarManager,
        appPreferencesRepository = appPreferencesRepository,
        providers = providers,
        conversation = conversation,
        activeConversationId = activeConversationId,
        currentConversation = { currentConversation },
        inputTextProvider = { inputText },
        savedStateHandle = savedStateHandle,
    )
    init {
        if (initialConversationId != null) {
            viewModelScope.launch {
                
                
                val initialConversation = conversationRepository.getWithLatestMessageWindow(initialConversationId)
                bootstrapConversation = initialConversation
                hasMissingInitialConversation = initialConversation == null

                if (initialConversation != null) {
                    activeProviderId = initialConversation.providerID
                    activeModelId = initialConversation.modelID
                    conversationState = resolveChatConversationState(
                        conversation = initialConversation,
                        providers = providers.value,
                        activeProviderId = initialConversation.providerID,
                        activeModelId = initialConversation.modelID,
                    )
                    syncResolvedConversationSelectionIfNeeded(providers.value, conversationState)
                }
            }

            conversationLoadCoordinator.start()
        }

        viewModelScope.launch {
            combine(conversation, providers, lastUsedModelRef) { conversationState, providerList, lastUsed ->
                Triple(conversationState.conversation, providerList, lastUsed)
            }.collect { (conv, providerList, lastUsed) ->
                val effectiveConversation = conv ?: bootstrapConversation

                if (effectiveConversation != null) {
                    if (conv != null && bootstrapConversation?.id == conv.id) {
                        bootstrapConversation = null
                    }
                    hasMissingInitialConversation = false
                    activeConversationId.value = effectiveConversation.id
                    val incomingSelection = effectiveConversation.providerID to effectiveConversation.modelID
                    val shouldSyncSelection = lastBoundConversationId != effectiveConversation.id ||
                        lastConversationSelection == null ||
                        (activeProviderId == lastConversationSelection?.first &&
                            activeModelId == lastConversationSelection?.second)
                    if (shouldSyncSelection) {
                        activeProviderId = effectiveConversation.providerID
                        activeModelId = effectiveConversation.modelID
                    }
                    lastBoundConversationId = effectiveConversation.id
                    lastConversationSelection = incomingSelection
                } else {
                    lastBoundConversationId = null
                    lastConversationSelection = null
                    if (activeConversationId.value == null) {
                        bootstrapConversation = null
                    }
                    
                    
                    val effectiveLastUsed = appPreferencesRepository.lastUsedModelRefSnapshot ?: lastUsed
                    val activeModel = resolveActiveModel(providerList, effectiveLastUsed)
                    activeProviderId = activeModel?.provider?.id
                    activeModelId = activeModel?.model?.id
                }

                conversationState = resolveChatConversationState(
                    conversation = effectiveConversation,
                    providers = providerList,
                    activeProviderId = activeProviderId,
                    activeModelId = activeModelId,
                )
                syncResolvedConversationSelectionIfNeeded(providerList, conversationState)
            }
        }

        viewModelScope.launch {
            conversation.collect { conversationState ->
                val conv = conversationState.conversation
                if (conv?.id != lastDraftConversationId) {
                    inputText = conv?.draftText.orEmpty()
                    lastDraftConversationId = conv?.id
                } else if (conv == null && inputText.isNotEmpty()) {
                    inputText = ""
                }
            }
        }

        
        
        
        viewModelScope.launch {
            combine(streamingMessageId, conversation) { sid, state -> sid to state.conversation }
                .collect { (streamingId, conv) ->
                    if (!pinRequested || streamingId == null || conv == null) return@collect
                    val userId = resolvePinnedUserMessageId(conv.messages, streamingId) ?: return@collect
                    pendingPinUserMessageId = userId
                    pinRequested = false
                }
        }

        
        
        
        if (pendingHeroAutoSend) {
            viewModelScope.launch {
                conversation
                    .map { it.conversation }
                    .filterNotNull()
                    .first()
                
                var waitedMs = 0
                while (
                    pendingHeroAutoSend &&
                    (activeProviderId == null || activeModelId == null || inputText.isBlank()) &&
                    waitedMs < 1000
                ) {
                    delay(50)
                    waitedMs += 50
                }
                if (pendingHeroAutoSend &&
                    activeProviderId != null &&
                    activeModelId != null &&
                    inputText.isNotBlank()
                ) {
                    pendingHeroAutoSend = false
                    savedStateHandle["autoSend"] = false
                    sendMessage()
                } else if (pendingHeroAutoSend) {
                    
                    pendingHeroAutoSend = false
                    savedStateHandle["autoSend"] = false
                }
            }
        }

        viewModelScope.launch {
            conversation
                .map { it.conversation?.id }
                .distinctUntilChanged()
                .collectLatest { conversationId ->
                if (conversationId == null) {
                    Unit
                    return@collectLatest
                }

                
                delay(350)
                if (currentConversation?.id == conversationId) {
                    Unit
                }
                }
        }
    }

    
    fun activeModelCapabilities(): List<ModelCapability> {
        return capabilityResolver.activeModelCapabilities(conversationState.model)
    }

    
    fun supportsImage(): Boolean {
        return capabilityResolver.supportsImage(activeProvider(), conversationState.model)
    }

    fun supportsFile(): Boolean {
        return capabilityResolver.supportsFile(activeProvider(), conversationState.model)
    }

    fun supportsVideo(): Boolean {
        return capabilityResolver.supportsVideo(activeProvider(), conversationState.model)
    }

    /** Exact dispatch carrier exposed to the composer before it renders runtime controls. */
    fun modelControlsFinalTransport(): String? =
        capabilityResolver.finalTransport(activeProvider(), conversationState.model)

    fun updateWebSearchEnabled(@Suppress("UNUSED_PARAMETER") enabled: Boolean) {}

    private fun activeProvider(): Provider? =
        capabilityResolver.activeProvider(conversationState.provider, providers.value, activeProviderId)

    fun sendMessage() {
        val text = inputText.trim()
        if (!canSendMessages || (text.isEmpty() && pendingAttachments.isEmpty())) return
        if (isSendSetupInFlight) return
        activeConversationId.value?.let { if (chatStreamingManager.isBusyStreaming(it)) return }
        isSendSetupInFlight = true
        expensiveModelHint = null
        sendCommandCoordinator.sendMessage(
            text = text,
            attachments = pendingAttachments.ifEmpty { null },
            quoteContext = pendingQuoteContext,
            providerId = activeProviderId,
            modelId = activeModelId,
        )
    }

    fun confirmProviderDisclosure() {
        if (isSendSetupInFlight) return
        isSendSetupInFlight = true
        sendCommandCoordinator.confirmProviderDisclosure(
            prompt = providerDisclosurePrompt,
            payload = pendingDisclosurePayload,
            clearPrompt = {
                providerDisclosurePrompt = null
                pendingDisclosurePayload = null
            },
        )
    }

    fun cancelProviderDisclosure() {
        providerDisclosurePrompt = null
        pendingDisclosurePayload = null
    }

    fun runCrosscheck(option: CrosscheckOption) = noteCoordinator.runCrosscheck(option)

    fun stopGeneration() {
        val convId = activeConversationId.value ?: return
        chatStreamingManager.stopStream(convId)
    }

    
    fun regenerateMessage(messageId: String) {
        retryCoordinator.regenerateMessage(messageId)
    }

    
    fun retryMessage(messageId: String) {
        retryCoordinator.retryMessage(messageId)
    }

    fun retryWithoutLocalCustomFields(messageId: String) {
        retryCoordinator.retryWithoutLocalCustomFields(messageId)
    }

    
    fun continueMessage(messageId: String) {
        retryCoordinator.continueMessage(messageId)
    }

    
    fun editMessageInline(messageId: String): String? {
        val conversation = currentConversation
        val messages = conversation?.messages.orEmpty()
        val messageIndex = messages.indexOfFirst { it.id == messageId }
        val restoredQuote = when {
            messageIndex < 0 -> null
            messages[messageIndex].role == ChatRole.User -> messages[messageIndex].quoteContext
            else -> messages.take(messageIndex).lastOrNull { it.role == ChatRole.User }?.quoteContext
        }
        return retryCoordinator.editMessageInline(messageId)?.also {
            quoteCoordinator.restore(restoredQuote)
        }
    }

    fun askAboutSelection(message: ChatMessage, selection: QuoteSelectionContent): Boolean {
        return quoteCoordinator.attach(message, selection)
    }

    fun removePendingQuote() = quoteCoordinator.remove()

    
    fun selectModel(providerId: String, modelId: String) {
        expensiveModelHint = evaluateExpensiveModelHint(
            providers = providers.value,
            oldProviderId = activeProviderId,
            oldModelId = activeModelId,
            newProviderId = providerId,
            newModelId = modelId,
        )
        modelSelectionCoordinator.selectModel(providerId, modelId) { selectedProviderId, selectedModelId ->
            activeProviderId = selectedProviderId
            activeModelId = selectedModelId
        }
    }

    fun dismissExpensiveModelHint() {
        expensiveModelHint = null
    }

    fun toggleUseMemory() {
        val conv = currentConversation ?: return
        conversationActions.toggleUseMemory(conv.useMemory)
    }

    fun enableModel(providerId: String, modelId: String) {
        modelSelectionCoordinator.enableModel(providerId, modelId)
    }

    

    
    fun consumePendingPin() {
        pendingPinUserMessageId = null
    }

    fun onInputTextChanged(text: String) {
        draftCoordinator.onInputTextChanged(
            text = text,
            conversationId = activeConversationId.value,
            updateInput = { inputText = it },
        )
    }

    fun flushDraft() {
        draftCoordinator.flushDraft(activeConversationId.value, inputText)
    }

    fun handleChatScreenLeaving() {
        
        
        
        
        flushDraft()
    }

    

    fun addAttachment(attachment: Attachment, source: String = "file") {
        
        if (!attachmentCoordinator.accepts(attachment)) return
        pendingAttachments = pendingAttachments + attachment
    }

    fun removeAttachment(id: String) {
        pendingAttachments = pendingAttachments.filter { it.id != id }
    }

    fun clearAttachments() {
        pendingAttachments = emptyList()
        quoteCoordinator.clear()
    }

    fun dismissAttachmentSizeLimitDialog() {
        showAttachmentSizeLimitDialog = false
    }

    private fun presentAttachmentSizeLimitDialog() {
        showAttachmentSizeLimitDialog = true
    }

    
    fun processImageUri(context: android.content.Context, uri: android.net.Uri) {
        viewModelScope.launch {
            attachmentCoordinator.processImage(context, uri)
        }
    }

    
    fun processFileUri(context: android.content.Context, uri: android.net.Uri) {
        viewModelScope.launch {
            attachmentCoordinator.processFile(context, uri)
        }
    }

    

    fun copyMessage(message: ChatMessage, context: Context) {
        exportCoordinator.copyMessage(message, context)
    }

    fun shareMessage(message: ChatMessage, context: Context) {
        exportCoordinator.shareMessage(message, context)
    }

    

    fun exportAsMarkdown(context: Context) {
        exportCoordinator.exportAsMarkdown(context)
    }

    fun exportAsJson(context: Context) {
        exportCoordinator.exportAsJson(context)
    }

    
    fun startNewChat() {
        val currentProvider = activeProviderId
        val currentModel = activeModelId

        activeConversationId.value = null
        bootstrapConversation = null
        inputText = ""
        pendingAttachments = emptyList()
        pendingPinUserMessageId = null
        pinRequested = false

        
        activeProviderId = currentProvider
        activeModelId = currentModel
    }

    fun deleteConversation() {
        conversationActions.deleteConversation {
            isUserInitiatedExit = true
        }
    }

    

    override fun onCleared() {
        super.onCleared()
        conversationLoadCoordinator.stop()
        Unit
        messageWindowLoader.stop()
    }

    private fun activeProviderKind() = conversationState.provider?.kind
        ?: providers.value.find { it.id == activeProviderId }?.kind

    private fun syncResolvedConversationSelectionIfNeeded(
        providerList: List<Provider>,
        resolvedState: ChatConversationState,
    ) {
        val resolvedProvider = resolvedState.provider ?: return
        val activeProvider = activeProviderId?.let { selectedId ->
            providerList.firstOrNull { it.id == selectedId }
        }
        val activeModel = activeProvider?.let { provider ->
            ProviderSelectionSnapshot.currentModel(provider, activeModelId)
        }
        if (activeProvider?.id == resolvedProvider.id && activeModel?.id == resolvedState.model?.id) {
            return
        }

        activeProviderId = resolvedProvider.id
        activeModelId = resolvedState.model?.let(ModelSelectionUtils::preferredStoredModelIdentifier)
    }

    private fun showProviderSelectionError() {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(R.string.chat_issue_no_provider_message),
            ),
        )
    }

    private fun showProviderResolutionError(error: Throwable) = providerResolutionErrorReporter.show(error)

    private fun showModelSelectionError() {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(R.string.chat_issue_model_missing_message),
            ),
        )
    }

    private fun showProviderDisclosureConfirmationError(error: Throwable) {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(R.string.provider_disclosure_ack_failed),
                style = GlobalToastStyle.Error,
            ),
        )
    }

}
