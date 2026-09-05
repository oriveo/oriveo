package ai.oriveo.community.feature.chat

import android.content.Context
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.feature.chat.components.ChatOutlineRail
import ai.oriveo.community.feature.chat.components.ScrollToBottomButton
import ai.oriveo.community.feature.chat.recovery.MessageItemWithActions
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
internal fun BoxScope.ChatMessagesList(
    messages: List<ChatMessage>,
    streamingMessageId: String?,
    streamingText: StateFlow<String>,
    streamingReasoning: StateFlow<String>,
    
    streamingReasoningActive: StateFlow<Boolean>,
    listState: LazyListState,
    scrollController: ChatScrollController,
    hasMoreAbove: Boolean,
    hasMoreBelow: Boolean,
    displayLookup: ModelDisplayLookup,
    providersById: Map<String, ai.oriveo.community.core.model.Provider>,
    composerOverlayHeightDp: Dp,
    reserveDp: Dp,
    hideInitialListUntilBottomSettled: Boolean,
    isDragging: Boolean,
    onPointerDownChange: (Boolean) -> Unit,
    isGenerating: Boolean,
    isRateLimitError: (ChatMessage) -> Boolean,
    onCopy: (ChatMessage) -> Unit,
    onEdit: (ChatMessage) -> Unit,
    onRegenerate: (String) -> Unit,
    onContinue: (String) -> Unit,
    onRetry: (String) -> Unit,
    onRetryWithoutLocalCustomFields: (String) -> Unit,
    onSwitchModel: () -> Unit,
    onShare: (ChatMessage) -> Unit,
    onSaveAsNote: (ChatMessage) -> Unit,
    onSaveCodeAsNote: (message: ChatMessage, code: String) -> Unit,
    onSaveSelectionAsNote: (message: ChatMessage, text: String) -> Unit,
    onAskSelection: (message: ChatMessage, selection: QuoteSelectionContent) -> Unit,
    onReplaceSelectionInCurrentNote: ((message: ChatMessage, text: String, noteId: String?) -> Unit)? = null,
    onCrosscheck: (ChatMessage) -> Unit,
    savedNoteLinksByMessage: Map<String, List<SavedNoteLink>>,
    returnToNoteId: String?,
    onOpenSavedNote: (String) -> Unit,
    highlightedMessageId: String?,
    context: Context,
    coroutineScope: CoroutineScope,
    latestMessageCount: Int,
) {
    val density = LocalDensity.current
    // The pointerInput block starts once, on the first pointer event, and recomposition does not
    // restart it (see [PointerPressTracker]). Everything it captures freezes at that moment, so the
    // callback has to be read through rememberUpdatedState to reach the current instance.
    val latestOnPointerDownChange = rememberUpdatedState(onPointerDownChange)
    LazyColumn(
        state = listState,
        modifier = Modifier
            .fillMaxSize()
            .alpha(if (hideInitialListUntilBottomSettled) 0f else 1f)
            // The baseline has to be block-local state (tracker). A captured parameter freezes when
            // the block starts, and the release is then never reported.
            .pointerInput(Unit) {
                val tracker = PointerPressTracker()
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val anyPressed = event.changes.any { it.pressed }
                        tracker.consume(anyPressed)?.let { latestOnPointerDownChange.value(it) }
                    }
                }
            },
        contentPadding = PaddingValues(
            top = OriveoTheme.layout.sectionGap,
            bottom = composerOverlayHeightDp + OriveoTheme.spacing.xxl,
        ),
    ) {
        itemsIndexed(
            items = messages,
            key = { _, msg -> msg.id },
            contentType = { _, msg -> msg.role },
        ) { index, message ->
            val isStreaming = message.id == streamingMessageId
            val previousRole = messages.getOrNull(index - 1)?.role
            val nextRole = messages.getOrNull(index + 1)?.role
            val topPadding = if (previousRole == message.role) {
                OriveoTheme.spacing.sm
            } else {
                OriveoTheme.spacing.lg
            }
            val showMetadata = message.role == ChatRole.User || nextRole != ChatRole.Assistant
            val messageMetadata = remember(
                message.providerID,
                message.modelID,
                message.providerName,
                message.modelName,
                displayLookup,
            ) {
                resolveMessageDisplayMetadata(
                    message = message,
                    displayLookup = displayLookup,
                )
            }

            
            
            
            val streamingHold = remember(message.id) { StreamingCellHold() }
            val liveStreamingText: String? = if (isStreaming) {
                streamingText.collectAsStateWithLifecycle().value
            } else {
                null
            }
            val liveStreamingReasoning: String? = if (isStreaming) {
                streamingReasoning.collectAsStateWithLifecycle().value
            } else {
                null
            }
            
            val liveReasoningActive: Boolean = isStreaming &&
                streamingReasoningActive.collectAsStateWithLifecycle().value
            if (!liveStreamingText.isNullOrEmpty()) streamingHold.text = liveStreamingText
            if (!liveStreamingReasoning.isNullOrEmpty()) streamingHold.reasoning = liveStreamingReasoning
            val isPersistedGenerating = message.state == ChatMessageState.Generating
            val cellStreamingText = resolveStreamingCellText(
                live = liveStreamingText,
                held = streamingHold.text,
                isPersistedGenerating = isPersistedGenerating,
            )
            val cellStreamingReasoning = resolveStreamingCellText(
                live = liveStreamingReasoning,
                held = streamingHold.reasoning,
                isPersistedGenerating = isPersistedGenerating,
            )

            val messageSavedNoteLinks = savedNoteLinksForMessage(savedNoteLinksByMessage, message.id)
            val replacementNoteId = replacementNoteIdForSelection(
                returnToNoteId = returnToNoteId,
                savedNoteLinks = messageSavedNoteLinks,
            )
            val isPinnedAssistant = shouldApplyPinnedAssistantReserve(
                messages = messages,
                index = index,
                pinnedTurnUserId = scrollController.pinnedTurnUserId,
            )
            
            val highlightColor by animateColorAsState(
                targetValue = if (message.id == highlightedMessageId) {
                    OriveoTheme.colors.primary.copy(alpha = 0.12f)
                } else {
                    Color.Transparent
                },
                animationSpec = tween(durationMillis = 320),
                label = "noteSourceHighlight",
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(highlightColor, RoundedCornerShape(14.dp))
                    .then(
                        if (isPinnedAssistant && scrollController.reservePx > 0) {
                            
                            
                            val pinnedFloorDp = with(density) {
                                scrollController.pinnedAssistantFloorPx.toDp()
                            }
                            Modifier
                                .heightIn(min = maxOf(reserveDp, pinnedFloorDp))
                                .onSizeChanged { scrollController.reportPinnedAssistantHeight(it.height) }
                        } else {
                            Modifier
                        },
                    ),
            ) {
                MessageItemWithActions(
                    message = message,
                    streamingText = cellStreamingText,
                    streamingReasoning = cellStreamingReasoning,
                    streamingReasoningActive = liveReasoningActive,
                    isSendingMessage = isGenerating,
                    isRateLimitError = isRateLimitError(message),
                    topPadding = topPadding,
                    showMetadata = showMetadata,
                    isLastMessage = index == messages.lastIndex,
                    providerNameOverride = messageMetadata.providerName,
                    modelNameOverride = messageMetadata.modelName,
                    relayKind = providersById[message.providerID]?.relayKind,
                    isUserDragging = isDragging,
                    onCopy = { onCopy(message) },
                    onEdit = { onEdit(message) },
                    onRegenerate = { onRegenerate(message.id) },
                    onContinue = { onContinue(message.id) },
                    onRetry = { onRetry(message.id) },
                    onRetryWithoutLocalCustomFields = { onRetryWithoutLocalCustomFields(message.id) },
                    onSwitchModel = onSwitchModel,
                    onShare = { onShare(message) },
                    onSaveAsNote = { onSaveAsNote(message) },
                    onSaveCodeAsNote = { code -> onSaveCodeAsNote(message, code) },
                    onSaveSelection = { text -> onSaveSelectionAsNote(message, text) },
                    onAskSelection = { selection -> onAskSelection(message, selection) },
                    onReplaceSelection = if (message.state == ChatMessageState.Delivered && replacementNoteId != null) {
                        onReplaceSelectionInCurrentNote?.let { callback ->
                            { text -> callback(message, text, replacementNoteId) }
                        }
                    } else {
                        null
                    },
                    onCrosscheck = { onCrosscheck(message) },
                    savedNoteLinks = messageSavedNoteLinks,
                    onOpenSavedNote = onOpenSavedNote,
                )
            }
        }
    }

    val showScrollToBottom by remember(listState, scrollController) {
        derivedStateOf { listState.canScrollForward && !scrollController.following }
    }

    AnimatedVisibility(
        visible = showScrollToBottom,
        
        
        modifier = Modifier
            .align(Alignment.BottomEnd)
            .padding(end = OriveoTheme.spacing.lg, bottom = composerOverlayHeightDp + OriveoTheme.spacing.sm),
        enter = fadeIn() + scaleIn(initialScale = 0.8f),
        exit = fadeOut() + scaleOut(targetScale = 0.8f),
    ) {
        ScrollToBottomButton(
            onClick = {
                @Suppress("DEPRECATION")
                (context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)
                    ?.vibrate(VibrationEffect.createOneShot(20, VibrationEffect.DEFAULT_AMPLITUDE))
                scrollController.resumeFollowing()
                coroutineScope.launch {
                    scrollController.scrollToBottom(listState, latestMessageCount)
                }
            },
        )
    }

    
    ChatOutlineRail(
        messages = messages,
        listState = listState,
        hasMoreAbove = hasMoreAbove,
        hasMoreBelow = hasMoreBelow,
        scrollController = scrollController,
        context = context,
        coroutineScope = coroutineScope,
    )
}
