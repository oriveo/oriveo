package ai.oriveo.community.feature.providers.relay

import androidx.compose.ui.platform.testTag

import androidx.compose.foundation.ExperimentalFoundationApi
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.ui.component.OriveoErrorCard
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.isCleartext
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.RelayFormDraft
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.feature.providers.detail.ProviderDetailSectionLabel
import ai.oriveo.community.feature.providers.detail.ProviderDetailViewModel
import ai.oriveo.community.feature.providers.detail.RelayDetailIconTone
import ai.oriveo.community.feature.providers.detail.RelayEditPlan
import ai.oriveo.community.ui.theme.DetailRowPalette
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

/**
 * Edit connection (the EditConnection board): the bottom sheet container is unchanged,
 * the header is a close button at the top left + a centered "Edit connection" title + the connection name as subtitle; the content is rendered
 * strictly from the output of [RelayEditBoardModel.make]; the bottom action bar has "Test connection" + the primary button.
 * There is no hero, no type picker, no preset card, no model-family suggestion banner and no connection-level reasoning row.
 *
 * Renaming, changing the key, the default model and deletion live only on the detail page.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun RelayAdvancedSettingsSheet(
    provider: Provider,
    viewModel: ProviderDetailViewModel,
    onDismiss: () -> Unit,
) {
    val spacing = OriveoTheme.spacing
    // A relay has no default model: the model in the draft is the verification sample (fallback model, then the first catalog model) and stays in memory only.
    val sampleModelID = viewModel.relaySampleModelID(provider)
    val initialDraft = remember(provider.id) { RelayEditDraft.from(provider, sampleModelID) }
    // The connection at the moment the draft starts is the merge baseline at save time; it is taken from the same composition as initialDraft.
    val baseline = remember(provider.id) { provider }
    DisposableEffect(baseline) {
        viewModel.beginRelayEdit(baseline)
        onDispose { viewModel.endRelayEdit() }
    }
    var draft by remember(provider.id) { mutableStateOf(initialDraft) }
    var endpointSelectionRange by remember(provider.id) { mutableStateOf<IntRange?>(null) }
    var headersExpanded by remember(provider.id) { mutableStateOf(false) }
    var compatibilityExpanded by remember(provider.id) { mutableStateOf(false) }
    var showDiscardDialog by remember(provider.id) { mutableStateOf(false) }
    // Compatibility rows the draft has opened during this edit: they stay after being turned off / cleared, until the page is left.
    val stickyCompatRows = remember(provider.id) { mutableSetOf<RelayEditRowId>() }
    stickyCompatRows += RelayEditBoardModel.draftTouchedCompatRows(draft)

    fun update(next: RelayEditDraft) {
        draft = next
        viewModel.invalidateRelayDraftEvidence()
    }

    val hasStoredKey = viewModel.hasStoredKey(provider)
    val formDraft = RelayFormDraft(
        requested = draft.requested.copy(
            headers = draft.headers.cleanRelayAdvancedPairs(),
            queryParams = draft.queryParams.cleanRelayAdvancedPairs(),
        ),
        endpoint = draft.endpoint,
        hasSavedCredential = hasStoredKey,
    )
    val formIssues = RelayFormValidation.validate(formDraft, RelayFormValidation.FormMode.Edit)
    val normalizedDraftEndpoint = RelayFormValidation.normalizedEndpoint(formDraft, RelayFormValidation.FormMode.Edit)
    val status = RelayEditStatus.of(
        isReconnecting = viewModel.isReconnectingRelaySecurity,
        isTesting = viewModel.isTestingRelayConnection,
        result = viewModel.relayConnectionTestResult,
        canSaveUnverified = viewModel.canSaveRelaySettingsUnverified,
    )
    val board = RelayEditBoardModel.make(
        provider = provider,
        draft = draft,
        status = status,
        isSaving = viewModel.isSavingRelaySettings,
        issues = formIssues,
        shownCompatRows = stickyCompatRows.toSet(),
        headersExpanded = headersExpanded,
        compatibilityExpanded = compatibilityExpanded,
        baseline = baseline,
    )

    val hasCredentialMaterial = RelayEndpointPolicy.hasCredentialMaterial(
        requested = initialDraft.requested.copy(
            headers = (initialDraft.headers + draft.headers).ifEmpty { null },
            queryParams = (initialDraft.queryParams + draft.queryParams).ifEmpty { null },
        ),
        hasKey = hasStoredKey,
    )
    // "Has unsaved changes" = saving now would change the stored connection (connection security is persisted immediately and does not count).
    val isDirty = run {
        val persisted = provider.relayRequested ?: return@run true
        RelayEditPlan.endpointChanged(provider, draft.endpoint) || !relayRequestedMatchesPersisted(
            persisted = persisted,
            candidate = RelayEditSavePolicy.savedRequested(provider, draft.cleanedRequested(), draft.endpoint),
        )
    }
    val attemptClose = { if (isDirty) showDiscardDialog = true else onDismiss() }

    // Only when a result appears or changes do we dismiss the keyboard and scroll to it; an in-flight one replaced by its result in place does not scroll.
    val statusRequester = remember { BringIntoViewRequester() }
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val lastStatus = remember(provider.id) { arrayOfNulls<RelayEditStatus>(1) }
    LaunchedEffect(status) {
        val reveal = RelayEditBoardModel.revealsStatus(lastStatus[0], status)
        lastStatus[0] = status
        if (reveal) {
            focusManager.clearFocus()
            keyboard?.hide()
            statusRequester.bringIntoView()
        }
    }

    if (showDiscardDialog) {
        AlertDialog(
            onDismissRequest = { showDiscardDialog = false },
            title = { Text(stringResource(R.string.relay_discard_changes_title)) },
            text = { Text(stringResource(R.string.relay_edit_unsaved_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDiscardDialog = false
                        onDismiss()
                    },
                ) { Text(stringResource(R.string.relay_discard_changes_confirm)) }
            },
            dismissButton = {
                TextButton(
                    onClick = { showDiscardDialog = false },
                ) { Text(stringResource(R.string.relay_discard_changes_keep)) }
            },
        )
    }

    val onSecurityModeSelected: (ai.oriveo.community.core.model.RelayConnectionSecurityMode, RelaySecurityModePolicy.Assessment, Boolean) -> Unit =
        { mode, assessment, confirmed ->
            val normalized = RelaySecurityModePolicy.normalizedEndpoint(
                rawEndpoint = draft.endpoint,
                mode = mode,
                assessment = assessment,
            )
            val effectiveEndpoint = normalized ?: draft.endpoint.trim()
            if (normalized != null) {
                endpointSelectionRange = RelaySecurityModePolicy.addedSchemeHighlightRange(draft.endpoint, normalized)
            }
            val cleartext = mode.isCleartext
            val clearsKv = cleartext && confirmed && hasCredentialMaterial
            draft = draft.copy(
                endpoint = normalized ?: draft.endpoint,
                requested = draft.requested.copy(
                    authMode = if (cleartext) RelayAuthMode.None else draft.requested.authMode,
                    securityMode = mode,
                    resolvedAPIBaseURL = null,
                ),
                headers = if (clearsKv) emptyList() else draft.headers,
                queryParams = if (clearsKv) emptyList() else draft.queryParams,
            )
            // Persist only securityMode/T2; the remaining draft fields are never handed to the VM here.
            viewModel.changeRelaySecurityMode(provider, mode, effectiveEndpoint)
        }

    Column(
        modifier = Modifier
            .fillMaxWidth(),
    ) {
        EditHeader(title = stringResource(board.titleRes), subtitle = board.subtitle, onClose = attemptClose)
        Column(
            modifier = Modifier
                .weight(1f, fill = false)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = spacing.lg),
            verticalArrangement = Arrangement.spacedBy(spacing.lg),
        ) {
            board.groups.forEach { group ->
                EditGroup(
                    group = group,
                    onToggle = {
                        val forced = group.id == RelayEditGroupId.Headers &&
                            group.rows.any { it.issues.isNotEmpty() }
                        when (group.id) {
                            RelayEditGroupId.Headers ->
                                headersExpanded = RelayEditBoardModel.toggledExpansion(headersExpanded, forced)
                            RelayEditGroupId.Compatibility ->
                                compatibilityExpanded = RelayEditBoardModel.toggledExpansion(compatibilityExpanded, false)
                            else -> Unit
                        }
                    },
                ) { row ->
                    when (row.id) {
                        RelayEditRowId.RequestUrl, RelayEditRowId.EngineAddress -> AddressRow(
                            row = row,
                            endpoint = draft.endpoint,
                            cleartext = draft.requested.securityMode.isCleartext,
                            enabled = !viewModel.isSavingRelaySettings,
                            selectionRange = endpointSelectionRange,
                            onChange = {
                                endpointSelectionRange = null
                                update(draft.copy(endpoint = it))
                            },
                        )
                        RelayEditRowId.ConnectionSecurity -> RelaySecurityModeControl(
                            endpoint = draft.endpoint,
                            selectedMode = draft.requested.securityMode,
                            hasCredentialMaterial = hasCredentialMaterial,
                            enabled = !viewModel.isSavingRelaySettings && status !is RelayEditStatus.Reconnecting &&
                                status !is RelayEditStatus.Testing,
                            onModeSelected = onSecurityModeSelected,
                            summary = { onChange ->
                                ValueRow(
                                    row = row,
                                    trailing = stringResource(R.string.relay_type_row_change),
                                    onClick = onChange,
                                )
                            },
                        )
                        RelayEditRowId.DefaultProtocol -> MenuRow(
                            row = row,
                            options = RelayTransport.entries,
                            label = { relayAdvancedTransportLabel(it) },
                            onSelect = { update(draft.copy(requested = draft.requested.copy(transport = it))) },
                        )
                        RelayEditRowId.Channel -> MenuRow(
                            row = row,
                            options = relayEditChannelSection(draft.requested.engineProfile)?.options.orEmpty(),
                            label = { relayAdvancedTransportLabel(it) },
                            // Carry the old connection's webSearchToolName over as is (the picker is gone; it is only used for read-only mapping).
                            onSelect = { update(draft.copy(requested = draft.requested.copy(transport = it))) },
                        )
                        RelayEditRowId.Authentication -> MenuRow(
                            row = row,
                            options = RelayAuthMode.entries,
                            label = { relayAdvancedAuthModeLabel(it) },
                            onSelect = { update(draft.copy(requested = draft.requested.copy(authMode = it))) },
                        )
                        RelayEditRowId.UserAgent -> KeyValueRow(
                            label = stringResource(row.titleRes),
                            name = null,
                            value = draft.requested.customUserAgent.orEmpty(),
                            valuePlaceholder = stringResource(R.string.relay_advanced_user_agent_placeholder),
                            masked = false,
                            onName = {},
                            onValue = { update(draft.copy(requested = draft.requested.copy(customUserAgent = it))) },
                            onRemove = null,
                        )
                        RelayEditRowId.Header -> {
                            val pair = draft.headers[row.index]
                            KeyValueRow(
                                label = stringResource(row.titleRes),
                                name = pair.key,
                                namePlaceholder = RelayFormValidation.definition(RelayFormValidation.Field.Headers)?.placeholder.orEmpty(),
                                value = pair.value,
                                valuePlaceholder = stringResource(R.string.relay_value_label),
                                masked = row.masked,
                                onName = { update(draft.copy(headers = draft.headers.replaced(row.index, pair.copy(key = it)))) },
                                onValue = { update(draft.copy(headers = draft.headers.replaced(row.index, pair.copy(value = it)))) },
                                onRemove = { update(draft.copy(headers = draft.headers.filterIndexed { i, _ -> i != row.index })) },
                            )
                            RowIssues(row.issues)
                        }
                        RelayEditRowId.QueryParam -> {
                            val pair = draft.queryParams[row.index]
                            KeyValueRow(
                                label = stringResource(row.titleRes),
                                name = pair.key,
                                namePlaceholder = RelayFormValidation.definition(RelayFormValidation.Field.QueryParams)?.placeholder.orEmpty(),
                                value = pair.value,
                                valuePlaceholder = stringResource(R.string.relay_value_label),
                                masked = false,
                                onName = { update(draft.copy(queryParams = draft.queryParams.replaced(row.index, pair.copy(key = it)))) },
                                onValue = { update(draft.copy(queryParams = draft.queryParams.replaced(row.index, pair.copy(value = it)))) },
                                onRemove = { update(draft.copy(queryParams = draft.queryParams.filterIndexed { i, _ -> i != row.index })) },
                            )
                            RowIssues(row.issues)
                        }
                        RelayEditRowId.AddEntry -> AddEntryRow(
                            onAddHeader = { update(draft.copy(headers = draft.headers + RelayKeyValue("", ""))) },
                            onAddQueryParam = { update(draft.copy(queryParams = draft.queryParams + RelayKeyValue("", ""))) },
                        )
                        RelayEditRowId.Stream -> RelayToggleRow(
                            title = stringResource(row.titleRes),
                            isOn = draft.requested.stream != false,
                            onToggle = { update(draft.copy(requested = draft.requested.copy(stream = it))) },
                        )
                        RelayEditRowId.ServiceTier -> InlineSlotRow(
                            title = stringResource(row.titleRes),
                            value = draft.requested.serviceTier.orEmpty(),
                            placeholder = stringResource(R.string.relay_advanced_service_tier_placeholder),
                            onChange = { update(draft.copy(requested = draft.requested.copy(serviceTier = it))) },
                        )
                        RelayEditRowId.DisableResponseStorage -> RelayToggleRow(
                            title = stringResource(row.titleRes),
                            isOn = draft.requested.disableResponseStorage == true,
                            footnote = row.footnote?.let { resolve(it) },
                            onToggle = {
                                update(draft.copy(requested = draft.requested.copy(disableResponseStorage = it.takeIf { on -> on })))
                            },
                        )
                    }
                }
                if (group.id == RelayEditGroupId.Connection) RelayFormIssueNotes(issues = board.connectionIssues)
            }

            Box(modifier = Modifier.bringIntoViewRequester(statusRequester)) {
                StatusBlock(
                    status = board.status,
                    onSaveUnverified = { viewModel.saveRelaySettingsUnverified(onSaved = onDismiss) },
                    onClose = viewModel::clearRelayFailure,
                    // A failed verification on the edit page is a recoverable state where "save unverified" is possible: warning tone.
                    severity = OriveoErrorSeverity.Warning,
                )
            }
            Spacer(modifier = Modifier.height(spacing.sm))
        }

        SetupActionBar(
            primaryText = stringResource(board.actionBar.primaryTitleRes),
            primaryEnabled = board.actionBar.primaryEnabled,
            primaryLoading = viewModel.isSavingRelaySettings,
            secondaryText = stringResource(R.string.relay_test_connection),
            secondaryEnabled = board.actionBar.testEnabled,
            secondaryIcon = null,
            secondaryInline = true,
            onPrimary = {
                viewModel.saveRelaySettings(
                    provider = provider,
                    relayRequested = draft.cleanedRequested(),
                    baseUrlText = normalizedDraftEndpoint,
                    onSaved = onDismiss,
                )
            },
            onSecondary = {
                val requested = draft.cleanedRequested()
                val normalized = runCatching {
                    RelayEndpointPolicy.requireConfigured(
                        baseUrl = draft.endpoint,
                        securityMode = requested.securityMode,
                        credentials = RelayEndpointPolicy.credentialsOf(requested = requested, hasKey = hasStoredKey),
                    )
                }.getOrNull()
                if (normalized != null) {
                    endpointSelectionRange = RelaySecurityModePolicy.addedSchemeHighlightRange(draft.endpoint, normalized)
                    // Completing the scheme does not count as editing the draft: write it directly without invalidating the test about to be sent.
                    draft = draft.copy(endpoint = normalized)
                }
                viewModel.testRelayConnection(
                    provider = provider,
                    relayRequested = requested,
                    endpoint = normalized ?: draft.endpoint,
                    modelID = draft.requested.modelID.orEmpty(),
                )
            },
        )
    }
}

private fun List<RelayKeyValue>.replaced(index: Int, value: RelayKeyValue): List<RelayKeyValue> =
    toMutableList().also { it[index] = value }

/** Manual setup on the add page reuses the rows and the failure card of edit connection; text resolution goes through the same function. */
@Composable
internal fun relayEditText(text: RelayEditText): String = resolve(text)

