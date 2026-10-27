package ai.oriveo.community.feature.settings

import android.text.format.DateFormat
import androidx.annotation.StringRes
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.feature.chat.components.chatAuroraGlowLayers
import ai.oriveo.community.feature.chat.components.formatReasoningDuration
import ai.oriveo.community.ui.component.FlatSectionHeader
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.markdown.MarkdownColors
import ai.oriveo.community.ui.component.markdown.MarkdownTheme
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.Calendar
import org.koin.androidx.compose.koinViewModel

private const val THEME_COLOR_ANIM_MILLIS = 250
private const val PREVIEW_THINKING_MILLIS = 4_000L
private const val PREVIEW_MODEL_NAME = "Claude Opus 5.5"
private const val PREVIEW_COST = "$0.04"
private const val PREVIEW_CODE_LANG = "rust"
private val PREVIEW_MIN_HEIGHT = 352.dp
private val PREVIEW_COMPOSER_HEIGHT = 38.dp

// Mini "other side" bubbles on the light card (the light surface is white on white).
// dark-palette-guard: keep (d) light branch only; dark cards use the palette surface
private val LightMiniBubble = Color(0xFFE5E7EB)

/** Horizontal palette row order: Light, Dark, then the other dark palettes. */
internal val ThemePaletteCardOrder: List<ThemeSwatchSelection> =
    listOf(ThemeSwatchSelection.Light) + DarkPaletteId.entries.map { ThemeSwatchSelection.Palette(it) }

/** Display name of a dark palette; the default palette is shown as "Dark". */
@StringRes
internal fun darkPaletteNameRes(palette: DarkPaletteId): Int = when (palette) {
    DarkPaletteId.Dark -> R.string.theme_dark
    DarkPaletteId.Purple -> R.string.theme_palette_purple
    DarkPaletteId.Graphite -> R.string.theme_palette_graphite
    DarkPaletteId.Black -> R.string.theme_palette_black
    DarkPaletteId.Ocean -> R.string.theme_palette_ocean
    DarkPaletteId.Forest -> R.string.theme_palette_forest
    DarkPaletteId.Sunset -> R.string.theme_palette_sunset
}

internal fun themeSwatchTestTag(selection: ThemeSwatchSelection): String = when (selection) {
    ThemeSwatchSelection.Light -> "theme_swatch_light"
    is ThemeSwatchSelection.Palette -> "theme_swatch_${selection.palette.id}"
}

