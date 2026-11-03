package ai.oriveo.community.feature.home.homescreen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import ai.oriveo.community.ui.util.userContentTextStyle
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CropSquare
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.runtime.Composable
import ai.oriveo.community.feature.chat.voice.voiceEntryAnchor
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ConnectionAvatar
import ai.oriveo.community.feature.chat.composer.ComposerDictationGlowSlot
import ai.oriveo.community.feature.chat.composer.DictationHostCoordinator
import ai.oriveo.community.feature.chat.composer.DictationInputRow
import ai.oriveo.community.feature.chat.composer.DictationInputSwitcher
import ai.oriveo.community.feature.home.AuroraGreeting
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.feature.home.auroraGlassCard
import ai.oriveo.community.feature.home.homeHeroPillModelName
import ai.oriveo.community.ui.component.ComposerSelectionProbe
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.rememberComposerLengthLimitedField
import kotlinx.coroutines.delay

/** Hero card corner radius / model pill max width / send button diameter (iOS auroraComposerCard / modelSelectorPill / auroraSendButton) */
internal val HOME_HERO_CORNER_RADIUS = 26.dp
internal val HOME_HERO_PILL_MAX_WIDTH = 230.dp
internal val HOME_HERO_SEND_SIZE = 44.dp

/**
 * Aurora composer card (matches iOS auroraComposerCard).
 *
 * - Idle is pure flat (card face + 1dp stroke + two soft glows); the aurora ring lights up only on focus (see [auroraGlassCard]); no middle divider.
 * - Input area: 18sp Medium, up to 5 lines; when unfocused and empty, a decorative placeholder + blinking cursor overlays it; minimum height 48.
 * - Control row: left model pill (tonal, no stroke; logo + model name + provider name), right 44dp solid purple send key ↑; when the draft is empty the ≋ secondary button sits just to its left (same as iOS); no attachments, no microphone.
 * - The draft box is a 1dp stroke with padding 18/18/14 (border-box); content sits 1dp further in from the outer edge on each side: 19 / 19 / 15.
 * - Dictation (P1-U3B): while recording / transcribing the card keeps only the input (live text) and
 *   [DictationInputSwitcher] puts the recording bar (with its own ↑) 8 dp below, outside the card (iOS
 *   DictationInputRow); this composable does not collect the controller state.
 */
