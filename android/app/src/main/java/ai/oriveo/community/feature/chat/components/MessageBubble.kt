package ai.oriveo.community.feature.chat.components

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.util.Base64
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.FactCheck
import androidx.compose.material.icons.automirrored.outlined.NoteAdd
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.TextSnippet
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.AudioFile
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Slideshow
import androidx.compose.material.icons.outlined.TableChart
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import ai.oriveo.community.R
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityExecutionResult
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.QuoteSelectionContent
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.UnhandledToolCall
import ai.oriveo.community.feature.chat.AssistantMessageFooterMetrics
import ai.oriveo.community.ui.component.ImageViewerSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.TypingIndicator
import java.text.NumberFormat
import ai.oriveo.community.ui.component.UserAvatarImage
import ai.oriveo.community.ui.component.rememberAttachmentDisplayBitmap
import ai.oriveo.community.ui.component.markdown.MarkdownMessageView
import ai.oriveo.community.ui.component.markdown.rememberNoteSelectionTextToolbar
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import android.graphics.BlurMaskFilter
import android.graphics.Paint as AndroidPaint
import org.koin.compose.koinInject
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlin.math.max
import kotlin.math.min


private val AssistantBodyLeadingInset = 0.dp

internal fun shouldShowAssistantFooterActions(
    messageState: ChatMessageState,
    hasText: Boolean,
    isBodyRenderSettled: Boolean,
): Boolean = messageState == ChatMessageState.Delivered && hasText && isBodyRenderSettled


internal fun shouldShowReasoningBlock(
    reasoningText: String,
    isStreaming: Boolean,
    reasoningActive: Boolean,
): Boolean = reasoningText.isNotBlank() || (isStreaming && reasoningActive)

internal data class ToolCallArgumentsPreview(val text: String, val truncated: Boolean)

private val toolCallPrettyJson = Json { prettyPrint = true }

internal fun toolCallArgumentsPreview(arguments: String): ToolCallArgumentsPreview {
    val raw = arguments.trim()
    val formatted = runCatching {
        toolCallPrettyJson.encodeToString(JsonElement.serializer(), sortToolCallJson(Json.parseToJsonElement(raw)))
    }.getOrDefault(raw)
    if (formatted.toByteArray(Charsets.UTF_8).size <= 2048) {
        return ToolCallArgumentsPreview(formatted, truncated = false)
    }
    var index = 0
    var usedBytes = 0
    val clipped = StringBuilder()
    while (index < formatted.length) {
        val codePoint = formatted.codePointAt(index)
        val scalar = String(Character.toChars(codePoint))
        val width = scalar.toByteArray(Charsets.UTF_8).size
        if (usedBytes + width > 2048) break
        clipped.append(scalar)
        usedBytes += width
        index += Character.charCount(codePoint)
    }
    return ToolCallArgumentsPreview(clipped.append('…').toString(), truncated = true)
}

private fun sortToolCallJson(element: JsonElement): JsonElement = when (element) {
    is JsonObject -> JsonObject(element.toSortedMap().mapValues { sortToolCallJson(it.value) })
    is JsonArray -> JsonArray(element.map(::sortToolCallJson))
    else -> element
}


