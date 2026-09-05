package ai.oriveo.community.feature.chat

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.ui.component.markdown.MarkdownColors
import ai.oriveo.community.ui.component.markdown.MarkdownRenderCache
import ai.oriveo.community.ui.component.markdown.shouldPrewarmMarkdown
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import androidx.metrics.performance.PerformanceMetricsState

@Composable
internal fun ChatPinToTopEffect(
    pendingPinUserMessageId: String?,
    latestMessages: List<ChatMessage>,
    listState: LazyListState,
    scrollController: ChatScrollController,
    minAssistantVisiblePx: Int,
    consumePendingPin: () -> Unit,
) {
    val latestMessagesState = rememberUpdatedState(latestMessages)

    LaunchedEffect(pendingPinUserMessageId) {
        val pinId = pendingPinUserMessageId ?: return@LaunchedEffect
        
        snapshotFlow {
            val idx = latestMessagesState.value.indexOfFirst { it.id == pinId }
            idx >= 0 && listState.layoutInfo.totalItemsCount > idx
        }.filter { it }.first()

        val userIndex = latestMessagesState.value.indexOfFirst { it.id == pinId }
        if (userIndex < 0) {
            consumePendingPin()
            return@LaunchedEffect
        }
        scrollController.pinToTop(
            listState = listState,
            pinId = pinId,
            userIndex = userIndex,
            minAssistantVisiblePx = minAssistantVisiblePx,
        )
        consumePendingPin()
    }
}

@Composable
internal fun ChatFollowToBottomEffect(
    listState: LazyListState,
    scrollController: ChatScrollController,
    isPointerDown: Boolean,
) {
    val latestIsPointerDown = rememberUpdatedState(isPointerDown)

    LaunchedEffect(Unit) {
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()
            val overflow = if (last != null && last.index >= info.totalItemsCount - 1) {
                last.offset + last.size - info.viewportEndOffset
            } else {
                0
            }
            overflow.coerceAtLeast(0)
        }
            .distinctUntilChanged()
            .collect { overflow ->
                scrollController.followToBottom(listState, overflow, latestIsPointerDown.value)
            }
    }
}

@Composable
internal fun ChatStreamingModeEffect(
    isGenerating: Boolean,
    scrollController: ChatScrollController,
) {
    LaunchedEffect(isGenerating) {
        scrollController.updateStreamingMode(isGenerating)
    }
}

@Composable
internal fun ChatInitialScrollToBottomEffect(
    conversationId: String?,
    initialConversationId: String?,
    enabled: Boolean = true,
    latestMessageCount: Int,
    composerOverlayHeightPx: Int,
    listState: LazyListState,
    scrollController: ChatScrollController,
    onInitialBottomSettledConversationChange: (String?) -> Unit,
) {
    val latestMessageCountState = rememberUpdatedState(latestMessageCount)
    val composerOverlayHeightPxState = rememberUpdatedState(composerOverlayHeightPx)

    LaunchedEffect(conversationId) {
        if (!enabled) return@LaunchedEffect
        if (conversationId == null || conversationId != initialConversationId) return@LaunchedEffect
        onInitialBottomSettledConversationChange(null)
        scrollController.reset()
        
        snapshotFlow { latestMessageCountState.value to composerOverlayHeightPxState.value }
            .filter { (size, h) -> size > 0 && h > 0 }
            .first()
        scrollController.scrollToBottom(listState, latestMessageCountState.value)
        scrollController.resumeFollowing()
        onInitialBottomSettledConversationChange(conversationId)
    }
}

@Composable
internal fun ChatSearchScrollTargetEffect(
    conversationId: String?,
    searchQuery: String?,
    targetIndex: Int,
    latestMessageCount: Int,
    composerOverlayHeightPx: Int,
    listState: LazyListState,
    scrollController: ChatScrollController,
) {
    val latestMessageCountState = rememberUpdatedState(latestMessageCount)
    val composerOverlayHeightPxState = rememberUpdatedState(composerOverlayHeightPx)

    LaunchedEffect(conversationId, searchQuery, targetIndex) {
        if (conversationId == null || searchQuery.isNullOrBlank()) return@LaunchedEffect
        scrollController.reset()
        snapshotFlow { latestMessageCountState.value to composerOverlayHeightPxState.value }
            .filter { (size, h) -> size > 0 && h > 0 }
            .first()
        if (targetIndex >= 0 && targetIndex < latestMessageCountState.value) {
            listState.scrollToItem(targetIndex)
        } else {
            listState.scrollToItem(0)
        }
    }
}

