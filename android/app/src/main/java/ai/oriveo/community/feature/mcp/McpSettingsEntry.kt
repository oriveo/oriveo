package ai.oriveo.community.feature.mcp

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import ai.oriveo.community.R
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpServerOverview
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.feature.settings.SettingsGrid
import ai.oriveo.community.feature.settings.SettingsGridItem
import ai.oriveo.community.feature.settings.SettingsSectionTitle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.koin.compose.koinInject

/** Subtitle data for the "MCP servers" row on the settings screen. */
data class McpSettingsEntrySummary(val serverCount: Int, val attentionCount: Int)

/**
 * The "Tools & connections" group on the settings home: a single MCP servers cell. It is hidden entirely when
 * `mcpRuntimeConfig.enabled = false` (stored servers are kept).
 */
@Composable
fun SettingsToolsSection(
    onNavigateToMcpServers: () -> Unit,
) {
    val store: McpServerStore = koinInject()
    val credentialStore: McpCredentialStore = koinInject()

    // The master switch comes with the model catalog; it takes effect after a catalog refresh without a restart.
    var metadataVersion by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { MetadataClient.refreshEvents.collect { metadataVersion += 1 } }
    val enabled = remember(metadataVersion) { MetadataClient.mcpRuntimeConfig().enabled }

    var summary by remember { mutableStateOf<McpSettingsEntrySummary?>(null) }
    var resumes by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) {
        resumes += 1
        onPauseOrDispose { }
    }
    LaunchedEffect(resumes, enabled) {
        if (!enabled) return@LaunchedEffect
        summary = withContext(Dispatchers.IO) {
            runCatching {
                val servers = McpServerOverview.load(store, credentialStore, LOCAL_PARTITION_ID)
                McpSettingsEntrySummary(servers.size, McpServerOverview.attentionCount(servers))
            }.getOrNull()
        }
    }

    if (!enabled) return
    SettingsToolsSectionContent(
        mcpSummary = summary,
        onNavigateToMcpServers = onNavigateToMcpServers,
    )
}

@Composable
internal fun SettingsToolsSectionContent(
    mcpSummary: McpSettingsEntrySummary?,
    onNavigateToMcpServers: () -> Unit,
) {
    Column {
        SettingsSectionTitle(text = stringResource(R.string.mcp_settings_section))
        Spacer(modifier = Modifier.height(10.dp))
        SettingsGrid(
            items = listOf(
                SettingsGridItem(
                    key = "mcp",
                    icon = R.drawable.ic_settings_mcp,
                    title = stringResource(R.string.mcp_servers_title),
                    tag = "settings_mcp_tile",
                    value = mcpSettingsEntrySubtitle(mcpSummary),
                    onClick = onNavigateToMcpServers,
                ),
            ),
        )
    }
}

/** Subtitle: no numbers while nothing has been read or there are no servers; the second half only appears when something needs attention. */
@Composable
internal fun mcpSettingsEntrySubtitle(summary: McpSettingsEntrySummary?): String? = when {
    summary == null -> null
    summary.serverCount == 0 -> stringResource(R.string.mcp_servers_empty_title)
    // Each number uses its own plural form ("1 server · 1 needs attention"), then they are joined the way each language does it.
    summary.attentionCount > 0 -> stringResource(
        R.string.mcp_settings_entry_count_attention,
        pluralStringResource(R.plurals.mcp_settings_entry_count, summary.serverCount, summary.serverCount),
        pluralStringResource(R.plurals.mcp_settings_entry_attention, summary.attentionCount, summary.attentionCount),
    )
    else -> pluralStringResource(R.plurals.mcp_settings_entry_count, summary.serverCount, summary.serverCount)
}
