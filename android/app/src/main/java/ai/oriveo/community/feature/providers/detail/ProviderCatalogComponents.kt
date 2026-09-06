@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.ui.component.ModelListMetadataRow
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.ui.component.ModelVendorIcon
import ai.oriveo.community.ui.component.StatusPill
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.component.normalizedPriceTierLabel
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.component.LocalModelRuntimeLabel
import ai.oriveo.community.ui.theme.opacity

fun LazyListScope.providerCatalogGroups(
    provider: Provider,
    groups: List<ProviderCatalogGroup>,
    searchQuery: String,
    expandedGroups: Set<String>,
    onToggleGroup: (String) -> Unit,
    onEnableModel: (AIModel) -> Unit,
    capabilityObservationRevision: Long,
) {
    val autoExpand = shouldAutoExpandCatalogGroups(searchQuery)
    groups.forEachIndexed { groupIndex, group ->
        val isExpanded = autoExpand || expandedGroups.contains(group.id)
        val hasRows = isExpanded && group.models.isNotEmpty()

        item(key = "group_header_${group.id}", contentType = CatalogHeaderContentType) {
            CatalogGroupHeader(
                group = group,
                isExpanded = isExpanded,
                canToggle = !autoExpand,
                onToggle = { onToggleGroup(group.id) },
                position = if (hasRows) CatalogRowPosition.First else CatalogRowPosition.Single,
                modifier = Modifier.animateItem(),
            )
        }
        if (hasRows) {
            itemsIndexed(
                items = group.models,
                key = { _, model -> "group_${group.id}_model_${model.id}" },
                contentType = { _, _ -> CatalogRowContentType },
            ) { rowIndex, model ->
                val position = if (rowIndex == group.models.lastIndex) {
                    CatalogRowPosition.Last
                } else {
                    CatalogRowPosition.Middle
                }
                CatalogModelRow(
                    provider = provider,
                    model = model,
                    capabilityObservationRevision = capabilityObservationRevision,
                    onEnable = { onEnableModel(model) },
                    position = position,
                    showTopDivider = true,
                )
            }
        }
        if (groupIndex < groups.lastIndex) {
            item(key = "group_spacer_${group.id}", contentType = CatalogSpacerContentType) {
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
            }
        }
    }
}

private const val CatalogHeaderContentType = "catalog_header"
private const val CatalogRowContentType = "catalog_row"
private const val CatalogSpacerContentType = "catalog_spacer"

internal enum class CatalogRowPosition { Single, First, Middle, Last }

internal fun Modifier.catalogRowSurface(
    surface: Color,
    border: Color,
    position: CatalogRowPosition,
    radius: Dp,
    borderWidth: Dp,
): Modifier {
    val shape: Shape = when (position) {
        CatalogRowPosition.Single -> RoundedCornerShape(radius)
        CatalogRowPosition.First -> RoundedCornerShape(
            topStart = radius,
            topEnd = radius,
            bottomStart = 0.dp,
            bottomEnd = 0.dp,
        )
        CatalogRowPosition.Last -> RoundedCornerShape(
            topStart = 0.dp,
            topEnd = 0.dp,
            bottomStart = radius,
            bottomEnd = radius,
        )
        CatalogRowPosition.Middle -> RoundedCornerShape(0.dp)
    }
    return this
        .clip(shape)
        .background(surface, shape)
        .then(
            when (position) {
                CatalogRowPosition.Single,
                CatalogRowPosition.First,
                CatalogRowPosition.Last -> Modifier.border(borderWidth, border, shape)
                CatalogRowPosition.Middle -> Modifier.drawBehind {
                    val strokePx = borderWidth.toPx()
                    drawRect(
                        color = border,
                        topLeft = Offset.Zero,
                        size = Size(strokePx, size.height),
                    )
                    drawRect(
                        color = border,
                        topLeft = Offset(size.width - strokePx, 0f),
                        size = Size(strokePx, size.height),
                    )
                }
            },
        )
}

