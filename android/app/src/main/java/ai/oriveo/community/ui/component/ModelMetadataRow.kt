package ai.oriveo.community.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.res.stringResource
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
import ai.oriveo.community.core.provider.ModelPricingFormatter
import ai.oriveo.community.ui.theme.OriveoTheme

data class HeroIconGradient(
    val start: Color,
    val end: Color,
)

data class HeroIconTextItem(
    val id: String,
    val title: String,
    val icon: ImageVector,
    val gradient: HeroIconGradient,
    val shadowColor: Color,
)

private data class HeroIconTextStripSize(
    val itemSpacing: Dp,
    val rowSpacing: Dp,
    val iconDiameter: Dp,
    val iconSize: Dp,
    val textStyle: TextStyle,
)

private val RegularHeroIconTextStripSize = HeroIconTextStripSize(
    itemSpacing = 6.dp,
    rowSpacing = 10.5.dp,
    iconDiameter = 16.dp,
    iconSize = 7.5.dp,
    textStyle = TextStyle(
        fontSize = 12.sp,
        lineHeight = 16.sp,
        fontWeight = FontWeight.Medium,
    ),
)

private val CompactHeroIconTextStripSize = HeroIconTextStripSize(
    itemSpacing = 5.dp,
    rowSpacing = 9.dp,
    iconDiameter = 14.dp,
    iconSize = 6.6.dp,
    textStyle = TextStyle(
        fontSize = 11.sp,
        lineHeight = 14.sp,
        fontWeight = FontWeight.Medium,
    ),
)

@Composable
fun HeroIconTextStrip(
    items: List<HeroIconTextItem>,
    modifier: Modifier = Modifier,
    maximumVisibleItems: Int = 3,
    compact: Boolean = false,
    iconOnly: Boolean = false,
) {
    val visibleItems = items.take(maximumVisibleItems)
    if (visibleItems.isEmpty()) return

    val choices = buildList<@Composable () -> Unit> {
        add { HeroIconTextCandidateRow(items = visibleItems, compact = compact, iconOnly = iconOnly) }
        if (visibleItems.size > 2) {
            add { HeroIconTextCandidateRow(items = visibleItems.take(2), compact = compact, iconOnly = iconOnly) }
        }
        visibleItems.firstOrNull()?.let { firstItem ->
            add { HeroIconTextCandidateRow(items = listOf(firstItem), compact = compact, iconOnly = iconOnly) }
        }
    }

    FirstFitLayout(
        modifier = modifier,
        choices = choices,
    )
}

@Composable
fun HeroModelCapabilityStrip(
    capabilities: List<ModelCapability>,
    modifier: Modifier = Modifier,
    maximumVisibleItems: Int = 3,
    compact: Boolean = false,
    iconOnly: Boolean = false,
) {
    val visibleCapabilities = capabilities
        .filter(ModelCapability::isVisibleMetadataCapability)
        .take(maximumVisibleItems)
    if (visibleCapabilities.isEmpty()) return

    HeroIconTextStrip(
        items = visibleCapabilities.map { capability -> capability.toHeroIconTextItem() },
        modifier = modifier,
        maximumVisibleItems = maximumVisibleItems,
        compact = compact,
        iconOnly = iconOnly,
    )
}

/** Fixed-content variant for dense rows that already cap their visible metadata. */
@Composable
fun FixedHeroModelCapabilityStrip(
    capabilities: List<ModelCapability>,
    modifier: Modifier = Modifier,
    maximumVisibleItems: Int = 3,
    compact: Boolean = false,
    iconOnly: Boolean = false,
) {
    val visibleCapabilities = capabilities
        .filter(ModelCapability::isVisibleMetadataCapability)
        .take(maximumVisibleItems)
    if (visibleCapabilities.isEmpty()) return

    HeroIconTextCandidateRow(
        items = visibleCapabilities.map { capability -> capability.toHeroIconTextItem() },
        modifier = modifier,
        compact = compact,
        iconOnly = iconOnly,
    )
}

@Composable
fun ModelMetadataRow(
    model: AIModel,
    modifier: Modifier = Modifier,
    maxCapabilities: Int = 3,
    prominentPrice: Boolean = false,
    compact: Boolean = false,
) {
    ModelMetadataInlineStrip(
        model = model,
        modifier = modifier,
        maxCapabilities = maxCapabilities,
        prominentPrice = prominentPrice,
        compact = compact,
    )
}

