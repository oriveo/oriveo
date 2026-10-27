package ai.oriveo.community.feature.settings

import android.text.format.DateFormat
import androidx.annotation.StringRes
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
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
import androidx.compose.foundation.systemGestureExclusion
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
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
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
import ai.oriveo.community.ui.component.markdown.SyntaxHighlighter
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoCustomPalette
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoLightBrand
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.OriveoUserBubble
import ai.oriveo.community.ui.theme.UserBubbleStyle
import ai.oriveo.community.ui.theme.UserBubbleViewport
import ai.oriveo.community.ui.theme.userBubbleFill
import ai.oriveo.community.ui.theme.userBubbleViewport
import ai.oriveo.community.ui.theme.lightOriveoColorsOf
import java.util.Calendar
import kotlin.math.roundToInt
import org.koin.androidx.compose.koinViewModel

private const val THEME_COLOR_ANIM_MILLIS = 250
private const val PREVIEW_THINKING_MILLIS = 4_000L
private const val PREVIEW_MODEL_NAME = "Claude Opus 5.5"
private const val PREVIEW_COST = "$0.04"
private const val PREVIEW_CODE_LANG = "rust"
private const val PREVIEW_CODE_SOURCE = "let s = String::from(\"hi\");\nlet r = &s;"
private val PREVIEW_MIN_HEIGHT = 352.dp
private val PREVIEW_COMPOSER_HEIGHT = 38.dp
private const val PRESET_DOTS_PER_ROW = 6
private val PRESET_DOT_SIZE = 32.dp
private val PRESET_DOT_TOUCH = 48.dp
private val HUE_TRACK_HEIGHT = 12.dp
private val HUE_THUMB_SIZE = 26.dp

/** Appearance segments, left to right. */
internal val ThemeAppearanceOrder: List<ThemeOption> = listOf(ThemeOption.Light, ThemeOption.Dark, ThemeOption.System)

/** Palette card order: Default (`dark`), the other presets, then Custom. */
internal val ThemePaletteCardOrder: List<ThemeSwatchSelection> =
    DarkPaletteId.entries.map { ThemeSwatchSelection.Palette(it) } + ThemeSwatchSelection.Custom

/** Display name of a preset palette; `dark` is "Default" because it applies to both appearances. */
@StringRes
internal fun darkPaletteNameRes(palette: DarkPaletteId): Int = when (palette) {
    DarkPaletteId.Dark -> R.string.default_model_short
    DarkPaletteId.Purple -> R.string.theme_palette_purple
    DarkPaletteId.Graphite -> R.string.theme_palette_graphite
    DarkPaletteId.Black -> R.string.theme_palette_black
    DarkPaletteId.Ocean -> R.string.theme_palette_ocean
    DarkPaletteId.Forest -> R.string.theme_palette_forest
    DarkPaletteId.Sunset -> R.string.theme_palette_sunset
}

@StringRes
internal fun themeSwatchNameRes(selection: ThemeSwatchSelection): Int = when (selection) {
    is ThemeSwatchSelection.Palette -> darkPaletteNameRes(selection.palette)
    ThemeSwatchSelection.Custom -> R.string.theme_palette_custom
}

@StringRes
internal fun themeAppearanceNameRes(theme: ThemeOption): Int = when (theme) {
    ThemeOption.Light -> R.string.theme_light
    ThemeOption.Dark -> R.string.theme_dark
    ThemeOption.System -> R.string.theme_system
}

/** "<appearance> · %1$s" summary for non-default palettes. */
@StringRes
internal fun themeSummaryWithPaletteRes(theme: ThemeOption): Int = when (theme) {
    ThemeOption.Light -> R.string.theme_summary_light
    ThemeOption.Dark -> R.string.theme_summary_dark
    ThemeOption.System -> R.string.theme_summary_follow_system
}

