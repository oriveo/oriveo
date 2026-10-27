package ai.oriveo.community.feature.settings

import androidx.annotation.DrawableRes
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextCompactNumber
import ai.oriveo.community.feature.chat.ContextCapCommit
import ai.oriveo.community.feature.chat.ContextCapHeroCaption
import ai.oriveo.community.feature.chat.ContextCapPresentation
import ai.oriveo.community.feature.chat.ContextCapSettingsSelection
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

/**
 * Settings › Context: hero card for the default cap, the default cap segments (auto / unlimited / custom),
 * the price-line reminder card, then the two overflow strategy cards (keep the user's messages / AI summary).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContextSettingsScreen(
    onNavigateBack: () -> Unit = {},
    viewModel: ContextSettingsViewModel = koinViewModel(),
) {
    val colors = OriveoTheme.colors
    val aiSummaryEnabled by viewModel.aiSummaryEnabled.collectAsStateWithLifecycle()
    val defaultCap by viewModel.defaultCap.collectAsStateWithLifecycle()
    val priceLineReminderEnabled by viewModel.priceLineReminderEnabled.collectAsStateWithLifecycle()
    val focusManager = LocalFocusManager.current
    val customPrefill = ContextCapPresentation.settings(defaultCap).customPrefill
    // Typed custom text lives here so the hero previews the same value as the input echo.
    // Reset to the stored value whenever storage changes (commit, clamp, restore).
    var customText by rememberSaveable(customPrefill) { mutableStateOf(customPrefill.toString()) }

    Box(modifier = Modifier.fillMaxSize().testTag("context_settings_screen")) {
        OriveoScreenBackground()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.settings_context_title),
                            style = OriveoTheme.typography.title3,
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = {
                        OriveoBackButton(
                            onClick = onNavigateBack,
                            modifier = Modifier.testTag("settings_context_back_button"),
                        )
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    // Tapping blank space dismisses the keyboard; focus loss runs the existing commit.
                    .pointerInput(Unit) { detectTapGestures(onTap = { focusManager.clearFocus() }) }
                    .padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(28.dp),
            ) {
                HeroCard(cap = ContextCapPresentation.heroPreviewCap(defaultCap, customText))
                DefaultCapGroup(
                    cap = defaultCap,
                    onSelect = viewModel::setDefaultCap,
                    onSelectCustom = viewModel::selectCustomDefaultCap,
                    onCommit = viewModel::commitDefaultCap,
                    customText = customText,
                    onCustomTextChange = { customText = it },
                )
                PriceLineReminderGroup(
                    enabled = priceLineReminderEnabled,
                    onChange = viewModel::setPriceLineReminderEnabled,
                )
                OverflowGroup(
                    aiSummaryEnabled = aiSummaryEnabled,
                    onSelect = viewModel::setAISummaryEnabled,
                )
                OverflowFooter()
            }
        }
    }
}

/** Faint ink on the current surface for tracks, dashes and unselected illustration bars (no theme token for these). */
@Composable
private fun ink(alpha: Float): Color = OriveoTheme.colors.textPrimary.copy(alpha = alpha)

/** Hero card: current default cap as a big number (or "full window"), an illustrative bar with a fixed price-line tick, caption. */
@Composable
private fun HeroCard(cap: ContextBudgetCap) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    val hero = ContextCapPresentation.hero(cap)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(colors.surface)
            .border(1.dp, colors.hairline, RoundedCornerShape(24.dp))
            .padding(start = 22.dp, end = 22.dp, top = 22.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ContextIcon(R.drawable.ic_context_limit_window, 16.dp, colors.textSecondary)
                Text(
                    text = stringResource(R.string.settings_context_hero_label),
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium, letterSpacing = 1.2.sp),
                    color = colors.textSecondary,
                )
            }
            Text(
                text = stringResource(selectionLabel(hero.selected)),
                style = OriveoTheme.typography.footnote.copy(
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 0.6.sp,
                ),
                color = colors.primary,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.primarySoft)
                    .padding(horizontal = 9.dp, vertical = 4.dp),
            )
        }
        Row(
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = hero.valueTokens?.let { ContextCompactNumber.format(it.toLong(), locale) }
                    ?: stringResource(R.string.settings_context_hero_full_window),
                style = OriveoTheme.typography.brandDigits.copy(
                    fontSize = 44.sp,
                    lineHeight = 48.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = (-1.2).sp,
                ),
                color = colors.textPrimary,
                modifier = Modifier.alignByBaseline(),
            )
            if (hero.hasUnit) {
                Text(
                    text = stringResource(R.string.context_cap_input_unit),
                    style = OriveoTheme.typography.caption.copy(fontSize = 15.sp, fontWeight = FontWeight.Medium),
                    color = colors.textSecondary,
                    modifier = Modifier.alignByBaseline(),
                )
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            PriceLineLabel()
            HeroBar(fill = hero.fill.toFloat())
            HeroScaleLabels(locale)
        }
        Text(
            text = stringResource(heroCaption(hero.caption)),
            style = OriveoTheme.typography.caption.copy(fontSize = 13.sp, lineHeight = 21.sp),
            color = colors.textSecondary,
        )
    }
}