@Composable
private fun resolve(text: RelayEditText): String = stringResource(
    text.res,
    *text.args.map { arg -> if (arg is RelayEditText) resolve(arg) else arg }.toTypedArray(),
)

@Composable
private fun toneColor(tone: RelayDetailIconTone?): Color = when (tone) {
    RelayDetailIconTone.Teal -> DetailRowPalette.teal
    RelayDetailIconTone.Cyan -> DetailRowPalette.cyan
    RelayDetailIconTone.Indigo -> DetailRowPalette.indigo
    RelayDetailIconTone.Orange -> DetailRowPalette.orange
    else -> OriveoTheme.colors.textSecondary
}

/** Header: a 36dp rounded-square close button at the top left + a centered title + the connection name as subtitle; no system navigation bar. */
@Composable
private fun EditHeader(title: String, subtitle: String, onClose: () -> Unit) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(colors.surfaceElevated)
                .border(1.dp, colors.border.opacity(0.72f), RoundedCornerShape(10.dp))
                .clickable(onClick = onClose),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painter = painterResource(R.drawable.ph_x),
                contentDescription = stringResource(R.string.close),
                tint = colors.textPrimary,
                modifier = Modifier.size(18.dp),
            )
        }
        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 48.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = title,
                style = OriveoTheme.typography.title3.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = subtitle,
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/** A group: the same group title as the detail page (a collapsible group title shows the filled count and an arrow on its right) + a card. */
@Composable
internal fun EditGroup(
    group: RelayEditGroup,
    onToggle: () -> Unit,
    /** Text on the right of the group title; null = use the filled count (edit connection). */
    trailing: String? = null,
    row: @Composable (RelayEditRow) -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val title = stringResource(group.titleRes)
        if (group.collapsible) {
            val expandedLabel = stringResource(if (group.expanded) R.string.mcp_steps_expanded else R.string.mcp_steps_collapsed)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onToggle)
                    .semantics { stateDescription = expandedLabel },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ProviderDetailSectionLabel(
                    title = title,
                    trailing = trailing ?: group.filledCount?.let {
                        pluralStringResource(R.plurals.relay_edit_headers_set_count, it, it)
                    },
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.size(8.dp))
                // Collapsed points in the reading direction, expanded points down; the caret_right resource is not mirrored automatically, so flip it manually in RTL.
                val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
                Icon(
                    painter = painterResource(if (group.expanded) R.drawable.ph_caret_down else R.drawable.ph_caret_right),
                    contentDescription = null,
                    tint = colors.textSecondary,
                    modifier = Modifier
                        .size(12.dp)
                        .then(if (rtl && !group.expanded) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
                )
            }
        } else {
            ProviderDetailSectionLabel(title = title)
        }
        if (group.expanded && group.rows.isNotEmpty()) {
            val shape = RoundedCornerShape(16.dp)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(shape)
                    .background(colors.surfaceElevated),
            ) {
                group.rows.forEachIndexed { index, item ->
                    if (index > 0) EditDivider()
                    row(item)
                }
            }
        }
    }
}

