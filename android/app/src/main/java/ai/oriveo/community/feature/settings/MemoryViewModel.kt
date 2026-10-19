package ai.oriveo.community.feature.settings

import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.FeatureBadges
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.context.MemoryConflictResolution
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryServerTime
import ai.oriveo.community.core.context.MemoryOrganizedItem
import ai.oriveo.community.core.context.MemoryRawApply
import ai.oriveo.community.core.context.MemoryRawOp
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.data.repository.ChatContextProjector
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.PlannedChatRequest
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.memory.MemoryOrganizer
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.koin.core.component.KoinComponent
import org.koin.core.component.get
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeParseException

/**
 * Memory page ViewModel; mirrors the iOS MemoryView business logic.
 *
 * - Item writes always go through [MemoryItemRepository] (it mirrors memoryText); the repository list includes tombstones, so the UI layer filters them itself.
 * - Draft generation first shows the pre-send disclosure [extractionDisclosure]: only the first-ranked provider + model is used, and only that provider's
 *   user messages are sent; a failure is reported directly as a [DraftError] without trying the next provider. On success the new-item editor opens prefilled (category About me); memoryText is no longer written.
 * - When [editItemId] is non-null ("this is wrong" from chat) and the item exists, its editor opens directly.
 * - Errors are exposed to the UI layer as [DraftError] (carrying stringRes + args) so the ViewModel never holds a Context.
 * - The raw view [rawView] and organizing into items [organize]: results always land through the repository edit / create / delete;
 *   organizing also shows [extractionDisclosure] first, uses only the first candidate and does not fall back to another provider on failure.
 */
