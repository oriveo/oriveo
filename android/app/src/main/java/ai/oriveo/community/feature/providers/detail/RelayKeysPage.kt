package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.Placeholder
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.text.input.VisualTransformation
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.ui.semantics.Role
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.DetailRowPalette
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.draw.scale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoBackButtonDefaults
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.util.formatRelayRelativeTime

/** What the user is doing on the keys page; only one panel / dialog is open at a time. */
private sealed interface KeysPageDialog {
    data class Actions(val keyId: String) : KeysPageDialog
    data class Rename(val keyId: String) : KeysPageDialog
    data class Replace(val keyId: String) : KeysPageDialog
    data class Delete(val keyId: String) : KeysPageDialog
    data object Add : KeysPageDialog
}

/**
 * Keys page (the Keys board): renders only [RelayKeysBoardModel.build], and every write is called back to the detail page host
 * (the key operations from ViewModel to ProviderRepository). With fewer than two keys, "Replace key" goes through [onReplaceSingleKey] (the existing replace-key dialog).
 */
@Composable
internal fun RelayKeysPage(
    provider: Provider,
    pageState: RelayKeysPageState,
    contentPadding: PaddingValues,
    onBack: () -> Unit,
    onReplaceSingleKey: () -> Unit,
    onAdd: (name: String?, secret: String) -> Unit,
    onRename: (keyId: String, name: String?) -> Unit,
    onReplace: (keyId: String, secret: String) -> Unit,
    onMove: (keyId: String, toIndex: Int) -> Unit,
    onDelete: (keyId: String) -> Unit,
    /** Open the model library filtered by key(id): the panel's "View models (N)" and the link in the add-success notice. */
    onOpenLibrary: (keyId: String) -> Unit,
) {
    val colors = OriveoTheme.colors
    val board = RelayKeysBoardModel.build(provider, pageState.fetchingKeyIDs)
    var dialog: KeysPageDialog? by rememberSaveableDialog()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(contentPadding)
            .padding(horizontal = OriveoTheme.layout.screenH)
            .padding(top = OriveoTheme.spacing.sm, bottom = OriveoTheme.spacing.xxl),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
    ) {
        // The back button and the title are on the same line (iOS page header); the subtitle goes below.
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                OriveoBackButton(
                    onClick = onBack,
                    modifier = Modifier.offset(x = -OriveoBackButtonDefaults.EdgeInset),
                )
                Text(
                    text = stringResource(R.string.relay_keys_title),
                    modifier = Modifier.weight(1f),
                    style = OriveoTheme.typography.title2,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = listOf(board.host, pluralStringResource(R.plurals.relay_keys_count, board.keyCount, board.keyCount))
                    .filter(String::isNotEmpty)
                    .joinToString(" · "),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }

        // iOS block order: card, then notice, then footnote, then action explanations; "The first key is the primary key" is the group title above the card (shown only with two or more keys).
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            if (board.showsPrimaryHint) {
                KeysGroupTitle(stringResource(R.string.relay_keys_primary_hint))
            }
            val shape = RoundedCornerShape(16.dp)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(shape)
                    .background(colors.surfaceElevated),
            ) {
                board.listItems.forEachIndexed { index, item ->
                    if (index > 0) {
                        Box(
                            modifier = Modifier
                                .padding(horizontal = 14.dp)
                                .fillMaxWidth()
                                .height(0.5.dp)
                                .background(colors.border.opacity(0.72f)),
                        )
                    }
                    when (item) {
                        is RelayKeysListItem.Key -> RelayKeyRowSummary(
                            key = item.row,
                            detailed = true,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { dialog = KeysPageDialog.Actions(item.row.id) }
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                        )
                        // "Add key" is merged into the last row inside the card (Keys board).
                        RelayKeysListItem.AddKey -> Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 52.dp)
                                .clickable { dialog = KeysPageDialog.Add }
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(painterResource(R.drawable.ph_plus), contentDescription = null, tint = colors.primary, modifier = Modifier.size(18.dp))
                            Text(
                                text = stringResource(R.string.relay_keys_add),
                                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                                color = colors.primary,
                            )
                        }
                    }
                }
            }
        }

        // Post-operation notices: listed one by one in completion order (identical sentences already deduplicated) and withdrawn as a whole when the next operation starts.
        pageState.notices.forEach { notice ->
            when (notice) {
                is RelayKeysNotice.Warning -> Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(
                        painterResource(R.drawable.ph_warning),
                        contentDescription = null,
                        tint = colors.warning,
                        modifier = Modifier.padding(top = 2.dp).size(16.dp),
                    )
                    Text(text = stringResource(notice.messageRes), style = OriveoTheme.typography.footnote, color = colors.textPrimary)
                }
                is RelayKeysNotice.Added -> KeyAddedNotice(notice, onOpen = { onOpenLibrary(notice.keyID) })
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            board.footnoteRes.forEach { res ->
                Text(text = stringResource(res), style = OriveoTheme.typography.footnote, color = colors.textTertiary)
            }
        }

        // The consequence of each action is visible before choosing (shown only with two or more keys); the title is outside the card.
        if (board.actionNotes.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                KeysGroupTitle(stringResource(board.actionNotesTitleRes))
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(colors.surfaceElevated)
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    board.actionNotes.forEach { note ->
                        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            val (icon, tint) = keyActionGlyph(note.action)
                            Icon(painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(
                                    text = stringResource(keyActionLabelRes(note.action)),
                                    style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                                    color = if (note.action == RelayKeyAction.Delete) colors.danger else colors.textPrimary,
                                )
                                Text(text = stringResource(note.textRes), style = OriveoTheme.typography.footnote, color = colors.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    when (val current = dialog) {
        null -> Unit
        is KeysPageDialog.Actions -> board.rows.firstOrNull { it.id == current.keyId }?.let { row ->
            KeyActionsDialog(
                row = row,
                onDismiss = { dialog = null },
                onAction = { action ->
                    dialog = null
                    when (action) {
                        RelayKeyAction.ViewModels -> onOpenLibrary(row.id)
                        RelayKeyAction.Rename -> {
                            dialog = KeysPageDialog.Rename(row.id)
                        }
                        RelayKeyAction.Replace -> {
                            if (board.replaceUsesSingleKeyPath) onReplaceSingleKey() else dialog = KeysPageDialog.Replace(row.id)
                        }
                        RelayKeyAction.MoveUp, RelayKeyAction.MoveDown -> {
                            RelayKeysBoardModel.moveTarget(provider, row.id, action)?.let { onMove(row.id, it) }
                        }
                        RelayKeyAction.Delete -> {
                            dialog = KeysPageDialog.Delete(row.id)
                        }
                    }
                },
            )
        }
        is KeysPageDialog.Rename -> board.rows.firstOrNull { it.id == current.keyId }?.let { row ->
            KeyEntrySheet(
                sheet = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Rename, row),
                initialName = if (row.title == row.maskedSecret) "" else row.title,
                onDismiss = { dialog = null },
                onSave = { name, _ ->
                    dialog = null
                    onRename(row.id, name.trim().ifEmpty { null })
                },
            )
        }
        is KeysPageDialog.Replace -> KeyEntrySheet(
            sheet = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Replace, board.rows.firstOrNull { it.id == current.keyId }),
            onDismiss = { dialog = null },
            onSave = { _, secret ->
                dialog = null
                onReplace(current.keyId, secret.trim())
            },
        )
        KeysPageDialog.Add -> KeyEntrySheet(
            sheet = RelayKeysBoardModel.inputSheet(RelayKeyInputKind.Add, null),
            onDismiss = { dialog = null },
            onSave = { name, secret ->
                dialog = null
                onAdd(name.trim().ifEmpty { null }, secret.trim())
            },
        )
        is KeysPageDialog.Delete -> RelayKeysBoardModel.deleteConfirmation(provider, current.keyId)?.let { confirmation ->
            DeleteKeyDialog(
                confirmation = confirmation,
                onDismiss = { dialog = null },
                onConfirm = {
                    dialog = null
                    onDelete(confirmation.keyId)
                },
            )
        }
    }
}

@Composable
private fun rememberSaveableDialog() = rememberSaveable(
    stateSaver = androidx.compose.runtime.saveable.Saver<KeysPageDialog?, String>(
        save = { value ->
            when (value) {
                null -> null
                is KeysPageDialog.Actions -> "actions|${value.keyId}"
                is KeysPageDialog.Rename -> "rename|${value.keyId}"
                is KeysPageDialog.Replace -> "replace|${value.keyId}"
                is KeysPageDialog.Delete -> "delete|${value.keyId}"
                KeysPageDialog.Add -> "add|"
            }
        },
        restore = { raw ->
            val kind = raw.substringBefore("|")
            val id = raw.substringAfter("|")
            when (kind) {
                "actions" -> KeysPageDialog.Actions(id)
                "rename" -> KeysPageDialog.Rename(id)
                "replace" -> KeysPageDialog.Replace(id)
                "delete" -> KeysPageDialog.Delete(id)
                "add" -> KeysPageDialog.Add
                else -> null
            }
        },
    ),
) { mutableStateOf<KeysPageDialog?>(null) }

private const val STATUS_MARK_ID = "relay_key_status_mark"

/** Inline placeholder of the status mark: a dot of 6, warning / progress 12, aligned to the text midline. */
private fun relayKeyStatusMarkInline(mark: RelayKeyStatusMark?, color: Color): Map<String, InlineTextContent> {
    if (mark == null) return emptyMap()
    val size = if (mark == RelayKeyStatusMark.Dot) 6.sp else 12.sp
    return mapOf(
        STATUS_MARK_ID to InlineTextContent(Placeholder(size, size, PlaceholderVerticalAlign.TextCenter)) {
            when (mark) {
                RelayKeyStatusMark.Dot -> Box(modifier = Modifier.fillMaxSize().clip(CircleShape).background(color))
                RelayKeyStatusMark.Warning -> Icon(
                    painterResource(R.drawable.ph_warning),
                    contentDescription = null,
                    tint = color,
                    modifier = Modifier.fillMaxSize(),
                )
                RelayKeyStatusMark.Progress -> CircularProgressIndicator(
                    modifier = Modifier.fillMaxSize(),
                    strokeWidth = 1.5.dp,
                    color = color,
                )
            }
        },
    )
}

/** Group title above the card (iOS footnote semibold, letter spacing 0.6). */
@Composable
private fun KeysGroupTitle(text: String) {
    Text(
        text = text,
        style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp),
        color = OriveoTheme.colors.textSecondary,
    )
}