@Composable
private fun EditDivider() {
    Box(
        modifier = Modifier
            .padding(start = ROW_H, end = ROW_H)
            .fillMaxWidth()
            .height(0.5.dp)
            .background(OriveoTheme.colors.border.opacity(0.72f)),
    )
}

@Composable
private fun RowIcon(row: RelayEditRow) {
    row.icon?.let {
        Icon(
            painter = painterResource(it),
            contentDescription = null,
            tint = toneColor(row.tone),
            modifier = Modifier.size(ROW_ICON),
        )
    }
}

/**
 * Indent input slots to the start of the title (iOS textInset): with an icon, skip past the icon and its spacing.
 * Only for blocks with an input below (the address row), and the call site must be marked `row-lead: top`; the icon of an ordinary multi-line row is centered on the whole block and does not indent the footnote with this (RL2-LAYOUT-ROW-10).
 */
private fun textInset(row: RelayEditRow) = if (row.icon != null) ROW_ICON + ROW_ICON_GAP else 0.dp

/** Icon + title (body primary) on one line. */
@Composable
private fun RowTitle(row: RelayEditRow, title: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(ROW_ICON_GAP), verticalAlignment = Alignment.CenterVertically) {
        RowIcon(row)
        Text(text = title, style = OriveoTheme.typography.body, color = OriveoTheme.colors.textPrimary)
    }
}