@Composable
internal fun ChatManagedLoginEffect(
    loginRequests: SharedFlow<Unit>,
    onRequireManagedLogin: () -> Unit,
) {
    val latestOnRequireManagedLogin = rememberUpdatedState(onRequireManagedLogin)

    LaunchedEffect(loginRequests) {
        loginRequests.collect {
            latestOnRequireManagedLogin.value()
        }
    }
}

@Composable
internal fun ChatImeLatestTrackingEffect(
    listState: LazyListState,
    imeBottomPx: Int,
    onWasAtLatestBeforeImeChange: (Boolean) -> Unit,
) {
    LaunchedEffect(listState, imeBottomPx) {
        if (imeBottomPx > 0) return@LaunchedEffect
        snapshotFlow { !listState.canScrollForward }
            .distinctUntilChanged()
            .collect { atLatest ->
                onWasAtLatestBeforeImeChange(atLatest)
            }
    }
}

@Composable
internal fun ChatImeFollowEffect(
    listState: LazyListState,
    imeInsets: WindowInsets,
    density: Density,
    scrollController: ChatScrollController,
    wasAtLatestBeforeIme: Boolean,
    isPointerDown: Boolean,
) {
    val latestWasAtLatestBeforeIme = rememberUpdatedState(wasAtLatestBeforeIme)
    val latestIsPointerDown = rememberUpdatedState(isPointerDown)

    LaunchedEffect(listState) {
        var previousImeBottom = imeInsets.getBottom(density)
        snapshotFlow { imeInsets.getBottom(density) }
            .collect { currentImeBottom ->
                val delta = currentImeBottom - previousImeBottom
                previousImeBottom = currentImeBottom
                scrollController.followImeInset(
                    listState = listState,
                    deltaPx = delta,
                    wasAtLatestBeforeIme = latestWasAtLatestBeforeIme.value,
                    isPointerDown = latestIsPointerDown.value,
                )
            }
    }
}

@Composable
internal fun ChatAnchorTransitionEffect(
    listState: LazyListState,
    scrollController: ChatScrollController,
    isPointerDown: Boolean,
    hideKeyboard: () -> Unit,
) {
    val latestIsPointerDown = rememberUpdatedState(isPointerDown)
    val latestHideKeyboard = rememberUpdatedState(hideKeyboard)

    LaunchedEffect(listState) {
        var prevFirstVisibleIndex = listState.firstVisibleItemIndex
        var prevFirstVisibleOffset = listState.firstVisibleItemScrollOffset
        snapshotFlow {
            ChatScrollSignal(
                scrolling = listState.isScrollInProgress,
                canScrollForward = listState.canScrollForward,
                firstVisibleIndex = listState.firstVisibleItemIndex,
                firstVisibleOffset = listState.firstVisibleItemScrollOffset,
            )
        }
            .distinctUntilChanged()
            .collect { signal ->
                val scrolledUp = isScrolledUp(
                    prevFirstVisibleIndex = prevFirstVisibleIndex,
                    prevFirstVisibleOffset = prevFirstVisibleOffset,
                    curFirstVisibleIndex = signal.firstVisibleIndex,
                    curFirstVisibleOffset = signal.firstVisibleOffset,
                )
                prevFirstVisibleIndex = signal.firstVisibleIndex
                prevFirstVisibleOffset = signal.firstVisibleOffset

                val transition = decideAnchorTransition(
                    anchored = scrollController.isAnchored,
                    anchorDetached = !scrollController.following,
                    isPointerDown = latestIsPointerDown.value,
                    signal = signal,
                    scrolledUp = scrolledUp,
                )
                if (scrollController.applyTransition(transition)) {
                    latestHideKeyboard.value()
                }
            }
    }
}


