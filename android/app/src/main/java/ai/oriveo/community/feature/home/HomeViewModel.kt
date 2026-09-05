package ai.oriveo.community.feature.home

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.FolderRepository
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderIssueInfo
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.model.selectHomeSkills
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.util.TextShareLauncher
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.util.Calendar

/** Home list, folders, notes, and the last-used model. */
@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class HomeViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
    private val providerRepository: ProviderRepository,
    private val conversationRepository: ConversationRepository,
    private val folderRepository: FolderRepository,
    private val noteRepository: NoteRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val skillRepository: SkillRepository,
    private val chatStreamingManager: ChatStreamingManager,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val generationParameterSettingsStore: GenerationParameterSettingsStore? = null,
    private val capabilityPreferenceStore: ai.oriveo.community.core.model.CapabilityPreferenceStore? = null,
    private val localCustomFragmentStore: LocalCapabilityCustomFragmentStore? = null,
) : ViewModel() {

    val streamingConversationIds: StateFlow<Set<String>> = chatStreamingManager.streamingConversationIds

    private var hasTriggeredInitialHomeLoadRefresh: Boolean = false
    private val providersLoaded = MutableStateFlow(false)
    private val conversationsLoaded = MutableStateFlow(false)
    private val foldersLoaded = MutableStateFlow(false)
    private val earlierDisplayCount = MutableStateFlow(HOME_EARLIER_PAGE_SIZE)
    private val recentConversationStartMillis = computeRecentConversationStartMillis()

    val providers: StateFlow<List<Provider>> = providerRepository.observeAll()
        .onEach { providersLoaded.value = true }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val folders: StateFlow<List<Folder>> = folderRepository.observeAll()
        .onEach { foldersLoaded.value = true }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val homeSkills: StateFlow<List<Skill>> = skillRepository.observeAllSkills()
        .map { selectHomeSkills(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    
    val activeNoteCount: StateFlow<Int> = noteRepository.observeActive()
        .map { it.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    
    val latestNoteTitle: StateFlow<String?> = noteRepository.observeActive()
        .map { notes -> notes.firstOrNull()?.title?.takeIf { it.isNotBlank() } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    
    val allConversations: StateFlow<List<Conversation>> = conversationRepository.observeAll()
        .onEach { conversationsLoaded.value = true }
        .map { items -> items.filter { !it.isDraft || it.messageCount > 0 } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    
    val conflictCopies: StateFlow<List<Conversation>> = MutableStateFlow(emptyList())

    
    val pinnedConversationIds: StateFlow<List<String>> = appPreferencesRepository.pinnedConversationIds
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    
    val pinnedConversations: StateFlow<List<Conversation>> = combine(
        pinnedConversationIds,
        allConversations,
    ) { ids, all ->
        if (ids.isEmpty()) {
            emptyList()
        } else {
            val byId = all.associateBy { it.id }
            ids.mapNotNull { byId[it] }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val homeSections: StateFlow<List<HomeConversationSection>> = combine(
        earlierDisplayCount.flatMapLatest { limit ->
            conversationRepository.observeUngroupedHomeConversations(
                recentStartMillis = recentConversationStartMillis,
                earlierLimit = limit,
            )
        },
        conversationRepository.observeUngroupedEarlierCount(recentConversationStartMillis),
        pinnedConversationIds,
    ) { visibleConversations, earlierTotalCount, pinnedIds ->
        
        
        val pinnedSet = pinnedIds.toHashSet()
        buildHomeConversationSections(
            conversations = visibleConversations.filter {
                (!it.isDraft || it.messageCount > 0) && !pinnedSet.contains(it.id)
            },
            earlierTotalCount = earlierTotalCount,
        )
    }
        
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val initialContentLoaded: StateFlow<Boolean> = combine(
        providersLoaded,
        conversationsLoaded,
        foldersLoaded,
    ) { hasProviders, hasConversations, hasFolders ->
        hasProviders && hasConversations && hasFolders
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    

    val searchQuery = MutableStateFlow("")

    
    val searchResults: StateFlow<List<Conversation>> = searchQuery
        .debounce(250L)
        .distinctUntilChanged()
        .flatMapLatest { query ->
            if (query.isBlank()) {
                flowOf(emptyList())
            } else {
                conversationRepository.search(query)
            }
        }
        .map { items ->
            items.filter { !it.isDraft || it.messageCount > 0 }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    

    val lastUsedModelRef: StateFlow<LastUsedModelRef?> = appPreferencesRepository.lastUsedModelRef
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    
    private var lastAutoRefreshTime: Long = 0
    private val autoRefreshThrottleMs = 60_000L // 60 seconds
    var expandedFolderIds by mutableStateOf(emptySet<String>())
        private set

    

    
    var heroText: String by mutableStateOf("")

    
    var isSendingFromHero: Boolean by mutableStateOf(false)
        private set

    init {
        viewModelScope.launch {
            folders.collect { loadedFolders ->
                val validIds = loadedFolders.map { it.id }.toSet()
                expandedFolderIds = expandedFolderIds.filter(validIds::contains).toSet()
            }
        }
        
        viewModelScope.launch {
            skillRepository.refreshAll()
        }
        
        viewModelScope.launch(ioDispatcher) {
            initialContentLoaded.first { it }
            folderRepository.migrateColorTags()
        }
    }

    
    data class ActiveModel(
        val provider: Provider,
        val model: AIModel,
    )

    data class ActiveModelState(
        val activeModel: ActiveModel?,
        val providerIssue: ProviderIssueInfo?,
    )

    val greetingName: StateFlow<String> = MutableStateFlow("")

    
    val activeModelState: StateFlow<ActiveModelState> = combine(
        providers,
        lastUsedModelRef,
        CapabilityEvidenceObservationBridge.revision,
    ) { provs, ref, _ ->
        val resolved = resolveActiveModel(provs, ref)
        val active = resolved?.let { ActiveModel(it.provider, it.model) }
        ActiveModelState(activeModel = active, providerIssue = null)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ActiveModelState(null, null))

    
    fun resolveActiveModel(providers: List<Provider>): ActiveModel? {
        val resolved = resolveActiveModel(providers, lastUsedModelRef.value) ?: return null
        return ActiveModel(
            provider = resolved.provider,
            model = resolved.model,
        )
    }

    
    fun refreshActiveProviderIfNeeded() {
        val providerList = providers.value
        val active = resolveActiveModel(providerList) ?: return
        val provider = active.provider

        if (!provider.kind.supportsAutomaticSync) return

        if (provider.lastCheckedAt != null && System.currentTimeMillis() - provider.lastCheckedAt < 6 * 60 * 60 * 1000L) {
            return
        }

        val now = System.currentTimeMillis()
        if (now - lastAutoRefreshTime < autoRefreshThrottleMs) return
        lastAutoRefreshTime = now

        viewModelScope.launch {
            try {
                providerRepository.resyncProvider(provider.id)
            } catch (_: Exception) {
                
            }
        }
    }

    fun refreshActiveProviderIfNeededOnInitialLoad() {
        if (hasTriggeredInitialHomeLoadRefresh) return
        hasTriggeredInitialHomeLoadRefresh = true
        refreshActiveProviderIfNeeded()
    }

    

    var isEditing by mutableStateOf(false)
    var selectedIds by mutableStateOf(emptySet<String>())
        private set

    fun toggleSelection(id: String) {
        selectedIds = if (selectedIds.contains(id)) {
            selectedIds - id
        } else {
            selectedIds + id
        }
    }

    fun selectAll(conversations: List<Conversation>) {
        selectedIds = conversations.map { it.id }.toSet()
    }

    fun toggleSectionSelection(conversations: List<Conversation>) {
        val ids = conversations.map { it.id }.toSet()
        selectedIds = if (ids.isNotEmpty() && ids.all(selectedIds::contains)) {
            selectedIds - ids
        } else {
            selectedIds + ids
        }
    }

    fun areAllSelected(conversations: List<Conversation>): Boolean {
        val ids = conversations.map { it.id }.toSet()
        return ids.isNotEmpty() && ids.all(selectedIds::contains)
    }

    fun deselectAll() {
        selectedIds = emptySet()
    }

    fun exitEditMode() {
        isEditing = false
        selectedIds = emptySet()
    }

    fun startEditingWithSelection(conversationId: String) {
        isEditing = true
        isSearching = false
        searchQuery.value = ""
        selectedIds = setOf(conversationId)
    }

    fun toggleFolderExpansion(folderId: String) {
        expandedFolderIds = if (expandedFolderIds.contains(folderId)) {
            expandedFolderIds - folderId
        } else {
            expandedFolderIds + folderId
        }
    }

    fun isFolderExpanded(folderId: String): Boolean = expandedFolderIds.contains(folderId)

    

    var isSearching by mutableStateOf(false)

    fun setSearchQuery(query: String) {
        searchQuery.value = query
    }

    fun exitSearch() {
        isSearching = false
        searchQuery.value = ""
    }

    fun loadMoreEarlier() {
        earlierDisplayCount.value += HOME_EARLIER_PAGE_SIZE
    }

    fun togglePinConversation(conversationId: String) {
        viewModelScope.launch {
            val currentIds = appPreferencesRepository.getPinnedConversationIds()
            val updatedIds = if (currentIds.contains(conversationId)) {
                currentIds.filterNot { it == conversationId }
            } else {
                currentIds + conversationId
            }
            appPreferencesRepository.setPinnedConversationIds(updatedIds)
        }
    }

    fun isPinned(conversationId: String): Boolean =
        pinnedConversationIds.value.contains(conversationId)

    fun deleteConversation(id: String) {
        
        
        chatStreamingManager.stopStream(id)
        viewModelScope.launch {
            try {
                conversationRepository.delete(id)
                generationParameterSettingsStore?.removeScopes(conversationID = id)
                capabilityPreferenceStore?.removeScopes(conversationID = id)
                localCustomFragmentStore?.removeScopes(conversationID = id)
            } catch (_: Exception) { }
        }
    }

    
    fun copyConflictCopyAsNewConversation(
        conversation: Conversation,
        onCreated: (String) -> Unit = {},
    ) {
    }

    
    fun cleanupAllConflictCopies() {
        val ids = conflictCopies.value.map { it.id }
        if (ids.isEmpty()) return
        viewModelScope.launch {
            try {
                conversationRepository.deleteMultiple(ids)
                ids.forEach { generationParameterSettingsStore?.removeScopes(conversationID = it) }
                ids.forEach { capabilityPreferenceStore?.removeScopes(conversationID = it) }
                ids.forEach { localCustomFragmentStore?.removeScopes(conversationID = it) }
            } catch (_: Exception) {
            }
        }
    }


    fun deleteSelectedConversations() {
        val ids = selectedIds.toList()
        
        ids.forEach { chatStreamingManager.stopStream(it) }
        exitEditMode()
        viewModelScope.launch {
            try {
                conversationRepository.deleteMultiple(ids)
                ids.forEach { generationParameterSettingsStore?.removeScopes(conversationID = it) }
                ids.forEach { capabilityPreferenceStore?.removeScopes(conversationID = it) }
                ids.forEach { localCustomFragmentStore?.removeScopes(conversationID = it) }
            } catch (_: Exception) {
            }
        }
    }

    var showSkillProviderPrompt by mutableStateOf(false)
        private set

    fun dismissSkillProviderPrompt() {
        showSkillProviderPrompt = false
    }

    fun createFolder(name: String, onCreated: ((Folder) -> Unit)? = null) {
        viewModelScope.launch {
            val folder = folderRepository.create(name) ?: return@launch
            expandedFolderIds = expandedFolderIds + folder.id
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.folder_created, listOf(folder.name)),
                ),
            )
            onCreated?.invoke(folder)
        }
    }

    fun renameFolder(id: String, newName: String) {
        viewModelScope.launch {
            folderRepository.rename(id, newName)
        }
    }

    fun updateFolderColor(id: String, colorTag: String) {
        viewModelScope.launch {
            folderRepository.updateColor(id, colorTag)
        }
    }

    fun deleteFolder(id: String) {
        expandedFolderIds = expandedFolderIds - id
        viewModelScope.launch {
            folderRepository.delete(id)
            globalSnackbarManager.show(
                GlobalSnackbarMessage(message = UiText.Resource(R.string.folder_deleted)),
            )
        }
    }

    fun moveConversationToFolder(conversationId: String, folderID: String?) {
        viewModelScope.launch {
            conversationRepository.moveToFolder(conversationId, folderID)
            showMoveToFolderSnackbar(1, folderID)
        }
    }

    fun moveSelectedConversationsToFolder(folderID: String?) {
        val ids = selectedIds.toList()
        if (ids.isEmpty()) return
        exitEditMode()
        moveConversationIdsToFolder(ids, folderID)
    }

    fun moveConversationIdsToFolder(ids: List<String>, folderID: String?, clearSelection: Boolean = false) {
        if (ids.isEmpty()) return
        if (clearSelection) {
            exitEditMode()
        }
        viewModelScope.launch {
            conversationRepository.batchMoveToFolder(ids, folderID)
            showMoveToFolderSnackbar(ids.size, folderID)
        }
    }

    fun createConversationInFolder(folderID: String, onCreated: (String) -> Unit) {
        val active = activeModelState.value.activeModel ?: return
        viewModelScope.launch {
            val conversation = conversationRepository.createDraft(
                providerID = active.provider.id,
                providerKind = active.provider.kind,
                modelID = ModelSelectionUtils.preferredStoredModelIdentifier(active.model),
                folderID = folderID,
            )
            expandedFolderIds = expandedFolderIds + folderID
            onCreated(conversation.id)
        }
    }

    fun renameConversation(id: String, newTitle: String) {
        if (newTitle.isBlank()) return
        viewModelScope.launch {
            conversationRepository.rename(id, newTitle.trim())
        }
    }

    
    fun copyLastMessage(conversationId: String, context: Context) {
        viewModelScope.launch {
            val conversation = conversationRepository.getWithMessages(conversationId) ?: return@launch
            val lastMsg = conversation.messages.lastOrNull() ?: return@launch
            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.app_name), lastMsg.text))
        }
    }

    fun shareConversation(conversationId: String, context: Context) {
        viewModelScope.launch {
            val conversation = conversationRepository.getWithMessages(conversationId) ?: return@launch
            val text = buildString {
                appendLine(conversation.title)
                appendLine()
                conversation.messages.forEach { msg ->
                    appendLine("${msg.role.name}: ${msg.text}")
                    appendLine()
                }
            }
            val fileName = conversation.title
                .takeIf { it.isNotBlank() }
                ?: context.getString(R.string.export_conversation)
            TextShareLauncher.shareTextFile(
                context = context,
                text = text,
                fileName = "$fileName.txt",
                mimeType = "text/plain",
            ).onFailure {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.error_generic_message),
                        style = GlobalToastStyle.Error,
                    ),
                )
            }
        }
    }

    

    fun setActiveModel(providerId: String, modelId: String) {
        
        
        appPreferencesRepository.primeLastUsedModel(providerId, modelId)
        viewModelScope.launch {
            val provider = providerRepository.getById(providerId)
            val selection = ProviderSelectionSnapshot.persistedSelection(provider, modelId)
            if (selection?.model != null) {
                appPreferencesRepository.setLastUsedModel(providerId, selection.model)
            } else {
                appPreferencesRepository.setLastUsedModel(
                    providerId = providerId,
                    modelId = selection?.storedModelId ?: ModelSelectionUtils.resolvedId(modelId),
                )
            }
        }
    }

    
    suspend fun ensureActiveModelWithFreeFallback(
        onMissingProvider: () -> Unit,
    ): ActiveModel? {
        
        
        appPreferencesRepository.lastUsedModelRefSnapshot?.let { ref ->
            resolveActiveModel(providers.value, ref)?.let { return ActiveModel(it.provider, it.model) }
        }
        
        activeModelState.value.activeModel?.let { return it }

        
        val current = providers.value
        val firstUsable = current.firstOrNull {
            it.status !is ProviderConnectionState.Issue && it.models.isNotEmpty()
        }
        if (firstUsable != null) {
            val defaultModel = ProviderSelectionSnapshot.defaultModel(firstUsable)
            if (defaultModel != null) {
                appPreferencesRepository.setLastUsedModel(firstUsable.id, defaultModel)
                return ActiveModel(provider = firstUsable, model = defaultModel)
            }
        }

        


        
        onMissingProvider()
        return null
    }

    
    fun sendFromHero(
        onConversationCreated: (String) -> Unit,
        onConversationCreatedAutoSend: (String) -> Unit,
        onMissingProvider: () -> Unit,
    ) {
        if (isSendingFromHero) return
        val trimmed = heroText.trim()

        viewModelScope.launch {
            isSendingFromHero = true
            try {
                val active = ensureActiveModelWithFreeFallback(onMissingProvider) ?: return@launch

                if (trimmed.isEmpty()) {
                    
                    val conversation = conversationRepository.createDraft(
                        providerID = active.provider.id,
                        providerKind = active.provider.kind,
                        modelID = ModelSelectionUtils.preferredStoredModelIdentifier(active.model),
                    )
                    onConversationCreated(conversation.id)
                    return@launch
                }

                val conversation = conversationRepository.create(
                    providerID = active.provider.id,
                    providerKind = active.provider.kind,
                    modelID = ModelSelectionUtils.preferredStoredModelIdentifier(active.model),
                )
                conversationRepository.updateDraft(conversation.id, trimmed)
                heroText = ""
                onConversationCreatedAutoSend(conversation.id)
            } finally {
                isSendingFromHero = false
            }
        }
    }

    fun enableModel(providerId: String, modelId: String) {
        viewModelScope.launch {
            try {
                val provider = providerRepository.getById(providerId) ?: return@launch
                val model = ModelSelectionUtils.matchingModel(provider.allModels, modelId) ?: return@launch

                if (provider.models.any { ModelSelectionUtils.modelsShareSameRemoteModel(it, model, provider.kind) }) {
                    return@launch
                }

                providerRepository.updateProvider(
                    ModelSelectionUtils.enableModel(provider, model),
                )
            } catch (_: Exception) {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.snackbar_model_enable_failed),
                    ),
                )
            }
        }
    }

    

    private fun resolveModelForSkill(skill: Skill): ActiveModel? {
        val providerList = providers.value
            .filter { it.status !is ProviderConnectionState.Issue && it.models.isNotEmpty() }

        if (providerList.isEmpty()) return null

        if (skill.suggestedModelId != null && skill.suggestedProviderId != null) {
            val suggestedProvider = providerList.firstOrNull {
                it.id == skill.suggestedProviderId || it.kind.rawValue == skill.suggestedProviderId
            }
            val suggestedModel = suggestedProvider?.models?.let { models ->
                ModelSelectionUtils.matchingModel(models, skill.suggestedModelId)
            }
            if (suggestedProvider != null && suggestedModel != null) {
                return ActiveModel(suggestedProvider, suggestedModel)
            }
        }

        if (skill.modelCapabilityHint != "any") {
            val activeProviderId = activeModelState.value.activeModel?.provider?.id
            val sortedProviders = providerList.sortedByDescending { it.id == activeProviderId }
            for (provider in sortedProviders) {
                val model = provider.models.firstOrNull {
                    matchesCapabilityHint(provider, it, skill.modelCapabilityHint)
                }
                if (model != null) {
                    return ActiveModel(provider, model)
                }
            }
        }

        val active = activeModelState.value.activeModel
        if (active != null && providerList.any { it.id == active.provider.id }) {
            return active
        }

        val fallbackProvider = providerList.firstOrNull() ?: return null
        val fallbackModel = fallbackProvider.defaultModel ?: fallbackProvider.models.firstOrNull() ?: return null
        return ActiveModel(fallbackProvider, fallbackModel)
    }

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

    
    fun startConversationWithSkill(
        skill: Skill,
        onCreated: (String) -> Unit,
        onMissingProvider: (() -> Unit)? = null,
    ) {
        val active = resolveModelForSkill(skill)
        if (active == null) {
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.skills_needProviderMessage),
                ),
            )
            showSkillProviderPrompt = true
            return
        }

        viewModelScope.launch {
            appPreferencesRepository.setLastUsedModel(active.provider.id, active.model)
            val conversation = conversationRepository.createDraft(
                providerID = active.provider.id,
                providerKind = active.provider.kind,
                modelID = ModelSelectionUtils.preferredStoredModelIdentifier(active.model),
                title = skill.name,
                skillId = skill.id,
                useMemory = skill.useMemory,
            )
            
            
            
            onCreated(conversation.id)
            skillRepository.recordUse(skill.id)
        }
    }

    

    var showModelPicker by mutableStateOf(false)
    var conversationToRename: Conversation? by mutableStateOf(null)
    var conversationToDelete: Conversation? by mutableStateOf(null)
    var showBatchDeleteConfirm by mutableStateOf(false)

    fun folderName(folderID: String?): String? {
        if (folderID == null) return null
        return folders.value.firstOrNull { it.id == folderID }?.name
    }

    private fun showMoveToFolderSnackbar(count: Int, folderID: String?) {
        if (folderID == null) {
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(
                        if (count == 1) R.string.removed_from_folder else R.string.batch_removed_from_folder,
                        if (count == 1) emptyList() else listOf(count),
                    ),
                ),
            )
            return
        }

        val folderName = folderName(folderID) ?: return
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(
                    if (count == 1) R.string.moved_to_folder else R.string.batch_moved_to_folder,
                    if (count == 1) listOf(folderName) else listOf(count, folderName),
                ),
            ),
        )
    }

    private fun computeRecentConversationStartMillis(): Long {
        val calendar = Calendar.getInstance()
        calendar.set(Calendar.HOUR_OF_DAY, 0)
        calendar.set(Calendar.MINUTE, 0)
        calendar.set(Calendar.SECOND, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        calendar.add(Calendar.DAY_OF_YEAR, -7)
        return calendar.timeInMillis
    }
}