/**
 * iOS rowBody: left column [icon in its own column, centered on the whole block of "title + footnote (secondary)"] | value (body secondary, at most 2 lines, tail-truncated) + trailing control,
 * with the value and the control in one column, centered on the whole row; 14h / 10v, minimum height 56. Shared by menu rows and the connection security action row.
 * The value column (the value plus trailing actions such as "Change") takes at most 45% of the row content width excluding the trailing arrow; the arrow [chevron] sits outside the value column; the footnote is not truncated (RL2-LAYOUT-ROW-06).
 */
@Composable
private fun EditRowBody(
    row: RelayEditRow,
    title: String,
    value: String?,
    modifier: Modifier = Modifier,
    chevron: (@Composable () -> Unit)? = null,
    trailing: @Composable () -> Unit = {},
) {
    val colors = OriveoTheme.colors
    val footnote = row.footnote?.let { resolve(it) }
    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = ROW_MIN_HEIGHT)
            .padding(horizontal = ROW_H, vertical = ROW_V),
        contentAlignment = Alignment.CenterStart,
    ) {
        val contentWidth = if (chevron != null) maxWidth - ROW_CHEVRON - ROW_CHEVRON_GAP else maxWidth
        val valueMaxWidth = contentWidth * 0.45f
        // On multi-line rows the right column is vertically centered on the whole row, not pinned to the title line. (whole-row vertical centering)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The icon sits in its own column, vertically centered on the whole "title + footnote" block instead of pinned to the title line.
            Row(
                modifier = Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(ROW_ICON_GAP),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RowIcon(row)
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(text = title, style = OriveoTheme.typography.body, color = colors.textPrimary)
                    footnote?.let {
                        Text(text = it, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
                    }
                }
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(ROW_CHEVRON_GAP),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    modifier = Modifier.widthIn(max = valueMaxWidth),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (value != null) {
                        Text(
                            text = value,
                            style = OriveoTheme.typography.body,
                            color = colors.textSecondary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                    }
                    trailing()
                }
                chevron?.invoke()
            }
        }
    }
}

