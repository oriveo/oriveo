package ai.oriveo.community.feature.chat

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.CompactOutcome
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextCapConfirmChoice
import ai.oriveo.community.core.context.ContextCapConfirmCoordinator
import ai.oriveo.community.core.context.ContextCompactionMode
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.PendingContextCapConfirmation
import ai.oriveo.community.core.data.repository.ChatContextProjector
import ai.oriveo.community.core.data.repository.ContextCompactionCoordinator
import ai.oriveo.community.core.data.repository.ContextCompactionResult
import ai.oriveo.community.core.data.repository.ContextCompactionStore
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ActiveModelSelection
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContentKind
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.model.QuotePromptBuilder
import ai.oriveo.community.core.model.isMissingCredentialForNewChat
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/**
 * Transcript separator of the latestValid row. It is drawn on top of the item of
 * [drawAboveMessageId] (the first message after coversTo); when coversTo is the last message it is drawn at the
 * bottom of the coversTo item instead. No extra LazyColumn item, so list indices and keys stay unchanged.
 */
data class TranscriptCompactionSeparator(
    val separator: ContextCompactionSeparator,
    val detail: ContextCompactionDetail,
    val drawAboveMessageId: String?,
)

/** Result toasts of the compaction actions; a summary result shows none. */
enum class ContextCompactionToast(@param:StringRes val messageRes: Int, private val style: GlobalToastStyle) {
    CLEARED(R.string.context_compaction_toast_cleared, GlobalToastStyle.Success),
    FALLBACK(R.string.context_compaction_toast_fallback, GlobalToastStyle.Warning),
    NOOP(R.string.context_compaction_toast_noop, GlobalToastStyle.Info),
    ;

    /** GlobalSnackbarManager message shown for this result. */
    fun snackbarMessage() = GlobalSnackbarMessage(UiText.Resource(messageRes), style)
}

/**
 * after a local save leaves exactly 3 rows, hint once per conversation per process.
 * One instance per process (DI single), fed by ContextCompactionCoordinator's onSaved.
 */
class ThirdCompactionHint {
    private val shown = ConcurrentHashMap.newKeySet<String>()
    private val _hint = MutableStateFlow<String?>(null)

    /** Conversation id whose hint is showing, or null. */
    val hint: StateFlow<String?> = _hint.asStateFlow()

    fun onSaved(conversationId: String, localCount: Int) {
        if (localCount == HINT_COUNT && shown.add(conversationId)) _hint.value = conversationId
    }

    fun dismiss() {
        _hint.value = null
    }

    private companion object {
        const val HINT_COUNT = 3
    }
}

/** Chat-page compaction collaborators handed to ChatViewModel as one DI bundle; null in unit tests. */
class ChatCompactionDeps(
    val chatRepository: ChatRepository,
    val store: ContextCompactionStore,
    val thirdHint: ThirdCompactionHint,
    val conversationRepository: ConversationRepository,
    val accountId: () -> String,
    /** Rule 9: AI summary in progress / cancel; null in tests that do not wire it. */
    val contextCompaction: ContextCompactionCoordinator? = null,
    /** composer usage ring; null in tests that do not wire it. */
    val ledger: ai.oriveo.community.core.data.dao.ContextLedgerDao? = null,
    /** Pre-send confirmation gate (same instance ChatRepository suspends on); null in tests that do not wire it. */
    val contextCapConfirm: ContextCapConfirmCoordinator? = null,
    /**
     * limit B of the conversation's current cap and window, as the send computes it
     * (ContextCapViewModel.currentB); a null result = connection unresolved (keeps the manifest's B), a null B
     * inside = window unknown. null (unit tests) keeps the manifest's B.
     */
    val contextWindowB: (suspend (Conversation) -> ContextCurrentB?)? = null,
    /** Global default cap, so the usage ring recomputes B when it changes; null in tests that do not wire it. */
    val contextDefaultCap: kotlinx.coroutines.flow.Flow<ai.oriveo.community.core.context.ContextBudgetCap>? = null,
)

/**
 * Chat-page compaction actions: clear, recompact, manual compact.
 * Remote deletes go out only when sync is bound to the account the rows were deleted under.
 */