/**
 * The row of one key (the same component is used on the keys page and inline on the detail page, iOS RelayKeyRowView):
 * left column [name or mask + primary key badge / <mask> · catalog count (may wrap) / in-use model count / last] | trailing column [status text] | arrow.
 * An unnamed key has the mask as its title, and the catalog row does not repeat it; the mask is no longer switched between the left and right columns by width.
 * [detailed] = the keys page: adds the in-use model count, the "Last" lines and the trailing arrow.
 */
@Composable
internal fun RelayKeyRowSummary(key: RelayKeysBoardRow, detailed: Boolean = false, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    // Never detected: neither the status word nor the mark is drawn.
    val statusWord = key.statusRes?.let { stringResource(it) }
    val statusColor = when {
        key.statusMark == RelayKeyStatusMark.Progress -> colors.textSecondary
        key.statusRes == R.string.relay_key_status_ok -> colors.success
        else -> colors.warning
    }
    val mask = key.catalogMask
    val catalog = key.catalogCount?.let { pluralStringResource(R.plurals.relay_key_catalog_count, it, it) }
        ?: stringResource(R.string.relay_key_catalog_none)
    val enabled = if (key.enabledCount > 0) {
        pluralStringResource(R.plurals.relay_key_enabled_using, key.enabledCount, key.enabledCount)
    } else {
        stringResource(R.string.relay_key_enabled_none)
    }
    val last = key.lastStatus?.let { status ->
        stringResource(
            R.string.relay_key_last_status,
            "${status.httpStatus} ${stringResource(status.statusRes)}",
            status.checkedAt?.let { formatRelayRelativeTime(androidx.compose.ui.platform.LocalContext.current, it) } ?: "—",
        )
    }
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val statusStyle = OriveoTheme.typography.footnote
    // Key row: left column | trailing column (status text) | arrow, vertically centered on the whole row. (whole-row vertical centering)
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // Before the arrow the width is divided like iOS columnWidths: status = min(ideal single-line width, total x 50%), and the left column takes what is left.
        RelayStatusColumnsLayout(
            spacing = 10.dp,
            modifier = Modifier.weight(1f),
            status = if (key.statusMark != null || statusWord != null) {
                {
                    // The mark is an inline prefix of the first line of the status word: one text flow, the whole block aligned to the end of the row, and when it wraps the mark stays attached to the first word of the first line; the status word takes at most 2 lines.
                    val statusText = buildAnnotatedString {
                        if (key.statusMark != null) {
                            appendInlineContent(STATUS_MARK_ID, alternateText = " ")
                            if (statusWord != null) append(" ")
                        }
                        statusWord?.let { append(it) }
                    }
                    Text(
                        text = statusText,
                        inlineContent = relayKeyStatusMarkInline(key.statusMark, statusColor),
                        style = statusStyle,
                        color = statusColor,
                        textAlign = TextAlign.End,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            } else {
                null
            },
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text = key.title,
                        modifier = Modifier.weight(1f, fill = false),
                        style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (key.showsPrimaryBadge) {
                        Text(
                            text = stringResource(R.string.relay_key_primary_badge),
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(colors.primary.opacity(0.12f))
                                .padding(horizontal = 6.dp, vertical = 1.dp),
                            style = OriveoTheme.typography.caption,
                            color = colors.primary,
                        )
                    }
                }
                Text(
                    text = listOfNotNull(mask, catalog).joinToString(" · "),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
                if (detailed) {
                    Text(text = enabled, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
                    last?.let { Text(text = it, style = OriveoTheme.typography.footnote, color = colors.warning) }
                }
            }
        }
        if (detailed) {
            Icon(
                painter = painterResource(R.drawable.ph_caret_right),
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier
                    .size(14.dp)
                    .then(if (rtl) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
            )
        }
    }
}

@Composable
private fun KeyActionsDialog(row: RelayKeysBoardRow, onDismiss: () -> Unit, onAction: (RelayKeyAction) -> Unit) {
    val colors = OriveoTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(row.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                row.actions.forEach { action ->
                    val label = keyActionLabelRes(action)
                    val hint = when (action) {
                        RelayKeyAction.ViewModels -> null
                        RelayKeyAction.Rename -> R.string.relay_key_rename_hint
                        RelayKeyAction.Replace -> R.string.relay_key_replace_hint
                        RelayKeyAction.Delete -> R.string.relay_key_delete_hint
                        RelayKeyAction.MoveUp, RelayKeyAction.MoveDown -> null
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { onAction(action) }
                            .padding(vertical = 8.dp),
                    ) {
                        Text(
                            text = if (action == RelayKeyAction.ViewModels) stringResource(label, row.catalogCount ?: 0) else stringResource(label),
                            style = OriveoTheme.typography.body,
                            color = if (action == RelayKeyAction.Delete) colors.danger else colors.textPrimary,
                        )
                        hint?.let { Text(text = stringResource(it), style = OriveoTheme.typography.caption, color = colors.textTertiary) }
                    }
                }
                row.panelNoteRes?.let { note ->
                    Text(
                        text = stringResource(note),
                        modifier = Modifier.padding(top = 4.dp),
                        style = OriveoTheme.typography.caption,
                        color = colors.textTertiary,
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}

/** Add-success notice: a success-colored check + "Added · N listed" (with M > 0 followed by " · M of them new"), and the trailing link opens the model library. */
@Composable
private fun KeyAddedNotice(notice: RelayKeysNotice.Added, onOpen: () -> Unit) {
    val colors = OriveoTheme.colors
    val listed = pluralStringResource(R.plurals.relay_keys_notice_added, notice.listed, notice.listed)
    val text = if (notice.new > 0) {
        listed + " · " + pluralStringResource(R.plurals.relay_keys_notice_added_new, notice.new, notice.new)
    } else {
        listed
    }
    // The link tap area is stretched to 48dp and the row is center-aligned, so the check, the text and the link share one midline.
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(
            painterResource(R.drawable.ph_check_circle),
            contentDescription = null,
            tint = colors.success,
            modifier = Modifier.size(16.dp),
        )
        Text(text = text, modifier = Modifier.weight(1f), style = OriveoTheme.typography.footnote, color = colors.textSecondary)
        Text(
            text = stringResource(R.string.relay_keys_notice_view_models),
            // Link style, a tap area of at least 48dp, read by screen readers as a button.
            modifier = Modifier
                .minimumInteractiveComponentSize()
                .clickable(role = Role.Button, onClick = onOpen),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.primary,
        )
    }
}

/** Two-color icon of an action explanation row (iOS 22pt): replace key uses the same cyan as the detail row, delete uses danger, and the rest use primary. */
@Composable
private fun keyActionGlyph(action: RelayKeyAction): Pair<Int, Color> = when (action) {
    RelayKeyAction.ViewModels -> R.drawable.ph_squares_four_duotone to OriveoTheme.colors.primary
    RelayKeyAction.Rename -> R.drawable.ph_pencil_simple_duotone to OriveoTheme.colors.primary
    RelayKeyAction.Replace -> R.drawable.ph_arrows_clockwise_duotone to DetailRowPalette.cyan
    RelayKeyAction.MoveUp -> R.drawable.ph_arrow_up_duotone to OriveoTheme.colors.primary
    RelayKeyAction.MoveDown -> R.drawable.ph_arrow_down_duotone to OriveoTheme.colors.primary
    RelayKeyAction.Delete -> R.drawable.ph_trash_duotone to OriveoTheme.colors.danger
}

/** Action names: the panel and the "Actions for each key" explanation card use the same set. */
@androidx.annotation.StringRes
private fun keyActionLabelRes(action: RelayKeyAction): Int = when (action) {
    RelayKeyAction.ViewModels -> R.string.relay_key_action_view_models
    RelayKeyAction.Rename -> R.string.rename
    RelayKeyAction.Replace -> R.string.relay_key_replace
    RelayKeyAction.MoveUp -> R.string.relay_key_move_up
    RelayKeyAction.MoveDown -> R.string.relay_key_move_down
    RelayKeyAction.Delete -> R.string.delete
}

/**
 * Input surface for add / replace key / rename (same as the iOS bottom sheet): a × at the top left (drawn at 36dp / 48dp tap area) + a centered title,
 * an input field with a title, a show / hide eye on the key field, one full-width Save at the bottom and no Cancel. All content comes from [RelayKeysBoardModel.inputSheet].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KeyEntrySheet(
    sheet: RelayKeyInputSheet,
    onDismiss: () -> Unit,
    onSave: (name: String, secret: String) -> Unit,
    initialName: String = "",
) {
    val colors = OriveoTheme.colors
    var name by rememberSaveable { mutableStateOf(initialName) }
    // The plaintext key never goes into the saved-instance Bundle (it must be re-entered after rotation / process recreation); the name may be kept.
    var secret by remember { mutableStateOf("") }
    var revealed by remember { mutableStateOf(false) }
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        Box(modifier = Modifier.fillMaxWidth().padding(horizontal = OriveoTheme.spacing.sm)) {
            Box(
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .size(48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.surfaceElevated)
                        .border(1.dp, colors.border.opacity(0.72f), RoundedCornerShape(10.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ph_x),
                        contentDescription = stringResource(R.string.close),
                        tint = colors.textPrimary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            Text(
                text = stringResource(sheet.titleRes),
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(horizontal = 56.dp),
                style = OriveoTheme.typography.title3.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        ) {
            sheet.fields.forEach { field ->
                val placeholder = field.placeholderText ?: field.placeholderRes?.let { stringResource(it) }
                // The title sits outside the field, and the field itself uses the same string as its screen reader label.
                val title = stringResource(field.labelRes)
                when (field.id) {
                    RelayKeyInputFieldId.Name -> KeyEntryField(title = title) {
                        OutlinedTextField(
                            value = name,
                            onValueChange = { name = it },
                            modifier = Modifier.fillMaxWidth().semantics { contentDescription = title },
                            placeholder = placeholder?.let { { Text(it) } },
                            singleLine = true,
                        )
                    }
                    RelayKeyInputFieldId.Secret -> KeyEntryField(title = title) {
                        OutlinedTextField(
                            value = secret,
                            onValueChange = { secret = it },
                            modifier = Modifier.fillMaxWidth().semantics { contentDescription = title },
                            placeholder = placeholder?.let { { Text(it) } },
                            singleLine = true,
                            visualTransformation = if (revealed) VisualTransformation.None else PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                            trailingIcon = {
                                IconButton(
                                    onClick = { revealed = !revealed },
                                ) {
                                    Icon(
                                        painter = painterResource(if (revealed) R.drawable.ph_eye_duotone else R.drawable.ph_eye),
                                        contentDescription = stringResource(
                                            if (revealed) R.string.secure_field_hide else R.string.secure_field_show,
                                        ),
                                        tint = if (revealed) colors.primary else colors.textTertiary,
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            },
                        )
                    }
                }
            }
            sheet.noteRes?.let { Text(text = stringResource(it), style = OriveoTheme.typography.caption, color = colors.textTertiary) }
            OriveoPrimaryButton(
                text = stringResource(R.string.save),
                onClick = { onSave(name, secret) },
                enabled = sheet.canSave(secret),
                modifier = Modifier
                    .fillMaxWidth(),
            )
        }
    }
}

/** The title of the input field sits above the field, and only the placeholder goes inside the field (same as iOS). */
@Composable
private fun KeyEntryField(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
        Text(
            text = title,
            style = OriveoTheme.typography.caption,
            color = OriveoTheme.colors.textPrimary,
        )
        content()
    }
}

@Composable
private fun DeleteKeyDialog(confirmation: RelayKeyDeleteConfirmation, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val colors = OriveoTheme.colors
    val count = confirmation.modelIds.size
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.relay_key_delete_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = if (count > 0) {
                        pluralStringResource(R.plurals.relay_key_delete_message, count, count, confirmation.fallbackName)
                    } else {
                        stringResource(R.string.relay_key_delete_message_none)
                    },
                    style = OriveoTheme.typography.body,
                    color = colors.textPrimary,
                )
                // List the display names of the models using it one by one (an id when there is no name).
                confirmation.modelNames.forEach { name ->
                    Text(text = name, style = OriveoTheme.typography.caption, color = colors.textSecondary)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.delete), color = colors.danger)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}
