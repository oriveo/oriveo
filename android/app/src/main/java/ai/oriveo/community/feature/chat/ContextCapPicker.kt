package ai.oriveo.community.feature.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextBudgetLimit
import ai.oriveo.community.core.context.ContextCompactNumber
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlin.math.roundToInt

/** Writes of the per-conversation cap picker; every choice is stored right away. */
class ContextCapPickerActions(
    /** null = follow the global default. */
    val onSelect: (ContextBudgetCap?) -> Unit,
    val onSelectCustom: () -> Unit,
    /** Slider released: (pressed tick index, released tick index); unchanged index writes nothing. */
    val onReleaseSlider: (Int, Int) -> Unit,
    /** Typed custom number; null when the conversation has no cap inputs any more. */
    val onCommit: (String) -> ContextCapCommit?,
)

/**
 * "Limit for this chat" picker inside the context panel sheet (contract P9·U7 rules 1, 2 and 5):
 * head line, follow global / automatic / no limit / custom (slider, tick labels, input, echo, hint), footer.
 */
@Composable
fun ContextCapPickerPage(
    cap: ContextCapInputs,
    actions: ContextCapPickerActions,
    onBack: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    val picker = cap.picker()
    val t = cap.window.priceLineTokens
    fun compact(tokens: Int): String = ContextCapPresentation.isolatedCompact(tokens.toLong(), locale)

    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            OriveoBackButton(onClick = onBack)
            Text(
                text = stringResource(R.string.context_cap_title),
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
        }
        Text(
            text = headLine(cap, locale),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )

        val autoLabel = stringResource(R.string.context_cap_auto)
        val unlimitedLabel = stringResource(R.string.context_cap_unlimited)
        val unknownHint = stringResource(R.string.context_cap_hint_window_unknown)
        CapOptionRow(
            title = stringResource(R.string.context_cap_follow),
            hint = stringResource(
                R.string.context_cap_follow_hint,
                ContextCapPresentation.capLabel(cap.globalCap, autoLabel, unlimitedLabel, locale),
            ),
            selected = picker.selected == ContextCapSelection.FOLLOW,
            tag = "chat_context_cap_follow_option",
            onClick = { actions.onSelect(null) },
        )
        CapOptionRow(
            title = autoLabel,
            hint = autoHint(picker.auto, t, locale) ?: unknownHint,
            selected = picker.selected == ContextCapSelection.AUTO,
            tag = "chat_context_cap_auto_option",
            onClick = { actions.onSelect(ContextBudgetCap.Auto) },
        )
        val unlimitedB = picker.unlimited.B
        CapOptionRow(
            title = unlimitedLabel,
            hint = when {
                unlimitedB == null -> unknownHint
                picker.unlimitedCrossesPriceLine && t != null ->
                    stringResource(R.string.context_cap_unlimited_hint_price_line, compact(unlimitedB), compact(t))
                else -> stringResource(R.string.context_cap_unlimited_hint, compact(unlimitedB))
            },
            hintColor = if (picker.unlimitedCrossesPriceLine) colors.warningText else null,
            selected = picker.selected == ContextCapSelection.UNLIMITED,
            tag = "chat_context_cap_unlimited_option",
            onClick = { actions.onSelect(ContextBudgetCap.Unlimited) },
        )
        CapOptionRow(
            title = stringResource(R.string.context_cap_custom),
            hint = null,
            selected = picker.selected == ContextCapSelection.CUSTOM,
            tag = "chat_context_cap_custom_option",
            onClick = { if (picker.selected != ContextCapSelection.CUSTOM) actions.onSelectCustom() },
        )
        if (picker.selected == ContextCapSelection.CUSTOM) {
            CustomCapEditor(cap = cap, picker = picker, actions = actions, locale = locale)
        }
        Text(
            text = stringResource(R.string.context_cap_footer),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
}

/** "{model} · {W} window · {U} usable", plus the price line when the model has one; unknown window otherwise. */
@Composable
private fun headLine(cap: ContextCapInputs, locale: String): String {
    val model = "\u2068" + cap.modelName + "\u2069"
    val w = cap.window.W
    val u = cap.usable
    if (w == null || u == null) return stringResource(R.string.context_cap_head_unknown, model)
    val head = stringResource(
        R.string.context_cap_head,
        model,
        ContextCapPresentation.isolatedCompact(w.toLong(), locale),
        ContextCapPresentation.isolatedCompact(u.toLong(), locale),
    )
    val t = cap.window.priceLineTokens ?: return head
    return stringResource(R.string.context_cap_head_price_line, head, ContextCapPresentation.isolatedCompact(t.toLong(), locale))
}

/** Automatic option hint by what bounds its B; null for an unknown window. */
@Composable
private fun autoHint(auto: ContextCapOptionBudget, t: Int?, locale: String): String? {
    val b = auto.B ?: return null
    val value = ContextCapPresentation.isolatedCompact(b.toLong(), locale)
    val max = ContextCapPresentation.isolatedCompact(ContextBudget.AUTO_CAP_DEFAULT.toLong(), locale)
    return when (auto.limitedBy) {
        ContextBudgetLimit.PRICE_LINE -> stringResource(R.string.context_cap_auto_hint_price_line, value)
        ContextBudgetLimit.AUTO_DEFAULT -> if (t == null) {
            stringResource(R.string.context_cap_auto_hint_default, value, max)
        } else {
            stringResource(R.string.context_cap_auto_hint_default_below_line, value, max)
        }
        else -> stringResource(R.string.context_cap_auto_hint_window, value)
    }
}

/** Slider over the cap ticks, tick labels, raw input with echo / adjusted hint and the price line hint. */
@Composable
private fun CustomCapEditor(
    cap: ContextCapInputs,
    picker: ContextCapPicker,
    actions: ContextCapPickerActions,
    locale: String,
) {
    val colors = OriveoTheme.colors
    val ticks = picker.ticks
    val t = cap.window.priceLineTokens
    // Live slider position while dragging; reset whenever the stored value moves the nearest tick.
    var index by remember(picker.sliderIndex, ticks) { mutableIntStateOf(picker.sliderIndex) }
    var dragging by remember { mutableStateOf(false) }
    var pressedIndex by remember { mutableIntStateOf(picker.sliderIndex) }
    val sliderValue = ticks.getOrNull(index) ?: picker.customStart
    // While dragging the hint follows the slider; otherwise the stored custom start.
    val hintValue = if (dragging) sliderValue else picker.customStart
    val hint = if (dragging) {
        ContextCapPresentation.picker(cap.window, ContextBudgetCap.Custom(hintValue), cap.globalCap).customHint
    } else {
        picker.customHint
    }
    val over = hint.kind == ContextCapHintKind.OVER

    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (ticks.size >= 2) {
            val tint = if (t != null && sliderValue > t) colors.warning else colors.primary
            val a11y = stringResource(R.string.context_cap_slider_a11y, ContextCapPresentation.isolatedCompact(sliderValue.toLong(), locale))
            Slider(
                value = index.toFloat(),
                onValueChange = {
                    if (!dragging) pressedIndex = index
                    dragging = true
                    index = it.roundToInt().coerceIn(0, ticks.lastIndex)
                },
                onValueChangeFinished = {
                    dragging = false
                    actions.onReleaseSlider(pressedIndex, index)
                },
                valueRange = 0f..ticks.lastIndex.toFloat(),
                steps = ticks.size - 2,
                colors = SliderDefaults.colors(thumbColor = tint, activeTrackColor = tint),
                modifier = Modifier
                    .semantics { stateDescription = a11y },
            )
            TickLabels(ticks = ticks, priceLineIndex = picker.priceLineTickIndex, locale = locale)
        }
        CustomCapInput(
            stored = (cap.conversationCap as? ContextBudgetCap.Custom)?.tokens ?: picker.customStart,
            u = cap.usable,
            locale = locale,
            onCommit = actions.onCommit,
        )
        val hintText = when (hint.kind) {
            ContextCapHintKind.NONE -> null
            ContextCapHintKind.OVER -> t?.let { line ->
                val multiplier = cap.pricing?.let(ContextCapPresentation::multiplier)
                val lineText = ContextCapPresentation.isolatedCompact(line.toLong(), locale)
                if (multiplier == null) {
                    stringResource(R.string.context_cap_custom_over_plain, lineText)
                } else {
                    stringResource(R.string.context_cap_custom_over, lineText, multiplierText(multiplier, locale))
                }
            }
            ContextCapHintKind.AT -> stringResource(R.string.context_cap_custom_at)
            ContextCapHintKind.UNDER -> stringResource(
                R.string.context_cap_custom_under,
                ContextCapPresentation.isolatedCompact((hint.gap ?: 0).toLong(), locale),
            )
        }
        hintText?.let {
            Text(
                text = it,
                style = OriveoTheme.typography.footnote,
                color = if (over) colors.warningText else colors.textSecondary,
            )
        }
    }
}