/** Request address / engine address: the input slot carries a scheme prefix chip, and for a relay the next line says "Will request ...". */
@Composable
private fun AddressRow(
    row: RelayEditRow,
    endpoint: String,
    cleartext: Boolean,
    enabled: Boolean,
    selectionRange: IntRange?,
    onChange: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    // The slot shows only what follows the scheme, which the chip displays; when writing back, a scheme the user already typed is kept.
    val slotText = relaySchemeSlotText(endpoint)
    val slotRange = relaySchemeSlotRange(endpoint, selectionRange)
    var fieldValue by remember { mutableStateOf(TextFieldValue(slotText, selection = TextRange(slotText.length))) }
    LaunchedEffect(slotText, slotRange) {
        if (fieldValue.text != slotText || slotRange != null) {
            fieldValue = TextFieldValue(
                text = slotText,
                selection = slotRange?.let { TextRange(it.first, it.last + 1) } ?: TextRange(slotText.length),
            )
        }
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ROW_H, vertical = ROW_V),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        RowTitle(row, stringResource(row.titleRes))
        // The input slot and the footnote are indented to the start of the title (iOS addressRow).
        // row-lead: top -- there is an input below, so the icon follows the title line instead of being centered on the whole block.
        Column(modifier = Modifier.padding(start = textInset(row)), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            BasicTextField(
                value = fieldValue,
                onValueChange = {
                    fieldValue = it
                    val next = relaySchemeSlotInput(endpoint, it.text)
                    if (next != endpoint) onChange(next)
                },
                singleLine = true,
                enabled = enabled,
                // The address uses the body font (same as the add page address slot), not monospace.
                textStyle = OriveoTheme.typography.body.copy(
                    color = if (enabled) colors.textPrimary else colors.textTertiary,
                ),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                cursorBrush = SolidColor(colors.primary),
                modifier = Modifier
                    .fillMaxWidth(),
                decorationBox = { inner ->
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(colors.surfaceInset)
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        SetupSchemeChip(setupSchemeChip(endpoint, cleartext))
                        Spacer(Modifier.size(8.dp))
                        Box(modifier = Modifier.weight(1f)) {
                            if (fieldValue.text.isEmpty()) {
                                Text(
                                    RELAY_EDIT_ENDPOINT_PLACEHOLDER,
                                    style = OriveoTheme.typography.body,
                                    color = colors.textTertiary,
                                    maxLines = 1,
                                )
                            }
                            inner()
                        }
                    }
                },
            )
            row.footnote?.let {
                Text(
                    text = resolve(it),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** Current value + trailing action text (the "Change" of connection security + an arrow), with the value and the action in one trailing column. */
@Composable
private fun ValueRow(row: RelayEditRow, trailing: String, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    EditRowBody(
        row = row,
        title = stringResource(row.titleRes),
        value = row.valueRes?.let { stringResource(it) },
        modifier = Modifier
            .clickable(onClick = onClick),
        chevron = {
            // The forward arrow resource is not mirrored automatically; flip it in RTL.
            Icon(
                painter = painterResource(R.drawable.ph_caret_right),
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier
                    .size(ROW_CHEVRON)
                    .then(if (rtl) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
            )
        },
    ) {
        Text(
            text = trailing,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.primaryTextSafe,
            maxLines = 1,
        )
    }
}

/** Menu row: tappable with an arrow when there is more than one candidate; no arrow when read-only. */
@Composable
internal fun <T> MenuRow(
    row: RelayEditRow,
    options: List<T>,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    Box {
        EditRowBody(
            row = row,
            title = stringResource(row.titleRes),
            value = row.valueRes?.let { stringResource(it) },
            modifier = if (row.hasMenu) {
                Modifier
                    .clickable { expanded = true }
            } else {
                Modifier
            },
            chevron = if (row.hasMenu) {
                {
                    Icon(
                        painter = painterResource(R.drawable.ph_caret_down),
                        contentDescription = null,
                        tint = colors.textTertiary,
                        modifier = Modifier.size(ROW_CHEVRON),
                    )
                }
            } else {
                null
            },
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            RelayMenuOptions(
                options = options,
                label = label,
                onSelect = { option ->
                    onSelect(option)
                    expanded = false
                },
            )
        }
    }
}

/**
 * Key-value row: kind + name slot + value slot (header values are masked by default and have an eye button) + a trailing trash button on one line;
 * the kind moves above only when it does not fit (iOS ViewThatFits). The UA row has only a value slot, with the title and the slot on one line.
 */
@Composable
internal fun KeyValueRow(
    label: String,
    name: String?,
    value: String,
    valuePlaceholder: String,
    masked: Boolean,
    onName: (String) -> Unit,
    onValue: (String) -> Unit,
    onRemove: (() -> Unit)?,
    namePlaceholder: String = "",
) {
    if (name == null) {
        InlineSlotRow(title = label, value = value, placeholder = valuePlaceholder, onChange = onValue)
        return
    }
    val colors = OriveoTheme.colors
    var revealed by remember { mutableStateOf(false) }
    val labelStyle = OriveoTheme.typography.footnote
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val labelWidth = with(density) { measurer.measure(label, labelStyle, maxLines = 1).size.width.toDp() }
    val slots: @Composable RowScope.() -> Unit = {
        EditSlot(value = name, placeholder = namePlaceholder, onChange = onName, modifier = Modifier.weight(1f))
        EditSlot(
            value = value,
            placeholder = valuePlaceholder,
            onChange = onValue,
            modifier = Modifier.weight(1f),
            visualTransformation = if (masked && !revealed) PasswordVisualTransformation() else VisualTransformation.None,
            trailing = if (masked) {
                {
                    IconButton(
                        onClick = { revealed = !revealed },
                        modifier = Modifier
                            .size(ROW_TAP),
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
                }
            } else {
                null
            },
        )
        if (onRemove != null) {
            IconButton(
                onClick = onRemove,
                modifier = Modifier
                    .size(ROW_TAP),
            ) {
                Icon(
                    painter = painterResource(R.drawable.ph_trash),
                    contentDescription = stringResource(R.string.remove),
                    tint = colors.textSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ROW_H, vertical = ROW_V),
    ) {
        // One line fits = kind + the minimum width of both slots + the trash button; only when it does not fit does the kind move above.
        val oneLine = labelWidth + KV_SLOT_MIN * 2 + ROW_TAP + 8.dp * 3 <= maxWidth
        if (oneLine) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(label, style = labelStyle, color = colors.textSecondary, maxLines = 1)
                slots()
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(label, style = labelStyle, color = colors.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically, content = slots)
            }
        }
    }
}

/** UA / service tier: the title (body, 1 line) and a monospace filled slot on one line. */
@Composable
private fun InlineSlotRow(title: String, value: String, placeholder: String, onChange: (String) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = ROW_MIN_HEIGHT)
            .padding(horizontal = ROW_H, vertical = ROW_V),
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.body,
            color = OriveoTheme.colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        EditSlot(value = value, placeholder = placeholder, onChange = onChange, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun EditSlot(
    value: String,
    placeholder: String,
    onChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailing: (@Composable () -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    BasicTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        textStyle = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace, color = colors.textPrimary),
        cursorBrush = SolidColor(colors.primary),
        visualTransformation = visualTransformation,
        modifier = modifier,
        decorationBox = { inner ->
            Row(
                modifier = Modifier
                    .heightIn(min = 36.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(colors.surfaceInset)
                    .padding(start = 10.dp, end = if (trailing != null) 0.dp else 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(modifier = Modifier.weight(1f)) {
                    if (value.isEmpty()) {
                        Text(placeholder, style = OriveoTheme.typography.footnote, color = colors.textTertiary, maxLines = 1)
                    }
                    inner()
                }
                trailing?.invoke()
            }
        },
    )
}

/** The last row "+ Add" (plus sign 14 + footnote semibold, minimum height 56): a menu with two items (header / query parameter). */
@Composable
internal fun AddEntryRow(
    onAddHeader: () -> Unit,
    onAddQueryParam: () -> Unit,
) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = ROW_MIN_HEIGHT)
                .clickable { expanded = true }
                .padding(horizontal = ROW_H),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(painterResource(R.drawable.ph_plus), contentDescription = null, tint = colors.primaryTextSafe, modifier = Modifier.size(14.dp))
            Text(
                text = stringResource(R.string.add),
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.primaryTextSafe,
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.relay_edit_headers)) },
                onClick = {
                    expanded = false
                    onAddHeader()
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.relay_edit_query_params)) },
                onClick = {
                    expanded = false
                    onAddQueryParam()
                },
            )
        }
    }
}

