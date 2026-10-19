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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.height
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ContextCheckpointKind
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.core.model.StreamActivity
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.feature.chat.components.ChatOutlineRail
import ai.oriveo.community.feature.chat.components.ScrollToBottomButton
import ai.oriveo.community.feature.chat.recovery.MessageItemWithActions
import ai.oriveo.community.feature.chat.recovery.RelaySwitchKey
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
    /**
     * The activity observed in progress on the wire. Like the streaming text it is collected only
     * inside the streaming cell, so it stays out of the list's own recomposition scope.
     */
    streamingActivity: StateFlow<StreamActivity?>,
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
    /** Relay failure message "switch to another key". */
    onSwitchKey: (ChatMessage) -> Unit = {},
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
    coroutineScope: CoroutineScope,
    latestMessageCount: Int,
    /** Separator of the latestValid row, drawn inside its anchor item (no extra list item). */
    separator: TranscriptCompactionSeparator? = null,
    onSeparatorClick: () -> Unit = {},
    /** Pending "set as instruction" suggestion, drawn under its user message. */
    directiveSuggestion: DirectiveSuggestion? = null,
    onAcceptDirectiveSuggestion: () -> Unit = {},
    onIgnoreDirectiveSuggestion: () -> Unit = {},
    /** Pending "save to memory?" bar, drawn under its user message. */
    memorySuggestion: MemorySuggestion? = null,
    onIgnoreMemorySuggestion: () -> Unit = {},
    onEditMemorySuggestion: () -> Unit = {},
    onSaveMemorySuggestion: () -> Unit = {},
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
            val liveStreamingActivity: StreamActivity? = if (isStreaming) {
                streamingActivity.collectAsStateWithLifecycle().value
            } else {
                null
            }
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
                Column(modifier = Modifier.fillMaxWidth()) {
                    if (separator != null && separator.drawAboveMessageId == message.id) {
                        CompactionSeparatorRow(separator.separator, onSeparatorClick)
                    }
                    MessageItemWithActions(
                        message = message,
                        streamingText = cellStreamingText,
                        streamingReasoning = cellStreamingReasoning,
                        streamingReasoningActive = liveReasoningActive,
                        streamingActivity = liveStreamingActivity,
                        isLiveStream = isStreaming,
                        isSendingMessage = isGenerating,
                        isRateLimitError = isRateLimitError(message),
                        topPadding = topPadding,
                        showMetadata = showMetadata,
                        isLastMessage = index == messages.lastIndex,
                        providerNameOverride = messageMetadata.providerName,
                        modelNameOverride = messageMetadata.modelName,
                        isUserDragging = isDragging,
                        onCopy = { onCopy(message) },
                        onEdit = { onEdit(message) },
                        onRegenerate = { onRegenerate(message.id) },
                        onContinue = { onContinue(message.id) },
                        onRetry = { onRetry(message.id) },
                        onRetryWithoutLocalCustomFields = { onRetryWithoutLocalCustomFields(message.id) },
                        onSwitchModel = onSwitchModel,
                        offersSwitchKey = message.state == ChatMessageState.Failed &&
                            RelaySwitchKey.options(providersById[message.providerID], message).isNotEmpty(),
                        onSwitchKey = { onSwitchKey(message) },
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
                    // coversTo is the last message: nothing follows it, so the row goes below it.
                    if (separator != null && separator.drawAboveMessageId == null &&
                        separator.separator.anchorMessageId == message.id
                    ) {
                        CompactionSeparatorRow(separator.separator, onSeparatorClick)
                    }
                    if (directiveSuggestion != null && directiveSuggestion.messageId == message.id) {
                        DirectiveSuggestionRow(onAcceptDirectiveSuggestion, onIgnoreDirectiveSuggestion)
                    }
                    // Under the turn's assistant reply, only once it has stopped streaming.
                    if (memorySuggestion != null && memorySuggestion.messageId == message.id &&
                        message.role == ChatRole.Assistant && !isStreaming &&
                        message.state != ChatMessageState.Generating
                    ) {
                        MemorySuggestionRow(
                            suggestion = memorySuggestion,
                            onIgnore = onIgnoreMemorySuggestion,
                            onEdit = onEditMemorySuggestion,
                            onSave = onSaveMemorySuggestion,
                        )
                    }
                }
            }
        }
    }

    ChatScrollToBottomOverlay(
        listState = listState,
        scrollController = scrollController,
        composerOverlayHeightDp = composerOverlayHeightDp,
        coroutineScope = coroutineScope,
        latestMessageCount = latestMessageCount,
    )

    ChatOutlineRail(
        messages = messages,
        listState = listState,
        hasMoreAbove = hasMoreAbove,
        hasMoreBelow = hasMoreBelow,
        scrollController = scrollController,
        coroutineScope = coroutineScope,
    )
}

