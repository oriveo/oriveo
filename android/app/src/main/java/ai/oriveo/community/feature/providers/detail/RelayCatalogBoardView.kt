package ai.oriveo.community.feature.providers.detail

import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAvatar
import ai.oriveo.community.core.model.RelayAvatarResolver
import ai.oriveo.community.feature.providers.relay.SetupDot
import ai.oriveo.community.feature.providers.relay.relayProtocolColor
import ai.oriveo.community.ui.component.StatusPill
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.theme.CapabilityPalette
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

/** Capability icon: supported = duotone + the capability color; unknown = monochrome gray at 60%; unsupported = monochrome strong border color (the same tokens on all three platforms). */
private data class CapabilityGlyph(@DrawableRes val regular: Int, @DrawableRes val duotone: Int)

private fun glyph(capability: RelayCatalogCapability): CapabilityGlyph = when (capability) {
    RelayCatalogCapability.Image -> CapabilityGlyph(R.drawable.ph_eye, R.drawable.ph_eye_duotone)
    RelayCatalogCapability.File -> CapabilityGlyph(R.drawable.ph_paperclip, R.drawable.ph_paperclip_duotone)
    RelayCatalogCapability.Thinking -> CapabilityGlyph(R.drawable.ph_brain, R.drawable.ph_brain_duotone)
    RelayCatalogCapability.Tool -> CapabilityGlyph(R.drawable.ph_wrench, R.drawable.ph_wrench_duotone)
    RelayCatalogCapability.Web -> CapabilityGlyph(R.drawable.ph_globe, R.drawable.ph_globe_duotone)
}

@Composable
private fun capabilityColor(capability: RelayCatalogCapability): Color = when (capability) {
    RelayCatalogCapability.Image -> CapabilityPalette.vision
    RelayCatalogCapability.File -> CapabilityPalette.attachment
    RelayCatalogCapability.Thinking -> CapabilityPalette.reasoning
    RelayCatalogCapability.Tool -> CapabilityPalette.tools
    RelayCatalogCapability.Web -> CapabilityPalette.webSearch
}

@Composable
private fun unknownTint(): Color = OriveoTheme.colors.textSecondary.opacity(0.6f)

@Composable
private fun unsupportedTint(): Color = OriveoTheme.colors.borderStrong

@Composable
private fun RelayCatalogCapabilityIcons(caps: List<RelayCatalogCapabilityState>) {
    // The five icons are hidden from screen readers; the capability screen reader value hangs on the row-level merged node.
    Row(
        modifier = Modifier.clearAndSetSemantics {},
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RelayCatalogCapability.entries.forEachIndexed { index, capability ->
            val state = caps.getOrNull(index) ?: RelayCatalogCapabilityState.Unknown
            val glyph = glyph(capability)
            Icon(
                painter = painterResource(if (state == RelayCatalogCapabilityState.Supported) glyph.duotone else glyph.regular),
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = when (state) {
                    RelayCatalogCapabilityState.Supported -> capabilityColor(capability)
                    RelayCatalogCapabilityState.Unknown -> unknownTint()
                    RelayCatalogCapabilityState.Unsupported -> unsupportedTint()
                },
            )
        }
    }
}

/** Chips of the second row (iOS order: protocol, then key); the component and the layout check both read this single pure function. */
internal sealed interface RelayCatalogRowChip {
    data class Protocol(val protocol: RelayBoardProtocol) : RelayCatalogRowChip
    data class Key(val text: String) : RelayCatalogRowChip
}

internal object RelayCatalogRowChips {
    fun of(row: RelayCatalogRow): List<RelayCatalogRowChip> = listOfNotNull(
        row.protocol?.let { RelayCatalogRowChip.Protocol(it) },
        row.keyChip?.let { RelayCatalogRowChip.Key(it) },
    )
}

