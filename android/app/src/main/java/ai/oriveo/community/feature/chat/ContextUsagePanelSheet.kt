package ai.oriveo.community.feature.chat

import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextCompactionMode
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.theme.DetailRowPalette
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.util.formatRelativeTime

/** Visibility of the panel buttons (contract P4·U4 rule 4). */
data class ContextUsagePanelButtons(
    val compactEnabled: Boolean,
    val showClear: Boolean,
    val showNewChatWithSummary: Boolean,
    val showRetry: Boolean,
)

/** Ring segments in drawing / legend order. */
enum class ContextUsageLegendKind(@param:StringRes val labelRes: Int) {
    CONVERSATION(R.string.context_usage_segment_conversation),
    LIBRARY(R.string.context_usage_segment_library),
    SUMMARY(R.string.context_usage_segment_summary),
    INSTRUCTIONS(R.string.context_usage_segment_instructions),
    MEMORY(R.string.context_usage_segment_memory),
    FREE(R.string.context_usage_segment_free),
}

data class ContextUsageLegendItem(val kind: ContextUsageLegendKind, val tokens: Int)

enum class ContextUsageOmittedKind(@param:PluralsRes val pluralRes: Int) {
    NOTES(R.plurals.context_usage_omitted_notes),
    KNOWLEDGE(R.plurals.context_usage_omitted_knowledge),
    MEMORY(R.plurals.context_usage_omitted_memory),
}

data class ContextUsageOmittedLine(val kind: ContextUsageOmittedKind, val count: Int)

/** Percent text of the panel center and the settings usage row (contract P4·U4 rules 4 and 5). */
sealed interface ContextUsageValueText {
    data class Percent(val value: Int) : ContextUsageValueText
    data class AboutPercent(val value: Int) : ContextUsageValueText
    data object Unavailable : ContextUsageValueText
}

/** Pure values behind the context panel and the settings usage row. */
object ContextUsagePanel {

    /**
     * [Condense context] always shows and is disabled while a compaction ([compacting]) or a send ([sending]) runs;
     * clear / new chat with summary need a checkpoint; retry shows while the breaker is in fallback-only mode.
     */
    fun buttons(
        summary: ContextUsageSummary?,
        breakerMode: ContextCompactionMode,
        compacting: Boolean,
        sending: Boolean,
    ): ContextUsagePanelButtons {
        val hasCheckpoint = summary?.checkpoint != null
        return ContextUsagePanelButtons(
            compactEnabled = !compacting && !sending,
            showClear = hasCheckpoint,
            showNewChatWithSummary = hasCheckpoint,
            showRetry = breakerMode == ContextCompactionMode.FALLBACK_ONLY,
        )
    }

    /** Percent display and never_observed draw the segmented ring; every other case a dashed circle. */
    fun showsSegmentedRing(summary: ContextUsageSummary?): Boolean {
        if (summary == null || summary.segments == null) return false
        return summary.display == ContextUsageDisplay.PERCENT ||
            (summary.display == ContextUsageDisplay.UNAVAILABLE && summary.reason == ContextUsageReason.NEVER_OBSERVED)
    }

    /** Only segments above zero, except conversation and free which are always listed. */
    fun legend(summary: ContextUsageSummary?): List<ContextUsageLegendItem> {
        if (!showsSegmentedRing(summary)) return emptyList()
        val s = summary?.segments ?: return emptyList()
        return listOf(
            ContextUsageLegendItem(ContextUsageLegendKind.CONVERSATION, s.conversation),
            ContextUsageLegendItem(ContextUsageLegendKind.LIBRARY, s.library),
            ContextUsageLegendItem(ContextUsageLegendKind.SUMMARY, s.summary),
            ContextUsageLegendItem(ContextUsageLegendKind.INSTRUCTIONS, s.instructions),
            ContextUsageLegendItem(ContextUsageLegendKind.MEMORY, s.memory),
            ContextUsageLegendItem(ContextUsageLegendKind.FREE, s.free),
        ).filter {
            it.tokens > 0 || it.kind == ContextUsageLegendKind.CONVERSATION || it.kind == ContextUsageLegendKind.FREE
        }
    }

    /** One line per omitted category above zero. */
    fun omittedLines(summary: ContextUsageSummary?): List<ContextUsageOmittedLine> {
        val o = summary?.omitted ?: return emptyList()
        return listOf(
            ContextUsageOmittedLine(ContextUsageOmittedKind.NOTES, o.notes),
            ContextUsageOmittedLine(ContextUsageOmittedKind.KNOWLEDGE, o.knowledge),
            ContextUsageOmittedLine(ContextUsageOmittedKind.MEMORY, o.memory),
        ).filter { it.count > 0 }
    }