/**
 * Settings › Theme (Telegram-style): live chat preview, a horizontally scrolling row of palette cards,
 * then the follow-system card. Every tap applies immediately app-wide; there is no save button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThemeSettingsScreen(
    onNavigateBack: () -> Unit = {},
    viewModel: ThemeSettingsViewModel = koinViewModel(),
) {
    val colors = OriveoTheme.colors
    val theme by viewModel.theme.collectAsStateWithLifecycle()
    val darkPalette by viewModel.darkPalette.collectAsStateWithLifecycle()
    val systemDark = isSystemInDarkTheme()

    Box(modifier = Modifier.fillMaxSize().testTag("theme_settings_screen")) {
        OriveoScreenBackground()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.theme),
                            style = OriveoTheme.typography.title3,
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = {
                        OriveoBackButton(
                            onClick = onNavigateBack,
                            modifier = Modifier.testTag("settings_theme_back_button"),
                        )
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->
            ThemeSettingsContent(
                theme = theme,
                darkPalette = darkPalette,
                onAction = { viewModel.onAction(it, systemDark) },
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState()),
            )
        }
    }
}

@Composable
internal fun ThemeSettingsContent(
    theme: ThemeOption,
    darkPalette: String?,
    onAction: (ThemePageAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val follow = theme == ThemeOption.System
    val selection = ThemePageRules.selection(theme, darkPalette)
    val sidePadding = OriveoTheme.spacing.lg

    Column(
        modifier = modifier.padding(top = 6.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        ThemePreviewCard(selection = selection, modifier = Modifier.padding(horizontal = sidePadding))

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FlatSectionHeader(
                title = stringResource(R.string.theme_section_palettes),
                modifier = Modifier.padding(horizontal = sidePadding + 4.dp),
            )
            PaletteCardRow(selection = selection, onAction = onAction, sidePadding = sidePadding)
        }

        FollowSystemCard(
            follow = follow,
            onAction = onAction,
            modifier = Modifier.padding(horizontal = sidePadding),
        )
    }
}

@Composable
private fun FollowSystemCard(
    follow: Boolean,
    onAction: (ThemePageAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(colors.surface)
            .padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                text = stringResource(R.string.theme_system),
                style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
            )
            Text(
                text = stringResource(R.string.theme_follow_system_hint),
                style = TextStyle(fontSize = 12.sp, lineHeight = 17.sp),
                color = colors.textTertiary,
            )
        }
        Switch(
            checked = follow,
            onCheckedChange = { onAction(ThemePageAction.ToggleFollow(it)) },
            modifier = Modifier.testTag("theme_follow_system_switch"),
        )
    }
}

@Composable
private fun PaletteCardRow(
    selection: ThemeSwatchSelection,
    onAction: (ThemePageAction) -> Unit,
    sidePadding: androidx.compose.ui.unit.Dp,
) {
    val listState = rememberLazyListState()
    // Bring the selected card into view when it is not fully visible (keep one card peeking before it).
    // Keyed on the selection because the stored preference arrives after the first frame on entry.
    LaunchedEffect(selection) {
        val index = ThemePaletteCardOrder.indexOf(selection)
        val layout = listState.layoutInfo
        val fullyVisible = layout.visibleItemsInfo.any {
            it.index == index && it.offset >= layout.viewportStartOffset &&
                it.offset + it.size <= layout.viewportEndOffset
        }
        if (!fullyVisible) listState.scrollToItem((index - 1).coerceAtLeast(0))
    }
    // Cards are 76 wide with a 4dp ring allowance on each side; 12dp visual gap between cards.
    LazyRow(
        state = listState,
        contentPadding = PaddingValues(horizontal = sidePadding - 4.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.fillMaxWidth().selectableGroup().testTag("theme_palette_row"),
    ) {
        itemsIndexed(ThemePaletteCardOrder, key = { _, item -> themeSwatchTestTag(item) }) { _, item ->
            PaletteCard(
                item = item,
                selected = item == selection,
                onClick = {
                    onAction(
                        when (item) {
                            ThemeSwatchSelection.Light -> ThemePageAction.TapLight
                            is ThemeSwatchSelection.Palette -> ThemePageAction.TapPalette(item.palette)
                        },
                    )
                },
            )
        }
    }
}

/** Colors of one palette card: its own background, mini bubbles, brand gradient and glow. */
private data class PaletteCardColors(
    val background: Color,
    val bubble: Color,
    val stops: List<Color>,
    val primary: Color,
    val glowK: Float,
)

private fun paletteCardColors(item: ThemeSwatchSelection): PaletteCardColors = when (item) {
    ThemeSwatchSelection.Light -> PaletteCardColors(
        background = LightOriveoColors.backgroundBase,
        bubble = LightMiniBubble,
        stops = OriveoGradients.primaryStops(LightOriveoColors, isDark = false),
        primary = LightOriveoColors.primary,
        glowK = LightOriveoColors.glowK,
    )
    is ThemeSwatchSelection.Palette -> item.palette.colors.let { c ->
        PaletteCardColors(
            background = c.backgroundBase,
            bubble = c.surface,
            stops = OriveoGradients.primaryStops(c, isDark = true),
            primary = c.primary,
            glowK = c.glowK,
        )
    }
}