class ChatCompactionUiCoordinator(
    private val store: ContextCompactionStore,
    private val accountId: () -> String,
    private val loadConversation: suspend (String) -> Conversation?,
    private val memoryItems: () -> List<MemoryItem>,
    /** Same context request the chat send builds (ChatSendCoordinator.manualCompactionContext). */
    private val chatContext: suspend (Conversation, List<MemoryItem>) -> ChatContextRequest,
    /** Same max output / funding preference as the chat send. */
    private val requestOptions: suspend (Conversation) -> ChatRequestOptions,
    private val compactNow: suspend (String, ChatContextRequest, ChatRequestOptions) -> ContextCompactionResult,
    private val thirdHint: ThirdCompactionHint = ThirdCompactionHint(),
    /** Same rhoHi source as the send path (ChatRepository.currentRhoHi). */
    private val rhoHi: suspend (Conversation) -> Double = { ContextBudget.RHO0 },
    /** ViewModel side (scope, observed conversation, new-chat hook); null keeps only the suspend API. */
    private val host: Host? = null,
    /** Rule 9: conversations whose AI summary call is running (ContextCompactionCoordinator.aiCompacting). */
    val aiCompacting: StateFlow<Set<String>> = MutableStateFlow(emptySet()),
    /** Compactions inside a send (ContextCompactionCoordinator.sendCompacting); only these show the stop button. */
    val sendCompacting: StateFlow<Set<String>> = MutableStateFlow(emptySet()),
    /** Rule 9: cancels the running AI summary of a conversation (ContextCompactionCoordinator.cancel). */
    private val cancelAi: (String) -> Unit = {},
    /** Rule 10: background pre-compaction (ChatRepository.precompactIfNeeded); failures stay silent. */
    private val precompact: suspend (String, ChatContextRequest, ChatRequestOptions) -> ContextCompactionResult =
        { _, _, _ -> ContextCompactionResult(CompactOutcome.NOOP, null, emptyList()) },
    /** breaker mode of a conversation (ContextCompactionCoordinator.breaker). */
    private val breakerMode: (String) -> ContextCompactionMode = { ContextCompactionMode.LLM },
    /** user retry clears the breaker (ContextCompactionCoordinator.retry). */
    private val retryBreaker: (String) -> Unit = {},
    /** catalog display name of a model id under the conversation's provider; null when unknown. */
    private val modelName: (Conversation, String) -> String? = { _, _ -> null },
    /** sends waiting at the confirmation gate (ContextCapConfirmCoordinator.pending). */
    private val pendingConfirmations: StateFlow<List<PendingContextCapConfirmation>> = MutableStateFlow(emptyList()),
    /** answers one waiting confirmation (ContextCapConfirmCoordinator.resolve). */
    private val resolveConfirm: (String, ContextCapConfirmChoice) -> Unit = { _, _ -> },
    /** cancels every waiting confirmation of a conversation (ContextCapConfirmCoordinator.cancelConversation). */
    private val cancelConfirm: (String) -> Unit = {},
) {
    private val precompacting = ConcurrentHashMap.newKeySet<String>()

    /**
     * Rule 10: composer focus or first input starts one background pre-compaction of the shown conversation.
     * Skipped while one is already running for it; the eligibility (AI mode, not Free, 0.75·B) is the repository's.
     */
    fun launchPrecompact(): Job? {
        val host = host ?: return null
        val conversationId = currentConversationId ?: return null
        if (conversationId in aiCompacting.value || !precompacting.add(conversationId)) return null
        return host.scope.launch {
            try {
                val conversation = loadConversation(conversationId) ?: return@launch
                precompact(conversationId, chatContext(conversation, memoryItems()), requestOptions(conversation))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w(LOG_TAG, "precompact failed: ${e.message}")
            } finally {
                precompacting.remove(conversationId)
            }
        }
    }

    /** Rule 10: first input (empty → non-empty) of the composer starts the same background pre-compaction. */
    fun onComposerInput(previous: String, text: String) {
        if (previous.isEmpty() && text.isNotEmpty()) launchPrecompact()
    }

    /** breaker mode of the shown conversation; LLM without one. */
    fun breakerModeHere(): ContextCompactionMode =
        currentConversationId?.let(breakerMode) ?: ContextCompactionMode.LLM

    /** [Retry] of the context panel clears the shown conversation's breaker. */
    fun retryBreakerHere() {
        currentConversationId?.let(retryBreaker)
    }

    /** Rule 9: cancel button of the in-progress row; pre-send falls back and still sends, manual saves nothing. */
    fun cancelAiCompaction(conversationId: String) {
        cancelAi(conversationId)
        // stopping the send also cancels its waiting confirmation (the gate rolls it back).
        cancelConfirm(conversationId)
    }

    /** the shown conversation's send waiting for the confirmation dialog; always null without a host. */
    val pendingConfirm: StateFlow<PendingContextCapConfirmation?> by lazy {
        val host = host ?: return@lazy MutableStateFlow(null)
        combine(host.conversation.map { it.conversation?.id }, pendingConfirmations) { id, pending ->
            pending.firstOrNull { it.conversationId == id }
        }.stateIn(host.scope, SharingStarted.Eagerly, null)
    }

    /** [Send anyway]; [dontAsk] is the checkbox (only shown for the price line). */
    fun confirmContextCap(confirmationId: String, dontAsk: Boolean) =
        resolveConfirm(confirmationId, ContextCapConfirmChoice.Send(dontAsk))

    /** [Cancel], tap outside or back: the gate rolls the send back. */
    fun cancelContextCap(confirmationId: String) = resolveConfirm(confirmationId, ContextCapConfirmChoice.Cancel)

    /**
     * the stop button while the shown conversation waits for the dialog cancels it (rolled
     * back, no stop recorded). False when nothing waits, so the caller stops the generation as usual.
     */
    fun stopWaitingConfirmHere(): Boolean {
        val conversationId = currentConversationId ?: return false
        if (pendingConfirmations.value.none { it.conversationId == conversationId }) return false
        cancelConfirm(conversationId)
        return true
    }

    /**
     * the stop button of a send. Cancels its waiting confirmation; the AI summary is cancelled only when
     * the conversation is not compacting inside a send. A send compaction ends with the send itself
     * (stopStream cancels the send coroutine), so cancelling its summary first would let it fall back and save a
     * fallback row before the stop lands.
     */
    fun stopSend(conversationId: String) {
        cancelConfirm(conversationId)
        if (conversationId !in sendCompacting.value) cancelAi(conversationId)
    }

    class Host(
        val scope: CoroutineScope,
        val conversation: StateFlow<ConversationRenderState>,
        val startNewChatWith: suspend (QuoteContext?) -> String?,
    )

    private val currentConversationId: String? get() = host?.conversation?.value?.conversation?.id

    /**
     * Rule 1: transcript separator of the latestValid row; refreshed on conversation switch, store changes and
     * message list changes. Always null without a host.
     */
    val separator: StateFlow<TranscriptCompactionSeparator?> by lazy {
        val host = host ?: return@lazy MutableStateFlow(null)
        separatorFlow(
            conversationId = host.conversation.map { it.conversation?.id }.distinctUntilChanged(),
            messagesChanged = host.conversation
                .map { state -> state.conversation?.messages?.map { it.id to it.state } }
                .distinctUntilChanged(),
        ).stateIn(host.scope, SharingStarted.WhileSubscribed(5000), null)
    }

    /** Rule 9: true while the shown conversation's AI summary runs; always false without a host. */
    val aiCompactingHere: StateFlow<Boolean> by lazy {
        val host = host ?: return@lazy MutableStateFlow(false)
        combine(host.conversation.map { it.conversation?.id }, aiCompacting) { id, running -> id != null && id in running }
            .stateIn(host.scope, SharingStarted.WhileSubscribed(5000), false)
    }

    private val _toasts = MutableSharedFlow<ContextCompactionToast>(extraBufferCapacity = 4)

    /** Result toasts of the launch* actions; the UI maps them to GlobalSnackbarManager messages. */
    val toasts: SharedFlow<ContextCompactionToast> = _toasts.asSharedFlow()

    private val _providerDetailRequests = MutableSharedFlow<String>(extraBufferCapacity = 1)

    /** A new chat could not open because the connection is missing its credential: carries the connection id so the UI opens that connection's detail page. */
    val providerDetailRequests: SharedFlow<String> = _providerDetailRequests.asSharedFlow()

    private val _actionRunning = MutableStateFlow(false)

    /** True while a launch* action runs; the detail sheet disables "condense again" meanwhile. */
    val actionRunning: StateFlow<Boolean> = _actionRunning.asStateFlow()

    fun launchManualCompact() = launchAction { manualCompact(it) }

    fun launchClear() = launchAction { clear(it) }

    fun launchRecompact() = launchAction { recompact(it) }

    /**
     * Rule 7: new chat on the same provider/model with the latest summary attached as a pending quote; not sent.
     * [label] is the localized quote_label supplied by the UI.
     */
    fun startNewChatWithSummary(label: String): Job? {
        val host = host ?: return null
        val conversationId = currentConversationId
        thirdHint.dismiss()
        return host.scope.launch {
            host.startNewChatWith(conversationId?.let { quoteForNewChat(it, label) })?.let(_providerDetailRequests::tryEmit)
        }
    }

    private fun launchAction(action: suspend (String) -> ContextCompactionToast?): Job? {
        val host = host ?: return null
        val conversationId = currentConversationId ?: return null
        if (!_actionRunning.compareAndSet(expect = false, update = true)) return null
        return host.scope.launch {
            val toast = try {
                action(conversationId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A failed store / network action must not crash the app; it shows no result toast.
                android.util.Log.w(LOG_TAG, "compaction action failed: ${e.message}")
                null
            } finally {
                _actionRunning.value = false
            }
            toast?.let(_toasts::tryEmit)
        }
    }

    /** Rule 6: conversation id whose third-compaction hint is showing. */
    val hint: StateFlow<String?> get() = thirdHint.hint

    fun dismissHint() = thirdHint.dismiss()

    /** Rule 7: the quote for "new chat with summary", built from the latestValid row; null when there is none. */
    suspend fun quoteForNewChat(conversationId: String, label: String): QuoteContext? {
        val conversation = loadConversation(conversationId) ?: return null
        val history = ChatContextProjector.compactionHistory(conversation.messages, ContextBudget.RHO0)
            .map { CheckpointCoveredMessage(it.id, it.text) }
        val row = store.latestValid(accountId(), conversationId, history) ?: return null
        return summaryQuote(row, conversation.messages, label)
    }

    /**
     * Rule 1: separator of the latestValid row, computed over the full stored history (not the paged window),
     * the same history latestValid is checked against. Null when there is no valid row.
     */
    suspend fun transcriptSeparator(conversationId: String): TranscriptCompactionSeparator? {
        val conversation = loadConversation(conversationId) ?: return null
        val rho = rhoHi(conversation)
        val history = ChatContextProjector.compactionHistory(conversation.messages, rho)
            .map { CheckpointCoveredMessage(it.id, it.text) }
        val row = store.latestValid(accountId(), conversationId, history) ?: return null
        // Same quote-expanded text the send path estimates with.
        val expanded = QuotePromptBuilder.applyToMessages(conversation.messages)
        val separator = ContextCompactionPresentation.separator(row, expanded, rho) { id -> modelName(conversation, id) }
            ?: return null
        val anchorIndex = conversation.messages.indexOfFirst { it.id == row.coversTo }
        return TranscriptCompactionSeparator(
            separator = separator,
            detail = ContextCompactionPresentation.detail(row),
            drawAboveMessageId = conversation.messages.getOrNull(anchorIndex + 1)?.id,
        )
    }

    /**
     * Rule 1: recomputes [transcriptSeparator] on conversation switch, on every store change of the current
     * conversation, and whenever [messagesChanged] emits.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun separatorFlow(
        conversationId: Flow<String?>,
        messagesChanged: Flow<Any?>,
    ): Flow<TranscriptCompactionSeparator?> =
        combine(conversationId, messagesChanged) { id, _ -> id }
            .flatMapLatest { id ->
                if (id == null) {
                    flowOf(null)
                } else {
                    store.changes
                        .filter { it == id }
                        .map { }
                        .onStart { emit(Unit) }
                        .mapLatest { transcriptSeparator(id) }
                }
            }
            // The digest and token estimates walk the whole history; keep them off the main thread.
            .flowOn(Dispatchers.Default)

    /** Rule 3: deletes every row of the conversation locally. */
    suspend fun clear(conversationId: String): ContextCompactionToast {
        val account = accountId()
        val ids = store.deleteAll(account, conversationId)
        return ContextCompactionToast.CLEARED
    }

    /** Rule 4: drops the latestValid row, then runs the manual compaction of rule 5. */
    suspend fun recompact(conversationId: String): ContextCompactionToast? {
        val conversation = loadConversation(conversationId) ?: return ContextCompactionToast.NOOP
        val account = accountId()
        val history = ChatContextProjector.compactionHistory(conversation.messages, ContextBudget.RHO0)
            .map { CheckpointCoveredMessage(it.id, it.text) }
        store.latestValid(account, conversationId, history)?.let { latest ->
            val ids = listOf(latest.checkpointId)
            store.delete(account, conversationId, ids)
            }
        return manualCompact(conversation)
    }

    /** Rule 5: summary → no toast, fallback → FALLBACK, noop → NOOP. */
    suspend fun manualCompact(conversationId: String): ContextCompactionToast? {
        val conversation = loadConversation(conversationId) ?: return ContextCompactionToast.NOOP
        return manualCompact(conversation)
    }

    private suspend fun manualCompact(conversation: Conversation): ContextCompactionToast? {
        val result = compactNow(
            conversation.id,
            chatContext(conversation, memoryItems()),
            requestOptions(conversation),
        )
        return when (result.outcome) {
            CompactOutcome.SUMMARY -> null
            CompactOutcome.FALLBACK -> ContextCompactionToast.FALLBACK
            CompactOutcome.NOOP -> ContextCompactionToast.NOOP
        }
    }

    companion object {
        private const val PARAGRAPH = "\n\n"
        private const val LOG_TAG = "ChatCompactionUi"

        /** ChatViewModel wiring: same context / options / rhoHi sources as the chat send path; null without deps. */
        internal fun forChat(
            deps: ChatCompactionDeps?,
            sendCoordinator: ChatSendCoordinator,
            quoteCoordinator: ChatQuoteCoordinator,
            memoryItems: StateFlow<List<MemoryItem>>,
            scope: CoroutineScope,
            conversation: StateFlow<ConversationRenderState>,
            startNewChat: () -> String?,
            /** Same provider list the chat send resolves against; feeds the separator's model display name. */
            providers: () -> List<Provider> = { emptyList() },
        ): ChatCompactionUiCoordinator? =
            deps?.let { wire(it, sendCoordinator, quoteCoordinator, memoryItems, scope, conversation, startNewChat, providers) }

        private fun wire(
            deps: ChatCompactionDeps,
            sendCoordinator: ChatSendCoordinator,
            quoteCoordinator: ChatQuoteCoordinator,
            memoryItems: StateFlow<List<MemoryItem>>,
            scope: CoroutineScope,
            conversation: StateFlow<ConversationRenderState>,
            startNewChat: () -> String?,
            providers: () -> List<Provider>,
        ) = ChatCompactionUiCoordinator(
            store = deps.store,
            accountId = deps.accountId,
            loadConversation = { id -> deps.conversationRepository.getWithMessages(id) },
            memoryItems = { memoryItems.value },
            chatContext = sendCoordinator::manualCompactionContext,
            requestOptions = sendCoordinator::manualCompactionRequestOptions,
            compactNow = { id, chatContext, requestOptions ->
                deps.chatRepository.compactConversationNow(id, chatContext, requestOptions)
            },
            thirdHint = deps.thirdHint,
            rhoHi = deps.chatRepository::currentRhoHi,
            host = newChatHost(scope, conversation, quoteCoordinator, startNewChat),
            aiCompacting = deps.contextCompaction?.aiCompacting ?: MutableStateFlow(emptySet()),
            sendCompacting = deps.contextCompaction?.sendCompacting ?: MutableStateFlow(emptySet()),
            cancelAi = { id -> deps.contextCompaction?.cancel(id) },
            breakerMode = { id -> deps.contextCompaction?.breaker(id)?.mode ?: ContextCompactionMode.LLM },
            retryBreaker = { id -> deps.contextCompaction?.retry(id) },
            precompact = { id, chatContext, requestOptions ->
                deps.chatRepository.precompactIfNeeded(id, chatContext, requestOptions)
            },
            modelName = { conversation, modelId -> catalogModelName(providers(), conversation, modelId) },
            pendingConfirmations = deps.contextCapConfirm?.pending ?: MutableStateFlow(emptyList()),
            resolveConfirm = { id, choice -> deps.contextCapConfirm?.resolve(id, choice) },
            cancelConfirm = { id -> deps.contextCapConfirm?.cancelConversation(id) },
        )

        /**
         * [modelId]'s name in the conversation provider's model list, then the catalog display name;
         * null when neither has one (the separator then shows the id).
         */
        internal fun catalogModelName(
            providers: List<Provider>,
            conversation: Conversation,
            modelId: String,
            catalogDisplayName: (String, ProviderKind) -> String? = { id, kind ->
                MetadataClient.instance.resolveCatalogModel(id, kind)?.displayName
            },
        ): String? =
            providers.firstOrNull { it.id == conversation.providerID }
                ?.models
                ?.firstOrNull { it.id == modelId }
                ?.name
                ?.takeIf { it.isNotBlank() }
                ?: catalogDisplayName(modelId, conversation.providerKind)?.takeIf { it.isNotBlank() }

        /** Rule 7 host: reset to a new chat (same provider/model), then attach the quote as pending; not sent. */
        internal fun newChatHost(
            scope: CoroutineScope,
            conversation: StateFlow<ConversationRenderState>,
            quoteCoordinator: ChatQuoteCoordinator,
            startNewChat: () -> String?,
        ) = Host(scope, conversation) { quote ->
            startNewChat().also { blocked -> if (blocked == null) quoteCoordinator.restore(quote) }
        }

        /**
         * Keeps the current model for a new chat. A connection missing its credential returns its id (the caller opens that
         * connection's detail page, nothing is written); a usable model is written as last used and opens the new chat; otherwise
         * the new-chat chain is resolved from this connection, and an empty chain also returns the connection id.
         */
        internal fun keepModelForNewChat(
            provider: Provider?,
            model: AIModel?,
            sendable: Boolean,
            lastUsed: LastUsedModelRef?,
            writeLastUsed: (Provider, AIModel) -> Unit,
            open: (ActiveModelSelection?) -> Unit,
        ): String? {
            if (provider?.isMissingCredentialForNewChat() == true) return provider.id
            if (provider == null) {
                open(null)
                return null
            }
            if (model != null && sendable) {
                writeLastUsed(provider, model)
                open(null)
                return null
            }
            val chain = resolveActiveModel(listOf(provider), lastUsed?.takeIf { it.providerID == provider.id })
                ?: return provider.id
            open(chain)
            return null
        }

        internal fun lastUsedWriter(preferences: AppPreferencesRepository, scope: CoroutineScope): (Provider, AIModel) -> Unit =
            { provider, model ->
                preferences.primeLastUsedModel(provider.id, model.id)
                scope.launch { preferences.setLastUsedModel(provider.id, model, provider.kind) }
            }

        /**
         * Rule 7: selectedText is the row's summary when non-blank, else the kept user messages in time order,
         * one paragraph each. Over the grapheme cap the summary is cut at the tail; messages drop from the oldest,
         * and a lone remaining message is cut at the tail; any cut or drop marks contextTruncated. Null when the
         * result is not a valid quote.
         */
        fun summaryQuote(row: ContextCheckpointRecord, messages: List<ChatMessage>, label: String): QuoteContext? {
            val budget = QuoteContext.MAXIMUM_GRAPHEME_COUNT - label.graphemeCount()
            if (budget <= 0) return null
            val summary = row.summary?.trim().orEmpty()
            val texts = if (summary.isNotEmpty()) {
                mutableListOf(summary)
            } else {
                val kept = row.userMessageIds.toSet()
                // Conversation messages are already in time order.
                messages.filter { it.id in kept }.map { it.text.trim() }.filter { it.isNotEmpty() }.toMutableList()
            }
            val full = texts.joinToString(PARAGRAPH)
            while (texts.size > 1 && texts.joinToString(PARAGRAPH).graphemeCount() > budget) texts.removeAt(0)
            val selected = texts.joinToString(PARAGRAPH).takeGraphemes(budget)
            return QuoteContext(
                sourceMessageId = row.coversTo,
                sourceRole = ChatRole.Assistant,
                contentKind = QuoteContentKind.Prose,
                leadingText = label,
                selectedText = selected,
                trailingText = "",
                contextTruncated = selected != full,
            ).takeIf { it.isValid }
        }
    }
}
