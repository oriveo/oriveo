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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.FeatureBadges
import ai.oriveo.community.core.search.SearchCatalogRepository
import ai.oriveo.community.core.search.SearchJson
import ai.oriveo.community.core.search.SearchSettings
import ai.oriveo.community.core.search.SearchServiceStore
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
 * The "Tools & connections" group on the settings home: web search and MCP servers side by side. The MCP cell is
 * hidden when `mcpRuntimeConfig.enabled = false` (stored servers are kept), leaving web search on its own.
 */
@Composable
fun SettingsToolsSection(
    onNavigateToMcpServers: () -> Unit,
    onNavigateToWebSearch: () -> Unit = {},
) {
    val store: McpServerStore = koinInject()
    val credentialStore: McpCredentialStore = koinInject()
    val searchStore: SearchServiceStore = koinInject()
    val searchCatalog: SearchCatalogRepository = koinInject()
    val preferences: AppPreferencesRepository = koinInject()
    val webSearchBadge by remember { preferences.featureBadgeUnseen(FeatureBadges.SETTINGS_WEB_SEARCH) }
        .collectAsStateWithLifecycle(initialValue = false)

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
    // Value of the web search cell: the default service's display name; no service yet = "Not set"
    var webSearchDefault by remember { mutableStateOf<WebSearchEntryValue?>(null) }
    LaunchedEffect(resumes) {
        webSearchDefault = withContext(Dispatchers.IO) {
            runCatching {
                if (searchCatalog.current() == null) searchCatalog.loadLocal()
                val id = searchStore.defaultServiceId(LOCAL_PARTITION_ID)
                val s = id?.let { searchStore.service(LOCAL_PARTITION_ID, it) }
                WebSearchEntryValue(
                    s?.let {
                        // Same display-name rule as the web search list (catalog displayName, then stored name, then serviceId).
                        SearchSettings.searchServiceDisplayName(
                            it.kind,
                            it.name,
                            it.serviceId,
                            it.serviceId?.let(searchCatalog::entry)?.let { e -> SearchJson.string(e["displayName"]) },
                        )
                    },
                )
            }.getOrNull()
        }
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

    SettingsToolsSectionContent(
        mcpSummary = summary,
        onNavigateToMcpServers = onNavigateToMcpServers,
        mcpEnabled = enabled,
        webSearchValue = webSearchDefault?.let { it.name ?: stringResource(R.string.web_search_entry_not_set) },
        webSearchBadge = webSearchBadge,
        onNavigateToWebSearch = onNavigateToWebSearch,
    )
}

/** Loaded value of the web search tile; [name] null = no service yet. */
private data class WebSearchEntryValue(val name: String?)

@Composable
internal fun SettingsToolsSectionContent(
    mcpSummary: McpSettingsEntrySummary?,
    onNavigateToMcpServers: () -> Unit,
    mcpEnabled: Boolean = true,
    webSearchValue: String? = null,
    webSearchBadge: Boolean = false,
    onNavigateToWebSearch: () -> Unit = {},
) {
    Column {
        SettingsSectionTitle(text = stringResource(R.string.mcp_settings_section))
        Spacer(modifier = Modifier.height(10.dp))
        SettingsGrid(
            items = buildList {
                add(
                    SettingsGridItem(
                        key = "webSearch",
                        icon = R.drawable.ic_settings_search,
                        title = stringResource(R.string.web_search_entry_title),
                        tag = "settings_web_search_tile",
                        value = webSearchValue,
                        showBadge = webSearchBadge,
                        onClick = onNavigateToWebSearch,
                    ),
                )
                if (mcpEnabled) {
                    add(
                        SettingsGridItem(
                            key = "mcp",
                            icon = R.drawable.ic_settings_mcp,
                            title = stringResource(R.string.mcp_servers_title),
                            tag = "settings_mcp_tile",
                            value = mcpSettingsEntrySubtitle(mcpSummary),
                            onClick = onNavigateToMcpServers,
                        ),
                    )
                }
            },
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
