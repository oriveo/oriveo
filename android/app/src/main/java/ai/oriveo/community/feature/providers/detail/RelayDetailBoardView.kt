package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayAvatar
import ai.oriveo.community.core.model.RelayAvatarResolver
import ai.oriveo.community.feature.providers.relay.SetupDot
import ai.oriveo.community.feature.providers.relay.relayProtocolColor
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.localizedProviderError
import ai.oriveo.community.ui.theme.CapabilityPalette
import ai.oriveo.community.ui.theme.DetailRowPalette
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.util.formatRelayRelativeTime

/**
 * Relay / local detail page board (RelayDetail / LocalDetail): header, connection card, model card (with parameter row),
 * re-detect / delete, footnote; there is no Settings section outside the board any more.
 * Row order, copy and button states all come from [RelayDetailBoardModel.build]; this file only draws.
 */
@Composable
internal fun RelayDetailBoardView(
    provider: Provider,
    board: RelayDetailBoard,
    onAction: (RelayDetailAction) -> Unit,
) {
    val colors = OriveoTheme.colors
    val tint = if (board.isLocal) colors.success else colors.primary
    Column(
        modifier = Modifier.testTag("relay_detail_board"),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
    ) {
        BoardHeader(provider = provider, board = board, tint = iconToneColor(relayDetailHeaderIconTone, tint), onAction = onAction)

        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            ProviderDetailSectionLabel(title = stringResource(R.string.relay_section_connection))
            BoardCard {
                board.connectionRows.forEachIndexed { index, row ->
                    if (index > 0) BoardDivider()
                    BoardRow(row = row, identityTint = tint, onAction = onAction)
                    if (row.secondaryAction != null) {
                        Text(
                            text = stringResource(R.string.relay_remove_api_key),
                            modifier = Modifier
                                .padding(start = 46.dp, bottom = 10.dp)
                                .clip(RoundedCornerShape(50))
                                .clickable { onAction(row.secondaryAction) }
                                .padding(horizontal = 6.dp, vertical = 4.dp),
                            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.warning,
                        )
                    }
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            ProviderDetailSectionLabel(title = stringResource(R.string.provider_detail_models_title))
            BoardCard {
                board.modelRows.forEachIndexed { index, row ->
                    if (index > 0) BoardDivider()
                    BoardRow(row = row, identityTint = tint, onAction = onAction)
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            board.buttons.forEach { button ->
                when (button.action) {
                    RelayDetailAction.Delete -> DeleteButton(text = stringResource(button.textRes), onClick = { onAction(button.action) })
                    else -> OriveoSecondaryButton(
                        text = stringResource(button.textRes),
                        onClick = { onAction(button.action) },
                        enabled = button.enabled,
                        loading = button.loading,
                        fill = colors.surface,
                        leadingIcon = {
                            Icon(painterResource(R.drawable.ph_scan), contentDescription = null, tint = colors.primary, modifier = Modifier.size(20.dp))
                        },
                        modifier = Modifier,
                    )
                }
            }
        }

        Text(
            text = stringResource(board.footnoteRes),
            style = OriveoTheme.typography.footnote,
            color = colors.textTertiary,
        )
    }
}

/**
 * Relay / local connection error recovery card: rendered only from [RelayDetailBoardModel.recoveryCard]; neutral card surface (same as a normal card),
 * the top-right x dismisses only for this visit to the page. Actions are listed row by row; an in-flight re-verify row shows a spinner and is not tappable.
 */
@Composable
internal fun RelayRecoveryCardView(card: RelayRecoveryCard, onAction: (RelayDetailAction) -> Unit, onDismiss: () -> Unit) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(16.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceElevated),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    card.titleAction?.let { action ->
                        Modifier
                            .clickable { onAction(action) }
                    } ?: Modifier,
                )
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(painterResource(card.titleIconRes), contentDescription = null, tint = colors.warning, modifier = Modifier.size(20.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = stringResource(card.titleRes),
                    style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                card.reason?.let { reason ->
                    Text(
                        text = RelayDetailBoardModel.recoveryReasonRes(reason)?.let { stringResource(it) }
                            ?: localizedProviderError(reason),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (card.titleAction != null) {
                Icon(painterResource(R.drawable.ph_caret_right), contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(14.dp))
            }
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painterResource(R.drawable.ph_x),
                    contentDescription = stringResource(R.string.close),
                    tint = colors.textTertiary,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        card.actions.forEach { item ->
            BoardDivider()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = item.enabled) { onAction(item.action) }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(painterResource(item.iconRes), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(20.dp))
                Text(
                    text = stringResource(item.titleRes),
                    modifier = Modifier.weight(1f),
                    style = OriveoTheme.typography.body,
                    color = if (item.enabled) colors.textPrimary else colors.textTertiary,
                )
                if (item.running) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.warning)
                } else if (RelayDetailBoardModel.opensPage(item.action)) {
                    Icon(painterResource(R.drawable.ph_caret_right), contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}

@Composable
private fun BoardHeader(
    provider: Provider,
    board: RelayDetailBoard,
    tint: Color,
    onAction: (RelayDetailAction) -> Unit,
) {
    val colors = OriveoTheme.colors
    val status = listOfNotNull(
        pluralStringResource(R.plurals.relay_detail_models_count, board.modelCount, board.modelCount),
        board.lastCheckedAt?.let { stringResource(R.string.relay_detail_checked_at, formatRelayRelativeTime(androidx.compose.ui.platform.LocalContext.current, it)) },
    ).joinToString(" · ")
    val editConnectionLabel = stringResource(R.string.relay_detail_edit_connection)
    // Page header (top-aligned): the name may wrap to two lines, and the avatar and edit button are pinned to the top.
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        // The relay avatar goes through the unified resolver and doubles as the "Change icon" button; the local header is unchanged.
        val avatar = board.avatar
        if (avatar != null && RelayAvatarResolver.appliesTo(provider)) {
            val changeIconLabel = stringResource(R.string.relay_avatar_change_icon)
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(10.dp))
                    .then(
                        if (board.avatarPickable) {
                            Modifier
                                .clickable(role = Role.Button, onClickLabel = changeIconLabel) { onAction(RelayDetailAction.ChangeIcon) }
                                // Screen readers announce only "Change icon", not the name of the icon inside.
                                .clearAndSetSemantics { contentDescription = changeIconLabel }
                        } else {
                            Modifier
                        },
                    ),
            ) {
                RelayAvatar(result = avatar, size = 40.dp)
            }
        } else {
            Icon(
                painter = painterResource(R.drawable.ph_hard_drives_duotone),
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(40.dp),
            )
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            // Tapping the name or the pencil next to it renames.
            Row(
                modifier = if (RelayDetailAction.Rename in board.headerActions) {
                    Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable { onAction(RelayDetailAction.Rename) }
                } else {
                    Modifier
                },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = provider.displayName,
                    modifier = Modifier.weight(1f, fill = false),
                    style = OriveoTheme.typography.title1,
                    color = colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (board.showsRenamePencil) {
                    Icon(
                        painter = painterResource(R.drawable.ph_pencil_simple),
                        contentDescription = stringResource(R.string.rename),
                        tint = colors.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            Text(
                text = status,
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
        if (RelayDetailAction.EditConnection in board.headerActions) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(colors.surfaceElevated)
                    .clickable { onAction(RelayDetailAction.EditConnection) }
                    .semantics { contentDescription = editConnectionLabel },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painter = painterResource(R.drawable.ph_sliders_horizontal),
                    contentDescription = null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}

@Composable
private fun BoardCard(content: @Composable () -> Unit) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(16.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceElevated),
    ) {
        content()
    }
}

@Composable
private fun BoardDivider() {
    Box(
        modifier = Modifier
            .padding(horizontal = 14.dp)
            .fillMaxWidth()
            .height(0.5.dp)
            .background(OriveoTheme.colors.border.opacity(0.72f)),
    )
}

/** token to actual color; [identity] is this connection's identity color. */
@Composable
private fun iconToneColor(tone: RelayDetailIconTone, identity: Color): Color = when (tone) {
    RelayDetailIconTone.Identity -> identity
    RelayDetailIconTone.Teal -> DetailRowPalette.teal
    RelayDetailIconTone.Cyan -> DetailRowPalette.cyan
    RelayDetailIconTone.Indigo -> DetailRowPalette.indigo
    RelayDetailIconTone.Orange -> DetailRowPalette.orange
    RelayDetailIconTone.Rose -> DetailRowPalette.rose
    RelayDetailIconTone.CapabilityWebSearch -> CapabilityPalette.webSearch
    RelayDetailIconTone.CapabilityReasoning -> CapabilityPalette.reasoning
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun BoardRow(
    row: RelayDetailRow,
    identityTint: Color,
    onAction: (RelayDetailAction) -> Unit,
    onClick: (() -> Unit)? = row.action?.let { action -> { onAction(action) } },
) {
    val colors = OriveoTheme.colors
    // Catalog / thinking / web / parameters and the API key row that renders inline keys (same inline decision, regardless of key count) are title + description; the rest are small title + value.
    val titleFirst = row.id == RelayDetailRowId.ModelLibrary || row.id == RelayDetailRowId.Thinking ||
        row.id == RelayDetailRowId.WebSearch || row.id == RelayDetailRowId.Parameters ||
        (row.id == RelayDetailRowId.ApiKey && row.inlineKeys.isNotEmpty())
    // The web row's trailing side is a configured / not configured status word plus a chevron (board RelayDetail).
    val statusWithChevron = row.id == RelayDetailRowId.WebSearch
    // The key row's can-add-multiple hint is still followed by an arrow (the whole row opens the keys page).
    val addMoreHint = row.trailingRes == R.string.relay_keys_add_more_hint
    // Detail row: when the left column (including inline keys) spans multiple lines, the trailing hint and arrow are vertically centered on the whole row (layout rule three). (whole-row vertical centering)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .then(if (statusWithChevron) Modifier else Modifier)
            .then(if (row.id == RelayDetailRowId.Parameters) Modifier else Modifier)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        relayDetailRowIcon(row.id)?.let { icon ->
            val tint = iconToneColor(relayDetailRowIconTone(row.id) ?: RelayDetailIconTone.Identity, identityTint)
            Icon(painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        }
        if (row.id == RelayDetailRowId.BasePaths) {
            Text(
                text = stringResource(row.titleRes),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
            FlowRow(
                modifier = Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                row.basePaths.forEach { item ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        SetupDot(relayProtocolColor(item.protocol))
                        Text(
                            text = "${item.protocol.legend} ${item.path}",
                            style = OriveoTheme.typography.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
            }
            return@Row
        }
        val valueText = row.value
            ?: row.valueRes?.let { res -> stringResource(res, *row.valueArgs.toTypedArray()) }
            ?: row.keyCount?.let { count -> pluralStringResource(R.plurals.relay_keys_count, count, count) }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = stringResource(row.titleRes),
                style = if (titleFirst) {
                    OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold)
                } else {
                    OriveoTheme.typography.caption
                },
                color = if (titleFirst) colors.textPrimary else colors.textSecondary,
            )
            if (!valueText.isNullOrEmpty()) {
                Text(
                    text = valueText,
                    style = if (titleFirst) OriveoTheme.typography.footnote else OriveoTheme.typography.body,
                    color = if (titleFirst) colors.textSecondary else colors.textPrimary,
                    maxLines = if (titleFirst) 3 else 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            // With multiple keys the first 3 are inlined in the left column, using the same key-row component as the keys page; tapping the whole row opens the keys page.
            if (row.inlineKeys.isNotEmpty()) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    row.inlineKeys.forEach { key ->
                        RelayKeyRowSummary(key = key, modifier = Modifier.fillMaxWidth())
                    }
                    if (row.moreKeys > 0) {
                        Text(
                            text = pluralStringResource(R.plurals.relay_keys_more, row.moreKeys, row.moreKeys),
                            style = OriveoTheme.typography.footnote,
                            color = colors.textTertiary,
                        )
                    }
                }
            }
        }
        if (statusWithChevron) row.trailingRes?.let { res ->
            val set = res == R.string.relay_web_status_set
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (set) {
                    Icon(painter = painterResource(R.drawable.ph_check), contentDescription = null, tint = colors.success, modifier = Modifier.size(14.dp))
                }
                Text(
                    text = stringResource(res),
                    modifier = Modifier.testTag("relay_detail_web_search_status"),
                    style = OriveoTheme.typography.caption,
                    color = if (set) colors.success else colors.textSecondary,
                )
            }
        } else row.trailingRes?.let { res ->
            // Both trailing variants are secondary-color descriptions, not buttons: read-only gets a lock, can-add-multiple gets a plus; whole-row tapping is unchanged.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(
                    painter = painterResource(if (addMoreHint) R.drawable.ph_plus else R.drawable.ph_lock_simple),
                    contentDescription = null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    text = stringResource(res),
                    style = OriveoTheme.typography.caption,
                    color = colors.textSecondary,
                )
            }
        }
        // A leftover key row with a Remove saved key exit never has an arrow, and its empty trailing side is not filled in.
        if (onClick != null && row.secondaryAction == null && (row.trailingRes == null || statusWithChevron || addMoreHint)) {
            Icon(
                painter = painterResource(R.drawable.ph_caret_right),
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
private fun DeleteButton(text: String, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoTheme.radius.lg)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(shape)
            .background(colors.dangerSoft)
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        Icon(painterResource(R.drawable.ph_x), contentDescription = null, tint = colors.danger, modifier = Modifier.size(18.dp))
        Text(
            text = text,
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
            color = colors.danger,
            textAlign = TextAlign.Center,
        )
    }
}
