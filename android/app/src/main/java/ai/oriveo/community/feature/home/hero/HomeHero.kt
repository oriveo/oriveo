package ai.oriveo.community.feature.home.hero

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.outlined.AttachMoney
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.ui.component.HeroModelCapabilityStrip
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoEmptyState
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.capabilityIcon
import ai.oriveo.community.ui.component.localizedPriceTier
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

@Composable
internal fun HeroSection(
    viewModel: HomeViewModel,
    providers: List<Provider>,
    showEmptyProviderState: Boolean,
    onNewChat: () -> Unit,
    onSwitchModel: () -> Unit,
    onAddProvider: () -> Unit,
) {
    val spacing = OriveoTheme.spacing
    val modelState by viewModel.activeModelState.collectAsStateWithLifecycle()
    val activeModel = modelState.activeModel

    val screenH = OriveoTheme.layout.screenH
    Column(
        modifier = Modifier.padding(
            start = screenH,
            end = screenH,
            top = screenH,
            bottom = spacing.lg,
        ),
        verticalArrangement = Arrangement.spacedBy(spacing.lg),
    ) {
        when {
            providers.isEmpty() && showEmptyProviderState -> {
                OriveoEmptyState(
                    icon = Icons.Outlined.Inbox,
                    title = stringResource(R.string.home_no_provider_title),
                    description = stringResource(R.string.home_no_provider_description),
                    actionTitle = stringResource(R.string.add_provider),
                    onAction = onAddProvider,
                )
            }

            providers.isEmpty() -> {
                Spacer(modifier = Modifier.height(184.dp))
            }

            activeModel != null -> {
                HomeHeroCard {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(15.dp),
                    ) {
                        HeroProviderMetaRow(
                            kind = activeModel.provider.kind,
                            providerName = activeModel.provider.displayName,
                            status = activeModel.provider.status,
                        )
                        HeroModelSelectionButton(
                            provider = activeModel.provider,
                            model = activeModel.model,
                            onClick = onSwitchModel,
                        )
                        HeroPrimaryActionButton(
                            text = stringResource(R.string.new_chat),
                            onClick = onNewChat,
                        )
                    }
                }
            }

            else -> {
                OriveoPrimaryButton(
                    text = stringResource(R.string.new_chat),
                    onClick = onNewChat,
                )
            }
        }
    }
}

private enum class HeroInfoPillTone {
    Primary,
    Warning,
    Neutral,
}

private data class HeroInfoItem(
    val id: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val title: String,
    val tone: HeroInfoPillTone,
)

private enum class HeroSwitchControlVariant(val reservedWidth: Dp) {
    Regular(84.dp),
    Compact(34.dp),
}