/**
 * Row body (shared by enabled rows and catalog rows, iOS RelayCatalogRowContent): the name takes the first line alone (may wrap);
 * the second row has the chips (protocol, then key) + the five capability icons, and the icons drop to a third row when they do not fit. The status text is not here; see [RelayCatalogRowStatusText] (trailing column).
 * The vendor icon, specifications and price tier are dropped.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun RelayCatalogRowBody(row: RelayCatalogRow, modifier: Modifier = Modifier) {
    // The row-level merged node (the caller's clickable node) reads "model name, capability name state word, ...".
    val context = LocalContext.current
    val readout = RelayCatalogBoardModel.rowReadoutText(row.model.name, row.readout) { context.getString(it) }
    val chips = RelayCatalogRowChips.of(row)
    Column(modifier = modifier.semantics { contentDescription = readout }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = row.model.name,
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
            color = OriveoTheme.colors.textPrimary,
        )
        // Chips flow and wrap one by one: a key chip that does not fit wraps whole to the next line and is not squeezed by the status column into "key ...".
        if (chips.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                chips.forEach { chip -> RelayCatalogChip(chip) }
            }
        }
        // The capability icons always take the line below the chips on their own.
        RelayCatalogCapabilityIcons(row.caps)
    }
}

/** iOS chip: capsule, 8 / 3, caption.medium, surfaceInset 0.8; a key name is middle-truncated only when it exceeds the whole column width. */
@Composable
private fun RelayCatalogChip(chip: RelayCatalogRowChip) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(colors.surfaceInset.opacity(0.8f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        val style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.Medium)
        when (chip) {
            is RelayCatalogRowChip.Protocol -> {
                SetupDot(relayProtocolColor(chip.protocol))
                // Protocol legend names are literals and are not translated (same as the add page / the detail page root address row).
                Text(text = chip.protocol.legend, style = style, color = colors.textSecondary, maxLines = 1)
            }
            is RelayCatalogRowChip.Key -> {
                Icon(
                    painter = painterResource(R.drawable.ph_key),
                    contentDescription = null,
                    modifier = Modifier.size(11.dp),
                    tint = colors.textSecondary,
                )
                Text(
                    text = chip.text,
                    style = style,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                )
            }
        }
    }
}

/** Status text of the trailing column (right before the chat button on enabled rows, before the plus on catalog rows): maximum width 84, caption, wrapping allowed. */
@Composable
internal fun RelayCatalogRowStatusText(row: RelayCatalogRow) {
    val colors = OriveoTheme.colors
    row.status?.let { status ->
        // "Unreachable · View reason" is tappable and shows the failure reason.
        var showsReason by remember(row.model.id) { mutableStateOf(false) }
        val failure = row.unreachable
        Text(
            text = stringResource(status.textRes),
            style = OriveoTheme.typography.caption,
            color = when (status) {
                RelayCatalogRowStatus.DeniedOnCurrentKey, RelayCatalogRowStatus.Unreachable -> colors.warningText
                else -> colors.textSecondary
            },
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
            modifier = Modifier
                .widthIn(max = 84.dp)
                .then(
                    if (failure != null) {
                        Modifier
                            .clickable { showsReason = true }
                    } else {
                        Modifier
                    },
                ),
        )
        if (showsReason && failure != null) {
            AlertDialog(
                onDismissRequest = { showsReason = false },
                title = { Text(stringResource(R.string.relay_catalog_unreachable_title)) },
                text = { Text(relayProbeFailureText(failure)) },
                confirmButton = {
                    TextButton(
                        onClick = { showsReason = false },
                    ) { Text(stringResource(R.string.ok)) }
                },
            )
        }
    }
}

/** One-line failure reason: the existing failure classification (ErrorMapper) + the upstream status code. */
@Composable
internal fun relayProbeFailureText(failure: ProviderRepository.RelayModelProbeState.Failed): String {
    val context = LocalContext.current
    val message = when (val error = failure.error) {
        is ProviderServiceError -> ErrorMapper.localizeProviderErrorMessage(error, context)
        null -> ErrorMapper.localizeProviderErrorMessage(ProviderRepository.RELAY_UNVERIFIED_MESSAGE, context)
        else -> ErrorMapper.localizeProviderErrorMessage(error.message.orEmpty(), context)
    }
    return listOfNotNull(failure.httpStatus?.let { "HTTP $it" }, message.takeIf(String::isNotBlank)).joinToString(" · ")
}