@Composable
private fun PaletteCard(
    item: ThemeSwatchSelection,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val name = when (item) {
        ThemeSwatchSelection.Light -> stringResource(R.string.theme_light)
        is ThemeSwatchSelection.Palette -> stringResource(darkPaletteNameRes(item.palette))
    }
    val card = paletteCardColors(item)
    val cardShape = RoundedCornerShape(16.dp)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .testTag(themeSwatchTestTag(item))
            .width(84.dp)
            .clip(RoundedCornerShape(20.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .clearAndSetSemantics {
                role = Role.Button
                this.selected = selected
                contentDescription = name
            },
    ) {
        // Selected: 2dp gap showing the page background + 2dp ring in the current primary.
        Box(
            modifier = Modifier
                .size(width = 84.dp, height = 112.dp)
                .then(if (selected) Modifier.border(2.dp, colors.primary, RoundedCornerShape(20.dp)) else Modifier)
                .padding(4.dp),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.Bottom),
                modifier = Modifier
                    .fillMaxSize()
                    .clip(cardShape)
                    .background(card.background)
                    .drawBehind {
                        drawRect(
                            brush = Brush.radialGradient(
                                colors = listOf(card.primary.copy(alpha = 0.30f * card.glowK), Color.Transparent),
                                center = Offset(size.width / 2f, size.height * 1.1f),
                                radius = size.height * 0.75f,
                            ),
                        )
                    }
                    .then(if (selected) Modifier else Modifier.border(1.dp, colors.border, cardShape))
                    .padding(horizontal = 8.dp, vertical = 10.dp),
            ) {
                val otherShape = RoundedCornerShape(topStart = 7.dp, topEnd = 7.dp, bottomEnd = 7.dp, bottomStart = 3.dp)
                Box(Modifier.size(width = 40.dp, height = 14.dp).background(card.bubble, otherShape))
                Box(Modifier.size(width = 28.dp, height = 14.dp).background(card.bubble, otherShape))
                Box(
                    Modifier
                        .align(Alignment.End)
                        .size(width = 44.dp, height = 16.dp)
                        .background(
                            Brush.linearGradient(card.stops, start = Offset.Zero, end = Offset.Infinite),
                            RoundedCornerShape(topStart = 8.dp, topEnd = 8.dp, bottomEnd = 3.dp, bottomStart = 8.dp),
                        ),
                )
            }
        }
        BasicText(
            text = name,
            style = TextStyle(
                fontSize = 12.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                color = if (selected) colors.textPrimary else colors.textTertiary,
                textAlign = TextAlign.Center,
            ),
            maxLines = 1,
            softWrap = false,
            // iOS minimumScaleFactor(0.85)
            autoSize = TextAutoSize.StepBased(minFontSize = 10.2.sp, maxFontSize = 12.sp, stepSize = 0.2.sp),
            modifier = Modifier.widthIn(max = 84.dp).padding(top = 4.dp),
        )
    }
}

/** Palette used by the preview card: the light set or the selected dark palette. */
private fun previewColors(selection: ThemeSwatchSelection): Pair<OriveoColors, Boolean> = when (selection) {
    ThemeSwatchSelection.Light -> LightOriveoColors to false
    is ThemeSwatchSelection.Palette -> selection.palette.colors to true
}

/** Markdown tokens of the previewed palette, so the mini code block matches real chat highlighting. */
internal fun previewMarkdownColors(selection: ThemeSwatchSelection): MarkdownColors {
    val (colors, isDark) = previewColors(selection)
    return MarkdownTheme.resolveColors(colors, isDark)
}

@Composable
private fun animatedColor(target: Color, label: String): Color =
    animateColorAsState(target, animationSpec = tween(THEME_COLOR_ANIM_MILLIS), label = label).value

/** Animated colors of the preview card, all derived from the previewed palette's tokens. */
private class PreviewPalette(
    val bg: Color,
    val border: Color,
    val hairline: Color,
    val text: Color,
    val text2: Color,
    val text3: Color,
    val primary: Color,
    val accent: Color,
    val onBubble: Color,
    val stops: List<Color>,
    val inlineCodeText: Color,
    val inlineCodeBg: Color,
    val codeBg: Color,
    val codeHeaderBg: Color,
    val codeText: Color,
    val syntaxKeyword: Color,
    val syntaxType: Color,
    val syntaxString: Color,
    val composer: Color,
)