/**
 * The "jump to latest" button, kept in its own recomposition scope.
 *
 * `showScrollToBottom` is a `derivedStateOf`, so whoever reads it is invalidated when it flips. Read
 * inside [ChatMessagesList] itself, every flip recomposed the whole list function, handed `LazyColumn`
 * a new content lambda, produced a new `LazyListIntervalContent` (which does not override `equals`),
 * made `LazyListItemProviderImpl.equals` report a change, and so recomposed every visible message cell
 * together with its markdown subtree.
 *
 * `canScrollForward` flips when the list reaches either edge and `following` flips on follow
 * detach/reclaim and on streaming mode changes, all of which happen constantly while reading a long
 * conversation. With the read moved here, a flip recomposes only this button.
 *
 * `coroutineScope` is still passed in rather than created with `rememberCoroutineScope()` here: the
 * scroll-to-bottom animation has to outlive the button's own fade-out, and a scope tied to the button
 * would be cancelled halfway through.
 */
@Composable
private fun BoxScope.ChatScrollToBottomOverlay(
    listState: LazyListState,
    scrollController: ChatScrollController,
    composerOverlayHeightDp: Dp,
    coroutineScope: CoroutineScope,
    latestMessageCount: Int,
) {
    val context = LocalContext.current
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
}

/** Suggestion bar under the user bubble: one secondary line plus accept / ignore actions. */
@Composable
private fun DirectiveSuggestionRow(
    onAccept: () -> Unit,
    onIgnore: () -> Unit,
) {
    SuggestionCard {
        // iOS parity: prompt on its own line, actions on the row below (same as the memory bar).
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = MemorySuggestionRowLayout.horizontalAlignment,
        ) {
            Text(
                text = stringResource(R.string.directive_suggestion_prompt),
                style = TextStyle(fontSize = 12.sp),
                color = OriveoTheme.colors.textSecondary,
            )
            Row(
                modifier = Modifier.padding(top = OriveoTheme.spacing.sm),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm, MemorySuggestionRowLayout.horizontalAlignment),
            ) {
                SuggestionPillButton(stringResource(R.string.directive_suggestion_ignore), primary = false, onClick = onIgnore)
                SuggestionPillButton(stringResource(R.string.directive_suggestion_accept), primary = true, onClick = onAccept)
            }
        }
    }
}

/** iOS parity: suggestion bars sit on a rounded card surface, padded in from the screen edges. */
@Composable
private fun SuggestionCard(content: @Composable () -> Unit) {
    ai.oriveo.community.ui.component.OriveoCard(
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg),
        radius = MemorySuggestionRowLayout.cardRadius,
        contentPadding = PaddingValues(horizontal = OriveoTheme.spacing.md, vertical = OriveoTheme.spacing.sm),
        content = content,
    )
}

/** Capsule action, same look as the memory inbox actions: gray capsule for secondary, solid primary fill for the main one. */
@Composable
private fun SuggestionPillButton(label: String, primary: Boolean, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .height(MemorySuggestionRowLayout.actionHeight)
            .clip(MemorySuggestionRowLayout.actionShape)
            .background(if (primary) colors.primaryTextSafe else MemorySuggestionRowLayout.secondaryActionFill(OriveoTheme.isDark))
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick)
            .padding(horizontal = if (primary) 16.dp else 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = TextStyle(fontSize = 14.5.sp, lineHeight = 19.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
            color = if (primary) colors.onPrimary else colors.textSecondary,
            maxLines = 1,
        )
    }
}

/**
 * "Save to memory?" bar under the assistant reply: prompt plus candidate text (at most two lines)
 * and [ignore][edit][save]; with memory off for the chat only the hint line, no candidate and no actions.
 */
/** The bar hangs under the assistant reply, so its lines align with the reply's leading edge. */
internal object MemorySuggestionRowLayout {
    val horizontalAlignment: Alignment.Horizontal = Alignment.Start
    val textAlign: androidx.compose.ui.text.style.TextAlign = androidx.compose.ui.text.style.TextAlign.Start

    /** iOS parity: rounded card surface behind the bar. */
    val cardRadius: Dp = ai.oriveo.community.ui.theme.OriveoRadius.md