@Composable
private fun multiplierText(multiplier: ContextCapMultiplier, locale: String): String {
    val strings = ContextCapPanelStrings(
        windowLine = stringResource(R.string.context_cap_window_line),
        windowLinePrice = stringResource(R.string.context_cap_window_line_price),
        windowLinePricePlain = stringResource(R.string.context_cap_window_line_price_plain),
        aboveLine = stringResource(R.string.context_cap_above_line),
        multBoth = stringResource(R.string.context_cap_mult_both),
        multInput = stringResource(R.string.context_cap_mult_input),
        multOutput = stringResource(R.string.context_cap_mult_output),
        multSplit = stringResource(R.string.context_cap_mult_split),
    )
    return ContextCapPresentation.multiplierText(multiplier, strings, locale)
}

/**
 * First and last tick at the slider ends and the price line tick at its position. The price line label is
 * always drawn (also when T is an end tick); an end label it would overlap is dropped. placeRelative follows
 * the layout direction, so the labels mirror with the slider in RTL.
 */
@Composable
private fun TickLabels(ticks: List<Int>, priceLineIndex: Int?, locale: String) {
    val colors = OriveoTheme.colors
    val last = ticks.lastIndex
    val gap = with(LocalDensity.current) { 4.dp.roundToPx() }
    Layout(
        modifier = Modifier.fillMaxWidth(),
        content = {
            Text(
                text = ContextCompactNumber.format(ticks.first().toLong(), locale),
                fontSize = 11.sp,
                color = colors.textSecondary,
                maxLines = 1,
            )
            Text(
                text = ContextCompactNumber.format(ticks.last().toLong(), locale),
                fontSize = 11.sp,
                color = colors.textSecondary,
                maxLines = 1,
            )
            if (priceLineIndex != null) {
                Text(
                    text = stringResource(
                        R.string.context_cap_price_line_tick,
                        ContextCompactNumber.format(ticks[priceLineIndex].toLong(), locale),
                    ),
                    fontSize = 11.sp,
                    color = colors.warningText,
                    maxLines = 1,
                )
            }
        },
    ) { measurables, constraints ->
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val placeables = measurables.map { it.measure(loose) }
        val width = constraints.maxWidth
        val height = placeables.maxOf { it.height }
        layout(width, height) {
            val first = placeables[0]
            val end = placeables[1]
            val price = placeables.getOrNull(2)
            if (price == null || priceLineIndex == null) {
                first.placeRelative(0, 0)
                if (last > 0) end.placeRelative(width - end.width, 0)
                return@layout
            }
            val fraction = if (last > 0) priceLineIndex.toFloat() / last else 0f
            val priceX = (width * fraction - price.width / 2f).toInt().coerceIn(0, maxOf(width - price.width, 0))
            price.placeRelative(priceX, 0)
            if (priceLineIndex != 0 && first.width + gap <= priceX) first.placeRelative(0, 0)
            if (last > 0 && priceLineIndex != last && priceX + price.width + gap <= width - end.width) {
                end.placeRelative(width - end.width, 0)
            }
        }
    }
}

