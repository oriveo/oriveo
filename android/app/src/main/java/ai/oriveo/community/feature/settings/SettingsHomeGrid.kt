package ai.oriveo.community.feature.settings

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Layout of the settings home grid: 4 = 2x2, 3 = 1x3, 2 = 1x2, 1 = a single full-width cell, 0 = not rendered.
 * Returns (columns, rows). More than 4 items are not specified and continue in two columns.
 */
internal fun settingsGridShape(count: Int): Pair<Int, Int> = when {
    count <= 0 -> 0 to 0
    count <= 3 -> count to 1
    else -> 2 to (count + 1) / 2
}

/** Solid color of the grid cross lines: dark = the palette primary @ (0.18 + 0.16 x glowK); light = black 10%. */
internal fun settingsGridLineColor(isDark: Boolean, primary: Color, glowK: Float): Color =
    if (isDark) {
        primary.copy(alpha = (0.18f + 0.16f * glowK).coerceIn(0f, 1f))
    } else {
        Color.Black.copy(alpha = 0.10f)
    }

internal data class SettingsGridItem(
    val key: String,
    @param:DrawableRes val icon: Int,
    val title: String,
    /** Doubles as the testTag; written out as a literal for each item. */
    val tag: String,
    val value: String? = null,
    val showBadge: Boolean = false,
    val onClick: () -> Unit,
)

/** Feature = AI / tools & connections (cell height 104); Compact = help & about (cell height 76). */
internal enum class SettingsGridStyle { Feature, Compact }

/** Section title: 13 / 600, letter spacing 0.02em, text-tertiary. */
@Composable
internal fun SettingsSectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        modifier = modifier,
        style = OriveoTheme.typography.footnote.copy(
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.02.em,
        ),
        color = OriveoTheme.colors.textTertiary,
    )
}

/**
 * A grid without a card background: cells are separated only by thin lines pinned at the center and open at the edges (transparent ends -> solid middle -> transparent ends).
 */
