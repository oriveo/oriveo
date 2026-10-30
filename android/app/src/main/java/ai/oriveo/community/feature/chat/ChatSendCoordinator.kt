package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.resolvedForRequest
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.context.ContextKnowledgeFile
import ai.oriveo.community.core.context.ContextPinnedNote
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.util.normalizeUuid
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.StreamRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal class ChatSendCoordinator(
    private val chatStreamingManager: ChatStreamingManager,
    private val applicationScope: CoroutineScope,
    // Skill inputs handed to the context assembler; budgeting and system assembly are entirely up to the assembler.
    private val skillProvider: suspend (String) -> Skill? = { null },
    private val providersProvider: () -> List<Provider> = { emptyList() },
    private val untitledNoteFallback: String = "",
    /** Resolves the pinned note ids on the conversation, plus any staged before it was stored. */
    private val pinnedNotesResolver: suspend (List<String>) -> List<Note>,
    private val pendingPinnedNoteIds: () -> List<String>,
    private val generationParameterSettingsStore: GenerationParameterSettingsStore,
    private val capabilityPreferenceStore: CapabilityPreferenceStore? = null,
    private val localCustomFragmentStore: LocalCapabilityCustomFragmentStore? = null,
    private val capabilityEvidencePartition: () -> String = { "" },
    private val capabilityEvidenceIdentity: suspend (Provider, String, String) -> ai.oriveo.community.core.model.CapabilityEvidenceIdentity? = { _, _, _ -> null },
    // Remote switch context_reminder_enabled (default true): when off only the reminder is turned off, and the instructions section still goes into system.
    private val reminderEnabled: () -> Boolean = {
        MetadataClient.isRuntimeFeatureEnabled(REMINDER_FLAG_KEY, defaultValue = true)
    },
    // L3 recall index, rebuilt off the main thread only when the episodic item set changes.
    private val memoryRecallIndexCache: ai.oriveo.community.core.memory.MemoryRecallIndexCache =
        ai.oriveo.community.core.memory.MemoryRecallIndexCache(),
    // The connection's remembered tool_call verdict (the propose_memory / MCP tool predicate reads it).
    private val toolCallMemoryVerdict: (Provider, ai.oriveo.community.core.model.AIModel) -> Boolean? = { _, _ -> null },
    /**
     * Reads this conversation's search source and service on a background thread before every send (cached catalog
     * only); null = external search not wired, the request goes out unchanged (tests etc.).
     */
    private val webSearchSnapshot: (suspend (Provider, ai.oriveo.community.core.model.AIModel, String) -> ai.oriveo.community.feature.chat.modelcontrols.WebSearchPanelSnapshot?)? = null,
    /** Service binding for this turn's external search (called on a background thread); null = no external search. */
    private val externalSearchBinding: (suspend (ai.oriveo.community.feature.chat.modelcontrols.WebSearchPanelSnapshot, String) -> ai.oriveo.community.core.search.ExternalSearchBinding?)? = null,
) {
    /** The skill prompt and raw knowledge files of one send; null when the conversation has no skill attached. */
    private class SkillInputs(
        val skillPrompt: String,
        val knowledgeFiles: List<ContextKnowledgeFile>,
    )

    private suspend fun resolveSkillInputs(conversation: Conversation): SkillInputs? {
        val skill = conversation.skillId?.let { skillProvider(it) } ?: return null
        return SkillInputs(
            skillPrompt = skill.systemPrompt,
            knowledgeFiles = skill.knowledgeFiles.map { ContextKnowledgeFile(name = it.name, text = it.content) },
        )
    }

    /** The pinned note as the assembler sees it: an empty title falls back to the localized "Untitled". */
    private fun contextPinnedNote(note: Note): ContextPinnedNote =
        ContextPinnedNote(title = note.title.trim().ifBlank { untitledNoteFallback }, text = note.body)

    /**
     * The context request of a manual compaction, on the same basis as this conversation's chat send (memory switch, skill,
     * pinned notes); handed to ChatRepository.compactConversationNow.
     */
    suspend fun manualCompactionContext(
        conversation: Conversation,
        memoryItems: List<ai.oriveo.community.core.context.MemoryItem>,
    ): ai.oriveo.community.core.context.ChatContextRequest {
        val latestUserText = conversation.messages.lastOrNull { it.role == ai.oriveo.community.core.model.ChatRole.User }?.text.orEmpty()
        return chatContextRequest(conversation, memoryItems, resolveSkillInputs(conversation), attachments = null)
    }

    /**
     * The context request for the realtime session opening and the re-plan at turn boundaries: memory switch, skill and
     * pinned notes are the same as [manualCompactionContext].
     */
    suspend fun realtimeSessionContext(
        conversation: Conversation,
        memoryItems: List<ai.oriveo.community.core.context.MemoryItem>,
    ): ai.oriveo.community.core.context.ChatContextRequest =
        chatContextRequest(conversation, memoryItems, resolveSkillInputs(conversation), attachments = null)

    /**
     * request options of a manual compaction, same as the panel window (ContextCapViewModel.sendRequestOptions):
     * the chat send's max output with dormant values filtered, and its default funding preference (none).
     */
    fun manualCompactionRequestOptions(conversation: Conversation): ChatRequestOptions {
        val provider = providersProvider().firstOrNull { it.id == conversation.providerID } ?: return ChatRequestOptions()
        return ContextCapViewModel.sendRequestOptions(generationParameterSettingsStore, conversation, provider)
    }

    private suspend fun chatContextRequest(
        conversation: Conversation,
        memoryItems: List<ai.oriveo.community.core.context.MemoryItem>,
        skillInputs: SkillInputs?,
        attachments: List<Attachment>?,
        /** User message this turn answers; null = no L3 recall (manual compaction). */
        recallQuery: String? = null,
        delivery: ai.oriveo.community.core.context.ContextDelivery? = null,
    ): ai.oriveo.community.core.context.ChatContextRequest {
        val now = java.time.Instant.now()
        // Pinned notes: the conversation's pinnedNoteIds plus the ones pending while composing (a first message
        // whose conversation is not stored yet), de-duplicated and cut to the latest 3, then resolved to active notes
        // (deleted or missing ones are dropped).
        val pinnedNoteIds = (conversation.pinnedNoteIds + pendingPinnedNoteIds())
            .map(::normalizeUuid)
            .distinct()
            .takeLast(ChatNoteCoordinator.MAX_PINNED_NOTES)
        // getActiveByIds has no ORDER BY, so reorder by the original pinnedNoteIds order after resolving: the injection
        // order stays deterministic, and the notes dropped under a tight budget are the same as on the web.
        val resolvedPinned = if (pinnedNoteIds.isEmpty()) emptyList() else pinnedNotesResolver(pinnedNoteIds)
        val pinnedById = resolvedPinned.associateBy { normalizeUuid(it.id) }
        val pinnedNotes = pinnedNoteIds.mapNotNull { pinnedById[it] }
        return ai.oriveo.community.core.context.ChatContextRequest(
            conversation = ai.oriveo.community.core.context.ContextConversation(
                id = conversation.id,
                useMemory = conversation.useMemory,
                skillPrompt = skillInputs?.skillPrompt,
                instructions = conversation.instructions,
                pinnedNotes = pinnedNotes.filter { it.deletedAt == null }
                    .map(::contextPinnedNote),
                knowledgeFiles = skillInputs?.knowledgeFiles.orEmpty(),
                reminderEnabled = reminderEnabled(),
            ),
            memoryItems = ai.oriveo.community.core.context.ChatContextRequest.memoryItems(
                useMemory = conversation.useMemory,
                items = memoryItems,
                conversationId = conversation.id,
                folderId = conversation.folderID,
                now = now,
            ),
            recall = recallQuery?.let { query ->
                memoryRecallIndexCache.recall(
                    useMemory = conversation.useMemory,
                    items = memoryItems,
                    query = query,
                    conversationId = conversation.id,
                    folderId = conversation.folderID,
                    now = now,
                )
            }.orEmpty(),
            attachmentGuide = AttachmentInjector.SYSTEM_PROMPT_GUIDANCE.takeIf {
                attachments?.any { it.kind == ai.oriveo.community.core.model.AttachmentKind.File } == true
            },
            delivery = delivery,
        )
    }

    fun launchSend(
        conversation: Conversation,
        provider: Provider,
        modelId: String,
        text: String,
        memoryItems: List<ai.oriveo.community.core.context.MemoryItem>,
        existingMessages: List<ChatMessage>,
        attachments: List<Attachment>? = null,
        quoteContext: QuoteContext? = null,
        persistUserMessage: Boolean = true,
        appendToAssistant: ChatMessage? = null,
        userMessageAlreadyInHistory: Boolean = false,
        attemptKind: ai.oriveo.community.feature.chat.ContextConfirmAttempt = ai.oriveo.community.feature.chat.ContextConfirmAttempt.SEND,
        /** Callback after this send's user message is persisted (only the fresh-send entry passes it). */
        onUserMessageCreated: ((messageId: String, text: String) -> Unit)? = null,
        /** Non-null only for a fresh send in tool mode; the request then carries propose_memory. */
        memoryPropose: ai.oriveo.community.core.memory.MemoryProposeSendHook? = null,
        /** VOICE for a voice-conversation send; the request carries it to every leg of this turn. */
        delivery: ai.oriveo.community.core.context.ContextDelivery? = null,
        /** Internal: this conversation's search source was already read on a background thread ([searchSnapshot] is the result); do not read again. */
        searchSnapshotRead: Boolean = false,
        searchSnapshot: ai.oriveo.community.feature.chat.modelcontrols.WebSearchPanelSnapshot? = null,
        capturedEvidencePartitionId: String? = null,
    ) {
        // Capture the capability partition exactly once, up front. The identity producer may read
        // the epoch later on another thread, and re-reading it there would let a request built for
        // one partition be dispatched against another.
        val evidencePartitionId = capabilityEvidencePartition()
        // External search: read the source and service on a background thread first, then re-enter with the result;
        // the read does not change any of the existing ordering below.
        val readSnapshot = webSearchSnapshot
        val snapshotModel = ProviderSelectionSnapshot.selectedModel(provider, modelId)
        if (readSnapshot != null && !searchSnapshotRead && snapshotModel != null) {
            applicationScope.launch {
                val snapshot = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    runCatching { readSnapshot(provider, snapshotModel, conversation.id) }.getOrNull()
                }
                launchSend(
                    conversation = conversation, provider = provider, modelId = modelId, text = text, memoryItems = memoryItems,
                    existingMessages = existingMessages, attachments = attachments, quoteContext = quoteContext,
                    persistUserMessage = persistUserMessage, appendToAssistant = appendToAssistant,
                    userMessageAlreadyInHistory = userMessageAlreadyInHistory, attemptKind = attemptKind,
                    onUserMessageCreated = onUserMessageCreated, memoryPropose = memoryPropose, delivery = delivery,
                    searchSnapshotRead = true, searchSnapshot = snapshot, capturedEvidencePartitionId = evidencePartitionId,
                )
            }
            return
        }
        val evidencePartition = capturedEvidencePartitionId ?: evidencePartitionId
        val dispatch = resolveCapabilityDispatch(
            provider = provider,
            modelId = modelId,
            conversationId = conversation.id,
            skillId = conversation.skillId,
            appendToAssistant = appendToAssistant,
            webSearchSnapshot = searchSnapshot,
        )
        val selectedModel = dispatch.selectedModel
        val modelControlIdentity = dispatch.modelControlIdentity
        val resendSettingSource = dispatch.resendSettingSource
        val resendSettingOwner = dispatch.resendSettingOwner
        val resendSettingPointers = dispatch.resendSettingPointers
        val resendRecipeRef = dispatch.resendRecipeRef
        val dormantOwners = dispatch.dormantOwners
        val effectiveReasoningMode = dispatch.effectiveReasoningMode
        val effectiveWebSearchEnabled = dispatch.effectiveWebSearchEnabled
        val localCustomFragments = dispatch.localCustomFragments
        val additionalRequestBody = dispatch.additionalRequestBody
        val customTypedPreferences = dispatch.customTypedPreferences
        val customReasoningMode = dispatch.customReasoningMode

        // The whole send, including the 1-50ms window spent assembling the prompt, runs on the
        // application scope rather than the ViewModel's. Navigating away or closing the chat screen
        // mid-send would otherwise cancel it somewhere between prompt assembly and startStream, and
        // the message would be lost.
        applicationScope.launch {
            val externalSearch = externalSearchSend(conversation.id, dispatch, searchSnapshot, attemptKind)
            val skillInputs = resolveSkillInputs(conversation)
            // Every entry (send / retry / regenerate / edit-and-send / continue) hands the raw
            // inputs to the context assembler in ChatRepository; system is written only by the plan's transport input.
            // Recall queries the user message this turn answers; continue sends the fixed prompt,
            // so it looks up the last user message of the history instead.
            val recallQuery = if (appendToAssistant != null && text == ai.oriveo.community.core.context.ContextAssembler.CONTINUE_PROMPT) {
                existingMessages.lastOrNull { it.role == ai.oriveo.community.core.model.ChatRole.User }?.text.orEmpty()
            } else {
                text
            }
            val chatContext = chatContextRequest(conversation, memoryItems, skillInputs, attachments, recallQuery, delivery)
            // One identity per send: the request carrier and the search_memory tool predicate read the same value.
            val evidenceIdentity = capabilityEvidenceIdentity(provider, modelId, evidencePartition)
            val memorySearch = memorySearchTurn(
                conversation = conversation,
                provider = provider,
                modelId = modelId,
                model = selectedModel,
                memoryItems = memoryItems,
                isContinue = appendToAssistant != null && text == ai.oriveo.community.core.context.ContextAssembler.CONTINUE_PROMPT,
                webSearchEnabled = dispatch.outboundWebSearchEnabled,
                localIdentity = evidenceIdentity,
            )
            val baseRequestOptions = ChatRequestOptions(chatContext = chatContext)
            val requestOptions = baseRequestOptions.let { options ->
                // The outbound profile and the dormant check must read the same resolution. If the
                // set this side calls active differs from the set `GenerationParameterResolver.apply`
                // actually writes into the body, the panel says it kept N parameters while M went
                // out. Resolve once here and share it.
                val outboundGenerationProfile = selectedModel?.let {
                    ai.oriveo.community.core.provider.GenerationParameterAvailability.profile(provider, it)
                }
                val selectedRecipeRefs = MetadataClient.capabilityRuntimeRequest(
                    providerKind = provider.kind,
                    modelID = modelId,
                    finalTransport = modelControlIdentity?.finalTransport.orEmpty(),
                    webRequested = effectiveWebSearchEnabled,
                    reasoningMode = customReasoningMode,
                    typedWebIntent = "force".takeIf { customTypedPreferences.web == CapabilityWebPreference.Force },
                    typedReasoningIntent = customTypedPreferences.reasoningIntent,
                )?.selections.orEmpty().associate { it.capability to it.id }
                val recipeRejectedSettings = selectedRecipeRefs.mapNotNull { (owner, recipeRef) ->
                    resendSettingPointers.takeIf {
                        resendSettingSource == "provider_recipe" && resendSettingOwner == owner && resendRecipeRef == recipeRef
                    }?.let { owner to mapOf(recipeRef to it) }
                }.toMap()
                options.copy(
                    generationParameters = if ("generation" in dormantOwners) null else generationParameterSettingsStore.resolve(
                        transient = baseRequestOptions.generationParameters,
                        providerID = provider.id,
                        modelID = modelId,
                        conversationID = conversation.id,
                        profileFingerprint = selectedModel?.let {
                            ai.oriveo.community.core.model.GenerationParameterProfileFingerprint.make(provider, it)
                        },
                        // An explicit reasoning choice on the chip makes the connection-level
                        // reasoning defaults step aside as a group.
                        reasoningMode = effectiveReasoningMode,
                        // Dormant values are stored but never dispatched. Passing null when the
                        // profile cannot be resolved means "do not filter": `apply` still falls
                        // back to the profile it resolves itself, so filtering on a guess here
                        // would silently drop values the user really can send.
                        activeParameterIds = outboundGenerationProfile?.let {
                            ai.oriveo.community.core.provider.GenerationParameterLifecycleRules
                                .declaredParameterIdsForFinalDispatch(it)
                        },
                    )?.let { overrides ->
                        val rejectedRoots = recipeRejectedSettings["generation"]
                            ?.values?.flatten().orEmpty()
                            .map { it.removePrefix("/") }.toSet()
                        overrides.copy(values = overrides.values.filterKeys { it !in rejectedRoots })
                            .takeIf { it.values.isNotEmpty() }
                    },
                    activeModel = selectedModel?.copy(generationProfile = outboundGenerationProfile),
                    capabilityPreferences = customTypedPreferences,
                    localCustomFragment = localCustomFragments["generation"],
                    localCustomFragments = localCustomFragments,
                    additionalRequestBody = additionalRequestBody,
                    // Every provider carries the same identity carrier. It holds only opaque local
                    // generation/epoch/revision values and never reads or forwards a key; the real
                    // transport and endpoint are filled in by the dispatch layer, which fails
                    // closed when the scope is missing.
                    capabilityEvidenceIdentity = evidenceIdentity,
                    modelControlRuntimeIdentity = modelControlIdentity,
                    rejectedRecipeSettings = recipeRejectedSettings,
                    rejectedCustomSettings = resendSettingOwner?.takeIf { resendSettingSource == "custom" }
                        ?.let { owner -> mapOf(owner to resendSettingPointers) }.orEmpty(),
                    dormantCapabilityOwners = dormantOwners,
                    // "Resend without this parameter": omit it explicitly this time, regardless of whether the negative cache still matches.
                    omitParametersOnce = setOfNotNull(omitParameterOnceName(appendToAssistant?.customRetryWithoutFieldsCode)),
                )
            }.let { options ->
                // propose_memory is the last tool, tool_choice auto.
                if (memoryPropose == null) options else options.copy(
                    clientTools = options.clientTools + ai.oriveo.community.core.context.MemoryPropose.tool,
                    clientToolChoice = ai.oriveo.community.core.tools.ToolLoopToolChoice.Auto,
                )
            }.let { options ->
                // search_memory goes after propose_memory, tool_choice stays auto.
                if (memorySearch == null) options else options.copy(
                    clientTools = options.clientTools + ai.oriveo.community.core.context.MemorySearch.tool,
                    clientToolChoice = ai.oriveo.community.core.tools.ToolLoopToolChoice.Auto,
                )
            }.let { options ->
                // propose_memory is the last tool, tool_choice auto.
                if (memoryPropose == null) options else options.copy(
                    clientTools = options.clientTools + ai.oriveo.community.core.context.MemoryPropose.tool,
                    clientToolChoice = ai.oriveo.community.core.tools.ToolLoopToolChoice.Auto,
                )
            }.let { options ->
                // search_memory goes after propose_memory, tool_choice stays auto.
                if (memorySearch == null) options else options.copy(
                    clientTools = options.clientTools + ai.oriveo.community.core.context.MemorySearch.tool,
                    clientToolChoice = ai.oriveo.community.core.tools.ToolLoopToolChoice.Auto,
                )
            }
            chatStreamingManager.startStream(
                StreamRequest(
                    conversation = conversation,
                    text = text,
                    provider = provider,
                    modelID = modelId,
                    existingMessages = existingMessages,
                    attachments = attachments,
                    quoteContext = quoteContext,
                    reasoningMode = customReasoningMode,
                    webSearchEnabled = dispatch.outboundWebSearchEnabled,
                    requestOptions = requestOptions,
                    persistUserMessage = persistUserMessage,
                    userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                    appendToAssistant = appendToAssistant,
                    attemptKind = attemptKind,
                    onUserMessageCreated = onUserMessageCreated,
                    memoryPropose = memoryPropose,
                    memorySearch = memorySearch,
                    externalSearch = externalSearch,
                ),
            )
        }
    }

    /**
     * Builds the execution-side input when this turn takes an external search path (route.path, not
     * webSearchEnabled); any other path returns null and the request goes out unchanged. Continue only extends the
     * text and never searches.
     */
    private suspend fun externalSearchSend(
        conversationId: String,
        dispatch: CapabilityDispatch,
        snapshot: ai.oriveo.community.feature.chat.modelcontrols.WebSearchPanelSnapshot?,
        attemptKind: ai.oriveo.community.feature.chat.ContextConfirmAttempt,
    ): ai.oriveo.community.core.search.ExternalSearchSend? {
        // A "regenerate and search again" intent only applies to this one regeneration: take it first (cleared even when the path is not external)
        val reSearch = ai.oriveo.community.core.search.ExternalSearchReSearchIntents.take(conversationId) &&
            attemptKind == ai.oriveo.community.feature.chat.ContextConfirmAttempt.REGENERATE
        val state = dispatch.webSearchState ?: return null
        val path = state.route.path
        if (!ai.oriveo.community.core.search.isExternalSearchPath(path) || snapshot == null) return null
        val action = when (attemptKind) {
            ai.oriveo.community.feature.chat.ContextConfirmAttempt.CONTINUE,
            ai.oriveo.community.feature.chat.ContextConfirmAttempt.OVERFLOW_RECOVERY,
            ai.oriveo.community.feature.chat.ContextConfirmAttempt.TOOL_LOOP_LEG,
            -> return null
            ai.oriveo.community.feature.chat.ContextConfirmAttempt.REGENERATE,
            ai.oriveo.community.feature.chat.ContextConfirmAttempt.RETRY,
            -> if (reSearch) "re_search" else "regenerate"
            ai.oriveo.community.feature.chat.ContextConfirmAttempt.EDIT -> "edit_resend"
            ai.oriveo.community.feature.chat.ContextConfirmAttempt.SEND -> "send"
        }
        val serviceId = state.source.serviceId
        val binding = if (serviceId != null) {
            externalSearchBinding?.let { bind ->
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    runCatching { bind(snapshot, serviceId) }.getOrNull()
                }
            }
        } else {
            null
        }
        return ai.oriveo.community.core.search.ExternalSearchSend(
            path = path,
            toolCall = dispatch.webSearchToolCall ?: snapshot.toolCall,
            modelKey = dispatch.webSearchModelKey.orEmpty(),
            binding = binding,
            action = action,
        )
    }

    /**
     * a [ai.oriveo.community.core.memory.MemorySearchTurn] when this send carries search_memory
     * (purpose chat, memory on, client tools can ride the send, not degraded, at least one recallable L3 item); null otherwise.
     */
    @Suppress("LongParameterList")
    private suspend fun memorySearchTurn(
        conversation: Conversation,
        provider: Provider,
        modelId: String,
        model: ai.oriveo.community.core.model.AIModel?,
        memoryItems: List<ai.oriveo.community.core.context.MemoryItem>,
        isContinue: Boolean,
        webSearchEnabled: Boolean,
        localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity?,
    ): ai.oriveo.community.core.memory.MemorySearchTurn? {
        val hasL3 = conversation.useMemory && memoryItems.any { it.layer == ai.oriveo.community.core.context.MemoryLayer.EPISODIC }
        return ai.oriveo.community.core.memory.MemorySearchTurn.forSend(
            purpose = if (isContinue) {
                ai.oriveo.community.core.context.MemoryProposePurpose.CONTINUE
            } else {
                ai.oriveo.community.core.context.MemoryProposePurpose.CHAT
            },
            useMemory = conversation.useMemory,
            provider = provider,
            model = model,
            modelId = modelId,
            memoryVerdict = model?.let { toolCallMemoryVerdict(provider, it) },
            localIdentity = localIdentity,
            webSearchEnabled = webSearchEnabled,
            index = if (hasL3) memoryRecallIndexCache.index(memoryItems) else null,
            conversationId = conversation.id,
            folderId = conversation.folderID,
            now = java.time.Instant.now(),
            structuredOutput = ai.oriveo.community.core.memory.ProposeMemoryRuntime.structuredOutputActive(
                generationParameterSettingsStore, provider, model, modelId, conversation.id,
            ),
        )
    }

    /** The result of [resolveCapabilityDispatch]: every conclusion a send reaches about capability options. The outbound request and the pre-send check read the same one. */
    internal class CapabilityDispatch(
        val selectedModel: AIModel?,
        /** This send's combined web search conclusion (only when a search snapshot was read); execution reads route.path and source.serviceId. */
        val webSearchState: ai.oriveo.community.core.search.WebSearchState? = null,
        /** The catalog-evidence tool-call tri-state and modelKey from the same input as [webSearchState]. */
        val webSearchToolCall: String? = null,
        val webSearchModelKey: String? = null,
        val modelControlIdentity: ai.oriveo.community.core.provider.ModelControlRuntimeIdentity?,
        val resendSettingSource: String?,
        val resendSettingOwner: String?,
        val resendRecipeRef: String?,
        val resendSettingPointers: Set<String>,
        val dormantOwners: Set<String>,
        val effectiveReasoningMode: ReasoningMode,
        val effectiveWebSearchEnabled: Boolean,
        val localCustomFragments: Map<String, String>,
        val customOwners: Set<String>,
        val additionalRequestBody: String?,
        val customTypedPreferences: CapabilityPreferenceValues,
        val customReasoningMode: ReasoningMode,
    ) {
        /** The web search switch handed to the service: when a custom fragment owns web search, the typed switch no longer goes out. */
        val outboundWebSearchEnabled: Boolean get() = effectiveWebSearchEnabled && "web" !in customOwners
    }

    /**
     * Resolves the value of web search, reasoning and the other capability options for one send. Reads only in-memory
     * preferences and caches; it neither suspends nor touches the network.
     *
     * Split out of [launchSend] so the composer's pre-send check gets exactly the values the outbound request will
     * use (see [outboundRouteOptions]) instead of deriving them a second time.
     */
    internal fun resolveCapabilityDispatch(
        provider: Provider,
        modelId: String,
        conversationId: String,
        skillId: String?,
        appendToAssistant: ChatMessage?,
        /** This conversation's search source and service, read fresh for this send; null = not read (request unchanged). */
        webSearchSnapshot: ai.oriveo.community.feature.chat.modelcontrols.WebSearchPanelSnapshot? = null,
    ): CapabilityDispatch {
        val selectedModel = ProviderSelectionSnapshot.selectedModel(provider, modelId)
        val modelControlIdentity = selectedModel?.let {
            ModelControlRuntimeIdentityResolver.resolve(provider, it)
        }
        val omitSettingMarker = appendToAssistant?.customRetryWithoutFieldsCode
            ?.split(':')
            ?.takeIf { parts -> parts.size == 5 && parts[0] == "omit_capability_setting_once" }
        val omitSettingSource = omitSettingMarker?.get(1)?.takeIf { it in setOf("custom", "provider_recipe") }
        val omitSettingOwner = omitSettingMarker?.get(2)?.takeIf { it in setOf("web", "reasoning", "generation") }
        fun decodeMarkerPart(encoded: String): String? = runCatching {
            String(java.util.Base64.getUrlDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull()
        val omitRecipeRef = omitSettingMarker?.get(3)?.takeUnless { it == "-" }?.let(::decodeMarkerPart)
        val omitSettingPointers = omitSettingMarker?.get(4)?.let { encoded ->
            runCatching {
                String(java.util.Base64.getUrlDecoder().decode(encoded), Charsets.UTF_8)
                    .split('\u001f')
                    .filter { it.startsWith('/') && it.length <= 160 }
                    .toSet()
                    .takeIf { it.isNotEmpty() }
            }.getOrNull()
        }.orEmpty()
        fun cachedRejectedSettings(owner: String, source: String, recipeRef: String? = null): Set<String> =
            modelControlIdentity
                ?.let { ModelControlRejectionCache.rejectedSettings(it, owner, source, recipeRef = recipeRef) }
                .orEmpty()
        val omitSettingCacheMatches = omitSettingSource != null && omitSettingOwner != null &&
            omitSettingPointers.isNotEmpty() &&
            (omitSettingSource != "provider_recipe" || !omitRecipeRef.isNullOrBlank()) &&
            cachedRejectedSettings(omitSettingOwner, omitSettingSource, omitRecipeRef).containsAll(omitSettingPointers)
        val resendSettingSource = omitSettingSource.takeIf { omitSettingCacheMatches }
        val resendSettingOwner = omitSettingOwner.takeIf { omitSettingCacheMatches }
        val resendRecipeRef = omitRecipeRef.takeIf { omitSettingCacheMatches }
        val resendSettingPointers = omitSettingPointers.takeIf { omitSettingCacheMatches }.orEmpty()
        // One-shot way out after a local rejection or an upstream rejection of the additional request body:
        // omit it for this request only, without touching what is stored.
        val omitLocalOwnerOnce = appendToAssistant?.customRetryWithoutFieldsCode
            ?.let(::omitLocalFieldsOnceOwner)
        // Same resolution the composer chip and the model-control panel use. What goes out on the
        // wire and what the UI shows must always come from one conclusion, never two.
        val relayWebDefault = selectedModel?.let { ai.oriveo.community.core.provider.relay.RelayWebChat.of(provider, it)?.defaultPreference }
        var webSearchState: ai.oriveo.community.core.search.WebSearchState? = null
        var webSearchModelKey: String? = null
        val storedTypedPreferences = capabilityPreferenceStore?.resolvedForRequest(
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = modelControlIdentity?.canonicalModelId ?: modelId,
            conversationID = conversationId,
            skillID = skillId,
            transportIdentity = modelControlIdentity?.storageIdentity,
            legacyModelID = modelControlIdentity?.legacyModelId,
            // Default layer when relay web search is unset: the first-send protocol has a stored fragment -> on.
            webDefault = relayWebDefault,
        )?.let { values ->
            // The relay web switch reads the fixed identity, the same one as the composer; the thinking tier still uses the protocol-bearing identity.
            val relayWebIdentity = selectedModel?.let { ai.oriveo.community.core.provider.RelayWebPreferenceIdentity.resolve(provider, it) }
                ?: return@let values
            values.copy(
                web = capabilityPreferenceStore?.resolvedForRequest(
                    providerID = provider.id,
                    providerKind = provider.kind,
                    modelID = relayWebIdentity.canonicalModelId,
                    conversationID = conversationId,
                    skillID = skillId,
                    transportIdentity = relayWebIdentity.storageIdentity,
                    webDefault = relayWebDefault,
                )?.web ?: values.web,
            )
        }?.let { values ->
            // External search: the same combined entry as the panel and the composer preview. Native / relay web
            // fields are dropped only when nativeFieldsSuppressed; otherwise the request goes out exactly as before.
            val snapshot = webSearchSnapshot ?: return@let values
            val model = selectedModel ?: return@let values
            val modelKey = ai.oriveo.community.feature.chat.modelcontrols.webSearchModelKey(provider, model)
            val state = ai.oriveo.community.core.search.resolveWebSearchState(
                snapshot.stateInput(
                    facts = ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput.webSearchFactsForSend(
                        provider, model, modelControlIdentity?.finalTransport, values.web, modelControlIdentity, snapshot.toolCall,
                    ),
                    // The panel can persist iff there is a runtime identity (same premise as the panel; without one the per-conversation choice does not apply)
                    panelWritable = modelControlIdentity != null,
                    webOn = ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput.webSearchOn(
                        values.web,
                        ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput.relayWeb(provider, model, webPreference = values.web),
                    ),
                    modelKey = modelKey,
                ),
            )
            webSearchState = state
            webSearchModelKey = modelKey
            if (state.nativeFieldsSuppressed) values.copy(web = CapabilityWebPreference.Off) else values
        } ?: CapabilityPreferenceValues()
        // A custom fragment goes out on exactly one condition: this owner's custom entry is
        // enabled right now. Schema availability filtering already happens inside
        // `fragmentsByOwner`, so there is deliberately no second `capabilityCustomFragmentAvailable`
        // check here. Writing that rule in two places is exactly the shape of the bug where the UI
        // claims a custom fragment is in charge while the request quietly dropped it.
        val storedCustomFragments = if (modelControlIdentity != null) {
            localCustomFragmentStore?.fragmentsByOwner(
                provider.id,
                modelControlIdentity.canonicalModelId,
                conversationId,
                modelControlIdentity.storageIdentity,
                // Sending is the one discrete event that must not miss a recipe version change: if
                // the user's custom fields do not follow the new version, this message silently
                // goes out without a JSON block they believe is still in effect.
                forwardPort = LocalCapabilityCustomFragmentStore.ForwardPortContext(
                    providerKind = provider.kind,
                    schemaModelID = modelId,
                    activeProfile = selectedModel.generationProfile,
                ),
                legacyModelID = modelControlIdentity.legacyModelId,
            ).orEmpty()
        } else emptyMap()
        val storedReasoningMode = ReasoningMode.fromIntent(storedTypedPreferences.reasoningIntent)
        val storedWebRequested = storedTypedPreferences.web != CapabilityWebPreference.Off
        val currentRecipeSelections = MetadataClient.capabilityRuntimeRequest(
            providerKind = provider.kind,
            modelID = modelId,
            finalTransport = modelControlIdentity?.finalTransport.orEmpty(),
            webRequested = storedWebRequested,
            reasoningMode = storedReasoningMode,
            typedWebIntent = "force".takeIf { storedTypedPreferences.web == CapabilityWebPreference.Force },
            typedReasoningIntent = storedTypedPreferences.reasoningIntent,
        )?.selections.orEmpty()
        val currentRecipeRefs = currentRecipeSelections.associate { it.capability to it.id }
        val explicitRecipeOwner = resendSettingOwner?.takeIf {
            resendSettingSource == "provider_recipe" && resendRecipeRef != null && resendSettingPointers.isNotEmpty()
        }
        // When the selected reasoning tier is rejected, settle on the nearest tier (downwards first, then
        // upwards); an explicit resend keeps its original tier and does not settle. An untiered rejection
        // (legacy entry / automatic tier) and a rejection of every tier still make the whole group dormant.
        val storedReasoningTier = storedTypedPreferences.reasoningIntent
            ?.takeIf { it.isNotBlank() && it != "automatic" && it != "off" }
        val reasoningFallbackTier = currentRecipeSelections.firstOrNull { it.capability == "reasoning" }
            ?.takeIf {
                storedReasoningTier != null && modelControlIdentity != null && explicitRecipeOwner != "reasoning" &&
                    "reasoning" !in storedCustomFragments
            }
            ?.let { selection ->
                val rejections = ModelControlRejectionCache.tierRejections(
                    modelControlIdentity!!, "reasoning", "provider_recipe", selection.id,
                )
                if (rejections.untiered) null else ModelControlRejectionCache.fallbackTier(
                    storedReasoningTier!!, selection.availableIntents.orEmpty(), rejections.tiers,
                )
            }
        // A tiered rejection makes the group dormant only when exactly that tier is selected; an untiered rejection still makes the whole group dormant.
        val normalRejectedRecipeOwners = currentRecipeRefs.mapNotNull { (owner, recipeRef) ->
            owner.takeIf {
                owner !in storedCustomFragments && modelControlIdentity != null &&
                    (owner != "reasoning" || reasoningFallbackTier == null) &&
                    ModelControlRejectionCache.blocksSelection(
                        modelControlIdentity,
                        owner,
                        "provider_recipe",
                        recipeRef,
                        selectedTier = storedTypedPreferences.reasoningIntent.takeIf { owner == "reasoning" },
                    )
            }
        }.toSet()
        val normalRejectedCustomOwners = storedCustomFragments.keys.filterTo(linkedSetOf()) { owner ->
            cachedRejectedSettings(owner, "custom").isNotEmpty()
        }
        val dormantOwners = (normalRejectedRecipeOwners + normalRejectedCustomOwners) - setOfNotNull(explicitRecipeOwner)
        val typedPreferences = storedTypedPreferences.copy(
            web = if ("web" in dormantOwners) CapabilityWebPreference.Off else storedTypedPreferences.web,
            reasoningIntent = reasoningFallbackTier ?: storedTypedPreferences.reasoningIntent,
        )
        val effectiveReasoningMode = ReasoningMode.fromIntent(typedPreferences.reasoningIntent)
        val requestedWebSearchEnabled = when (typedPreferences.web) {
            CapabilityWebPreference.Off -> false
            CapabilityWebPreference.Automatic, CapabilityWebPreference.Force, CapabilityWebPreference.Custom -> true
        }
        val effectiveWebSearchEnabled = requestedWebSearchEnabled
        val dispatchedTypedPreferences = if (effectiveWebSearchEnabled) typedPreferences else typedPreferences.copy(
            web = CapabilityWebPreference.Off,
        )
        // The raw fragment is read only into this process-local request carrier; it is never
        // persisted or logged. An explicit recovery retry carries a one-shot marker on the
        // replacement assistant message, which suppresses every custom owner for that one request
        // without touching what the user has stored.
        val localCustomFragments = storedCustomFragments
            .mapNotNull { (owner, raw) ->
                // The additional request body now owns the outbound path of the legacy generation custom
                // field (stored values are migrated), so it is not sent from here any more.
                (owner to raw).takeIf {
                    owner != "generation" && owner !in dormantOwners && resendSettingOwner != owner &&
                        omitLocalOwnerOnce != owner
                }
            }
            .toMap()
        val customOwners = localCustomFragments.keys
        val additionalRequestBody = if (omitLocalOwnerOnce != ai.oriveo.community.core.provider.AdditionalRequestBody.OWNER) {
            localCustomFragmentStore?.outboundAdditionalBody(
                provider.id,
                modelControlIdentity?.canonicalModelId ?: modelId,
                conversationId,
                legacyModelID = modelControlIdentity?.legacyModelId,
            )
        } else null
        val customTypedPreferences = dispatchedTypedPreferences.copy(
            web = if ("web" in customOwners) CapabilityWebPreference.Off else dispatchedTypedPreferences.web,
            reasoningIntent = if ("reasoning" in customOwners) null else dispatchedTypedPreferences.reasoningIntent,
        )
        val customReasoningMode = if ("reasoning" in customOwners) ReasoningMode.Automatic else effectiveReasoningMode
        return CapabilityDispatch(
            selectedModel = selectedModel,
            webSearchState = webSearchState,
            webSearchToolCall = webSearchSnapshot?.toolCall,
            webSearchModelKey = webSearchModelKey,
            modelControlIdentity = modelControlIdentity,
            resendSettingSource = resendSettingSource,
            resendSettingOwner = resendSettingOwner,
            resendRecipeRef = resendRecipeRef,
            resendSettingPointers = resendSettingPointers,
            dormantOwners = dormantOwners,
            effectiveReasoningMode = effectiveReasoningMode,
            effectiveWebSearchEnabled = effectiveWebSearchEnabled,
            localCustomFragments = localCustomFragments,
            customOwners = customOwners,
            additionalRequestBody = additionalRequestBody,
            customTypedPreferences = customTypedPreferences,
            customReasoningMode = customReasoningMode,
        )
    }

    /**
     * The reasoning mode and web search switch the service would receive if the message in the composer were sent
     * now. They come from the same resolution [launchSend] hands to [ChatStreamingManager].
     *
     * @param conversationId id of the existing conversation; pass the draft session id when none exists yet (the
     *   preferences move over unchanged when the conversation is created).
     */
    fun outboundRouteOptions(
        provider: Provider,
        modelId: String,
        conversationId: String,
        skillId: String?,
        /** This conversation's search source read on a background thread for this preview (same as the send); null = not read. */
        webSearchSnapshot: ai.oriveo.community.feature.chat.modelcontrols.WebSearchPanelSnapshot? = null,
    ): Pair<ReasoningMode, Boolean> {
        val dispatch = resolveCapabilityDispatch(
            provider = provider,
            modelId = modelId,
            conversationId = conversationId,
            skillId = skillId,
            appendToAssistant = null,
            webSearchSnapshot = webSearchSnapshot,
        )
        return dispatch.customReasoningMode to dispatch.outboundWebSearchEnabled
    }

    /**
     * The options the pre-send check works from: the two values of [outboundRouteOptions], plus whether the tool loop
     * may take over.
     *
     * Whether the tool loop takes over is only decided after the send, because the MCP tool plan has to ask this
     * connection's tool-call ruling. All the composer knows is whether MCP servers are enabled.
     */
    suspend fun attachmentSendOptions(
        provider: Provider,
        modelId: String,
        conversationId: String,
        skillId: String?,
        mcpEnabledServerCount: Int,
    ): ai.oriveo.community.core.provider.AttachmentSendPreflight.SendOptions {
        // Same background read as the send, so the preview's "will it search the web" matches the real request
        val reader = webSearchSnapshot
        val model = ProviderSelectionSnapshot.selectedModel(provider, modelId)
        val snapshot = if (reader != null && model != null) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                runCatching { reader(provider, model, conversationId) }.getOrNull()
            }
        } else {
            null
        }
        val (reasoningMode, webSearchEnabled) = outboundRouteOptions(provider, modelId, conversationId, skillId, snapshot)
        return ai.oriveo.community.core.provider.AttachmentSendPreflight.SendOptions(
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            toolLoopPossible = mcpEnabledServerCount > 0,
        )
    }

    companion object {
        const val REMINDER_FLAG_KEY: String = "context_reminder_enabled"
    }
}

internal const val OMIT_LOCAL_FIELDS_ONCE_PREFIX = "omit_local_fields_once:"

internal const val OMIT_PARAMETER_ONCE_PREFIX = "omit_parameter_once:"

/** The parameter name inside a "resend without this parameter" marker; only names on the parameter-gate list are accepted, anything else is treated as no marker. */
internal fun omitParameterOnceName(marker: String?): String? =
    marker?.takeIf { it.startsWith(OMIT_PARAMETER_ONCE_PREFIX) }
        ?.removePrefix(OMIT_PARAMETER_ONCE_PREFIX)
        ?.takeIf { it in ai.oriveo.community.core.capability.InputRejectionFlow.GATED_PARAMETERS }

/** Only these three owners are recognized in a local recovery marker; any other value counts as no marker. */
internal fun omitLocalFieldsOnceOwner(marker: String): String? =
    marker.removePrefix(OMIT_LOCAL_FIELDS_ONCE_PREFIX).takeIf {
        marker.startsWith(OMIT_LOCAL_FIELDS_ONCE_PREFIX) &&
            it in setOf(ai.oriveo.community.core.provider.AdditionalRequestBody.OWNER, "web", "reasoning")
    }

