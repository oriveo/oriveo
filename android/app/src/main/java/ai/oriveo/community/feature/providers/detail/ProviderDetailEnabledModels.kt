package ai.oriveo.community.feature.providers.detail

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.provider.ModelPricingFormatter
import ai.oriveo.community.ui.component.HeroModelCapabilityStrip
import ai.oriveo.community.ui.component.MODEL_ROW_MAX_CAPABILITIES
import ai.oriveo.community.ui.component.localizedPriceTier
import ai.oriveo.community.ui.component.visibleMetadataCapabilities
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.component.LocalModelRuntimeLabel
import ai.oriveo.community.ui.theme.opacity
import org.koin.compose.koinInject

fun LazyListScope.providerDetailEnabledModels(
    provider: Provider,
    titleRes: Int,
    capabilityObservationRevision: Long,
    sortedModels: List<AIModel>,
    highlightedModelID: String?,
    onToggleModel: (AIModel) -> Unit,
    /** null = the model row menu on this page offers no "Set as default" (relay / local: the default model is changed only in the model card on the detail page). */
    onSetDefault: ((AIModel) -> Unit)?,
    onStartChat: (AIModel) -> Unit,
    /**
     * Membership index of the confirmed relay catalog; null means the catalog is unconfirmed or
     * failed to load, so no model may be reported as gone from it.
     *
     * An index rather than the catalog itself: each row used to run
     * `ModelSelectionUtils.matchingModel(wholeCatalog, model.id)` during composition, an O(catalog)
     * scan that, on a miss, runs two regexes and several string allocations for every catalog
     * model. A relay catalog comes from the user's own server and can hold thousands of entries,
     * and that cost was paid for every row composed while scrolling. The caller remembers the
     * index once; the verdict is exactly the one matchingModel gave.
     */
    confirmedRelayCatalogIndex: Set<String>? = null,
    /** Tapping an enabled relay / local row opens the "Model > Advanced" page; capability testing and restoring automatic both live on that page. */
    onOpenAdvanced: (AIModel) -> Unit = {},
    /** The enabled section of the relay / local model library; null = an official provider, behavior and appearance unchanged. */
    relayBoard: RelayCatalogEnabledSection? = null,
) {
    // When the model library is filtered by protocol both sections are filtered: rows come from the board model, while the removal threshold still counts all enabled models.
    val rowModels = relayBoard?.rows?.map { it.model } ?: sortedModels
    val boardRows = relayBoard?.rows?.associateBy { it.model.id }

    item(key = "enabled_models_header") {
        ProviderDetailSectionHeader(
            modifier = Modifier.padding(bottom = OriveoTheme.spacing.md),
            title = relayBoard?.let { stringResource(it.titleRes, it.count) } ?: stringResource(titleRes),
            trailing = if (relayBoard == null) {
                pluralStringResource(R.plurals.provider_detail_n_models, provider.enabledModelCount, provider.enabledModelCount)
            } else {
                null
            },
            helpMessage = stringResource(R.string.enabled_models_help),
        )
    }

    // After filtering, an empty section simply shows no rows; the "no models yet" empty state is only for when truly none are enabled.
    if (sortedModels.isEmpty()) {
        item(key = "enabled_models_empty") {
            EmptyModelsPanel(provider = provider)
        }
    } else {
        val canRemove = (provider.kind.isAggregatedProvider || provider.kind == ProviderKind.Relay) &&
            sortedModels.size > 1
        itemsIndexed(
            items = rowModels,
            key = { _, model -> "enabled_model_${model.id}" },

            contentType = { _, _ -> EnabledModelRowContentType },
        ) { index, model ->
            val colors = OriveoTheme.colors
            val position = enabledModelRowPosition(index = index, lastIndex = rowModels.lastIndex)
            // A relay has no default model, so no default badge is shown.
            val isDefault = provider.kind != ProviderKind.Relay && provider.defaultModel?.id == model.id
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(enabledModelsCardShadow(position = position, isDark = OriveoTheme.isDark))
                    .enabledModelsRowSurface(
                        surface = colors.surfaceElevated,
                        borderColor = colors.border.opacity(0.72f),
                        position = position,
                    ),
            ) {
                EnabledModelRow(
                    provider = provider,
                    model = model,
                    capabilityObservationRevision = capabilityObservationRevision,
                    isMissingFromConfirmedCatalog = RelayCatalogBoardModel.isMissingFromConfirmedCatalog(
                        provider,
                        model,
                        confirmedRelayCatalogIndex,
                    ),
                    boardRow = boardRows?.get(model.id),
                    isDefault = isDefault,
                    isHighlighted = highlightedModelID == model.id,
                    canSetDefault = onSetDefault != null && !isDefault,
                    canRemove = canRemove,
                    onStartChat = { onStartChat(model) },
                    onSetDefault = { onSetDefault?.invoke(model) },
                    onToggle = { onToggleModel(model) },
                    onOpenAdvanced = { onOpenAdvanced(model) },
                )
                if (position == CatalogRowPosition.First || position == CatalogRowPosition.Middle) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 14.dp)
                            .height(0.5.dp)
                            .background(colors.border.opacity(0.45f)),
                    )
                }
            }
        }
    }

    item(key = "enabled_models_bottom_spacer") {
        Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
    }
}

