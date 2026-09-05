package ai.oriveo.community.feature.chat

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.CreateNoteInput
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.notes.NoteCapture
import ai.oriveo.community.core.notes.NoteRecall
import ai.oriveo.community.core.notes.NoteTime
import ai.oriveo.community.core.util.normalizeUuid
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckCoordinator
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckModelIdentity
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckOption
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Origin context for the model-crosscheck sheet (chat side: sourced from an assistant message). */
data class CrosscheckOrigin(
    val message: ChatMessage,
    val conversationId: String,
    val prompt: String?,
    val priorMessages: List<ChatMessage>,
)

private data class NoteRecallInput(
    val text: String,
    val notes: List<Note>,
    val attachedIDs: Set<String>,
    val dismissedIDs: Set<String>,
)

/**
 * All chat-side orchestration for the notes engine: save-from-chat entry points, related-note
 * recall, attached/pinned chips, the saved-note badge, and model crosscheck. Pulled out of
 * [ChatViewModel] to keep that class within a reasonable size budget.
 *
 * Pure orchestration — behavior matches what it replaced exactly; dependencies are injected
 * through the constructor, and dynamic view-model state is read via lambdas/StateFlow.
 */
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
class ChatNoteCoordinator(
    private val scope: CoroutineScope,
    private val noteRepository: NoteRepository,
    private val conversationRepository: ConversationRepository,
    providerRepository: ProviderRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val providers: StateFlow<List<Provider>>,
    conversation: StateFlow<ConversationRenderState>,
    private val activeConversationId: StateFlow<String?>,
    private val currentConversation: () -> Conversation?,
    private val inputTextProvider: () -> String,
    savedStateHandle: SavedStateHandle,
    private val recallDispatcher: CoroutineDispatcher = Dispatchers.Default,
) {

    /** Target message id for a note's "return to conversation" jump (auto-injected via type-safe nav; does not reuse the searchQuery text locator). */
    val focusMessageId: String? = savedStateHandle.get<String>("focusMessageId")
        ?.trim()
        ?.takeIf { it.isNotBlank() }
        ?.let(::normalizeUuid)

    /** Target for the top "back to note" entry point: preserves the way back when navigating from NoteDetail into the conversation. */
    val returnToNoteId: String? = savedStateHandle.get<String>("fromNoteId")
        ?.trim()
        ?.takeIf { it.isNotBlank() }
        ?.let(::normalizeUuid)

    /**
     * Note ids pending a pin while composing (before a conversation exists). Once the first
     * send creates the conversation these land in [Conversation.pinnedNoteIds]; when resolving
     * prompt injection they get merged and deduplicated with conversation.pinnedNoteIds.
     */
    var pendingPinnedNoteIds: List<String> by mutableStateOf(emptyList())
        private set

    /** Related-notes popover: ids the user dismissed within the current typing session (a large enough input change gets recomputed and clears these via debounce). */
    private val dismissedRelatedNoteIds = MutableStateFlow<Set<String>>(emptySet())
    private val noteRecallIndex = NoteRecall.Index()

    /** Note preview sheet (triggered by tapping an attached/related chip). */
    var notePreview: Note? by mutableStateOf(null)
        private set

    /** Origin for the model-crosscheck sheet (non-null means the sheet is open). */
    var crosscheckOrigin: CrosscheckOrigin? by mutableStateOf(null)
        private set

    /** Requests navigation to NoteDetail after tapping "View" on the save-success toast (the UI layer collects this and performs the navigation). */
    private val _navToNoteDetail = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val navToNoteDetail: SharedFlow<String> = _navToNoteDetail.asSharedFlow()
    private var noteCaptureHintHandled = false

    private val crosscheckCoordinator = CrosscheckCoordinator(
        scope = scope,
        providerRepository = providerRepository,
        appLanguageTag = {
            AppPreferencesRepository.serializeLanguageSyncTag(appPreferencesRepository.getLanguage())
                ?: CrosscheckCoordinator.currentSystemLanguageTag()
        },
    )

    /** All active notes (the recall pool and the source used to resolve chips). */
    private val activeNotes: StateFlow<List<Note>> = noteRepository.observeActive()
        .stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** The chat selection only offers "replace current note" when the NoteDetail return target is still an active note. */
    val canReplaceCurrentNote: StateFlow<Boolean> = activeNotes
        .map { notes ->
            val noteId = returnToNoteId ?: return@map false
            notes.any { normalizeUuid(it.id) == noteId }
        }
        .distinctUntilChanged()
        .stateIn(scope, SharingStarted.WhileSubscribed(5000), false)

    /** Projection of the "saved as note" badge for messages in the current conversation; writes no persisted state. */
    val savedNoteLinksByMessage: StateFlow<Map<String, List<SavedNoteLink>>> = combine(
        activeConversationId,
        activeNotes,
    ) { conversationId, notes ->
        savedNoteLinksByMessage(conversationId, notes)
    }.stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyMap())

    /** Notes pinned into this conversation's context (conversation.pinnedNoteIds unioned with compose-time pending pins, deduplicated down to the most recent, with deleted notes filtered out). */
    val attachedNotes: StateFlow<List<Note>> = combine(
        conversation.map { it.conversation?.pinnedNoteIds ?: emptyList() }.distinctUntilChanged(),
        snapshotFlow { pendingPinnedNoteIds },
        activeNotes,
    ) { pinnedIds, pendingIds, notes ->
        val ids = (pinnedIds + pendingIds)
            .map(::normalizeUuid).distinct().takeLast(ChatPromptInjectionBuilder.MAX_PINNED_NOTES)
        ids.mapNotNull { id -> notes.firstOrNull { normalizeUuid(it.id) == id } }
    }.stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** Related older notes surfaced above the input field (at most 2, excluding ones already attached or dismissed; debounced 250ms). */
    val relatedNotes: StateFlow<List<Note>> = combine(
        snapshotFlow { inputTextProvider() }.debounce(250),
        activeNotes,
        attachedNotes.map { list -> list.map { normalizeUuid(it.id) }.toSet() }.distinctUntilChanged(),
        dismissedRelatedNoteIds,
    ) { text, notes, attachedIds, dismissed ->
        NoteRecallInput(text.trim(), notes, attachedIds, dismissed)
    }.mapLatest { input ->
        if (input.text.isEmpty()) return@mapLatest emptyList()
        withContext(recallDispatcher) {
            val context = currentCoroutineContext()
            val checkpoint = { context.ensureActive() }
            val terms = NoteRecall.termsFor(input.text)
            if (terms.isEmpty()) return@withContext emptyList()
            // FTS prefilter hits take priority (up to MAX_CANDIDATES - RECENT_CANDIDATE_FLOOR,
            // which is how older notes make it into the pool); recent notes fill the rest. If
            // the prefilter fails or there are no searchable terms, this falls back to filling
            // straight from recent notes.
            val visible = input.notes.filter {
                normalizeUuid(it.id) !in input.attachedIDs && normalizeUuid(it.id) !in input.dismissedIDs
            }
            val prefilterIds = noteRepository.recallCandidateIds(
                terms,
                limit = NoteRecall.MAX_CANDIDATES - NoteRecall.RECENT_CANDIDATE_FLOOR,
            )
            checkpoint()
            val byId = visible.associateBy { it.id }
            val candidates = LinkedHashMap<String, Note>(NoteRecall.MAX_CANDIDATES)
            prefilterIds.forEach { id -> byId[id]?.let { candidates[it.id] = it } }
            for (note in visible) {
                if (candidates.size >= NoteRecall.MAX_CANDIDATES) break
                candidates.putIfAbsent(note.id, note)
            }
            noteRecallIndex.update(candidates.values.toList(), checkpoint)
            noteRecallIndex.find(terms, limit = 2, checkpoint = checkpoint).map { it.note }
        }
    }.stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** Transient streaming state for model crosscheck (never written into the conversation). */
    val crosscheckState: StateFlow<CrosscheckState> = crosscheckCoordinator.state

    // ── Notes: save-from-chat entry points ──

    /** Saves an entire message as a note: assistant messages use fullAnswer, user messages use userMessage. */
    fun saveMessageAsNote(messageId: String) {
        val convId = activeConversationId.value ?: return
        val msgs = currentConversation()?.messages ?: return
        val msg = msgs.firstOrNull { it.id == messageId } ?: return
        createNoteAndAnnounce(NoteCapture.fromMessage(msg, convId, msgs))
    }

    /** Saves a text selection or code block as a note: captureKind=selection, body holds the selected text/whole code block, bodySnapshot keeps the full original message. */
    fun saveSelectionAsNote(messageId: String, selectedText: String) {
        if (selectedText.isBlank()) return
        val convId = activeConversationId.value ?: return
        val msgs = currentConversation()?.messages ?: return
        val msg = msgs.firstOrNull { it.id == messageId } ?: return
        createNoteAndAnnounce(NoteCapture.fromSelection(msg, selectedText, convId, msgs))
    }

    /** Updates a target note's body/source from the current selection while preserving its organizational fields (folder, tags, pin, etc.). */
    fun replaceCurrentNoteSelection(messageId: String, selectedText: String, noteIdOverride: String? = null) {
        if (selectedText.isBlank()) return
        val noteId = noteIdOverride ?: returnToNoteId ?: return
        val convId = activeConversationId.value ?: return
        val msgs = currentConversation()?.messages ?: return
        val msg = msgs.firstOrNull { it.id == messageId } ?: return
        val input = NoteCapture.fromSelection(msg, selectedText, convId, msgs)
        scope.launch {
            val note = noteRepository.replaceNote(noteId, input) ?: return@launch
            announceNoteReplaced(note.id)
        }
    }

    private fun createNoteAndAnnounce(input: CreateNoteInput) {
        scope.launch {
            val note = noteRepository.createNote(input)
            announceNoteSaved(note.id, note.title)
        }
    }

    /** Shared save-success feedback: a top toast shows the title plus a "View" action that navigates to NoteDetail. */
    private fun announceNoteSaved(noteId: String, title: String) {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = if (title.isBlank()) {
                    UiText.Resource(R.string.notes_untitled)
                } else {
                    UiText.Dynamic(title)
                },
                style = GlobalToastStyle.Success,
                action = GlobalToastAction(UiText.Resource(R.string.notes_toast_view)) {
                    _navToNoteDetail.tryEmit(noteId)
                },
                durationMs = 4000L,
            ),
        )
    }

    /** Replace-success feedback: kept lightweight, the action jumps back to the same note's detail. */
    private fun announceNoteReplaced(noteId: String) {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(R.string.notes_chat_note_replaced),
                style = GlobalToastStyle.Success,
                action = GlobalToastAction(UiText.Resource(R.string.notes_toast_view)) {
                    _navToNoteDetail.tryEmit(noteId)
                },
                durationMs = 4000L,
            ),
        )
    }

    /** Shows a one-time hint the first time a savable assistant reply appears in chat (persisted via hasSeenNoteCaptureHint, shown only once ever). */
    fun maybeShowNoteCaptureHint() {
        if (noteCaptureHintHandled) return
        noteCaptureHintHandled = true
        scope.launch {
            if (!appPreferencesRepository.hasSeenNoteCaptureHint()) {
                appPreferencesRepository.markNoteCaptureHintSeen()
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(R.string.notes_chat_note_capture_hint),
                        style = GlobalToastStyle.Success,
                        durationMs = 4000L,
                    ),
                )
            }
        }
    }

    // ── Notes engine: attached/related chips, re-adding to notes, model crosscheck ──

    /** After the first send creates the conversation, flush the pins accumulated during compose into conversation.pinnedNoteIds (kept for later turns; leaving pending as-is is harmless since it's already deduplicated). */
    fun flushPendingPinnedNotes(conversationId: String) {
        val ids = pendingPinnedNoteIds
        if (ids.isEmpty()) return
        scope.launch {
            ids.forEach { conversationRepository.pinNoteToConversation(conversationId, it) }
        }
    }

    /** Pins a related/selected note into this conversation's context: writes straight to storage if a conversation exists, otherwise queues it in the compose-time pending list. */
    fun attachNoteToContext(note: Note) {
        val nid = normalizeUuid(note.id)
        dismissedRelatedNoteIds.value = dismissedRelatedNoteIds.value - nid
        val convId = activeConversationId.value
        if (convId != null) {
            scope.launch { conversationRepository.pinNoteToConversation(convId, nid) }
        } else {
            pendingPinnedNoteIds = (pendingPinnedNoteIds + nid)
                .distinct().takeLast(ChatPromptInjectionBuilder.MAX_PINNED_NOTES)
        }
    }

    /** Removes a note from context: clears it from both the conversation and the pending list, so pending doesn't merge the just-removed note back in. */
    fun detachNoteFromContext(note: Note) {
        val nid = normalizeUuid(note.id)
        pendingPinnedNoteIds = pendingPinnedNoteIds.filter { it != nid }
        val convId = activeConversationId.value
        if (convId != null) {
            scope.launch { conversationRepository.unpinNoteFromConversation(convId, nid) }
        }
    }

    /** Dismisses the related-notes popover (only for the current typing session). */
    fun dismissRelatedNote(note: Note) {
        dismissedRelatedNoteIds.value = dismissedRelatedNoteIds.value + normalizeUuid(note.id)
    }

    fun showNotePreview(note: Note) { notePreview = note }
    fun clearNotePreview() { notePreview = null }

    // ── Model crosscheck ──

    /** Candidate models for crosscheck: providers still needing a key are excluded, and the origin model is filtered out entirely. */
    fun crosscheckOptions(): List<CrosscheckOption> {
        val msg = crosscheckOrigin?.message
        val origin = if (msg != null && !msg.modelID.isNullOrBlank()) {
            CrosscheckModelIdentity(
                providerKind = msg.providerKind,
                modelId = msg.modelID,
                providerId = msg.providerID,
            )
        } else null
        return CrosscheckCoordinator.eligibleOptions(providers.value, excluding = origin)
    }

    /** Opens the crosscheck sheet using a delivered assistant message as the origin. */
    fun openCrosscheck(messageId: String) {
        val conv = currentConversation() ?: return
        val msg = conv.messages.firstOrNull { it.id == messageId } ?: return
        if (msg.role != ChatRole.Assistant) return
        val idx = conv.messages.indexOfFirst { it.id == messageId }
        val prompt = if (idx <= 0) null else {
            (idx - 1 downTo 0).asSequence()
                .map { conv.messages[it] }
                .firstOrNull { it.role == ChatRole.User && it.text.isNotBlank() }?.text
        }
        crosscheckCoordinator.reset()
        crosscheckOrigin = CrosscheckOrigin(
            message = msg,
            conversationId = conv.id,
            prompt = prompt,
            priorMessages = conv.messages,
        )
    }

    fun runCrosscheck(option: CrosscheckOption) {
        val origin = crosscheckOrigin ?: return
        crosscheckCoordinator.start(
            originalQuestion = origin.prompt ?: "",
            originalAnswer = origin.message.text,
            priorMessages = origin.priorMessages,
            provider = option.provider,
            model = option.model,
        )
    }

    fun saveCrosscheckNote(option: CrosscheckOption) {
        val origin = crosscheckOrigin ?: return
        val text = crosscheckState.value.text
        if (text.isBlank()) return
        val input = NoteCapture.fromCrosscheck(
            originalAnswer = origin.message.text,
            originConversationId = origin.conversationId,
            originMessageId = origin.message.id,
            // Falls back to the conversation's current model when the message itself has no modelID.
            originModelID = origin.message.modelID ?: currentConversation()?.modelID,
            originModelName = origin.message.modelName,
            originProviderKind = origin.message.providerKind,
            originProviderName = origin.message.providerName,
            originPrompt = origin.prompt,
            crosscheckProviderKind = option.provider.kind,
            crosscheckProviderName = option.provider.displayName,
            crosscheckModelID = option.model.id,
            crosscheckModelName = option.model.name,
            crosscheckText = text,
            originAtIso = NoteTime.millisToIso(origin.message.createdAt ?: System.currentTimeMillis()),
            nowIso = NoteTime.nowIso(),
        )
        scope.launch {
            val note = noteRepository.createNote(input)
            closeCrosscheck()
            announceNoteSaved(note.id, note.title)
        }
    }

    fun closeCrosscheck() {
        crosscheckOrigin = null
        crosscheckCoordinator.reset()
    }
}