    /**
     * Hint under the dashed circle; null when the segmented ring shows. Unavailable without a reason =
     * checkpoints cleared since the last send, so usage shows again after the next send; a summary not read
     * yet shows the same hint. No manifest (none) has no hint of its own: a conversation has one after its
     * first send.
     */
    @StringRes
    fun hintRes(summary: ContextUsageSummary?): Int? {
        if (summary == null) return R.string.context_usage_hint_empty
        if (summary.display == ContextUsageDisplay.NONE) return null
        if (showsSegmentedRing(summary)) return null
        return when (summary.reason) {
            ContextUsageReason.WINDOW_UNKNOWN -> R.string.context_usage_hint_window_unknown
            ContextUsageReason.COMPACTED_SINCE -> R.string.context_usage_hint_compacted
            // Cleared: same hint as no manifests (usage.v1 cleared_since).
            ContextUsageReason.NEVER_OBSERVED, ContextUsageReason.CLEARED_SINCE, null -> R.string.context_usage_hint_empty
        }
    }

    /** "N%" when measured, "About N%" when estimated, otherwise unavailable. */
    fun settingsValue(summary: ContextUsageSummary?): ContextUsageValueText {
        if (summary == null) return ContextUsageValueText.Unavailable
        val percent = summary.percent
        if (summary.display == ContextUsageDisplay.PERCENT && percent != null) {
            return if (summary.basis == ContextBasis.ESTIMATED) {
                ContextUsageValueText.AboutPercent(percent)
            } else {
                ContextUsageValueText.Percent(percent)
            }
        }
        val estimated = summary.estimatedPercent
        if (summary.reason == ContextUsageReason.NEVER_OBSERVED && estimated != null) {
            return ContextUsageValueText.AboutPercent(estimated)
        }
        return ContextUsageValueText.Unavailable
    }

    /** Plain "N%" like the ring label; locale percent formats ("40 %", "٤٠٪") are not used. */
    fun percentText(value: Int): String = "$value%"
}

/** Localized text of a [ContextUsageValueText]. */
@Composable
fun ContextUsageValueText.text(): String = when (this) {
    is ContextUsageValueText.Percent -> ContextUsagePanel.percentText(value)
    is ContextUsageValueText.AboutPercent -> stringResource(R.string.context_usage_about_percent, value)
    ContextUsageValueText.Unavailable -> stringResource(R.string.context_usage_unavailable)
}

/** Panel actions; the caller decides which ones also close the panel. */
class ContextUsagePanelActions(
    val onCompact: () -> Unit,
    val onClear: () -> Unit,
    val onNewChatWithSummary: () -> Unit,
    val onRetry: () -> Unit,
)

/**
 * Context panel (contract P4·U4 rule 4), opened from the composer ring and the settings usage row.
 * [cap] adds the "limit for this chat" row and the window row (contract P9·U7 rule 3); null (drafts) hides them.
 * Tapping the cap row switches the sheet to the cap picker ([capActions] writes the choice); back returns here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContextUsagePanelSheet(
    summary: ContextUsageSummary?,
    buttons: ContextUsagePanelButtons,
    actions: ContextUsagePanelActions,
    onDismiss: () -> Unit,
    cap: ContextCapInputs? = null,
    capActions: ContextCapPickerActions? = null,
    /** Debug sample-screen entry only: open straight on the cap picker; production always starts on the panel. */
    initialShowCapPicker: Boolean = false,
    /** Clock for the "compacted N times · …" relative time; production uses the system clock, sample screens pin it. */
    now: () -> Long = { System.currentTimeMillis() },
) {
    val colors = OriveoTheme.colors
    var showCapPicker by rememberSaveable { mutableStateOf(initialShowCapPicker) }
    val pickerCap = cap?.takeIf { showCapPicker && capActions != null }
    val capPanel = cap?.panel(used = summary?.used)
    // Only a price line below the limit is drawn on the ring (T < B).
    val ringPriceLine = if (capPanel?.windowLine == ContextCapWindowLine.ABOVE_LINE) cap?.window?.priceLineTokens else null
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { ai.oriveo.community.ui.component.OriveoSheetDragHandle() },
        containerColor = colors.backgroundBase,
    ) {
        if (pickerCap != null && capActions != null) {
            BackHandler { showCapPicker = false }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 24.dp)
                    .heightIn(max = 640.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                ContextCapPickerPage(cap = pickerCap, actions = capActions, onBack = { showCapPicker = false })
            }
            return@OriveoModalBottomSheet
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.context_usage_title),
                    style = OriveoTheme.typography.title3,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss, modifier = Modifier) {
                    Text(stringResource(R.string.done))
                }
            }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 520.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                UsageRingBlock(summary, ringPriceLine, capPanel?.priceLineDistance)
                UsageDetails(summary, ringPriceLine)
                if (cap != null && capPanel != null) {
                    CapRows(cap, capPanel, onCapClick = { if (capActions != null) showCapPicker = true })
                }
            }
            HorizontalDivider(color = colors.hairline)
            if (buttons.showRetry) {
                Text(
                    text = stringResource(R.string.context_usage_breaker_paused),
                    style = OriveoTheme.typography.footnote,
                    color = colors.warningText,
                )
                TextButton(
                    onClick = actions.onRetry,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.context_usage_retry))
                }
            }
            summary?.checkpoint?.let { checkpoint ->
                Text(
                    text = pluralStringResource(
                        R.plurals.context_usage_compacted_count,
                        checkpoint.count,
                        checkpoint.count,
                        formatRelativeTime(checkpoint.latestCreatedAt, now()),
                    ),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
            TextButton(
                onClick = actions.onCompact,
                enabled = buttons.compactEnabled,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.context_compaction_action_compact))
            }
            if (buttons.showNewChatWithSummary) {
                TextButton(
                    onClick = actions.onNewChatWithSummary,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.context_compaction_action_new_chat_with_summary))
                }
            }
            if (buttons.showClear) {
                TextButton(
                    onClick = actions.onClear,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.context_compaction_action_clear))
                }
            }
        }
    }
}

