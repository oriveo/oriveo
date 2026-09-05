package ai.oriveo.community.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity


@Composable
fun FlatGroup(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = OriveoRadius.lgShape
    val fill = if (isDark) colors.surfaceElevated else Color.White

    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (isDark) 12.dp else 8.dp,
                shape = shape,
                ambientColor = colors.shadow,
                spotColor = colors.shadow,
            )
            .background(fill, shape)
            
            .then(
                if (isDark) {
                    Modifier.border(OriveoBorderWidth.standard, Color.White.copy(alpha = 0.07f), shape)
                } else {
                    Modifier
                },
            ),
        content = content,
    )
}


@Composable
fun FlatSectionHeader(
    title: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = title,
        style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
        color = OriveoTheme.colors.textTertiary,
        modifier = modifier.padding(start = OriveoTheme.spacing.lg),
    )
}


@Composable
fun InsetHairline(modifier: Modifier = Modifier) {
    val line = OriveoTheme.colors.borderStrong.opacity(0.65f)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(horizontal = OriveoTheme.spacing.lg)
            .background(
                Brush.horizontalGradient(
                    0f to Color.Transparent,
                    0.15f to line,
                    0.85f to line,
                    1f to Color.Transparent,
                ),
            ),
    )
}


@Composable
fun FlatTapRow(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = 9.dp),
    ) {
        content()
    }
}
