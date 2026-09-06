package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.CropSquare
import androidx.compose.material.icons.outlined.UnfoldMore
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraGreeting
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.auroraGlassCard
import ai.oriveo.community.feature.home.homeHeroPillModelName
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.delay

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
    val accent = AuroraTheme.accent()
    val focusRequester = remember { androidx.compose.ui.focus.FocusRequester() }
    var isFocused by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.layout.screenH)
            .auroraGlassCard(isDark = isDark, cornerRadius = 28.dp, focused = isFocused)
            .padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 12.dp),
    ) {

        HeroComposerInput(
            text = heroText,
            onTextChange = onHeroTextChange,
            isFocused = isFocused,
            onFocusChange = { isFocused = it },
            focusRequester = focusRequester,
            accent = accent,
            isSearchActive = isSearchActive,
        )

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 10.dp, bottom = 12.dp)
                .height(0.6.dp)
                .background(
                    androidx.compose.ui.graphics.Brush.horizontalGradient(
                        listOf(Color.Transparent, AuroraTheme.hairline(), Color.Transparent),
                    ),
                ),
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {

            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp)
                    .testTag("model_picker_button")
                    .clickable(
                        enabled = hasProvider,
                        role = androidx.compose.ui.semantics.Role.Button,
                        onClick = onModelSelect,
                    )
                    .padding(vertical = 6.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                ModelSelectorPillContent(
                    activeModel = activeModel,
                    hasProvider = hasProvider,
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

@Composable
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
private fun ModelSelectorPillContent(
    activeModel: HomeViewModel.ActiveModel?,
    hasProvider: Boolean,
    onAddProvider: () -> Unit,
) {
    BoxWithConstraints(modifier = Modifier.widthIn(max = 250.dp)) {
        val density = LocalDensity.current
        val textMeasurer = rememberTextMeasurer()
        val titleStyle = TextStyle(
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
        )
        val subtitleStyle = TextStyle(
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
        )
        val active = activeModel
        val titleText = when {
            hasProvider && active != null -> homeHeroPillModelName(active.model.name)
            hasProvider -> stringResource(R.string.select_model)
            else -> stringResource(R.string.add_provider)
        }
        val subtitleText = active?.provider?.displayName
        val textMaxWidth = (maxWidth - 24.dp - 18.dp - 18.dp).coerceAtLeast(96.dp)
        val textNaturalWidth = remember(
            titleText,
            subtitleText,
            titleStyle,
            subtitleStyle,
            textMeasurer,
            density,
            textMaxWidth,
        ) {
            val titleWidth = textMeasurer.measure(
                text = titleText,
                style = titleStyle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            ).size.width
            val subtitleWidth = subtitleText?.let {
                textMeasurer.measure(
                    text = it,
                    style = subtitleStyle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                ).size.width
            } ?: 0
            val naturalPx = kotlin.math.max(titleWidth, subtitleWidth).toFloat()
            with(density) {
                naturalPx.toDp()
                    .coerceAtMost(textMaxWidth)
                    .coerceAtLeast(36.dp)
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            if (hasProvider && active != null) {
                ProviderBadgeIcon(
                    kind = active.provider.kind,
                    size = 24.dp,
                    relayKind = active.provider.relayKind,
                )
                Column(
                    modifier = Modifier.width(textNaturalWidth),
                    verticalArrangement = Arrangement.spacedBy(1.dp),
                ) {
                    Text(
                        text = titleText,
                        style = titleStyle,
                        color = AuroraTheme.textPrimary(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = active.provider.displayName,
                        style = subtitleStyle,
                        color = AuroraTheme.textTertiary(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                ModelSelectorChevron()
            } else if (hasProvider) {
                ModelSelectorPlaceholderIcon()
                Text(
                    text = titleText,
                    style = titleStyle,
                    color = AuroraTheme.textPrimary(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.width(textNaturalWidth),
                )
                ModelSelectorChevron()
            } else {
                Text(
                    text = titleText,
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.Medium,
                    color = AuroraTheme.textSecondary(),
                    maxLines = 1,
                    modifier = Modifier.clickable(onClick = onAddProvider),
                )
            }
        }
    }
}

@Composable
private fun ModelSelectorPlaceholderIcon() {
    Box(
        modifier = Modifier.size(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Outlined.CropSquare,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = AuroraTheme.textTertiary(),
        )
    }
}

@Composable
private fun ModelSelectorChevron() {
    Icon(
        imageVector = Icons.Outlined.UnfoldMore,
        contentDescription = null,
        modifier = Modifier.size(12.dp),
        tint = AuroraTheme.textTertiary(),
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HeroComposerInput(
    text: String,
    onTextChange: (String) -> Unit,
    isFocused: Boolean,
    onFocusChange: (Boolean) -> Unit,
    focusRequester: androidx.compose.ui.focus.FocusRequester,
    accent: Color,
    isSearchActive: Boolean,
) {
    val context = LocalContext.current
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val isImeVisible = WindowInsets.isImeVisible

    LaunchedEffect(isImeVisible) {
        if (!isImeVisible) {
            focusManager.clearFocus(force = false)
        }
    }

    val placeholder = stringResource(AuroraGreeting.placeholderResId)
    val placeholderStyle = AuroraTheme.Typography.composerPlaceholder.copy(
        color = AuroraTheme.textTertiary(),
    )
    val inputStyle = AuroraTheme.Typography.composerPlaceholder.copy(
        color = AuroraTheme.textPrimary(),
    )

    val showDecoration = !isFocused && text.isEmpty()

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightInMin(44.dp)
            .clickable(
                indication = null,
                interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
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
                .onFocusChanged { onFocusChange(it.isFocused) },
            textStyle = inputStyle,
            cursorBrush = SolidColor(accent),
            maxLines = 5,
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Sentences,
                imeAction = androidx.compose.ui.text.input.ImeAction.Default,
            ),
        )

        if (showDecoration) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = placeholder,
                    style = placeholderStyle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!isSearchActive) {
                    Spacer(modifier = Modifier.width(4.dp))
                    BlinkingCursor(
                        accent = accent,
                        reduceMotion = isReduceMotionEnabled(context),
                    )
                }
            }
        }
    }
}

@Composable
private fun BlinkingCursor(accent: Color, reduceMotion: Boolean) {

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
            .shadow(
                elevation = 4.dp,
                shape = androidx.compose.ui.graphics.RectangleShape,
                ambientColor = accent.copy(alpha = 0.55f),
                spotColor = accent.copy(alpha = 0.55f),
                clip = false,
            )
            .background(accent),
    )
}

private fun isReduceMotionEnabled(context: android.content.Context): Boolean {
    return try {
        android.provider.Settings.Global.getFloat(
            context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    } catch (_: Exception) {
        false
    }
}

@Composable
private fun AuroraSendButton(
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(48.dp)
            .clickable(
                enabled = enabled,
                role = androidx.compose.ui.semantics.Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .shadow(
                    elevation = 6.dp,
                    shape = CircleShape,
                    ambientColor = OriveoTheme.colors.shadow,
                    spotColor = OriveoTheme.colors.shadow,
                    clip = false,
                )
                .clip(CircleShape)
                .background(OriveoGradients.primary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(
                        androidx.compose.ui.graphics.Brush.verticalGradient(
                            listOf(Color.White.copy(alpha = 0.28f), Color.Transparent),
                        ),
                        CircleShape,
                    ),
            )
            Icon(
                imageVector = Icons.Outlined.ArrowUpward,
                contentDescription = stringResource(R.string.new_chat),
                modifier = Modifier.size(16.dp),

                tint = Color.White,
            )
        }
    }
}

private const val CURSOR_BLINK_INTERVAL_MS = 550L