@Composable
private fun animatedPreviewPalette(
    target: OriveoColors,
    isDark: Boolean,
    markdown: MarkdownColors,
): PreviewPalette {
    val targetStops = OriveoGradients.primaryStops(target, isDark)
    return PreviewPalette(
        bg = animatedColor(target.backgroundBase, "previewBg"),
        border = animatedColor(target.border, "previewBorder"),
        hairline = animatedColor(target.border, "previewHairline"),
        text = animatedColor(target.textPrimary, "previewText"),
        text2 = animatedColor(target.textSecondary, "previewText2"),
        text3 = animatedColor(target.textTertiary, "previewText3"),
        primary = animatedColor(target.primary, "previewPrimary"),
        accent = animatedColor(target.accent, "previewAccent"),
        // Text on the brand gradient: on-primary in dark, white in light.
        // dark-palette-guard: keep (d) light branch keeps white text on the light brand gradient
        onBubble = animatedColor(if (isDark) target.onPrimary else Color.White, "previewOnBubble"),
        stops = listOf(
            animatedColor(targetStops.first(), "previewStopStart"),
            animatedColor(targetStops.last(), "previewStopEnd"),
        ),
        inlineCodeText = animatedColor(markdown.inlineCodeText, "previewInlineCodeText"),
        inlineCodeBg = animatedColor(markdown.inlineCodeBg, "previewInlineCodeBg"),
        codeBg = animatedColor(markdown.codeBlockBg, "previewCodeBg"),
        codeHeaderBg = animatedColor(markdown.codeBlockSurface, "previewCodeHeaderBg"),
        codeText = animatedColor(markdown.codeBlockFg, "previewCodeText"),
        syntaxKeyword = animatedColor(markdown.syntaxKeyword, "previewSyntaxKeyword"),
        syntaxType = animatedColor(markdown.syntaxType, "previewSyntaxType"),
        syntaxString = animatedColor(markdown.syntaxString, "previewSyntaxString"),
        composer = animatedColor(target.surface, "previewComposer"),
    )
}

@Composable
private fun ThemePreviewCard(selection: ThemeSwatchSelection, modifier: Modifier = Modifier) {
    val (target, isDark) = previewColors(selection)
    val p = animatedPreviewPalette(target, isDark, previewMarkdownColors(selection))
    val glowLayers = chatAuroraGlowLayers(target.copy(primary = p.primary, accent = p.accent), isDark)
    val gradient = Brush.linearGradient(p.stops, start = Offset.Zero, end = Offset.Infinite)

    Box(
        modifier = modifier
            .fillMaxWidth()
            // At least 352dp, grows with long locales / large font scale; never clips or scrolls inside.
            .heightIn(min = PREVIEW_MIN_HEIGHT)
            .clip(RoundedCornerShape(24.dp))
            .background(p.bg)
            .drawBehind {
                val maxDim = maxOf(size.width, size.height)
                glowLayers.forEach { layer ->
                    drawRect(
                        brush = Brush.radialGradient(
                            colors = listOf(layer.color, Color.Transparent),
                            center = Offset(size.width * layer.centerX, size.height * layer.centerY),
                            radius = maxDim * layer.radiusFraction,
                        ),
                        blendMode = layer.blendMode,
                    )
                }
            }
            .border(1.dp, p.border, RoundedCornerShape(24.dp))
            // Display only: the readable part (question + reply) is one node; the chrome is decorative.
            .semantics(mergeDescendants = true) {}
            .testTag("theme_preview_card"),
    ) {
        // Composer sits at the bottom of the (at least 352dp) card; extra content makes the card taller instead.
        Column(
            modifier = Modifier.fillMaxWidth().heightIn(min = PREVIEW_MIN_HEIGHT),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(modifier = Modifier.fillMaxWidth()) {
                PreviewTopBar(p, gradient)
                Column(
                    modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(9.dp),
                ) {
                    PreviewUserBubble(p, gradient, modifier = Modifier.align(Alignment.End))
                    PreviewThinkingRow(p)
                    PreviewReply(p)
                    PreviewCodeBlock(p)
                    PreviewCapabilityTags(p)
                }
            }
            PreviewComposer(p, gradient)
        }
    }
}

