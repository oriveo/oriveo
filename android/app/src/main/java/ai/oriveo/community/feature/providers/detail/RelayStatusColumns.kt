package ai.oriveo.community.feature.providers.detail

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import kotlin.math.max
import kotlin.math.min

/**
 * Width split between the left column and the status column (same rule as iOS):
 * total = the width after the mark / key icon and before Retry or the trailing arrow; status column = min(ideal single-line status width, total x 50%),
 * left column = total - status column - spacing. Taking 50% of the whole row width would let the status eat Retry's share and truncate "Catalog: N models" in the left column.
 */
internal object RelayStatusColumns {
    const val STATUS_RATIO = 0.5f

    /** Returns (left column width, status column width); with no status (ideal width 0) the left column takes everything and no spacing is left. */
    fun columnWidths(total: Int, statusIdeal: Int, spacing: Int): Pair<Int, Int> {
        val width = max(total, 0)
        if (statusIdeal <= 0) return width to 0
        val status = min(statusIdeal, (width * STATUS_RATIO).toInt())
        return max(width - status - spacing, 0) to status
    }
}

/**
 * Lays out the left column and the status column per [RelayStatusColumns.columnWidths]: the caller makes this layout take total (weight(1f) in the row),
 * the status column sits at the row end, and both columns are vertically centered on the whole row; when [status] is null the left column takes everything.
 */
@Composable
internal fun RelayStatusColumnsLayout(
    spacing: Dp,
    modifier: Modifier = Modifier,
    status: (@Composable () -> Unit)?,
    left: @Composable () -> Unit,
) {
    Layout(
        contents = listOf(left, status ?: {}),
        modifier = modifier,
    ) { (leftMeasurables, statusMeasurables), constraints ->
        val total = if (constraints.hasBoundedWidth) constraints.maxWidth else constraints.minWidth
        // Ideal single-line width = maximum intrinsic width (the width without wrapping).
        val ideal = statusMeasurables.maxOfOrNull { it.maxIntrinsicWidth(Constraints.Infinity) } ?: 0
        val (leftWidth, statusWidth) = RelayStatusColumns.columnWidths(total, ideal, spacing.roundToPx())
        val statusPlaceables = statusMeasurables.map { it.measure(Constraints(maxWidth = statusWidth)) }
        val leftPlaceables = leftMeasurables.map { it.measure(Constraints(minWidth = leftWidth, maxWidth = leftWidth)) }
        val height = max(
            leftPlaceables.maxOfOrNull { it.height } ?: 0,
            statusPlaceables.maxOfOrNull { it.height } ?: 0,
        ).coerceIn(constraints.minHeight, constraints.maxHeight)
        layout(total, height) {
            leftPlaceables.forEach { it.placeRelative(0, (height - it.height) / 2) }
            statusPlaceables.forEach { it.placeRelative(total - it.width, (height - it.height) / 2) }
        }
    }
}