@Composable
internal fun ChatLoadMoreAboveEffect(
    listState: LazyListState,
    hasMoreAbove: StateFlow<Boolean>,
    isLoadingAbove: StateFlow<Boolean>,
    loadMoreAbove: () -> Unit,
) {
    val canLoadMore by hasMoreAbove.collectAsStateWithLifecycle()
    val isLoading by isLoadingAbove.collectAsStateWithLifecycle()

    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            if (info.totalItemsCount <= 0) -1 else listState.firstVisibleItemIndex
        }
            .distinctUntilChanged()
            .collect { firstVisible ->
                
                if (firstVisible in 0..MESSAGE_WINDOW_LOAD_MORE_THRESHOLD &&
                    canLoadMore &&
                    !isLoading
                ) {
                    loadMoreAbove()
                }
            }
    }
}

@Composable
internal fun ChatLoadMoreBelowEffect(
    listState: LazyListState,
    hasMoreBelow: StateFlow<Boolean>,
    isLoadingBelow: StateFlow<Boolean>,
    loadMoreBelow: () -> Unit,
) {
    val canLoadMore by hasMoreBelow.collectAsStateWithLifecycle()
    val isLoading by isLoadingBelow.collectAsStateWithLifecycle()

    LaunchedEffect(listState) {
        snapshotFlow {
            val visible = listState.layoutInfo.visibleItemsInfo
            val lastVisible = visible.lastOrNull()?.index ?: -1
            listState.layoutInfo.totalItemsCount to lastVisible
        }
            .distinctUntilChanged()
            .collect { (totalItems, lastVisible) ->
                if (totalItems > 0 &&
                    lastVisible >= 0 &&
                    totalItems - 1 - lastVisible <= MESSAGE_WINDOW_LOAD_MORE_THRESHOLD &&
                    canLoadMore &&
                    !isLoading
                ) {
                    loadMoreBelow()
                }
            }
    }
}

@Composable
internal fun ChatMarkdownPrewarmEffect(
    assistantPrewarmFingerprint: Int,
    markdownColors: MarkdownColors,
    messages: List<ChatMessage>,
) {
    LaunchedEffect(assistantPrewarmFingerprint, markdownColors) {
        val staticAssistantMessages = recentMarkdownPrewarmTargets(messages)
        if (staticAssistantMessages.isEmpty()) return@LaunchedEffect

        withFrameNanos { }
        withContext(Dispatchers.Default) {
            staticAssistantMessages.forEach { message ->
                MarkdownRenderCache.prewarm(message.text, markdownColors)
            }
        }
    }
}

@Composable
internal fun ChatMissingConversationExitEffect(
    conversationId: String?,
    conversation: Conversation?,
    hasMissingInitialConversation: Boolean,
    isGenerating: Boolean,
    isUserInitiatedExit: Boolean,
    hasLoadedConversation: Boolean,
    onHasLoadedConversationChange: (Boolean) -> Unit,
    onBack: () -> Unit,
) {
    LaunchedEffect(conversationId, hasMissingInitialConversation, isGenerating) {
        
        if (isUserInitiatedExit) return@LaunchedEffect
        if (conversation != null) {
            onHasLoadedConversationChange(true)
        } else if (
            !isGenerating &&
            (
                hasMissingInitialConversation ||
                    hasLoadedConversation
                )
        ) {
            onBack()
        }
    }
}

@Composable
internal fun ChatMetricsEffect(
    metricsStateHolder: PerformanceMetricsState.Holder,
    listState: LazyListState,
    isGenerating: Boolean,
) {
    LaunchedEffect(metricsStateHolder, listState) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collect { isScrolling ->
                if (isScrolling) {
                    metricsStateHolder.state?.putState("chat_list", "scrolling")
                } else {
                    metricsStateHolder.state?.removeState("chat_list")
                }
            }
    }

    LaunchedEffect(metricsStateHolder, isGenerating) {
        if (isGenerating) {
            metricsStateHolder.state?.putState("chat_generation", "streaming")
        } else {
            metricsStateHolder.state?.removeState("chat_generation")
        }
    }
}