    /** iOS parity: capsule actions, same metrics as the memory inbox actions. */
    val actionHeight: Dp = 36.dp
    val actionShape: androidx.compose.ui.graphics.Shape = androidx.compose.foundation.shape.CircleShape

    /** Directive bar stacks prompt over actions (iOS parity) instead of squeezing both into one row. */
    val directiveStacksActionsBelowPrompt: Boolean = true

    /** Card fill behind both bars (what [SuggestionCard] paints via OriveoCard's default). */
    fun cardFill(colors: ai.oriveo.community.ui.theme.OriveoColors): androidx.compose.ui.graphics.Color = colors.surface

    /**
     * Secondary capsule fill, mirroring iOS secondarySystemFill (rgb 120,120,128 at 16% light / 32% dark)
     * so the gray pill stays visible on the card in both themes.
     */
    fun secondaryActionFill(isDark: Boolean): androidx.compose.ui.graphics.Color =
        if (isDark) androidx.compose.ui.graphics.Color(0x52787880) else androidx.compose.ui.graphics.Color(0x29787880)
}

@Composable
private fun MemorySuggestionRow(
    suggestion: MemorySuggestion,
    onIgnore: () -> Unit,
    onEdit: () -> Unit,
    onSave: () -> Unit,
) {
    val candidate = suggestion.candidate
    if (candidate == null) {
        Text(
            text = stringResource(R.string.memory_suggestion_memory_off),
            style = TextStyle(fontSize = 12.sp),
            color = OriveoTheme.colors.textSecondary,
            textAlign = MemorySuggestionRowLayout.textAlign,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.spacing.lg),
        )
        return
    }
    SuggestionCard {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = MemorySuggestionRowLayout.horizontalAlignment,
        ) {
            Text(
                text = stringResource(R.string.memory_suggestion_prompt),
                style = TextStyle(fontSize = 12.sp),
                color = OriveoTheme.colors.textSecondary,
            )
            Text(
                text = candidate.content,
                style = TextStyle(fontSize = 12.sp),
                color = OriveoTheme.colors.textPrimary,
                maxLines = 2,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            )
            Row(
                modifier = Modifier.padding(top = OriveoTheme.spacing.sm),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm, MemorySuggestionRowLayout.horizontalAlignment),
            ) {
                SuggestionPillButton(stringResource(R.string.memory_suggestion_ignore), primary = false, onClick = onIgnore)
                SuggestionPillButton(stringResource(R.string.memory_suggestion_edit), primary = false, onClick = onEdit)
                SuggestionPillButton(stringResource(R.string.memory_suggestion_save), primary = true, onClick = onSave)
            }
        }
    }
}

/**
 * Transcript separator: 1dp hairlines on both sides, two centered 12sp secondary lines with tabular
 * figures, a trailing chevron on line 2. The whole row is one button whose description reads both lines.
 */
@Composable
private fun CompactionSeparatorRow(
    separator: ContextCompactionSeparator,
    onClick: () -> Unit,
) {
    val line1: String
    val line2: String
    // Same "not available" wording as the detail sheet; never 0 or a dash.
    val unknownCount = stringResource(R.string.context_compaction_detail_cost_unavailable)
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    when (separator.kind) {
        ContextCheckpointKind.SUMMARY -> {
            line1 = pluralStringResource(
                R.plurals.context_compaction_summary_line1,
                separator.count,
                separator.count,
                ContextCompactionPresentation.separatorTokenText(separator.before, locale) ?: unknownCount,
                ContextCompactionPresentation.separatorTokenText(separator.after, locale) ?: unknownCount,
            )
            line2 = stringResource(R.string.context_compaction_summary_line2, separator.model)
        }
        ContextCheckpointKind.FALLBACK -> {
            val kept = separator.kept ?: 0
            line1 = pluralStringResource(R.plurals.context_compaction_fallback_line1, separator.count, separator.count)
            line2 = pluralStringResource(R.plurals.context_compaction_fallback_line2, kept, kept)
        }
    }
    val color = OriveoTheme.colors.textSecondary
    val style = TextStyle(fontSize = 12.sp, fontFeatureSettings = "tnum", textAlign = TextAlign.Center)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .clearAndSetSemantics {
                contentDescription = "$line1\n$line2"
                role = Role.Button
            }
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        HorizontalDivider(modifier = Modifier.weight(1f), thickness = 1.dp, color = OriveoTheme.colors.border)
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text = line1, style = style, color = color)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(text = line2, style = style, color = color)
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = color,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        HorizontalDivider(modifier = Modifier.weight(1f), thickness = 1.dp, color = OriveoTheme.colors.border)
    }
}
