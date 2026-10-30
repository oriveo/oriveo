package ai.oriveo.community.feature.settings.websearch

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.AttachMoney
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.search.SavedSearchService
import ai.oriveo.community.core.search.SearchCatalog
import ai.oriveo.community.core.search.SearchCustomService
import ai.oriveo.community.core.search.SearchJson
import ai.oriveo.community.core.search.SearchSettings
import ai.oriveo.community.core.search.SearchTestPresentation
import ai.oriveo.community.feature.mcp.McpTextField
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.serialization.json.JsonObject
import org.koin.androidx.compose.koinViewModel

/** Pages inside the web search settings route (full-screen pages, like the MCP add flow). */
internal sealed interface WsPageKey {
    data object Main : WsPageKey
    data object Add : WsPageKey
    data class Connect(val draft: PresetDraft) : WsPageKey
    data class CustomForm(val draft: CustomDraft) : WsPageKey
    data class CustomConsent(val draft: CustomDraft) : WsPageKey
    data class Detail(val id: String) : WsPageKey
    data class ResultCount(val id: String) : WsPageKey
}

@Composable
fun WebSearchSettingsScreen(
    onBack: () -> Unit,
    viewModel: WebSearchSettingsViewModel = koinViewModel(),
) {
    WebSearchSettingsPages(onBack, viewModel, listOf(WsPageKey.Main))
}

/**
 * Web search settings opened from the chat web search card action: [oneTap] non-null = connect page
 * prefilled with the reused connection, and a passed test calls [onEnabled] (the card then turns this chat's web search on);
 * null = the add flow (back returns to the chat; nothing is turned on).
 */
@Composable
fun WebSearchFromChatScreen(
    oneTap: PresetDraft?,
    onBack: () -> Unit,
    onEnabled: () -> Unit,
    viewModel: WebSearchSettingsViewModel = koinViewModel(),
) {
    // Leaving this settings page settles an add / one-tap enable started from the panel: an extra service = success; an unfinished record is discarded with it.
    androidx.compose.runtime.DisposableEffect(viewModel) {
        onDispose {
            ai.oriveo.community.core.search.WebSearchChatReturn.finish(viewModel.state.value.services.map { it.saved.id })
        }
    }
    WebSearchSettingsPages(
        onBack = onBack,
        viewModel = viewModel,
        initialPages = if (oneTap != null) listOf(WsPageKey.Connect(oneTap)) else listOf(WsPageKey.Main, WsPageKey.Add),
        onConnectDone = if (oneTap != null) onEnabled else null,
    )
}

/**
 * Opened from a search error card in chat: the service detail, or straight into the custom service editor
 * when [edit]. A service no longer on this device (or a null [serviceId]) lands on the Web Search main page.
 */
@Composable
fun WebSearchServiceScreen(
    serviceId: String?,
    edit: Boolean,
    onBack: () -> Unit,
    viewModel: WebSearchSettingsViewModel = koinViewModel(),
) {
    WebSearchSettingsPages(
        onBack = onBack,
        viewModel = viewModel,
        initialPages = if (serviceId != null) listOf(WsPageKey.Main, WsPageKey.Detail(serviceId)) else listOf(WsPageKey.Main),
        editServiceId = serviceId?.takeIf { edit },
    )
}

/**
 * [initialPages] = the page stack to start from (Settings starts at Main; the chat web search card opens Add or a prefilled
 * Connect page). [onConnectDone] non-null = a passed connect test finishes the whole route instead of returning to Main.
 */
@Composable
internal fun WebSearchSettingsPages(
    onBack: () -> Unit,
    viewModel: WebSearchSettingsViewModel,
    initialPages: List<WsPageKey>,
    onConnectDone: (() -> Unit)? = null,
    /** Non-null = push the custom service editor for this id once the list is loaded. */
    editServiceId: String? = null,
) {
    LaunchedEffect(Unit) { viewModel.markBadgeSeen() }
    val stack = remember { mutableStateListOf<WsPageKey>().apply { addAll(initialPages.ifEmpty { listOf(WsPageKey.Main) }) } }
    if (editServiceId != null) {
        val loaded = viewModel.state.collectAsStateWithLifecycle().value.loaded
        var editOpened by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
        LaunchedEffect(loaded) {
            if (loaded && !editOpened) {
                editOpened = true
                // A custom service opens the editor; a preset goes straight to key editing (same as the detail page's "Update key")
                val custom = viewModel.customDraftOf(editServiceId)
                val rekey = if (custom == null) viewModel.rekeyDraftOf(editServiceId) else null
                when {
                    custom != null -> stack.add(WsPageKey.CustomForm(custom))
                    rekey != null -> stack.add(WsPageKey.Connect(rekey))
                }
            }
        }
    }
    val testing = viewModel.test.collectAsStateWithLifecycle().value == WebSearchTestState.Testing
    fun push(p: WsPageKey) {
        viewModel.resetFlow()
        stack.add(p)
    }
    fun pop() {
        if (stack.size <= 1) onBack() else {
            stack.removeAt(stack.lastIndex)
            viewModel.resetFlow()
        }
    }
    fun popTo(predicate: (WsPageKey) -> Boolean) {
        while (stack.size > 1 && !predicate(stack.last())) stack.removeAt(stack.lastIndex)
        viewModel.resetFlow()
    }
    BackHandler(enabled = stack.size > 1) { pop() }

    when (val page = stack.last()) {
        WsPageKey.Main -> MainPage(viewModel, onBack = ::pop, onAdd = { push(WsPageKey.Add) }, onOpen = { push(WsPageKey.Detail(it)) })
        WsPageKey.Add -> AddPage(
            viewModel,
            onBack = ::pop,
            onPreset = { push(WsPageKey.Connect(it)) },
            onCustom = { push(WsPageKey.CustomForm(CustomDraft())) },
            onOpen = { id -> popTo { it == WsPageKey.Main }; push(WsPageKey.Detail(id)) },
        )
        is WsPageKey.Connect -> ConnectPage(
            viewModel,
            page.draft,
            testing = testing,
            onBack = ::pop,
            onDone = onConnectDone ?: { popTo { it == WsPageKey.Main || it is WsPageKey.Detail } },
        )
        is WsPageKey.CustomForm -> CustomFormPage(
            viewModel,
            page.draft,
            testing = testing,
            onBack = ::pop,
            onContinue = { push(WsPageKey.CustomConsent(it)) },
            onSaved = ::pop,
        )
        is WsPageKey.CustomConsent -> CustomConsentPage(
            viewModel,
            page.draft,
            testing = testing,
            onBack = ::pop,
            onCheckSettings = ::pop,
            onDone = { popTo { it == WsPageKey.Main } },
        )
        is WsPageKey.Detail -> DetailPage(
            viewModel,
            page.id,
            onBack = ::pop,
            onRekey = { push(WsPageKey.Connect(it)) },
            onEdit = { push(WsPageKey.CustomForm(it)) },
            onResultCount = { push(WsPageKey.ResultCount(page.id)) },
        )
        is WsPageKey.ResultCount -> ResultCountPage(viewModel, page.id, onBack = ::pop)
    }
}

