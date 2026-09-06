package ai.oriveo.community.feature.chat.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun ScrollToBottomButton(
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(36.dp)
            .shadow(
                elevation = 12.dp,
                shape = CircleShape,
                ambientColor = OriveoTheme.colors.primaryGlow,
                spotColor = OriveoTheme.colors.primaryGlow,
            )
            .clip(CircleShape)
            .background(OriveoGradients.primary, CircleShape)
            .border(OriveoBorderWidth.standard, OriveoTheme.colors.hairline, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.KeyboardArrowDown,
            contentDescription = null,
            modifier = Modifier.size(18.dp),

            tint = Color.White,
        )
    }
}