@Composable
fun MessageBubble(
    message: ChatMessage,
    streamingText: String? = null,
    streamingReasoning: String? = null,
    
    streamingReasoningActive: Boolean = false,
    showMetadata: Boolean = true,
    providerNameOverride: String? = null,
    modelNameOverride: String? = null,
    relayKind: RelayKind? = null,
    avatarURL: String? = null,
    avatarLocalID: String? = null,
    avatarFallbackName: String = "",
    
    isUserDragging: Boolean = false,
    onEdit: (() -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    
    onSaveMessageAsNote: (() -> Unit)? = null,
    
    onSaveCodeAsNote: ((String) -> Unit)? = null,
    
    onSaveSelection: ((String) -> Unit)? = null,
    onAskSelection: ((QuoteSelectionContent) -> Unit)? = null,
    
    onReplaceSelection: ((String) -> Unit)? = null,
    
    onSelectionToolbarVisibleChange: (Boolean) -> Unit = {},
    
    onSelectionGestureActiveChange: (Boolean) -> Unit = {},
    onCrosscheck: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    attachmentStore: AttachmentStore = koinInject(),
) {
    if (message.role == ChatRole.User) {
        UserBubble(
            message = message,
            streamingText = streamingText,
            showMetadata = showMetadata,
            avatarURL = avatarURL,
            avatarLocalID = avatarLocalID,
            avatarFallbackName = avatarFallbackName,
            onEdit = onEdit,
            onSaveSelection = onSaveSelection,
            onAskSelection = onAskSelection,
            onReplaceSelection = onReplaceSelection,
            onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
            onSelectionGestureActiveChange = onSelectionGestureActiveChange,
            modifier = modifier,
            attachmentStore = attachmentStore,
        )
    } else {
        AssistantMessage(
            message = message,
            streamingText = streamingText,
            streamingReasoning = streamingReasoning,
            streamingReasoningActive = streamingReasoningActive,
            showMetadata = showMetadata,
            providerNameOverride = providerNameOverride,
            modelNameOverride = modelNameOverride,
            relayKind = relayKind,
            isUserDragging = isUserDragging,
            onRetry = onRetry,
            onSaveMessageAsNote = onSaveMessageAsNote,
            onSaveCodeAsNote = onSaveCodeAsNote,
            onSaveSelection = onSaveSelection,
            onAskSelection = onAskSelection,
            onReplaceSelection = onReplaceSelection,
            onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
            onSelectionGestureActiveChange = onSelectionGestureActiveChange,
            onCrosscheck = onCrosscheck,
            modifier = modifier,
            attachmentStore = attachmentStore,
        )
    }
}

@Composable
private fun UserBubble(
    message: ChatMessage,
    streamingText: String?,
    showMetadata: Boolean,
    avatarURL: String?,
    avatarLocalID: String?,
    avatarFallbackName: String,
    onEdit: (() -> Unit)?,
    onSaveSelection: ((String) -> Unit)?,
    onAskSelection: ((QuoteSelectionContent) -> Unit)?,
    onReplaceSelection: ((String) -> Unit)?,
    onSelectionToolbarVisibleChange: (Boolean) -> Unit,
    onSelectionGestureActiveChange: (Boolean) -> Unit,
    modifier: Modifier,
    attachmentStore: AttachmentStore,
) {
    val resolvedAvatarURL = avatarURL
    val resolvedAvatarLocalID = avatarLocalID
    val resolvedFallbackName = avatarFallbackName

    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val screenWidthDp = LocalConfiguration.current.screenWidthDp
    val maxBubbleWidth = remember(screenWidthDp) {
        max(min((screenWidthDp * 0.72).toInt(), 380), 240).dp
    }
    val bubbleShape = RoundedCornerShape(
        topStart = 20.dp,
        topEnd = 20.dp,
        bottomStart = 20.dp,
        bottomEnd = 6.dp,
    )
    val displayText = if (message.state == ChatMessageState.Generating) {
        streamingText ?: message.text
    } else {
        message.text
    }

    
    val imageAttachmentsForWidth = remember(message.attachments) {
        message.attachments?.filter { it.kind == AttachmentKind.Image }.orEmpty()
    }
    val fileAttachmentsForWidth = remember(message.attachments) {
        message.attachments?.filter { it.kind != AttachmentKind.Image }.orEmpty()
    }
    val isImmersiveHeroForWidth = imageAttachmentsForWidth.size == 1 && fileAttachmentsForWidth.isEmpty()
    val heroBitmap = if (isImmersiveHeroForWidth) {
        rememberAttachmentDisplayBitmap(imageAttachmentsForWidth.first())
    } else null
    val heroImageWidth: Dp? = if (heroBitmap != null) {
        val aspect = heroBitmap.width.toFloat() / heroBitmap.height.toFloat().coerceAtLeast(1f)
        val computed = 240.dp * aspect
        if (computed < maxBubbleWidth) computed else null
    } else null

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.End,
    ) {
        
        Row(
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Spacer(modifier = Modifier.weight(1f))

            Box(
                modifier = Modifier
                    .let { if (heroImageWidth != null) it.width(heroImageWidth) else it.widthIn(max = maxBubbleWidth) }
                    .userBubbleGlow(glowColor = colors.primaryGlow, isDark = isDark)
                    .background(OriveoGradients.primary, bubbleShape)
                    .border(OriveoBorderWidth.standard, colors.hairline, bubbleShape)
                    .clip(bubbleShape),
            ) {
                
                val imageCount = message.attachments?.count { it.kind == AttachmentKind.Image } ?: 0
                val fileCount = message.attachments?.count { it.kind != AttachmentKind.Image } ?: 0
                val isImmersiveHero = imageCount == 1 && fileCount == 0
                val hasText = displayText.isNotBlank()
                val isGeneratingNoText = message.state == ChatMessageState.Generating && displayText.isBlank()

                val onAskPlainSelection = onAskSelection?.let { callback ->
                    { selected: String ->
                        callback(
                            ai.oriveo.community.ui.component.markdown.QuoteSelectionMapper.capturePlain(
                                message.text,
                                selected,
                            ),
                        )
                    }
                }

                if (isImmersiveHero) {
                    Column {
                        message.quoteContext?.takeIf { it.isValid }?.let { quote ->
                            QuoteContextChip(
                                quote = quote,
                                presentation = QuoteContextChipPresentation.SentMessage,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                            )
                        }
                        MessageAttachmentList(
                            attachments = message.attachments!!,
                            isUserMessage = true,
                            immersiveHero = true,
                            hasText = hasText,
                            attachmentStore = attachmentStore,
                        )
                        if (hasText) {
                            SelectableUserMessageText(
                                text = displayText,
                                modifier = Modifier.padding(
                                    start = 16.dp,
                                    end = 16.dp,
                                    top = 8.dp,
                                    bottom = 14.dp,
                                ),
                                onSaveSelection = onSaveSelection,
                                onAskSelection = onAskPlainSelection,
                                onReplaceSelection = onReplaceSelection,
                                onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
                                onSelectionGestureActiveChange = onSelectionGestureActiveChange,
                            )
                        }
                    }
                } else {
                    Column(
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                    ) {
                        message.quoteContext?.takeIf { it.isValid }?.let { quote ->
                            QuoteContextChip(
                                quote = quote,
                                presentation = QuoteContextChipPresentation.SentMessage,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        if (!message.attachments.isNullOrEmpty()) {
                            MessageAttachmentList(
                                attachments = message.attachments,
                                isUserMessage = true,

                                attachmentStore = attachmentStore,
                            )
                        }

                        when {
                            isGeneratingNoText -> TypingIndicator()
                            hasText -> {
                                SelectableUserMessageText(
                                    text = displayText,
                                    onSaveSelection = onSaveSelection,
                                    onAskSelection = onAskPlainSelection,
                                    onReplaceSelection = onReplaceSelection,
                                    onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
                                    onSelectionGestureActiveChange = onSelectionGestureActiveChange,
                                )
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.width(OriveoTheme.spacing.sm))

            UserAvatarImage(
                size = 36.dp,
                avatarURL = resolvedAvatarURL,
                avatarLocalID = resolvedAvatarLocalID,
                fallbackName = resolvedFallbackName,
            )
        }

    }
}

@Composable
private fun SelectableUserMessageText(
    text: String,
    modifier: Modifier = Modifier,
    onSaveSelection: ((String) -> Unit)?,
    onAskSelection: ((String) -> Unit)?,
    onReplaceSelection: ((String) -> Unit)?,
    onSelectionToolbarVisibleChange: (Boolean) -> Unit,
    onSelectionGestureActiveChange: (Boolean) -> Unit,
) {
    // Keep this API text-only: arbitrary content can open Popup/ModalBottomSheet roots that inherit
    // LocalSelectionRegistrar. Registering those roots in this message-level SelectionContainer makes
    // Compose call localPositionOf across unrelated layout hierarchies and crash on long press.
    val selectionModifier = Modifier.selectionGestureGuard(onSelectionGestureActiveChange)
    if (onSaveSelection != null || onAskSelection != null) {
        val toolbar = rememberNoteSelectionTextToolbar(
            onSaveSelection = onSaveSelection ?: {},
            onAskSelection = onAskSelection,
            onReplaceSelection = onReplaceSelection,
            onVisibilityChange = onSelectionToolbarVisibleChange,
        )
        CompositionLocalProvider(LocalTextToolbar provides toolbar) {
            SelectionContainer(modifier = selectionModifier) {
                Text(
                    text = text,
                    modifier = modifier,
                    style = OriveoTheme.typography.chatBody,
                    color = Color.White,
                )
            }
        }
    } else {
        SelectionContainer(modifier = selectionModifier) {
            Text(
                text = text,
                modifier = modifier,
                style = OriveoTheme.typography.chatBody,
                color = Color.White,
            )
        }
    }
}

private fun Modifier.selectionGestureGuard(onActiveChange: (Boolean) -> Unit): Modifier = pointerInput(onActiveChange) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        onActiveChange(true)
        try {
            waitForUpOrCancellation(pass = PointerEventPass.Initial)
        } finally {
            onActiveChange(false)
        }
    }
}

@Composable
private fun AssistantMessage(
    message: ChatMessage,
    streamingText: String?,
    streamingReasoning: String?,
    streamingReasoningActive: Boolean,
    showMetadata: Boolean,
    providerNameOverride: String?,
    modelNameOverride: String?,
    relayKind: RelayKind?,
    isUserDragging: Boolean,
    onRetry: (() -> Unit)?,
    onSaveMessageAsNote: (() -> Unit)?,
    onSaveCodeAsNote: ((String) -> Unit)? = null,
    onSaveSelection: ((String) -> Unit)? = null,
    onAskSelection: ((QuoteSelectionContent) -> Unit)? = null,
    onReplaceSelection: ((String) -> Unit)? = null,
    onSelectionToolbarVisibleChange: (Boolean) -> Unit,
    onSelectionGestureActiveChange: (Boolean) -> Unit,
    onCrosscheck: (() -> Unit)? = null,
    modifier: Modifier,
    attachmentStore: AttachmentStore,
) {
    val colors = OriveoTheme.colors
    val resolvedProviderName = providerNameOverride ?: message.providerName
    val resolvedModelName = modelNameOverride ?: message.modelName
    val displayText = if (message.state == ChatMessageState.Generating) {
        streamingText ?: message.text
    } else {
        message.text
    }
    
    val isStreaming = message.state == ChatMessageState.Generating
    var isBodyRenderSettled by remember(message.id) {
        mutableStateOf(message.state != ChatMessageState.Generating)
    }
    LaunchedEffect(isStreaming) {
        if (isStreaming) isBodyRenderSettled = false
    }
    val displayReasoningText = if (isStreaming) {
        streamingReasoning ?: message.reasoningText ?: ""
    } else {
        message.reasoningText ?: ""
    }
    
    
    val metadataText = remember(
        resolvedProviderName,
        resolvedModelName,
        message.state,
        message.estimatedCost,
        message.estimatedCostText,
    ) {
        buildList {
            add(resolvedProviderName)
            add(resolvedModelName)
            if (message.state == ChatMessageState.Delivered && message.estimatedCost > 0) {
                add(message.estimatedCostText)
            }
        }.joinToString(" · ")
    }
    
    
    val showReasoningBlock = shouldShowReasoningBlock(
        reasoningText = displayReasoningText,
        isStreaming = isStreaming,
        reasoningActive = streamingReasoningActive,
    )
    val showTypingIndicator = message.state == ChatMessageState.Generating &&
        displayText.isBlank() &&
        !showReasoningBlock

    
    
    
    
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 26.dp, end = 22.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        ) {
            
            Row(
                modifier = Modifier.heightIn(min = 28.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                ProviderBadgeIcon(
                    kind = message.providerKind,
                    size = 28.dp,
                    relayKind = relayKind,
                )
                Text(
                    text = resolvedModelName,
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
                if (message.state == ChatMessageState.Generating) {
                    ai.oriveo.community.ui.component.StatusPill(
                        text = stringResource(R.string.generating),
                        tone = ai.oriveo.community.ui.component.StatusTone.Primary,
                    )
                }
            }

            Column(
                
                modifier = Modifier.padding(
                    bottom = OriveoTheme.spacing.xs,
                ),
                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            ) {
                
                
                
                if (showReasoningBlock) {
                    ReasoningBlock(
                        reasoningText = displayReasoningText,
                        isStreaming = isStreaming,
                        durationMs = message.reasoningDurationMs,
                        messageId = message.id,
                        
                        
                        reasoningEnded = message.reasoningDurationMs != null || displayText.isNotBlank(),
                    )
                }

                when {
                    showTypingIndicator -> {
                        
                        TypingIndicator()
                    }
                    displayText.isNotBlank() -> {
                        val hapticContext = LocalContext.current
                        MarkdownMessageView(
                            text = displayText,
                            modifier = Modifier.fillMaxWidth(),
                            isStreaming = message.state == ChatMessageState.Generating,
                            onSaveCodeBlock = onSaveCodeAsNote,
                            onSaveSelection = onSaveSelection,
                            onAskSelection = onAskSelection,
                            onReplaceSelection = onReplaceSelection,
                            onSelectionToolbarVisibleChange = onSelectionToolbarVisibleChange,
                            onSelectionGestureActiveChange = onSelectionGestureActiveChange,
                            
                            
                            onRenderSettled = {
                                @Suppress("DEPRECATION")
                                (hapticContext.getSystemService(Context.VIBRATOR_SERVICE) as? android.os.Vibrator)
                                    ?.vibrate(
                                        android.os.VibrationEffect.createOneShot(
                                            30,
                                            android.os.VibrationEffect.DEFAULT_AMPLITUDE,
                                        ),
                                    )
                            },
                            onRenderStreamingChanged = { renderStreaming ->
                                isBodyRenderSettled = !renderStreaming
                            },
                        )
                    }
                }

                if (message.unhandledToolCalls.isNotEmpty()) {
                    UnhandledToolCallsCard(message.unhandledToolCalls)
                } else if (message.toolFallbackNotice == "library_not_searched") {
                    ToolFallbackNoticeRow()
                }

                if (!message.attachments.isNullOrEmpty()) {
                    MessageAttachmentList(
                        attachments = message.attachments,
                        isUserMessage = false,
                    )
                }

                
                
                
                
                
                if (!message.citations.isNullOrEmpty() && (!isStreaming || message.text.isNotEmpty())) {
                    CitationsBlock(citations = message.citations)
                }
            }

            val showDeliveredFooterActions = shouldShowAssistantFooterActions(
                messageState = message.state,
                hasText = message.text.isNotBlank(),
                isBodyRenderSettled = isBodyRenderSettled,
            )
            val hasCapabilityExecutionStatus = message.capabilityExecutionResults.isNotEmpty()
            val hasVisibleMetadata = metadataText.isNotBlank() ||
                hasCapabilityExecutionStatus ||
                showDeliveredFooterActions
            if (showMetadata && hasVisibleMetadata) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (metadataText.isNotBlank()) {
                        Text(
                            text = metadataText,
                            style = OriveoTheme.typography.footnote,
                            color = colors.textTertiary,
                        )
                    }
                    if (hasCapabilityExecutionStatus) {
                        CapabilityExecutionStatusText(message.capabilityExecutionResults)
                    }
                    if (showDeliveredFooterActions) {
                        AssistantFooterActionRow(
                            messageText = message.text,
                            inputTokens = message.inputTokens,
                            outputTokens = message.outputTokens,
                            cacheReadTokens = message.cachedInputTokens,
                            cacheWriteTokens = message.cacheCreationInputTokens,
                            onSaveMessageAsNote = onSaveMessageAsNote,
                            onRegenerate = onRetry,
                            onCrosscheck = onCrosscheck,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun UnhandledToolCallsCard(calls: List<UnhandledToolCall>) {
    val colors = OriveoTheme.colors
    var expanded by remember(calls) { mutableStateOf(false) }
    val expansionState = stringResource(if (expanded) R.string.hide_details else R.string.code_block_expand)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(colors.backgroundSecondary)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button) { expanded = !expanded }
                .semantics { stateDescription = expansionState },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Build,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = colors.textSecondary,
            )
            val names = calls.map { it.name.ifBlank { "?" } }
            Text(
                text = if (names.size == 1) {
                    stringResource(R.string.tool_call_unhandled_single, names.first())
                } else {
                    stringResource(R.string.tool_call_unhandled_multiple, names.joinToString(", "))
                },
                modifier = Modifier.weight(1f),
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textSecondary,
            )
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                modifier = Modifier.size(16.dp).rotate(if (expanded) 180f else 0f),
                tint = colors.textTertiary,
            )
        }
        if (expanded) {
            Text(
                text = stringResource(R.string.tool_call_unhandled_title),
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textTertiary,
            )
            calls.forEach { call ->
                
                
                val preview = remember(call.arguments) {
                    toolCallArgumentsPreview(call.arguments.ifBlank { "{}" })
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = call.name.ifBlank { "?" },
                        style = OriveoTheme.typography.footnote.copy(
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold,
                        ),
                        color = colors.textPrimary,
                    )
                    SelectionContainer {
                        Text(
                            text = preview.text,
                            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
                            color = colors.textSecondary,
                        )
                    }
                    if (preview.truncated) {
                        Text(
                            text = stringResource(R.string.tool_call_arguments_truncated),
                            style = OriveoTheme.typography.footnote,
                            color = colors.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ToolFallbackNoticeRow() {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(colors.backgroundSecondary)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.Build,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = colors.textTertiary,
        )
        Text(
            text = stringResource(R.string.tool_fallback_library_not_searched),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
        )
    }
}

/** Displays only facts that reached final-wire dispatch; absent is never guessed as a state. */
@Composable
private fun CapabilityExecutionStatusText(results: List<CapabilityExecutionResult>) {
    val colors = OriveoTheme.colors
    val segments = results
        .sortedBy { it.owner }
        .map { result ->
            val owner = when (result.owner) {
                "web" -> stringResource(R.string.capability_web)
                "reasoning" -> stringResource(R.string.capability_reasoning)
                "generation" -> stringResource(R.string.generation_parameters_section)
                else -> stringResource(R.string.generation_model_behavior)
            }
            val status = when (result.state) {
                "requested" -> stringResource(R.string.capability_execution_requested)
                "observed" -> stringResource(R.string.capability_execution_observed)
                "rejected" -> stringResource(R.string.capability_execution_rejected)
                "recovered" -> stringResource(R.string.capability_execution_recovered)
                else -> stringResource(R.string.capability_execution_unconfirmed)
            }
            stringResource(
                R.string.capability_execution_status,
                owner,
                status,
            )
        }
    val text = segments.joinToString(" · ")

    Text(
        text = text,
        style = OriveoTheme.typography.footnote.copy(
            fontSize = 11.sp,
            lineHeight = 15.sp,
        ),
        color = colors.textTertiary,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = text },
    )
}

@Composable
private fun AssistantFooterActionRow(
    messageText: String,
    inputTokens: Int?,
    outputTokens: Int?,
    cacheReadTokens: Int?,
    cacheWriteTokens: Int?,
    onSaveMessageAsNote: (() -> Unit)?,
    onRegenerate: (() -> Unit)?,
    onCrosscheck: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val clipboard = LocalClipboard.current
    val copyScope = rememberCoroutineScope()
    var copied by remember(messageText) { mutableStateOf(false) }
    var showMoreMenu by remember { mutableStateOf(false) }
    var showTokenUsage by remember { mutableStateOf(false) }
    val hasSecondaryActions = true

    LaunchedEffect(copied, messageText) {
        if (copied) {
            delay(2000)
            copied = false
        }
    }

    Row(
        
        modifier = modifier.offset(x = AssistantMessageFooterMetrics.RowOpticalOffset),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FooterIconButton(
            icon = {
                Icon(
                    imageVector = if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
                    contentDescription = null,
                    modifier = Modifier.size(AssistantMessageFooterMetrics.IconSize),
                    tint = if (copied) colors.primary else colors.textTertiary,
                )
            },
            contentDescription = stringResource(if (copied) R.string.copied else R.string.copy),
            onClick = {
                copyScope.launch {
                    clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("text", messageText)))
                }
                copied = true
            },
        )

        if (onSaveMessageAsNote != null) {
            FooterActionButton(
                icon = {
                    Icon(
                        imageVector = Icons.AutoMirrored.Outlined.NoteAdd,
                        contentDescription = null,
                        modifier = Modifier.size(AssistantMessageFooterMetrics.IconSize),
                        tint = colors.primary,
                    )
                },
                label = stringResource(R.string.notes_chat_save_as_note),
                onClick = onSaveMessageAsNote,
            )
        }

        if (hasSecondaryActions) {
            Box {
                FooterIconButton(
                    icon = {
                        Icon(
                            imageVector = Icons.Filled.MoreHoriz,
                            contentDescription = null,
                            modifier = Modifier.size(AssistantMessageFooterMetrics.IconSize),
                            tint = colors.textTertiary,
                        )
                    },
                    contentDescription = stringResource(R.string.provider_list_more_actions),
                    onClick = { showMoreMenu = true },
                )
                DropdownMenu(
                    expanded = showMoreMenu,
                    onDismissRequest = { showMoreMenu = false },
                ) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.chat_token_usage_title)) },
                        onClick = {
                            showMoreMenu = false
                            showTokenUsage = true
                        },
                        leadingIcon = { Icon(Icons.Outlined.BarChart, contentDescription = null) },
                    )
                    if (onRegenerate != null) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.regenerate)) },
                            onClick = {
                                showMoreMenu = false
                                onRegenerate()
                            },
                            leadingIcon = { Icon(Icons.Outlined.Refresh, contentDescription = null) },
                        )
                    }
                    if (onCrosscheck != null) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.notes_chat_crosscheck_action)) },
                            onClick = {
                                showMoreMenu = false
                                onCrosscheck()
                            },
                            leadingIcon = { Icon(Icons.AutoMirrored.Outlined.FactCheck, contentDescription = null) },
                        )
                    }
                }
            }
        }
    }

    if (showTokenUsage) {
        MessageTokenUsageDialog(
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            cacheReadTokens = cacheReadTokens,
            cacheWriteTokens = cacheWriteTokens,
            onDismiss = { showTokenUsage = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MessageTokenUsageDialog(
    inputTokens: Int?,
    outputTokens: Int?,
    cacheReadTokens: Int?,
    cacheWriteTokens: Int?,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val unavailable = stringResource(R.string.chat_token_usage_unavailable)
    val formatter = remember { NumberFormat.getIntegerInstance() }
    fun format(value: Int?): String = value?.let(formatter::format) ?: unavailable
    val rows = remember(inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens) {
        resolveTokenUsageRows(
            MessageTokenUsageSnapshot(
                inputTokens = inputTokens,
                outputTokens = outputTokens,
                cacheReadTokens = cacheReadTokens,
                cacheWriteTokens = cacheWriteTokens,
            ),
        )
    }
    val cacheLabel: @Composable (TokenUsageCacheRow.Kind) -> String = { kind ->
        when (kind) {
            TokenUsageCacheRow.Kind.CacheRead -> stringResource(R.string.chat_token_usage_cache_read)
            TokenUsageCacheRow.Kind.CacheWrite -> stringResource(R.string.chat_token_usage_cache_write)
        }
    }

    
    
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { OriveoSheetDragHandle() },
        containerColor = colors.surface,
    ) {
        Column(
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    text = stringResource(R.string.chat_token_usage_title),
                    
                    
                    
                    
                    
                    color = colors.textPrimary,
                    style = OriveoTheme.typography.title2,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = stringResource(R.string.chat_token_usage_subtitle),
                    color = colors.textSecondary,
                    style = OriveoTheme.typography.footnote,
                )
            }
            Spacer(Modifier.height(6.dp))

            val inputCard: @Composable (Modifier) -> Unit = { modifier ->
                TokenUsageMetric(
                    label = stringResource(R.string.chat_token_usage_input),
                    value = format(rows.inputTokens),
                    modifier = modifier,
                    
                    
                    
                    
                    subRows = if (rows.cacheRows.isEmpty()) {
                        null
                    } else {
                        {
                            
                            
                            
                            HorizontalDivider(color = colors.border)
                            rows.cacheRows.forEach { row ->
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = cacheLabel(row.kind),
                                        color = colors.textSecondary,
                                        style = OriveoTheme.typography.footnote,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f, fill = false),
                                    )
                                    Spacer(Modifier.weight(1f))
                                    Text(
                                        text = format(row.value),
                                        color = colors.textSecondary,
                                        style = OriveoTheme.typography.footnote,
                                        fontWeight = FontWeight.Medium,
                                    )
                                }
                            }
                        }
                    },
                )
            }
            val outputCard: @Composable (Modifier) -> Unit = { modifier ->
                TokenUsageMetric(
                    label = stringResource(R.string.chat_token_usage_output),
                    value = format(rows.outputTokens),
                    modifier = modifier,
                )
            }

            if (rows.singleColumn) {
                inputCard(Modifier.fillMaxWidth())
                outputCard(Modifier.fillMaxWidth())
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    inputCard(Modifier.weight(1f))
                    outputCard(Modifier.weight(1f))
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(colors.primarySoft)
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.chat_token_usage_total), color = colors.textSecondary)
                Spacer(Modifier.weight(1f))
                Text(format(rows.total), color = colors.textPrimary, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun TokenUsageMetric(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    subRows: (@Composable ColumnScope.() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(colors.surfaceInset)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Text(label, color = colors.textSecondary, style = OriveoTheme.typography.footnote)
        
        
        Text(value, color = colors.textPrimary, fontWeight = FontWeight.SemiBold)
        subRows?.invoke(this)
    }
}


@Composable
private fun FooterActionButton(
    icon: @Composable () -> Unit,
    label: String,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(AssistantMessageFooterMetrics.CornerRadius))
            .clickable(
                role = Role.Button,
                onClick = onClick,
            )
            .padding(
                horizontal = AssistantMessageFooterMetrics.ActionHorizontalPadding,
                vertical = AssistantMessageFooterMetrics.ActionVerticalPadding,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        icon()
        Text(
            text = label,
            style = OriveoTheme.typography.footnote,
            color = colors.primary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}


@Composable
private fun FooterIconButton(
    icon: @Composable () -> Unit,
    contentDescription: String,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(AssistantMessageFooterMetrics.IconTouchSize)
            .clip(RoundedCornerShape(AssistantMessageFooterMetrics.CornerRadius))
            .semantics { this.contentDescription = contentDescription }
            .clickable(
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        icon()
    }
}

@Composable
private fun MessageAttachmentList(
    attachments: List<Attachment>,
    isUserMessage: Boolean,
    immersiveHero: Boolean = false,
    hasText: Boolean = false,
    attachmentStore: AttachmentStore = koinInject(),
) {
    val imageAttachments = attachments.filter { it.kind == AttachmentKind.Image }
    val fileAttachments = attachments.filter { it.kind != AttachmentKind.Image }

    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (imageAttachments.isNotEmpty()) {
            if (isUserMessage) {
                
                
                
                
                
                when (imageAttachments.size) {
                    1 -> UserImageHero(
                        attachment = imageAttachments.first(),
                        gallery = imageAttachments,
                        index = 0,
                        immersiveHero = immersiveHero,
                        hasText = hasText,
                        attachmentStore = attachmentStore,
                    )
                    2 -> Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        imageAttachments.forEachIndexed { idx, attachment ->
                            UserImageGridCell(
                                attachment = attachment,
                                gallery = imageAttachments,
                                index = idx,

                                attachmentStore = attachmentStore,
                            )
                        }
                    }
                    3 -> Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        imageAttachments.forEachIndexed { idx, attachment ->
                            UserImageThumbnail(
                                attachment = attachment,
                                gallery = imageAttachments,
                                index = idx,

                                attachmentStore = attachmentStore,
                            )
                        }
                    }
                    else -> {
                        val firstFour = imageAttachments.take(4)
                        val remaining = imageAttachments.size - 4
                        Column(
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                UserImageGridCell(attachment = firstFour[0], gallery = imageAttachments, index = 0, attachmentStore = attachmentStore)
                                UserImageGridCell(attachment = firstFour[1], gallery = imageAttachments, index = 1, attachmentStore = attachmentStore)
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                UserImageGridCell(attachment = firstFour[2], gallery = imageAttachments, index = 2, attachmentStore = attachmentStore)
                                UserImageGridCell(
                                    attachment = firstFour[3],
                                    gallery = imageAttachments,
                                    index = 3,
                                    overflowCount = remaining,
    
                                    attachmentStore = attachmentStore,
                                )
                            }
                        }
                    }
                }
            } else {
                
                imageAttachments.forEach { attachment ->
                    AssistantImageView(attachment = attachment)
                }
            }
        }

        
        fileAttachments.forEach { attachment ->
            if (isUserMessage) {
                
                UserFileChip(attachment = attachment, attachmentStore = attachmentStore)
            } else {
                MessageAttachmentChip(
                    fileName = attachment.fileName,
                    kind = attachment.kind,
                    isUnavailable = !hasAccessibleFileData(attachment),
                    isUserMessage = false,
                )
            }
        }
    }
}