// ── Main ────────────────────────────────────────────────

@Composable
private fun MainPage(viewModel: WebSearchSettingsViewModel, onBack: () -> Unit, onAdd: () -> Unit, onOpen: (String) -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    WsPage(title = { WsTitle(stringResource(R.string.web_search_entry_title)) }, onBack = onBack, tag = "web_search_screen") {
        WsFooter(stringResource(R.string.web_search_main_intro), OriveoTheme.colors.textSecondary)
        WsSection(stringResource(R.string.web_search_main_section))
        WsCard {
            if (state.loaded && state.services.isEmpty()) {
                Text(
                    text = stringResource(R.string.web_search_main_empty),
                    style = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
                    color = OriveoTheme.colors.textSecondary,
                    modifier = Modifier.padding(16.dp),
                )
                WsDivider()
            }
            state.services.forEach { item ->
                WsRow(
                    title = item.displayName,
                    subtitle = rowSubtitle(item),
                    subtitleColor = if (item.rowState.status == "ready") OriveoTheme.colors.textTertiary else OriveoTheme.colors.warningText,
                    onClick = { onOpen(item.saved.id) },
                    modifier = Modifier.testTag("web_search_service_row"),
                    leading = { WsLogo(item.saved.serviceId, item.saved.kind == SavedSearchService.KIND_CUSTOM, 28.dp) },
                    titleTrailing = {
                        if (item.isDefault) WsTag(stringResource(R.string.web_search_badge_default), emphasized = true)
                        if (item.saved.kind == SavedSearchService.KIND_CUSTOM) WsTag(stringResource(R.string.web_search_badge_custom), emphasized = false)
                    },
                    trailing = { Chevron() },
                )
                WsDivider()
            }
            WsRow(
                title = stringResource(R.string.web_search_main_add),
                titleColor = OriveoTheme.colors.primaryTextSafe,
                onClick = onAdd,
                modifier = Modifier.testTag("web_search_add_row"),
                leading = { Icon(Icons.Filled.Add, contentDescription = null, tint = OriveoTheme.colors.primaryTextSafe, modifier = Modifier.size(22.dp)) },
            )
        }
        WsFooter(stringResource(R.string.web_search_main_footer))
    }
}

@Composable
internal fun rowSubtitle(item: WebSearchServiceItem): String {
    val r = item.rowState
    val custom = item.saved.kind == SavedSearchService.KIND_CUSTOM
    return when (r.status) {
        "ready" -> when {
            r.keySource == SavedSearchService.KEY_SOURCE_CONNECTION -> stringResource(R.string.web_search_row_via_connection, r.connectionName.orEmpty())
            custom && r.keySource == "none" -> stringResource(R.string.web_search_row_no_key)
            custom -> stringResource(R.string.web_search_row_connected)
            else -> listOf(
                stringResource(R.string.web_search_row_connected),
                priceText(SearchSettings.searchPriceSummary(item.entry, item.saved.regionId)),
            ).filter { it.isNotEmpty() }.joinToString(" · ")
        }
        "connection_missing" -> stringResource(R.string.web_search_row_connection_missing)
        "needs_key" -> stringResource(R.string.web_search_row_needs_key)
        "host_changed" -> stringResource(R.string.web_search_row_host_changed)
        "withdrawn" -> stringResource(R.string.web_search_row_withdrawn)
        else -> stringResource(R.string.web_search_row_catalog_unavailable)
    }
}

@Composable
private fun Chevron() {
    Icon(
        Icons.AutoMirrored.Filled.KeyboardArrowRight,
        contentDescription = null,
        tint = OriveoTheme.colors.textTertiary,
        modifier = Modifier.size(20.dp),
    )
}

// ── Add ─────────────────────────────────────────────────

