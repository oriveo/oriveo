package ai.oriveo.community.feature.mcp

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpOrigin
import ai.oriveo.community.core.mcp.McpPendingToolChange
import ai.oriveo.community.core.mcp.McpServerHealth
import ai.oriveo.community.core.mcp.McpToolChange
import ai.oriveo.community.core.mcp.McpToolChangeKind
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.mcp.McpToolSnapshot
import ai.oriveo.community.feature.chat.mcp.McpBottomSheet
import ai.oriveo.community.feature.chat.mcp.McpCard
import ai.oriveo.community.feature.chat.mcp.McpCodeBlock
import ai.oriveo.community.feature.chat.mcp.McpFootnote
import ai.oriveo.community.feature.chat.mcp.McpHairline
import ai.oriveo.community.feature.chat.mcp.McpInlineAction
import ai.oriveo.community.feature.chat.mcp.McpQuietButton
import ai.oriveo.community.feature.chat.mcp.McpServerIcon
import ai.oriveo.community.feature.chat.mcp.McpSheetHeader
import ai.oriveo.community.ui.component.OriveoFullScreenDialog
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme

/** User actions on the detail screen. */
internal class McpDetailActions(
    val onBack: () -> Unit,
    val onReloadTools: () -> Unit = {},
    val onReauthorize: () -> Unit = {},
    val onOpenChanges: () -> Unit = {},
    val onOpenPermission: (toolName: String) -> Unit = {},
    val onAskRemove: () -> Unit = {},
    val onAddressChange: (String) -> Unit = {},
    val onSaveAddress: () -> Unit = {},
)

/** Server detail, plus what opens from it: the permission sheet, the tool-change confirmation and the removal confirmation. */
@Composable
fun McpServerDetailScreen(
    onBack: () -> Unit,
    viewModel: McpServerDetailViewModel,
) {
    val controller = viewModel.controller
    val state by controller.state.collectAsStateWithLifecycle()

    // Reload on return from the system browser or from another screen.
    LifecycleResumeEffect(controller) {
        controller.reload()
        onPauseOrDispose { }
    }
    // The server is gone (it was just removed): leave this screen.
    LaunchedEffect(state.gone) {
        if (state.gone) onBack()
    }

    McpServerDetailContent(
        state = state,
        actions = McpDetailActions(
            onBack = onBack,
            onReloadTools = controller::reloadTools,
            onReauthorize = controller::reauthorize,
            onOpenChanges = controller::openChanges,
            onOpenPermission = controller::openPermission,
            onAskRemove = controller::askRemove,
            onAddressChange = controller::updateAddressDraft,
            onSaveAddress = controller::saveAddress,
        ),
    )

    val name = state.summary?.record?.name.orEmpty()

    state.permissionTool?.let { toolName ->
        state.snapshots.firstOrNull { it.toolName == toolName }?.let { tool ->
            McpBottomSheet(onDismiss = controller::dismissPermission) {
                McpToolPermissionContent(
                    serverName = name,
                    tool = tool,
                    selected = state.permission(tool),
                    onSelect = { controller.setPermission(toolName, it) },
                )
            }
        }
    }

    state.changes?.let { sheet ->
        McpBottomSheet(onDismiss = controller::dismissChanges, dismissible = state.busy != McpDetailBusy.Confirming) {
            McpToolsChangedContent(
                serverName = name,
                pending = state.pending,
                sheet = sheet,
                confirming = state.busy == McpDetailBusy.Confirming,
                onConfirm = controller::confirmChanges,
                onPause = controller::pause,
                serverIconUrl = state.summary?.iconUrl,
            )
        }
    }

    if (state.showRemoveConfirm) {
        // Centred dialog. Goes through the full-screen Dialog wrapper (the window has its own toast host) and centres its content; tapping outside the card = cancel.
        OriveoFullScreenDialog(onDismissRequest = controller::dismissRemove) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    // Tapping the empty area outside the dialog closes it, same as "Cancel".
                    .clickable(interactionSource = null, indication = null, onClick = controller::dismissRemove)
                    .padding(horizontal = 36.dp),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    // Swallows taps landing on the card so they do not reach the outer tap-to-dismiss.
                    modifier = Modifier.clickable(interactionSource = null, indication = null, onClick = {}),
                ) {
                    McpRemoveConfirmContent(
                        serverName = name,
                        removing = state.busy == McpDetailBusy.Removing,
                        failed = state.notice == McpDetailNotice.RemoveFailed,
                        onRemove = controller::confirmRemove,
                        onCancel = controller::dismissRemove,
                    )
                }
            }
        }
    }
}