@Composable
private fun AssistantImageView(attachment: Attachment) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(12.dp)
    val bitmap = rememberAttachmentDisplayBitmap(attachment)
    var showViewer by remember(attachment.id) { mutableStateOf(false) }

    if (bitmap != null) {
        val aspectRatio = remember(bitmap) {
            bitmap.width.toFloat() / max(bitmap.height.toFloat(), 1f)
        }
        androidx.compose.foundation.Image(
            bitmap = bitmap,
            contentDescription = attachment.fileName,
            contentScale = androidx.compose.ui.layout.ContentScale.Fit,
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 320.dp)
                .aspectRatio(aspectRatio)
                .clickable(enabled = hasAccessibleImageData(attachment)) {
                    showViewer = true
                }
                .clip(shape),
        )
    } else {
        Box(
            modifier = Modifier
                .widthIn(max = 320.dp)
                .heightIn(min = 80.dp)
                .fillMaxWidth()
                .clip(shape)
                .then(
                    if (hasAccessibleImageData(attachment)) {
                        Modifier.clickable { showViewer = true }
                    } else {
                        Modifier
                    },
                )
                .background(colors.surfaceChrome),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.Image,
                contentDescription = null,
                modifier = Modifier.size(28.dp),
                tint = colors.textTertiary,
            )
        }
    }

    if (showViewer) {
        ImageViewerSheet(
            attachments = listOf(attachment),
            initialIndex = 0,
            onDismiss = { showViewer = false },
        )
    }
}