/** Catalog row (model library section): row body + a "+" or the existing unavailable pill. The rounded card assembly and the dividers follow the catalog row. */
@Composable
internal fun RelayCatalogLibraryRow(
    row: RelayCatalogRow,
    onEnable: () -> Unit,
    /** Tapping the row = read-only Advanced (zero requests); only the plus enables it. */
    onOpen: () -> Unit,
    position: CatalogRowPosition,
    showTopDivider: Boolean,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val dividerColor = colors.border.opacity(0.45f)
    val available = RelayCatalogTrailing.Add in row.trailing
    // Catalog row: left column | status text | plus, vertically centered on the whole row; the iOS grouped card has no border. (whole-row vertical centering)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .catalogRowSurface(
                surface = colors.surfaceElevated,
                border = Color.Transparent,
                position = position,
                radius = OriveoTheme.radius.lg,
                borderWidth = OriveoBorderWidth.standard,
            )
            .drawWithContent {
                drawContent()
                if (showTopDivider) {
                    val insetPx = spacing.md.toPx()
                    drawRect(
                        color = dividerColor,
                        topLeft = Offset(insetPx, 0f),
                        size = Size(size.width - insetPx, 1.dp.toPx()),
                    )
                }
            }
            .heightIn(min = 74.dp)
            .clickable {
                // A row tap is dispatched by tapTarget only.
                when (RelayCatalogBoardModel.rowTap(row.model.id, row.tapTarget, enabledRow = false)) {
                    is RelayCatalogRowTap.OpenAdvanced -> onOpen()
                    RelayCatalogRowTap.Enable -> if (available) onEnable()
                    RelayCatalogRowTap.StartChat -> Unit
                }
            }
            .padding(horizontal = spacing.md, vertical = 12.dp)
            .alpha(if (available) 1f else 0.6f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spacing.md),
    ) {
        RelayCatalogRowBody(row = row, modifier = Modifier.weight(1f))
        RelayCatalogRowStatusText(row)
        if (available) {
            // The trailing area is drawn strictly from trailing: [plus] or [unavailable]. Tap target 44, drawn at 30 (iOS).
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onEnable),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(colors.primarySoft)
                        .border(1.dp, colors.primary.copy(alpha = 0.16f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ph_plus),
                        contentDescription = stringResource(R.string.add),
                        modifier = Modifier.size(12.dp),
                        tint = colors.primary,
                    )
                }
            }
        } else {
            StatusPill(
                text = stringResource(R.string.status_unavailable),
                tone = StatusTone.Warning,
            )
        }
    }
}

/** Protocol filter chips: "All" + the protocols that appear in the rows. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun RelayCatalogFilterChips(
    filters: List<RelayCatalogFilter>,
    selected: RelayCatalogFilter,
    onSelect: (RelayCatalogFilter) -> Unit,
    /** Display name of the key on the key filter chip ([RelayCatalogBoard.keyFilterTitle]). */
    keyTitle: String? = null,
) {
    val colors = OriveoTheme.colors
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
    ) {
        filters.forEach { filter ->
            val isSelected = filter == selected
            val shape = RoundedCornerShape(50)
            Row(
                modifier = Modifier
                    .clip(shape)
                    .background(if (isSelected) colors.primarySoft else colors.surfaceElevated)
                    .border(1.dp, if (isSelected) colors.primary.opacity(0.3f) else colors.border.opacity(0.66f), shape)
                    .clickable { onSelect(filter) }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                when (filter) {
                    RelayCatalogFilter.All -> Text(
                        text = stringResource(RelayCatalogFilter.All.labelRes),
                        style = OriveoTheme.typography.footnote,
                        color = if (isSelected) colors.primary else colors.textSecondary,
                    )
                    is RelayCatalogFilter.Protocol -> {
                        SetupDot(relayProtocolColor(filter.protocol))
                        Text(
                            text = filter.protocol.legend,
                            style = OriveoTheme.typography.footnote,
                            color = if (isSelected) colors.primary else colors.textSecondary,
                        )
                    }
                    is RelayCatalogFilter.Key -> Text(
                        text = stringResource(R.string.relay_catalog_filter_key, keyTitle.orEmpty()),
                        style = OriveoTheme.typography.footnote,
                        color = if (isSelected) colors.primary else colors.textSecondary,
                    )
                }
            }
        }
    }
}

/** The three legend items at the bottom + the footnote "The source is shown only in Advanced". */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun RelayCatalogLegend(board: RelayCatalogBoard) {
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs)) {
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
        ) {
            board.legend.forEach { (state, textRes) ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    SetupDot(
                        when (state) {
                            RelayCatalogCapabilityState.Supported -> CapabilityPalette.vision
                            RelayCatalogCapabilityState.Unknown -> unknownTint()
                            RelayCatalogCapabilityState.Unsupported -> unsupportedTint()
                        },
                    )
                    Text(
                        text = stringResource(textRes),
                        style = OriveoTheme.typography.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
        Text(
            text = stringResource(board.footnoteRes),
            style = OriveoTheme.typography.caption,
            color = colors.textTertiary,
        )
    }
}

/** Model library page header: avatar + "Model Library" + "host · N models · K keys" + refresh (the existing full catalog refresh). */
@Composable
internal fun RelayCatalogLibraryHeader(
    provider: Provider,
    header: RelayCatalogHeader,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        if (RelayAvatarResolver.appliesTo(provider)) {
            RelayAvatar(provider = provider, size = 32.dp)
        } else {
            Icon(
                painter = painterResource(R.drawable.ph_hard_drives_duotone),
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(32.dp),
            )
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(text = stringResource(R.string.model_library), style = OriveoTheme.typography.title2, color = colors.textPrimary)
            Text(
                text = listOfNotNull(
                    header.host.takeIf(String::isNotBlank),
                    pluralStringResource(R.plurals.relay_detail_models_count, header.modelCount, header.modelCount),
                    header.keyCount?.let { pluralStringResource(R.plurals.relay_keys_count, it, it) },
                ).joinToString(" · "),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                // When the host name is long it wraps to a second line and is then tail-truncated, instead of cutting the host and keeping the second half intact.
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .clickable(enabled = !isRefreshing, onClick = onRefresh)
                .alpha(if (isRefreshing) 0.4f else 1f),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painter = painterResource(R.drawable.ph_arrows_clockwise),
                contentDescription = stringResource(R.string.retry),
                modifier = Modifier.size(18.dp),
                tint = colors.primary,
            )
        }
    }
}