@Composable
internal fun McpServerDetailContent(state: McpServerDetailUiState, actions: McpDetailActions) {
    val summary = state.summary
    McpPageScaffold(title = summary?.record?.name.orEmpty(), onBack = actions.onBack) {
        if (summary == null) return@McpPageScaffold
        val colors = OriveoTheme.colors
        val record = summary.record

        McpHeroCard(
            name = record.name,
            iconUrl = summary.iconUrl,
            status = { McpHealthPill(summary.health) },
            caption = when (summary.health) {
                McpServerHealth.NeedsAuth -> stringResource(R.string.mcp_detail_tools_unavailable)
                else -> mcpHealthCaption(summary)
            },
        ) {
            Column(modifier = Modifier.padding(top = 14.dp)) {
                DetailRow(stringResource(R.string.mcp_detail_address), mcpDisplayAddress(record.url), monospace = true)
                McpHairline()
                DetailRow(
                    stringResource(R.string.mcp_detail_sign_in),
                    stringResource(
                        when (state.signIn) {
                            McpSignInLabel.Browser -> R.string.mcp_detail_sign_in_browser
                            McpSignInLabel.Token -> R.string.mcp_access_token
                            McpSignInLabel.None -> R.string.mcp_detail_sign_in_none
                        },
                    ),
                )
                McpHairline()
                DetailRow(
                    stringResource(R.string.mcp_detail_last_connected),
                    summary.lastSuccessAt?.let { at ->
                        DateUtils.getRelativeTimeSpanString(at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
                    } ?: stringResource(R.string.mcp_detail_never),
                )
            }
            Column(modifier = Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when (summary.health) {
                    McpServerHealth.NeedsAuth -> OriveoPrimaryButton(
                        text = stringResource(R.string.mcp_sign_in_again),
                        onClick = actions.onReauthorize,
                    )
                    McpServerHealth.NeedsAddress -> AddressEntry(state, actions)
                    else -> {
                        if (summary.health == McpServerHealth.NeedsReview) {
                            OriveoPrimaryButton(
                                text = stringResource(R.string.mcp_detail_review_changes),
                                onClick = actions.onOpenChanges,
                            )
                        }
                        SoftButton(
                            text = stringResource(
                                if (state.busy == McpDetailBusy.Reloading) R.string.mcp_detail_reloading else R.string.mcp_detail_reload_tools,
                            ),
                            busy = state.busy == McpDetailBusy.Reloading,
                            onClick = actions.onReloadTools,
                        )
                    }
                }
                if (state.notice == McpDetailNotice.Unreachable) {
                    Text(
                        text = stringResource(R.string.mcp_detail_unreachable),
                        style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp, lineHeight = 18.sp),
                        color = colors.danger,
                    )
                }
            }
        }

        // With expired authorization / an address not on this device the tool list is greyed out and inert.
        Column(
            modifier = Modifier.alpha(if (state.toolsLocked) 0.5f else 1f),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            if (state.snapshots.isEmpty() && summary.health == McpServerHealth.Connected) {
                McpFootnote(stringResource(R.string.mcp_no_tools), color = colors.textSecondary)
            }
            ToolGroup(stringResource(R.string.mcp_group_read_only), state.readOnlyTools, state, actions)
            ToolGroup(stringResource(R.string.mcp_group_changes_data), state.changingTools, state, actions)
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .clip(RoundedCornerShape(12.dp))
                .clickable(role = Role.Button, onClick = actions.onAskRemove),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = stringResource(R.string.mcp_detail_remove_server),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.danger,
            )
        }
    }
}

/** Display form of the address: scheme removed, host and path kept; the query string is not shown. */
internal fun mcpDisplayAddress(url: String): String {
    val uri = McpOrigin.parse(url) ?: return url
    val host = uri.host?.takeIf { it.isNotEmpty() } ?: return url
    val port = if (uri.port >= 0) ":${uri.port}" else ""
    val path = uri.rawPath.orEmpty().takeUnless { it == "/" }.orEmpty()
    return host + port + path
}

@Composable
private fun DetailRow(label: String, value: String, monospace: Boolean = false) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(vertical = 10.dp).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.caption,
            color = colors.textTertiary,
            modifier = Modifier.width(96.dp),
        )
        Text(
            text = value,
            style = if (monospace) {
                OriveoTheme.typography.code.copy(fontSize = 13.5.sp)
            } else {
                OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.Medium)
            },
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.MiddleEllipsis,
        )
    }
}