@Composable
private fun AddPage(
    viewModel: WebSearchSettingsViewModel,
    onBack: () -> Unit,
    onPreset: (PresetDraft) -> Unit,
    onCustom: () -> Unit,
    onOpen: (String) -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val sheet = state.addSheet
    WsPage(title = { WsTitle(stringResource(R.string.web_search_add_title)) }, onBack = onBack, tag = "web_search_add_screen") {
        if (sheet.presets == "unavailable") {
            WsCard {
                Text(
                    text = stringResource(R.string.web_search_add_presets_unavailable),
                    style = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
                    color = OriveoTheme.colors.textSecondary,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
        sheet.sections.forEach { section ->
            WsSection(
                stringResource(
                    when (section.id) {
                        "reuse" -> R.string.web_search_add_section_reuse
                        "domestic" -> R.string.web_search_add_section_domestic
                        else -> R.string.web_search_add_section_overseas
                    },
                ),
            )
            WsCard {
                section.rows.forEachIndexed { i, row ->
                    val entry = state.entries[row.serviceId]
                    val price = priceText(SearchSettings.searchPriceSummary(entry, row.regionId), withOtherRegion = row.connectionRef == null)
                    val subtitle = when {
                        row.addedServiceRef != null -> stringResource(R.string.web_search_add_added)
                        row.connectionName != null -> listOf(stringResource(R.string.web_search_add_reuse_row, row.connectionName), price)
                            .filter { it.isNotEmpty() }.joinToString(" · ")
                        else -> price
                    }
                    if (i > 0) WsDivider()
                    WsRow(
                        title = SearchJson.string(entry?.get("displayName")) ?: row.serviceId,
                        subtitle = subtitle,
                        onClick = {
                            val added = row.addedServiceRef
                            if (added != null) onOpen(added) else onPreset(PresetDraft(row.serviceId, row.regionId, row.connectionRef, row.connectionName))
                        },
                        modifier = Modifier.testTag("web_search_add_preset_${row.serviceId}"),
                        leading = { WsLogo(row.serviceId, custom = false, size = 28.dp) },
                        trailing = { Chevron() },
                    )
                }
            }
        }
        WsSection(stringResource(R.string.web_search_add_section_custom))
        WsCard {
            WsRow(
                title = stringResource(R.string.web_search_add_custom_title),
                subtitle = stringResource(R.string.web_search_add_custom_subtitle),
                onClick = onCustom,
                modifier = Modifier.testTag("web_search_add_custom"),
                leading = { WsLogo(null, custom = true, size = 28.dp) },
                trailing = { Chevron() },
            )
        }
        WsFooter(stringResource(R.string.web_search_add_footer))
    }
}

// ── Connect (preset) ────────────────────────────────────

@Composable
private fun ConnectPage(
    viewModel: WebSearchSettingsViewModel,
    draft: PresetDraft,
    testing: Boolean,
    onBack: () -> Unit,
    onDone: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val test by viewModel.test.collectAsStateWithLifecycle()
    val errors by viewModel.formErrors.collectAsStateWithLifecycle()
    val entry = state.entries[draft.serviceId]
    val uri = LocalUriHandler.current
    val name = SearchJson.string(entry?.get("displayName")) ?: draft.serviceId
    val regions = SearchJson.array(entry?.get("regions"))?.mapNotNull { (it as? JsonObject)?.let { r -> SearchJson.string(r["id"]) } }.orEmpty()
    var useConnection by remember { mutableStateOf(draft.connectionRef != null) }
    var key by remember { mutableStateOf("") }
    // Paste mode defaults to the catalog's first site; reuse mode always uses the site the connection fixed (draft.regionId).
    var region by remember { mutableStateOf(regions.firstOrNull()) }
    val keyFocus = remember { FocusRequester() }
    val effectiveRegion = if (useConnection) draft.regionId else region
    val summary = SearchSettings.searchPriceSummary(entry, effectiveRegion)
    val links = entry?.let { SearchCatalog.regionLinks(it, effectiveRegion) }
    val query = stringResource(R.string.web_search_test_query_default)
    val done = (test as? WebSearchTestState.Done)?.takeIf { it.presentation is SearchTestPresentation.Passed }
    fun startTest() = viewModel.testAndSavePreset(draft, useConnection, key, region, query)

    WsPage(
        title = { WsTitle(name) },
        onBack = onBack,
        tag = "web_search_connect_screen",
        bottomBar = {
            ConsentButton(testing = testing, done = done != null, onAgree = ::startTest, onDone = onDone)
        },
    ) {
        Header(logo = { WsLogo(draft.serviceId, custom = false, size = 56.dp) }, title = name, subtitle = listOf(
            priceText(summary),
            if (summary.billing == "non_empty_only") stringResource(R.string.web_search_price_non_empty_only) else "",
        ).filter { it.isNotEmpty() }.joinToString(" · "))

        if (draft.connectionRef != null) {
            WsCard {
                Column(Modifier.selectableGroup()) {
                    ChoiceRow(
                        title = stringResource(R.string.web_search_connect_use_connection, draft.connectionName.orEmpty()),
                        subtitle = stringResource(R.string.web_search_connect_use_connection_hint),
                        selected = useConnection,
                        enabled = !testing,
                        onSelect = { useConnection = true },
                    )
                    WsDivider()
                    ChoiceRow(
                        title = stringResource(R.string.web_search_connect_paste_another),
                        selected = !useConnection,
                        enabled = !testing,
                        onSelect = { useConnection = false },
                    )
                }
            }
        }
        if (!useConnection) {
            if (regions.size > 1) {
                WsSection(stringResource(R.string.web_search_region_label))
                Segmented(
                    options = regions.map { it to regionLabel(it) },
                    selected = region,
                    enabled = !testing,
                    onSelect = { region = it },
                )
            }
            WsCard {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    FieldLabel(stringResource(R.string.web_search_connect_key_label))
                    McpTextField(
                        value = key,
                        onValueChange = {
                            key = it
                            viewModel.clearFieldError("key")
                        },
                        label = stringResource(R.string.web_search_connect_key_label),
                        placeholder = stringResource(R.string.web_search_connect_key_placeholder, name),
                        errorText = errors.fields["key"]?.let { stringResource(formErrorRes(it)) },
                        secure = true,
                        monospace = true,
                        modifier = Modifier.focusRequester(keyFocus).testTag("web_search_key_field"),
                    )
                    links?.keyHelp?.let { url ->
                        LinkText(stringResource(R.string.web_search_connect_get_key, name)) { runCatching { uri.openUri(url) } }
                    }
                }
            }
        }
        TestFailure(test) { action ->
            when (action) {
                "update_key" -> {
                    useConnection = false
                    runCatching { keyFocus.requestFocus() }
                }
                "top_up" -> links?.pricing?.let { runCatching { uri.openUri(it) } }
                else -> startTest()
            }
        }
        ConsentCard(SearchSettings.searchConsentLines(SavedSearchService.KIND_PRESET, "android", name, entry?.let { SearchCatalog.presetTarget(it, effectiveRegion)?.host }))
        done?.let { PassedNote(if (it.becameDefault) R.string.web_search_consent_passed_default else R.string.web_search_consent_passed) }
        links?.terms?.let { url ->
            Row(Modifier.padding(horizontal = OriveoTheme.spacing.lg + 4.dp)) {
                LinkText(stringResource(R.string.web_search_connect_view_terms, name)) { runCatching { uri.openUri(url) } }
            }
        }
    }
}

@Composable
private fun Header(logo: @Composable () -> Unit, title: String, subtitle: String, tag: (@Composable () -> Unit)? = null) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp, horizontal = OriveoTheme.spacing.lg),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        logo()
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold), color = OriveoTheme.colors.textPrimary)
            tag?.invoke()
        }
        if (subtitle.isNotEmpty()) {
            Text(subtitle, style = TextStyle(fontSize = 13.sp, lineHeight = 18.sp), color = OriveoTheme.colors.textSecondary)
        }
    }
}

