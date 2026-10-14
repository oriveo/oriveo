package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.data.repository.ProviderRepository
import org.koin.compose.koinInject
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.chat.components.ConversationIssueBanner
import ai.oriveo.community.feature.chat.ChatViewModel
import ai.oriveo.community.feature.chat.components.ExpensiveModelHintBanner
import dev.chrisbanes.haze.HazeState

/**
 * Host for the composer overlay, and the **sole owner of the composer text**.
 *
 * Why it is a layer of its own: `ChatScreenContent` used to read `viewModel.inputText` (snapshot
 * state) in its root body and pass it down to [EnhancedComposer], so every keystroke invalidated
 * the root composable -- and once `ChatMessagesList` recomposes with it, foundation's
 * `rememberLazyListItemProviderLambda` swaps in a fresh `LazyListIntervalContent` and **every
 * visible cell, markdown subtree included, recomposes**.
 *
 * Per-keystroke text now lives only in this composable's local state, and **this body does not read
 * it either** -- the text reaches `ComposerTextField` through a stable provider, so the
 * per-keystroke recomposition surface is that one composable (the thousand-plus line
 * `EnhancedComposer` body no longer runs once per character). The rest of the benefit:
 * - outbound truth (sending, drafts, note recall) goes through [ChatViewModel.onInputTextChanged],
 *   which writes a non-snapshot field and invalidates no composable;
 * - overwriting the field from the outside (draft hydration, clear after send, new chat, restoring
 *   an inline edit) only bumps the token of [ChatViewModel.composerTextRestore], and this file is
 *   the whole screen's only reader of it;
 * - `relatedNotes` is a `debounce(250)` derivative of the text, so it **has** to be collected here.
 *   Collecting it at the root would push the whole page into the recomposition queue every 250ms,
 *   which is the same trap as reading inputText per keystroke.
 *
 * By the same reasoning, the handful of view-model states that only the composer consumes
 * (attachments, quote, attached notes) are collected here too, so "add an attachment" no longer
 * recomposes the entire message list.
 */