@Composable
fun ModelMetadataInlineStrip(
    model: AIModel,
    modifier: Modifier = Modifier,
    maxCapabilities: Int = 3,
    prominentPrice: Boolean = false,
    compact: Boolean = false,
) {
    val priceTier = model.normalizedPriceTierLabel()
    val capabilities = model.visibleMetadataCapabilities(maxCapabilities)

    if (priceTier.isBlank() && capabilities.isEmpty()) return

    val capabilityCountCandidates = buildList {
        add(capabilities.size)
        if (capabilities.isNotEmpty()) {
            add(minOf(capabilities.size, maxOf(1, maxCapabilities - 1)))
            add(1)
        }
    }.distinct()

    val rowCandidates = if (priceTier.isBlank()) {
        capabilityCountCandidates.map { capabilityCount -> capabilityCount to false }
    } else {
        capabilityCountCandidates.map { capabilityCount -> capabilityCount to true }
    }

    SubcomposeLayout(modifier = modifier) { constraints ->
        val probeConstraints = Constraints(
            minWidth = 0,
            minHeight = 0,
            maxWidth = Constraints.Infinity,
            maxHeight = if (constraints.hasBoundedHeight) constraints.maxHeight else Constraints.Infinity,
        )

        val selectedIndex = rowCandidates.indexOfFirst { (capabilityCount, includePrice) ->
            val placeable = subcompose("metadata_inline_probe_$capabilityCount$includePrice") {
                ModelMetadataInlineCandidateRow(
                    priceTier = priceTier,
                    capabilities = capabilities.take(capabilityCount),
                    includePrice = includePrice,
                    prominentPrice = prominentPrice,
                    compact = compact,
                )
            }.single().measure(probeConstraints)

            !constraints.hasBoundedWidth || placeable.width <= constraints.maxWidth
        }.takeIf { it >= 0 } ?: rowCandidates.lastIndex

        val (selectedCapabilityCount, selectedIncludePrice) = rowCandidates[selectedIndex]
        val selectedPlaceable = subcompose("metadata_inline_selected") {
            ModelMetadataInlineCandidateRow(
                priceTier = priceTier,
                capabilities = capabilities.take(selectedCapabilityCount),
                includePrice = selectedIncludePrice,
                prominentPrice = prominentPrice,
                compact = compact,
            )
        }.single().measure(
            constraints.copy(
                minWidth = 0,
                minHeight = 0,
            ),
        )

        val layoutWidth = if (constraints.hasBoundedWidth) {
            selectedPlaceable.width.coerceIn(constraints.minWidth, constraints.maxWidth)
        } else {
            selectedPlaceable.width.coerceAtLeast(constraints.minWidth)
        }

        layout(
            width = layoutWidth,
            height = selectedPlaceable.height.coerceAtLeast(constraints.minHeight),
        ) {
            selectedPlaceable.placeRelative(0, 0)
        }
    }
}