@Composable
private fun ChoiceRow(
    title: String,
    selected: Boolean,
    enabled: Boolean,
    onSelect: () -> Unit,
    subtitle: String? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onSelect)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium), color = OriveoTheme.colors.textPrimary)
            subtitle?.let { Text(it, style = TextStyle(fontSize = 12.sp, lineHeight = 17.sp), color = OriveoTheme.colors.textTertiary) }
        }
        RadioButton(selected = selected, onClick = null, enabled = enabled)
    }
}

@Composable
private fun Segmented(options: List<Pair<String, String>>, selected: String?, enabled: Boolean, onSelect: (String) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = OriveoTheme.spacing.lg)) {
        options.forEachIndexed { i, (id, label) ->
            SegmentedButton(
                selected = id == selected,
                onClick = { onSelect(id) },
                enabled = enabled,
                shape = SegmentedButtonDefaults.itemShape(index = i, count = options.size),
                label = { Text(label) },
            )
        }
    }
}

@Composable
private fun FieldLabel(text: String) {
    Text(text, style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = OriveoTheme.colors.textSecondary)
}

@Composable
private fun LinkText(text: String, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.clickable(onClick = onClick).padding(vertical = 4.dp),
    ) {
        Text(text, style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium), color = OriveoTheme.colors.primaryTextSafe)
        Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, tint = OriveoTheme.colors.primaryTextSafe, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun ConsentCard(lines: List<ai.oriveo.community.core.search.SearchConsentLine>) {
    WsCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                stringResource(R.string.web_search_consent_title),
                style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                color = OriveoTheme.colors.textPrimary,
            )
            lines.forEach { line ->
                val warn = line.key == "customUnverified"
                val icon: ImageVector = when (line.key) {
                    "customUnverified" -> Icons.Outlined.WarningAmber
                    "billing", "billingCustom" -> Icons.Outlined.AttachMoney
                    "testOnce", "testOnceSave" -> Icons.Filled.Check
                    else -> Icons.AutoMirrored.Filled.ArrowForward
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = if (warn) OriveoTheme.colors.warning else OriveoTheme.colors.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(
                        consentText(line.key, line.args),
                        style = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
                        color = if (warn) OriveoTheme.colors.warningText else OriveoTheme.colors.textPrimary,
                    )
                }
            }
        }
    }
}

@Composable
private fun consentText(key: String, args: Map<String, String?>): String = when (key) {
    "sendsQuery" -> stringResource(R.string.web_search_consent_sends_query, args["name"].orEmpty())
    "sendsQueryCustom" -> stringResource(R.string.web_search_consent_sends_query_custom)
    "billing" -> stringResource(R.string.web_search_consent_billing, args["name"].orEmpty())
    "billingCustom" -> stringResource(R.string.web_search_consent_billing_custom)
    "customUnverified" -> stringResource(R.string.web_search_consent_custom_unverified, args["host"].orEmpty())
    "webForwarded" -> stringResource(R.string.web_search_consent_web_forwarded)
    "testOnceSave" -> stringResource(R.string.web_search_consent_test_once_save)
    else -> stringResource(R.string.web_search_consent_test_once)
}

/** Failed test: headline + the settings-page action (nothing is saved). */
@Composable
private fun TestFailure(test: WebSearchTestState, onAction: (String) -> Unit) {
    val failed = ((test as? WebSearchTestState.Done)?.presentation as? SearchTestPresentation.Failed) ?: return
    WsCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(headlineRes(failed.headline)),
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, lineHeight = 20.sp),
                color = OriveoTheme.colors.error,
                modifier = Modifier.testTag("web_search_test_error"),
            )
            actionRes(failed.action)?.let { res ->
                TextButton(onClick = { onAction(failed.action) }) { Text(stringResource(res), color = OriveoTheme.colors.primaryTextSafe) }
            }
        }
    }
}

@Composable
private fun PassedNote(res: Int) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg + 4.dp),
    ) {
        Icon(Icons.Filled.Check, contentDescription = null, tint = OriveoTheme.colors.success, modifier = Modifier.size(18.dp))
        Text(stringResource(res), style = TextStyle(fontSize = 14.sp), color = OriveoTheme.colors.success, modifier = Modifier.testTag("web_search_test_passed"))
    }
}

@Composable
private fun ConsentButton(testing: Boolean, done: Boolean, onAgree: () -> Unit, onDone: () -> Unit) {
    OriveoPrimaryButton(
        text = stringResource(
            when {
                done -> R.string.web_search_consent_done
                testing -> R.string.web_search_consent_testing
                else -> R.string.web_search_consent_agree
            },
        ),
        onClick = if (done) onDone else onAgree,
        loading = testing,
        modifier = Modifier.testTag("web_search_consent_button"),
    )
}

// ── Custom form ─────────────────────────────────────────