private const val EnabledModelRowContentType = "enabled_model_row"

private val EnabledModelsCardRadius = 16.dp
private val EnabledModelsCardBorderWidth = 1.dp
private val EnabledModelsCardElevation = 12.dp

private val EnabledModelsShadowInset = 24.dp

private fun enabledModelRowPosition(index: Int, lastIndex: Int): CatalogRowPosition = when {
    lastIndex == 0 -> CatalogRowPosition.Single
    index == 0 -> CatalogRowPosition.First
    index == lastIndex -> CatalogRowPosition.Last
    else -> CatalogRowPosition.Middle
}

private fun Modifier.enabledModelsRowSurface(
    surface: Color,
    borderColor: Color,
    position: CatalogRowPosition,
): Modifier = this
    .clip(enabledModelsRowShape(position))
    .background(surface)
    .drawWithContent {
        drawContent()
        val strokePx = EnabledModelsCardBorderWidth.toPx()
        val radiusPx = EnabledModelsCardRadius.toPx()
        val overshoot = radiusPx + strokePx
        val roundedTop = position == CatalogRowPosition.Single || position == CatalogRowPosition.First
        val roundedBottom = position == CatalogRowPosition.Single || position == CatalogRowPosition.Last
        val top = if (roundedTop) strokePx / 2f else -overshoot
        val bottom = if (roundedBottom) size.height - strokePx / 2f else size.height + overshoot
        drawRoundRect(
            color = borderColor,
            topLeft = Offset(strokePx / 2f, top),
            size = Size(size.width - strokePx, bottom - top),
            cornerRadius = CornerRadius(radiusPx, radiusPx),
            style = Stroke(strokePx),
        )
    }

private fun enabledModelsRowShape(position: CatalogRowPosition): Shape = when (position) {
    CatalogRowPosition.Single -> RoundedCornerShape(EnabledModelsCardRadius)
    CatalogRowPosition.First -> RoundedCornerShape(
        topStart = EnabledModelsCardRadius,
        topEnd = EnabledModelsCardRadius,
        bottomStart = 0.dp,
        bottomEnd = 0.dp,
    )
    CatalogRowPosition.Last -> RoundedCornerShape(
        topStart = 0.dp,
        topEnd = 0.dp,
        bottomStart = EnabledModelsCardRadius,
        bottomEnd = EnabledModelsCardRadius,
    )
    CatalogRowPosition.Middle -> RoundedCornerShape(0.dp)
}

private fun enabledModelsCardShadow(position: CatalogRowPosition, isDark: Boolean): Modifier {
    if (position == CatalogRowPosition.Middle) return Modifier
    val shadowColor = Color.Black.copy(alpha = if (isDark) 0.45f else 0.55f)
    return Modifier.shadow(
        elevation = EnabledModelsCardElevation,
        shape = EnabledModelsCardShadowShape(position),
        clip = false,
        ambientColor = shadowColor,
        spotColor = shadowColor,
    )
}

private data class EnabledModelsCardShadowShape(val position: CatalogRowPosition) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val radiusPx = with(density) { EnabledModelsCardRadius.toPx() }
        val insetPx = with(density) { EnabledModelsShadowInset.toPx() }.coerceAtMost(size.height / 2f)
        val roundedTop = position != CatalogRowPosition.Last
        val roundedBottom = position != CatalogRowPosition.First
        val corner = CornerRadius(radiusPx, radiusPx)
        val topCorner = if (roundedTop) corner else CornerRadius.Zero
        val bottomCorner = if (roundedBottom) corner else CornerRadius.Zero
        return Outline.Rounded(
            RoundRect(
                left = 0f,
                top = if (roundedTop) 0f else insetPx,
                right = size.width,
                bottom = size.height,
                topLeftCornerRadius = topCorner,
                topRightCornerRadius = topCorner,
                bottomLeftCornerRadius = bottomCorner,
                bottomRightCornerRadius = bottomCorner,
            ),
        )
    }
}