/** Secondary button in the hero card: brand-tinted background + brand outline + brand text ("Reload tools"). */
@Composable
private fun SoftButton(text: String, busy: Boolean, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(16.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(OriveoTheme.layout.buttonHeight)
            .clip(shape)
            .background(colors.primarySoft)
            .border(1.dp, colors.primary.copy(alpha = 0.3f), shape)
            .clickable(enabled = !busy, role = Role.Button, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.primaryTextSafe, trackColor = colors.border)
        }
        Text(text = text, style = OriveoTheme.typography.title3, color = colors.primaryTextSafe, maxLines = 1)
    }
}

/** The full address is not on this device; ask the user to enter it again. */
@Composable
private fun AddressEntry(state: McpServerDetailUiState, actions: McpDetailActions) {
    McpNoticeBlock(
        title = stringResource(R.string.mcp_detail_needs_address_title),
        body = stringResource(R.string.mcp_detail_needs_address_body),
        tone = McpPillTone.Warning,
    )
    McpTextField(
        value = state.addressDraft,
        onValueChange = actions.onAddressChange,
        label = stringResource(R.string.mcp_add_address),
        placeholder = stringResource(R.string.mcp_add_address_placeholder),
        errorText = state.addressError?.let { mcpInvalidUrlText(it) },
        monospace = true,
        keyboardType = KeyboardType.Uri,
    )
    OriveoPrimaryButton(
        text = stringResource(R.string.mcp_detail_save_address),
        onClick = actions.onSaveAddress,
        enabled = state.addressDraft.isNotBlank() && state.addressError == null,
        loading = state.busy == McpDetailBusy.SavingAddress,
    )
}

// ── Tool groups: 3 shown per group, the rest collapsed ──────

private const val COLLAPSED_TOOL_COUNT = 3

@Composable
private fun ToolGroup(title: String, tools: List<McpToolSnapshot>, state: McpServerDetailUiState, actions: McpDetailActions) {
    if (tools.isEmpty()) return
    val colors = OriveoTheme.colors
    var expanded by rememberSaveable(title) { mutableStateOf(false) }
    val visible = if (expanded) tools else tools.take(COLLAPSED_TOOL_COUNT)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        McpSectionTitle(title = title, trailing = stringResource(R.string.mcp_count, tools.size))
        McpCard(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
            visible.forEachIndexed { index, tool ->
                if (index > 0) McpHairline()
                ToolRow(tool, state, actions)
            }
            if (!expanded && tools.size > COLLAPSED_TOOL_COUNT) {
                McpHairline()
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 46.dp)
                        .clickable(enabled = !state.toolsLocked, role = Role.Button) { expanded = true },
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Text(
                        text = stringResource(R.string.mcp_detail_show_more, tools.size - COLLAPSED_TOOL_COUNT),
                        style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.primaryTextSafe,
                    )
                }
            }
        }
    }
}

@Composable
private fun ToolRow(tool: McpToolSnapshot, state: McpServerDetailUiState, actions: McpDetailActions) {
    val colors = OriveoTheme.colors
    val permission = state.permission(tool)
    val permissionText = mcpPermissionText(permission)
    val label = stringResource(R.string.mcp_detail_permission_for, tool.title)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            // An oversized tool cannot be sent, so there is no permission to choose.
            .clickable(enabled = !state.toolsLocked && !tool.oversized, role = Role.Button, onClickLabel = label) {
                actions.onOpenPermission(tool.toolName)
            }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = tool.title,
                style = OriveoTheme.typography.body,
                color = if (permission == McpToolPermission.Off || tool.oversized) colors.textTertiary else colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val note = when {
                tool.oversized -> stringResource(R.string.mcp_detail_oversized)
                tool.pendingReview -> stringResource(R.string.mcp_servers_needs_review)
                else -> null
            }
            if (note != null) {
                Text(text = note, style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp), color = colors.warningText)
            }
        }
        if (!tool.oversized) {
            Text(text = permissionText, style = OriveoTheme.typography.body.copy(fontSize = 15.sp), color = colors.textSecondary, maxLines = 1)
            Icon(Icons.Outlined.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp), tint = colors.textTertiary)
        }
    }
}

// ── Permission for a single tool ────────────────────────────

/**
 * The server's description verbatim (not translated) + a three-way single choice. The recommended option comes first: "Ask every time"
 * for tools that modify data, "Run automatically" for read-only ones. For a modifying tool, the caption of "Run automatically" is the warning.
 */
