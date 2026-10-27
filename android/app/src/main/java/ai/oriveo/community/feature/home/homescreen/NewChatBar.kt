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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ConnectionAvatar
import ai.oriveo.community.feature.chat.composer.DictationHostCoordinator
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
 * - Purely flat while idle (face + 1dp stroke + two glows); the aurora ring lights up only on focus (see [auroraGlassCard]). No divider in the middle.
 * - Input: 18sp Medium, up to 5 lines; unfocused and empty shows a decorative placeholder with a blinking cursor; minimum height 48.
 * - Controls row: the model pill on the left (tonal, no stroke; logo + model name + provider name), a 44dp solid purple send button on the right; with an empty draft the waveform secondary button sits right next to it on the left (same as iOS); no attachment button, no microphone.
 * - The design is a 1dp stroke plus padding 18/18/14 (border-box), so content sits 1dp further from the outer edge: 19 / 19 / 15.
 * - Dictation: while recording / transcribing, [DictationInputSwitcher] swaps the input area together with the controls row for a recording bar (with its own up arrow);
 *   this component does not collect controller state.
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
) {
    // Same as iOS: the waveform key is offered even when no model is usable yet (voiceEntryAllowed gates it on entry); models that can only generate images do not get it
    val actions = ai.oriveo.community.feature.chat.composer.ComposerVoiceEntry.home(
        isSending = isSendingFromHero,
        hasContent = heroText.isNotBlank(),
        voiceAvailable = activeModel == null ||
            ai.oriveo.community.feature.chat.composer.ComposerVoiceEntry.voiceAvailable(activeModel.model, activeModel.provider.kind),
    )
    val showsVoice = onStartVoiceConversation != null && actions.showsVoice
    val focusRequester = remember { FocusRequester() }
    var isFocused by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .auroraGlassCard(isDark = isDark, cornerRadius = HOME_HERO_CORNER_RADIUS, focused = isFocused)
            .padding(start = 19.dp, end = 19.dp, top = 19.dp, bottom = 15.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val heroInput: @Composable () -> Unit = {
            // While recording, the input area and the model pill / send key row are replaced together by the recording bar.
            // With a handle, DictationInputSwitcher wraps normal in a Crossfade (Box): both blocks must bring their own Column, otherwise they stack and the bottom bar covers the input
            DictationInputSwitcher(
                handle = dictation,
                canSend = canSendDictation ?: { !isSendingFromHero },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    HeroComposerInput(
                        text = heroText,
                        onTextChange = onHeroTextChange,
                        isFocused = isFocused,
                        onFocusChange = { isFocused = it },
                        focusRequester = focusRequester,
                        isSearchActive = isSearchActive,
                        selectionProbe = selectionProbe,
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        // The pill shrinks to content, 230 at most; fill=false lets it take only the width it needs so the send button always hugs the right
                        Box(modifier = Modifier.weight(1f, fill = false).padding(end = 10.dp)) {
                            ModelSelectorPill(
                                activeModel = activeModel,
                                hasProvider = hasProvider,
                                onModelSelect = onModelSelect,
                                onAddProvider = onAddProvider,
                            )
                        }
                        // The waveform secondary button sits right next to the up arrow on its left (same as iOS home); home no longer has a dictation microphone
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            // Show / hide fades in and out over 180ms, same as iOS opacity 0.18s
                            AnimatedVisibility(
                                visible = showsVoice && onStartVoiceConversation != null,
                                enter = fadeIn(tween(HERO_VOICE_FADE_MS)),
                                exit = fadeOut(tween(HERO_VOICE_FADE_MS)),
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    HeroVoiceButton(onClick = { onStartVoiceConversation?.invoke() })
                                    Spacer(modifier = Modifier.width(10.dp))
                                }
                            }
                            // The up arrow always goes through onSend: with no provider, sendFromHero reports it so the page can start adding one (same as iOS)
                            AuroraSendButton(
                                enabled = actions.sendEnabled,
                                onClick = onSend,
                            )
                        }
                    }
                }
            }
        }
        if (voice == null) {
            heroInput()
        } else {
            // Voice conversation: the bar replaces the input and the pill row together.
            ai.oriveo.community.feature.chat.voice.VoiceConversationSwitcher(handle = voice, modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { heroInput() }
            }
        }
    }
}

/**
 * Model selector chip: the provider's color logo + model name + provider name in a tonal capsule without a stroke,
 * 40 high (44 hit area), 230 at most. Without providers it degrades to an "add a provider" text entry; with
 * providers but the active model still resolving it shows a placeholder icon + Select Model.
 */
@Composable
private fun ModelSelectorPill(
    activeModel: HomeViewModel.ActiveModel?,
    hasProvider: Boolean,
    onModelSelect: () -> Unit,
    onAddProvider: () -> Unit,
) {
    if (!hasProvider) {
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
    val title = if (active != null) homeHeroPillModelName(active.model.name) else stringResource(R.string.select_model)
    Row(
        modifier = Modifier
            .widthIn(max = HOME_HERO_PILL_MAX_WIDTH)
            // 40 high visually; grows with content at larger system font sizes instead of clipping the provider name
            .heightIn(min = 40.dp)
            .clip(CircleShape)
            .background(AuroraTheme.pillFill())
            .testTag("model_picker_button")
            .clickable(role = Role.Button, onClick = onModelSelect)
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
            Text(
                text = title,
                fontSize = 14.sp,
                lineHeight = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraTheme.textPrimary(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
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
    val placeholderStyle = AuroraTheme.Typography.composerPlaceholder.copy(
        color = AuroraTheme.heroTextTertiary(),
        letterSpacing = (-0.2).sp,
    )
    val showDecoration = !isFocused && text.isEmpty()

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
        BasicTextField(
            value = field.value,
            onValueChange = field.onValueChange,
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

/** Send button: a 44dp solid purple circle with a white up arrow; no gradient, shadow or sheen; always an up arrow on home. */
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

