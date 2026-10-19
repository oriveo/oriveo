package ai.oriveo.community.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * New-feature red dot: an 8dp solid danger circle, placed to the right of the entry row title (OriveoSettingsRow.titleBadge).
 * Decorative: not read by screen readers and carries no text.
 */
@Composable
fun FeatureBadgeDot(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(8.dp)
            .clip(CircleShape)
            .background(OriveoTheme.colors.danger),
    )
}
