package ai.oriveo.community.feature.chat

import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.CloudQueue
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.IconButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Switch
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.resolveProviderLogoKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.util.localizedDescription
import ai.oriveo.community.core.util.localizedName
import ai.oriveo.community.core.util.localizedStarterMessages
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.feature.chat.attachments.AttachmentConflictDialog
import ai.oriveo.community.feature.chat.attachments.AttachmentImportPolicy
import ai.oriveo.community.feature.chat.attachments.AttachmentPreviewRow
import ai.oriveo.community.feature.chat.components.ChatAuroraBackground
import ai.oriveo.community.feature.chat.components.ChatToolbar
import ai.oriveo.community.feature.chat.components.ConversationBootstrapState
import ai.oriveo.community.feature.chat.components.ConversationIssueBanner
import ai.oriveo.community.feature.chat.components.ConversationStalledState
import ai.oriveo.community.feature.chat.components.EmptyChatState
import ai.oriveo.community.feature.chat.components.ExpensiveModelHintBanner
import ai.oriveo.community.feature.chat.composer.NotePreviewSheet
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckSheet
import ai.oriveo.community.feature.chat.components.ProviderDisclosureSheet
import ai.oriveo.community.feature.chat.components.SkillStarterView

import ai.oriveo.community.feature.chat.composer.EnhancedComposer
import ai.oriveo.community.feature.modelpicker.ModelPickerContext
import ai.oriveo.community.feature.modelpicker.ModelPickerSheet
import ai.oriveo.community.ui.component.CostPill
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.component.rememberAttachmentThumbnailBitmap
import ai.oriveo.community.ui.component.markdown.MarkdownRenderCache
import ai.oriveo.community.ui.component.markdown.MarkdownTheme
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.oriveoSurface
import ai.oriveo.community.ui.theme.OriveoTheme
import dev.chrisbanes.haze.ExperimentalHazeApi
import dev.chrisbanes.haze.HazeInputScale
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import dev.chrisbanes.haze.materials.CupertinoMaterials
import dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi
import androidx.metrics.performance.PerformanceMetricsState
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale


@OptIn(
    ExperimentalMaterial3Api::class,
    ExperimentalFoundationApi::class,
    ExperimentalLayoutApi::class,
    ExperimentalHazeApi::class,
    ExperimentalHazeMaterialsApi::class,
)
@Composable
internal fun ChatScreenContent(
    initialConversationId: String? = null,
    searchQuery: String? = null,
    onBack: () -> Unit,
    onNavigateToMemory: () -> Unit = {},
    onNavigateToProviderSetup: () -> Unit = {},
    
    onNavigateToProviderDetail: (providerId: String) -> Unit = {},
    onNavigateToSkillEdit: () -> Unit = {},
    onNavigateToNoteDetail: (String) -> Unit = {},
    viewModel: ChatViewModel,
) {
    val conversationRenderState by viewModel.conversation.collectAsStateWithLifecycle()
    val providers by viewModel.providers.collectAsStateWithLifecycle()
    // The bridge is the sole metadata/TTL/credential invalidation input for capability controls.
    // Reading it here causes the existing resolver calls below to re-run without recreating the VM.
    
    
    
    
    val capabilityObservationRevision = CapabilityEvidenceObservationBridge.revision
        .collectAsStateWithLifecycle()
    
    
    
    val streamingMessageId by viewModel.streamingMessageId.collectAsStateWithLifecycle()
    val hasMoreAbove by viewModel.hasMoreAbove.collectAsStateWithLifecycle()
    val hasMoreBelow by viewModel.hasMoreBelow.collectAsStateWithLifecycle()
    val isLoadingAbove by viewModel.isLoadingAbove.collectAsStateWithLifecycle()
    val isInitialLoading by viewModel.isInitialLoading.collectAsStateWithLifecycle()
    val showMemoryIndicator by viewModel.showMemoryIndicator.collectAsStateWithLifecycle()
    val currentMemoryText by viewModel.currentMemoryText.collectAsStateWithLifecycle()

    val colors = OriveoTheme.colors
    val markdownColors = MarkdownTheme.colors()
    val screenH = OriveoTheme.layout.screenH
    val context = LocalContext.current
    val resources = LocalResources.current
    

    val view = LocalView.current
    val density = LocalDensity.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val trueTransparentBlurEnabled = remember { Build.VERSION.SDK_INT >= Build.VERSION_CODES.S_V2 }
    val hazeState = rememberHazeState(blurEnabled = trueTransparentBlurEnabled)
    var composerOverlayHeightPx by remember { mutableIntStateOf(0) }
    val composerOverlayHeightDp = with(density) { composerOverlayHeightPx.toDp() }
    val imeInsets = WindowInsets.ime
    val imeBottomPx = imeInsets.getBottom(density)
    val metricsStateHolder = remember(view) { PerformanceMetricsState.getHolderForHierarchy(view) }

    val conversation = conversationRenderState.conversation ?: viewModel.bootstrapConversation
    val messages = conversation?.messages ?: emptyList()
    
    val messagesEmpty = messages.isEmpty()
    
    val chatLoadState = viewModel.chatLoadState
    val currentSkill by viewModel.currentSkill.collectAsStateWithLifecycle()
    
    val attachedNotes by viewModel.noteCoordinator.attachedNotes.collectAsStateWithLifecycle()
    val relatedNotes by viewModel.noteCoordinator.relatedNotes.collectAsStateWithLifecycle()
    val savedNoteLinksByMessage by viewModel.noteCoordinator.savedNoteLinksByMessage.collectAsStateWithLifecycle()
    val canReplaceCurrentNote by viewModel.noteCoordinator.canReplaceCurrentNote.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val coroutineScope = rememberCoroutineScope()
    val latestMessageCount by rememberUpdatedState(messages.size)
    
    
    val latestMessages by rememberUpdatedState(messages)
    
    
    var isPointerDown by remember { mutableStateOf(false) }
    
    var noteFocusHighlightId by remember { mutableStateOf<String?>(null) }

    val providersById = remember(providers) { providers.associateBy { it.id } }
    val displayLookup = remember(providers) { ModelDisplayLookup(providers) }
    val hasVerifiedConnectedUserProvider = remember(providers) { providers.isNotEmpty() }
    val conversationId = conversation?.id
    val searchTargetIndex = remember(searchQuery, messages) {
        val normalized = searchQuery?.trim()?.lowercase(Locale.ROOT).orEmpty()
        if (normalized.isBlank()) {
            -1
        } else {
            messages.indexOfFirst { it.text.lowercase(Locale.ROOT).contains(normalized) }
        }
    }
    val handleScreenLeaving by rememberUpdatedState(newValue = { viewModel.handleChatScreenLeaving() })
    
    
    val lastDeliveredAssistant = remember(messages) {
        messages.lastOrNull { it.role == ai.oriveo.community.core.model.ChatRole.Assistant && it.state == ai.oriveo.community.core.model.ChatMessageState.Delivered }
    }
    val assistantPrewarmFingerprint = remember(
        messages.size,
        lastDeliveredAssistant?.id,
        lastDeliveredAssistant?.text?.length,
    ) {
        assistantMarkdownPrewarmFingerprint(messages)
    }

    
    
    val activeProvider by remember(providersById) {
        derivedStateOf {
            capabilityObservationRevision.value
            providersById[viewModel.activeProviderId]
        }
    }
    val activeModel by remember(providersById) {
        derivedStateOf {
            capabilityObservationRevision.value
            ProviderSelectionSnapshot.currentModel(
                providersById[viewModel.activeProviderId],
                viewModel.activeModelId,
            )
        }
    }
    val activeModelName = (activeModel?.name ?: viewModel.activeModelId ?: "") +
        if (activeModel?.executionLocality == ai.oriveo.community.core.model.ModelExecutionLocality.ProxiedCloud) {
            " · ${stringResource(R.string.local_model_via_ollama_cloud)}"
        } else ""

    
    var showMoreMenu by remember { mutableStateOf(false) }
    var showDeleteConfirmation by remember { mutableStateOf(false) }
    var showMemorySheet by remember { mutableStateOf(false) }
    var hasLoadedConversation by remember { mutableStateOf(false) }

    ChatMissingConversationExitEffect(
        conversationId = conversationId,
        conversation = conversation,
        hasMissingInitialConversation = viewModel.hasMissingInitialConversation,
        isGenerating = viewModel.isGenerating,
        isUserInitiatedExit = viewModel.isUserInitiatedExit,
        hasLoadedConversation = hasLoadedConversation,
        onHasLoadedConversationChange = { hasLoadedConversation = it },
        onBack = onBack,
    )

     
    
    
    
    
    
    
    
    val scrollController = rememberChatScrollController()
    val reserveDp = with(density) { scrollController.reservePx.toDp() }
    val minAssistantVisiblePx = with(density) { MIN_ASSISTANT_VISIBLE_HINT_DP.dp.roundToPx() }
    var wasAtLatestBeforeIme by remember { mutableStateOf(true) }
    var initialBottomSettledConversationId by remember { mutableStateOf<String?>(null) }
    val hasNavigationTarget = !searchQuery.isNullOrBlank() || viewModel.noteCoordinator.focusMessageId != null
    val hideInitialListUntilBottomSettled = !hasNavigationTarget &&
        conversationId != null &&
        conversationId == initialConversationId &&
        messages.isNotEmpty() &&
        initialBottomSettledConversationId != conversationId

    
    val isDragging by remember(listState) {
        derivedStateOf { isPointerDown && listState.isScrollInProgress }
    }

    ChatPinToTopEffect(
        pendingPinUserMessageId = viewModel.pendingPinUserMessageId,
        latestMessages = latestMessages,
        listState = listState,
        scrollController = scrollController,
        minAssistantVisiblePx = minAssistantVisiblePx,
        consumePendingPin = viewModel::consumePendingPin,
    )

    
    
    
    
    
    ChatFollowToBottomEffect(
        listState = listState,
        scrollController = scrollController,
        isPointerDown = isPointerDown,
    )

    
    ChatStreamingModeEffect(viewModel.isGenerating, scrollController)

    
    
    
    
    ChatInitialScrollToBottomEffect(
        conversationId = conversationId,
        initialConversationId = initialConversationId,
        enabled = !hasNavigationTarget,
        latestMessageCount = latestMessageCount,
        composerOverlayHeightPx = composerOverlayHeightPx,
        listState = listState,
        scrollController = scrollController,
        onInitialBottomSettledConversationChange = { initialBottomSettledConversationId = it },
    )

    ChatSearchScrollTargetEffect(
        conversationId = conversationId,
        searchQuery = searchQuery,
        targetIndex = searchTargetIndex,
        latestMessageCount = latestMessageCount,
        composerOverlayHeightPx = composerOverlayHeightPx,
        listState = listState,
        scrollController = scrollController,
    )

    
    
    ChatNoteEffects(
        focusMessageId = viewModel.noteCoordinator.focusMessageId,
        conversationId = conversationId,
        messages = messages,
        hasMoreAbove = hasMoreAbove,
        isLoadingAbove = isLoadingAbove,
        isInitialLoading = isInitialLoading,
        listState = listState,
        scrollController = scrollController,
        density = density,
        highlightId = noteFocusHighlightId,
        lastDeliveredAssistant = lastDeliveredAssistant,
        navToNoteDetail = viewModel.noteCoordinator.navToNoteDetail,
        onLoadMoreAbove = { viewModel.loadMoreAbove() },
        onLoadFocusMessageWindow = { viewModel.loadFocusMessageWindow(it) },
        onSetHighlight = { noteFocusHighlightId = it },
        onNavigateToNoteDetail = onNavigateToNoteDetail,
        onMaybeShowHint = { viewModel.noteCoordinator.maybeShowNoteCaptureHint() },
    )


    ChatImeLatestTrackingEffect(
        listState = listState,
        imeBottomPx = imeBottomPx,
        onWasAtLatestBeforeImeChange = { wasAtLatestBeforeIme = it },
    )

    
    
    
    
    ChatImeFollowEffect(
        listState = listState,
        imeInsets = imeInsets,
        density = density,
        scrollController = scrollController,
        wasAtLatestBeforeIme = wasAtLatestBeforeIme,
        isPointerDown = isPointerDown,
    )

    
    
    
    ChatAnchorTransitionEffect(
        listState = listState,
        scrollController = scrollController,
        isPointerDown = isPointerDown,
        hideKeyboard = { keyboardController?.hide() },
    )

    
    
    
    
    ChatLoadMoreAboveEffect(
        listState = listState,
        hasMoreAbove = viewModel.hasMoreAbove,
        isLoadingAbove = viewModel.isLoadingAbove,
        loadMoreAbove = viewModel::loadMoreAbove,
    )
    ChatLoadMoreBelowEffect(
        listState = listState,
        hasMoreBelow = viewModel.hasMoreBelow,
        isLoadingBelow = viewModel.isLoadingBelow,
        loadMoreBelow = viewModel::loadMoreBelow,
    )

    ChatMetricsEffect(
        metricsStateHolder = metricsStateHolder,
        listState = listState,
        isGenerating = viewModel.isGenerating,
    )

    ChatMarkdownPrewarmEffect(
        assistantPrewarmFingerprint = assistantPrewarmFingerprint,
        markdownColors = markdownColors,
        messages = messages,
    )

    ChatScreenLeavingEffect(handleScreenLeaving)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .testTag("chat_screen"),
    ) {
        
        OriveoScreenBackground(
            modifier = Modifier.hazeSource(state = hazeState, zIndex = 0f),
        )
        
        ChatAuroraBackground(prominent = messagesEmpty)

        
        
        
        
        Box(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars)),
        ) {

        Column(
            modifier = Modifier
                .fillMaxSize(),
        ) {
            ChatToolbar(
                skillIcon = currentSkill?.icon,
                providerKind = activeProvider?.kind,
                relayKind = activeProvider?.relayKind,
                providerName = activeProvider?.displayName.orEmpty(),
                modelName = activeModelName.ifEmpty { stringResource(R.string.select_model) },
                isSendingMessage = viewModel.isGenerating,
                cost = conversation?.estimatedCost ?: 0.0,
                costText = conversation?.estimatedCostText.orEmpty(),
                showMenu = showMoreMenu,
                onBack = onBack,
                onToggleModelSwitcher = { viewModel.showModelSwitcher = true },
                onNewChat = { viewModel.startNewChat() },
                onOpenMenu = { showMoreMenu = true },
                onDismissMenu = { showMoreMenu = false },
                onExportConversation = { viewModel.exportAsMarkdown(context) },
                onDeleteConversation = { showDeleteConfirmation = true },
                showMemoryIndicator = showMemoryIndicator,
                onOpenMemoryIndicator = { showMemorySheet = true },
                showMemoryToggle = conversation != null && currentMemoryText.isNotBlank(),
                memoryEnabledForConversation = conversation?.useMemory ?: true,
                onToggleUseMemory = {
                    viewModel.toggleUseMemory()
                    showMoreMenu = false
                },
                hasMessages = messages.isNotEmpty(),
                transparentChrome = messagesEmpty,
                hazeState = hazeState,
                trueTransparentBlurEnabled = trueTransparentBlurEnabled,
            )

            
            viewModel.noteCoordinator.returnToNoteId?.let { noteId ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = screenH, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Row(
                        modifier = Modifier
                            .weight(1f)
                            .clickable { onNavigateToNoteDetail(noteId) },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            text = stringResource(R.string.notes_chat_return_to_note),
                            style = OriveoTheme.typography.footnote,
                            color = colors.primary,
                        )
                    }
                }
            }

            viewModel.conversationState.issue?.let { issue ->
                ConversationIssueBanner(
                    issue = issue,
                    providerName = activeProvider?.displayName,
                    onPrimaryAction = {
                        if (issue.canRepairFromModelPicker) {
                            viewModel.showModelSwitcher = true
                        } else {
                            onBack()
                        }
                    },
                )
            }


            
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .hazeSource(state = hazeState, zIndex = 1f),
            ) {
                if (chatLoadState == ChatLoadState.Bootstrapping) {
                    ConversationBootstrapState(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = screenH),
                    )
                } else if (chatLoadState == ChatLoadState.Stalled) {
                    ConversationStalledState(
                        onRetry = viewModel::retryConversationLoad,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = screenH)
                            .padding(bottom = composerOverlayHeightDp),
                    )
                } else if (messages.isEmpty() && !viewModel.isGenerating) {
                    
                    
                    
                    
                    EmptyChatState(
                        skillIcon = currentSkill?.icon,
                        skillDescription = currentSkill?.localizedDescription(),
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = screenH)
                            .padding(bottom = composerOverlayHeightDp),
                    )
                } else {
                    ChatMessagesList(
                        messages = messages,
                        streamingMessageId = streamingMessageId,
                        streamingText = viewModel.streamingText,
                        streamingReasoning = viewModel.streamingReasoning,
                        streamingReasoningActive = viewModel.streamingReasoningActive,
                        listState = listState,
                        scrollController = scrollController,
                        hasMoreAbove = hasMoreAbove,
                        hasMoreBelow = hasMoreBelow,
                        displayLookup = displayLookup,
                        providersById = providersById,
                        composerOverlayHeightDp = composerOverlayHeightDp,
                        reserveDp = reserveDp,
                        hideInitialListUntilBottomSettled = hideInitialListUntilBottomSettled,
                        isDragging = isDragging,
                        isPointerDown = isPointerDown,
                        onPointerDownChange = { isPointerDown = it },
                        isGenerating = viewModel.isGenerating,
                        isRateLimitError = ::isRateLimitError,
                        onCopy = { message -> viewModel.copyMessage(message, context) },
                        onEdit = { message ->
                            val restoredText = viewModel.editMessageInline(message.id)
                            if (restoredText != null) {
                                viewModel.onInputTextChanged(restoredText)
                            }
                        },
                        onRegenerate = viewModel::regenerateMessage,
                        onContinue = viewModel::continueMessage,
                        onRetry = viewModel::retryMessage,
                        onRetryWithoutLocalCustomFields = viewModel::retryWithoutLocalCustomFields,
                        onSwitchModel = { viewModel.showModelSwitcher = true },
                        onShare = { message -> viewModel.shareMessage(message, context) },
                        onSaveAsNote = { message -> viewModel.noteCoordinator.saveMessageAsNote(message.id) },
                        onSaveCodeAsNote = { message, code -> viewModel.noteCoordinator.saveSelectionAsNote(message.id, code) },
                        onSaveSelectionAsNote = { message, text -> viewModel.noteCoordinator.saveSelectionAsNote(message.id, text) },
                        onAskSelection = { message, selection ->
                            if (!viewModel.askAboutSelection(message, selection)) {
                                android.widget.Toast.makeText(
                                    context,
                                    resources.getString(R.string.chat_selection_too_long),
                                    android.widget.Toast.LENGTH_SHORT,
                                ).show()
                            }
                        },
                        onReplaceSelectionInCurrentNote = { message, text, noteId ->
                            viewModel.noteCoordinator.replaceCurrentNoteSelection(message.id, text, noteId)
                        },
                        onCrosscheck = { message -> viewModel.noteCoordinator.openCrosscheck(message.id) },
                        savedNoteLinksByMessage = savedNoteLinksByMessage,
                        returnToNoteId = if (canReplaceCurrentNote) viewModel.noteCoordinator.returnToNoteId else null,
                        onOpenSavedNote = onNavigateToNoteDetail,
                        highlightedMessageId = noteFocusHighlightId,
                        context = context,
                        coroutineScope = coroutineScope,
                        latestMessageCount = latestMessageCount,
                    )
                }

                
            }

        }

        
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .onSizeChanged { composerOverlayHeightPx = it.height },
        ) {
            viewModel.expensiveModelHint?.let { hint ->
                ExpensiveModelHintBanner(
                    hint = hint,
                    onDismiss = { viewModel.dismissExpensiveModelHint() },
                )
            }

            EnhancedComposer(
                inputText = viewModel.inputText,
                onInputChange = viewModel::onInputTextChanged,
                pendingAttachments = viewModel.pendingAttachments,
                pendingQuoteContext = viewModel.pendingQuoteContext,
                onRemoveQuote = viewModel::removePendingQuote,
                onAttachmentRemove = viewModel::removeAttachment,
                currentModel = viewModel.conversationState.model,
                generationParameterProvider = activeProvider,
                generationParameterConversationId = conversationId ?: viewModel.generationParameterDraftSessionId,
                isExistingConversation = conversationId != null,
                conversationSkillId = conversation?.skillId,
                modelControlsFinalTransport = viewModel.modelControlsFinalTransport(),
                supportsImageAttachment = viewModel.supportsImage(),
                supportsVideoAttachment = viewModel.supportsVideo(),
                supportsFileAttachment = viewModel.supportsFile(),
                onSelectReasoningMode = viewModel::selectReasoningMode,
                onWebSearchToggled = viewModel::updateWebSearchEnabled,
                onSelectModel = viewModel::selectModel,
                onOpenModelSwitcher = { viewModel.showModelSwitcher = true },
                showAttachmentSizeLimitDialog = viewModel.showAttachmentSizeLimitDialog,
                onDismissAttachmentSizeLimitDialog = viewModel::dismissAttachmentSizeLimitDialog,
                onProcessImageUri = { uri -> viewModel.processImageUri(context, uri) },
                onProcessFileUri = { uri -> viewModel.processFileUri(context, uri) },
                onSendClick = viewModel::sendMessage,
                onStopGeneration = viewModel::stopGeneration,
                providerKind = activeProvider?.kind,
                onNavigateToProviderSetup = onNavigateToProviderSetup,
                onNavigateToProviderDetail = onNavigateToProviderDetail,
                
                onNavigateToSkillEdit = onNavigateToSkillEdit,
                canUseKnowledgeBase = activeProvider?.kind == ProviderKind.OpenAI &&
                    activeProvider?.apiKey?.isNotEmpty() == true,
                isGenerating = viewModel.isGenerating,
                
                
                isReadOnly = !viewModel.canSendMessages || chatLoadState.blocksSending(),
                managedQuotaPresentation = null,
                transparentChrome = messagesEmpty,
                hazeState = hazeState,
                trueTransparentBlurEnabled = trueTransparentBlurEnabled,
                attachedNotes = attachedNotes,
                relatedNotes = relatedNotes,
                onAttachNote = viewModel.noteCoordinator::attachNoteToContext,
                onDismissRelatedNote = viewModel.noteCoordinator::dismissRelatedNote,
                onDetachNote = viewModel.noteCoordinator::detachNoteFromContext,
                onPreviewNote = viewModel.noteCoordinator::showNotePreview,
            )
        }
        }
    }

    viewModel.noteCoordinator.notePreview?.let { note ->
        NotePreviewSheet(note = note, onDismiss = viewModel.noteCoordinator::clearNotePreview)
    }

    
    viewModel.noteCoordinator.crosscheckOrigin?.let { origin ->
        val crosscheckState by viewModel.noteCoordinator.crosscheckState.collectAsStateWithLifecycle()
        val sourceProvider = origin.message.providerID?.let { providersById[it] }
        val sourceLogoKind = sourceProvider?.let(::resolveProviderLogoKind) ?: origin.message.providerKind
        val sourceRelayKind = sourceProvider
            ?.takeIf { it.kind == ProviderKind.Relay && resolveProviderLogoKind(it) == ProviderKind.Relay }
            ?.relayKind
        CrosscheckSheet(
            originalAnswer = origin.message.text,
            providers = providers,
            options = viewModel.noteCoordinator.crosscheckOptions(),
            state = crosscheckState,
            onRun = viewModel::runCrosscheck,
            onSave = viewModel.noteCoordinator::saveCrosscheckNote,
            onEnableModel = viewModel::enableModel,
            onDismiss = viewModel.noteCoordinator::closeCrosscheck,
            sourceProviderKind = sourceLogoKind,
            sourceProviderName = origin.message.providerName,
            sourceModelName = origin.message.modelName,
            sourceRelayKind = sourceRelayKind,
        )
    }


    
    

    // Model Switcher Bottom Sheet
    if (viewModel.showModelSwitcher) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { viewModel.showModelSwitcher = false },
            sheetState = sheetState,
            dragHandle = null,
            contentWindowInsets = { WindowInsets(0) },
            
            containerColor = ai.oriveo.community.ui.theme.OriveoTheme.colors.backgroundBase,
        ) {
            ModelPickerSheet(
                context = ModelPickerContext.Chat,
                providers = providers,
                activeProviderId = viewModel.activeProviderId,
                activeModelId = viewModel.activeModelId,
                onEnableModel = viewModel::enableModel,
                onModelSelected = { providerId, modelId ->
                    viewModel.selectModel(providerId, modelId)
                },
                onDismiss = { viewModel.showModelSwitcher = false },
            )
        }
    }

    
    viewModel.providerDisclosurePrompt?.let { prompt ->
        ProviderDisclosureSheet(
            prompt = prompt,
            onAccept = viewModel::confirmProviderDisclosure,
            onCancel = viewModel::cancelProviderDisclosure,
        )
    }

    if (showDeleteConfirmation) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirmation = false },
            confirmButton = {
                
                TextButton(
                    onClick = {
                        showDeleteConfirmation = false
                        viewModel.deleteConversation()
                        onBack()
                    },
                ) {
                    Text(
                        text = stringResource(R.string.delete),
                        color = OriveoTheme.colors.danger,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirmation = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
            title = { Text(stringResource(R.string.delete_conversation_title)) },
            text = { Text(stringResource(R.string.delete_conversation_confirm)) },
        )
    }

    if (showMemorySheet && currentMemoryText.isNotBlank()) {
        MemoryIndicatorSheet(
            memoryText = currentMemoryText,
            onDismiss = { showMemorySheet = false },
            onViewEdit = {
                showMemorySheet = false
                onNavigateToMemory()
            },
            onDisableForConversation = conversation?.let {
                {
                    viewModel.toggleUseMemory()
                    showMemorySheet = false
                }
            },
        )
    }
}


internal const val MESSAGE_WINDOW_LOAD_MORE_THRESHOLD = 5


internal const val MARKDOWN_PREWARM_RECENT_MESSAGE_LIMIT = 12