@Composable
internal fun ChatComposerHost(
    viewModel: ChatViewModel,
    activeProvider: Provider?,
    conversationId: String?,
    conversationSkillId: String?,
    /** Loading states (skeleton, backfill, stalled) block writing; OR-ed with `canSendMessages`. */
    sendingBlockedByLoadState: Boolean,
    transparentChrome: Boolean,
    hazeState: HazeState,
    trueTransparentBlurEnabled: Boolean,
    onOverlayHeightChange: (Int) -> Unit,
    onNavigateToProviderSetup: () -> Unit,
    onNavigateToProviderDetail: (providerId: String) -> Unit,
    onNavigateToConnectionWebSearch: (providerId: String) -> Unit = {},
    /** "Test capability" for a rejected web template: opens this model's advanced page in this connection. */
    onNavigateToRelayModelAdvanced: (providerId: String, modelId: String) -> Unit = { _, _ -> },
    onNavigateToSkillEdit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val restore = viewModel.composerTextRestore
    // Local text: typing only mutates this. It starts from the current restore value so that a
    // draft hydrated before the first composition is not lost.
    val composerText = remember { mutableStateOf(restore.text) }
    // Keyed on the token alone: pushing the same text twice still takes effect twice, while typing
    // never triggers this effect.
    LaunchedEffect(restore.token) { composerText.value = restore.text }
    // **This body deliberately never reads composerText.value.** Reading it would recompose this
    // composable on every keystroke, which would hand EnhancedComposer a fresh batch of
    // `viewModel::` method references and make it non skippable too.
    // The text only travels down through this stable provider; the actual subscription happens
    // inside ComposerTextField's own scope.
    val inputTextProvider = remember { { composerText.value } }
    // The body only needs "is there any text": send button enablement and draft highlight. It
    // recomposes once, when the text crosses between empty and non-empty.
    val hasComposerText by remember { derivedStateOf { composerText.value.isNotBlank() } }

    val attachedNotes by viewModel.noteCoordinator.attachedNotes.collectAsStateWithLifecycle()
    val relatedNotes by viewModel.noteCoordinator.relatedNotes.collectAsStateWithLifecycle()
    // Must be subscribed here: the view model's isGenerating reads StateFlow.value, which is not
    // snapshot state. This host is skippable, so a recomposition of the screen root triggered by
    // streamingMessageId skips it, and the recomposition caused by clearing the input on send runs
    // before the stream is marked active. Without its own subscription the stop button never
    // appears. The value flips once when a stream starts or ends, never per token.
    val streamingMessageId by viewModel.streamingMessageId.collectAsStateWithLifecycle()
    // Only the official Gemini route depends on whether the outbound history contains video; other
    // providers do not subscribe (subscribing reads the whole history from the database).
    val outboundHistoryHasVideo = if (activeProvider?.kind == ProviderKind.Gemini) {
        viewModel.outboundHistoryHasVideo.collectAsStateWithLifecycle().value
    } else {
        false
    }
    // The number on the "Tools" chip and its dimmed state come from local storage: they are read again
    // whenever the conversation, the connection or the model changes, and once more after an answer
    // ends (the loop may just have found that a server needs re-authorization).
    val mcpPanelState = viewModel.mcpCoordinator.panelState
    val mcpModelId = viewModel.conversationState.model?.id
    LaunchedEffect(conversationId, activeProvider?.id, mcpModelId, streamingMessageId == null) {
        viewModel.mcpCoordinator.refresh()
    }

    // The relay verdict for the image entry needs the connection identity (obtained the same way as the
    // generation parameters in EnhancedComposer); it stays null when unavailable and the check fails closed.
    val providerRepository = koinInject<ProviderRepository>()
    val capabilityPartition = providerRepository.currentCapabilityPartitionId()
    var imageCapabilityIdentity by remember(activeProvider, mcpModelId, capabilityPartition) {
        mutableStateOf<ai.oriveo.community.core.model.CapabilityEvidenceIdentity?>(null)
    }
    LaunchedEffect(activeProvider, mcpModelId, capabilityPartition) {
        val provider = activeProvider
        imageCapabilityIdentity = if (provider?.kind == ProviderKind.Relay && mcpModelId != null) {
            providerRepository.capabilityEvidenceIdentity(provider, mcpModelId, capabilityPartition)
        } else {
            null
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .onSizeChanged { onOverlayHeightChange(it.height) },
    ) {
        viewModel.expensiveModelHint?.let { hint ->
            ExpensiveModelHintBanner(
                hint = hint,
                onDismiss = { viewModel.dismissExpensiveModelHint() },
            )
        }

        // The relay conversation's model was removed: the banner sits right above the composer and its
        // button opens the model picker.
        viewModel.conversationState.issue?.takeIf { it.rendersAboveComposer }?.let { issue ->
            ConversationIssueBanner(
                issue = issue,
                providerName = activeProvider?.displayName,
                onPrimaryAction = { viewModel.showModelSwitcher = true },
            )
        }

        EnhancedComposer(
            inputTextProvider = inputTextProvider,
            hasComposerText = hasComposerText,
            onInputChange = {
                composerText.value = it
                viewModel.onInputTextChanged(it)
            },
            pendingAttachments = viewModel.pendingAttachments,
            pendingQuoteContext = viewModel.pendingQuoteContext,
            onRemoveQuote = viewModel::removePendingQuote,
            onAttachmentRemove = viewModel::removeAttachment,
            currentModel = viewModel.conversationState.model,
            generationParameterProvider = activeProvider,
            generationParameterConversationId = conversationId ?: viewModel.generationParameterDraftSessionId,
            isExistingConversation = conversationId != null,
            conversationSkillId = conversationSkillId,
            modelControlsFinalTransport = viewModel.modelControlsFinalTransport(),
            supportsImageAttachment = viewModel.supportsImage(imageCapabilityIdentity),
            supportsVideoAttachment = viewModel.supportsVideo(),
            supportsFileAttachment = viewModel.supportsFile(),
            outboundHistoryHasVideo = outboundHistoryHasVideo,
            onSelectReasoningMode = viewModel::selectReasoningMode,
            onSelectModel = viewModel::selectModel,
            onOpenModelSwitcher = { viewModel.showModelSwitcher = true },
            mcpEntryVisible = viewModel.mcpCoordinator.isEntryVisible,
            mcpToolsAvailable = mcpPanelState.availability.isAvailable,
            mcpEnabledServerCount = mcpPanelState.enabledServerCount,
            onOpenMcpTools = viewModel.mcpCoordinator::openToolPanel,
            showAttachmentSizeLimitDialog = viewModel.showAttachmentSizeLimitDialog,
            onDismissAttachmentSizeLimitDialog = viewModel::dismissAttachmentSizeLimitDialog,
            onProcessImageUri = { uri -> viewModel.processImageUri(context, uri) },
            onProcessFileUri = { uri -> viewModel.processFileUri(context, uri) },
            onSendClick = viewModel::sendMessage,
            onStopGeneration = viewModel::stopGeneration,
            providerKind = activeProvider?.kind,
            onNavigateToProviderSetup = onNavigateToProviderSetup,
            onNavigateToProviderDetail = onNavigateToProviderDetail,
            onNavigateToConnectionWebSearch = onNavigateToConnectionWebSearch,
            onNavigateToRelayModelAdvanced = onNavigateToRelayModelAdvanced,
            onNavigateToSkillEdit = onNavigateToSkillEdit,
            isGenerating = streamingMessageId != null,
            // Loading states (skeleton, backfilling) and stalled all block writing: allowing a send
            // while stalled means the user starts talking in a conversation that has history, and
            // the context is silently dropped. It becomes writable again once the backfill lands.
            isReadOnly = viewModel.conversationState.isReadOnly || sendingBlockedByLoadState,
            // When the conversation's model was removed the composer stays editable and only sending is blocked.
            isSendBlocked = !viewModel.canSendMessages,
            transparentChrome = transparentChrome,
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