@Composable
fun ModelListMetadataRow(
    model: AIModel,
    modifier: Modifier = Modifier,
    maxCapabilities: Int = 3,
    prominentPrice: Boolean = false,
    compact: Boolean = false,
    iconOnly: Boolean = false,
    showPrice: Boolean = true,
    statusText: String? = null,
    statusTone: StatusTone = StatusTone.Primary,
) {
    val priceTier = model.normalizedPriceTierLabel()
    val capabilities = model.visibleMetadataCapabilities(maxCapabilities)
    val includePrice = showPrice && priceTier.isNotBlank()

    if (statusText == null && !includePrice && capabilities.isEmpty()) return

    val rowCandidates = buildList {
        add(capabilities.size to includePrice)
        if (includePrice && capabilities.size > 2) {
            add(2 to true)
        }
        if (includePrice && capabilities.isNotEmpty()) {
            add(1 to true)
        }
        if (capabilities.isNotEmpty()) {
            add(capabilities.size to false)
        }
        if (statusText != null) {
            add(0 to false)
        }
        if (includePrice) {
            add(0 to true)
        }
    }.distinct()

    SubcomposeLayout(modifier = modifier) { constraints ->
        val probeConstraints = Constraints(
            minWidth = 0,
            minHeight = 0,
            maxWidth = Constraints.Infinity,
            maxHeight = if (constraints.hasBoundedHeight) constraints.maxHeight else Constraints.Infinity,
        )

        val selectedIndex = rowCandidates.indexOfFirst { (capabilityCount, includePrice) ->
            val placeable = subcompose("metadata_list_probe_$capabilityCount$includePrice") {
                ModelListMetadataCandidateRow(
                    priceTier = priceTier,
                    capabilities = capabilities.take(capabilityCount),
                    includePrice = includePrice,
                    prominentPrice = prominentPrice,
                    compact = compact,
                    iconOnly = iconOnly,
                    statusText = statusText,
                    statusTone = statusTone,
                )
            }.single().measure(probeConstraints)

            !constraints.hasBoundedWidth || placeable.width <= constraints.maxWidth
        }.takeIf { it >= 0 } ?: rowCandidates.lastIndex

        val (selectedCapabilityCount, selectedIncludePrice) = rowCandidates[selectedIndex]
        val selectedPlaceable = subcompose("metadata_list_selected") {
            ModelListMetadataCandidateRow(
                priceTier = priceTier,
                capabilities = capabilities.take(selectedCapabilityCount),
                includePrice = selectedIncludePrice,
                prominentPrice = prominentPrice,
                compact = compact,
                statusText = statusText,
                statusTone = statusTone,
            )
        }.single().measure(constraints.copy(minHeight = 0))

        val layoutWidth = if (constraints.hasBoundedWidth) {
            selectedPlaceable.width.coerceIn(constraints.minWidth, constraints.maxWidth)
        } else {
            selectedPlaceable.width.coerceAtLeast(constraints.minWidth)
        }

        layout(
            width = layoutWidth,
            height = selectedPlaceable.height.coerceAtLeast(constraints.minHeight),
        ) {
            selectedPlaceable.placeRelative(0, 0)
        }
    }
}

@Composable
private fun HeroIconTextCandidateRow(
    items: List<HeroIconTextItem>,
    modifier: Modifier = Modifier,
    compact: Boolean,
    iconOnly: Boolean = false,
) {
    val size = if (compact) CompactHeroIconTextStripSize else RegularHeroIconTextStripSize

    Row(
        modifier = modifier
            .wrapContentWidth()
            .wrapContentHeight(),
        horizontalArrangement = Arrangement.spacedBy(if (iconOnly) 5.dp else size.rowSpacing),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEach { item ->
            HeroIconTextLabel(
                item = item,
                compact = compact,
                iconOnly = iconOnly,
            )
        }
    }
}

@Composable
internal fun HeroIconTextLabel(
    item: HeroIconTextItem,
    compact: Boolean,
    iconOnly: Boolean = false,
) {
    val size = if (compact) CompactHeroIconTextStripSize else RegularHeroIconTextStripSize

    Row(
        modifier = Modifier
            .wrapContentWidth()
            .wrapContentHeight(),
        horizontalArrangement = Arrangement.spacedBy(if (iconOnly) 0.dp else size.itemSpacing),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .shadow(3.5.dp, CircleShape, ambientColor = item.shadowColor, spotColor = item.shadowColor)
                .size(size.iconDiameter)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(
                        listOf(item.gradient.start, item.gradient.end),
                    ),
                )
                .border(
                    0.7.dp,
                    if (OriveoTheme.isDark) Color.White.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.30f),
                    CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = item.icon,
                contentDescription = null,
                modifier = Modifier.size(size.iconSize),

                tint = Color.White,
            )
        }

        if (!iconOnly) {
            Text(
                text = item.title,
                style = size.textStyle,
                color = OriveoTheme.colors.textSecondary.copy(alpha = 0.94f),
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Clip,
            )
        }
    }
}

