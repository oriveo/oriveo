package ai.oriveo.community.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.outlined.AutoAwesome
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
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity


@Composable
fun ProvidersFullEmptyState(onAdd: () -> Unit, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val primaryGradient = Brush.linearGradient(
        colors = listOf(colors.primary, colors.primaryPressed),
    )

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(26.dp))
            .background(
                color = colors.surface.copy(alpha = if (isDark) 0.55f else 0.78f),
                shape = RoundedCornerShape(26.dp),
            )
            .border(
                width = 0.5.dp,
                color = colors.border.opacity(0.6f),
                shape = RoundedCornerShape(26.dp),
            )
            .padding(horizontal = 24.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        
        Box(
            modifier = Modifier
                .size(140.dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            colors.primary.copy(alpha = if (isDark) 0.35f else 0.18f),
                            Color.Transparent,
                        ),
                    ),
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.AutoAwesome,
                contentDescription = null,
                modifier = Modifier.size(44.dp),
                tint = colors.primary,
            )
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = stringResource(R.string.providers_connect_first_title),
                style = compactTextStyle(
                    TextStyle(
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 19.sp,
                        lineHeight = 24.sp,
                    ),
                ),
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
            )
            Text(
                text = stringResource(R.string.no_providers_description),
                modifier = Modifier.widthIn(max = 300.dp),
                style = compactTextStyle(
                    TextStyle(
                        fontWeight = FontWeight.Medium,
                        fontSize = 13.5.sp,
                        lineHeight = 18.sp,
                    ),
                ),
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
            )
        }

        
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .shadow(
                    elevation = 12.dp,
                    shape = CircleShape,
                    ambientColor = colors.primary.copy(alpha = if (isDark) 0.45f else 0.28f),
                    spotColor = colors.primary.copy(alpha = if (isDark) 0.45f else 0.28f),
                )
                .background(primaryGradient, CircleShape)
                .clickable(onClick = onAdd)
                .padding(horizontal = 22.dp, vertical = 13.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Icon(
                
                imageVector = Icons.Filled.AddCircle,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = Color.White,
            )
            Text(
                text = stringResource(R.string.add_provider),
                style = compactTextStyle(
                    TextStyle(
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        lineHeight = 18.sp,
                    ),
                ),
                color = Color.White,
                maxLines = 1,
            )
        }
    }
}


@Composable
fun ProvidersListEmptyState(modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text(
            text = stringResource(R.string.no_providers_title),
            style = compactTextStyle(
                TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 20.sp),
            ),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            text = stringResource(R.string.no_providers_description),
            modifier = Modifier.widthIn(max = 280.dp),
            style = compactTextStyle(
                TextStyle(fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 17.sp),
            ),
            color = colors.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

private fun compactTextStyle(base: TextStyle): TextStyle =
    base.copy(
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = LineHeightStyle(
            alignment = LineHeightStyle.Alignment.Center,
            trim = LineHeightStyle.Trim.Both,
        ),
    )