@Composable
private fun HeroProviderMetaRow(
    kind: ai.oriveo.community.core.model.ProviderKind,
    providerName: String,
    status: ProviderConnectionState,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.weight(1f, fill = false),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ProviderBadgeIcon(kind = kind, size = 22.dp)
            Text(
                text = providerName,
                style = TextStyle(
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = OriveoTheme.colors.textSecondary.copy(alpha = 0.98f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        HeroProviderStatusInline(status = status)
    }
}

@Composable
private fun HeroProviderStatusInline(status: ProviderConnectionState) {
    val colors = OriveoTheme.colors
    val isDarkTheme = OriveoTheme.isDark
    val statusColor = when (status) {
        ProviderConnectionState.Connected -> if (isDarkTheme) colors.success.copy(alpha = 0.94f) else colors.success.copy(alpha = 0.88f)
        ProviderConnectionState.Syncing -> if (isDarkTheme) colors.primary.copy(alpha = 0.94f) else colors.primary.copy(alpha = 0.88f)
        is ProviderConnectionState.Issue -> if (isDarkTheme) colors.warning.copy(alpha = 0.94f) else colors.warning.copy(alpha = 0.88f)
    }
    val background = when (status) {
        ProviderConnectionState.Connected -> if (isDarkTheme) Color(0xFF103321) else colors.successSoft.copy(alpha = 0.90f)
        ProviderConnectionState.Syncing -> if (isDarkTheme) Color(0xFF2A2347) else colors.primarySoft.copy(alpha = 0.90f)
        is ProviderConnectionState.Issue -> if (isDarkTheme) Color(0xFF3A2A0D) else colors.warningSoft.copy(alpha = 0.94f)
    }
    val border = when (status) {
        ProviderConnectionState.Connected -> colors.success.copy(alpha = if (isDarkTheme) 0.24f else 0.24f)
        ProviderConnectionState.Syncing -> colors.primary.copy(alpha = if (isDarkTheme) 0.24f else 0.24f)
        is ProviderConnectionState.Issue -> colors.warning.copy(alpha = if (isDarkTheme) 0.26f else 0.28f)
    }
    val textColor = when (status) {
        ProviderConnectionState.Connected -> if (isDarkTheme) colors.textPrimary.copy(alpha = 0.96f) else colors.success.copy(alpha = 0.88f)
        ProviderConnectionState.Syncing -> if (isDarkTheme) colors.textPrimary.copy(alpha = 0.96f) else colors.primary.copy(alpha = 0.90f)
        is ProviderConnectionState.Issue -> if (isDarkTheme) colors.textPrimary.copy(alpha = 0.96f) else colors.warning.copy(alpha = 0.88f)
    }

    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(background)
            .border(OriveoBorderWidth.standard, border, CircleShape)
            .padding(horizontal = 9.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            modifier = Modifier
                .size(5.dp)
                .clip(CircleShape)
                .background(statusColor),
        )
        Text(
            text = providerStatusText(status),
            style = TextStyle(
                fontSize = 11.5.sp,
                lineHeight = 13.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = textColor,
        )
    }
}

@Composable
private fun HeroModelSelectionButton(
    provider: Provider,
    model: AIModel,
    onClick: () -> Unit,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(18.dp)
    val capabilityObservationRevision by CapabilityEvidenceObservationBridge.revision.collectAsStateWithLifecycle()
    val heroCapabilities = remember(provider, model, capabilityObservationRevision) {
        prioritizedHeroCapabilities(
            model.copy(
                capabilities = CapabilityEvidenceProductionAdapter
                    .governedMetadataCapabilities(provider, model)
                    .toList(),
            ),
        )
    }

    val priceTierLabel = localizedPriceTier(model.priceTier.trim())
    val heroMetaItems = remember(model, priceTierLabel) { heroMetaItems(model, priceTierLabel) }
    val hasHeaderContent = heroMetaItems.isNotEmpty()
    val backgroundBrush = Brush.linearGradient(
        colors = listOf(
            if (isDark) Color(0xFF162238) else Color.White,
            if (isDark) Color(0xFF111B30) else Color(0xFFF8F4FF),
            if (isDark) Color(0xFF0E182A) else Color(0xFFF4F8FF),
        ),
    )
    val borderColor = if (isDark) {
        Color.White.copy(alpha = 0.08f)
    } else {
        Color(0xFFE8E2F5).copy(alpha = 0.92f)
    }

    Box(modifier = Modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(backgroundBrush)
                .border(OriveoBorderWidth.standard, borderColor, shape)
                .clickable(
                    interactionSource = interactionSource,
                    indication = null,
                    role = Role.Button,
                    onClick = onClick,
                )
        ) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .offset(x = 12.dp, y = 10.dp)
                    .size(if (isDark) 120.dp else 144.dp)
                    .background(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                if (isDark) Color(0xFF8C5FF8).copy(alpha = 0.12f) else Color(0xFFC4B5FD).copy(alpha = 0.20f),
                                Color.Transparent,
                            ),
                        ),
                        shape = CircleShape,
                    ),
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 15.dp, vertical = 13.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (hasHeaderContent) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Box(modifier = Modifier.weight(1f)) {
                            HeroHeaderLeadingGroup(
                                items = heroMetaItems,
                            )
                        }
                        Spacer(modifier = Modifier.width(8.dp))
                        HeroSwitchControl(variant = HeroSwitchControlVariant.Regular)
                    }
                }

                Text(
                    text = model.name,
                    style = heroModelTitleTextStyle().copy(color = OriveoTheme.colors.textPrimary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                )

                if (heroCapabilities.isNotEmpty()) {
                    HeroModelCapabilityStrip(
                        capabilities = heroCapabilities,
                        modifier = Modifier.padding(
                            top = if (hasHeaderContent) 2.dp else 4.dp,
                            end = if (!hasHeaderContent) HeroSwitchControlVariant.Compact.reservedWidth + 8.dp else 0.dp,
                        ),
                    )
                } else if (!hasHeaderContent) {
                    Spacer(modifier = Modifier.height(4.dp))
                }
            }
        }

        if (!hasHeaderContent) {
            HeroSwitchControl(
                variant = HeroSwitchControlVariant.Compact,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 14.dp, end = 15.dp),
            )
        }
    }
}

@Composable
private fun HeroHeaderLeadingGroup(
    items: List<HeroInfoItem>,
    modifier: Modifier = Modifier,
) {
    if (items.isEmpty()) return

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        HeroMetaRow(items = items)
    }
}

