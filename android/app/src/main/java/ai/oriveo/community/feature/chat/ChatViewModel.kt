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
import ai.oriveo.community.core.model.ActiveModelSelection
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.StreamActivity
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.provider.showNewChatHintIfNeeded
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.modelDisplayLookups

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
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import ai.oriveo.community.core.util.generateUuidString

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
    /** Chat-side entry point and confirmation gate of remote MCP; when null (unit tests) the Tools entry is hidden. */
    private val mcpChatToolRunner: ai.oriveo.community.core.mcp.McpChatToolRunner? = null,
    private val mcpConfirmationCoordinator: ai.oriveo.community.core.mcp.McpConfirmationCoordinator? = null,
    /** DI singleton; when null (unit tests, etc.) it is built from context and only reads file sizes. */
    private val attachmentStore: ai.oriveo.community.core.data.attachment.AttachmentStore? = null,
    /** Compaction collaborators; null (unit tests) disables compaction. */
    private val compactionDeps: ChatCompactionDeps? = null,
    /** Local ignore streak for the "set as instruction" suggestion; null (unit tests) turns the suggestion off. */
    private val directiveSuggestionStore: ai.oriveo.community.core.notice.DirectiveSuggestionStore? = null,
    /** Local memory items of the current account (MemoryItemRepository.observe, follows account switches); null (unit tests etc.) means no items. */
    memoryItemsSource: kotlinx.coroutines.flow.Flow<List<ai.oriveo.community.core.context.MemoryItem>>? = null,
    /** Memory candidates generated from fresh sends, partitioned by [memoryAccountId]; null = off. */
    private val memoryCandidates: ai.oriveo.community.core.memory.MemoryCandidateRepository? = null,
    private val memoryAccountId: () -> String = { "" },
    private val readAloudController: ai.oriveo.community.core.voice.ReadAloudController? = null,
    private val ioDispatcher: kotlinx.coroutines.CoroutineDispatcher = kotlinx.coroutines.Dispatchers.IO,
) : ViewModel() {
    val generationParameterDraftSessionId: String = generateUuidString()
    private val generationParameterSettingsStore = GenerationParameterSettingsStore.from(context)
    private val outboundHistoryProbe = ChatOutboundHistoryProbe(
        { attachmentStore ?: ai.oriveo.community.core.data.attachment.AttachmentStore(context) }, conversationRepository,
    )
    private val capabilityPreferenceStore = CapabilityPreferenceStore.from(context)
    private val inputCapabilityHintStore by lazy { ai.oriveo.community.core.capability.InputCapabilityHintStore.from(context) }
    private val modelRetiredHintStore by lazy { ai.oriveo.community.core.provider.ModelRetiredHintStore.from(context) }
    private val localCustomFragmentStore = LocalCapabilityCustomFragmentStore.from(context)

    private val initialConversationId: String? =
        (savedStateHandle.get<String>("conversationId"))?.let(::normalizeUuid)

    private var pendingHeroAutoSend: Boolean = savedStateHandle.get<Boolean>("autoSend") == true
    private val activeConversationId = MutableStateFlow(initialConversationId)

    /** Conversation settings (conversation instructions and the "set as instruction" suggestion), orchestrated in ChatConversationSettingsCoordinator. */
    private val conversationSettings = ChatConversationSettingsCoordinator(viewModelScope, conversationRepository,
        activeConversationId, directiveSuggestionStore, globalSnackbarManager::show, memoryCandidates, memoryAccountId, applicationScope)
    val pendingDraftInstructions: StateFlow<String> get() = conversationSettings.pendingDraftInstructions
    val directiveSuggestion: StateFlow<DirectiveSuggestion?> get() = conversationSettings.directiveSuggestion
    fun acceptDirectiveSuggestion() = conversationSettings.acceptSuggestion()
    fun ignoreDirectiveSuggestion() = conversationSettings.ignoreSuggestion()
    val memorySuggestions: MemorySuggestionController get() = conversationSettings.memorySuggestions

    private val capabilityResolver = ChatModelCapabilityResolver()
    private val providerResolutionErrorReporter = ChatProviderResolutionErrorReporter(context, globalSnackbarManager)
    internal val sendCoordinator = ChatSendCoordinator(
        chatStreamingManager = chatStreamingManager,
        applicationScope = applicationScope,
        skillProvider = skillRepository::getById,
        providersProvider = { providers.value },
        untitledNoteFallback = context.getString(R.string.notes_untitled),
        pinnedNotesResolver = { ids -> noteRepository.getActiveNotesByIds(ids) },
        pendingPinnedNoteIds = { noteCoordinator.pendingPinnedNoteIds },
        generationParameterSettingsStore = generationParameterSettingsStore,
        capabilityPreferenceStore = capabilityPreferenceStore,
        localCustomFragmentStore = localCustomFragmentStore,
        capabilityEvidencePartition = providerRepository::currentCapabilityPartitionId,
        capabilityEvidenceIdentity = { p, modelId, partitionId -> providerRepository.capabilityEvidenceIdentity(p, modelId, partitionId) },
        toolCallMemoryVerdict = providerRepository::toolCallMemoryVerdict,
    )
    val mcpCoordinator = ChatMcpCoordinator(
        scope = viewModelScope,
        runner = mcpChatToolRunner,
        confirmationCoordinator = mcpConfirmationCoordinator,
        draftConversationId = generationParameterDraftSessionId,
        currentConversationId = { activeConversationId.value },
        activeProvider = ::activeProvider,
        activeModel = { conversationState.model },
        toolCallMemoryVerdict = providerRepository::toolCallMemoryVerdict,
        capabilityEvidenceIdentity = { provider, modelId -> providerRepository.capabilityEvidenceIdentity(provider, modelId) },
    )
    private val attachmentCoordinator = ChatAttachmentCoordinator(
        attachmentProcessor = attachmentProcessor,
        globalSnackbarManager = globalSnackbarManager,
        activeModel = { conversationState.model },
        pendingAttachments = { pendingAttachments },
        addAttachment = ::addAttachment,
        presentAttachmentSizeLimitDialog = ::presentAttachmentSizeLimitDialog,
        activeProvider = { conversationState.provider },
        attachmentInputGate = { identity -> capabilityResolver.attachmentInputGate(activeProvider(), conversationState.model, identity) },
        capabilityIdentity = { activeProvider()?.takeIf { it.kind == ProviderKind.Relay }?.let { providerRepository.capabilityEvidenceIdentity(it, conversationState.model?.id.orEmpty()) } },
        attachmentStore = { attachmentStore ?: ai.oriveo.community.core.data.attachment.AttachmentStore(context) },
        ioDispatcher = ioDispatcher,
    )
    /** Restored images that are still downloading or failed, by attachment id; local-only attachments are always ready, so this stays empty. */
    internal val restoredImageStates: Map<String, RestoredImageState> = emptyMap()

    // Send launchers: retry / sendCommand share sendLauncher, a fresh user send goes through userSendLauncher; both inject the current memory items at send time.
    private val sendLauncher = sendCoordinator.memoryInjectingSendLauncher({ memory.items.value })
    private val userSendLauncher =
        sendCoordinator.memoryInjectingUserSendLauncher({ memory.items.value })
    private val retryCoordinator = ChatRetryCoordinator(
        viewModelScope = viewModelScope,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        providers = { providers.value },
        chatStreamingManager = chatStreamingManager,
        currentConversation = { currentConversation },
        activeProviderId = { activeProviderId },
        activeModelId = { activeModelId },
        requestPin = { pinRequested = true },
        launchSend = sendLauncher,
        onProviderResolutionError = ::showProviderResolutionError,
        onProviderSelectionError = ::showProviderSelectionError,
        stopReadAloudIfSpeaking = { id ->
            readAloudController?.stopIfSpeaking(id, ai.oriveo.community.core.voice.ReadAloudEndReason.NAVIGATED)
        },
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
    private var newChatSelectionOnce: ActiveModelSelection? = null
    private var composerAttemptKind: ContextConfirmAttempt = ContextConfirmAttempt.SEND
    private val sendCommandCoordinator = ChatSendCommandCoordinator(
        viewModelScope = viewModelScope,
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        currentConversation = { currentConversation },
        currentConversationId = { activeConversationId.value },
        pendingDraftInstructions = { conversationSettings.pendingDraftInstructions.value },
        onProviderSelectionError = ::showProviderSelectionError,
        onProviderResolutionError = ::showProviderResolutionError,
        onModelSelectionError = ::showModelSelectionError,
        onDisclosureRequired = { prompt, payload ->
            providerDisclosurePrompt = prompt
            pendingDisclosurePayload = payload
        },
        onVoiceEntryDisclosureAccepted = { voice.request() },
        onDisclosureConfirmationFailed = ::showProviderDisclosureConfirmationError,
        onConversationActivated = { convId ->
            activeConversationId.value = convId
            conversationSettings.clearDraftInstructions()
            window.bind(convId)
            noteCoordinator.flushPendingPinnedNotes(convId)
        },
        generationParameterSettingsStore = generationParameterSettingsStore,
        capabilityPreferenceStore = capabilityPreferenceStore,
        localCustomFragmentStore = localCustomFragmentStore,
        generationParameterDraftSessionId = { generationParameterDraftSessionId },
        adoptMcpDraft = { conversationId -> mcpCoordinator.adoptDraft(conversationId) },
        onQuoteConsumed = quoteCoordinator::consume,
        onAttachmentsUndeliverable = { attachmentsUndeliverableToast(it)?.let(globalSnackbarManager::show) },
        outboundHistory = outboundHistoryProbe::trim,
        attemptKind = { composerAttemptKind.also { composerAttemptKind = ContextConfirmAttempt.SEND } },
        resolveAttachmentSendOptions = { provider, modelId ->
            sendCoordinator.attachmentSendOptions(
                provider, modelId,
                // Before a conversation exists the preferences live under the draft session id and move over unchanged
                // when the conversation is created.
                conversationId = currentConversation?.id ?: generationParameterDraftSessionId,
                skillId = currentConversation?.skillId,
                mcpEnabledServerCount = mcpCoordinator.panelState.enabledServerCount,
            )
        },
        onComposerConsumed = { conversationId ->
            draftCoordinator.pushText("")
            pendingAttachments = emptyList()
            draftCoordinator.cancelPendingFlush()
            conversationRepository.updateDraft(conversationId, "")
        },
        requestPin = { pinRequested = true },
        onSendSettled = { isSendSetupInFlight = false },
        launchSend = sendLauncher,
        directiveSuggestions = conversationSettings.directiveSuggestions,
        launchUserSend = userSendLauncher,
        memoryCandidates = memoryCandidates,
        memorySuggestions = conversationSettings.memorySuggestions,
        memoryAccountId = memoryAccountId,
        memoryScope = applicationScope,
    )

    private val window = ChatMessageWindowCoordinator(
        scope = viewModelScope,
        conversationRepository = conversationRepository,
        activeConversationId = activeConversationId,
    )
    val conversation: StateFlow<ConversationRenderState> get() = window.conversation

    /** Whether the outbound history (the trimmed conversation history plus the pending turn) contains video; the model panel's file card uses it to predict the wire route. */
    val outboundHistoryHasVideo: StateFlow<Boolean> = outboundHistoryProbe.hasVideoFlow(conversation, viewModelScope)
    val hasMoreAbove: StateFlow<Boolean> get() = window.hasMoreAbove
    val isLoadingAbove: StateFlow<Boolean> get() = window.isLoadingAbove
    val hasMoreBelow: StateFlow<Boolean> get() = window.hasMoreBelow
    val isLoadingBelow: StateFlow<Boolean> get() = window.isLoadingBelow
    val isInitialLoading: StateFlow<Boolean> get() = window.isInitialLoading
    fun loadMoreAbove() = window.loadMoreAbove()
    fun loadMoreBelow() = window.loadMoreBelow()
    fun loadFocusMessageWindow(messageId: String) = window.loadFocusMessageWindow(messageId)
    private val loadedProviders: StateFlow<List<Provider>?> =
        providerRepository.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
    val providers: StateFlow<List<Provider>> =
        loadedProviders.map { it.orEmpty() }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** The lookup that resolves model display names in message metadata: built and index-prewarmed in the background per providers emission; composition only reads it. */
    val modelDisplayLookup: StateFlow<ModelDisplayLookup> = providerRepository.observeAll()
        .modelDisplayLookups()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ModelDisplayLookup.Pending)

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

    /** The activity observed in progress on the wire, such as a web search. Transient: it falls back to null when the stream ends. */
    val streamingActivity: StateFlow<StreamActivity?> = chatStreamingManager
        .streamingActivityFlow(activeConversationId)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    /**
     * Outbound truth for the composer text (sending, drafts and note recall all read it). It is
     * **not** Compose snapshot state -- the per-keystroke text is held by `ChatComposerHost` in
     * local state, so writing here invalidates no composable. The state itself and the one-shot
     * push-back protocol live in [ChatDraftCoordinator], which already owns the draft debounce.
     */
    var inputText: String
        get() = draftCoordinator.text
        set(value) {
            draftCoordinator.text = value
        }

    /** One-shot "push this text back into the composer" request; `ChatComposerHost` is the only reader, the root scope never subscribes. */
    val composerTextRestore: ChatComposerTextRestore get() = draftCoordinator.restore

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

    /**
     * Whether a stream is active for the current conversation.
     *
     * Reads `StateFlow.value`, which is **not snapshot state**: reading it in a composable
     * subscribes to nothing. UI that must follow the generating state has to collect
     * [streamingMessageId] itself (see `ChatComposerHost`).
     */
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

    fun selectReasoningMode(mode: ReasoningMode) {
        if (mode == reasoningMode) return
        reasoningMode = mode
    }

    /** Memory items and the memory indicator; the state lives in ChatMemoryState. */
    private val memory = ChatMemoryState(viewModelScope, memoryItemsSource, conversation)
    val currentMemoryItems: StateFlow<List<ai.oriveo.community.core.context.MemoryItem>> get() = memory.items
    val showMemoryIndicator: StateFlow<Boolean> get() = memory.showIndicator

    var pendingAttachments: List<Attachment> by mutableStateOf(emptyList())
        private set

    var showAttachmentSizeLimitDialog: Boolean by mutableStateOf(false)
        private set

    var providerDisclosurePrompt: ProviderDisclosurePrompt? by mutableStateOf(null)
        private set

    private var pendingDisclosurePayload: PendingDisclosurePayload? = null

    val canSendMessages: Boolean
        get() = !conversationState.isSendBlocked

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
        inputText = draftCoordinator.textFlow,
        savedStateHandle = savedStateHandle,
    )
    /** Voice conversation entry and turns: the gates of [sendMessage], `delivery = VOICE`. */
    internal val voice: ChatVoiceCoordinator = ChatVoiceCoordinator(
        sendCommands = sendCommandCoordinator,
        conversationReady = { canSendMessages },
        claimSendSetup = { !isSendSetupInFlight && activeConversationId.value?.let(chatStreamingManager::isBusyStreaming) != true && run { isSendSetupInFlight = true; true } },
        selection = { activeProviderId to activeModelId },
        approvalPending = (mcpConfirmationCoordinator?.pending ?: flowOf(emptyList())).map { it.isNotEmpty() },
        messages = conversation.map { it.conversation?.messages.orEmpty() },
    )

    init {
        // A refused send: show the toast and put the original text and attachments back into the composer; the wiring lives in ChatContextRejectionObserver.
        observeChatContextRejections(
            viewModelScope, globalSnackbarManager::show, draftCoordinator, { activeConversationId.value }, quoteCoordinator,
            { pendingAttachments }) { pendingAttachments = it }
        mcpCoordinator.observeLoopState()
        if (initialConversationId != null) {
            viewModelScope.launch {

                val initialConversation = conversationRepository.getWithLatestMessageWindow(initialConversationId)
                bootstrapConversation = initialConversation
                hasMissingInitialConversation = initialConversation == null

                if (initialConversation != null) {
                    activeProviderId = initialConversation.providerID
                    activeModelId = initialConversation.modelID
                    conversationState = resolveConversationState(initialConversation, loadedProviders.value)
                    syncResolvedConversationSelectionIfNeeded(providers.value, conversationState)
                }
            }

            conversationLoadCoordinator.start()
        }

        viewModelScope.launch {
            combine(conversation, loadedProviders, lastUsedModelRef) { conversationState, providerSnapshot, lastUsed ->
                Triple(conversationState.conversation, providerSnapshot, lastUsed)
            }.collect { (conv, providerSnapshot, lastUsed) ->
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
                    val activeModel = newChatSelectionOnce?.also { newChatSelectionOnce = null }
                        ?: resolveActiveModel(providerSnapshot.orEmpty(), effectiveLastUsed)
                    // The de-dup ledger is read and written on an IO thread; launch a separate coroutine so the selection binding is not suspended midway.
                    viewModelScope.launch { modelRetiredHintStore.showNewChatHintIfNeeded(activeModel, globalSnackbarManager) }
                    activeProviderId = activeModel?.provider?.id
                    activeModelId = activeModel?.model?.id
                }

                // A session with an empty modelID first takes the last use that points at this connection.
                conversationState = resolveConversationState(effectiveConversation, providerSnapshot, lastUsed)
                syncResolvedConversationSelectionIfNeeded(providerSnapshot.orEmpty(), conversationState)
            }
        }

        viewModelScope.launch {
            conversation.collect { conversationState ->
                val conv = conversationState.conversation
                if (conv?.id != lastDraftConversationId) {
                    draftCoordinator.pushText(conv?.draftText.orEmpty())
                    lastDraftConversationId = conv?.id
                } else if (conv == null && inputText.isNotEmpty()) {
                    draftCoordinator.pushText("")
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

        if (pendingHeroAutoSend) viewModelScope.launchHeroAutoSend(
            conversationLoaded = { conversation.map { it.conversation }.filterNotNull().first() },
            pending = { pendingHeroAutoSend },
            ready = { activeProviderId != null && activeModelId != null && inputText.isNotBlank() },
            consume = { pendingHeroAutoSend = false; savedStateHandle["autoSend"] = false },
            send = ::sendMessage,
        )

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

    internal fun attachmentEntryModel(localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity? = null) =
        capabilityResolver.attachmentEntryModel(activeProvider(), conversationState.model, localIdentity)

    fun modelControlsFinalTransport(): String? =
        capabilityResolver.finalTransport(activeProvider(), conversationState.model)

    private fun activeProvider(): Provider? =
        capabilityResolver.activeProvider(conversationState.provider, providers.value, activeProviderId)

    /** Realtime voice on a draft: creates the conversation through the first-send path, without sending. */
    suspend fun createFirstConversation(): String? =
        sendCommandCoordinator.createFirstConversation(activeProviderId, activeModelId)

    /** The conversation a first send would create (not stored), for a realtime plan on a draft. */
    suspend fun plannedFirstConversation(): Conversation? =
        sendCommandCoordinator.plannedFirstConversation(activeProviderId, activeModelId)

    fun sendMessage() {
        val text = inputText.trim()
        if (text.isEmpty() && pendingAttachments.isEmpty()) return
        if (!canSendMessages) return
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
        mcpCoordinator.cancelPending(convId)
        chatStreamingManager.stopStream(convId)
        compaction?.stopSend(convId)
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
        val editedUserMessage = when {
            messageIndex < 0 -> null
            messages[messageIndex].role == ChatRole.User -> messages[messageIndex]
            else -> messages.take(messageIndex).lastOrNull { it.role == ChatRole.User }
        }
        val originalAttachments = editedUserMessage?.attachments.orEmpty()
        // The new-key copy is awaited serially inside the truncation coroutine; the original message row is deleted only after it completes.
        return retryCoordinator.editMessageInline(
            messageId,
            restoreAttachments = {
                pendingAttachments = pendingAttachments + attachmentCoordinator.restoredForEdit(originalAttachments)
            },
        )?.also {
            composerAttemptKind = ContextConfirmAttempt.EDIT
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

fun saveConversationInstructions(opened: String, edited: String) = conversationSettings.saveInstructions(opened, edited)

    suspend fun conversationInstructionsCarryOver(currentInstructions: String): String? =
        conversationSettings.instructionsCarryOver(currentInstructions)

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

    // -- Pin-to-top: scroll control --

    /** ChatScreen clears [pendingPinUserMessageId] once it has pinned the message, so the pin is not triggered twice. */
    fun consumePendingPin() { pendingPinUserMessageId = null }

    /** Typing callback: only updates the outbound truth and queues the draft debounce, never bumps the restore token (see the coordinator). */
    fun onInputTextChanged(text: String) {
        // The first input (empty → non-empty) starts a background pre-compaction.
        compaction?.onComposerInput(inputText, text)
        draftCoordinator.onInputTextChanged(text, activeConversationId.value)
    }

    /** External push of text back into the composer (inline message edit and the like): reaches the composer and still goes through the draft debounce. */
    fun restoreInputText(text: String) = draftCoordinator.restoreText(text, activeConversationId.value)

    fun flushDraft() {
        draftCoordinator.flushDraft(activeConversationId.value, inputText)
    }

    fun handleChatScreenLeaving() {

        flushDraft()
    }

    fun addAttachment(attachment: Attachment, source: String = "file") {

        if (!attachmentCoordinator.accepts(attachment)) return
        pendingAttachments = pendingAttachments + attachment
        showFirstAttachHint(attachment)
    }

    private fun showFirstAttachHint(attachment: Attachment) {
        val provider = activeProvider() ?: return
        val model = conversationState.model ?: return
        viewModelScope.launch {
            val identity = provider.takeIf { it.kind == ProviderKind.Relay }?.let { providerRepository.capabilityEvidenceIdentity(it, model.id) }
            val entryModel = attachmentEntryModel(identity)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                entryModel.firstAttachHintRes(attachment, provider, model, inputCapabilityHintStore)
            }?.let { globalSnackbarManager.show(GlobalSnackbarMessage(message = UiText.Resource(it))) }
        }
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

    fun startNewChat(keep: ActiveModelSelection? = null) {
        val currentProvider = keep?.provider?.id ?: activeProviderId
        val currentModel = keep?.model?.id ?: activeModelId
        newChatSelectionOnce = keep?.takeIf { activeConversationId.value != null }

        activeConversationId.value = null
        bootstrapConversation = null
        conversationSettings.clearDraftInstructions()
        draftCoordinator.pushText("")
        pendingAttachments = emptyList()
        // A pending quote belongs to the previous conversation's messages.
        quoteCoordinator.clear()
        pendingPinUserMessageId = null
        pinRequested = false
        mcpCoordinator.resetDraft()

        activeProviderId = currentProvider
        activeModelId = currentModel
    }

    /**
     * New chat with the summary: a connection missing its credential neither writes nor opens and returns its id so the caller can open its detail page;
     * a sendable current model is written as last used and then opened; an unsendable one is not written and the new-chat chain of this connection is used,
     * and an empty chain does not open and returns the connection id for the detail page (the judgment lives in the collaborator).
     */
    internal fun startNewChatKeepingModel(): String? = ChatCompactionUiCoordinator.keepModelForNewChat(
        conversationState.provider, conversationState.model, !conversationState.isSendBlocked,
        appPreferencesRepository.lastUsedModelRefSnapshot ?: lastUsedModelRef.value,
        ChatCompactionUiCoordinator.lastUsedWriter(appPreferencesRepository, viewModelScope), ::startNewChat,
    )

    /**
     * compaction UI (separator, third-compaction hint, new chat with summary, clear / recompact / manual
     * compact and their toasts). Null when compaction is not wired (unit tests).
     */
    val compaction: ChatCompactionUiCoordinator? = ChatCompactionUiCoordinator.forChat(compactionDeps,
        sendCoordinator, quoteCoordinator, memory.items, viewModelScope, conversation, ::startNewChatKeepingModel,
        providers = { providers.value })

    /**
     * usage summary of the shown conversation for the composer ring; recomputed on
     * conversation switch, message changes and checkpoint changes. Null for drafts and when not wired.
     */
    val contextUsage: StateFlow<ContextUsageSummary?> = chatContextUsage(compactionDeps, conversation, viewModelScope)

    fun deleteConversation() {
        conversationActions.deleteConversation {
            isUserInitiatedExit = true
        }
    }

    override fun onCleared() {
        conversationLoadCoordinator.stop()
        window.stop()
    }

    private fun activeProviderKind() = conversationState.provider?.kind
        ?: providers.value.find { it.id == activeProviderId }?.kind

    private fun syncResolvedConversationSelectionIfNeeded(providerList: List<Provider>, resolvedState: ChatConversationState) {
        val (providerId, modelId) = conversationSelectionToSync(providerList, activeProviderId, activeModelId, resolvedState) ?: return
        activeProviderId = providerId
        activeModelId = modelId
    }

    private fun resolveConversationState(conversation: Conversation?, snapshot: List<Provider>?, lastUsed: LastUsedModelRef? = null) =
        resolveChatConversationState(conversation, snapshot, activeProviderId, activeModelId, lastUsed)

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