enum class DateGroup(val order: Int) {
    Today(0),
    Yesterday(1),
    PastSevenDays(2),
    Earlier(3),
}

data class HomeConversationSection(
    val group: DateGroup,
    val conversations: List<Conversation>,
    val remainingCount: Int = 0,
)

fun buildHomeConversationSections(
    conversations: List<Conversation>,
    earlierTotalCount: Int,
): List<HomeConversationSection> {
    val grouped = groupConversationsByDate(conversations)
    val sections = grouped
        .filter { it.first != DateGroup.Earlier }
        .map { (group, convs) ->
            HomeConversationSection(group = group, conversations = convs)
        }
        .toMutableList()

    val earlierConversations = grouped.firstOrNull { it.first == DateGroup.Earlier }?.second.orEmpty()
    if (earlierConversations.isNotEmpty() || earlierTotalCount > 0) {
        sections += HomeConversationSection(
            group = DateGroup.Earlier,
            conversations = earlierConversations,
            remainingCount = (earlierTotalCount - earlierConversations.size).coerceAtLeast(0),
        )
    }

    return sections
}

fun classifyDate(timestampMs: Long): DateGroup {
    val cal = Calendar.getInstance()

    val todayStart = cal.apply {
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    val yesterdayStart = todayStart - 24 * 60 * 60 * 1000L
    val sevenDaysAgo = todayStart - 7 * 24 * 60 * 60 * 1000L

    return when {
        timestampMs >= todayStart -> DateGroup.Today
        timestampMs >= yesterdayStart -> DateGroup.Yesterday
        timestampMs >= sevenDaysAgo -> DateGroup.PastSevenDays
        else -> DateGroup.Earlier
    }
}

fun groupConversationsByDate(conversations: List<Conversation>): List<Pair<DateGroup, List<Conversation>>> {
    
    val cal = Calendar.getInstance()
    val todayStart = cal.apply {
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
    val yesterdayStart = todayStart - 24 * 60 * 60 * 1000L
    val sevenDaysAgo = todayStart - 7 * 24 * 60 * 60 * 1000L

    return conversations
        .filter { it.folderID == null }
        .groupBy { ts ->
            when {
                ts.updatedAt >= todayStart -> DateGroup.Today
                ts.updatedAt >= yesterdayStart -> DateGroup.Yesterday
                ts.updatedAt >= sevenDaysAgo -> DateGroup.PastSevenDays
                else -> DateGroup.Earlier
            }
        }
        .toSortedMap(compareBy { it.order })
        .map { (group, convs) -> group to convs }
}
