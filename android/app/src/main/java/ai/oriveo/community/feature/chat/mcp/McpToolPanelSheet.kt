package ai.oriveo.community.feature.chat.mcp

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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Power
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpToolPanelServerRow
import ai.oriveo.community.core.mcp.McpToolPanelState
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.NumberFormat

/**
 * The "Tools in this conversation" panel. [McpToolPanelState] selects one of three forms:
 * the current model cannot use tools → no servers yet → the server list.
 */
@Composable
internal fun McpToolPanelSheet(
    state: McpToolPanelState,
    onDismiss: () -> Unit,
    onToggle: (serverId: String, enabled: Boolean) -> Unit,
    onReauthorize: (serverId: String) -> Unit,
    onManageServers: () -> Unit,
    onAddServer: () -> Unit,
    onSwitchModel: () -> Unit,
) {
    McpBottomSheet(
        onDismiss = onDismiss,
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 22.dp),
    ) {
        McpToolPanelContent(
            state = state,
            onToggle = onToggle,
            onReauthorize = onReauthorize,
            onManageServers = onManageServers,
            onAddServer = onAddServer,
            onSwitchModel = onSwitchModel,
        )
    }
}

@Composable
internal fun ColumnScope.McpToolPanelContent(
    state: McpToolPanelState,
    onToggle: (serverId: String, enabled: Boolean) -> Unit,
    onReauthorize: (serverId: String) -> Unit,
    onManageServers: () -> Unit,
    onAddServer: () -> Unit,
    onSwitchModel: () -> Unit,
) {
    when {
        !state.availability.isAvailable -> UnavailablePanel(state, onSwitchModel)
        !state.hasServers -> EmptyPanel(onAddServer)
        else -> ServerListPanel(state, onToggle, onReauthorize, onManageServers)
    }
}

@Composable
private fun ColumnScope.ServerListPanel(
    state: McpToolPanelState,
    onToggle: (String, Boolean) -> Unit,
    onReauthorize: (String) -> Unit,
    onManageServers: () -> Unit,
) {
    val colors = OriveoTheme.colors
    McpSheetHeader(
        title = stringResource(R.string.mcp_panel_title),
        subtitle = stringResource(R.string.mcp_panel_subtitle),
    )
    // At most maxServers servers (20 by default), laid out directly; beyond the available height this block scrolls internally so the footer note and entry point are not pushed out.
    McpCard(modifier = Modifier.heightIn(max = 340.dp).verticalScroll(rememberScrollState())) {
        state.rows.forEachIndexed { index, row ->
            if (index > 0) McpHairline()
            ServerRow(row = row, locked = false, onToggle = onToggle, onReauthorize = onReauthorize)
        }
    }
    if (state.truncated) {
        McpFootnote(
            text = stringResource(R.string.mcp_panel_footer_truncated, state.maxToolsPerRequest, state.maxToolsPerRequest),
            color = colors.warningText,
        )
    } else if (state.outboundToolCount > 0) {
        McpFootnote(
            text = pluralStringResource(
                R.plurals.mcp_panel_footer,
                state.outboundToolCount,
                state.outboundToolCount,
                NumberFormat.getIntegerInstance().format(state.estimatedTokens),
            ),
        )
    }
    Row(
        modifier = Modifier
            .align(Alignment.CenterHorizontally)
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(12.dp))
            .clickable(role = Role.Button, onClick = onManageServers)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = stringResource(R.string.mcp_panel_manage),
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
            color = colors.primaryTextSafe,
        )
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = colors.primaryTextSafe,
        )
    }
}