@Suppress("LongParameterList")
class MemoryViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
    private val conversationRepository: ConversationRepository,
    private val providerRepository: ProviderRepository,
    @Suppress("unused") private val globalSnackbarManager: GlobalSnackbarManager,
    /** When null (unit tests etc.) there are no items and item operations have no effect. */
    private val memoryItemRepository: MemoryItemRepository? = null,
    private val accountIds: StateFlow<String> = MutableStateFlow(LOCAL_ACCOUNT_ID),
    editItemId: String? = null,
    /** The request that organizes text into items; unit tests inject a stand-in so no real provider is called. */
    private val organizerFor: (Provider, AIModel) -> MemoryOrganizer = { provider, model ->
        MemoryOrganizer.forModel(providerRepository, provider, model)
    },
    /** Folder list; the scope of an L3 row ("Folder <name>") takes its name from here. */
    folders: Flow<List<Folder>> = flowOf(emptyList()),
    /** Default date (today) for a new L3 item; unit tests can pin it. */
    private val today: () -> LocalDate = { LocalDate.now() },
) : ViewModel(), KoinComponent {

    var isGeneratingDraft by mutableStateOf(false)
        private set
    var activeDraftRequestId by mutableStateOf<String?>(null)
        private set
    var pendingGeneratedDraft by mutableStateOf<String?>(null)
        private set
    var showDraftConflictDialog by mutableStateOf(false)
        private set

    /** The pre-send disclosure for AI drafting; not shown when null. */
    var extractionDisclosure by mutableStateOf<MemoryExtractionDisclosure?>(null)
        private set

    var draftError by mutableStateOf<DraftError?>(null)
        private set

    /** The open new-item / edit editor; not shown when null. */
    var editor by mutableStateOf<MemoryItemEditorState?>(null)
        private set

    /** The item waiting for delete confirmation; the confirmation dialog is not shown when null. */
    var pendingDelete by mutableStateOf<MemoryItem?>(null)
        private set

    /** This device's memory id; conflict groups use it to label "this device's version". */
    var deviceId by mutableStateOf<String?>(null)
        private set

    /** The open raw view; the list is shown when null. */
    var rawView by mutableStateOf<MemoryRawState?>(null)
        private set

    /** The open organize-into-items sheet; not shown when null. */
    var organize by mutableStateOf<MemoryOrganizeState?>(null)
        private set

    private var draftGenerationJob: Job? = null
    private var organizeJob: Job? = null

    /** Preparation before the disclosure is shown for drafting / organizing (read conversations, pick a model): the two are mutually exclusive, and a new preparation cancels the old one. */
    private var prepareJob: Job? = null

    /** Request id of the draft preparation phase (reading conversations); while non-null [isGeneratingDraft] is true and tapping "Draft with AI" again is ignored. */
    private var preparingDraftRequestId: String? = null

    val hasRecentConversations: StateFlow<Boolean> = conversationRepository.observeHasAnyWithMessages()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    /** All items of the current account (including tombstones), in listOrder. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val items: StateFlow<List<MemoryItem>> = (memoryItemRepository?.observeCurrent(accountIds) ?: flowOf(emptyList()))
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** Folder id to name. */
    val folderNames: StateFlow<Map<String, String>> = folders
        .map { list -> list.associate { it.id to it.name } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())

    init {
        val repository = memoryItemRepository
        if (repository != null) {
            viewModelScope.launch {
                deviceId = repository.deviceId()
                val target = editItemId?.let { repository.get(accountIds.value, it) }
                if (target != null && target.status != MemoryStatus.DELETED) openEditor(target)
            }
        }
    }

    /** Called on the first composition of the memory settings page: clears the new-feature red dot on the "Memory" row in Settings. */
    fun markMemoryFeatureBadgeSeen() {
        viewModelScope.launch {
            appPreferencesRepository.markFeatureBadgeSeen(FeatureBadges.SETTINGS_MEMORY)
        }
    }

    fun openNewEditor(group: MemoryItemGroup = MemoryItemGroup.About, text: String = "") {
        editor = MemoryItemEditorState(itemId = null, group = group, text = text)
    }

    /** "+ Add" of the "Events and decisions" group: creates an L3 item with kind defaulting to decision and the date defaulting to today. */
    fun openNewEpisodicEditor() {
        editor = MemoryItemEditorState(
            itemId = null,
            group = MemoryItemGroup.Projects,
            text = "",
            layer = MemoryLayer.EPISODIC,
            episodicKind = MemoryKind.DECISION,
            date = today(),
        )
    }

    fun openEditor(item: MemoryItem) {
        val episodic = item.layer == MemoryLayer.EPISODIC
        editor = MemoryItemEditorState(
            itemId = item.id,
            group = MemoryItemGroup.of(item.kind) ?: MemoryItemGroup.About,
            text = item.content,
            originalKind = item.kind,
            layer = item.layer,
            episodicKind = item.kind.takeIf { it in MemoryItemEditorState.EPISODIC_KINDS } ?: MemoryKind.DECISION,
            date = if (episodic) episodicDate(item) ?: today() else null,
        )
    }

    fun updateEditorEpisodicKind(kind: MemoryKind) {
        if (kind in MemoryItemEditorState.EPISODIC_KINDS) editor = editor?.copy(episodicKind = kind)
    }

    fun updateEditorDate(date: LocalDate) {
        editor = editor?.copy(date = date)
    }

    /** Hands the three resolutions of an L3 conflict pair (keep newer useNew / keep older useOld / keep both keepBoth) to the repository. */
    fun resolveL3Conflict(pair: MemoryL3ConflictPair, resolution: MemoryConflictResolution) =
        write { accountId -> resolveL3Conflict(accountId, pair.newer.item.id, pair.older.item.id, resolution) }

    fun updateEditorText(text: String) {
        editor = editor?.copy(text = text)
    }

    fun updateEditorGroup(group: MemoryItemGroup) {
        editor = editor?.copy(group = group)
    }

    fun dismissEditor() {
        editor = null
    }

    /** Creates a new item or edits the text / category; over-limit or blank text is not saved. */
    fun saveEditor() {
        val state = editor ?: return
        val repository = memoryItemRepository ?: return
        if (!state.counter.canSave) return
        val content = state.text.trim()
        editor = null
        viewModelScope.launch {
            val accountId = accountIds.value
            val itemId = state.itemId
            when {
                itemId != null -> repository.edit(accountId, itemId, content, state.kind, state.occurredAt)
                state.isEpisodic ->
                    repository.create(accountId, state.kind, content, layer = MemoryLayer.EPISODIC, occurredAt = state.occurredAt)
                else -> repository.create(accountId, state.kind, content)
            }
        }
    }

    fun togglePinned(item: MemoryItem) = write { accountId -> setPinned(accountId, item.id, !item.pinned) }

    fun togglePaused(item: MemoryItem) =
        write { accountId -> setPaused(accountId, item.id, item.status != MemoryStatus.PAUSED) }

    fun keepConflict(item: MemoryItem) = write { accountId -> resolveConflict(accountId, item.id) }

    /** Delete goes through a confirmation dialog first; the tombstone is written only after confirming. */
    fun requestDelete(item: MemoryItem) {
        pendingDelete = item
    }

    fun cancelDelete() {
        pendingDelete = null
    }

    fun confirmDelete() {
        val item = pendingDelete ?: return
        pendingDelete = null
        write { accountId -> delete(accountId, item.id) }
    }

    private fun write(block: suspend MemoryItemRepository.(accountId: String) -> Unit) {
        val repository = memoryItemRepository ?: return
        viewModelScope.launch { repository.block(accountIds.value) }
    }

    // ---- Raw view ----

    /** Contains active items only (MemoryItems.rawRender). */
    fun openRawView() {
        rawView = MemoryRawState(items.value)
    }

    fun updateRawText(text: String) {
        rawView = rawView?.copy(text = text, tooLongIndex = null)
    }

    /** Cancel discards the changes without asking for confirmation. */
    fun dismissRawView() {
        rawView = null
    }

    /** Nothing is written without changes; if one segment is too long only its index is reported and no item is written; otherwise the ops are applied in order and the list is shown again. */
    fun saveRawView() {
        val state = rawView ?: return
        val separators = state.text.split("\n").count { it.removeSuffix("\r") == MemoryItems.RAW_VIEW_SEPARATOR }
        val newIds = List(separators + 1) { generateUuidString().lowercase() }
        when (val result = MemoryItems.rawApply(state.items, state.text, newIds)) {
            is MemoryRawApply.TooLong -> rawView = state.copy(tooLongIndex = result.index + 1)
            is MemoryRawApply.Ops -> {
                rawView = null
                if (result.ops.isEmpty()) return
                write { accountId ->
                    result.ops.forEach { op ->
                        when (op) {
                            is MemoryRawOp.Update -> edit(accountId, op.id, op.content)
                            // The repository assigns a lowercase UUID as the id on create, and source defaults to manual.
                            is MemoryRawOp.Create -> create(accountId, op.kind, op.content)
                            is MemoryRawOp.Delete -> delete(accountId, op.id)
                        }
                    }
                }
            }
        }
    }

    // ---- Organize into items ----

    /**
     * Tapping "Organize into items": uses the same candidate ranking as AI drafting but only the first one, and shows the pre-send disclosure first (the organize scope);
     * no request is sent before [Send] ([confirmExtraction]). With no usable model it just shows a message and no disclosure.
     */
    fun organize(item: MemoryItem) {
        cancelPrepare()
        organizeJob?.cancel()
        organize = null
        extractionDisclosure = null
        prepareJob = viewModelScope.launch {
            val candidate = draftCandidates(providerRepository.observeAll().first()).firstOrNull()
            if (candidate == null) {
                organize = MemoryOrganizeState(item = item, phase = MemoryOrganizePhase.NoModel)
                return@launch
            }
            extractionDisclosure = MemoryExtractionDisclosure.organize(candidate, item)
        }
    }

    /** Disclosure [Send] (organize): enters Loading, makes one request with only the provider + model in the dialog, and on failure enters Failed without trying the next provider. */
    private fun startOrganize(disclosure: MemoryExtractionDisclosure, item: MemoryItem) {
        organizeJob?.cancel()
        organize = MemoryOrganizeState(item = item, phase = MemoryOrganizePhase.Loading)
        organizeJob = viewModelScope.launch {
            val reply = try {
                organizerFor(disclosure.provider, disclosure.model).reply(item.content)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Throwable) {
                organize = MemoryOrganizeState(item = item, phase = MemoryOrganizePhase.Failed)
                return@launch
            }
            // An empty reply counts as a failure; Empty is only for a non-empty reply from which no items can be parsed.
            if (reply.trim().isEmpty()) {
                organize = MemoryOrganizeState(item = item, phase = MemoryOrganizePhase.Failed)
                return@launch
            }
            val proposals = MemoryItems.organizeParse(reply)
            organize = if (proposals.isEmpty()) {
                MemoryOrganizeState(item = item, phase = MemoryOrganizePhase.Empty)
            } else {
                MemoryOrganizeState(item = item, phase = MemoryOrganizePhase.Ready, proposals = proposals)
            }
        }
    }

    fun toggleOrganizeSelection(index: Int) {
        val state = organize ?: return
        organize = state.copy(selected = if (index in state.selected) state.selected - index else state.selected + index)
    }

    fun setOrganizeKeepOriginal(keep: Boolean) {
        organize = organize?.copy(keepOriginal = keep)
    }

    /** Cancels the request and closes, writing nothing. */
    fun dismissOrganize() {
        organizeJob?.cancel()
        organizeJob = null
        organize = null
    }

    /** Creates manual items from the checked entries in order (kind taken from the parse result); unless "keep original" is on, the original item gets a tombstone. */
    fun saveOrganized() {
        val state = organize ?: return
        if (!state.canSave) return
        organize = null
        val picked = state.proposals.filterIndexed { index, _ -> index in state.selected }
        write { accountId ->
            picked.forEach { proposal -> create(accountId, proposal.kind, proposal.content) }
            if (!state.keepOriginal) delete(accountId, state.item.id)
        }
    }

    fun dismissDraftError() {
        draftError = null
    }

    /**
     * Tapping "Draft with AI": works out the send scope first and only sets the disclosure; no request is sent before [Send] ([confirmExtraction]).
     * [isGeneratingDraft] is true while conversations are read (button loading) and is cleared before the disclosure shows; tapping again while generating is ignored.
     */
    fun generateDraft() {
        if (isGeneratingDraft) return
        cancelPrepare()
        draftGenerationJob?.cancel()
        val requestId = generateUuidString()
        activeDraftRequestId = requestId
        preparingDraftRequestId = requestId
        isGeneratingDraft = true
        pendingGeneratedDraft = null
        draftError = null
        extractionDisclosure = null

        prepareJob = viewModelScope.launch {
            try {
                // 1. Pick the model: the existing ranking (last used first), take only the first one
                val allProviders = providerRepository.observeAll().first()
                val candidate = draftCandidates(allProviders).firstOrNull()

                if (candidate == null) {
                    val hasAnyKey = allProviders.any { ProviderCredentialResolver.apiKey(it, null).isNotBlank() }
                    presentDraftError(
                        if (hasAnyKey) {
                            DraftError(
                                titleRes = R.string.memory_error_no_model_title,
                                messageRes = R.string.memory_error_no_model_message,
                            )
                        } else {
                            DraftError(
                                titleRes = R.string.memory_error_no_provider_title,
                                messageRes = R.string.memory_error_no_provider_message,
                            )
                        },
                    )
                    return@launch
                }

                val recent = conversationRepository.getRecentConversationsWithMessages(limit = 5)

                // 3. Scope: per conversation keep only the user messages sent to the chosen provider, the first 500 characters, joined with \n---\n
                val excerpts = MemoryExtraction.draftExcerpts(recent, candidate.provider.id)
                if (excerpts.isBlank()) {
                    presentDraftError(
                        DraftError(
                            titleRes = R.string.memory_error_not_enough_title,
                            messageRes = R.string.memory_error_not_enough_message,
                        ),
                    )
                    return@launch
                }

                if (activeDraftRequestId != requestId) return@launch
                endDraftPrepare(requestId)
                extractionDisclosure = MemoryExtractionDisclosure.draft(candidate, excerpts)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Throwable) {
                if (activeDraftRequestId == requestId) {
                    presentDraftError(
                        DraftError(
                            titleRes = R.string.memory_error_hydrate_title,
                            messageRes = R.string.memory_error_hydrate_message,
                        ),
                    )
                }
            } finally {
                endDraftPrepare(requestId)
                if (activeDraftRequestId == requestId) {
                    activeDraftRequestId = null
                }
            }
        }
    }

    /** Cancels the preparation in progress (drafting or organizing); cancelling a draft preparation also clears the loading state. */
    private fun cancelPrepare() {
        prepareJob?.cancel()
        prepareJob = null
        preparingDraftRequestId?.let { requestId ->
            endDraftPrepare(requestId)
            if (activeDraftRequestId == requestId) activeDraftRequestId = null
        }
    }

    private fun endDraftPrepare(requestId: String) {
        if (preparingDraftRequestId != requestId) return
        preparingDraftRequestId = null
        isGeneratingDraft = false
    }

    /** Disclosure [Cancel]: sends nothing and returns to the state before the tap. */
    fun cancelExtraction() {
        extractionDisclosure = null
    }

    /** Disclosure [Send]: sends once with only the provider + model in the dialog; a failure or empty reply is reported directly without trying the next provider. */
    fun confirmExtraction() {
        val disclosure = extractionDisclosure ?: return
        extractionDisclosure = null
        disclosure.organizeItem?.let { item ->
            startOrganize(disclosure, item)
            return
        }
        draftGenerationJob?.cancel()
        val requestId = generateUuidString()
        activeDraftRequestId = requestId
        val editorAtStart = editor
        pendingGeneratedDraft = null
        draftError = null
        isGeneratingDraft = true

        draftGenerationJob = viewModelScope.launch {
            try {
                // The same instructions as iOS (verbatim) go into the purpose system, and the excerpts are the only user message (purpose memoryExtraction)
                val provider = disclosure.provider
                val model = disclosure.model
                val service = providerRepository.serviceFor(provider, model)
                val transport = draftProjection(disclosure.excerpts, provider, model)
                    .transportInput(ChatRequestOptions())
                val response = service.sendMessage(
                    apiKey = ProviderCredentialResolver.apiKey(provider, model.id),
                    modelID = model.id,
                    messages = transport.messages,
                    baseUrl = ai.oriveo.community.core.provider.transport.OfficialEndpointSource.effectiveBaseUrlText(provider),
                    supportsImageGen = false,
                    reasoningMode = ReasoningMode.Automatic,
                    webSearchEnabled = false,
                    requestOptions = transport.options,
                )

                if (activeDraftRequestId != requestId) return@launch

                val draft = response.result.text
                    .trim()
                    .takeGraphemes(AppPreferencesRepository.MEMORY_CHARACTER_LIMIT)
                if (draft.isBlank()) {
                    presentDraftError(providerDraftError(ProviderServiceError.EmptyResponse))
                    return@launch
                }

                // The user opened or changed the editor while generating: ask whether to replace it with the draft instead of overwriting directly.
                if (editor != null && editor != editorAtStart) {
                    pendingGeneratedDraft = draft
                    showDraftConflictDialog = true
                } else {
                    openNewEditor(text = draft)
                }
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Throwable) {
                if (activeDraftRequestId == requestId) {
                    presentDraftError(providerDraftError(error))
                }
            } finally {
                if (activeDraftRequestId == requestId) {
                    activeDraftRequestId = null
                    isGeneratingDraft = false
                }
            }
        }
    }

    fun applyPendingGeneratedDraft() {
        pendingGeneratedDraft?.let { draft -> openNewEditor(text = draft) }
        pendingGeneratedDraft = null
        showDraftConflictDialog = false
    }

    fun dismissPendingGeneratedDraft() {
        pendingGeneratedDraft = null
        showDraftConflictDialog = false
    }

    override fun onCleared() {
        prepareJob?.cancel()
        draftGenerationJob?.cancel()
        organizeJob?.cancel()
        activeDraftRequestId = null
    }

    /** One provider failed: the body is that provider's localized error detail; without detail use the generic failure text. */
    private fun providerDraftError(error: Throwable?): DraftError {
        val detail = providerErrorDetail(error)
        return if (detail.isNullOrBlank()) {
            DraftError(
                titleRes = R.string.memory_error_generic_title,
                messageRes = R.string.memory_error_generic_message,
            )
        } else {
            DraftError(
                titleRes = R.string.memory_error_generic_title,
                messageLiteral = detail,
            )
        }
    }

    private fun providerErrorDetail(error: Throwable?): String? = when (error) {
        null -> null
        is ProviderServiceError -> localizeProviderMessage(error)
        else -> error.message
    }

    private fun localizeProviderMessage(error: ProviderServiceError): String =
        runCatching { ErrorMapper.localizeProviderErrorMessage(error, get<android.content.Context>()) }
            .getOrDefault(error.userMessage)

    private fun presentDraftError(error: DraftError) {
        draftError = error
    }

    /** Candidates keep the existing ranking (last-used connection first); see [MemoryExtraction.candidates]. */
    private suspend fun draftCandidates(allProviders: List<Provider>): List<MemoryExtractionCandidate> {
        val lastUsed = appPreferencesRepository.lastUsedModelRefSnapshot
            ?: appPreferencesRepository.getLastUsedModelRef()
        return MemoryExtraction.candidates(allProviders, lastUsed)
    }

    data class DraftError(
        @param:StringRes val titleRes: Int,
        @param:StringRes val messageRes: Int? = null,
        val messageLiteral: String? = null,
        val args: List<Any> = emptyList(),
    )

    companion object {
        /** UTC date of occurredAt (createdAt when absent); null when neither parses. */
        private fun episodicDate(item: MemoryItem): LocalDate? =
            listOfNotNull(item.occurredAt, (item.createdAt as? MemoryServerTime.At)?.rfc3339).firstNotNullOfOrNull { text ->
                try {
                    OffsetDateTime.parse(text).atZoneSameInstant(ZoneOffset.UTC).toLocalDate()
                } catch (_: DateTimeParseException) {
                    null
                }
            }

        /** Draft instructions (iOS wording, verbatim); sent as the purpose system of memoryExtraction. */
        internal val DRAFT_INSTRUCTIONS: String = """
            Based on the following conversation excerpts, write a concise personal profile in the same language the user is using (under 400 words).
            Include: their role/expertise, current projects or tech stack, preferred response style and language.
            Only include information clearly evident from the conversations. Do not invent or assume.
            Write in first person, as if the user is describing themselves.
        """.trimIndent()

        /**
         * The draft request comes from the assembler (purpose memoryExtraction): instructions as the purpose system,
         * the excerpts as the only user message.
         */
        internal fun draftProjection(excerpts: String, provider: Provider, model: AIModel): PlannedChatRequest =
            ChatContextProjector.projectPurpose(
                purpose = RequestPurpose.MEMORY_EXTRACTION,
                messages = listOf(
                    ChatMessage(
                        id = generateUuidString(),
                        role = ChatRole.User,
                        text = excerpts,
                        providerID = provider.id,
                        providerKind = provider.kind,
                        providerName = provider.displayName,
                        modelID = model.id,
                        modelName = model.name,
                        state = ChatMessageState.Delivered,
                    ),
                ),
                window = ChatContextProjector.window(provider, model, ChatRequestOptions()),
                purposeSystem = DRAFT_INSTRUCTIONS,
            )
    }
}

/** The single local account id that memory items are stored under. */
private const val LOCAL_ACCOUNT_ID = "guest"