@Composable
private fun CustomFormPage(
    viewModel: WebSearchSettingsViewModel,
    initial: CustomDraft,
    testing: Boolean,
    onBack: () -> Unit,
    onContinue: (CustomDraft) -> Unit,
    onSaved: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val errors by viewModel.formErrors.collectAsStateWithLifecycle()
    val test by viewModel.test.collectAsStateWithLifecycle()
    var d by remember { mutableStateOf(initial) }
    val editing = initial.editingId != null
    val query = stringResource(R.string.web_search_test_query_default)
    fun set(field: String, next: CustomDraft) {
        d = next
        viewModel.clearFieldError(field)
    }
    fun err(field: String): String? = errors.fields[field]
    LaunchedEffect(test) {
        if (editing && (test as? WebSearchTestState.Done)?.presentation is SearchTestPresentation.Passed) onSaved()
    }

    WsPage(
        title = { WsTitle(stringResource(R.string.web_search_custom_title)) },
        onBack = onBack,
        tag = "web_search_custom_screen",
        bottomBar = {
            OriveoPrimaryButton(
                text = stringResource(if (editing) R.string.web_search_detail_save else R.string.web_search_custom_continue),
                loading = testing,
                onClick = {
                    viewModel.validateCustom(d) { ok ->
                        if (!ok) return@validateCustom
                        when {
                            !editing -> onContinue(d)
                            viewModel.onlyNameChanged(d) -> {
                                viewModel.saveCustomName(d)
                                onSaved()
                            }
                            else -> viewModel.testAndSaveCustom(d, query)
                        }
                    }
                },
                modifier = Modifier.testTag("web_search_custom_continue"),
            )
        },
    ) {
        WsCard {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                FieldLabel(stringResource(R.string.web_search_custom_name))
                McpTextField(
                    value = d.name,
                    onValueChange = { set("name", d.copy(name = it)) },
                    label = stringResource(R.string.web_search_custom_name),
                    placeholder = stringResource(R.string.web_search_custom_name_placeholder),
                    errorText = err("name")?.let { stringResource(formErrorRes(it)) },
                    modifier = Modifier.testTag("web_search_custom_name"),
                )
                FieldLabel(stringResource(R.string.web_search_custom_address))
                McpTextField(
                    value = d.address,
                    onValueChange = { set("address", d.copy(address = it)) },
                    label = stringResource(R.string.web_search_custom_address),
                    placeholder = "https://",
                    errorText = err("address")?.let { stringResource(formErrorRes(it)) },
                    monospace = true,
                    keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri,
                    modifier = Modifier.testTag("web_search_custom_address"),
                )
                errors.warnings["address"]?.let {
                    Text(stringResource(formErrorRes(it)), style = TextStyle(fontSize = 13.sp, lineHeight = 18.sp), color = OriveoTheme.colors.warningText)
                }
                FieldLabel(stringResource(R.string.web_search_custom_key))
                McpTextField(
                    value = d.key,
                    onValueChange = { set("key", d.copy(key = it)) },
                    label = stringResource(R.string.web_search_custom_key),
                    placeholder = stringResource(R.string.web_search_custom_key_optional),
                    errorText = err("key")?.let { stringResource(formErrorRes(it)) },
                    secure = true,
                    monospace = true,
                    modifier = Modifier.testTag("web_search_custom_key"),
                )
            }
        }
        WsFooter(stringResource(R.string.web_search_custom_address_hint_mobile))
        if (editing && initial.address.isNotBlank() && SearchCustomService.addressChangeClearsKey(initial.address, d.address.trim())) {
            WsFooter(stringResource(R.string.web_search_detail_address_change_notice), OriveoTheme.colors.warningText)
        }

        WsSection(stringResource(R.string.web_search_custom_protocol))
        WsCard {
            Column(Modifier.selectableGroup()) {
                ChoiceRow(
                    title = stringResource(R.string.web_search_custom_protocol_searxng),
                    subtitle = stringResource(R.string.web_search_custom_protocol_searxng_hint),
                    selected = d.protocol == "searxng",
                    enabled = !testing,
                    onSelect = { set("protocol", d.copy(protocol = "searxng")) },
                )
                WsDivider()
                ChoiceRow(
                    title = stringResource(R.string.web_search_custom_protocol_same_as),
                    subtitle = stringResource(
                        if (state.catalogAvailable) R.string.web_search_custom_protocol_same_as_hint else R.string.web_search_form_preset_unavailable,
                    ),
                    selected = d.protocol == "same_as",
                    enabled = !testing && state.catalogAvailable,
                    onSelect = { set("protocol", d.copy(protocol = "same_as", sameAsId = d.sameAsId ?: state.entries.keys.firstOrNull())) },
                )
                WsDivider()
                ChoiceRow(
                    title = stringResource(R.string.web_search_custom_protocol_manual),
                    subtitle = stringResource(R.string.web_search_custom_protocol_manual_hint),
                    selected = d.protocol == "manual",
                    enabled = !testing,
                    onSelect = { set("protocol", d.copy(protocol = "manual")) },
                )
            }
        }
        err("protocol")?.let { WsFooter(stringResource(formErrorRes(it)), OriveoTheme.colors.error) }

        if (d.protocol == "same_as" && state.catalogAvailable) {
            WsSection(stringResource(R.string.web_search_custom_protocol_same_as_pick))
            WsCard {
                Column(Modifier.selectableGroup()) {
                    state.entries.entries.forEachIndexed { i, (id, entry) ->
                        if (i > 0) WsDivider()
                        ChoiceRow(
                            title = SearchJson.string(entry["displayName"]) ?: id,
                            selected = d.sameAsId == id,
                            enabled = !testing,
                            onSelect = { set("protocol", d.copy(sameAsId = id)) },
                        )
                    }
                }
            }
        }
        if (d.protocol == "manual") ManualSection(d, testing, ::err) { field, next -> set(field, next) }

        TestFailure(test) { viewModel.testAndSaveCustom(d, query) }
        WsFooter(stringResource(R.string.web_search_custom_footer))
    }
}