@Composable
private fun CatalogGroupHeader(
    group: ProviderCatalogGroup,
    isExpanded: Boolean,
    canToggle: Boolean,
    onToggle: () -> Unit,
    position: CatalogRowPosition,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing

    Row(
        modifier = modifier
            .fillMaxWidth()
            .catalogRowSurface(
                surface = colors.surfaceElevated,
                border = colors.border.opacity(0.66f),
                position = position,
                radius = OriveoTheme.radius.lg,
                borderWidth = OriveoBorderWidth.standard,
            )
            .background(
                if (isExpanded) colors.surfaceInset.copy(alpha = 0.55f) else Color.Transparent,
            )
            .clickable(enabled = canToggle, onClick = onToggle)
            .padding(horizontal = spacing.md, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ModelVendorIcon(
            groupKey = group.id,
            groupName = group.title,
            size = 36.dp,
        )
        Spacer(modifier = Modifier.width(spacing.md))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = group.title,
                style = OriveoTheme.typography.title3.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = stringResource(R.string.provider_detail_n_models, group.models.size),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(colors.surfaceInset.copy(alpha = 0.55f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (isExpanded) Icons.Filled.ExpandMore else Icons.Filled.ChevronRight,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun CatalogModelRow(
    provider: Provider,
    model: AIModel,
    capabilityObservationRevision: Long,
    onEnable: () -> Unit,
    position: CatalogRowPosition,
    showTopDivider: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing

    val dividerColor = colors.border.opacity(0.45f)

    Row(
        modifier = modifier
            .fillMaxWidth()
            .catalogRowSurface(
                surface = colors.surfaceElevated,
                border = colors.border.opacity(0.66f),
                position = position,
                radius = OriveoTheme.radius.lg,
                borderWidth = OriveoBorderWidth.standard,
            )
            .drawWithContent {
                drawContent()
                if (showTopDivider) {
                    val strokePx = 1.dp.toPx()

                    val insetPx = spacing.md.toPx()
                    drawRect(
                        color = dividerColor,
                        topLeft = Offset(insetPx, 0f),
                        size = Size(size.width - insetPx, strokePx),
                    )
                }
            }

            .heightIn(min = 62.dp)
            .then(if (model.isAvailable) Modifier.clickable(onClick = onEnable) else Modifier)
            .padding(horizontal = spacing.md, vertical = 10.dp)
            .alpha(if (model.isAvailable) 1f else 0.6f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spacing.md),
    ) {

        val hasSpecs = modelSpecifications(model).isNotEmpty()
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = model.name,
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            LocalModelRuntimeLabel(model)
            val metadataModel = remember(provider, model, capabilityObservationRevision) {
                model.copy(
                    capabilities = CapabilityEvidenceProductionAdapter
                        .governedMetadataCapabilities(provider, model)
                        .toList(),
                )
            }
            ModelListMetadataRow(
                model = metadataModel,
                modifier = Modifier.fillMaxWidth(),
                compact = true,
                showPrice = false,
            )

            if (hasSpecs) {
                ModelSpecInline(model = model)
            }
        }

        if (!hasSpecs) {
            val priceTier = model.normalizedPriceTierLabel()
            if (priceTier.isNotBlank()) {
                Text(
                    text = priceTier,
                    style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.Medium),
                    color = colors.textTertiary,
                    maxLines = 1,
                )
            }
        }

        if (model.isAvailable) {
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .clip(CircleShape)
                    .background(colors.primarySoft)
                    .border(1.dp, colors.primary.copy(alpha = 0.16f), CircleShape)
                    .clickable(onClick = onEnable),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = stringResource(R.string.add),
                    modifier = Modifier.size(12.dp),
                    tint = colors.primary,
                )
            }
        } else {
            StatusPill(
                text = stringResource(R.string.status_unavailable),
                tone = StatusTone.Warning,
            )
        }
    }
}