@Composable
internal fun RowIssues(issues: List<RelayFormValidation.FieldIssue>) {
    if (issues.isEmpty()) return
    RelayFormIssueNotes(issues = issues, modifier = Modifier.padding(start = ROW_H, end = ROW_H, bottom = 10.dp))
}

/**
 * Status row and failure card: while reconnecting / testing it uses the in-progress style (spinner, no icon), verified shows a success-colored check,
 * and a failure shows only the failure card (reason + technical details + "Save anyway (unverified)"), with no confirmation dialog.
 */
@Composable
internal fun StatusBlock(
    status: RelayEditStatus?,
    onSaveUnverified: () -> Unit,
    /** A note on its own line after the reason (manual setup on the add page: "The connection has not been saved yet"); null = not shown. */
    failureNote: String? = null,
    /** The "Close" of the failure card when saving unverified is not allowed: clears the failure state (edit connection); null = no button (manual setup relies on the bottom primary button). */
    onClose: (() -> Unit)? = null,
    /** Tone of the failure card; null = by error kind (manual setup). */
    severity: OriveoErrorSeverity? = null,
) {
    val colors = OriveoTheme.colors
    when (status) {
        null -> Unit
        RelayEditStatus.Reconnecting, RelayEditStatus.Testing -> Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            Text(
                text = stringResource(
                    if (status == RelayEditStatus.Reconnecting) {
                        R.string.relay_edit_status_reconnecting
                    } else {
                        R.string.relay_edit_status_testing
                    },
                ),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
        RelayEditStatus.Verified -> Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(painterResource(R.drawable.ph_check_circle), contentDescription = null, tint = colors.success, modifier = Modifier.size(16.dp))
            Text(stringResource(R.string.snackbar_connection_verified), style = OriveoTheme.typography.footnote, color = colors.success)
        }
        is RelayEditStatus.Failed -> {
            // Shared OriveoErrorCard (aligned with iOS): the title / severity come from the OriveoError mapped from the same exception, the reason uses stable copy of this platform,
            // and the technical details use only the redacted presentation; primary button = save anyway (unverified), or close when that is not allowed (edit connection).
            val canSave = status.canSaveUnverified
            val action: (() -> Unit)? = if (canSave) onSaveUnverified else onClose
            val reason = status.message.ifBlank { stringResource(R.string.relay_test_connection_missing_fields) }
            val error = OriveoError(
                title = status.error?.title ?: stringResource(R.string.error_generic_title),
                message = listOfNotNull(reason, failureNote).joinToString("\n"),
                actionTitle = when {
                    canSave -> stringResource(R.string.relay_save_unverified)
                    onClose != null -> stringResource(R.string.close)
                    else -> ""
                },
                detail = status.presentation?.let { relayFailureDetailText(it) }.orEmpty(),
                severity = severity ?: OriveoErrorSeverity.Warning,
            )
            OriveoErrorCard(
                error = error,
                onAction = action,
                actionModifier = Modifier
                    .fillMaxWidth(),
                // Failure card structure: title -> body -> full-width primary button -> "Technical details" below.
                detailsBelowAction = true,
            )
        }
    }
}