@Composable
private fun ServerRow(
    row: McpToolPanelServerRow,
    locked: Boolean,
    onToggle: (String, Boolean) -> Unit,
    onReauthorize: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    val dimmed = !locked && row.status is McpToolPanelServerRow.Status.Unreachable ||
        !locked && row.status == McpToolPanelServerRow.Status.NeedsAddress
    val detail = when (val status = row.status) {
        McpToolPanelServerRow.Status.Ready -> pluralStringResource(R.plurals.mcp_panel_tool_count, row.toolCount, row.toolCount)
        McpToolPanelServerRow.Status.NeedsAuth -> stringResource(R.string.mcp_panel_sign_in_expired)
        is McpToolPanelServerRow.Status.Unreachable -> status.lastSuccessAt?.let { at ->
            stringResource(
                R.string.mcp_panel_cant_connect_last_worked,
                DateUtils.getRelativeTimeSpanString(at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString(),
            )
        } ?: stringResource(R.string.mcp_panel_cant_connect)
        McpToolPanelServerRow.Status.NeedsAddress -> stringResource(R.string.mcp_panel_needs_address)
    }
    val detailColor = when {
        locked -> colors.textTertiary
        row.status == McpToolPanelServerRow.Status.NeedsAuth -> colors.warningText
        else -> colors.textTertiary
    }
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 62.dp).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        McpServerIcon(name = row.name, iconUrl = row.iconURL)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                text = row.name,
                style = OriveoTheme.typography.body,
                color = if (dimmed) colors.textSecondary else colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = detail,
                style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp),
                color = detailColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (!locked && row.status == McpToolPanelServerRow.Status.NeedsAuth) {
            McpInlineAction(
                text = stringResource(R.string.mcp_sign_in_again),
                onClick = { onReauthorize(row.id) },
            )
        } else {
            val name = row.name
            Switch(
                checked = !locked && row.isEnabled,
                onCheckedChange = { enabled -> onToggle(row.id, enabled) },
                enabled = !locked && row.canToggle,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Color.White,
                    checkedTrackColor = colors.primary,
                    uncheckedThumbColor = Color.White,
                    uncheckedTrackColor = colors.borderStrong,
                    uncheckedBorderColor = Color.Transparent,
                    disabledUncheckedThumbColor = Color.White,
                    disabledUncheckedTrackColor = colors.border,
                    disabledUncheckedBorderColor = Color.Transparent,
                ),
                // The switch has no label of its own; without a contentDescription it would be announced as just "switch".
                modifier = Modifier.semantics { contentDescription = name },
            )
        }
    }
}

@Composable
private fun ColumnScope.EmptyPanel(onAddServer: () -> Unit) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(68.dp).background(colors.primarySoft, RoundedCornerShape(22.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.Power,
                contentDescription = null,
                modifier = Modifier.size(32.dp),
                tint = colors.primaryTextSafe,
            )
        }
        Text(
            text = stringResource(R.string.mcp_panel_empty_title),
            style = OriveoTheme.typography.title1.copy(fontSize = 20.sp, lineHeight = 26.sp),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            text = stringResource(R.string.mcp_panel_empty_body),
            style = OriveoTheme.typography.caption.copy(fontSize = 14.5.sp, lineHeight = 22.sp),
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
    OriveoPrimaryButton(
        text = stringResource(R.string.mcp_panel_add_server),
        onClick = onAddServer,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}

@Composable
private fun ColumnScope.UnavailablePanel(state: McpToolPanelState, onSwitchModel: () -> Unit) {
    val colors = OriveoTheme.colors
    McpSheetHeader(title = stringResource(R.string.mcp_panel_title))
    val noticeShape = RoundedCornerShape(16.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.warningSoft, noticeShape)
            .border(1.dp, colors.warning.copy(alpha = 0.35f), noticeShape)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = stringResource(R.string.mcp_panel_unavailable_title),
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
            color = colors.warningText,
        )
        Text(
            text = stringResource(R.string.mcp_panel_unavailable_model),
            style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp),
            color = colors.textSecondary,
        )
    }
    if (state.hasServers) {
        // The list is greyed out and inert: it only shows the user that the servers are still there and will work with another model.
        McpCard(modifier = Modifier.alpha(0.5f).heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
            state.rows.forEachIndexed { index, row ->
                if (index > 0) McpHairline()
                ServerRow(row = row, locked = true, onToggle = { _, _ -> }, onReauthorize = {})
            }
        }
    }
    McpSecondaryButton(
        text = stringResource(R.string.mcp_panel_switch_model),
        onClick = onSwitchModel,
    )
}