@Composable
private fun PreviewTopBar(p: PreviewPalette, gradient: Brush) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 46.dp)
            .drawBehind {
                val stroke = 1.dp.toPx()
                drawRect(p.hairline, topLeft = Offset(0f, size.height - stroke), size = size.copy(height = stroke))
            }
            .padding(horizontal = 14.dp)
            .clearAndSetSemantics {},
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowLeft,
            contentDescription = null,
            tint = p.text2,
            modifier = Modifier.size(18.dp),
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterHorizontally),
            modifier = Modifier.weight(1f),
        ) {
            Box(
                Modifier
                    .size(8.dp)
                    .shadow(4.dp, CircleShape, ambientColor = p.primary, spotColor = p.primary)
                    .background(gradient, CircleShape),
            )
            Text(
                text = PREVIEW_MODEL_NAME,
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
                color = p.text,
            )
        }
        Text(
            text = PREVIEW_COST,
            style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace),
            color = p.primary,
        )
    }
}

@Composable
private fun PreviewUserBubble(p: PreviewPalette, gradient: Brush, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    // A fixed moment (21:41 today) formatted with the user's locale and 12/24h setting.
    val time = remember(context) {
        val moment = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 21)
            set(Calendar.MINUTE, 41)
        }
        DateFormat.getTimeFormat(context).format(moment.time)
    }
    val shape = RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomEnd = 6.dp, bottomStart = 18.dp)
    Column(
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = modifier
            .widthIn(max = 220.dp)
            .shadow(
                elevation = 8.dp,
                shape = shape,
                ambientColor = p.primary.copy(alpha = 0.35f),
                spotColor = p.primary.copy(alpha = 0.35f),
            )
            .background(gradient, shape)
            .padding(start = 13.dp, end = 13.dp, top = 9.dp, bottom = 7.dp),
    ) {
        Text(
            text = stringResource(R.string.theme_preview_question),
            style = TextStyle(fontSize = 13.5.sp, fontWeight = FontWeight.Medium, lineHeight = 19.sp),
            color = p.onBubble,
        )
        Text(
            text = time,
            style = TextStyle(fontSize = 10.sp),
            color = p.onBubble.copy(alpha = 0.7f),
            modifier = Modifier.clearAndSetSemantics {},
        )
    }
}

@Composable
private fun PreviewThinkingRow(p: PreviewPalette) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.clearAndSetSemantics {},
    ) {
        Icon(
            imageVector = Icons.Filled.Schedule,
            contentDescription = null,
            tint = p.text3,
            modifier = Modifier.size(11.dp),
        )
        Text(
            text = stringResource(R.string.reasoning_thought_for, formatReasoningDuration(PREVIEW_THINKING_MILLIS)),
            style = TextStyle(fontSize = 11.sp),
            color = p.text3,
        )
    }
}

@Composable
private fun PreviewReply(p: PreviewPalette) {
    val reply = previewReply(
        template = stringResource(R.string.theme_preview_reply, OWNER_MARK, CODE_MARK),
        owner = stringResource(R.string.theme_preview_owner),
        textColor = p.text,
        primary = p.primary,
        codeText = p.inlineCodeText,
        codeBackground = p.inlineCodeBg,
    )
    Text(text = reply, style = TextStyle(fontSize = 13.5.sp, lineHeight = 21.sp), color = p.text)
}