@Composable
private fun EmptyModelsPanel(provider: Provider) {
    val colors = OriveoTheme.colors
    val text = if (provider.kind == ProviderKind.Relay) {
        stringResource(R.string.provider_detail_relay_empty_description)
    } else {
        stringResource(R.string.no_added_models_yet)
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(colors.surfaceElevated)
            .border(1.dp, colors.border.opacity(0.72f), RoundedCornerShape(16.dp))
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.xl),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = OriveoTheme.typography.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun EnabledModelRow(
    provider: Provider,
    model: AIModel,
    capabilityObservationRevision: Long,
    isMissingFromConfirmedCatalog: Boolean = false,
    isDefault: Boolean,
    isHighlighted: Boolean,
    canSetDefault: Boolean,
    canRemove: Boolean,
    onStartChat: () -> Unit,
    onSetDefault: () -> Unit,
    onToggle: () -> Unit,
    onOpenAdvanced: () -> Unit = {},
    /** Row structure of the relay / local model library; when non-null the row tap, the trailing area and the menu are rendered from it alone. */
    boardRow: RelayCatalogRow? = null,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    // Official row overflow menu: set as default / remove; a board row menu comes from boardRow.menu (remove only).
    val menuItems = RelayModelAdvancedBoard.enabledRowActions(canSetDefault, canRemove).menu
    val hasMenu = if (boardRow != null) RelayCatalogTrailing.More in boardRow.trailing else menuItems.isNotEmpty()
    var showMenu by remember { mutableStateOf(false) }

    val highlightTint by animateColorAsState(
        targetValue = if (isHighlighted) {
            colors.primary.copy(alpha = if (isDark) 0.12f else 0.07f)
        } else {
            Color.Transparent
        },
        animationSpec = tween(220),
        label = "enabledRowHighlight",
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(highlightTint),
    ) {

        // Enabled row: left column | status text (board rows) | chat / overflow, all vertically centered. (whole-row vertical centering)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = 14.dp,
                    end = 10.dp,
                    top = 12.dp,
                    bottom = 12.dp,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (boardRow != null) {
                // Board row: name / chips + five capabilities; the status text sits in the trailing column (next to the chat button); a row tap is dispatched by tapTarget only (an unavailable model can still open Advanced).
                RelayCatalogRowBody(
                    row = boardRow,
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable {
                            when (RelayCatalogBoardModel.rowTap(model.id, boardRow.tapTarget, enabledRow = true)) {
                                is RelayCatalogRowTap.OpenAdvanced -> onOpenAdvanced()
                                RelayCatalogRowTap.StartChat -> if (model.isAvailable) onStartChat()
                                RelayCatalogRowTap.Enable -> Unit
                            }
                        }
                        .alpha(if (model.isAvailable) 1f else 0.72f),
                )
            } else {
            // Title area: takes the full width, weight(1f) keeps a short title aligned left; tap = new chat
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(enabled = model.isAvailable, onClick = onStartChat)
                    .alpha(if (model.isAvailable) 1f else 0.72f),
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = model.name,
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )
                    if (isMissingFromConfirmedCatalog) {
                        Text(
                            text = stringResource(R.string.relay_model_missing_from_catalog),
                            style = OriveoTheme.typography.footnote,
                            color = colors.textTertiary,
                        )
                    }
                    LocalModelRuntimeLabel(model)
                    EnabledModelMetadataRow(
                        provider = provider,
                        model = model,
                        capabilityObservationRevision = capabilityObservationRevision,
                    )
                    ModelSpecInline(model = model)
                }
            }

            if (!hasDetailedSpecifications(model)) {
                EnabledModelPriceLabel(model = model)
            }
            }

            if (boardRow != null) RelayCatalogRowStatusText(boardRow)

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (boardRow == null) {
                    EnabledRowChatButton(available = model.isAvailable, onClick = onStartChat)
                } else if (RelayCatalogTrailing.NewChat in boardRow.trailing) {
                    // "New chat" uses the same icon in the same position as an official enabled row.
                    EnabledRowChatButton(
                        available = model.isAvailable,
                        onClick = onStartChat,
                        contentDescription = stringResource(R.string.new_chat),
                    )
                }

                if (hasMenu) {
                    Box {

                        Box(
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape)
                                .background(
                                    color = colors.surfaceInset.opacity(0.6f),
                                    shape = CircleShape,
                                )
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                    onClick = { showMenu = true },
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Filled.MoreVert,
                                contentDescription = if (boardRow != null) stringResource(R.string.advanced_more) else null,
                                modifier = Modifier.size(14.dp),
                                tint = colors.textSecondary,
                            )
                        }

                        if (showMenu) {
                            DropdownMenu(
                                expanded = true,
                                onDismissRequest = { showMenu = false },
                            ) {
                                if (boardRow != null) {
                                    // A board row menu has only "Remove"; with one model left it is greyed out and shows a reason line.
                                    boardRow.menu.forEach { item ->
                                        DropdownMenuItem(
                                            text = {
                                                Text(
                                                    stringResource(R.string.remove),
                                                    color = if (item.enabled) colors.danger else colors.textTertiary,
                                                )
                                            },
                                            onClick = {
                                                showMenu = false
                                                onToggle()
                                            },
                                            enabled = item.enabled,
                                            leadingIcon = {
                                                Icon(
                                                    Icons.Outlined.Delete,
                                                    contentDescription = null,
                                                    tint = if (item.enabled) colors.danger else colors.textTertiary,
                                                )
                                            },
                                        )
                                        item.disabledReasonRes?.let { reason ->
                                            Text(
                                                text = stringResource(reason),
                                                style = OriveoTheme.typography.footnote,
                                                color = colors.textSecondary,
                                                modifier = Modifier
                                                    .widthIn(max = 260.dp)
                                                    .padding(horizontal = 16.dp, vertical = 6.dp),
                                            )
                                        }
                                    }
                                } else if (RelayEnabledRowMenuItem.SetDefault in menuItems) {
                                    DropdownMenuItem(
                                        text = { Text(stringResource(R.string.set_as_default)) },
                                        onClick = {
                                            showMenu = false
                                            onSetDefault()
                                        },
                                        leadingIcon = {
                                            Icon(Icons.Filled.Star, contentDescription = null)
                                        },
                                    )
                                }
                                if (boardRow == null && RelayEnabledRowMenuItem.Remove in menuItems) {
                                    DropdownMenuItem(
                                        text = {
                                            Text(
                                                stringResource(R.string.remove),
                                                color = colors.danger,
                                            )
                                        },
                                        onClick = {
                                            showMenu = false
                                            onToggle()
                                        },
                                        leadingIcon = {
                                            Icon(
                                                Icons.Outlined.Delete,
                                                contentDescription = null,
                                                tint = colors.danger,
                                            )
                                        },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The round chat button at the end of an enabled row: official rows and relay board rows share the same "new chat" icon and drawing. */
@Composable
private fun EnabledRowChatButton(
    available: Boolean,
    onClick: () -> Unit,
    contentDescription: String? = null,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    // Explicit indication = null, so the default ripple is not drawn against the rectangular layout bounds after
    // .clip(CircleShape) (in dark mode that looks like an extra strip next to the round background). The background is
    // bound to CircleShape directly; the shape is guaranteed by the background itself and does not rely on the outline of a preceding clip.
    Box(
        modifier = modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(
                color = if (available) colors.primarySoft else colors.surfaceInset.copy(alpha = 0.6f),
                shape = CircleShape,
            )
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                enabled = available,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Forum,
            contentDescription = contentDescription,
            modifier = Modifier.size(13.dp),
            tint = if (available) colors.primary else colors.textTertiary,
        )
    }
}

internal data class EnabledModelSpecification(
    val labelRes: Int?,
    val value: String,
    val showsContextIcon: Boolean = false,

    val isSecondary: Boolean = false,
)

@Composable
internal fun ModelSpecInline(model: AIModel) {
    val specifications = remember(model) { modelSpecifications(model) }
    if (specifications.isEmpty()) return

    val primary = specifications.filter { !it.isSecondary }
    val secondary = specifications.filter { it.isSecondary }

    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        if (primary.isNotEmpty()) {
            SpecLine(items = primary)
        }
        if (secondary.isNotEmpty()) {
            SpecLine(items = secondary)
        }
    }
}

private val SpecLabelStyle = TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium)
private val SpecValueStyle = TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.SemiBold)