@Composable
internal fun ColumnScope.McpToolPermissionContent(
    serverName: String,
    tool: McpToolSnapshot,
    selected: McpToolPermission,
    onSelect: (McpToolPermission) -> Unit,
) {
    val colors = OriveoTheme.colors
    McpSheetHeader(
        title = tool.title,
        subtitle = stringResource(
            R.string.mcp_permission_subtitle,
            serverName,
            stringResource(if (tool.readOnly) R.string.mcp_group_read_only else R.string.mcp_group_changes_data),
        ),
    )
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = stringResource(R.string.mcp_permission_description_title),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textTertiary,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
        McpCodeBlock(
            text = tool.description?.takeIf { it.isNotBlank() } ?: stringResource(R.string.mcp_permission_no_description),
            maxHeight = 160.dp,
            monospace = false,
        )
    }
    val recommended = McpToolPermission.defaultFor(tool.readOnly)
    val order = listOf(recommended) + McpToolPermission.entries.filterNot { it == recommended || it == McpToolPermission.Off } + McpToolPermission.Off
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        order.forEach { option ->
            val hint = when (option) {
                McpToolPermission.Ask -> stringResource(R.string.mcp_permission_ask_hint)
                McpToolPermission.Auto ->
                    if (tool.readOnly) {
                        stringResource(R.string.mcp_permission_auto_hint_read)
                    } else {
                        stringResource(R.string.mcp_permission_auto_hint_write, serverName)
                    }
                McpToolPermission.Off -> stringResource(R.string.mcp_permission_off_hint)
            }
            PermissionOption(
                title = mcpPermissionText(option),
                hint = hint,
                recommended = option == recommended,
                selected = option == selected,
                onClick = { onSelect(option) },
            )
        }
    }
}

/** Radio card: radius 16; brand-tinted background + brand outline + filled check when selected. */
@Composable
private fun PermissionOption(title: String, hint: String, recommended: Boolean, selected: Boolean, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(16.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (selected) colors.primarySoft else colors.surface)
            .border(1.dp, if (selected) colors.primary.copy(alpha = 0.45f) else colors.border, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .padding(top = 1.dp)
                .size(22.dp)
                .background(if (selected) colors.primary else colors.surface, CircleShape)
                .border(1.5.dp, if (selected) colors.primary else colors.borderStrong, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (selected) Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(14.dp), tint = colors.onPrimary)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(text = title, style = OriveoTheme.typography.title3, color = colors.textPrimary)
                if (recommended) McpStatusPill(stringResource(R.string.mcp_permission_recommended), McpPillTone.Primary)
            }
            Text(text = hint, style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp), color = colors.textSecondary)
        }
    }
}

// ── Tool changes awaiting confirmation ──────────────────────

/**
 * Lists the quarantined tools (new / description changed) and those this read found removed. "Confirm and keep using" fetches the definitions
 * from the server once more and only releases the ones matching what the user saw. The permission on each row is the level that takes effect after confirming (it can only go down, never up).
 */
@Composable
internal fun ColumnScope.McpToolsChangedContent(
    serverName: String,
    pending: List<McpPendingToolChange>,
    sheet: McpChangesSheetState,
    confirming: Boolean,
    onConfirm: () -> Unit,
    onPause: () -> Unit,
    serverIconUrl: String? = null,
) {
    val colors = OriveoTheme.colors
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(horizontal = 4.dp)) {
        McpServerIcon(name = serverName, iconUrl = serverIconUrl, size = 44.dp)
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                text = stringResource(R.string.mcp_changes_title, serverName),
                style = OriveoTheme.typography.title1.copy(fontSize = 20.sp, lineHeight = 26.sp),
                color = colors.textPrimary,
                modifier = Modifier.semantics { heading() },
            )
            Text(text = stringResource(R.string.mcp_changes_subtitle), style = OriveoTheme.typography.caption, color = colors.textSecondary)
        }
    }
    val before = remember(sheet.previous) { sheet.previous.associateBy { it.toolName } }
    // Sheet height follows the content; with many items this block scrolls internally so the buttons are not pushed out. No lazy containers in the content.
    McpCard(
        modifier = Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 2.dp),
    ) {
        var first = true
        pending.forEach { change ->
            if (!first) McpHairline()
            first = false
            PendingChangeRow(change, earlier = before[change.snapshot.toolName])
        }
        sheet.removed.forEach { change ->
            if (!first) McpHairline()
            first = false
            RemovedChangeRow(change)
        }
    }
    sheet.notice?.let { notice ->
        Text(
            text = stringResource(
                when (notice) {
                    McpChangesNotice.StillPending -> R.string.mcp_changes_still_pending
                    McpChangesNotice.NeedsAuth -> R.string.mcp_changes_failed_auth
                    McpChangesNotice.Unreachable -> R.string.mcp_detail_unreachable
                },
            ),
            style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp),
            color = colors.warningText,
            modifier = Modifier.padding(horizontal = 6.dp),
        )
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        OriveoPrimaryButton(
            text = stringResource(if (confirming) R.string.mcp_changes_confirming else R.string.mcp_changes_confirm),
            onClick = onConfirm,
            enabled = pending.isNotEmpty(),
            loading = confirming,
        )
        McpQuietButton(text = stringResource(R.string.mcp_changes_pause), onClick = onPause)
    }
}

