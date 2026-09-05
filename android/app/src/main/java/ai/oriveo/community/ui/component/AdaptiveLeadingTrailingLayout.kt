package ai.oriveo.community.ui.component

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.max

@Composable
fun AdaptiveLeadingTrailingLayout(
    modifier: Modifier = Modifier,
    horizontalSpacing: Dp = 0.dp,
    verticalSpacing: Dp = 0.dp,
    leading: @Composable () -> Unit,
    trailing: @Composable () -> Unit,
) {
    SubcomposeLayout(modifier = modifier) { constraints ->
        val relaxedConstraints = constraints.copy(minWidth = 0, minHeight = 0)
        val horizontalSpacingPx = horizontalSpacing.roundToPx()
        val verticalSpacingPx = verticalSpacing.roundToPx()

        val trailingPlaceable = subcompose(AdaptiveLeadingTrailingSlot.Trailing, trailing)
            .single()
            .measure(relaxedConstraints)

        val leadingRowMaxWidth = if (constraints.hasBoundedWidth) {
            (constraints.maxWidth - trailingPlaceable.width - horizontalSpacingPx).coerceAtLeast(0)
        } else {
            relaxedConstraints.maxWidth
        }

        val leadingRowPlaceable = subcompose(AdaptiveLeadingTrailingSlot.LeadingRow, leading)
            .single()
            .measure(relaxedConstraints.copy(maxWidth = leadingRowMaxWidth))

        val fitsHorizontally = !constraints.hasBoundedWidth ||
            leadingRowPlaceable.width + horizontalSpacingPx + trailingPlaceable.width <= constraints.maxWidth

        if (fitsHorizontally) {
            val layoutWidth = if (constraints.hasBoundedWidth) {
                constraints.maxWidth
            } else {
                leadingRowPlaceable.width + horizontalSpacingPx + trailingPlaceable.width
            }
            val layoutHeight = max(leadingRowPlaceable.height, trailingPlaceable.height)
            val constrainedWidth = layoutWidth.coerceIn(constraints.minWidth, constraints.maxWidth)
            val constrainedHeight = layoutHeight.coerceIn(constraints.minHeight, constraints.maxHeight)

            layout(
                width = constrainedWidth,
                height = constrainedHeight,
            ) {
                leadingRowPlaceable.placeRelative(
                    x = 0,
                    y = (constrainedHeight - leadingRowPlaceable.height) / 2,
                )
                trailingPlaceable.placeRelative(
                    x = constrainedWidth - trailingPlaceable.width,
                    y = (constrainedHeight - trailingPlaceable.height) / 2,
                )
            }
        } else {
            val leadingColumnPlaceable = subcompose(AdaptiveLeadingTrailingSlot.LeadingColumn, leading)
                .single()
                .measure(relaxedConstraints)
            val trailingColumnPlaceable = subcompose(AdaptiveLeadingTrailingSlot.TrailingColumn, trailing)
                .single()
                .measure(relaxedConstraints)

            val layoutWidth = if (constraints.hasBoundedWidth) {
                constraints.maxWidth
            } else {
                max(leadingColumnPlaceable.width, trailingColumnPlaceable.width)
            }
            val layoutHeight = leadingColumnPlaceable.height + verticalSpacingPx + trailingColumnPlaceable.height
            val constrainedWidth = layoutWidth.coerceIn(constraints.minWidth, constraints.maxWidth)
            val constrainedHeight = layoutHeight.coerceIn(constraints.minHeight, constraints.maxHeight)

            layout(
                width = constrainedWidth,
                height = constrainedHeight,
            ) {
                leadingColumnPlaceable.placeRelative(0, 0)
                trailingColumnPlaceable.placeRelative(0, leadingColumnPlaceable.height + verticalSpacingPx)
            }
        }
    }
}

private enum class AdaptiveLeadingTrailingSlot {
    LeadingRow,
    Trailing,
    LeadingColumn,
    TrailingColumn,
}
