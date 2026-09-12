package ai.oriveo.community.feature.home.homescreen

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
import androidx.compose.runtime.Composable
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
import ai.oriveo.community.feature.home.AuroraGreeting
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.feature.home.auroraGlassCard
import ai.oriveo.community.feature.home.homeHeroPillModelName
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import kotlinx.coroutines.delay

/** Hero card corner radius / model pill max width / send button diameter (iOS auroraComposerCard / modelSelectorPill / auroraSendButton) */
internal val HOME_HERO_CORNER_RADIUS = 26.dp
internal val HOME_HERO_PILL_MAX_WIDTH = 230.dp
internal val HOME_HERO_SEND_SIZE = 44.dp

/**
 * Aurora composer card (matches iOS auroraComposerCard).
 *
 * - Purely flat while idle (face + 1dp stroke + two glows); the aurora ring lights up only on focus (see
 *   [auroraGlassCard]). No divider in the middle.
 * - Input: 18sp Medium, up to 5 lines; unfocused and empty shows a decorative placeholder with a blinking cursor;
 *   minimum height 48.
 * - Controls row: the model pill on the left (tonal, no stroke; logo + model name + provider name), a 44dp solid
 *   purple send button on the right; no attachment button.
 * - The design is a 1dp stroke plus padding 18/18/14 (border-box), so content sits 1dp further from the outer
 *   edge: 19 / 19 / 15.
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
) {
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
        HeroComposerInput(
            text = heroText,
            onTextChange = onHeroTextChange,
            isFocused = isFocused,
            onFocusChange = { isFocused = it },
            focusRequester = focusRequester,
            isSearchActive = isSearchActive,
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
            AuroraSendButton(
                enabled = !isSendingFromHero,
                onClick = { if (hasProvider) onSend() else onAddProvider() },
            )
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
            ProviderBadgeIcon(
                kind = active.provider.kind,
                size = 24.dp,
                relayKind = active.provider.relayKind,
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
    // The system cursor matches the decorative one (dark #C4B5FD / light #8B5CF6)
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
        BasicTextField(
            value = text,
            onValueChange = onTextChange,
            modifier = Modifier
                .fillMaxWidth()
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

/** Send button: a 44dp solid purple circle with a white up arrow; no gradient, shadow or sheen. */
@Composable
private fun AuroraSendButton(
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(HOME_HERO_SEND_SIZE)
            .clip(CircleShape)
            .background(AuroraTheme.Colors.sendFill)
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
            tint = Color.White,
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

