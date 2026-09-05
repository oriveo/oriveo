package ai.oriveo.community.feature.providers.relay

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.ui.component.rememberBrandPainter
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
fun RelayKindPicker(
    selectedKind: RelayKind?,
    onSelect: (RelayKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    val spacing = OriveoTheme.spacing
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(spacing.xl),
    ) {
        DefaultSetupSection(selectedKind = selectedKind, onSelect = onSelect)
        CompatibilitySection(selectedKind = selectedKind, onSelect = onSelect)
        AdvancedSection(selectedKind = selectedKind, onSelect = onSelect)
    }
}

@Composable
private fun DefaultSetupSection(selectedKind: RelayKind?, onSelect: (RelayKind) -> Unit) {
    val spacing = OriveoTheme.spacing
    Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
        SectionHeader(stringResource(R.string.relay_kind_section_default_setup))
        HeroCard(
            kind = RelayKind.OpenAICompatible,
            selected = selectedKind == RelayKind.OpenAICompatible,
            onClick = { onSelect(RelayKind.OpenAICompatible) },
        )
    }
}

@Composable
private fun CompatibilitySection(selectedKind: RelayKind?, onSelect: (RelayKind) -> Unit) {
    val spacing = OriveoTheme.spacing
    Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
        SectionHeader(stringResource(R.string.relay_kind_section_compatibility))
        Column(verticalArrangement = Arrangement.spacedBy(spacing.md)) {
            TintedCard(RelayKind.CodexStyle, selectedKind == RelayKind.CodexStyle) { onSelect(RelayKind.CodexStyle) }
            TintedCard(RelayKind.AnthropicCompatible, selectedKind == RelayKind.AnthropicCompatible) { onSelect(RelayKind.AnthropicCompatible) }
            TintedCard(RelayKind.GeminiCompatible, selectedKind == RelayKind.GeminiCompatible) { onSelect(RelayKind.GeminiCompatible) }
        }
    }
}

@Composable
private fun AdvancedSection(selectedKind: RelayKind?, onSelect: (RelayKind) -> Unit) {
    val spacing = OriveoTheme.spacing
    Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
        SectionHeader(stringResource(R.string.relay_kind_section_advanced))
        TintedCard(
            kind = RelayKind.Custom,
            selected = selectedKind == RelayKind.Custom,
            badge = stringResource(R.string.relay_kind_advanced_badge),
            onClick = { onSelect(RelayKind.Custom) },
        )
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text.uppercase(),
        style = OriveoTheme.typography.caption,
        color = OriveoTheme.colors.textTertiary,
        fontFamily = FontFamily.Default,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}


@Composable
private fun HeroCard(kind: RelayKind, selected: Boolean, onClick: () -> Unit) {
    val meta = relayKindMeta(kind)
    val shape = RoundedCornerShape(24.dp)

    KindCardSurface(
        onClick = onClick,
        shape = shape,
        elevation = if (selected) 22.dp else 16.dp,
        shadowColor = meta.tint,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.linearGradient(listOf(meta.tint, meta.tintDeep))),
        ) {
            Watermark(
                res = meta.watermarkRes,
                size = 176.dp,
                color = Color.White.copy(alpha = 0.17f),
                overhang = 40.dp,
            )
            Column(
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 22.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(9.dp),
                ) {
                    Text(
                        text = stringResource(meta.titleRes),
                        fontSize = 22.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                    )
                    Badge(
                        text = stringResource(R.string.relay_kind_default_badge),
                        textColor = Color.White,
                        background = Color.White.copy(alpha = 0.24f),
                    )
                }
                Text(
                    text = stringResource(meta.subtitleRes),
                    fontSize = 13.5.sp,
                    color = Color.White.copy(alpha = 0.86f),
                )
                meta.endpointPath?.let { path ->
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color.White.copy(alpha = 0.18f))
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    ) {
                        Text(
                            text = path,
                            color = Color.White,
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.SemiBold,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }
        }
    }
}


@Composable
private fun TintedCard(
    kind: RelayKind,
    selected: Boolean,
    badge: String? = null,
    onClick: () -> Unit,
) {
    val meta = relayKindMeta(kind)
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(20.dp)

    KindCardSurface(onClick = onClick, shape = shape) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(meta.tint.copy(alpha = if (selected) 0.18f else 0.11f)),
        ) {
            Watermark(
                res = meta.watermarkRes,
                size = 116.dp,
                color = meta.tint.copy(alpha = 0.09f),
                overhang = 24.dp,
            )
            Row(
                modifier = Modifier.padding(horizontal = 18.dp, vertical = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(9.dp),
                    ) {
                        Text(
                            text = stringResource(meta.titleRes),
                            fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.textPrimary,
                        )
                        badge?.let {
                            Badge(
                                text = it,
                                textColor = meta.tint,
                                background = meta.tint.copy(alpha = 0.16f),
                            )
                        }
                    }
                    Text(
                        text = stringResource(meta.subtitleRes),
                        fontSize = 13.sp,
                        color = colors.textSecondary,
                    )
                    meta.endpointPath?.let { path ->
                        Text(
                            text = path,
                            color = meta.tint,
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.SemiBold,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
                Icon(
                    imageVector = Icons.Filled.ChevronRight,
                    contentDescription = null,
                    tint = meta.tint.copy(alpha = 0.55f),
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

@Composable
private fun Badge(text: String, textColor: Color, background: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(background)
            .padding(horizontal = 9.dp, vertical = 3.dp),
    ) {
        Text(
            text = text,
            color = textColor,
            fontSize = 10.5.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}


@Composable
private fun BoxScope.Watermark(
    @DrawableRes res: Int,
    size: Dp,
    color: Color,
    overhang: Dp,
) {
    Image(
        painter = rememberBrandPainter(res, size),
        contentDescription = null,
        colorFilter = ColorFilter.tint(color),
        modifier = Modifier
            .align(Alignment.CenterEnd)
            .offset(x = overhang)
            .size(size),
    )
}


@Composable
private fun KindCardSurface(
    onClick: () -> Unit,
    shape: Shape,
    elevation: Dp = 0.dp,
    shadowColor: Color = Color.Transparent,
    content: @Composable () -> Unit,
) {
    val haptic = LocalHapticFeedback.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale = if (pressed) 0.98f else 1.0f
    val alpha = if (pressed) 0.92f else 1.0f

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .graphicsLayer(scaleX = scale, scaleY = scale, alpha = alpha)
            
            .shadow(
                elevation = elevation,
                shape = shape,
                ambientColor = shadowColor,
                spotColor = shadowColor,
            )
            .clip(shape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onClick()
                },
            ),
    ) {
        content()
    }
}


@Composable
fun relayKindTitle(kind: RelayKind): String = stringResource(relayKindMeta(kind).titleRes)

@Composable
fun relayKindSubtitle(kind: RelayKind): String = stringResource(relayKindMeta(kind).subtitleRes)
