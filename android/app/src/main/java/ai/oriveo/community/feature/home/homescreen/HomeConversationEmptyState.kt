package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

@Composable
internal fun HomeConversationEmptyState(
    isDark: Boolean,
    modifier: Modifier = Modifier,
) {
    val accent = AuroraTheme.accent()
    val accentGlow = AuroraTheme.accentGlow()
    val auroraBlue = if (isDark) AuroraTheme.Colors.auroraBlueDark else AuroraTheme.Colors.auroraBlueLight

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(100.dp),
            contentAlignment = Alignment.Center,
        ) {

            Box(
                modifier = Modifier
                    .size(100.dp)
                    .background(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                accent.copy(alpha = if (isDark) 0.32f else 0.18f),
                                Color.Transparent,
                            ),
                        ),
                        shape = CircleShape,
                    ),
            )

            Box(
                modifier = Modifier
                    .size(64.dp)
                    .shadow(
                        elevation = if (isDark) 16.dp else 10.dp,
                        shape = CircleShape,
                        ambientColor = accent.copy(alpha = if (isDark) 0.40f else 0.18f),
                        spotColor = accent.copy(alpha = if (isDark) 0.40f else 0.18f),
                        clip = false,
                    )
                    .clip(CircleShape)
                    .background(
                        brush = Brush.linearGradient(
                            colors = listOf(
                                accent.copy(alpha = if (isDark) 0.45f else 0.20f),
                                auroraBlue.copy(alpha = if (isDark) 0.28f else 0.10f),
                            ),
                        ),
                        shape = CircleShape,
                    )
                    .border(
                        0.8.dp,
                        Brush.verticalGradient(
                            colors = listOf(

                                if (isDark) OriveoTheme.colors.cardHighlight.opacity(2.5f)
                                else Color.White.copy(alpha = 0.55f),
                                Color.Transparent,
                            ),
                        ),
                        CircleShape,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                    tint = accentGlow,
                )
            }
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = stringResource(R.string.no_conversations),
                fontSize = 19.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                color = AuroraTheme.textPrimary(),
                letterSpacing = (-0.2).sp,
            )
            Text(
                text = stringResource(R.string.home_start_chatting),
                fontSize = 14.sp,
                color = AuroraTheme.textSecondary(),
                textAlign = TextAlign.Center,
            )
        }
    }
}