@Composable
private fun ModelMetadataInlineCandidateRow(
    priceTier: String,
    capabilities: List<ModelCapability>,
    includePrice: Boolean,
    prominentPrice: Boolean,
    compact: Boolean,
) {
    Row(
        modifier = Modifier
            .wrapContentWidth()
            .wrapContentHeight(),
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (includePrice && priceTier.isNotBlank()) {
            MetadataPriceLabel(
                priceTier = priceTier,
                prominentPrice = prominentPrice,
                compact = compact,
            )
        }

        if (capabilities.isNotEmpty()) {
            HeroModelCapabilityStrip(
                capabilities = capabilities,
                compact = compact,
            )
        }
    }
}

@Composable
private fun ModelListMetadataCandidateRow(
    priceTier: String,
    capabilities: List<ModelCapability>,
    includePrice: Boolean,
    prominentPrice: Boolean,
    compact: Boolean,
    iconOnly: Boolean = false,
    statusText: String?,
    statusTone: StatusTone,
) {
    val rowSpacing = if (compact) 8.dp else OriveoTheme.spacing.sm
    val priceGap = if (compact) 8.dp else 12.dp

    Layout(
        modifier = Modifier,
        content = {
            if (statusText != null) {
                StatusPill(
                    text = statusText,
                    tone = statusTone,
                    compact = true,
                )
            }
            if (capabilities.isNotEmpty()) {
                HeroModelCapabilityStrip(
                    capabilities = capabilities,
                    compact = compact,
                    iconOnly = iconOnly,
                )
            }
            if (includePrice && priceTier.isNotBlank()) {
                MetadataPriceLabel(
                    priceTier = priceTier,
                    prominentPrice = prominentPrice,
                    compact = compact,
                )
            }
        },
    ) { measurables, constraints ->
        val probeConstraints = Constraints(
            minWidth = 0,
            minHeight = 0,
            maxWidth = Constraints.Infinity,
            maxHeight = if (constraints.hasBoundedHeight) constraints.maxHeight else Constraints.Infinity,
        )
        var measurableIndex = 0

        val statusPlaceable = if (statusText != null) {
            measurables[measurableIndex++].measure(probeConstraints)
        } else {
            null
        }
        val capabilityPlaceable = if (capabilities.isNotEmpty()) {
            measurables[measurableIndex++].measure(probeConstraints)
        } else {
            null
        }
        val pricePlaceable = if (includePrice && priceTier.isNotBlank()) {
            measurables[measurableIndex].measure(probeConstraints)
        } else {
            null
        }

        val rowSpacingPx = rowSpacing.roundToPx()
        val priceGapPx = priceGap.roundToPx()

        var leadingWidth = 0
        if (statusPlaceable != null) {
            leadingWidth += statusPlaceable.width
        }
        if (statusPlaceable != null && capabilityPlaceable != null) {
            leadingWidth += rowSpacingPx
        }
        if (capabilityPlaceable != null) {
            leadingWidth += capabilityPlaceable.width
        }

        val naturalWidth = leadingWidth + when {
            pricePlaceable == null -> 0
            statusPlaceable == null && capabilityPlaceable == null -> pricePlaceable.width
            else -> priceGapPx + pricePlaceable.width
        }
        val naturalHeight = listOfNotNull(statusPlaceable, capabilityPlaceable, pricePlaceable)
            .maxOfOrNull { it.height }
            ?.coerceAtLeast(constraints.minHeight)
            ?: constraints.minHeight

        val layoutWidth = if (constraints.hasBoundedWidth) {
            naturalWidth.coerceIn(constraints.minWidth, constraints.maxWidth)
        } else {
            naturalWidth.coerceAtLeast(constraints.minWidth)
        }

        layout(layoutWidth, naturalHeight) {
            var x = 0

            statusPlaceable?.let { placeable ->
                placeable.placeRelative(x, (naturalHeight - placeable.height) / 2)
                x += placeable.width
            }

            capabilityPlaceable?.let { placeable ->
                if (statusPlaceable != null) {
                    x += rowSpacingPx
                }
                placeable.placeRelative(x, (naturalHeight - placeable.height) / 2)
                x += placeable.width
            }

            pricePlaceable?.let { placeable ->
                val priceX = if (statusPlaceable == null && capabilityPlaceable == null) {
                    0
                } else {
                    maxOf(x + priceGapPx, layoutWidth - placeable.width)
                }
                placeable.placeRelative(priceX, (naturalHeight - placeable.height) / 2)
            }
        }
    }
}

