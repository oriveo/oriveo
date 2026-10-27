package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.feature.chat.realtimeVoiceTarget
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Compress
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.flow.MutableStateFlow
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
import ai.oriveo.community.feature.chat.components.modelRetiredBannerContent
import ai.oriveo.community.feature.chat.ChatViewModel
import ai.oriveo.community.feature.chat.components.ExpensiveModelHintBanner
import dev.chrisbanes.haze.HazeState
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely
import ai.oriveo.community.core.voice.RecordingStore
import ai.oriveo.community.ui.component.ComposerSelectionProbe
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager

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
    onNavigateToVoiceSettings: () -> Unit = {},
    onNavigateToProviderDetail: (providerId: String) -> Unit,
    onNavigateToWebSearchFromChat: (conversationId: String?, oneTap: ai.oriveo.community.core.search.OneTapReuseTarget?) -> Unit = { _, _ -> },
    onNavigateToConnectionWebSearch: (providerId: String) -> Unit = {},
    /** "Test capability" for a rejected web template: opens this model's advanced page in this connection. */
    onNavigateToRelayModelAdvanced: (providerId: String, modelId: String) -> Unit = { _, _ -> },
    onNavigateToSkillEdit: () -> Unit,
    modifier: Modifier = Modifier,
    /** Ring tap; opens the context panel. */
    onOpenContextUsage: () -> Unit = {},
    /** Waveform key on an empty draft; defaults to the view model's voice request hook. */
    onStartVoiceConversation: () -> Unit = viewModel.voice::request,
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
    val contextUsage by viewModel.contextUsage.collectAsStateWithLifecycle()
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

    // Third-compaction hint, shown above the composer only for the conversation it belongs to.
    val compactionHintId by remember(viewModel) {
        viewModel.compaction?.hint ?: MutableStateFlow<String?>(null)
    }.collectAsStateWithLifecycle()
    // AI summary in progress for this conversation (the instant fallback never shows).
    val aiCompacting by remember(viewModel) {
        viewModel.compaction?.aiCompacting ?: MutableStateFlow(emptySet())
    }.collectAsStateWithLifecycle()
    val compactingHere = conversationId != null && conversationId in aiCompacting
    // Only a compaction inside a send makes the send button a stop button; pre-compaction and manual keep send.
    val sendCompacting by remember(viewModel) {
        viewModel.compaction?.sendCompacting ?: MutableStateFlow(emptySet())
    }.collectAsStateWithLifecycle()
    val sendCompactingHere = conversationId != null && conversationId in sendCompacting
    // A send waiting for the pre-send confirmation also shows the stop button (stop = cancel).
    val confirmWaitingHere by remember(viewModel) {
        viewModel.compaction?.pendingConfirm ?: MutableStateFlow(null)
    }.collectAsStateWithLifecycle()

    val isGenerating = streamingMessageId != null || sendCompactingHere || confirmWaitingHere != null
    val isReadOnly = viewModel.conversationState.isReadOnly || sendingBlockedByLoadState

    // Dictation host: the slot is the conversation, or the home draft slot before one exists.
    // Only the handle is built here; controller state is collected inside the dictation components.
    val dictationSlotKey = conversationId ?: RecordingStore.HOME_DRAFT_KEY
    val chatSnackbar = rememberGlobalSnackbarManager()
    val selectionProbe = remember(chatSnackbar) {
        ComposerSelectionProbe(
            onLimitExceeded = {
                chatSnackbar?.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(
                            R.string.chat_input_length_limit_reached,
                            listOf(COMPOSER_MAX_INPUT_LENGTH),
                        ),
                    ),
                )
            },
        )
    }
    val dictationActions = object : DictationHostActions {
        override fun insert(text: String) {
            // Lands at the caret (or replaces the selection); read through the provider so the body never subscribes.
            val newText = selectionProbe.insert(text, inputTextProvider())
            composerText.value = newText
            viewModel.onInputTextChanged(newText)
        }

        // Same gate as the send button.
        override fun canSend(): Boolean = !isReadOnly && viewModel.canSendMessages && !isGenerating

        override fun send() = viewModel.sendMessage()

        override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) {
            chatSnackbar?.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(spec.message),
                    style = spec.style,
                    action = spec.snackbarAction(onUndo),
                    durationMs = spec.durationMillis,
                ),
            )
        }

        override fun openAppSettings() {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", context.packageName, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val outcome = launchExternalActivitySafely { context.startActivity(intent) }
            if (outcome != ExternalActivityLaunchOutcome.LAUNCHED) {
                chatSnackbar?.show(
                    GlobalSnackbarMessage(
                        UiText.Resource(R.string.external_app_unavailable),
                        style = GlobalToastStyle.Error,
                    ),
                )
            }
        }

        override fun openProviderDetail(providerId: String) = onNavigateToProviderDetail(providerId)

        override fun openProviderSetup() = onNavigateToProviderSetup()

        override fun openVoiceSettings() = onNavigateToVoiceSettings()
    }
    val dictation = rememberDictationHost(
        slotKey = dictationSlotKey,
        actions = dictationActions,
    )
    // Voice conversation of this chat page: its bar replaces the composer and chip row while it runs;
    // the close button writes a half-spoken transcript back at the caret, like dictation.
    val voice = ai.oriveo.community.feature.chat.voice.rememberVoiceConversationHost(
        page = ai.oriveo.community.feature.chat.voice.VoiceConversationPage.Chat,
        requests = viewModel.voice.requests,
        target = viewModel.realtimeVoiceTarget(conversationId),
        gate = viewModel.voice::entryAllowed,
        onDraftTranscript = dictationActions::insert,
    )

    Column(
        modifier = modifier
            .fillMaxWidth()
            .onSizeChanged { onOverlayHeightChange(it.height) },
    ) {
        if (conversationId != null && compactionHintId == conversationId) {
            val quoteLabel = stringResource(R.string.context_compaction_quote_label)
            ThirdCompactionHintBanner(
                onNewChat = { viewModel.compaction?.startNewChatWithSummary(quoteLabel) },
                onDismiss = { viewModel.compaction?.dismissHint() },
            )
        }

        if (compactingHere && conversationId != null) {
            CompactionInProgressRow(onCancel = { viewModel.compaction?.cancelAiCompaction(conversationId) })
        }

        viewModel.expensiveModelHint?.let { hint ->
            ExpensiveModelHintBanner(
                hint = hint,
                onDismiss = { viewModel.dismissExpensiveModelHint() },
            )
        }

        // The conversation's model was removed (relay) or retired: the banner sits right above the composer.
        // When the model is retired and its successor is enabled, the button switches straight to the successor;
        // otherwise it opens the model picker.
        // A deleted conversation connection is handled here too; with no usable connection at all, the button
        // opens add-connection.
        viewModel.conversationState.issue?.takeIf { it.rendersAboveComposer }?.let { issue ->
            val modelDisplayLookup by viewModel.modelDisplayLookup.collectAsStateWithLifecycle()
            val retiredContent = modelRetiredBannerContent(issue, viewModel.conversationState.provider, modelDisplayLookup)
            ConversationIssueBanner(
                issue = issue,
                providerName = activeProvider?.displayName,
                retiredContent = retiredContent,
                onPrimaryAction = {
                    retiredContent?.switchTarget?.let { target ->
                        viewModel.selectModel(target.providerId, target.modelId)
                    } ?: run {
                        if (issue.canRepairFromModelPicker) viewModel.showModelSwitcher = true else onNavigateToProviderSetup()
                    }
                },
            )
        }

        // Dictation status card sits right above the composer; takes no space without a card.
        DictationPromptSlot(
            handle = dictation,
            modifier = Modifier
                .padding(horizontal = OriveoTheme.spacing.lg)
                .padding(bottom = OriveoTheme.spacing.xs),
        )

        ai.oriveo.community.feature.chat.voice.VoiceConversationSwitcher(
            handle = voice,
            barModifier = Modifier
                .padding(horizontal = OriveoTheme.spacing.lg)
                .navigationBarsPadding()
                .padding(top = OriveoTheme.spacing.xs, bottom = OriveoTheme.spacing.sm),
        ) {
        EnhancedComposer(
            inputTextProvider = inputTextProvider,
            hasComposerText = hasComposerText,
            onInputChange = {
                composerText.value = it
                viewModel.onInputTextChanged(it)
            },
            onComposerFocused = { viewModel.compaction?.launchPrecompact() },
            pendingAttachments = viewModel.pendingAttachments,
            restoredImageStates = viewModel.restoredImageStates,
            pendingQuoteContext = viewModel.pendingQuoteContext,
            onRemoveQuote = viewModel::removePendingQuote,
            onAttachmentRemove = viewModel::removeAttachment,
            currentModel = viewModel.conversationState.model,
            generationParameterProvider = activeProvider,
            generationParameterConversationId = conversationId ?: viewModel.generationParameterDraftSessionId,
            isExistingConversation = conversationId != null,
            conversationSkillId = conversationSkillId,
            modelControlsFinalTransport = viewModel.modelControlsFinalTransport(),
            attachmentEntry = viewModel.attachmentEntryModel(imageCapabilityIdentity),
            outboundHistoryHasVideo = outboundHistoryHasVideo,
            onSelectReasoningMode = viewModel::selectReasoningMode,
            onSelectModel = viewModel::selectModel,
            onOpenModelSwitcher = { viewModel.showModelSwitcher = true },
            mcpEntryVisible = viewModel.mcpCoordinator.isToolsChipVisible,
            mcpToolsAvailable = mcpPanelState.availability.isAvailable,
            mcpEnabledServerCount = mcpPanelState.enabledServerCount,
            onOpenMcpTools = viewModel.mcpCoordinator::openToolPanel,
            showAttachmentSizeLimitDialog = viewModel.showAttachmentSizeLimitDialog,
            onDismissAttachmentSizeLimitDialog = viewModel::dismissAttachmentSizeLimitDialog,
            onProcessImageUri = { uri -> viewModel.processImageUri(context, uri) },
            onProcessFileUri = { uri -> viewModel.processFileUri(context, uri) },
            onSendClick = viewModel::sendMessage,
            // Stop while waiting for the confirmation = cancel (rolled back, no stop recorded).
            onStopGeneration = {
                if (viewModel.compaction?.stopWaitingConfirmHere() != true) viewModel.stopGeneration()
            },
            providerKind = activeProvider?.kind,
            onNavigateToProviderSetup = onNavigateToProviderSetup,
            onNavigateToProviderDetail = onNavigateToProviderDetail,
            onNavigateToWebSearchFromChat = onNavigateToWebSearchFromChat,
            onNavigateToConnectionWebSearch = onNavigateToConnectionWebSearch,
            onNavigateToRelayModelAdvanced = onNavigateToRelayModelAdvanced,
            onNavigateToSkillEdit = onNavigateToSkillEdit,
            // The stop button also works while a send's compaction runs (it cancels the whole send).
            isGenerating = isGenerating,
            // Loading states (skeleton, backfilling) and stalled all block writing: allowing a send
            // while stalled means the user starts talking in a conversation that has history, and
            // the context is silently dropped. It becomes writable again once the backfill lands.
            isReadOnly = isReadOnly,
            // When the conversation's model was removed the composer stays editable and only sending is blocked.
            isSendBlocked = !viewModel.canSendMessages,
            // Not remembered: the metadata catalog (imageGen route) can land after the first frame.
            voiceConversationAvailable = ComposerVoiceEntry.voiceAvailable(viewModel.conversationState.model, activeProvider?.kind),
            onStartVoiceConversation = onStartVoiceConversation,
            transparentChrome = transparentChrome,
            hazeState = hazeState,
            trueTransparentBlurEnabled = trueTransparentBlurEnabled,
            attachedNotes = attachedNotes,
            relatedNotes = relatedNotes,
            onAttachNote = viewModel.noteCoordinator::attachNoteToContext,
            onDismissRelatedNote = viewModel.noteCoordinator::dismissRelatedNote,
            onDetachNote = viewModel.noteCoordinator::detachNoteFromContext,
            onPreviewNote = viewModel.noteCoordinator::showNotePreview,
            // Drafts have no conversation id and show no ring.
            contextUsage = contextUsage.takeIf { conversationId != null },
            onOpenContextUsage = onOpenContextUsage,
            dictation = dictation,
            selectionProbe = selectionProbe,
        )
        }
    }
}

