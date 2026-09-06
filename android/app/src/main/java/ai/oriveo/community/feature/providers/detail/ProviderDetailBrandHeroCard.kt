package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import ai.oriveo.community.ui.component.rememberBrandPainter
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderEffectiveStatusKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.effectiveStatusKind
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.model.resolveProviderLogoKind
import ai.oriveo.community.feature.providers.blendedWith
import ai.oriveo.community.feature.providers.hsbAdjusted
import ai.oriveo.community.ui.component.OriveoStatusDot
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.brandWatermarkIcon
import ai.oriveo.community.ui.component.providerLogoRes
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.ProviderBadgeColors
import ai.oriveo.community.ui.util.formatRelativeTime

internal fun shouldShowHeroApiKeyEditor(provider: Provider): Boolean =
    provider.kind.allowsCredentialEditing &&
        (provider.kind != ProviderKind.Relay || provider.relayRequested.requiresCredential)

internal fun shouldShowResidualCredentialRemoval(provider: Provider): Boolean =
    provider.kind == ProviderKind.Relay &&
        !provider.relayRequested.requiresCredential &&
        hasStoredCredential(provider.apiKey)

@Composable
fun ProviderDetailBrandHeroCard(
    provider: Provider,
    enabledModelCount: Int,
    onStartChat: () -> Unit,
    onResync: () -> Unit,
    onEditApiKey: () -> Unit,
    onRemoveResidualApiKey: (() -> Unit)? = null,
    onEditName: (() -> Unit)?,
    modifier: Modifier = Modifier,

    isResyncing: Boolean = false,
) {

    val resolvedLogoKind = remember(
        provider.kind,
        provider.relayKind,
        provider.baseUrlText,
        provider.displayName,
        provider.models,
    ) { resolveProviderLogoKind(provider) }
    val resolvedRelayKind = remember(provider.kind, provider.relayKind, resolvedLogoKind) {
        if (provider.kind == ProviderKind.Relay && resolvedLogoKind == ProviderKind.Relay) {
            provider.relayKind
        } else {
            null
        }
    }
    val brandColor = if (resolvedLogoKind == ProviderKind.Relay) {
        OriveoTheme.colors.primary
    } else {
        ProviderBadgeColors.usageBreakdown(resolvedLogoKind)
    }

    val subduedBrand = remember(brandColor, resolvedLogoKind) {
        if (resolvedLogoKind == ProviderKind.Grok) {
            Color(0xFF2E3036)
        } else {
            brandColor.hsbAdjusted(saturation = 0.62f, brightness = 0.88f)
        }
    }
    val pressedBrand = remember(subduedBrand) { subduedBrand.hsbAdjusted(saturation = 0.85f, brightness = 0.55f) }

    val effective = provider.effectiveStatusKind
    val canStartChat = provider.defaultModel != null
    val isSyncing = isResyncing || provider.status is ProviderConnectionState.Syncing

    Box(
        modifier = modifier
            .fillMaxWidth()
            .shadow(
                elevation = 12.dp,
                shape = RoundedCornerShape(24.dp),
                ambientColor = Color.Black.copy(alpha = 0.16f),
                spotColor = Color.Black.copy(alpha = 0.16f),
            )
            .clip(RoundedCornerShape(24.dp))
            .heroBrandBackground(subduedBrand)
            .border(0.6.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(24.dp)),
    ) {

        HeroWatermark(logoKind = resolvedLogoKind)

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            HeroTopRow(
                logoKind = resolvedLogoKind,
                relayKind = resolvedRelayKind,
                effective = effective,
                statusTitle = heroStatusTitle(effective, provider.status),
                statusPulsing = isSyncing,
            )

            HeroNameAndMeta(
                name = provider.displayName,
                enabledModelCount = enabledModelCount,
                syncedText = provider.lastCheckedAt?.let(::formatRelativeTime) ?: stringResource(R.string.never),
                onEditName = onEditName,
            )

            if (shouldShowHeroApiKeyEditor(provider)) {
                HeroApiKeyRow(
                    provider = provider,
                    effective = effective,
                    onClick = onEditApiKey,
                )
            } else if (shouldShowResidualCredentialRemoval(provider) && onRemoveResidualApiKey != null) {
                Text(
                    text = stringResource(R.string.relay_remove_api_key),
                    modifier = Modifier
                        .align(Alignment.End)
                        .clip(CircleShape)
                        .clickable(onClick = onRemoveResidualApiKey)
                        .padding(horizontal = 10.dp, vertical = 7.dp),
                    style = OriveoTheme.typography.footnote,
                    color = Color.White.copy(alpha = 0.85f),
                )
            }

            HeroActions(
                canStartChat = canStartChat,
                isRelay = provider.kind == ProviderKind.Relay,
                isSyncing = isSyncing,
                pressedBrand = pressedBrand,
                onStartChat = onStartChat,
                onResync = onResync,
            )
        }
    }
}