@Composable
private fun ManualSection(d: CustomDraft, testing: Boolean, err: (String) -> String?, set: (String, CustomDraft) -> Unit) {
    @Composable
    fun field(field: String, label: Int, value: String, optional: Boolean = false, onChange: (String) -> CustomDraft) {
        McpTextField(
            value = value,
            onValueChange = { set(field, onChange(it)) },
            label = stringResource(label),
            placeholder = if (optional) stringResource(R.string.web_search_manual_optional) else "",
            errorText = err(field)?.let { stringResource(formErrorRes(it)) },
            monospace = true,
        )
    }
    WsSection(stringResource(R.string.web_search_manual_section))
    WsCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.web_search_manual_method), style = TextStyle(fontSize = 13.sp), color = OriveoTheme.colors.textSecondary)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("GET", "POST").forEachIndexed { i, m ->
                    SegmentedButton(
                        selected = d.method == m,
                        onClick = { set("method", d.copy(method = m)) },
                        enabled = !testing,
                        shape = SegmentedButtonDefaults.itemShape(i, 2),
                        label = { Text(m) },
                    )
                }
            }
            err("method")?.let { Text(stringResource(formErrorRes(it)), fontSize = 13.sp, color = OriveoTheme.colors.error) }
            Text(stringResource(R.string.web_search_manual_auth), style = TextStyle(fontSize = 13.sp), color = OriveoTheme.colors.textSecondary)
            val auths = listOf(
                "bearer" to R.string.web_search_manual_auth_bearer,
                "header" to R.string.web_search_manual_auth_header,
                "none" to R.string.web_search_manual_auth_none,
            )
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                auths.forEachIndexed { i, (k, res) ->
                    SegmentedButton(
                        selected = d.auth == k,
                        onClick = { set("auth", d.copy(auth = k)) },
                        enabled = !testing,
                        shape = SegmentedButtonDefaults.itemShape(i, auths.size),
                        label = { Text(stringResource(res)) },
                    )
                }
            }
            if (d.auth == "header") {
                field("auth", R.string.web_search_manual_header_name, d.headerName) { d.copy(headerName = it) }
            } else {
                err("auth")?.let { Text(stringResource(formErrorRes(it)), fontSize = 13.sp, color = OriveoTheme.colors.error) }
            }
            field("query", R.string.web_search_manual_query_field, d.queryField) { d.copy(queryField = it) }
            field("count", R.string.web_search_manual_count_field, d.countField, optional = true) { d.copy(countField = it) }
            Text(stringResource(R.string.web_search_manual_params), style = TextStyle(fontSize = 13.sp), color = OriveoTheme.colors.textSecondary)
            d.params.forEachIndexed { i, (k, v) ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    McpTextField(
                        value = k,
                        onValueChange = { nk -> set("params", d.copy(params = d.params.toMutableList().also { it[i] = nk to v })) },
                        label = stringResource(R.string.web_search_manual_param_name),
                        placeholder = stringResource(R.string.web_search_manual_param_name),
                        monospace = true,
                        modifier = Modifier.weight(1f),
                    )
                    McpTextField(
                        value = v,
                        onValueChange = { nv -> set("params", d.copy(params = d.params.toMutableList().also { it[i] = k to nv })) },
                        label = stringResource(R.string.web_search_manual_param_value),
                        placeholder = stringResource(R.string.web_search_manual_param_value),
                        monospace = true,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            err("params")?.let { Text(stringResource(formErrorRes(it)), fontSize = 13.sp, color = OriveoTheme.colors.error) }
            if (d.params.size < 10) {
                TextButton(onClick = { set("params", d.copy(params = d.params + ("" to ""))) }, enabled = !testing) {
                    Text(stringResource(R.string.web_search_manual_add_param), color = OriveoTheme.colors.primaryTextSafe)
                }
            }
            field("results", R.string.web_search_manual_results_path, d.resultsPath) { d.copy(resultsPath = it) }
            field("title", R.string.web_search_manual_title_path, d.titlePath) { d.copy(titlePath = it) }
            field("url", R.string.web_search_manual_url_path, d.urlPath) { d.copy(urlPath = it) }
            field("snippet", R.string.web_search_manual_snippet_path, d.snippetPath) { d.copy(snippetPath = it) }
            field("site", R.string.web_search_manual_site_path, d.sitePath, optional = true) { d.copy(sitePath = it) }
            field("date", R.string.web_search_manual_date_path, d.datePath, optional = true) { d.copy(datePath = it) }
            err("mapping")?.let { Text(stringResource(formErrorRes(it)), fontSize = 13.sp, color = OriveoTheme.colors.error) }
        }
    }
    WsFooter(stringResource(R.string.web_search_manual_path_hint))
}

// ── Custom consent ──────────────────────────────────────

@Composable
private fun CustomConsentPage(
    viewModel: WebSearchSettingsViewModel,
    draft: CustomDraft,
    testing: Boolean,
    onBack: () -> Unit,
    onCheckSettings: () -> Unit,
    onDone: () -> Unit,
) {
    val test by viewModel.test.collectAsStateWithLifecycle()
    val uri = LocalUriHandler.current
    val query = stringResource(R.string.web_search_test_query_default)
    val addr = SearchCustomService.parseServiceAddress(draft.address.trim())
    val hostPort = addr?.let { a -> a.host + (a.port?.let { ":$it" } ?: "") }.orEmpty()
    val done = (test as? WebSearchTestState.Done)?.takeIf { it.presentation is SearchTestPresentation.Passed }
    fun startTest() = viewModel.testAndSaveCustom(draft, query)
    WsPage(
        title = { WsTitle(draft.name.trim()) },
        onBack = onBack,
        tag = "web_search_custom_consent_screen",
        bottomBar = { ConsentButton(testing = testing, done = done != null, onAgree = ::startTest, onDone = onDone) },
    ) {
        Header(
            logo = { WsLogo(null, custom = true, size = 56.dp) },
            title = draft.name.trim(),
            subtitle = "${stringResource(protocolNameRes(draft.protocol))} · $hostPort",
            tag = { WsTag(stringResource(R.string.web_search_badge_custom), emphasized = false) },
        )
        TestFailure(test) { action ->
            when (action) {
                "check_settings", "update_key" -> onCheckSettings()
                "view_setup_guide" -> runCatching { uri.openUri(SearchSettings.SEARXNG_SETUP_GUIDE_URL) }
                else -> startTest()
            }
        }
        ConsentCard(SearchSettings.searchConsentLines(SavedSearchService.KIND_CUSTOM, "android", null, hostPort))
        done?.let { PassedNote(if (it.becameDefault) R.string.web_search_consent_passed_default else R.string.web_search_consent_passed) }
    }
}

