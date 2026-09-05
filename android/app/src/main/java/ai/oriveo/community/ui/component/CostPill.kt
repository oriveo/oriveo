package ai.oriveo.community.ui.component

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
fun CostPill(
    cost: Double,
    modifier: Modifier = Modifier,
) {
    if (cost <= 0.0) return

    val colors = OriveoTheme.colors
    val formatted = CostFormatter.format(cost)

    Text(
        modifier = modifier,
        text = formatted,
        
        style = TextStyle(
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            fontFeatureSettings = "tnum",
            platformStyle = PlatformTextStyle(includeFontPadding = false),
        ),
        color = colors.primary,
    )
}