@Composable
private fun SpecLine(items: List<EnabledModelSpecification>) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEachIndexed { index, spec ->
            if (index > 0) {
                Text(
                    text = "  ·  ",
                    style = SpecLabelStyle,
                    color = colors.textTertiary.opacity(0.7f),
                    maxLines = 1,
                )
            }
            if (spec.showsContextIcon) {
                Icon(
                    imageVector = Icons.Outlined.Memory,
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                    tint = colors.textTertiary,
                )
                Spacer(modifier = Modifier.width(3.dp))
            }
            spec.labelRes?.let { labelRes ->
                Text(
                    text = stringResource(labelRes) + " ",
                    style = SpecLabelStyle,
                    color = colors.textTertiary,
                    maxLines = 1,
                )
            }
            Text(
                text = spec.value,
                style = SpecValueStyle,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private fun hasDetailedSpecifications(model: AIModel): Boolean = modelSpecifications(model).isNotEmpty()

internal fun modelSpecifications(model: AIModel): List<EnabledModelSpecification> = buildList {
    compactTokenCount(model.contextLength)?.let {
        add(EnabledModelSpecification(labelRes = null, value = it, showsContextIcon = true))
    }
    perMillionPriceFromPerToken(model.promptPrice)?.let {
        add(EnabledModelSpecification(R.string.price_input, it))
    }
    perMillionPriceFromPerToken(model.completionPrice)?.let {
        add(EnabledModelSpecification(R.string.price_output, it))
    }
    perMillionPriceFromPerMillion(model.cacheReadInputPerMToken)?.let {
        add(EnabledModelSpecification(R.string.price_cache_read, it, isSecondary = true))
    }
    val cacheWrite = model.cacheWrite5mPerMToken ?: model.cacheCreationInputPerMToken
    perMillionPriceFromPerMillion(cacheWrite)?.let {
        add(EnabledModelSpecification(R.string.price_cache_write, it, isSecondary = true))
    }
}

private fun compactTokenCount(tokens: Int?): String? {
    val value = tokens?.takeIf { it > 0 } ?: return null
    return when {
        value >= 1_000_000 -> "${value / 1_000_000}M"
        value >= 1_000 -> "${value / 1_000}K"
        else -> value.toString()
    }
}

private fun perMillionPriceFromPerToken(price: Double?): String? {
    val value = price?.takeIf { it.isFinite() && it > 0 } ?: return null
    return ModelPricingFormatter.formatPerMillionValue(value)?.takeIf(String::isNotEmpty)
}

private fun perMillionPriceFromPerMillion(price: Double?): String? {
    val value = price?.takeIf { it.isFinite() && it > 0 } ?: return null
    return ModelPricingFormatter.formatPerMillionValue(value / 1_000_000.0)?.takeIf(String::isNotEmpty)
}

@Composable
private fun EnabledModelMetadataRow(
    provider: Provider,
    model: AIModel,
    capabilityObservationRevision: Long,
) {
    val providerRepository: ProviderRepository = koinInject()
    val toolCallMemoryStore: ToolCallMemoryStore = koinInject()
    val toolCallMemoryRevision by toolCallMemoryStore.revision.collectAsStateWithLifecycle()
    val memoryVerdict = remember(provider, model, toolCallMemoryRevision) {
        providerRepository.toolCallMemoryVerdict(provider, model)
    }

    val visibleCapabilities = remember(provider, model, capabilityObservationRevision, memoryVerdict) {
        model.copy(
        capabilities = CapabilityEvidenceProductionAdapter
            .governedMetadataCapabilities(provider, model)
            .toList(),
        ).visibleMetadataCapabilities(
            // Same limit as the iOS added-models row and the model picker row (3, with web / imageGen reserved).
            maxCapabilities = MODEL_ROW_MAX_CAPABILITIES,
            modelFactsToolCall = CapabilityEvidenceProductionAdapter.toolCallVerdict(
                provider,
                model,
                memoryVerdict = memoryVerdict,
            ),
        )
    }

    if (visibleCapabilities.isEmpty()) return
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        HeroModelCapabilityStrip(capabilities = visibleCapabilities, compact = true)
    }
}

@Composable
private fun EnabledModelPriceLabel(model: AIModel) {
    val colors = OriveoTheme.colors

    val priceText = localizedPriceTier(model.priceTier.trim()).ifBlank {
        ModelPricingFormatter.formatPerMillion(
            promptPrice = model.promptPrice,
            completionPrice = model.completionPrice,
        )
    }
    if (priceText.isBlank()) return
    Text(
        text = priceText,
        style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
        color = colors.textTertiary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        textAlign = TextAlign.End,
        modifier = Modifier.width(52.dp),
    )
}