@Composable
private fun heroStatusTitle(
    effective: ProviderEffectiveStatusKind,
    status: ProviderConnectionState,
): String = when (effective) {
    ProviderEffectiveStatusKind.NeedsKey -> stringResource(R.string.needs_api_key)
    ProviderEffectiveStatusKind.Connected -> stringResource(R.string.status_connected)
    ProviderEffectiveStatusKind.Syncing -> stringResource(R.string.status_syncing)
    ProviderEffectiveStatusKind.Issue -> stringResource(R.string.status_issue)
}

@Composable
private fun heroStatusColor(effective: ProviderEffectiveStatusKind): Color = when (effective) {
    ProviderEffectiveStatusKind.Connected -> OriveoTheme.colors.success

    ProviderEffectiveStatusKind.Syncing -> Color.White
    ProviderEffectiveStatusKind.Issue, ProviderEffectiveStatusKind.NeedsKey ->
        OriveoTheme.colors.warning
}

private fun Modifier.heroBrandBackground(subduedBrand: Color): Modifier {
    val start = subduedBrand.blendedWith(Color.White, 0.06f)
    val end = subduedBrand.blendedWith(Color.Black, 0.22f)
    return this
        .background(Brush.linearGradient(colors = listOf(start, end)))
        .drawBehind {

            drawRect(
                brush = Brush.radialGradient(
                    colors = listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0f)),
                    center = androidx.compose.ui.geometry.Offset(size.width * 0.92f, size.height * -0.05f),
                    radius = 280f.coerceAtLeast(size.minDimension * 0.7f),
                ),
            )

            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.18f)),
                    startY = size.height * 0.5f,
                    endY = size.height,
                ),
            )

            drawRect(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0f),
                        Color.White.copy(alpha = 0.06f),
                        Color.White.copy(alpha = 0f),
                    ),
                    start = androidx.compose.ui.geometry.Offset(size.width * 0.2f, size.height * -0.1f),
                    end = androidx.compose.ui.geometry.Offset(size.width * 0.4f, size.height * 1.2f),
                ),
            )
        }
}

@Composable
private fun HeroWatermark(logoKind: ProviderKind) {

    val watermarkSymbol = logoKind.brandWatermarkIcon()

    Box(modifier = Modifier.fillMaxSize()) {
        if (watermarkSymbol != null) {
            Icon(
                imageVector = watermarkSymbol,
                contentDescription = null,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(164.dp)
                    .offset(x = 50.dp, y = 40.dp),
                tint = Color.White.copy(alpha = 0.10f),
            )
        } else {
            Image(
                painter = rememberBrandPainter(providerLogoRes(logoKind), 200.dp),
                contentDescription = null,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(200.dp)
                    .offset(x = 50.dp, y = 40.dp)
                    .alpha(0.10f),
                contentScale = ContentScale.Fit,
                colorFilter = ColorFilter.tint(Color.White),
            )
        }
    }
}