private fun selectionLabel(selection: ContextCapSettingsSelection): Int = when (selection) {
    ContextCapSettingsSelection.AUTO -> R.string.context_cap_auto
    ContextCapSettingsSelection.UNLIMITED -> R.string.context_cap_unlimited
    ContextCapSettingsSelection.CUSTOM -> R.string.context_cap_custom
}

private fun heroCaption(caption: ContextCapHeroCaption): Int = when (caption) {
    ContextCapHeroCaption.AUTO -> R.string.settings_context_hero_caption_auto
    ContextCapHeroCaption.UNLIMITED -> R.string.settings_context_hero_caption_unlimited
    ContextCapHeroCaption.CUSTOM -> R.string.settings_context_hero_caption_custom
}

/** 8dp track, primary fill, 2x18dp tick fixed at the price-line marker. */
@Composable
private fun HeroBar(fill: Float) {
    val colors = OriveoTheme.colors
    val marker = ContextCapPresentation.HERO_PRICE_LINE_MARKER.toFloat()
    val animatedFill by animateFloatAsState(
        targetValue = fill,
        animationSpec = tween(durationMillis = 300, easing = FastOutSlowInEasing),
        label = "heroFill",
    )
    BoxWithConstraints(modifier = Modifier.fillMaxWidth().height(18.dp)) {
        val width = maxWidth
        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .fillMaxWidth()
                .height(8.dp)
                .clip(CircleShape)
                .background(ink(0.08f)),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(animatedFill)
                    .fillMaxHeight()
                    .clip(CircleShape)
                    .background(colors.primary),
            )
        }
        Box(
            modifier = Modifier
                .offset(x = width * marker - 1.dp)
                .width(2.dp)
                .fillMaxHeight()
                .clip(RoundedCornerShape(1.dp))
                .background(ink(0.55f)),
        )
    }
}

/** Price-line label above the bar, its end edge on the marker tick (grows toward start; mirrored in RTL), one line. */
@Composable
private fun PriceLineLabel() {
    val marker = ContextCapPresentation.HERO_PRICE_LINE_MARKER.toFloat()
    Layout(
        modifier = Modifier.fillMaxWidth(),
        content = {
            Text(
                text = stringResource(R.string.settings_context_scale_price_line),
                style = OriveoTheme.typography.footnote.copy(fontSize = 11.sp),
                color = OriveoTheme.colors.textTertiary,
                maxLines = 1,
                softWrap = false,
            )
        },
    ) { measurables, constraints ->
        val label = measurables.single().measure(constraints.copy(minWidth = 0, maxWidth = Int.MAX_VALUE))
        val width = constraints.maxWidth
        layout(width, label.height) {
            label.placeRelative((width * marker - label.width).toInt().coerceAtLeast(0), 0)
        }
    }
}

/** "0" at the start and the model window at the end, under the bar. */
@Composable
private fun HeroScaleLabels(locale: String) {
    val style = OriveoTheme.typography.footnote.copy(fontSize = 11.sp)
    val color = OriveoTheme.colors.textTertiary
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = ContextCompactNumber.format(0L, locale),
            style = style,
            color = color,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Text(text = stringResource(R.string.settings_context_scale_window), style = style, color = color, maxLines = 1)
    }
}