@Composable
internal fun NewChatBar(
    activeModel: HomeViewModel.ActiveModel?,
    hasProvider: Boolean,
    isDark: Boolean,
    heroText: String,
    onHeroTextChange: (String) -> Unit,
    isSendingFromHero: Boolean,
    isSearchActive: Boolean,
    onSend: () -> Unit,
    onModelSelect: () -> Unit,
    onAddProvider: () -> Unit,
    /**
     * Dictation handle from rememberDictationHost. The home hero has no mic any more, but the handle stays:
     * the draft:home slot is shared with the chat composer before a conversation exists and its saved recordings
     * live for 7 days, so the recording bar / prompt card must still surface them here. null keeps the normal input.
     */
    dictation: DictationHostCoordinator? = null,
    /** Selection probe of the hero field, so dictated text lands at the caret. */
    selectionProbe: ComposerSelectionProbe? = null,
    /** Availability of the recording bar's send action; null falls back to the send button's own gate. */
    canSendDictation: (() -> Boolean)? = null,
    /** Waveform key on an empty hero draft: voice conversation with the pill's model; null keeps the up arrow on an empty draft. */
    onStartVoiceConversation: (() -> Unit)? = null,
    /** Running voice conversation of the home page: its bar replaces the input and the pill row. */
    voice: ai.oriveo.community.feature.chat.voice.VoiceConversationHandle? = null,
    /**
     * The pill selected a realtime voice model (S4b): the voice dock replaces the card, its orb runs
     * [onStartVoiceConversation]; the keyboard switches to typing, where the ≋ slot returns to the dock.
     */
    realtimeSelected: Boolean = false,
    /** The realtime selection waits for the voice catalog (PM1 card A2): the dock shows, its orb does not start yet. */
    realtimePreparing: Boolean = false,
    /** The realtime selection held in the shared store (connection id, model id); null = none. */
    realtimeStoredSelection: Pair<String, String>? = null,
    /** While preparing: the voice catalog failed to load; the dock shows the failure card with "Retry" (PM1 card A2c). */
    realtimeCatalogFailed: Boolean = false,
    realtimeCatalogRetrying: Boolean = false,
    onRetryCatalog: () -> Unit = {},
    /** Moves the caret to the end of the initial [heroText] once (debug shots start on a typed "/we"); off by default. */
    initialHeroCaretAtEnd: Boolean = false,
) {
    // Same as iOS: ≋ is shown even when no model is available yet; on entry, voiceEntryAllowed decides; models that can only generate images do not get ≋
    val actions = ai.oriveo.community.feature.chat.composer.ComposerVoiceEntry.home(
        isSending = isSendingFromHero,
        hasContent = heroText.isNotBlank(),
        voiceAvailable = activeModel == null ||
            ai.oriveo.community.feature.chat.composer.ComposerVoiceEntry.voiceAvailable(activeModel.model, activeModel.provider.kind),
    )
    val showsVoice = onStartVoiceConversation != null && actions.showsVoice
    // Typing with a realtime model: per pill model, not saved (same as the chat composer).
    // Keyed on the stored selection: the catalog arriving swaps activeModel but must not pop typing back to the dock.
    var realtimeTyping by remember(realtimeStoredSelection) { mutableStateOf(false) }
    // Preparing before the connection list arrives: the pill names the stored model instead of "Add provider".
    val preparingModelId = if (realtimePreparing && activeModel == null) realtimeStoredSelection?.second else null
    val backToStage = ai.oriveo.community.feature.chat.composer.ComposerVoiceEntry.backToStage(realtimeSelected)
    val focusRequester = remember { FocusRequester() }
    var isFocused by remember { mutableStateOf(false) }

    // During a voice conversation the stage as a whole replaces this card (stage layout rule 1: the home panel sits in the original input-card position).
    val heroCard: @Composable () -> Unit = {
        // Like iOS DictationInputRow: the glass card wraps only the input (plus the pill / send row when idle);
        // while recording / transcribing the text field stays in the card (live dictation lands in it) and the
        // recording bar / busy row (with its own ↑) is a row of its own 8 dp below, outside the card.
        Box(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            DictationInputSwitcher(
                handle = dictation,
                canSend = canSendDictation ?: { !isSendingFromHero },
                modifier = Modifier.fillMaxWidth(),
                spacing = 8.dp,
                input = { dictationRow ->
                    // While dictation records, a slowly rotating shimmer edge wraps the card's outer edge (same as the chat-page composer; the corner radius is the card's own 26)
                    Box(modifier = Modifier.fillMaxWidth()) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .auroraGlassCard(isDark = isDark, cornerRadius = HOME_HERO_CORNER_RADIUS, focused = isFocused)
                                .padding(start = 19.dp, end = 19.dp, top = 19.dp, bottom = 15.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            HeroComposerInput(
                                text = heroText,
                                onTextChange = onHeroTextChange,
                                isFocused = isFocused,
                                onFocusChange = { isFocused = it },
                                focusRequester = focusRequester,
                                isSearchActive = isSearchActive,
                                selectionProbe = selectionProbe,
                                listening = dictationRow is DictationInputRow.Recording,
                                initialCaretAtEnd = initialHeroCaretAtEnd,
                            )
                            if (dictationRow == DictationInputRow.Normal) {
                                Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {

                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                    ) {
                                        // The pill narrows to its content, max width 230; fill=false makes it take only the width it needs so the send key always stays at the right
                                        Box(modifier = Modifier.weight(1f, fill = false).padding(end = 10.dp)) {
                                            ModelSelectorPill(
                                                activeModel = activeModel,
                                                hasProvider = hasProvider,
                                                onModelSelect = onModelSelect,
                                                onAddProvider = onAddProvider,
                                                realtime = realtimeSelected,
                                                preparingModelId = preparingModelId,
                                            )
                                        }
                                        // The ≋ secondary button sits just left of ↑ (same as the iOS home); the home screen no longer has a dictation microphone
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            // Show/hide fade 180ms, same as iOS opacity 0.18s
                                            AnimatedVisibility(
                                                visible = showsVoice && onStartVoiceConversation != null,
                                                enter = fadeIn(tween(HERO_VOICE_FADE_MS)),
                                                exit = fadeOut(tween(HERO_VOICE_FADE_MS)),
                                            ) {
                                                Row(verticalAlignment = Alignment.CenterVertically) {
                                                    if (backToStage) {
                                                        HeroBackToStageButton(
                                                            onClick = {
                                                                // A typed session sends the request only when it is running (the host's same connection re-opens capture); otherwise it returns only to the idle stage.
                                                                ai.oriveo.community.feature.chat.voice.backToVoiceStage(
                                                                    typedSessionRunning = voice?.typedSessionRunning == true,
                                                                    leaveTyping = { realtimeTyping = false },
                                                                    request = { onStartVoiceConversation?.invoke() },
                                                                )
                                                            },
                                                        )
                                                    } else {
                                                        HeroVoiceButton(onClick = { onStartVoiceConversation?.invoke() })
                                                    }
                                                    Spacer(modifier = Modifier.width(10.dp))
                                                }
                                            }
                                            // ↑ always goes through onSend: with no provider, sendFromHero falls back to Free, and only if that still fails does it go to add a provider (same as iOS)
                                            AuroraSendButton(
                                                enabled = actions.sendEnabled,
                                                onClick = onSend,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        ComposerDictationGlowSlot(
                            handle = dictation,
                            cornerRadius = HOME_HERO_CORNER_RADIUS,
                            modifier = Modifier.matchParentSize(),
                        ) {}
                    }
                },
            ) {}
        }
    }
    // The realtime dock and its running stage carry the same model pill on top (same tap, same
    // picker); switching models mid-session goes through the same path.
    val voicePill: @Composable () -> Unit = {
        ModelSelectorPill(
            activeModel = activeModel,
            hasProvider = hasProvider,
            onModelSelect = onModelSelect,
            onAddProvider = onAddProvider,
            realtime = realtimeSelected,
            preparingModelId = preparingModelId,
        )
    }
    val idle: @Composable () -> Unit = {
        if (realtimeSelected && !realtimeTyping) {
            ai.oriveo.community.feature.chat.voice.RealtimeVoiceDock(
                onStart = { onStartVoiceConversation?.invoke() },
                onKeyboard = { realtimeTyping = true },
                navigationBarInset = false,
                header = voicePill,
                preparing = realtimePreparing,
                catalogFailed = realtimeCatalogFailed,
                catalogRetrying = realtimeCatalogRetrying,
                onRetryCatalog = onRetryCatalog,
            )
        } else {
            heroCard()
        }
    }
    if (voice == null) {
        idle()
    } else {
        // Voice conversation: the stage takes the whole card's place.
        ai.oriveo.community.feature.chat.voice.VoiceConversationSwitcher(
            handle = voice,
            modifier = Modifier.fillMaxWidth(),
            stageHeader = if (realtimeSelected) voicePill else null,
        ) {
            idle()
        }
    }
}

/**
 * Model picker chip: provider brand-colored logo + model name + provider name; stroke-less tonal capsule, height 40 (hit area 44), max width 230.
 * With no provider it degrades to an "Add provider" text entry; with a provider but the active model still resolving it shows a placeholder icon + Select Model.
 * [realtime]: the home-selected model is a realtime voice model; a cyan dot precedes the name, and screen readers announce the "realtime voice" state after the name (same as the top bar).
 */
@Composable
internal fun ModelSelectorPill(
    activeModel: HomeViewModel.ActiveModel?,
    hasProvider: Boolean,
    onModelSelect: () -> Unit,
    onAddProvider: () -> Unit,
    realtime: Boolean = false,
    /** Realtime model id held in the store while its connection has not loaded yet (PM1 card A2b). */
    preparingModelId: String? = null,
) {
    if (!hasProvider && preparingModelId == null) {
        Box(
            modifier = Modifier
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClick = onAddProvider),
            contentAlignment = Alignment.CenterStart,
        ) {
            Text(
                text = stringResource(R.string.add_provider),
                fontSize = 13.5.sp,
                lineHeight = 17.sp,
                fontWeight = FontWeight.Medium,
                color = AuroraTheme.textSecondary(),
                maxLines = 1,
            )
        }
        return
    }

    val active = activeModel
    val title = when {
        active != null -> homeHeroPillModelName(active.model.name)
        preparingModelId != null -> homeHeroPillModelName(preparingModelId)
        else -> stringResource(R.string.select_model)
    }
    val realtimeState = if (realtime) stringResource(R.string.voice_realtime_model_tag) else null
    Row(
        modifier = Modifier
            .widthIn(max = HOME_HERO_PILL_MAX_WIDTH)
            // 40 high visually; grows with content at larger system font sizes instead of clipping the provider name
            .heightIn(min = 40.dp)
            .clip(CircleShape)
            .background(AuroraTheme.pillFill())
            .testTag("model_picker_button")
            .clickable(role = Role.Button, onClick = onModelSelect)
            .then(if (realtimeState != null) Modifier.semantics { stateDescription = realtimeState } else Modifier)
            .padding(start = 8.dp, end = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (active != null) {
            ConnectionAvatar(
                provider = active.provider,
                fallbackKind = active.provider.kind,
                size = 24.dp,
            )
        } else {
            Box(modifier = Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Outlined.CropSquare,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = AuroraTheme.heroTextTertiary(),
                )
            }
        }
        Spacer(modifier = Modifier.width(9.dp))
        Column(
            modifier = Modifier.weight(1f, fill = false),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (realtime) ai.oriveo.community.feature.chat.components.RealtimeModelDot()
                Text(
                    text = title,
                    fontSize = 14.sp,
                    lineHeight = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AuroraTheme.textPrimary(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (active != null) {
                Text(
                    text = active.provider.displayName,
                    fontSize = 11.sp,
                    lineHeight = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = AuroraTheme.heroTextTertiary(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(modifier = Modifier.width(9.dp))
        // The design uses a 12px Lucide chevrons-up-down box (about 6×10 visible); the slot stays 12
        Icon(
            imageVector = ChevronsUpDownGlyph,
            contentDescription = null,
            modifier = Modifier.size(12.dp),
            tint = AuroraTheme.heroTextTertiary(),
        )
    }
}

/**
 * Hero input: a real BasicTextField, overlaid with a decorative placeholder and blinking cursor while unfocused and
 * empty.
 *
 * IME coupling: on iOS @FocusState is tied to the soft keyboard, so dismissing it clears focus. Compose focus and
 * the IME are separate, so isImeVisible must be observed and focus cleared when the IME hides, otherwise the
 * placeholder never comes back.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HeroComposerInput(
    text: String,
    onTextChange: (String) -> Unit,
    isFocused: Boolean,
    onFocusChange: (Boolean) -> Unit,
    focusRequester: FocusRequester,
    isSearchActive: Boolean,
    selectionProbe: ComposerSelectionProbe? = null,
    /** Dictation is recording into this field: an empty field shows the listening placeholder. */
    listening: Boolean = false,
    /** Puts the caret after the initial text once, as a user edit, so a typed trigger is detected. */
    initialCaretAtEnd: Boolean = false,
) {
    val context = LocalContext.current
    val focusManager = LocalFocusManager.current
    val isImeVisible = WindowInsets.isImeVisible
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }

    LaunchedEffect(isImeVisible) {
        if (!isImeVisible) {
            focusManager.clearFocus(force = false)
        }
    }

    val placeholder = stringResource(AuroraGreeting.placeholderResId)
    // The system cursor matches the decorative one (dark = palette accent / light = fixed purple, see AuroraTheme.accentGlow)
    val cursorColor = AuroraTheme.accentGlow()
    val inputStyle = AuroraTheme.Typography.composerPlaceholder.copy(color = AuroraTheme.textPrimary())
        .merge(userContentTextStyle)
    val placeholderStyle = AuroraTheme.Typography.composerPlaceholder.copy(
        color = AuroraTheme.heroTextTertiary(),
        letterSpacing = (-0.2).sp,
    )
    val showDecoration = !isFocused && text.isEmpty() && !listening
    val listeningPlaceholder = stringResource(R.string.voice_dictation_listening_placeholder)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                onClick = { focusRequester.requestFocus() },
            ),
        contentAlignment = Alignment.CenterStart,
    ) {
        // Same length limit as the chat composer (rules in ComposerLengthLimiter)
        val field = rememberComposerLengthLimitedField(text = text, onTextChange = onTextChange, selectionProbe = selectionProbe)
        if (initialCaretAtEnd) {
            LaunchedEffect(Unit) { field.onValueChange(field.value.copy(selection = TextRange(field.value.text.length))) }
        }
        BasicTextField(
            value = field.value,
            onValueChange = field.onValueChange,
            visualTransformation = field.visualTransformation,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("home_composer_input")
                .focusRequester(focusRequester)
                .onFocusChanged { onFocusChange(it.isFocused) }
                // The placeholder is drawn by the decoration layer below, so the field itself needs an explicit name for TalkBack
                .semantics { contentDescription = placeholder },
            textStyle = inputStyle,
            cursorBrush = SolidColor(cursorColor),
            maxLines = 5,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.Sentences,
                imeAction = ImeAction.Default,
            ),
        )

        if (listening && text.isEmpty()) {
            Text(
                text = listeningPlaceholder,
                style = placeholderStyle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clearAndSetSemantics { },
            )
        }
        if (showDecoration) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    // Purely decorative; otherwise TalkBack reads the placeholder as a second element next to the field
                    .clearAndSetSemantics { },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = placeholder,
                    style = placeholderStyle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (!isSearchActive) {
                    Spacer(modifier = Modifier.width(4.dp))
                    BlinkingCursor(color = cursorColor, reduceMotion = reduceMotion)
                }
            }
        }
    }
}

/**
 * Decorative blinking cursor: a 2×22dp capsule in solid accentGlow; stays on when the system animation scale is 0.
 *
 * It blinks with a hard 550ms toggle rather than a tween: a real text cursor toggles the same way, so it looks
 * right while producing only **one** frame per 550ms. Visibility is read only in graphicsLayer (draw phase), so
 * toggling invalidates draw without recomposing this composable (equivalent to the discrete TimelineView switch
 * of iOS HomeHeroBlinkingCursor).
 */
@Composable
private fun BlinkingCursor(color: Color, reduceMotion: Boolean) {
    val cursorVisible = remember { mutableStateOf(true) }
    LaunchedEffect(reduceMotion) {
        if (reduceMotion) {
            cursorVisible.value = true
            return@LaunchedEffect
        }
        while (true) {
            delay(CURSOR_BLINK_INTERVAL_MS)
            cursorVisible.value = !cursorVisible.value
        }
    }

    Box(
        modifier = Modifier
            .size(width = 2.dp, height = 22.dp)
            .graphicsLayer { alpha = if (reduceMotion || cursorVisible.value) 1f else 0f }
            .background(color, RoundedCornerShape(1.dp)),
    )
}

private const val HERO_VOICE_FADE_MS = 180

/** Waveform secondary button style (matches iOS home): GraphicEq 21dp, accent tint, no fill or stroke, 44dp touch area. */
private object HeroVoiceButtonStyle {
    val glyph: ImageVector get() = Icons.Rounded.GraphicEq
    val glyphSize = 21.dp
    val touchSize = 44.dp

    @Composable
    fun tint(): Color = AuroraTheme.accent()
}

/** Waveform secondary button: sits left of the up arrow on an empty home draft and starts a voice conversation; the voice transition starts and ends here. */
@Composable
private fun HeroVoiceButton(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .voiceEntryAnchor()
            .size(HeroVoiceButtonStyle.touchSize)
            .clip(CircleShape)
            .testTag("home_voice_conversation_button")
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = HeroVoiceButtonStyle.glyph,
            contentDescription = stringResource(R.string.voice_conversation_start_a11y),
            modifier = Modifier.size(HeroVoiceButtonStyle.glyphSize),
            tint = HeroVoiceButtonStyle.tint(),
        )
    }
}