/** "Condensing context…" with a cancel button above the composer. */
@Composable
private fun CompactionInProgressRow(onCancel: () -> Unit) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.primarySoft)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.xs),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Text(
            text = stringResource(R.string.context_compaction_in_progress),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onCancel) {
            Text(stringResource(R.string.context_compaction_cancel))
        }
    }
}

/** Hint bar: "new chat" carries the summary along, "got it" dismisses. */
@Composable
internal fun ThirdCompactionHintBanner(onNewChat: () -> Unit, onDismiss: () -> Unit) {
    val colors = OriveoTheme.colors
    // iOS parity: rounded card inset from the edges, leading compress icon.
    ai.oriveo.community.ui.component.OriveoCard(
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.xs),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = OriveoTheme.spacing.md,
            end = OriveoTheme.spacing.sm,
            top = OriveoTheme.spacing.sm,
        ),
    ) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.Top) {
            androidx.compose.material3.Icon(
                imageVector = Icons.Outlined.Compress,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier
                    .padding(top = 2.dp, end = OriveoTheme.spacing.sm)
                    .size(18.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.context_compaction_third_hint),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm, androidx.compose.ui.Alignment.End),
                ) {
                    TextButton(onClick = onDismiss) {
                        Text(stringResource(R.string.context_compaction_third_hint_dismiss), color = colors.textSecondary)
                    }
                    TextButton(onClick = onNewChat) {
                        Text(stringResource(R.string.context_compaction_third_hint_new_chat), color = colors.primary)
                    }
                }
            }
        }
    }
}