/** Technical details body: the presentation is already redacted; it is assembled as address -> HTTP -> automatic retries -> local exception -> upstream raw text. */
@Composable
private fun relayFailureDetailText(presentation: RelayEditFailurePresentation): String = buildList {
    if (presentation.endpoint.isNotBlank()) add("${stringResource(R.string.relay_field_endpoint)}: ${presentation.endpoint}")
    presentation.statusCode?.let { add("HTTP $it") }
    add(stringResource(R.string.relay_quick_automatic_retries, presentation.automaticRetryCount))
    presentation.localErrorDetail?.let { add(it) }
    presentation.upstreamJson?.let {
        add(stringResource(R.string.relay_upstream_response_redacted))
        add(it)
    }
}.joinToString("\n")

/** Sizes of the edit / manual setup rows (iOS rowBody: 14h / 10v, minimum height 56, icon 22, tap target 44). */
private val ROW_H = 14.dp
private val ROW_V = 10.dp
private val ROW_MIN_HEIGHT = 56.dp
private val ROW_ICON = 22.dp
private val ROW_ICON_GAP = 12.dp
private val ROW_TAP = 44.dp
private val ROW_CHEVRON = 14.dp
private val ROW_CHEVRON_GAP = 6.dp

/** In the test of whether a header / query parameter row fits on one line, the minimum width each of the name slot and the value slot needs. */
private val KV_SLOT_MIN = 72.dp