// ── Detail ──────────────────────────────────────────────

@Composable
private fun DetailPage(
    viewModel: WebSearchSettingsViewModel,
    id: String,
    onBack: () -> Unit,
    onRekey: (PresetDraft) -> Unit,
    onEdit: (CustomDraft) -> Unit,
    onResultCount: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val tests by viewModel.detailTests.collectAsStateWithLifecycle()
    val item = state.services.firstOrNull { it.saved.id == id }
    if (item == null) {
        // Deleted (or not loaded yet): go back once the list is known.
        LaunchedEffect(state.loaded) { if (state.loaded) onBack() }
        return
    }
    val s = item.saved
    val custom = s.kind == SavedSearchService.KIND_CUSTOM
    val uri = LocalUriHandler.current
    val links = item.entry?.let { SearchCatalog.regionLinks(it, s.regionId) }
    val defaultQuery = stringResource(R.string.web_search_test_query_default)
    var query by remember(id) { mutableStateOf(defaultQuery) }
    var confirmDelete by remember { mutableStateOf(false) }
    fun rekeyDraft() = PresetDraft(
        serviceId = s.serviceId.orEmpty(),
        regionId = s.regionId,
        connectionRef = state.addSheet.sections.flatMap { it.rows }.firstOrNull { it.serviceId == s.serviceId }?.connectionRef,
        connectionName = state.addSheet.sections.flatMap { it.rows }.firstOrNull { it.serviceId == s.serviceId }?.connectionName,
        editingId = id,
    )
    fun editDraft() = viewModel.customDraftOf(id)?.let(onEdit)

    WsPage(
        title = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                WsLogo(s.serviceId, custom, 24.dp)
                WsTitle(item.displayName)
            }
        },
        onBack = onBack,
        tag = "web_search_detail_screen",
    ) {
        StatusNotice(item, onReconfirm = { viewModel.reconfirmHost(id) }, onPasteKey = { onRekey(rekeyDraft().copy(connectionRef = null, connectionName = null)) })
        WsCard {
            val keyValue = when {
                s.keySource == SavedSearchService.KEY_SOURCE_CONNECTION ->
                    stringResource(R.string.web_search_detail_key_via_connection, item.rowState.connectionName.orEmpty())
                item.hasKey -> "${stringResource(R.string.web_search_detail_key_saved)} ••••${item.keyTail.orEmpty()}"
                else -> stringResource(R.string.web_search_detail_key_none)
            }
            WsRow(
                title = stringResource(R.string.web_search_detail_key),
                subtitle = keyValue,
                onClick = { if (custom) editDraft() else if (item.entry != null) onRekey(rekeyDraft()) },
                trailing = { Chevron() },
            )
            WsDivider()
            WsRow(
                title = stringResource(R.string.web_search_detail_set_default),
                trailing = {
                    Switch(
                        checked = item.isDefault,
                        enabled = !item.isDefault,
                        onCheckedChange = { if (it) viewModel.setDefault(id) },
                        // Already default = on and disabled. Material's disabled-checked colors are a grey track that reads as
                        // "off"; keep the on look (dimmed) so the state stays legible, like iOS / Web.
                        colors = SwitchDefaults.colors(
                            disabledCheckedTrackColor = OriveoTheme.colors.primary.copy(alpha = 0.55f),
                            disabledCheckedThumbColor = OriveoTheme.colors.switchThumb,
                            disabledCheckedBorderColor = Color.Transparent,
                        ),
                        modifier = Modifier.testTag("web_search_default_switch"),
                    )
                },
            )
        }
        if (custom) {
            WsCard {
                WsRow(title = stringResource(R.string.web_search_custom_name), subtitle = s.name, onClick = { editDraft() }, trailing = { Chevron() })
                WsDivider()
                WsRow(title = stringResource(R.string.web_search_custom_address), subtitle = s.address, onClick = { editDraft() }, trailing = { Chevron() })
                WsDivider()
                WsRow(
                    title = stringResource(R.string.web_search_custom_protocol),
                    subtitle = stringResource(protocolNameRes(s.protocol)),
                    onClick = { editDraft() },
                    trailing = { Chevron() },
                )
            }
        }

        WsSection(stringResource(R.string.web_search_test_section))
        WsCard {
            val t = tests[id] ?: WebSearchTestState.Idle
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    McpTextField(
                        value = query,
                        onValueChange = { query = it },
                        label = stringResource(R.string.web_search_test_section),
                        modifier = Modifier.weight(1f).testTag("web_search_test_query"),
                    )
                    TextButton(
                        onClick = { viewModel.testSaved(id, query.trim()) },
                        enabled = query.isNotBlank() && t != WebSearchTestState.Testing,
                        modifier = Modifier.testTag("web_search_test_button"),
                    ) {
                        if (t == WebSearchTestState.Testing) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.web_search_test_run), color = OriveoTheme.colors.primaryTextSafe)
                        }
                    }
                }
                when (val p = (t as? WebSearchTestState.Done)?.presentation) {
                    is SearchTestPresentation.Passed -> Text(passedText(p), fontSize = 13.sp, color = OriveoTheme.colors.success)
                    is SearchTestPresentation.Failed -> {
                        Text(
                            stringResource(R.string.web_search_test_failed, stringResource(headlineRes(p.headline))),
                            fontSize = 13.sp,
                            color = OriveoTheme.colors.error,
                        )
                        actionRes(p.action)?.let { res ->
                            TextButton(onClick = {
                                when (p.action) {
                                    "update_key", "check_settings" -> if (custom) editDraft() else onRekey(rekeyDraft())
                                    "top_up" -> links?.pricing?.let { runCatching { uri.openUri(it) } }
                                    "view_setup_guide" -> runCatching { uri.openUri(SearchSettings.SEARXNG_SETUP_GUIDE_URL) }
                                    "reconfirm" -> viewModel.reconfirmHost(id)
                                    else -> viewModel.testSaved(id, query.trim())
                                }
                            }) { Text(stringResource(res), color = OriveoTheme.colors.primaryTextSafe) }
                        }
                    }
                    null -> Unit
                }
            }
        }

        if (!custom && item.entry != null) {
            val summary = SearchSettings.searchPriceSummary(item.entry, s.regionId)
            WsSection(stringResource(R.string.web_search_detail_price))
            WsCard {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(priceText(summary), style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = OriveoTheme.colors.textPrimary)
                    if (summary.billing == "non_empty_only") {
                        Text(stringResource(R.string.web_search_price_non_empty_only), fontSize = 12.sp, color = OriveoTheme.colors.textTertiary)
                    }
                    Text(stringResource(R.string.web_search_price_billed_by, item.displayName), fontSize = 12.sp, color = OriveoTheme.colors.textTertiary)
                    links?.pricing?.let { url ->
                        LinkText(stringResource(R.string.web_search_detail_official_link, item.displayName)) { runCatching { uri.openUri(url) } }
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        WsCard {
            WsRow(
                title = stringResource(R.string.web_search_detail_advanced),
                onClick = onResultCount,
                modifier = Modifier.testTag("web_search_advanced_row"),
                trailing = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            stringResource(R.string.web_search_detail_result_count_value, SearchSettings.searchResultCount(s.resultCount).toString()),
                            fontSize = 14.sp,
                            color = OriveoTheme.colors.textTertiary,
                        )
                        Chevron()
                    }
                },
            )
        }

        Spacer(Modifier.height(12.dp))
        WsCard {
            Text(
                text = stringResource(R.string.web_search_detail_delete),
                style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center),
                color = OriveoTheme.colors.danger,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { confirmDelete = true }
                    .padding(horizontal = 16.dp, vertical = 15.dp)
                    .testTag("web_search_delete_row"),
            )
        }
    }

    if (confirmDelete) {
        val nextDefault = viewModel.defaultAfterDelete(id)
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.web_search_detail_delete_title, item.displayName)) },
            text = {
                Text(
                    listOfNotNull(
                        stringResource(R.string.web_search_detail_delete_body),
                        nextDefault?.let { stringResource(R.string.web_search_detail_delete_new_default, it) },
                    ).joinToString(" "),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDelete = false
                        viewModel.delete(id)
                        onBack()
                    },
                    modifier = Modifier.testTag("web_search_delete_confirm"),
                ) { Text(stringResource(R.string.web_search_detail_delete_confirm), color = OriveoTheme.colors.danger) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text(stringResource(android.R.string.cancel)) }
            },
        )
    }
}