@Composable
private fun UserFileChip(attachment: Attachment, attachmentStore: AttachmentStore) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val scope = rememberCoroutineScope()
    var isDownloading by remember(attachment.id, attachment.base64Data, attachment.rawContentRef) {
        mutableStateOf(false)
    }
    val isUnavailable = !hasAccessibleFileData(attachment)

    Row(
        modifier = Modifier
            .clip(CircleShape)
            .clickable(enabled = !isUnavailable && !isDownloading) {
                scope.launch {
                    isDownloading = true
                    val opened = runCatching { openFileAttachment(context, attachmentStore, attachment) }.getOrDefault(false)
                    isDownloading = false
                    if (!opened) {
                        Toast.makeText(
                            context,
                            resources.getString(R.string.file_unavailable),
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                }
            }
            .background(
                Color.White.copy(
                    alpha = when {
                        isUnavailable -> 0.08f
                        isDownloading -> 0.12f
                        else -> 0.18f
                    },
                ),
            )
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (isDownloading) {
            CircularProgressIndicator(
                modifier = Modifier.size(12.dp),
                strokeWidth = 1.5.dp,
                color = Color.White.copy(alpha = 0.72f),
            )
        } else {
            Icon(
                imageVector = AttachmentIconResolver.iconFor(
                    mime = attachment.mimeType,
                    fileName = attachment.fileName,
                    isUnavailable = isUnavailable,
                ),
                contentDescription = null,
                modifier = Modifier.size(12.dp),
                tint = Color.White.copy(alpha = if (isUnavailable) 0.5f else 0.85f),
            )
        }
        Text(
            text = attachment.fileName,
            style = OriveoTheme.typography.footnote.copy(
                fontSize = androidx.compose.ui.unit.TextUnit(11f, androidx.compose.ui.unit.TextUnitType.Sp),
            ),
            color = Color.White.copy(alpha = if (isUnavailable) 0.5f else 0.85f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private fun hasAccessibleFileData(attachment: Attachment): Boolean =
    !attachment.base64Data.isNullOrBlank() ||
        !attachment.rawContentRef.isNullOrBlank()

internal fun hasAccessibleImageData(attachment: Attachment): Boolean =
    !attachment.localImageId.isNullOrBlank() ||
        (attachment.base64Data?.let { it.isNotBlank() && !it.startsWith("http") } == true) ||
        !attachment.thumbnailBase64.isNullOrBlank()

private fun sanitizeAttachmentFileName(fileName: String): String {
    val sanitized = fileName.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
    return if (sanitized.isBlank()) "attachment" else sanitized
}

private suspend fun openFileAttachment(context: Context, attachmentStore: AttachmentStore, attachment: Attachment): Boolean {
    val tempFile = withContext(Dispatchers.IO) {
        val bytes = loadAttachmentFileBytes(attachmentStore, attachment) ?: return@withContext null
        val cacheDir = File(context.cacheDir, "message_attachments").also { it.mkdirs() }
        val file = File(cacheDir, "${attachment.id}-${sanitizeAttachmentFileName(attachment.fileName)}")
        file.writeBytes(bytes)
        file
    } ?: return false

    val authority = "${context.packageName}.fileprovider"
    val uri = FileProvider.getUriForFile(context, authority, tempFile)
    val packageManager = context.packageManager

    val typedIntent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, attachment.mimeType.ifBlank { "*/*" })
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    val fallbackIntent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, "*/*")
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    
    
    
    
    val launchIntent = when {
        typedIntent.resolveActivity(packageManager) != null -> typedIntent
        fallbackIntent.resolveActivity(packageManager) != null -> fallbackIntent
        else -> typedIntent
    }

    return launchExternalActivitySafely {
        context.startActivity(
            Intent.createChooser(launchIntent, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        )
    } == ExternalActivityLaunchOutcome.LAUNCHED
}

private suspend fun loadAttachmentFileBytes(attachmentStore: AttachmentStore, attachment: Attachment): ByteArray? {
    attachment.base64Data?.takeIf { it.isNotBlank() }?.let { base64 ->
        return runCatching { Base64.decode(base64, Base64.NO_WRAP) }.getOrNull()
    }

    attachment.rawContentRef?.takeIf { it.isNotBlank() }?.let { ref ->
        attachmentStore.loadBlobBytes(ref)?.let { return it }
    }

    return null
}

@Composable
private fun MessageAttachmentChip(
    fileName: String,
    kind: AttachmentKind,
    isUnavailable: Boolean,
    isUserMessage: Boolean,
) {
    val colors = OriveoTheme.colors
    val containerColor = if (isUserMessage) {
        Color.Transparent
    } else {
        colors.surfaceInset
    }
    val contentColor = when {
        isUnavailable && isUserMessage -> Color.White.copy(alpha = 0.54f)
        isUnavailable -> colors.textTertiary
        isUserMessage -> Color.White
        else -> colors.textSecondary
    }
    val borderColor = if (isUserMessage) {
        Color.Transparent
    } else {
        colors.border
    }

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(containerColor)
            .border(OriveoBorderWidth.standard, borderColor, RoundedCornerShape(12.dp))
            .alpha(if (isUnavailable) 0.72f else 1f)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = when (kind) {
                AttachmentKind.Image -> Icons.Outlined.Image
                AttachmentKind.Video -> Icons.Outlined.Videocam
                AttachmentKind.File -> Icons.Outlined.Description
            },
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = contentColor,
        )
        Text(
            text = if (isUnavailable) stringResource(R.string.file_unavailable) else fileName,
            style = OriveoTheme.typography.footnote,
            color = contentColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}


private object AttachmentIconResolver {
    fun iconFor(
        mime: String,
        fileName: String,
        isUnavailable: Boolean,
    ): androidx.compose.ui.graphics.vector.ImageVector {
        if (isUnavailable) return Icons.Outlined.Description
        val mimeLower = mime.lowercase()
        val ext = fileName.substringAfterLast('.', "").lowercase()

        return when {
            mimeLower == "application/pdf" || ext == "pdf" ->
                Icons.Outlined.PictureAsPdf
            mimeLower.contains("wordprocessingml") || mimeLower == "application/msword" ||
                ext in listOf("doc", "docx", "odt", "rtf") ->
                Icons.AutoMirrored.Outlined.Article
            mimeLower.contains("spreadsheetml") || mimeLower == "application/vnd.ms-excel" ||
                ext in listOf("xls", "xlsx", "csv", "ods") ->
                Icons.Outlined.TableChart
            mimeLower.contains("presentationml") || mimeLower == "application/vnd.ms-powerpoint" ||
                ext in listOf("ppt", "pptx", "key", "odp") ->
                Icons.Outlined.Slideshow
            ext in listOf("zip", "rar", "7z", "tar", "gz", "bz2", "xz") ||
                mimeLower.contains("zip") || mimeLower.contains("compressed") ->
                Icons.Outlined.FolderZip
            ext in listOf(
                "swift", "kt", "java", "py", "js", "ts", "tsx", "jsx", "go", "rs",
                "c", "cpp", "h", "hpp", "cs", "rb", "php", "sh", "bash", "zsh",
                "html", "css", "scss", "less", "vue", "svelte",
                "json", "xml", "yaml", "yml", "toml", "ini", "env", "lock", "gradle", "groovy",
            ) -> Icons.Outlined.Code
            mimeLower.startsWith("text/") || ext in listOf("txt", "md", "markdown") ->
                Icons.AutoMirrored.Outlined.TextSnippet
            mimeLower.startsWith("audio/") -> Icons.Outlined.AudioFile
            mimeLower.startsWith("video/") -> Icons.Outlined.Videocam
            else -> Icons.Outlined.Description
        }
    }
}


private fun Modifier.userBubbleGlow(glowColor: Color, isDark: Boolean): Modifier = drawWithCache {
    val sigma = if (isDark) 22.dp.toPx() else 10.dp.toPx()
    val blurRadius = ((sigma - 0.5f) / 0.57735f).coerceAtLeast(1f)
    val offsetY = if (isDark) 4.dp.toPx() else 6.dp.toPx()
    val paint = AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
        style = AndroidPaint.Style.FILL
        color = glowColor.opacity(if (isDark) 0.7f else 0.9f).toArgb()
        maskFilter = BlurMaskFilter(blurRadius, BlurMaskFilter.Blur.NORMAL)
    }
    val cr = CornerRadius(20.dp.toPx())
    val glowPath = Path().apply {
        addRoundRect(
            RoundRect(
                left = 0f,
                top = 0f,
                right = size.width,
                bottom = size.height,
                topLeftCornerRadius = cr,
                topRightCornerRadius = cr,
                bottomLeftCornerRadius = cr,
                bottomRightCornerRadius = cr,
            ),
        )
    }.asAndroidPath()
    onDrawBehind {
        drawIntoCanvas { canvas ->
            canvas.nativeCanvas.save()
            canvas.nativeCanvas.translate(0f, offsetY)
            canvas.nativeCanvas.drawPath(glowPath, paint)
            canvas.nativeCanvas.restore()
        }
    }
}