@Composable
private fun MetadataPriceLabel(
    priceTier: String,
    prominentPrice: Boolean,
    compact: Boolean,
) {
    Text(
        text = priceTier,
        style = if (compact) {
            OriveoTheme.typography.caption.copy(fontWeight = FontWeight.Medium)
        } else {
            OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium)
        },
        color = if (prominentPrice) OriveoTheme.colors.primary else OriveoTheme.colors.textTertiary,
        maxLines = 1,
        softWrap = false,
        overflow = TextOverflow.Clip,
    )
}

@Composable
private fun FirstFitLayout(
    modifier: Modifier = Modifier,
    choices: List<@Composable () -> Unit>,
) {
    if (choices.isEmpty()) return

    SubcomposeLayout(modifier = modifier) { constraints ->
        var chosenPlaceables = emptyList<androidx.compose.ui.layout.Placeable>()
        var chosenWidth = 0
        var chosenHeight = 0
        val probeConstraints = Constraints(
            minWidth = 0,
            minHeight = 0,
            maxWidth = Constraints.Infinity,
            maxHeight = if (constraints.hasBoundedHeight) constraints.maxHeight else Constraints.Infinity,
        )

        for ((index, choice) in choices.withIndex()) {
            val placeables = subcompose(index) {
                Box { choice() }
            }.map { measurable ->
                measurable.measure(probeConstraints)
            }
            val width = placeables.maxOfOrNull { it.width } ?: 0
            val height = placeables.maxOfOrNull { it.height } ?: 0

            if (!constraints.hasBoundedWidth || width <= constraints.maxWidth || index == choices.lastIndex) {
                chosenPlaceables = placeables
                chosenWidth = width
                chosenHeight = height
                break
            }
        }

        val layoutWidth = if (constraints.hasBoundedWidth) {
            chosenWidth.coerceIn(constraints.minWidth, constraints.maxWidth)
        } else {
            chosenWidth.coerceAtLeast(constraints.minWidth)
        }
        val layoutHeight = chosenHeight.coerceAtLeast(constraints.minHeight)

        layout(layoutWidth, layoutHeight) {
            chosenPlaceables.forEach { placeable ->
                placeable.placeRelative(0, 0)
            }
        }
    }
}

@Composable
private fun ModelCapability.toHeroIconTextItem(): HeroIconTextItem = when (this) {
    ModelCapability.Reasoning -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = if (OriveoTheme.isDark) {
            HeroIconGradient(Color(0xFFF6C24B), Color(0xFFD97706))
        } else {
            HeroIconGradient(Color(0xFFF0A11F), Color(0xFFC66312))
        },
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.12f) else Color(0xFFC66312).copy(alpha = 0.14f),
    )
    ModelCapability.Text -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = HeroIconGradient(Color(0xFF94A3B8), Color(0xFF64748B)),
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.10f) else Color(0xFF475569).copy(alpha = 0.10f),
    )
    ModelCapability.Image -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = if (OriveoTheme.isDark) {
            HeroIconGradient(Color(0xFFF472B6), Color(0xFFDB2777))
        } else {
            HeroIconGradient(Color(0xFFF06292), Color(0xFFD946EF))
        },
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.12f) else Color(0xFFDB2777).copy(alpha = 0.14f),
    )
    ModelCapability.Video -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = if (OriveoTheme.isDark) {
            HeroIconGradient(Color(0xFF60A5FA), Color(0xFF2563EB))
        } else {
            HeroIconGradient(Color(0xFF38BDF8), Color(0xFF2563EB))
        },
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.12f) else Color(0xFF2563EB).copy(alpha = 0.14f),
    )
    ModelCapability.File -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = if (OriveoTheme.isDark) {
            HeroIconGradient(Color(0xFF818CF8), Color(0xFF4F46E5))
        } else {
            HeroIconGradient(Color(0xFF7C7CF9), Color(0xFF4F46E5))
        },
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.12f) else Color(0xFF4338CA).copy(alpha = 0.14f),
    )
    ModelCapability.Web -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = if (OriveoTheme.isDark) {
            HeroIconGradient(Color(0xFF2DD4BF), Color(0xFF0F766E))
        } else {
            HeroIconGradient(Color(0xFF2DC7B4), Color(0xFF0891B2))
        },
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.12f) else Color(0xFF0F766E).copy(alpha = 0.14f),
    )
    ModelCapability.ImageGen -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = if (OriveoTheme.isDark) {
            HeroIconGradient(Color(0xFFA78BFA), Color(0xFF7C3AED))
        } else {
            HeroIconGradient(Color(0xFF9B6BFF), Color(0xFF6D28D9))
        },
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.12f) else Color(0xFF6D28D9).copy(alpha = 0.14f),
    )
    ModelCapability.ToolCall -> HeroIconTextItem(
        id = name,
        title = stringResource(titleResId),
        icon = capabilityIcon(this),
        gradient = if (OriveoTheme.isDark) {
            HeroIconGradient(Color(0xFF67E8F9), Color(0xFF0E7490))
        } else {
            HeroIconGradient(Color(0xFF22D3EE), Color(0xFF0E7490))
        },
        shadowColor = if (OriveoTheme.isDark) Color.Black.copy(alpha = 0.12f) else Color(0xFF0E7490).copy(alpha = 0.14f),
    )

    ModelCapability.NativePdf, ModelCapability.Unknown -> HeroIconTextItem(
        id = name,
        title = "",
        icon = capabilityIcon(this),
        gradient = HeroIconGradient(Color.Transparent, Color.Transparent),
        shadowColor = Color.Transparent,
    )
}

