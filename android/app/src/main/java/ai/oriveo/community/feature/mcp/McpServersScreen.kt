package ai.oriveo.community.feature.mcp

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Power
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpServerHealth
import ai.oriveo.community.core.mcp.McpServerSummary
import ai.oriveo.community.feature.chat.mcp.McpCard
import ai.oriveo.community.feature.chat.mcp.McpFootnote
import ai.oriveo.community.feature.chat.mcp.McpServerIcon
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

/** MCP servers screen: the empty state and the server list. */
@Composable
fun McpServersScreen(
    onBack: () -> Unit,
    onAddServer: () -> Unit,
    onOpenServer: (serverId: String) -> Unit,
    viewModel: McpServersViewModel = koinViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    // Re-read whenever we come back from the add / detail screens or from the system browser.
    LifecycleResumeEffect(viewModel) {
        viewModel.reload()
        onPauseOrDispose { }
    }
    McpServersContent(
        state = state,
        onBack = onBack,
        onAddServer = onAddServer,
        onOpenServer = onOpenServer,
        onRefresh = viewModel::refresh,
    )
}

@Composable
internal fun McpServersContent(
    state: McpServersUiState,
    onBack: () -> Unit,
    onAddServer: () -> Unit,
    onOpenServer: (String) -> Unit,
    onRefresh: () -> Unit = {},
) {
    val empty = state.loaded && state.servers.isEmpty()
    McpPageScaffold(
        title = stringResource(R.string.mcp_servers_title),
        onBack = onBack,
        // Pull to refresh (re-probing connection state) is only available when there are servers.
        refresh = if (state.servers.isNotEmpty()) McpPullRefresh(state.refreshing, onRefresh) else null,
        actions = {
            if (state.servers.isNotEmpty()) {
                IconButton(onClick = onAddServer) {
                    Icon(
                        Icons.Outlined.Add,
                        contentDescription = stringResource(R.string.mcp_add_server),
                        tint = OriveoTheme.colors.textSecondary,
                    )
                }
            }
        },
        bottomBar = if (empty) {
            {
                OriveoPrimaryButton(
                    text = stringResource(R.string.mcp_add_server),
                    onClick = onAddServer,
                )
            }
        } else {
            null
        },
    ) {
        when {
            !state.loaded -> Unit
            empty -> EmptyState()
            else -> ServerList(state.servers, onOpenServer)
        }
    }
}

// ── Empty state ─────────────────────────────────────────────

@Composable
private fun EmptyState() {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(84.dp).background(colors.primarySoft, RoundedCornerShape(26.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Outlined.Power, contentDescription = null, modifier = Modifier.size(38.dp), tint = colors.primaryTextSafe)
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = stringResource(R.string.mcp_servers_empty_title),
            style = OriveoTheme.typography.hero.copy(fontSize = 26.sp, lineHeight = 32.sp, fontWeight = FontWeight.ExtraBold),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.mcp_servers_empty_body),
            style = OriveoTheme.typography.body.copy(lineHeight = 24.sp),
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
    // The three promises reuse the settings privacy card style: a green check plus one sentence.
    McpCard(contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp)) {
        listOf(R.string.mcp_promise_credentials, R.string.mcp_promise_confirm, R.string.mcp_promise_per_chat).forEach { promise ->
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Filled.CheckCircle, contentDescription = null, modifier = Modifier.size(18.dp), tint = colors.success)
                Text(text = stringResource(promise), style = OriveoTheme.typography.body.copy(fontSize = 15.sp), color = colors.textPrimary)
            }
        }
    }
}

// ── Server list ─────────────────────────────────────────────

@Composable
private fun ServerList(servers: List<McpServerSummary>, onOpenServer: (String) -> Unit) {
    McpSectionTitle(
        title = stringResource(R.string.mcp_servers_added),
        trailing = stringResource(R.string.mcp_count, servers.size),
    )
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        servers.forEach { server -> ServerCard(server, onClick = { onOpenServer(server.record.id) }) }
    }
    McpFootnote(stringResource(R.string.mcp_servers_trust_note))
}

/** A server's status pill and the caption next to it (shared by the list card and the detail screen's hero card). */
@Composable
internal fun McpHealthPill(health: McpServerHealth) {
    when (health) {
        McpServerHealth.Connected -> McpStatusPill(stringResource(R.string.mcp_status_connected), McpPillTone.Success)
        McpServerHealth.NeedsAuth -> McpStatusPill(stringResource(R.string.mcp_panel_sign_in_expired), McpPillTone.Warning)
        McpServerHealth.Unreachable -> McpStatusPill(stringResource(R.string.mcp_panel_cant_connect), McpPillTone.Neutral)
        McpServerHealth.NeedsReview -> McpStatusPill(stringResource(R.string.mcp_status_tools_changed), McpPillTone.Primary)
        McpServerHealth.NeedsAddress -> McpStatusPill(stringResource(R.string.mcp_status_needs_address), McpPillTone.Warning)
    }
}

@Composable
internal fun mcpHealthCaption(server: McpServerSummary): String? = when (server.health) {
    McpServerHealth.Connected -> pluralStringResource(R.plurals.mcp_panel_tool_count, server.toolCount, server.toolCount)
    McpServerHealth.NeedsAuth -> stringResource(R.string.mcp_servers_needs_reauth)
    McpServerHealth.Unreachable -> server.lastSuccessAt?.let { at ->
        stringResource(
            R.string.mcp_servers_last_worked,
            DateUtils.getRelativeTimeSpanString(at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString(),
        )
    }
    McpServerHealth.NeedsReview -> stringResource(R.string.mcp_servers_needs_review)
    McpServerHealth.NeedsAddress -> stringResource(R.string.mcp_servers_needs_address)
}

@Composable
private fun ServerCard(server: McpServerSummary, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    McpCard(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .clickable(role = Role.Button, onClick = onClick),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            McpServerIcon(name = server.record.name, iconUrl = server.iconUrl, size = 44.dp)
            Column(modifier = Modifier.weight(1f).heightIn(min = 44.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = server.record.name,
                    style = OriveoTheme.typography.title2,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    McpHealthPill(server.health)
                    mcpHealthCaption(server)?.let { caption ->
                        Text(
                            text = caption,
                            style = OriveoTheme.typography.caption,
                            color = colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = colors.textTertiary,
            )
        }
    }
}