/** Section title with its leading icon (design: 15dp icon, 13sp semibold tertiary). */
@Composable
private fun SectionTitle(@DrawableRes icon: Int, title: String) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        ContextIcon(icon, 15.dp, colors.textTertiary)
        Text(
            text = title,
            style = OriveoTheme.typography.footnote.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.4.sp),
            color = colors.textTertiary,
        )
    }
}

@Composable
private fun ContextIcon(@DrawableRes icon: Int, size: Dp, tint: Color) {
    Icon(painter = painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.size(size))
}

/** Default cap group (contract P9·U7 rule 4): three segments, custom input with echo and adjusted hint, per-chat note. */
@Composable
private fun DefaultCapGroup(
    cap: ContextBudgetCap,
    onSelect: (ContextBudgetCap) -> Unit,
    onSelectCustom: () -> Unit,
    onCommit: (String) -> ContextCapCommit,
    customText: String,
    onCustomTextChange: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    val presentation = ContextCapPresentation.settings(cap)
    val selected = presentation.selected

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle(R.drawable.ic_context_header_cap, stringResource(R.string.settings_context_cap_header))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(colors.surface)
                .border(1.dp, colors.hairline, RoundedCornerShape(16.dp))
                .padding(4.dp)
                .selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            CapSegment(
                icon = R.drawable.ic_context_cap_auto,
                title = stringResource(R.string.context_cap_auto),
                selected = selected == ContextCapSettingsSelection.AUTO,
                tag = "settings_context_cap_auto_option",
                onClick = { onSelect(ContextBudgetCap.Auto) },
            )
            CapSegment(
                icon = R.drawable.ic_context_cap_unlimited,
                title = stringResource(R.string.context_cap_unlimited),
                selected = selected == ContextCapSettingsSelection.UNLIMITED,
                tag = "settings_context_cap_unlimited_option",
                onClick = { onSelect(ContextBudgetCap.Unlimited) },
            )
            CapSegment(
                icon = R.drawable.ic_context_cap_custom,
                title = stringResource(R.string.context_cap_custom),
                selected = selected == ContextCapSettingsSelection.CUSTOM,
                tag = "settings_context_cap_custom_option",
                onClick = { if (selected != ContextCapSettingsSelection.CUSTOM) onSelectCustom() },
            )
        }
        if (selected == ContextCapSettingsSelection.CUSTOM) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(20.dp))
                    .background(colors.surface)
                    .border(1.dp, colors.hairline, RoundedCornerShape(20.dp))
                    .padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                CustomCapInput(text = customText, onTextChange = onCustomTextChange, locale = locale, onCommit = onCommit)
                Text(
                    text = stringResource(
                        R.string.settings_context_custom_min,
                        ContextCapPresentation.isolatedCompact(ContextBudget.CUSTOM_CAP_MIN.toLong(), locale),
                    ),
                    style = OriveoTheme.typography.footnote.copy(lineHeight = 19.sp),
                    color = colors.textTertiary,
                )
            }
        }
        Text(
            text = stringResource(R.string.settings_context_per_chat),
            style = OriveoTheme.typography.footnote.copy(lineHeight = 19.sp),
            color = colors.textTertiary,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

/** One segment of the default cap control: icon above the title, radio semantics. */
@Composable
private fun androidx.compose.foundation.layout.RowScope.CapSegment(
    @DrawableRes icon: Int,
    title: String,
    selected: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val tint = if (selected) colors.primary else colors.textSecondary
    Column(
        modifier = Modifier
            .weight(1f)
            .height(68.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) colors.surfaceElevated else Color.Transparent)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
    ) {
        ContextIcon(icon, 22.dp, tint)
        Text(
            text = title,
            style = OriveoTheme.typography.footnote.copy(
                fontSize = 13.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            ),
            color = tint,
            maxLines = 1,
        )
    }
}

