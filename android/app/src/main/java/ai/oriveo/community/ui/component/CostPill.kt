package ai.oriveo.community.ui.component

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Cost label, matching the iOS ChatCostPill (flat mono digits, no stroke, no container).
 *
 * Design notes:
 * - no fill, no border, no container; plain primary-color mono digits
 * - 13sp SemiBold + tabular num font feature (aligned financial-grade digits)
 * - consistent with the bare icons in the top bar
 *
 * [text] is the per-currency cost text ([costPartsText]); nothing is shown when it is empty.
 */
@Composable
fun CostPill(
    text: String,
    modifier: Modifier = Modifier,
) {
    if (text.isEmpty()) return

    val colors = OriveoTheme.colors

    Text(
        modifier = modifier,
        text = text,
        // tnum = tabular figures, matches iOS .monospacedDigit() so digit widths stay uniform
        style = TextStyle(
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            fontFeatureSettings = "tnum",
            platformStyle = PlatformTextStyle(includeFontPadding = false),
        ),
        color = colors.primary,
    )
}