@Composable
private fun PreviewCodeBlock(p: PreviewPalette) {
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(p.codeBg)
            .border(1.dp, p.border, shape)
            .clearAndSetSemantics {},
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .height(24.dp)
                .background(p.codeHeaderBg)
                .padding(horizontal = 10.dp),
        ) {
            Text(
                text = PREVIEW_CODE_LANG,
                style = TextStyle(fontSize = 10.5.sp),
                color = p.text3,
                modifier = Modifier.weight(1f),
            )
            Text(text = stringResource(R.string.copy), style = TextStyle(fontSize = 10.5.sp), color = p.text3)
        }
        // Two plain code lines, not localized: `let s = String::from("hi");` and `let r = &s;`.
        Text(
            text = buildAnnotatedString {
                val plain = SpanStyle(color = p.codeText)
                withStyle(SpanStyle(color = p.syntaxKeyword)) { append("let") }
                withStyle(plain) { append(" s = ") }
                withStyle(SpanStyle(color = p.syntaxType)) { append("String") }
                withStyle(plain) { append("::from(") }
                withStyle(SpanStyle(color = p.syntaxString)) { append("\"hi\"") }
                withStyle(plain) { append(");\n") }
                withStyle(SpanStyle(color = p.syntaxKeyword)) { append("let") }
                withStyle(plain) { append(" r = &s;") }
            },
            style = TextStyle(fontSize = 11.sp, lineHeight = 16.5.sp, fontFamily = FontFamily.Monospace),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
        )
    }
}

@Composable
private fun PreviewCapabilityTags(p: PreviewPalette) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.clearAndSetSemantics {}) {
        PreviewTag(stringResource(R.string.capability_reasoning), p.primary, p.primary.copy(alpha = 0.15f))
        PreviewTag(stringResource(R.string.capability_web), p.accent, p.accent.copy(alpha = 0.14f))
    }
}

@Composable
private fun PreviewTag(text: String, color: Color, background: Color) {
    Text(
        text = text,
        style = TextStyle(fontSize = 10.5.sp, fontWeight = FontWeight.Medium),
        color = color,
        modifier = Modifier
            .background(background, RoundedCornerShape(7.dp))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

@Composable
private fun PreviewComposer(p: PreviewPalette, gradient: Brush) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 10.dp)
            .fillMaxWidth()
            .heightIn(min = PREVIEW_COMPOSER_HEIGHT)
            .background(p.composer, RoundedCornerShape(19.dp))
            .border(1.dp, p.primary.copy(alpha = 0.22f), RoundedCornerShape(19.dp))
            .padding(start = 14.dp, end = 4.dp)
            .clearAndSetSemantics {},
    ) {
        Text(
            text = stringResource(R.string.type_a_message),
            style = TextStyle(fontSize = 12.5.sp),
            color = p.text3,
            modifier = Modifier.weight(1f).padding(vertical = 4.dp),
        )
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(30.dp).background(gradient, CircleShape),
        ) {
            Icon(
                imageVector = Icons.Filled.ArrowUpward,
                contentDescription = null,
                tint = p.onBubble,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

private const val OWNER_MARK = ""
private const val CODE_MARK = ""
private const val PREVIEW_CODE = "&T"

/** Builds the localized reply with the emphasized word (primary, bold) and the inline code (accent, monospace). */
private fun previewReply(
    template: String,
    owner: String,
    textColor: Color,
    primary: Color,
    codeText: Color,
    codeBackground: Color,
): AnnotatedString = buildAnnotatedString {
    var rest = template
    while (rest.isNotEmpty()) {
        val ownerAt = rest.indexOf(OWNER_MARK)
        val codeAt = rest.indexOf(CODE_MARK)
        val next = listOf(ownerAt, codeAt).filter { it >= 0 }.minOrNull()
        if (next == null) {
            withStyle(SpanStyle(color = textColor)) { append(rest) }
            break
        }
        withStyle(SpanStyle(color = textColor)) { append(rest.substring(0, next)) }
        if (next == ownerAt) {
            withStyle(SpanStyle(color = primary, fontWeight = FontWeight.SemiBold)) { append(owner) }
        } else {
            withStyle(
                SpanStyle(
                    color = codeText,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    background = codeBackground,
                ),
            ) { append(PREVIEW_CODE) }
        }
        rest = rest.substring(next + 1)
    }
}