/** Accessibility names of `custom.presets`, same order. */
internal val CustomPresetNameRes: List<Int> = listOf(
    R.string.theme_color_coral,
    R.string.theme_color_orange,
    R.string.theme_color_amber,
    R.string.theme_color_lime,
    R.string.theme_color_green,
    R.string.theme_color_teal,
    R.string.theme_color_cyan,
    R.string.theme_color_blue,
    R.string.theme_color_indigo,
    R.string.theme_color_violet,
    R.string.theme_color_pink,
    R.string.theme_color_rose,
)

/** Test tag and Sentry click tag of a palette card (`-` in ids becomes `_`, matching iOS). */
internal fun themeSwatchTestTag(selection: ThemeSwatchSelection): String = when (selection) {
    is ThemeSwatchSelection.Palette -> "theme_swatch_${selection.palette.id.replace('-', '_')}"
    ThemeSwatchSelection.Custom -> "theme_swatch_custom"
}

internal fun themeAppearanceTestTag(theme: ThemeOption): String = "theme_appearance_${theme.name.lowercase()}"

internal fun customPresetTestTag(seed: Int): String =
    "theme_custom_preset_${OriveoCustomPalette.format(seed).removePrefix("#")}"

/** The palette a card stands for; Custom shows the stored seed (or the default seed if never picked). */
private fun ThemeSwatchSelection.choice(customSeed: Int): DarkPaletteChoice = when (this) {
    is ThemeSwatchSelection.Palette -> DarkPaletteChoice.Preset(palette)
    ThemeSwatchSelection.Custom -> DarkPaletteChoice.Custom(customSeed)
}

private fun Int.opaque(): Color = Color(this).copy(alpha = 1f)

private fun Color.hex(): String = OriveoCustomPalette.format(toArgb() and 0xFFFFFF)

/**
 * Settings › Theme: live chat preview, appearance segments, a horizontally scrolling row of palette cards,
 * and the custom color picker when Custom is selected. Every tap applies immediately app-wide; no save button.
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
    val customSeed by viewModel.darkPaletteCustom.collectAsStateWithLifecycle()

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
                customSeed = customSeed,
                onAction = viewModel::onAction,
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
    customSeed: String?,
    onAction: (ThemePageAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val stored = DarkPaletteChoice.resolve(darkPalette, customSeed)
    // Hue drag / just-picked seed: previews on this page only until the stored preference catches up.
    var pendingSeed by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(darkPalette, customSeed) { pendingSeed = null }
    val effective = pendingSeed?.let { DarkPaletteChoice.Custom(it) } ?: stored
    val selection = ThemePageRules.selection(effective)
    val cardSeed = (effective as? DarkPaletteChoice.Custom)?.seed
        ?: OriveoCustomPalette.parseSeed(customSeed)
        ?: OriveoCustomPalette.DEFAULT_SEED
    val sidePadding = OriveoTheme.spacing.lg

    Column(
        modifier = modifier.padding(top = 6.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        ThemePreviewCard(choice = effective, isDark = isDark, modifier = Modifier.padding(horizontal = sidePadding))

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FlatSectionHeader(
                title = stringResource(R.string.theme_section_appearance),
                modifier = Modifier.padding(horizontal = sidePadding + 4.dp),
            )
            AppearanceSegments(theme = theme, onAction = onAction, modifier = Modifier.padding(horizontal = sidePadding))
        }

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FlatSectionHeader(
                title = stringResource(R.string.theme_section_palettes),
                modifier = Modifier.padding(horizontal = sidePadding + 4.dp),
            )
            PaletteCardRow(
                selection = selection,
                customSeed = cardSeed,
                isDark = isDark,
                onAction = onAction,
                sidePadding = sidePadding,
            )
        }

        if (selection == ThemeSwatchSelection.Custom) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                FlatSectionHeader(
                    title = stringResource(R.string.theme_custom_color),
                    modifier = Modifier.padding(horizontal = sidePadding + 4.dp),
                )
                CustomColorSection(
                    seed = cardSeed,
                    isDark = isDark,
                    onPreview = { pendingSeed = it },
                    onCommit = { seed ->
                        pendingSeed = seed
                        onAction(ThemePageAction.PickSeed(seed))
                    },
                    onCancel = { pendingSeed = null },
                    modifier = Modifier.padding(horizontal = sidePadding),
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppearanceSegments(
    theme: ThemeOption,
    onAction: (ThemePageAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    SingleChoiceSegmentedButtonRow(modifier = modifier.fillMaxWidth().testTag("theme_appearance")) {
        ThemeAppearanceOrder.forEachIndexed { index, option ->
            SegmentedButton(
                selected = option == theme,
                onClick = { if (option != theme) onAction(ThemePageAction.SetAppearance(option)) },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = ThemeAppearanceOrder.size),
                icon = {},
                modifier = Modifier
                    .testTag(themeAppearanceTestTag(option)),
                label = {
                    Text(
                        text = stringResource(themeAppearanceNameRes(option)),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
            )
        }
    }
}

@Composable
private fun PaletteCardRow(
    selection: ThemeSwatchSelection,
    customSeed: Int,
    isDark: Boolean,
    onAction: (ThemePageAction) -> Unit,
    sidePadding: Dp,
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
                card = paletteCardColors(item.choice(customSeed), isDark),
                selected = item == selection,
                onClick = {
                    onAction(
                        when (item) {
                            is ThemeSwatchSelection.Palette -> ThemePageAction.TapPalette(item.palette)
                            ThemeSwatchSelection.Custom -> ThemePageAction.TapCustom
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
    /** User-bubble stops, anchored on the card. */
    val stops: List<Color>,
    val primary: Color,
    val glowK: Float,
)