@Composable
private fun StatusNotice(item: WebSearchServiceItem, onReconfirm: () -> Unit, onPasteKey: () -> Unit) {
    val r = item.rowState
    if (r.status == "ready") return
    val host = item.entry?.let { SearchCatalog.presetTarget(it, item.saved.regionId)?.host }.orEmpty()
    val (text, action) = when (r.status) {
        "host_changed" -> stringResource(R.string.web_search_detail_host_changed_notice, item.displayName, host) to
            (R.string.web_search_action_reconfirm to onReconfirm)
        "withdrawn" -> stringResource(R.string.web_search_detail_withdrawn_notice) to null
        "connection_missing" -> stringResource(R.string.web_search_detail_connection_missing_notice) to
            (R.string.web_search_connect_paste_another to onPasteKey)
        "needs_key" -> stringResource(R.string.web_search_row_needs_key) to (R.string.web_search_connect_paste_another to onPasteKey)
        else -> stringResource(R.string.web_search_row_catalog_unavailable) to null
    }
    WsCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Outlined.WarningAmber, contentDescription = null, tint = OriveoTheme.colors.warning, modifier = Modifier.size(18.dp))
                Text(text, style = TextStyle(fontSize = 14.sp, lineHeight = 20.sp), color = OriveoTheme.colors.textPrimary)
            }
            action?.let { (res, onClick) ->
                TextButton(onClick = onClick) { Text(stringResource(res), color = OriveoTheme.colors.primaryTextSafe) }
            }
        }
    }
}

// ── Result count ──────────────────────────────────────────

@Composable
private fun ResultCountPage(viewModel: WebSearchSettingsViewModel, id: String, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val current = state.services.firstOrNull { it.saved.id == id }?.saved?.resultCount.let(SearchSettings::searchResultCount)
    WsPage(title = { WsTitle(stringResource(R.string.web_search_detail_result_count)) }, onBack = onBack, tag = "web_search_result_count_screen") {
        WsCard {
            Column(Modifier.selectableGroup()) {
                SearchSettings.RESULT_COUNT_CHOICES.forEachIndexed { i, n ->
                    if (i > 0) WsDivider()
                    ChoiceRow(
                        title = n.toString(),
                        selected = n == current,
                        enabled = true,
                        onSelect = { viewModel.setResultCount(id, n) },
                    )
                }
            }
        }
        WsFooter(stringResource(R.string.web_search_detail_result_count_footer))
    }
}