internal fun AIModel.normalizedPriceTier(): String {
    val explicitTier = priceTier.trim()
    if (explicitTier.isNotEmpty()) {
        return explicitTier
    }

    if (pricingUnit != "per_token" && costPerUnit != null) {
        return "Non-standard billing"
    }

    val perTokenTier = ModelPricingFormatter.formatPerMillion(
        promptPrice = promptPrice,
        completionPrice = completionPrice,
    )
    if (perTokenTier.isNotBlank()) {
        return perTokenTier
    }

    if (promptPrice == null && completionPrice == null && pricingUnit == "per_token") {
        return "Price unknown"
    }

    return ""
}

@Composable
internal fun localizedPriceTier(tier: String): String = when (tier) {
    "Price unknown" -> stringResource(R.string.price_unknown)
    "Non-standard billing" -> stringResource(R.string.pricing_non_standard)
    "Free" -> stringResource(R.string.pricing_free)
    else -> tier
}

@Composable
internal fun AIModel.normalizedPriceTierLabel(): String {
    val explicitTier = priceTier.trim()
    if (explicitTier.isNotEmpty()) {

        return localizedPriceTier(explicitTier)
    }

    if (pricingUnit != "per_token" && costPerUnit != null) {
        return stringResource(R.string.pricing_non_standard)
    }

    val perTokenTier = ModelPricingFormatter.formatPerMillion(
        promptPrice = promptPrice,
        completionPrice = completionPrice,
    )
    if (perTokenTier.isNotBlank()) {
        return perTokenTier
    }

    if (promptPrice == null && completionPrice == null && pricingUnit == "per_token") {
        return stringResource(R.string.price_unknown)
    }

    return ""
}

internal fun AIModel.visibleMetadataCapabilities(
    maxCapabilities: Int,
    modelFactsToolCall: Boolean? = null,
): List<ModelCapability> {
    if (maxCapabilities <= 0) return emptyList()
    val displayable = buildList {
        addAll(capabilities.filter(ModelCapability::isVisibleMetadataCapability))
        if ((toolCall ?: modelFactsToolCall) == true && ModelCapability.ToolCall !in this) {
            add(ModelCapability.ToolCall)
        }
    }
    val mustShow = listOf(ModelCapability.Web, ModelCapability.ImageGen, ModelCapability.ToolCall)
        .filter { it in displayable }
    if (displayable.size > maxCapabilities && mustShow.isNotEmpty()) {
        val regularSlots = maxOf(0, maxCapabilities - mustShow.size)
        return (displayable.filter { it !in mustShow }.take(regularSlots) + mustShow)
            .take(maxCapabilities)
    }
    return displayable.take(maxCapabilities)
}

private fun ModelCapability.isVisibleMetadataCapability(): Boolean =
    this != ModelCapability.Text &&
        this != ModelCapability.NativePdf &&
        this != ModelCapability.Unknown