/** A card draws its palette in the current appearance: light = bgTop page + light brand bubbles. */
private fun paletteCardColors(choice: DarkPaletteChoice, isDark: Boolean): PaletteCardColors = if (isDark) {
    choice.colors.let { c ->
        PaletteCardColors(
            background = c.backgroundBase,
            bubble = c.surface,
            stops = OriveoUserBubble.stops(choice, isDark = true),
            primary = c.primary,
            glowK = c.glowK,
        )
    }
} else {
    choice.lightBrand.let { b ->
        PaletteCardColors(
            background = b.bgTop,
            bubble = b.soft,
            stops = OriveoUserBubble.stops(choice, isDark = false),
            primary = b.ink,
            glowK = LightOriveoColors.glowK,
        )
    }
}

@Composable
private fun PaletteCard(
    item: ThemeSwatchSelection,
    card: PaletteCardColors,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val name = stringResource(themeSwatchNameRes(item))
    val tag = themeSwatchTestTag(item)
    val cardShape = RoundedCornerShape(16.dp)
    // The user-bubble strip takes its slice of a gradient anchored on the card.
    val bubbleViewport = remember { UserBubbleViewport() }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .testTag(tag)
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
                    .userBubbleViewport(bubbleViewport)
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
                        .userBubbleFill(
                            style = UserBubbleStyle(card.stops, isDark = OriveoTheme.isDark),
                            shape = RoundedCornerShape(topStart = 8.dp, topEnd = 8.dp, bottomEnd = 3.dp, bottomStart = 8.dp),
                            viewport = bubbleViewport,
                            decorated = false,
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

/** Custom color picker: 12 preset dots, a hue bar, primary / accent readout and the adjusted notice. */
@Composable
private fun CustomColorSection(
    seed: Int,
    isDark: Boolean,
    onPreview: (Int) -> Unit,
    onCommit: (Int) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = modifier.fillMaxWidth().testTag("theme_custom_section"),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        PresetDots(seed = seed, onPick = onCommit)
        Text(
            text = stringResource(R.string.theme_custom_hue),
            style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
            color = colors.textSecondary,
        )
        HueSlider(seed = seed, onPreview = onPreview, onCommit = onCommit, onCancel = onCancel)
        ColorReadout(choice = DarkPaletteChoice.Custom(seed), isDark = isDark)
        val adjusted = OriveoCustomPalette.derive(seed).adjusted
        if (adjusted != null) {
            Text(
                text = stringResource(
                    when (adjusted) {
                        OriveoCustomPalette.Adjusted.Lightened -> R.string.theme_custom_lightened
                        OriveoCustomPalette.Adjusted.Darkened -> R.string.theme_custom_darkened
                    },
                ),
                style = TextStyle(fontSize = 12.sp, lineHeight = 17.sp),
                color = colors.textTertiary,
                modifier = Modifier.testTag("theme_custom_adjusted"),
            )
        }
    }
}

@Composable
private fun PresetDots(seed: Int, onPick: (Int) -> Unit) {
    val colors = OriveoTheme.colors
    Column(
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.fillMaxWidth().selectableGroup(),
    ) {
        OriveoCustomPalette.presets.withIndex().chunked(PRESET_DOTS_PER_ROW).forEach { row ->
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                row.forEach { (index, preset) ->
                    val selected = preset == seed
                    val name = stringResource(CustomPresetNameRes[index])
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(PRESET_DOT_TOUCH)
                            .testTag(customPresetTestTag(preset))
                            .clip(CircleShape)
                            .clickable(role = Role.Button) { onPick(preset) }
                            .clearAndSetSemantics {
                                role = Role.Button
                                this.selected = selected
                                contentDescription = name
                            },
                    ) {
                        // Selected: 2dp gap + 2dp ring around the 32dp dot.
                        Box(
                            modifier = Modifier
                                .size(PRESET_DOT_SIZE + 8.dp)
                                .then(if (selected) Modifier.border(2.dp, colors.textPrimary, CircleShape) else Modifier)
                                .padding(4.dp)
                                .background(preset.opaque(), CircleShape),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun HueSlider(
    seed: Int,
    onPreview: (Int) -> Unit,
    onCommit: (Int) -> Unit,
    onCancel: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val label = stringResource(R.string.theme_custom_hue)
    val trackStops = remember {
        (0..12).map { OriveoCustomPalette.hueSliderSeed((it * 30).coerceAtMost(OriveoCustomPalette.HUE_SLIDER_MAX)).opaque() }
    }
    var dragHue by remember { mutableStateOf<Int?>(null) }
    val seedHue = remember(seed) {
        OriveoCustomPalette.oklch(seed)[2].roundToInt().mod(360)
            .coerceIn(OriveoCustomPalette.HUE_SLIDER_MIN, OriveoCustomPalette.HUE_SLIDER_MAX)
    }
    val hue = dragHue ?: seedHue
    val preview by rememberUpdatedState(onPreview)
    val commit by rememberUpdatedState(onCommit)
    val cancel by rememberUpdatedState(onCancel)
    val range = OriveoCustomPalette.HUE_SLIDER_MIN.toFloat()..OriveoCustomPalette.HUE_SLIDER_MAX.toFloat()

    BoxWithConstraints(
        contentAlignment = Alignment.CenterStart,
        modifier = Modifier
            .fillMaxWidth()
            .height(PRESET_DOT_TOUCH)
            .testTag("theme_hue_slider")
            // Keep the system back gesture off the bar; the drag below consumes every move so the
            // palette row / page scroll never steal it.
            .systemGestureExclusion()
            .pointerInput(Unit) {
                awaitEachGesture {
                    fun hueAt(x: Float): Int = (x / size.width * OriveoCustomPalette.HUE_SLIDER_MAX).roundToInt()
                        .coerceIn(OriveoCustomPalette.HUE_SLIDER_MIN, OriveoCustomPalette.HUE_SLIDER_MAX)
                    val down = awaitFirstDown()
                    down.consume()
                    var current = hueAt(down.position.x)
                    dragHue = current
                    preview(OriveoCustomPalette.hueSliderSeed(current))
                    val released = drag(down.id) { change ->
                        change.consume()
                        current = hueAt(change.position.x)
                        dragHue = current
                        preview(OriveoCustomPalette.hueSliderSeed(current))
                    }
                    dragHue = null
                    // Only the release writes the preference (and syncs); a cancelled drag reverts the preview.
                    if (released) commit(OriveoCustomPalette.hueSliderSeed(current)) else cancel()
                }
            }
            .semantics {
                contentDescription = label
                progressBarRangeInfo = ProgressBarRangeInfo(hue.toFloat(), range)
                setProgress { value ->
                    val target = value.roundToInt().coerceIn(range.start.toInt(), range.endInclusive.toInt())
                    commit(OriveoCustomPalette.hueSliderSeed(target))
                    true
                }
            },
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(HUE_TRACK_HEIGHT)
                .clip(CircleShape)
                .background(Brush.horizontalGradient(trackStops)),
        )
        val travel = maxWidth - HUE_THUMB_SIZE
        Box(
            Modifier
                .offset(x = travel * (hue.toFloat() / OriveoCustomPalette.HUE_SLIDER_MAX))
                .size(HUE_THUMB_SIZE)
                .shadow(3.dp, CircleShape)
                .background(colors.textPrimary, CircleShape)
                .padding(3.dp)
                .background(OriveoCustomPalette.hueSliderSeed(hue).opaque(), CircleShape),
        )
    }
}

/** Primary / accent swatches with hex, in the current appearance (light shows the light brand ink / accent). */
@Composable
private fun ColorReadout(choice: DarkPaletteChoice, isDark: Boolean) {
    val primary = if (isDark) choice.colors.primary else choice.lightBrand.ink
    val accent = if (isDark) choice.colors.accent else choice.lightBrand.accent
    Row(horizontalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.fillMaxWidth()) {
        ColorChip(label = stringResource(R.string.theme_custom_primary), color = primary, tag = "theme_custom_primary")
        ColorChip(label = stringResource(R.string.theme_custom_accent), color = accent, tag = "theme_custom_accent")
    }
}

@Composable
private fun ColorChip(label: String, color: Color, tag: String) {
    val colors = OriveoTheme.colors
    val hex = color.hex()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.testTag(tag).semantics(mergeDescendants = true) {},
    ) {
        Box(
            Modifier
                .size(22.dp)
                .background(color, RoundedCornerShape(6.dp))
                .border(1.dp, colors.border, RoundedCornerShape(6.dp)),
        )
        Column {
            Text(text = label, style = TextStyle(fontSize = 12.sp), color = colors.textTertiary)
            Text(
                text = hex,
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Monospace),
                color = colors.textPrimary,
            )
        }
    }
}

/** Token set the preview draws with: the palette's dark set, or the light set with its light brand. */
private fun previewColors(choice: DarkPaletteChoice, isDark: Boolean): OriveoColors =
    if (isDark) choice.colors else lightOriveoColorsOf(choice.lightBrand)

/** Markdown tokens of the previewed palette, so the mini code block matches real chat highlighting. */
internal fun previewMarkdownColors(choice: DarkPaletteChoice, isDark: Boolean): MarkdownColors =
    MarkdownTheme.resolveColors(previewColors(choice, isDark), isDark)

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
    /** User-bubble stops, top to bottom, anchored on the preview card. */
    val bubbleStops: List<Color>,
    val inlineCodeText: Color,
    val inlineCodeBg: Color,
    val codeBg: Color,
    val codeHeaderBg: Color,
    val codeText: Color,
    val composer: Color,
)

@Composable
private fun animatedPreviewPalette(
    target: OriveoColors,
    isDark: Boolean,
    brand: OriveoLightBrand,
    markdown: MarkdownColors,
    bubbleStops: List<Color>,
): PreviewPalette {
    val targetStops = OriveoGradients.primaryStops(target, isDark, brand)
    // Light page: the default palette keeps its original base, others use the brand page top.
    val bg = if (isDark) target.backgroundBase else brand.tuned(target.backgroundBase, brand.bgTop)
    return PreviewPalette(
        bg = animatedColor(bg, "previewBg"),
        border = animatedColor(target.border, "previewBorder"),
        hairline = animatedColor(target.border, "previewHairline"),
        text = animatedColor(target.textPrimary, "previewText"),
        text2 = animatedColor(target.textSecondary, "previewText2"),
        text3 = animatedColor(target.textTertiary, "previewText3"),
        primary = animatedColor(target.primary, "previewPrimary"),
        // Light: the default palette keeps its accent (= primary); others show the second brand color.
        accent = animatedColor(if (isDark) target.accent else brand.tuned(target.accent, brand.accent), "previewAccent"),
        // Text on the brand gradient: on-primary of the previewed set (light bright fills use dark text).
        onBubble = animatedColor(target.onPrimary, "previewOnBubble"),
        stops = listOf(
            animatedColor(targetStops.first(), "previewStopStart"),
            animatedColor(targetStops.last(), "previewStopEnd"),
        ),
        bubbleStops = bubbleStops.mapIndexed { i, stop -> animatedColor(stop, "previewBubbleStop$i") },
        inlineCodeText = animatedColor(markdown.inlineCodeText, "previewInlineCodeText"),
        inlineCodeBg = animatedColor(markdown.inlineCodeBg, "previewInlineCodeBg"),
        codeBg = animatedColor(markdown.codeBlockBg, "previewCodeBg"),
        codeHeaderBg = animatedColor(markdown.codeBlockSurface, "previewCodeHeaderBg"),
        codeText = animatedColor(markdown.codeBlockFg, "previewCodeText"),
        composer = animatedColor(target.surface, "previewComposer"),
    )
}

@Composable
private fun ThemePreviewCard(choice: DarkPaletteChoice, isDark: Boolean, modifier: Modifier = Modifier) {
    val target = remember(choice, isDark) { previewColors(choice, isDark) }
    val brand = choice.lightBrand
    val markdown = remember(target, isDark) { MarkdownTheme.resolveColors(target, isDark) }
    val p = animatedPreviewPalette(target, isDark, brand, markdown, OriveoUserBubble.stops(choice, isDark))
    val bubbleViewport = remember { UserBubbleViewport() }
    val glowLayers = chatAuroraGlowLayers(target.copy(primary = p.primary, accent = p.accent), isDark)
    val gradient = Brush.linearGradient(p.stops, start = Offset.Zero, end = Offset.Infinite)

    Box(
        modifier = modifier
            .fillMaxWidth()
            // At least 352dp, grows with long locales / large font scale; never clips or scrolls inside.
            .heightIn(min = PREVIEW_MIN_HEIGHT)
            .userBubbleViewport(bubbleViewport)
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
                    PreviewUserBubble(p, isDark, bubbleViewport, modifier = Modifier.align(Alignment.End))
                    PreviewThinkingRow(p)
                    PreviewReply(p)
                    PreviewCodeBlock(p, markdown)
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
private fun PreviewUserBubble(
    p: PreviewPalette,
    isDark: Boolean,
    viewport: UserBubbleViewport,
    modifier: Modifier = Modifier,
) {
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
            .userBubbleFill(UserBubbleStyle(p.bubbleStops, isDark), shape, viewport)
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
private fun PreviewCodeBlock(p: PreviewPalette, markdown: MarkdownColors) {
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
        // Two plain code lines, not localized; colored by the same highlighter as chat code blocks.
        val highlighted = remember(markdown) {
            SyntaxHighlighter.highlight(PREVIEW_CODE_SOURCE, PREVIEW_CODE_LANG, markdown)
        }
        Text(
            text = highlighted,
            color = p.codeText,
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