@Composable
internal fun ChatScreenLeavingEffect(
    handleScreenLeaving: () -> Unit,
) {
    
    DisposableEffect(Unit) {
        onDispose {
            handleScreenLeaving()
        }
    }
}


@Composable
internal fun ChatNoteEffects(
    focusMessageId: String?,
    conversationId: String?,
    messages: List<ChatMessage>,
    hasMoreAbove: Boolean,
    isLoadingAbove: Boolean,
    isInitialLoading: Boolean,
    listState: LazyListState,
    scrollController: ChatScrollController,
    density: Density,
    highlightId: String?,
    lastDeliveredAssistant: ChatMessage?,
    navToNoteDetail: SharedFlow<String>,
    onLoadMoreAbove: () -> Unit,
    onLoadFocusMessageWindow: (String) -> Unit,
    onSetHighlight: (String?) -> Unit,
    onNavigateToNoteDetail: (String) -> Unit,
    onMaybeShowHint: () -> Unit,
) {
    
    
    var focusHandled by remember(conversationId, focusMessageId) { mutableStateOf(false) }
    var focusHydrationRequested by remember(conversationId, focusMessageId) { mutableStateOf(false) }
    LaunchedEffect(focusMessageId, conversationId, messages, hasMoreAbove, isLoadingAbove, isInitialLoading) {
        val target = focusMessageId ?: return@LaunchedEffect
        if (focusHandled || conversationId == null) return@LaunchedEffect
        if (isInitialLoading) return@LaunchedEffect
        val idx = messages.indexOfFirst { it.id == target }
        when {
            idx >= 0 -> {
                focusHandled = true
                scrollController.stopFollowingForJump()
                val gapPx = with(density) { 16.dp.roundToPx() }
                listState.scrollToItem(idx, listState.layoutInfo.viewportStartOffset + gapPx)
                onSetHighlight(target)
            }
            !focusHydrationRequested -> {
                focusHydrationRequested = true
                onLoadFocusMessageWindow(target)
            }
            hasMoreAbove && !isLoadingAbove -> Unit
        }
    }

    
    LaunchedEffect(highlightId) {
        if (highlightId != null) {
            delay(2200)
            onSetHighlight(null)
        }
    }

    
    LaunchedEffect(Unit) {
        navToNoteDetail.collect { noteId -> onNavigateToNoteDetail(noteId) }
    }

    
    LaunchedEffect(lastDeliveredAssistant?.id) {
        if (lastDeliveredAssistant != null && lastDeliveredAssistant.text.isNotBlank()) {
            onMaybeShowHint()
        }
    }
}

internal fun recentMarkdownPrewarmTargets(messages: List<ChatMessage>): List<ChatMessage> {
    if (messages.isEmpty()) return emptyList()
    val collected = ArrayList<ChatMessage>(MARKDOWN_PREWARM_RECENT_MESSAGE_LIMIT)
    recentPrewarmCandidatesReverse(messages) { collected.add(it) }
    return collected.asReversed()
}

internal fun assistantMarkdownPrewarmFingerprint(messages: List<ChatMessage>): Int {
    
    
    
    var acc = 1
    recentPrewarmCandidatesReverse(messages) { message ->
        acc = (((acc * 31) + message.id.hashCode()) * 31) + message.text.length
    }
    return acc
}

private inline fun recentPrewarmCandidatesReverse(
    messages: List<ChatMessage>,
    block: (ChatMessage) -> Unit,
) {
    var taken = 0
    val limit = MARKDOWN_PREWARM_RECENT_MESSAGE_LIMIT
    for (i in messages.indices.reversed()) {
        val message = messages[i]
        if (
            message.role == ChatRole.Assistant &&
            message.state == ChatMessageState.Delivered &&
            message.text.isNotBlank() &&
            shouldPrewarmMarkdown(message.text)
        ) {
            block(message)
            taken++
            if (taken >= limit) break
        }
    }
}