@Composable
private fun PendingChangeRow(change: McpPendingToolChange, earlier: McpToolSnapshot?) {
    val colors = OriveoTheme.colors
    var expanded by remember(change.snapshot.toolName) { mutableStateOf(false) }
    val added = change.kind == McpToolChangeKind.Added
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            McpStatusPill(
                text = stringResource(if (added) R.string.mcp_changes_new else R.string.mcp_changes_changed),
                tone = if (added) McpPillTone.Primary else McpPillTone.Warning,
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = change.snapshot.title,
                    style = OriveoTheme.typography.body,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = stringResource(
                        R.string.mcp_changes_row_hint,
                        stringResource(if (change.snapshot.readOnly) R.string.mcp_group_read_only else R.string.mcp_group_changes_data),
                        mcpPermissionText(change.permissionAfter),
                    ),
                    style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp),
                    color = colors.textTertiary,
                )
            }
            McpInlineAction(
                text = stringResource(if (expanded) R.string.mcp_changes_hide else R.string.mcp_changes_see),
                onClick = { expanded = !expanded },
            )
        }
        if (expanded) {
            // Shown exactly as the server provides it, not translated.
            if (!added) {
                DiffBlock(
                    label = stringResource(R.string.mcp_changes_before),
                    text = when {
                        earlier == null -> stringResource(R.string.mcp_changes_before_unavailable)
                        earlier.description.isNullOrBlank() -> stringResource(R.string.mcp_permission_no_description)
                        else -> earlier.description.orEmpty()
                    },
                )
            }
            DiffBlock(
                label = stringResource(R.string.mcp_changes_now),
                text = change.snapshot.description?.takeIf { it.isNotBlank() } ?: stringResource(R.string.mcp_permission_no_description),
            )
        }
    }
}

@Composable
private fun DiffBlock(label: String, text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = label,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = OriveoTheme.colors.textTertiary,
        )
        McpCodeBlock(text = text, maxHeight = 120.dp, monospace = false)
    }
}

@Composable
private fun RemovedChangeRow(change: McpToolChange) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        McpStatusPill(text = stringResource(R.string.mcp_changes_removed), tone = McpPillTone.Neutral)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(text = change.title, style = OriveoTheme.typography.body, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                text = stringResource(R.string.mcp_changes_removed_hint),
                style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp),
                color = colors.textTertiary,
            )
        }
    }
}

// ── Removal confirmation ────────────────────────────────────

/** Centred dialog: title, description, destructive button, cancel. */
@Composable
internal fun McpRemoveConfirmContent(
    serverName: String,
    removing: Boolean,
    failed: Boolean,
    onRemove: () -> Unit,
    onCancel: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(28.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.background, shape)
            .padding(start = 20.dp, end = 20.dp, top = 26.dp, bottom = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = stringResource(R.string.mcp_remove_title, serverName),
            style = OriveoTheme.typography.title1.copy(fontSize = 20.sp, lineHeight = 26.sp),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.mcp_remove_body),
            style = OriveoTheme.typography.caption.copy(lineHeight = 21.sp),
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
        if (failed) {
            Text(
                text = stringResource(R.string.mcp_remove_failed),
                style = OriveoTheme.typography.caption,
                color = colors.danger,
                textAlign = TextAlign.Center,
            )
        }
        val buttonShape = RoundedCornerShape(16.dp)
        val removeLabel = stringResource(R.string.remove)
        Box(
            modifier = Modifier
                .padding(top = 6.dp)
                .fillMaxWidth()
                .height(OriveoTheme.layout.buttonHeight)
                .clip(buttonShape)
                .background(colors.dangerSoft)
                .border(1.dp, colors.danger.copy(alpha = 0.28f), buttonShape)
                // While removing, the button shows only a spinner: a screen reader must still be able to say which button this is (it is disabled at that point).
                .semantics { if (removing) contentDescription = removeLabel }
                .clickable(enabled = !removing, role = Role.Button, onClick = onRemove),
            contentAlignment = Alignment.Center,
        ) {
            if (removing) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.danger, trackColor = colors.border)
            } else {
                Text(text = removeLabel, style = OriveoTheme.typography.title3, color = colors.danger)
            }
        }
        McpQuietButton(text = stringResource(R.string.cancel), onClick = onCancel)
    }
}
