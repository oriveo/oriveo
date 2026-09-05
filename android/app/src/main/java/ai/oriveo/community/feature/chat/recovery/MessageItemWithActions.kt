package ai.oriveo.community.feature.chat.recovery

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.FactCheck
import androidx.compose.material.icons.automirrored.outlined.NoteAdd
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.feature.chat.AssistantMessageFooterMetrics
import ai.oriveo.community.feature.chat.SavedNoteLink
import ai.oriveo.community.feature.chat.components.MessageBubble
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch


private const val TEXT_SELECTION_OUTER_MENU_GUARD_MS = 120L

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun MessageItemWithActions(
    message: ChatMessage,
    streamingText: String?,
    streamingReasoning: String?,
    
    streamingReasoningActive: Boolean = false,
    isSendingMessage: Boolean,
    isRateLimitError: Boolean,
    topPadding: Dp,
    showMetadata: Boolean,
    isLastMessage: Boolean,
    providerNameOverride: String?,
    modelNameOverride: String?,
    relayKind: RelayKind?,
    isUserDragging: Boolean,
    onCopy: () -> Unit,
    onEdit: () -> Unit,
    onRegenerate: () -> Unit,
    onContinue: () -> Unit,
    onRetry: () -> Unit,
    onRetryWithoutLocalCustomFields: () -> Unit = {},
    onSwitchModel: () -> Unit,
    onShare: () -> Unit,
    onSaveAsNote: () -> Unit,
    onSaveCodeAsNote: (String) -> Unit,
    onSaveSelection: (String) -> Unit,
    onAskSelection: (QuoteSelectionContent) -> Unit,
    onReplaceSelection: ((String) -> Unit)? = null,
    onCrosscheck: () -> Unit = {},
    savedNoteLinks: List<SavedNoteLink> = emptyList(),
    onOpenSavedNote: (String) -> Unit = {},
) {
    val colors = OriveoTheme.colors
    var showMenu by remember(message.id) { mutableStateOf(false) }
    var selectionToolbarVisible by remember(message.id) { mutableStateOf(false) }
    var selectionGestureActive by remember(message.id) { mutableStateOf(false) }
    var pendingMessageMenuJob by remember(message.id) { mutableStateOf<Job?>(null) }
    val menuScope = rememberCoroutineScope()
    var showSavedNoteMenu by remember { mutableStateOf(false) }
    var showRecoveryCard by remember(message.id, message.state) {
        mutableStateOf(message.state == ChatMessageState.Failed || message.state == ChatMessageState.Interrupted)
    }
    val recoveryActionLayout = remember(
        message.state,
        isRateLimitError,
        message.customRetryWithoutFieldsAvailable,
        message.customRetryWithoutFieldsCode,
    ) {
        resolveMessageRecoveryCardActionLayout(
            state = message.state,
            shouldOfferModelSwitch = isRateLimitError,
            customRetryWithoutFieldsAvailable = message.customRetryWithoutFieldsAvailable,
            customRetryWithoutFieldsCode = message.customRetryWithoutFieldsCode,
        )
    }
    val recoveryActionsEnabled = remember(isSendingMessage) {
        messageRecoveryActionsEnabled(isSendingMessage)
    }
    val showDeliveredRegenerateAction = remember(message.state, isSendingMessage) {
        shouldShowDeliveredRegenerateAction(message.state, isSendingMessage)
    }

    DisposableEffect(message.id) {
        onDispose {
            pendingMessageMenuJob?.cancel()
            pendingMessageMenuJob = null
        }
    }

    Box(
        modifier = Modifier
            .padding(top = topPadding)
            .combinedClickable(
                onClick = {},
                onLongClick = {
                    pendingMessageMenuJob?.cancel()
                    if (!selectionToolbarVisible && !selectionGestureActive) {
                        pendingMessageMenuJob = menuScope.launch {
                            delay(TEXT_SELECTION_OUTER_MENU_GUARD_MS)
                            if (!selectionToolbarVisible && !selectionGestureActive) {
                                showMenu = true
                            }
                        }
                    }
                },
            ),
    ) {
        Column {
            MessageBubble(
                message = message,
                streamingText = streamingText,
                streamingReasoning = streamingReasoning,
                streamingReasoningActive = streamingReasoningActive,
                showMetadata = showMetadata,
                providerNameOverride = providerNameOverride,
                modelNameOverride = modelNameOverride,
                relayKind = relayKind,
                isUserDragging = isUserDragging,
                onEdit = if (message.role == ChatRole.User) onEdit else null,
                onRetry = if (message.role == ChatRole.Assistant && showDeliveredRegenerateAction) {
                    onRegenerate
                } else {
                    null
                },
                onSaveMessageAsNote = if (message.role == ChatRole.Assistant && message.text.isNotBlank()) {
                    onSaveAsNote
                } else {
                    null
                },
                onSaveCodeAsNote = onSaveCodeAsNote,
                onSaveSelection = onSaveSelection,
                onAskSelection = if (message.state != ChatMessageState.Generating) onAskSelection else null,
                onReplaceSelection = onReplaceSelection,
                onSelectionToolbarVisibleChange = { visible ->
                    selectionToolbarVisible = visible
                    pendingMessageMenuJob?.cancel()
                    pendingMessageMenuJob = null
                    if (visible) showMenu = false
                },
                onSelectionGestureActiveChange = { active ->
                    selectionGestureActive = active
                    if (active) {
                        pendingMessageMenuJob?.cancel()
                        pendingMessageMenuJob = null
                        showMenu = false
                    }
                },
                onCrosscheck = if (
                    message.role == ChatRole.Assistant &&
                    showDeliveredRegenerateAction &&
                    message.text.isNotBlank()
                ) {
                    onCrosscheck
                } else {
                    null
                },
            )

            if (savedNoteLinks.isNotEmpty()) {
                val statusStartPadding = if (message.role == ChatRole.Assistant) {
                    AssistantMessageFooterMetrics.AbsoluteContentStart +
                        AssistantMessageFooterMetrics.RowOpticalOffset
                } else {
                    24.dp
                }
                Box(
                    modifier = Modifier
                        .padding(
                            start = statusStartPadding,
                            end = 24.dp,
                            top = 2.dp,
                        ),
                ) {
                    val firstNoteTitle = savedNoteLinks.first().title.ifBlank {
                        stringResource(R.string.notes_untitled)
                    }
                    val overflowCount = savedNoteLinks.size - 1
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(AssistantMessageFooterMetrics.CornerRadius))
                            .clickable {
                                if (savedNoteLinks.size == 1) {
                                    onOpenSavedNote(savedNoteLinks.first().noteId)
                                } else {
                                    showSavedNoteMenu = true
                                }
                            }
                            .padding(vertical = AssistantMessageFooterMetrics.StatusVerticalPadding),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(AssistantMessageFooterMetrics.StatusTextGap),
                    ) {
                        Box(
                            modifier = Modifier.size(AssistantMessageFooterMetrics.IconTouchSize),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Outlined.NoteAdd,
                                contentDescription = null,
                                modifier = Modifier.size(AssistantMessageFooterMetrics.IconSize),
                                tint = colors.textTertiary,
                            )
                        }
                        Text(
                            
                            text = stringResource(R.string.notes_chat_saved_as_note) + " " + firstNoteTitle +
                                if (overflowCount > 0) " +$overflowCount" else "",
                            style = OriveoTheme.typography.footnote,
                            color = colors.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    DropdownMenu(
                        expanded = showSavedNoteMenu,
                        onDismissRequest = { showSavedNoteMenu = false },
                    ) {
                        savedNoteLinks.forEach { link ->
                            DropdownMenuItem(
                                text = {
                                    val untitled = stringResource(R.string.notes_untitled)
                                    Text(link.title.ifBlank { untitled })
                                },
                                onClick = {
                                    showSavedNoteMenu = false
                                    onOpenSavedNote(link.noteId)
                                },
                                leadingIcon = { Icon(Icons.AutoMirrored.Outlined.NoteAdd, contentDescription = null) },
                            )
                        }
                    }
                }
            }

            // Failed recovery card, shown only on the conversation's last message
            // (see shouldShowRecoveryCard).
            if (showRecoveryCard && message.state == ChatMessageState.Failed &&
                shouldShowRecoveryCard(message.state, message.role, isLastMessage)
            ) {
                val providerDetailKey = message.errorDetail
                val hasLocalizedProviderDetail = ErrorMapper.hasLocalizedProviderMessage(providerDetailKey)
                val localizedProviderDetail = providerDetailKey?.let {
                    ErrorMapper.localizeProviderErrorMessage(it, LocalContext.current)
                }
                MessageRecoveryCard(
                    title = stringResource(R.string.message_failed),
                    message = if (hasLocalizedProviderDetail) {
                        localizedProviderDetail.orEmpty()
                    } else if (message.errorDetail == RelayEndpointPolicy.HTTPS_REQUIRED_MESSAGE) {
                        stringResource(R.string.relay_setup_invalid_endpoint_message)
                    } else {
                        stringResource(R.string.message_failed_body)
                    },
                    tone = StatusTone.Danger,
                    technicalDetail = message.errorDetail.takeUnless { hasLocalizedProviderDetail },
                    primaryTitle = stringResource(recoveryActionLayout.primary.titleRes()),
                    secondaryTitle = recoveryActionLayout.secondary?.let { stringResource(it.titleRes()) },
                    tertiaryTitle = recoveryActionLayout.tertiary?.let { stringResource(it.titleRes()) },
                    onPrimary = {
                        performRecoveryAction(
                            recoveryActionLayout.primary,
                            onRetry,
                            onEdit,
                            onRegenerate,
                            onSwitchModel,
                            onContinue,
                            onRetryWithoutLocalCustomFields,
                        )
                    },
                    onSecondary = recoveryActionLayout.secondary?.let { action ->
                        {
                            performRecoveryAction(
                                action,
                                onRetry,
                                onEdit,
                                onRegenerate,
                                onSwitchModel,
                                onContinue,
                                onRetryWithoutLocalCustomFields,
                            )
                        }
                    },
                    onTertiary = recoveryActionLayout.tertiary?.let { action ->
                        {
                            performRecoveryAction(
                                action,
                                onRetry,
                                onEdit,
                                onRegenerate,
                                onSwitchModel,
                                onContinue,
                                onRetryWithoutLocalCustomFields,
                            )
                        }
                    },
                    actionsEnabled = recoveryActionsEnabled,
                    onDismiss = { showRecoveryCard = false },
                )
            }

            
            if (showRecoveryCard && message.state == ChatMessageState.Interrupted &&
                shouldShowRecoveryCard(message.state, message.role, isLastMessage)
            ) {
                MessageRecoveryCard(
                    title = stringResource(R.string.message_interrupted),
                    message = stringResource(R.string.message_interrupted_body),
                    tone = StatusTone.Warning,
                    technicalDetail = message.errorDetail,
                    primaryTitle = stringResource(recoveryActionLayout.primary.titleRes()),
                    secondaryTitle = recoveryActionLayout.secondary?.let { stringResource(it.titleRes()) },
                    tertiaryTitle = recoveryActionLayout.tertiary?.let { stringResource(it.titleRes()) },
                    onPrimary = {
                        performRecoveryAction(
                            recoveryActionLayout.primary,
                            onRetry,
                            onEdit,
                            onRegenerate,
                            onSwitchModel,
                            onContinue,
                        )
                    },
                    onSecondary = recoveryActionLayout.secondary?.let { action ->
                        {
                            performRecoveryAction(
                                action,
                                onRetry,
                                onEdit,
                                onRegenerate,
                                onSwitchModel,
                                onContinue,
                            )
                        }
                    },
                    onTertiary = recoveryActionLayout.tertiary?.let { action ->
                        {
                            performRecoveryAction(
                                action,
                                onRetry,
                                onEdit,
                                onRegenerate,
                                onSwitchModel,
                                onContinue,
                            )
                        }
                    },
                    actionsEnabled = recoveryActionsEnabled,
                    onDismiss = { showRecoveryCard = false },
                )
            }

            
            DropdownMenu(
                expanded = showMenu && !selectionToolbarVisible && !selectionGestureActive,
                onDismissRequest = { showMenu = false },
            ) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.copy)) },
                    onClick = { showMenu = false; onCopy() },
                    leadingIcon = { Icon(Icons.Outlined.ContentCopy, contentDescription = null) },
                )
                
                if (message.text.isNotBlank()) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.notes_chat_save_as_note)) },
                        onClick = { showMenu = false; onSaveAsNote() },
                        leadingIcon = { Icon(Icons.AutoMirrored.Outlined.NoteAdd, contentDescription = null) },
                    )
                }
                if (message.role == ChatRole.User) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.edit)) },
                        onClick = { showMenu = false; onEdit() },
                        leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
                    )
                }
                if (message.role == ChatRole.Assistant && showDeliveredRegenerateAction) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.regenerate)) },
                        onClick = { showMenu = false; onRegenerate() },
                        leadingIcon = { Icon(Icons.Outlined.Refresh, contentDescription = null) },
                    )
                    
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.notes_chat_crosscheck_action)) },
                        onClick = { showMenu = false; onCrosscheck() },
                        leadingIcon = { Icon(Icons.AutoMirrored.Outlined.FactCheck, contentDescription = null) },
                    )
                }
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.share)) },
                    onClick = { showMenu = false; onShare() },
                    leadingIcon = { Icon(Icons.Outlined.Share, contentDescription = null) },
                )
            }
        }
    }
}