@Composable
internal fun SettingsGrid(
    items: List<SettingsGridItem>,
    modifier: Modifier = Modifier,
    style: SettingsGridStyle = SettingsGridStyle.Feature,
) {
    val (columns, rows) = settingsGridShape(items.size)
    if (columns == 0) return
    val colors = OriveoTheme.colors
    val lineColor = settingsGridLineColor(OriveoTheme.isDark, colors.primary, colors.glowK)
    val cellHeight = if (style == SettingsGridStyle.Compact) 76.dp else 104.dp
    val verticalInset: Dp = when {
        style == SettingsGridStyle.Compact -> 16.dp
        rows == 2 -> 10.dp
        else -> 18.dp
    }
    val horizontalPadding = if (columns == 3) 8.dp else 14.dp
    Column(
        modifier = modifier
            .fillMaxWidth()
            .drawBehind {
                val stroke = 1.dp.toPx()
                val vInset = verticalInset.toPx()
                for (i in 1 until columns) {
                    val x = size.width * i / columns
                    drawLine(
                        brush = Brush.verticalGradient(
                            0f to Color.Transparent,
                            0.5f to lineColor,
                            1f to Color.Transparent,
                            startY = vInset,
                            endY = size.height - vInset,
                        ),
                        start = Offset(x, vInset),
                        end = Offset(x, size.height - vInset),
                        strokeWidth = stroke,
                    )
                }
                if (rows == 2) {
                    val hInset = 6.dp.toPx()
                    val y = size.height / 2
                    drawLine(
                        brush = Brush.horizontalGradient(
                            0f to Color.Transparent,
                            0.5f to lineColor,
                            1f to Color.Transparent,
                            startX = hInset,
                            endX = size.width - hInset,
                        ),
                        start = Offset(hInset, y),
                        end = Offset(size.width - hInset, y),
                        strokeWidth = stroke,
                    )
                }
            },
    ) {
        items.chunked(columns).forEach { rowItems ->
            Row(modifier = Modifier.fillMaxWidth().height(cellHeight)) {
                rowItems.forEach { item ->
                    SettingsGridCell(
                        item = item,
                        style = style,
                        horizontalPadding = horizontalPadding,
                        modifier = Modifier.weight(1f).fillMaxHeight(),
                    )
                }
                repeat(columns - rowItems.size) { Spacer(modifier = Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun SettingsGridCell(
    item: SettingsGridItem,
    style: SettingsGridStyle,
    horizontalPadding: Dp,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val compact = style == SettingsGridStyle.Compact
    Column(
        modifier = modifier
            .testTag(item.tag)
            .clickable(onClick = item.onClick)
            .padding(horizontal = horizontalPadding),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Image(
            painter = painterResource(item.icon),
            contentDescription = null,
            modifier = Modifier.size(if (compact) 23.dp else 26.dp),
        )
        Spacer(modifier = Modifier.height(if (compact) 9.dp else 10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = item.title,
                modifier = Modifier.weight(1f, fill = false),
                style = OriveoTheme.typography.body.copy(
                    fontSize = if (compact) 12.5.sp else 15.sp,
                    fontWeight = if (compact) FontWeight.Medium else FontWeight.SemiBold,
                    // When wrapping, break by phrase and keep both lines even (no single-character orphan line)
                    lineBreak = LineBreak.Heading,
                ),
                color = if (compact) colors.textSecondary else colors.textPrimary,
                textAlign = TextAlign.Center,
                // A name that does not fit wraps to a second line (long ja / ru names are not truncated); the value stays on one line with an ellipsis
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (item.showBadge) {
                Spacer(modifier = Modifier.width(5.dp))
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(colors.danger),
                )
            }
        }
        val value = item.value
        if (!compact && !value.isNullOrBlank()) {
            Spacer(modifier = Modifier.height(3.dp))
            Text(
                text = value,
                style = OriveoTheme.typography.footnote.copy(fontSize = 12.sp),
                color = colors.textTertiary,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * List row of the General group: height 52, icon 23 -> 16 -> right area (name fills -> value -> chevron, spacing 8);
 * the hairline is drawn at the bottom of the right area and omitted on the last row.
 */
@Composable
internal fun SettingsListRow(
    title: String,
    onClick: () -> Unit,
    showDivider: Boolean,
    modifier: Modifier = Modifier,
    @DrawableRes iconRes: Int? = null,
    icon: (@Composable () -> Unit)? = null,
    value: String? = null,
    leadingValueDot: Brush? = null,
    titleColor: Color = OriveoTheme.colors.textPrimary,
    titleBadge: (@Composable () -> Unit)? = null,
    showChevron: Boolean = true,
    enabled: Boolean = true,
    trailingContent: (@Composable () -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val hairline = if (OriveoTheme.isDark) Color.White.copy(alpha = 0.07f) else Color.Black.copy(alpha = 0.07f)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(52.dp)
            .clickable(enabled = enabled, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(modifier = Modifier.size(23.dp), contentAlignment = Alignment.Center) {
            when {
                iconRes != null -> Image(
                    painter = painterResource(iconRes),
                    contentDescription = null,
                    modifier = Modifier.size(23.dp),
                )
                icon != null -> icon()
            }
        }
        Spacer(modifier = Modifier.width(16.dp))
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .drawBehind {
                    if (showDivider) {
                        val stroke = 1.dp.toPx()
                        drawLine(
                            color = hairline,
                            start = Offset(0f, size.height - stroke / 2),
                            end = Offset(size.width, size.height - stroke / 2),
                            strokeWidth = stroke,
                        )
                    }
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(modifier = Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    modifier = Modifier.weight(1f, fill = false),
                    style = OriveoTheme.typography.body.copy(fontSize = 15.5.sp, fontWeight = FontWeight.Medium),
                    color = titleColor,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (titleBadge != null) {
                    Spacer(modifier = Modifier.width(6.dp))
                    titleBadge()
                }
            }
            if (!value.isNullOrBlank()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (leadingValueDot != null) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(leadingValueDot),
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                    }
                    Text(
                        text = value,
                        style = OriveoTheme.typography.footnote.copy(fontSize = 14.sp),
                        color = colors.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            trailingContent?.invoke()
            if (showChevron) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = colors.textTertiary,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

/** Color dot of the theme row: the palette primary -> accent at 135 degrees (top-left -> bottom-right). */
internal fun settingsThemeDotBrush(primary: Color, accent: Color): Brush =
    Brush.linearGradient(
        colors = listOf(primary, accent),
        start = Offset.Zero,
        end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
    )