@Composable
private fun legendColor(kind: ContextUsageLegendKind): Color =
    legendColor(kind, OriveoTheme.colors, memory = DetailRowPalette.teal)

/**
 * Legend / ring segment color. FREE doubles as the ring track; it uses `border` (iOS `Palette.border`)
 * because `hairline` is 70% white in light mode and disappears on the white sheet.
 */
internal fun legendColor(kind: ContextUsageLegendKind, colors: OriveoColors, memory: Color): Color =
    when (kind) {
        ContextUsageLegendKind.CONVERSATION -> colors.primary
        ContextUsageLegendKind.LIBRARY -> colors.info
        ContextUsageLegendKind.SUMMARY -> colors.textSecondary
        ContextUsageLegendKind.INSTRUCTIONS -> colors.warning
        ContextUsageLegendKind.MEMORY -> memory
        ContextUsageLegendKind.FREE -> colors.border
    }

/** Cap row (value and chevron), the limited-by-model row and the window / above-the-line row. */
@Composable
private fun CapRows(cap: ContextCapInputs, panel: ContextCapPanel, onCapClick: () -> Unit) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onCapClick)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = stringResource(R.string.context_cap_title),
            style = OriveoTheme.typography.footnote,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = ContextCapPresentation.capRowValue(
                panel = panel,
                cap = cap.effectiveCap,
                autoLabel = stringResource(R.string.context_cap_auto),
                unlimitedLabel = stringResource(R.string.context_cap_unlimited),
                locale = locale,
            ),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(16.dp),
        )
    }
    val actual = panel.actual
    if (panel.limitedByModel && actual != null) {
        Text(
            text = stringResource(R.string.context_cap_row_limited, ContextCapPresentation.isolatedCompact(actual.toLong(), locale)),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
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
    ContextCapPresentation.windowLineText(panel, cap.window, strings, locale)?.let { line ->
        Text(
            text = line,
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
}

/** [priceLine] = T when it sits below the limit; [priceLineDistance] = tokens left before it (0 = crossed). */
@Composable
private fun UsageRingBlock(summary: ContextUsageSummary?, priceLine: Int?, priceLineDistance: Int?) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    val segmented = ContextUsagePanel.showsSegmentedRing(summary)
    val segments = summary?.segments
    val arcs = if (segmented && segments != null) {
        listOf(
            ContextUsageLegendKind.CONVERSATION to segments.conversation,
            ContextUsageLegendKind.LIBRARY to segments.library,
            ContextUsageLegendKind.SUMMARY to segments.summary,
            ContextUsageLegendKind.INSTRUCTIONS to segments.instructions,
            ContextUsageLegendKind.MEMORY to segments.memory,
        ).filter { it.second > 0 }.map { (kind, tokens) -> legendColor(kind) to tokens }
    } else {
        emptyList()
    }
    val track = legendColor(ContextUsageLegendKind.FREE)
    val dashed = colors.textSecondary
    val priceLineColor = colors.textPrimary
    // Over the limit the used segments fill the whole circle.
    val total = maxOf(summary?.B ?: 0, arcs.sumOf { it.second }).coerceAtLeast(1)
    Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(modifier = Modifier.size(200.dp), contentAlignment = Alignment.Center) {
            Canvas(modifier = Modifier.size(200.dp)) {
                val stroke = 14.dp.toPx()
                val inset = stroke / 2
                val arcSize = Size(size.width - stroke, size.height - stroke)
                val topLeft = Offset(inset, inset)
                if (!segmented) {
                    drawArc(
                        color = dashed,
                        startAngle = -90f,
                        sweepAngle = 360f,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = Stroke(
                            width = 2.dp.toPx(),
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 6.dp.toPx())),
                        ),
                    )
                    return@Canvas
                }
                drawArc(
                    color = track,
                    startAngle = -90f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = stroke),
                )
                var start = -90f
                for ((color, tokens) in arcs) {
                    val sweep = 360f * tokens / total
                    drawArc(
                        color = color,
                        startAngle = start,
                        sweepAngle = sweep,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = Stroke(width = stroke),
                    )
                    start += sweep
                }
                if (priceLine != null) {
                    // Price line tick across the ring at T / total, starting from the top.
                    val angle = Math.toRadians((-90.0 + 360.0 * priceLine / total))
                    val radius = arcSize.width / 2
                    val center = Offset(size.width / 2, size.height / 2)
                    val dir = Offset(kotlin.math.cos(angle).toFloat(), kotlin.math.sin(angle).toFloat())
                    drawLine(
                        color = priceLineColor,
                        start = center + dir * (radius - stroke * 0.75f),
                        end = center + dir * (radius + stroke / 2),
                        strokeWidth = 2.dp.toPx(),
                        cap = StrokeCap.Round,
                    )
                }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                val value = if (segmented) ContextUsagePanel.settingsValue(summary) else ContextUsageValueText.Unavailable
                Text(
                    text = value.text(),
                    style = OriveoTheme.typography.title3,
                    color = colors.textPrimary,
                    textAlign = TextAlign.Center,
                )
                if (segmented) {
                    val used = ContextCompactionPresentation.compactTokenCount(summary?.used, locale) ?: "0"
                    val limit = ContextCompactionPresentation.compactTokenCount(summary?.B, locale)
                    if (limit != null) {
                        Text(
                            text = "$used / $limit",
                            style = OriveoTheme.typography.footnote,
                            color = colors.textSecondary,
                        )
                    }
                }
            }
        }
        if (segmented) {
            val observed = summary?.basis == ContextBasis.OBSERVED
            Text(
                text = when {
                    priceLine == null || priceLineDistance == null -> stringResource(
                        if (observed) R.string.context_usage_measured else R.string.context_usage_estimated,
                    )
                    priceLineDistance == 0 -> stringResource(
                        if (observed) R.string.context_usage_measured_price_line_crossed else R.string.context_usage_estimated_price_line_crossed,
                    )
                    else -> stringResource(
                        if (observed) R.string.context_usage_measured_price_line else R.string.context_usage_estimated_price_line,
                        ContextCapPresentation.isolatedCompact(priceLineDistance.toLong(), locale),
                    )
                },
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        } else {
            ContextUsagePanel.hintRes(summary)?.let { hint ->
                Text(
                    text = stringResource(hint),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

/** Legend rows, then the price line row (not a legend item) when [priceLine] is drawn on the ring. */
@Composable
private fun UsageDetails(summary: ContextUsageSummary?, priceLine: Int?) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    val legend = ContextUsagePanel.legend(summary)
    for (item in legend) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(modifier = Modifier.size(10.dp).background(legendColor(item.kind), CircleShape))
            Text(
                text = stringResource(item.kind.labelRes),
                style = OriveoTheme.typography.footnote,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = ContextCompactionPresentation.compactTokenCount(item.tokens, locale) ?: "0",
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
    }
    if (legend.isNotEmpty() && priceLine != null) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(modifier = Modifier.size(width = 10.dp, height = 10.dp), contentAlignment = Alignment.Center) {
                Box(modifier = Modifier.size(width = 2.dp, height = 10.dp).background(colors.textPrimary))
            }
            Text(
                text = stringResource(R.string.context_usage_legend_price_line),
                style = OriveoTheme.typography.footnote,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = ContextCompactionPresentation.compactTokenCount(priceLine, locale) ?: "0",
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
    }
    for (line in ContextUsagePanel.omittedLines(summary)) {
        Text(
            text = pluralStringResource(line.kind.pluralRes, line.count, line.count),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
}