/** "Back to voice stage": the small glow orb in the ≋ slot while typing with a realtime model; tapping it returns to the voice stage (same as ComposerActionCluster BackToStage on the chat page). */
@Composable
private fun HeroBackToStageButton(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .voiceEntryAnchor()
            .size(HeroVoiceButtonStyle.touchSize)
            .clip(CircleShape)
            
            .testTag("home_voice_back_to_stage_button")
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        ai.oriveo.community.feature.chat.voice.RealtimeBackToStageButton()
    }
}

/** Send key: 44dp solid purple circle + white up arrow; no gradient, no shadow, no highlight; always ↑ on the home screen. */
@Composable
private fun AuroraSendButton(
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(HOME_HERO_SEND_SIZE)
            .clip(CircleShape)
            .background(AuroraTheme.sendFill())
            .testTag("home_send_button")
            .clickable(
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        // The design uses a 19px Lucide arrow-up box (13×13 visible, stroke about 1.9)
        Icon(
            imageVector = ArrowUpGlyph,
            contentDescription = stringResource(R.string.send),
            modifier = Modifier.size(19.dp),
            tint = AuroraTheme.sendIcon(),
        )
    }
}

/** Lucide arrow-up on a 24 grid, stroke 2.4 (about 1.9 visible in a 19dp box, matching the design's stroke weight). */
private val ArrowUpGlyph: ImageVector by lazy {
    lucideStrokeIcon("ArrowUp", strokeWidth = 2.4f, "M5 12 L12 5 L19 12", "M12 19 L12 5")
}

/** Lucide chevrons-up-down on a 24 grid, stroke 2.4 (about 6×10 visible in a 12dp box). */
private val ChevronsUpDownGlyph: ImageVector by lazy {
    lucideStrokeIcon("ChevronsUpDown", strokeWidth = 2.4f, "M7 15 L12 20 L17 15", "M7 9 L12 4 L17 9")
}

private fun lucideStrokeIcon(name: String, strokeWidth: Float, vararg paths: String): ImageVector =
    ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply {
        paths.forEach { path ->
            addPath(
                pathData = addPathNodes(path),
                fill = null,
                stroke = SolidColor(Color.Black),
                strokeLineWidth = strokeWidth,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            )
        }
    }.build()

/** Blink interval of the decorative cursor (matches iOS homeHeroCursorBlinkInterval 0.55s). */
private const val CURSOR_BLINK_INTERVAL_MS = 550L