/** Raw token input showing the stored value c (even above U); commits on Done or focus loss. */
@Composable
private fun CustomCapInput(
    stored: Int,
    /** Model's usable input; the echo is clamped to it like the commit. */
    u: Int?,
    locale: String,
    onCommit: (String) -> ContextCapCommit?,
) {
    val colors = OriveoTheme.colors
    val focusManager = LocalFocusManager.current
    // Reset to the stored value whenever storage changes (commit, clamp, slider).
    var text by rememberSaveable(stored) { mutableStateOf(stored.toString()) }
    var adjustedTo by remember { mutableStateOf<Int?>(null) }
    var focused by remember { mutableStateOf(false) }

    fun commit() {
        val result = onCommit(text) ?: return
        adjustedTo = if (result.adjusted) result.value else null
        text = result.value.toString()
    }

    OutlinedTextField(
        value = text,
        onValueChange = {
            text = it
            adjustedTo = null
        },
        singleLine = true,
        label = { Text(stringResource(R.string.context_cap_input_label)) },
        suffix = { Text(stringResource(R.string.context_cap_input_unit)) },
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
    ContextCapPresentation.echoValue(text, u)?.let { echo ->
        Text(
            text = stringResource(R.string.context_cap_input_echo, ContextCapPresentation.isolatedCompact(echo.toLong(), locale)),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
    adjustedTo?.let { adjusted ->
        Text(
            text = stringResource(R.string.context_cap_adjusted, ContextCapPresentation.isolatedCompact(adjusted.toLong(), locale)),
            style = OriveoTheme.typography.footnote,
            color = colors.warningText,
        )
    }
}

@Composable
private fun CapOptionRow(
    title: String,
    hint: String?,
    selected: Boolean,
    /** One tag for the whole row and its radio. */
    tag: String,
    onClick: () -> Unit,
    hintColor: Color? = null,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        RadioButton(
            selected = selected,
            onClick = onClick,
            modifier = Modifier,
        )
        Column(modifier = Modifier.weight(1f).padding(top = 3.dp)) {
            Text(
                text = title,
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            if (hint != null) {
                Text(
                    text = hint,
                    style = OriveoTheme.typography.footnote,
                    color = hintColor ?: colors.textSecondary,
                )
            }
        }
    }
}
