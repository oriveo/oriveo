package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.MemoryItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn

/**
 * Memory item state of the chat screen: the items and the toolbar memory indicator.
 * Extracted from ChatViewModel; the VM only assembles and exposes state.
 */
internal class ChatMemoryState(
    scope: CoroutineScope,
    /** MemoryItemRepository.observe; when null (unit tests etc.) there are no items. */
    source: Flow<List<MemoryItem>>?,
    conversation: Flow<ConversationRenderState>,
) {
    /** The memory items (including tombstones; MemoryItems.injectable filters them at injection time); Eagerly so the send path can read .value imperatively. */
    val items: StateFlow<List<MemoryItem>> = (source ?: flowOf(emptyList()))
        .stateIn(scope, SharingStarted.Eagerly, emptyList())

    /** True when memory is on for this conversation and at least one effective semantic item exists. */
    val showIndicator: StateFlow<Boolean> = combine(items, conversation) { items, conversationState ->
        MemoryUsed.hasActiveSemantic(items) && (conversationState.conversation?.useMemory ?: true)
    }.stateIn(scope, SharingStarted.WhileSubscribed(5000), false)
}

/**
 * The send path shared by the retry / sendCommand coordinators: reads the current memory items once per send and injects them.
 * [memoryItems] is evaluated at send time, not read at construction.
 */
internal fun ChatSendCoordinator.memoryInjectingSendLauncher(
    memoryItems: () -> List<MemoryItem>,
) = ChatSendLauncher { conversation, provider, modelId, text, existingMessages, attachments,
    persistUserMessage, appendToAssistant, userMessageAlreadyInHistory, quoteContext, attemptKind ->
    launchSend(
        conversation = conversation,
        provider = provider,
        modelId = modelId,
        text = text,
        memoryItems = memoryItems(),
        existingMessages = existingMessages,
        attachments = attachments,
        quoteContext = quoteContext,
        persistUserMessage = persistUserMessage,
        appendToAssistant = appendToAssistant,
        userMessageAlreadyInHistory = userMessageAlreadyInHistory,
        attemptKind = attemptKind,
    )
}

/** The send path of the fresh-send entry: also injects the memory items and calls back after the user message is persisted. */
internal fun ChatSendCoordinator.memoryInjectingUserSendLauncher(
    memoryItems: () -> List<MemoryItem>,
) = ChatUserSendLauncher { conversation, provider, modelId, text, existingMessages,
    attachments, quoteContext, attemptKind, onUserMessageCreated, memoryPropose ->
    launchSend(
        conversation = conversation,
        provider = provider,
        modelId = modelId,
        text = text,
        memoryItems = memoryItems(),
        existingMessages = existingMessages,
        attachments = attachments,
        quoteContext = quoteContext,
        attemptKind = attemptKind,
        onUserMessageCreated = onUserMessageCreated,
        memoryPropose = memoryPropose,
    )
}