/** Price-line reminder card (contract P9·U8): icon tile, title with its explanation, switch; all centred on the row. */
@Composable
private fun PriceLineReminderGroup(
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(colors.surface)
            .border(1.dp, colors.hairline, RoundedCornerShape(20.dp))
            .padding(start = 18.dp, end = 16.dp, top = 16.dp, bottom = 16.dp),
        // Vertically center the leading icon, multi-line text and trailing switch as one row
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(colors.primarySoft),
            contentAlignment = Alignment.Center,
        ) {
            ContextIcon(R.drawable.ic_context_price_line, 20.dp, colors.primary)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = stringResource(R.string.settings_context_price_line_reminder),
                style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                text = stringResource(R.string.settings_context_price_line_reminder_footer),
                style = OriveoTheme.typography.footnote.copy(lineHeight = 19.sp),
                color = colors.textSecondary,
            )
        }
        Switch(
            checked = enabled,
            onCheckedChange = onChange,
            modifier = Modifier,
        )
    }
}

/** "When over the cap": two equal-width strategy cards side by side. */
@Composable
private fun OverflowGroup(
    aiSummaryEnabled: Boolean,
    onSelect: (Boolean) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle(R.drawable.ic_context_header_overflow, stringResource(R.string.settings_context_overflow_header))
        Row(
            modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Max).selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            ContextModeOptionRow(
                title = stringResource(R.string.settings_context_mode_fallback),
                hint = stringResource(R.string.settings_context_mode_fallback_hint),
                selected = !aiSummaryEnabled,
                summary = false,
                tag = "settings_context_fallback_option",
                onClick = { onSelect(false) },
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
            ContextModeOptionRow(
                title = stringResource(R.string.settings_context_mode_ai),
                hint = stringResource(R.string.settings_context_mode_ai_hint),
                selected = aiSummaryEnabled,
                summary = true,
                tag = "settings_context_ai_summary_option",
                onClick = { onSelect(true) },
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
        }
    }
}

/** Local messages stay complete: icon and text centred on each other. */
@Composable
private fun OverflowFooter() {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        ContextIcon(R.drawable.ic_context_local_kept, 16.dp, colors.textTertiary)
        Text(
            text = stringResource(R.string.settings_context_overflow_footer),
            style = OriveoTheme.typography.footnote.copy(lineHeight = 19.sp),
            color = colors.textTertiary,
            modifier = Modifier.weight(1f),
        )
    }
}

/** Raw token input; commits on Done or focus loss, echoes the compact value and shows the adjusted hint. */
@Composable
private fun CustomCapInput(
    text: String,
    onTextChange: (String) -> Unit,
    locale: String,
    onCommit: (String) -> ContextCapCommit,
) {
    val colors = OriveoTheme.colors
    val focusManager = LocalFocusManager.current
    var adjustedTo by remember { mutableStateOf<Int?>(null) }
    var focused by remember { mutableStateOf(false) }

    fun commit() {
        val result = onCommit(text)
        adjustedTo = if (result.adjusted) result.value else null
        onTextChange(result.value.toString())
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = {
                onTextChange(it)
                adjustedTo = null
            },
            singleLine = true,
            textStyle = OriveoTheme.typography.brandDigits.copy(
                fontSize = 30.sp,
                lineHeight = 36.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = (-0.6).sp,
                color = colors.textPrimary,
            ),
            label = { Text(stringResource(R.string.context_cap_input_label)) },
            suffix = {
                Text(
                    text = stringResource(R.string.context_cap_input_unit),
                    style = OriveoTheme.typography.caption,
                    color = colors.textSecondary,
                )
            },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { state ->
                    if (focused && !state.isFocused) commit()
                    focused = state.isFocused
                },
        )
        // Echo = the clamped value a commit would store (hidden when unreadable); shown alongside "adjusted".
        val echo = ContextCapPresentation.echoValue(text, u = null)
        if (echo != null) {
            Text(
                text = stringResource(
                    R.string.context_cap_input_echo,
                    ContextCapPresentation.isolatedCompact(echo.toLong(), locale),
                ),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
        adjustedTo?.let { adjusted ->
            Text(
                text = stringResource(
                    R.string.context_cap_adjusted,
                    ContextCapPresentation.isolatedCompact(adjusted.toLong(), locale),
                ),
                style = OriveoTheme.typography.footnote,
                color = colors.warningText,
            )
        }
    }
}

/** Overflow strategy card: illustration, title with the selection dot, hint, cost tag; primary outline when selected. */
@Composable
private fun ContextModeOptionRow(
    title: String,
    hint: String,
    selected: Boolean,
    summary: Boolean,
    /** One tag for the whole card, same name as iOS. */
    tag: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(20.dp)
    Column(
        modifier = modifier
            .clip(shape)
            .background(colors.surface)
            .border(1.dp, if (selected) colors.primary else colors.hairline, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(start = 10.dp, end = 10.dp, top = 10.dp, bottom = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        StrategyIllustration(summary = summary, selected = selected)
        // Vertically center the title against the trailing selection dot
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = title,
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            SelectionDot(selected = selected)
        }
        Text(
            text = hint,
            style = OriveoTheme.typography.footnote.copy(lineHeight = 19.sp),
            color = colors.textSecondary,
            modifier = Modifier.weight(1f, fill = true),
        )
        CostTag(extra = summary)
    }
}

@Composable
private fun SelectionDot(selected: Boolean) {
    val colors = OriveoTheme.colors
    if (selected) {
        Box(
            modifier = Modifier.size(20.dp).clip(CircleShape).background(colors.primary),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Check, contentDescription = null, tint = colors.onPrimary, modifier = Modifier.size(13.dp))
        }
    } else {
        Box(modifier = Modifier.size(20.dp).border(1.5.dp, ink(0.22f), CircleShape))
    }
}

@Composable
private fun CostTag(extra: Boolean) {
    val colors = OriveoTheme.colors
    val fg = if (extra) colors.warningText else colors.success
    val bg = if (extra) colors.warningSoft else colors.successSoft
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(bg)
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ContextIcon(if (extra) R.drawable.ic_context_cost_extra else R.drawable.ic_context_cost_none, 12.dp, fg)
        Text(
            text = stringResource(if (extra) R.string.settings_context_cost_extra else R.string.settings_context_cost_none),
            style = OriveoTheme.typography.footnote.copy(fontSize = 11.sp, lineHeight = 15.sp, fontWeight = FontWeight.SemiBold),
            color = fg,
        )
    }
}