@Composable
private fun HeroTopRow(
    logoKind: ProviderKind,
    relayKind: ai.oriveo.community.core.model.RelayKind?,
    effective: ProviderEffectiveStatusKind,
    statusTitle: String,
    statusPulsing: Boolean,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {

        ProviderBadgeIcon(
            kind = logoKind,
            size = 35.dp,
            relayKind = relayKind,
            forceDarkAppearance = true,
            contentScaleOverride = 1f,
        )
        Spacer(modifier = Modifier.weight(1f))
        HeroStatusCapsule(
            statusColor = heroStatusColor(effective),
            statusTitle = statusTitle,
            statusPulsing = statusPulsing,
        )
    }
}

@Composable
private fun HeroStatusCapsule(
    statusColor: Color,
    statusTitle: String,
    statusPulsing: Boolean,
) {
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.22f))
            .border(0.6.dp, Color.White.copy(alpha = 0.30f), CircleShape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        OriveoStatusDot(color = statusColor, size = 6.dp, pulsing = statusPulsing)
        Text(
            text = statusTitle,
            style = TextStyle(fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold),
            color = Color.White,
            maxLines = 1,
        )
    }
}

@Composable
private fun HeroNameAndMeta(
    name: String,
    enabledModelCount: Int,
    syncedText: String,
    onEditName: (() -> Unit)?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = name,
                style = TextStyle(
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = (-0.4).sp,
                    lineHeight = 32.sp,
                    platformStyle = PlatformTextStyle(includeFontPadding = false),
                    lineHeightStyle = LineHeightStyle(
                        alignment = LineHeightStyle.Alignment.Center,
                        trim = LineHeightStyle.Trim.Both,
                    ),
                ),
                color = Color.White,

                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (onEditName != null) {
                Box(
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .clickable(onClick = onEditName),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Edit,
                        contentDescription = stringResource(R.string.edit),
                        modifier = Modifier.size(13.dp),
                        tint = Color.White.copy(alpha = 0.62f),
                    )
                }
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = stringResource(R.string.provider_detail_available_models, enabledModelCount),
                style = TextStyle(fontSize = 12.5.sp, fontWeight = FontWeight.Medium),
                color = Color.White.copy(alpha = 0.78f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Box(
                modifier = Modifier
                    .size(3.5.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.45f)),
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.History,
                    contentDescription = null,
                    modifier = Modifier.size(11.dp),
                    tint = Color.White.copy(alpha = 0.72f),
                )
                Text(
                    text = syncedText,
                    style = TextStyle(fontSize = 12.5.sp, fontWeight = FontWeight.Medium),
                    color = Color.White.copy(alpha = 0.72f),
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun HeroApiKeyRow(
    provider: Provider,
    effective: ProviderEffectiveStatusKind,
    onClick: () -> Unit,
) {

    val isSubscription = provider.authMode == ProviderAuthMode.Subscription
    val displayValue = if (isSubscription) {

        if (provider.kind == ProviderKind.OpenAI) {
            stringResource(R.string.provider_credential_subscription_value_openai)
        } else {
            stringResource(R.string.provider_credential_subscription_value)
        }
    } else {
        heroApiKeyDisplayValue(provider, effective)
    }
    val isMissingMask = !isSubscription && provider.apiKeyPreview.isEmpty()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.18f))
            .border(0.5.dp, Color.White.copy(alpha = 0.22f), CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.22f))
                .border(0.6.dp, Color.White.copy(alpha = 0.30f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (isSubscription) Icons.Filled.VerifiedUser else Icons.Filled.Key,
                contentDescription = null,
                modifier = Modifier.size(13.dp),
                tint = Color.White,
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = if (isSubscription) {
                    stringResource(R.string.provider_credential_subscription_label).uppercase()
                } else {
                    stringResource(R.string.api_key).uppercase()
                },
                style = TextStyle(
                    fontSize = 10.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 0.6.sp,
                ),
                color = Color.White.copy(alpha = 0.62f),
                maxLines = 1,
            )
            Text(
                text = displayValue,
                style = TextStyle(
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = if (isSubscription) FontFamily.Default else FontFamily.Monospace,
                ),
                color = if (isMissingMask) Color.White.copy(alpha = 0.78f) else Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            modifier = Modifier.size(13.dp),
            tint = Color.White.copy(alpha = 0.55f),
        )
    }
}