@Composable
private fun HeroMetaRow(
    items: List<HeroInfoItem>,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items.forEachIndexed { index, item ->
            HeroMetaRowItem(item = item)
            if (index < items.lastIndex) {
                Box(
                    modifier = Modifier
                        .size(3.dp)
                        .clip(CircleShape)
                        .background(OriveoTheme.colors.textTertiary.copy(alpha = 0.55f)),
                )
            }
        }
    }
}

@Composable
private fun HeroInfoPill(item: HeroInfoItem) {
    val colors = OriveoTheme.colors
    val foreground = when (item.tone) {
        HeroInfoPillTone.Primary -> colors.primary.copy(alpha = 0.95f)
        HeroInfoPillTone.Warning -> colors.warning.copy(alpha = 0.90f)
        HeroInfoPillTone.Neutral -> colors.textSecondary.copy(alpha = 0.92f)
    }
    val background = when (item.tone) {
        HeroInfoPillTone.Primary -> colors.primarySoft.copy(alpha = 0.94f)
        HeroInfoPillTone.Warning -> colors.warningSoft.copy(alpha = 0.95f)
        HeroInfoPillTone.Neutral -> if (OriveoTheme.isDark) {
            Color(0xFF0F172A).copy(alpha = 0.34f)
        } else {
            Color.White.copy(alpha = 0.70f)
        }
    }
    val border = when (item.tone) {
        HeroInfoPillTone.Primary -> colors.primary.copy(alpha = 0.24f)
        HeroInfoPillTone.Warning -> colors.warning.copy(alpha = 0.24f)
        HeroInfoPillTone.Neutral -> colors.borderStrong.opacity(0.72f)
    }

    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(background)
            .border(OriveoBorderWidth.standard, border, CircleShape)
            .padding(horizontal = 9.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = item.icon,
            contentDescription = null,
            modifier = Modifier.size(10.5.dp),
            tint = foreground,
        )
        Text(
            text = item.title,
            style = TextStyle(
                fontSize = 11.5.sp,
                lineHeight = 14.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = foreground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun HeroMetaRowItem(item: HeroInfoItem) {
    val iconColor = when (item.tone) {
        HeroInfoPillTone.Primary -> OriveoTheme.colors.primary.copy(alpha = 0.88f)
        HeroInfoPillTone.Warning -> OriveoTheme.colors.warning.copy(alpha = 0.90f)
        HeroInfoPillTone.Neutral -> OriveoTheme.colors.textTertiary.copy(alpha = 0.86f)
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            imageVector = item.icon,
            contentDescription = null,
            modifier = Modifier.size(11.dp),
            tint = iconColor,
        )
        Text(
            text = item.title,
            style = TextStyle(
                fontSize = 12.5.sp,
                lineHeight = 16.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = OriveoTheme.colors.textSecondary.copy(alpha = 0.95f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun HeroSwitchControl(
    variant: HeroSwitchControlVariant,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = CircleShape
    val background = Brush.linearGradient(
        colors = listOf(
            if (isDark) Color(0xFF152038).copy(alpha = 0.78f) else Color.White.copy(alpha = 0.94f),
            if (isDark) Color(0xFF0F172A).copy(alpha = 0.72f) else Color(0xFFF8F4FF).copy(alpha = 0.92f),
        ),
    )
    val border = if (isDark) {
        Color(0xFFC7D2FE).copy(alpha = 0.12f)
    } else {
        Color(0xFFE6E0F3).copy(alpha = 0.88f)
    }
    val shellModifier = modifier
        .clip(shape)
        .background(background)
        .border(OriveoBorderWidth.standard, border, shape)

    if (variant == HeroSwitchControlVariant.Compact) {
        Box(
            modifier = shellModifier.size(30.dp),
            contentAlignment = Alignment.Center,
        ) {
            HeroSwitchGlyph()
        }
    } else {
        Row(
            modifier = shellModifier
                .height(28.dp)
                .padding(start = 8.dp, end = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            HeroSwitchGlyph()
            Text(
                text = stringResource(R.string.switch_label),
                style = TextStyle(
                    fontSize = 11.5.sp,
                    lineHeight = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = colors.textSecondary.copy(alpha = 0.96f),
            )
            Icon(
                imageVector = Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                modifier = Modifier.size(9.dp),
                tint = colors.textTertiary.copy(alpha = 0.84f),
            )
        }
    }
}

@Composable
private fun HeroSwitchGlyph() {
    val isDark = OriveoTheme.isDark

    Box(
        modifier = Modifier
            .size(15.dp)
            .clip(CircleShape)
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        if (isDark) Color(0xFF2A1D57).copy(alpha = 0.94f) else Color(0xFFF5EFFF).copy(alpha = 0.96f),
                        if (isDark) Color(0xFF1B2440).copy(alpha = 0.90f) else Color.White.copy(alpha = 0.96f),
                    ),
                ),
            )
            .border(
                1.dp,
                if (isDark) Color(0xFFC4B5FD).copy(alpha = 0.14f) else Color(0xFFE9DEFF).copy(alpha = 0.92f),
                CircleShape,
            ),
    ) {
        Icon(
            imageVector = Icons.Outlined.SwapHoriz,
            contentDescription = null,
            modifier = Modifier
                .align(Alignment.Center)
                .size(7.5.dp),
            tint = OriveoTheme.colors.primary.copy(alpha = if (isDark) 0.90f else 0.94f),
        )
    }
}

@Composable
private fun HeroPrimaryActionButton(
    text: String,
    onClick: () -> Unit,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val shape = RoundedCornerShape(16.dp)
    val brush = if (OriveoTheme.isDark) {
        Brush.linearGradient(
            colors = if (isPressed) {
                listOf(Color(0xFF5E40D1), Color(0xFF442A9B))
            } else {
                listOf(Color(0xFF6848DC), Color(0xFF4B2FA8))
            },
        )
    } else {
        Brush.linearGradient(
            colors = if (isPressed) {
                listOf(Color(0xFF6A48D9), Color(0xFF4F32B5))
            } else {
                listOf(Color(0xFF7250E3), Color(0xFF5739C2))
            },
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(brush)
            .border(
                1.dp,
                if (OriveoTheme.isDark) Color.White.copy(alpha = 0.10f) else Color.White.copy(alpha = 0.18f),
                shape,
            )
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                role = Role.Button,
                onClick = onClick,
            )
            .height(44.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = TextStyle(
                fontSize = 15.5.sp,
                lineHeight = 18.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = Color.White,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun HomeHeroCard(content: @Composable () -> Unit) {
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(22.dp)
    val baseBrush = Brush.linearGradient(
        colors = listOf(
            if (isDark) Color(0xFF172137) else Color(0xFFFFFDFE),
            if (isDark) Color(0xFF131C30) else Color(0xFFF7F3FF),
            if (isDark) Color(0xFF1A2741) else Color(0xFFF4F8FF),
        ),
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (isDark) 6.dp else 3.dp,
                shape = shape,
                ambientColor = if (isDark) Color.Black.copy(alpha = 0.16f) else Color(0xFF312E81).copy(alpha = 0.06f),
                spotColor = if (isDark) Color.Black.copy(alpha = 0.16f) else Color(0xFF312E81).copy(alpha = 0.06f),
            )
            .clip(shape)
            .background(baseBrush),
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .offset(x = 20.dp, y = (-28).dp)
                .size(180.dp)
                .background(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            if (isDark) Color(0xFF8C5FF8).copy(alpha = 0.14f) else Color(0xFF7C53ED).copy(alpha = 0.18f),
                            Color.Transparent,
                        ),
                    ),
                    shape = CircleShape,
                ),
        )
        Box(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .offset(x = (-12).dp, y = 30.dp)
                .size(140.dp)
                .background(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            if (isDark) Color(0xFF38BDF8).copy(alpha = 0.10f) else Color(0xFFBAE6FD).copy(alpha = 0.16f),
                            Color.Transparent,
                        ),
                    ),
                    shape = CircleShape,
                ),
        )
        Box(
            modifier = Modifier
                .matchParentSize()
                .background(
                    brush = Brush.linearGradient(
                        colors = listOf(
                            if (isDark) Color.White.copy(alpha = 0.06f) else Color.White.copy(alpha = 0.22f),
                            Color.Transparent,
                        ),
                    ),
                ),
        )

        Box(
            modifier = Modifier
                .matchParentSize()
                .drawWithCache {
                    val crPx = 22.dp.toPx()
                    val brush = Brush.sweepGradient(
                        colors = HERO_AURORA_COLORS,
                        center = Offset(size.width / 2f, size.height / 2f),
                    )
                    val outerWidth = 2.4.dp.toPx()
                    val innerWidth = 1.4.dp.toPx()
                    onDrawBehind {

                        strokeHeroRing(brush, outerWidth, crPx, alpha = 0.45f)

                        strokeHeroRing(brush, innerWidth, crPx, alpha = 0.90f)
                    }
                },
        )

        Box(
            modifier = Modifier
                .matchParentSize()
                .padding(1.1.dp)
                .border(
                    0.7.dp,
                    if (isDark) Color.White.copy(alpha = 0.04f) else Color.White.copy(alpha = 0.50f),
                    RoundedCornerShape(20.9.dp),
                ),
        )
        Box(modifier = Modifier.padding(horizontal = 18.dp, vertical = 18.dp)) {
            content()
        }
    }
}

private val HERO_AURORA_COLORS = listOf(
    Color(0xFF8B5CF6),
    Color(0xFFA78BFA),
    Color(0xFFEC8FEA),
    Color(0xFF8DB4FF),
    Color(0xFF86D2E6),
    Color(0xFFC4B5FD),
    Color(0xFF8B5CF6),
)

private fun DrawScope.strokeHeroRing(brush: Brush, strokeWidthPx: Float, cornerRadiusPx: Float, alpha: Float) {
    val inset = strokeWidthPx / 2f
    drawRoundRect(
        brush = brush,
        topLeft = Offset(inset, inset),
        size = Size(size.width - strokeWidthPx, size.height - strokeWidthPx),
        cornerRadius = CornerRadius((cornerRadiusPx - inset).coerceAtLeast(0f)),
        style = Stroke(width = strokeWidthPx),
        alpha = alpha,
    )
}

@Composable
private fun heroModelTitleTextStyle(): TextStyle = OriveoTheme.typography.hero.copy(
    fontSize = 28.sp,
    lineHeight = 34.sp,
    fontWeight = FontWeight.Bold,
    letterSpacing = (-1.2).sp,
)

@Composable
private fun providerStatusText(state: ProviderConnectionState): String = when (state) {
    ProviderConnectionState.Connected -> stringResource(R.string.status_connected)
    ProviderConnectionState.Syncing -> stringResource(R.string.status_syncing)
    is ProviderConnectionState.Issue -> stringResource(R.string.status_issue)
}

private fun prioritizedHeroCapabilities(model: AIModel): List<ModelCapability> {
    val capabilities = model.capabilities.filter { it != ModelCapability.Text }
    val preferred = if (capabilities.isEmpty()) model.capabilities else capabilities
    return preferred.take(3)
}

private fun heroMetaItems(model: AIModel, priceTierLabel: String): List<HeroInfoItem> {
    val items = mutableListOf<HeroInfoItem>()

    heroContextToken(model)?.let { contextToken ->
        items += HeroInfoItem(
            id = "context",
            icon = Icons.Outlined.Layers,
            title = contextToken,
            tone = HeroInfoPillTone.Neutral,
        )
    }

    if (priceTierLabel.isNotEmpty()) {
        items += HeroInfoItem(
            id = "price",
            icon = Icons.Outlined.AttachMoney,
            title = priceTierLabel,
            tone = HeroInfoPillTone.Neutral,
        )
    }

    return items
}

private fun heroContextToken(model: AIModel): String? =
    model.contextLength
        ?.takeIf { it > 0 }
        ?.let(::compactHeroContextLength)
        ?: heroContextToken(model.summary)

private fun heroContextToken(summary: String?): String? =
    heroSummaryTokens(summary).firstNotNullOfOrNull(::extractHeroContextToken)

private fun heroSummaryTokens(summary: String?): List<String> {
    val normalized = summary
        ?.trim()
        ?.replace('\n', ' ')
        ?.takeIf { it.isNotEmpty() }
        ?: return emptyList()

    return normalized
        .split(',', '|', '/', '·')
        .map { it.trim() }
        .filter { it.isNotEmpty() }
}

private fun extractHeroContextToken(token: String): String? {
    val segments = token
        .uppercase()
        .split(Regex("[^A-Z0-9.,]+"))
        .filter { it.isNotEmpty() }

    for (segment in segments) {
        val normalized = segment.replace(",", "")
        val suffix = normalized.lastOrNull()
        if (suffix == 'K' || suffix == 'M') {
            val numberPart = normalized.dropLast(1)
            val value = numberPart.toDoubleOrNull()
            if (value != null && value > 0) {
                val formatted = if (value % 1.0 == 0.0) {
                    value.toInt().toString()
                } else {
                    numberPart
                }
                return "$formatted$suffix"
            }
        }

        normalized.toIntOrNull()
            ?.takeIf { it >= 1_000 }
            ?.let(::compactHeroContextLength)
            ?.let { return it }
    }

    return null
}

private fun compactHeroContextLength(contextLength: Int): String = when {
    contextLength >= 1_000_000 -> "${contextLength / 1_000_000}M"
    contextLength >= 1_000 -> "${contextLength / 1_000}K"
    else -> contextLength.toString()
}
