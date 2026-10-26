package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.chat.MessageWindowLoader
import ai.oriveo.community.core.model.Conversation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Intermediate carrier of combine(observeMetadata, windowLoader.state); not visible outside. */
private data class ConversationStateBundle(
    val meta: Conversation?,
    val windowState: MessageWindowLoader.State,
)

/**
 * The conversation render stream plus message-window paging. It owns the lifecycle of [MessageWindowLoader]: bound to / stopped
 * by [activeConversationId]; on the first send that creates the conversation the host binds early through [bind], and calls [stop] in onCleared.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class ChatMessageWindowCoordinator(
    private val scope: CoroutineScope,
    private val conversationRepository: ConversationRepository,
    private val activeConversationId: StateFlow<String?>,
) {
    private val loader: MessageWindowLoader = conversationRepository.createMessageWindowLoader()
    // Catches any exception that slips out of a window load (corrupt history rows are already caught and degraded inside MessageWindowLoader); see ChatCoroutineExceptionHandlers.kt
    private val loaderScope: CoroutineScope = messageWindowLoaderScope(scope)

    /** The current conversation render state: metadata plus the tail window of messages. */
    val conversation: StateFlow<ConversationRenderState> = activeConversationId
        .flatMapLatest { conversationId ->
            if (conversationId == null) {
                loader.stop()
                flowOf(ConversationStateBundle(meta = null, windowState = MessageWindowLoader.State()))
            } else {
                loader.bind(loaderScope, conversationId)
                combine(
                    conversationRepository.observeMetadata(conversationId),
                    loader.state,
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
            scope,
            SharingStarted.WhileSubscribed(5000),
            ConversationRenderState(conversation = null),
        )

    // The four paging flows stay WhileSubscribed, but **the subscriber must really subscribe**: ChatLoadMoreAbove/BelowEffect
    // uses collectAsStateWithLifecycle (passing the StateFlow reference down and reading .value does not subscribe:
    // with no subscriber the upstream never starts and .value stays at its initial value, which once turned loadMoreBelow() into dead code).
    // The invariant is guarded by ChatViewModelFlowSubscriptionTest.
    // Note: do not switch to Eagerly for convenience - that keeps coroutines alive in viewModelScope (Dispatchers.Main) without being
    // cancelled by the lifecycle and makes unit tests much flakier (see the comment above the paging effect in ChatScreenEffects.kt).
    /** Derived: whether older messages remain above the window to page into. */
    val hasMoreAbove: StateFlow<Boolean> = derived { it.hasMoreAbove }

    /** Derived: loading older history. */
    val isLoadingAbove: StateFlow<Boolean> = derived { it.isLoadingAbove }

    /** Derived: whether newer messages remain below the window to load (anchored windows only). */
    val hasMoreBelow: StateFlow<Boolean> = derived { it.hasMoreBelow }

    /** Derived: an anchored window is loading downward. */
    val isLoadingBelow: StateFlow<Boolean> = derived { it.isLoadingBelow }

    /** Derived: the first-screen window is loading; locating a note's source must not judge it missing during this time. */
    val isInitialLoading: StateFlow<Boolean> = derived { it.isInitialLoading }

    private fun derived(pick: (MessageWindowLoader.State) -> Boolean): StateFlow<Boolean> = conversation
        .map { pick(it.windowState) }
        .distinctUntilChanged()
        .stateIn(scope, SharingStarted.WhileSubscribed(5000), false)

    /** Bound right after the first send creates the conversation (without waiting for the activeConversationId downstream to resubscribe). */
    fun bind(conversationId: String) = loader.bind(loaderScope, conversationId)

    fun stop() = loader.stop()

    /** Triggered by the UI when the LazyColumn scrolls near the top: asynchronously extends the window upward by 60 messages. */
    fun loadMoreAbove() {
        loaderScope.launch { loader.extendUpward() }
    }

    fun loadMoreBelow() {
        loaderScope.launch { loader.extendDownward() }
    }

    /** A note's "back to conversation": when the local window has been paged through and the target is still missing, tries to load a window around it. */
    fun loadFocusMessageWindow(messageId: String) {
        val conversationId = activeConversationId.value ?: return
        scope.launch { loader.loadAroundMessage(conversationId, messageId) }
    }
}