/**
 * Key status strip at the top of the catalog section (two or more keys): one row per key, the left column has two lines = name or mask (middle-truncated) / catalog count (tail-truncated);
 * the trailing area = status (a check mark, or "<code> <state word>", at most 50% of the width between the icon and Retry, at most 2 lines) + Retry (refreshes this key only, intrinsic width, never wrapped or squeezed). The iOS card has no border and rows are separated by hairlines.
 */
@Composable
internal fun RelayCatalogKeyStrip(items: List<RelayCatalogKeyStripItem>, onRetry: (String) -> Unit) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.lg))
            .background(colors.surfaceElevated)
            .padding(horizontal = OriveoTheme.spacing.md),
    ) {
        items.forEachIndexed { index, item ->
            if (index > 0) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(0.5.dp)
                        .background(colors.border.opacity(0.72f)),
                )
            }
            val state = item.state
            // Vertically centered on the whole row. (whole-row vertical centering)
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                Icon(
                    painter = painterResource(R.drawable.ph_key),
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.textSecondary,
                )
                // Between the key icon and Retry the width is divided like iOS columnWidths: status = min(ideal single-line width, total x 50%), and the left column takes what is left.
                RelayStatusColumnsLayout(
                    spacing = OriveoTheme.spacing.sm,
                    modifier = Modifier.weight(1f),
                    status = when (state) {
                        RelayCatalogKeyStripState.Ok -> {
                            {
                                Icon(
                                    painter = painterResource(R.drawable.ph_check_circle_duotone),
                                    contentDescription = stringResource(R.string.relay_key_status_ok),
                                    modifier = Modifier.size(16.dp),
                                    tint = colors.success,
                                )
                            }
                        }
                        RelayCatalogKeyStripState.Unchecked -> null
                        is RelayCatalogKeyStripState.Failed -> {
                            {
                                Text(
                                    text = listOfNotNull(state.httpStatus?.toString(), state.statusRes?.let { stringResource(it) }).joinToString(" "),
                                    style = OriveoTheme.typography.caption,
                                    color = colors.warningText,
                                    textAlign = TextAlign.End,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    },
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            text = item.title,
                            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),
                            color = colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.MiddleEllipsis,
                        )
                        Text(
                            text = item.catalogCount?.let { pluralStringResource(R.plurals.relay_key_catalog_count, it, it) }
                                ?: stringResource(R.string.relay_key_catalog_none),
                            style = OriveoTheme.typography.caption,
                            color = colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (state is RelayCatalogKeyStripState.Failed) {
                    TextButton(
                        onClick = { onRetry(item.keyId) },
                    ) {
                        Text(stringResource(R.string.retry), maxLines = 1, softWrap = false)
                    }
                }
            }
        }
    }
}

/** Single-key catalog fetch failure card (iOS boardFailureCard): no icon, title body.semibold, explanation footnote, a text retry button at the start of the row, no border; manual add is not placed inside the card. */
@Composable
internal fun RelayCatalogFailureCard(detail: String?, onRetry: () -> Unit) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.lg))
            .background(colors.surfaceElevated)
            .padding(OriveoTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Text(
            text = stringResource(R.string.relay_catalog_fetch_failed_title),
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        detail?.takeIf(String::isNotBlank)?.let {
            Text(text = it, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
        }
        Text(
            text = stringResource(R.string.retry),
            style = OriveoTheme.typography.body,
            color = colors.primary,
            modifier = Modifier
                .clickable(onClick = onRetry),
        )
    }
}

/** The enabling hint sentence under a group; not shown for local connections. */
@Composable
internal fun RelayCatalogEnableHint(@androidx.annotation.StringRes textRes: Int) {
    Text(
        text = stringResource(textRes),
        style = OriveoTheme.typography.caption,
        color = OriveoTheme.colors.textTertiary,
    )
}