/** 76dp inset sketch: trimmed (dashed) AI turns between kept user turns, or a summary block above recent turns. */
@Composable
private fun StrategyIllustration(summary: Boolean, selected: Boolean) {
    val colors = OriveoTheme.colors
    val fill = if (selected) colors.primary else ink(0.28f)
    val ghost = ink(0.22f)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .height(76.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(colors.surfaceInset)
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterVertically),
    ) {
        if (summary) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(7.dp))
                    .background(colors.hairline)
                    .padding(horizontal = 7.dp, vertical = 6.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                SketchLine(0.84f, fill)
                SketchLine(0.64f, ghost)
                SketchLine(0.74f, ghost)
            }
            SketchBubble(0.50f, end = true) { Modifier.background(fill) }
            SketchBubble(0.66f, end = false) { Modifier.background(ink(0.08f)) }
        } else {
            SketchBubble(0.62f, end = false) { dashed(ghost) }
            SketchBubble(0.54f, end = true) { Modifier.background(fill) }
            SketchBubble(0.70f, end = false) { dashed(ghost) }
            SketchBubble(0.44f, end = true) { Modifier.background(fill) }
        }
    }
}

@Composable
private fun ColumnScope.SketchLine(fraction: Float, color: Color) {
    Box(modifier = Modifier.fillMaxWidth(fraction).height(3.dp).clip(RoundedCornerShape(2.dp)).background(color))
}

@Composable
private fun ColumnScope.SketchBubble(fraction: Float, end: Boolean, paint: @Composable () -> Modifier) {
    Box(
        modifier = Modifier
            .align(if (end) Alignment.End else Alignment.Start)
            .fillMaxWidth(fraction)
            .height(12.dp)
            .clip(RoundedCornerShape(6.dp))
            .then(paint()),
    )
}

private fun dashed(color: Color): Modifier = Modifier.drawBehind {
    val stroke = 1.dp.toPx()
    drawRoundRect(
        color = color,
        topLeft = androidx.compose.ui.geometry.Offset(stroke / 2, stroke / 2),
        size = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke),
        cornerRadius = CornerRadius(6.dp.toPx() - stroke / 2),
        style = Stroke(width = stroke, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))),
    )
}