@Composable
private fun heroApiKeyDisplayValue(
    provider: Provider,
    effective: ProviderEffectiveStatusKind,
): String {

    if (effective == ProviderEffectiveStatusKind.NeedsKey) return stringResource(R.string.tap_to_set)
    val preview = provider.apiKeyPreview
    if (preview.isNotEmpty()) return preview

    return when (provider.status) {
        is ProviderConnectionState.Connected, is ProviderConnectionState.Syncing ->
            stringResource(R.string.tap_to_view)
        is ProviderConnectionState.Issue ->
            stringResource(R.string.tap_to_set)
    }
}

@Composable
private fun HeroActions(
    canStartChat: Boolean,
    isRelay: Boolean,
    isSyncing: Boolean,
    pressedBrand: Color,
    onStartChat: () -> Unit,
    onResync: () -> Unit,
) {
    val showsPrimary = canStartChat || !isRelay
    val showsSecondary = !isRelay && canStartChat
    if (!showsPrimary && !showsSecondary) return

    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {

        val needsStack = showsPrimary && showsSecondary && maxWidth < 225.dp ||
            !(showsPrimary && showsSecondary) && maxWidth < 140.dp

        val primary: @Composable (Modifier) -> Unit = { mod ->
            HeroPrimaryButton(
                text = if (canStartChat) {
                    stringResource(R.string.new_chat)
                } else if (isSyncing) {
                    stringResource(R.string.status_syncing)
                } else {
                    stringResource(R.string.verify_connection)
                },
                icon = if (canStartChat) Icons.Filled.Add else Icons.Filled.Refresh,
                pressedBrand = pressedBrand,
                enabled = !isSyncing,
                onClick = if (canStartChat) onStartChat else onResync,
                modifier = mod,
            )
        }
        val secondary: @Composable (Modifier) -> Unit = { mod ->
            HeroSecondaryButton(
                text = if (isSyncing) stringResource(R.string.status_syncing)
                else stringResource(R.string.verify_connection),
                enabled = !isSyncing,
                onClick = onResync,
                modifier = mod,
            )
        }

        if (needsStack) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (showsPrimary) primary(Modifier.fillMaxWidth())
                if (showsSecondary) secondary(Modifier.fillMaxWidth())
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (showsPrimary && showsSecondary) {
                    primary(Modifier.weight(1f))
                    secondary(Modifier.weight(1f))
                } else if (showsPrimary) {
                    primary(Modifier.fillMaxWidth())
                } else if (showsSecondary) {
                    secondary(Modifier.fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun HeroPrimaryButton(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    pressedBrand: Color,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current
    Box(
        modifier = modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.96f))
            .border(0.5.dp, Color.White.copy(alpha = 0.42f), RoundedCornerShape(14.dp))
            .alpha(if (enabled) 1f else 0.7f)
            .clickable(enabled = enabled) {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onClick()
            }
            .padding(vertical = 13.dp, horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = pressedBrand,
            )
            Text(
                text = text,
                style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                color = pressedBrand,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun HeroSecondaryButton(
    text: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current
    Box(
        modifier = modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.20f))
            .border(0.5.dp, Color.White.copy(alpha = 0.28f), RoundedCornerShape(14.dp))
            .alpha(if (enabled) 1f else 0.7f)
            .clickable(enabled = enabled) {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onClick()
            }
            .padding(vertical = 13.dp, horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Refresh,
                contentDescription = null,
                modifier = Modifier.size(13.dp),
                tint = Color.White.copy(alpha = 0.95f),
            )
            Text(
                text = text,
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = Color.White.copy(alpha = 0.95f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
