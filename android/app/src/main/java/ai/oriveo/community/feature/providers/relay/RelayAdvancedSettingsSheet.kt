package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayWebSearchToolName
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.provider.RelayFamilyHeuristics
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.core.provider.RelayFormDraft
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.feature.providers.detail.ProviderDetailViewModel
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun RelayAdvancedSettingsSheet(
    provider: Provider,
    viewModel: ProviderDetailViewModel,
    onDismiss: () -> Unit,
) {
    val spacing = OriveoTheme.spacing
    val initialRequested = (provider.relayRequested ?: RelayKindDefaults.makeRequested(
        provider.relayKind ?: RelayKind.OpenAICompatible,
    )).let { requested ->
        if (requested.modelID.isNullOrBlank()) {
            requested.copy(modelID = provider.defaultModel?.id)
        } else {
            requested
        }
    }
    var draftKind by remember(provider.id, provider.relayKind, provider.relayRequested) {
        mutableStateOf(provider.relayKind ?: RelayKindDefaults.inferKind(provider.relayRequested))
    }
    var draftRequested by remember(provider.id) {
        mutableStateOf(initialRequested)
    }
    var draftEndpoint by remember(provider.id, provider.baseUrlText) {
        mutableStateOf(provider.baseUrlText.orEmpty())
    }
    var endpointSelectionRange by remember(provider.id) { mutableStateOf<IntRange?>(null) }
    var headers by remember(provider.id) {
        mutableStateOf(initialRequested.headers.orEmpty())
    }
    var queryParams by remember(provider.id) {
        mutableStateOf(initialRequested.queryParams.orEmpty())
    }
    var ignoredSuggestionFor by remember(provider.id) {
        mutableStateOf<String?>(null)
    }
    var pendingKindChange by remember(provider.id) {
        mutableStateOf<RelayKind?>(null)
    }
    var showKindPicker by remember(provider.id) { mutableStateOf(false) }
    var showAdvancedHttp by remember(provider.id) { mutableStateOf(false) }
    var showDiscardDialog by remember(provider.id) { mutableStateOf(false) }

    var streamTouched by remember(provider.id, provider.relayRequested) {
        mutableStateOf(provider.relayRequested?.stream != null)
    }

    val origRequested = remember(provider.id, provider.relayRequested) { initialRequested }
    val origEndpoint = remember(provider.id, provider.baseUrlText) { provider.baseUrlText.orEmpty() }
    val origHeaders = remember(provider.id, provider.relayRequested) { initialRequested.headers.orEmpty() }
    val origQueryParams = remember(provider.id, provider.relayRequested) { initialRequested.queryParams.orEmpty() }
    val origKind = remember(provider.id, provider.relayKind, provider.relayRequested) {
        provider.relayKind ?: RelayKindDefaults.inferKind(provider.relayRequested)
    }
    val isDirty = draftKind != origKind ||
        draftEndpoint != origEndpoint ||
        !relayRequestedMatchesPersisted(draftKind, origRequested, draftRequested) ||
        headers != origHeaders ||
        queryParams != origQueryParams

    val formDraft = RelayFormDraft(
        requested = draftRequested.copy(
            headers = headers.cleanRelayAdvancedPairs(),
            queryParams = queryParams.cleanRelayAdvancedPairs(),
        ),
        endpoint = draftEndpoint,
        hasSavedCredential = viewModel.hasStoredKey(provider),
    )
    val formIssues = RelayFormValidation.validate(formDraft, RelayFormValidation.FormMode.Edit)
    val normalizedDraftEndpoint = RelayFormValidation.normalizedEndpoint(
        formDraft,
        RelayFormValidation.FormMode.Edit,
    )
    val canSave = formIssues.isEmpty()
    val catalogState = viewModel.relayCatalogUiState(provider)
    val catalogModelIDs = remember(provider.catalogModels) {
        provider.catalogModels.map { it.id }.distinct()
    }
    val selectableCatalogModelIDs = remember(catalogModelIDs, draftRequested.modelID) {
        (listOfNotNull(draftRequested.modelID?.trim()?.takeIf(String::isNotEmpty)) + catalogModelIDs)
            .distinct()
    }
    val editPlan = viewModel.relayEditPlan(
        provider = provider,
        relayKind = draftKind,
        relayRequested = draftRequested,
        baseUrlText = normalizedDraftEndpoint ?: draftEndpoint,
    )

    val hasCredentialMaterial = RelayEndpointPolicy.hasCredentialMaterial(
        requested = initialRequested.copy(
            headers = (initialRequested.headers.orEmpty() + headers).ifEmpty { null },
            queryParams = (initialRequested.queryParams.orEmpty() + queryParams).ifEmpty { null },
        ),
        hasKey = viewModel.hasStoredKey(provider),
    )

    val attemptClose = {
        if (isDirty) showDiscardDialog = true else onDismiss()
    }

    if (showDiscardDialog) {
        AlertDialog(
            onDismissRequest = { showDiscardDialog = false },
            title = { Text(stringResource(R.string.relay_discard_changes_title)) },
            text = { Text(stringResource(R.string.relay_discard_changes_body)) },
            confirmButton = {
                TextButton(onClick = {
                    showDiscardDialog = false
                    onDismiss()
                }) {
                    Text(stringResource(R.string.relay_discard_changes_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { showDiscardDialog = false }) {
                    Text(stringResource(R.string.relay_discard_changes_keep))
                }
            },
        )
    }

    val suggestionKey = "${draftRequested.modelID.orEmpty()}::${draftKind.value}"
    val suggestedKind = suggestedRelayKind(
        currentKind = draftKind,
        modelID = draftRequested.modelID,
    ).takeUnless { ignoredSuggestionFor == suggestionKey }

    pendingKindChange?.let { pending ->
        AlertDialog(
            onDismissRequest = { pendingKindChange = null },
            title = { Text(stringResource(R.string.relay_kind_confirm_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.relay_kind_confirm_body,
                        relayKindTitle(draftKind),
                        relayKindTitle(pending),
                    ),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    draftRequested = RelayKindDefaults.makeRequested(pending, draftRequested)
                    draftKind = pending
                    streamTouched = true
                    ignoredSuggestionFor = null
                    pendingKindChange = null
                    showKindPicker = false
                    viewModel.invalidateRelayConnectionTest()
                }) {
                    Text(stringResource(R.string.relay_kind_confirm_apply))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingKindChange = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    Column(
        modifier = Modifier
            .padding(spacing.lg)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(spacing.lg),
    ) {

        RelayEditorHeroCard(
            displayName = provider.displayName,
            endpointText = draftEndpoint.trim().ifEmpty { provider.baseUrlText.orEmpty() }.takeIf { it.isNotBlank() },
            relayKind = draftKind,
            status = provider.status,
            onChangeKind = { showKindPicker = !showKindPicker },

            onEditName = null,
        )

        if (showKindPicker) {
            RelayKindPicker(
                selectedKind = draftKind,
                onSelect = { selected ->
                    if (selected == draftKind) {
                        showKindPicker = false
                        return@RelayKindPicker
                    }
                    pendingKindChange = selected
                },
            )
        }

        if (suggestedKind != null) {
            RelayKindSuggestionBanner(
                suggestedKind = suggestedKind,
                onApply = {
                    draftRequested = RelayKindDefaults.makeRequested(suggestedKind, draftRequested)
                    draftKind = suggestedKind
                    streamTouched = true
                    ignoredSuggestionFor = null
                    viewModel.invalidateRelayConnectionTest()
                },
                onKeep = { ignoredSuggestionFor = suggestionKey },
            )
        }

        RelayEditConnectionCard(
            endpoint = draftEndpoint,
            onEndpointChange = {
                draftEndpoint = it
                endpointSelectionRange = null
                viewModel.invalidateRelayConnectionTest()
            },
            apiKeyPreview = provider.apiKeyPreview,

            requiresCredential = draftRequested.requiresCredential,
            securityMode = draftRequested.securityMode,
            hasCredentialMaterial = hasCredentialMaterial,
            isSubmitting = viewModel.isSavingRelaySettings,
            isTestingConnection = viewModel.isTestingRelayConnection,
            testResult = viewModel.relayConnectionTestResult,
            endpointPlaceholder = stringResource(R.string.relay_endpoint_placeholder),
            endpointSelectionRange = endpointSelectionRange,
            onEditApiKey = {
                onDismiss()
                viewModel.startEditApiKey()
            },
            onSecurityModeSelected = { mode, assessment, confirmed ->
                val normalized = RelaySecurityModePolicy.normalizedEndpoint(
                    rawEndpoint = draftEndpoint,
                    mode = mode,
                    assessment = assessment,
                )
                val effectiveEndpoint = normalized ?: draftEndpoint.trim()
                if (normalized != null) {
                    endpointSelectionRange = RelaySecurityModePolicy.addedSchemeHighlightRange(
                        draftEndpoint,
                        normalized,
                    )
                    draftEndpoint = normalized
                }
                val cleartext = mode == ai.oriveo.community.core.model.RelayConnectionSecurityMode.LocalHttp ||
                    mode == ai.oriveo.community.core.model.RelayConnectionSecurityMode.PrivateVpn
                draftRequested = draftRequested.copy(
                    authMode = if (cleartext) RelayAuthMode.None else draftRequested.authMode,
                    securityMode = mode,
                    resolvedAPIBaseURL = null,
                )
                if (cleartext && confirmed && hasCredentialMaterial) {
                    headers = emptyList()
                    queryParams = emptyList()
                }

                viewModel.changeRelaySecurityMode(provider, mode, effectiveEndpoint)
            },
            onTestConnection = {
                val requestForTest = draftRequested.copy(
                    modelID = draftRequested.modelID?.trim()?.takeIf { it.isNotEmpty() },
                    serviceTier = draftRequested.serviceTier?.trim()?.takeIf { it.isNotEmpty() },
                    headers = headers.cleanRelayAdvancedPairs(),
                    queryParams = queryParams.cleanRelayAdvancedPairs(),
                    customUserAgent = draftRequested.customUserAgent?.trim()?.takeIf { it.isNotEmpty() },
                    codexCompatIdentity = relayCodexIdentityForSave(draftKind, draftRequested),
                )
                val normalized = runCatching {
                    RelayEndpointPolicy.requireConfigured(
                        baseUrl = draftEndpoint,
                        securityMode = requestForTest.securityMode,
                        credentials = RelayEndpointPolicy.credentialsOf(
                            requested = requestForTest,
                            hasKey = viewModel.hasStoredKey(provider),
                        ),
                    )
                }.getOrNull()
                if (normalized != null) {
                    endpointSelectionRange = RelaySecurityModePolicy.addedSchemeHighlightRange(
                        draftEndpoint,
                        normalized,
                    )
                    draftEndpoint = normalized
                }
                viewModel.testRelayConnection(
                    provider = provider,
                    relayKind = draftKind,
                    relayRequested = requestForTest,
                    endpoint = normalized ?: draftEndpoint,
                    modelID = draftRequested.modelID.orEmpty(),
                )
            },
        )
        RelayFormIssueNotes(issues = formIssues)

        Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
            RelayGroupHeader(
                title = stringResource(R.string.relay_default_model_label),
                icon = Icons.Filled.Memory,
                tint = OriveoTheme.colors.primary,
            )
            RelayRowGroup {
                when (catalogState) {
                    ProviderDetailViewModel.RelayCatalogUiState.Available -> RelayMenuRow(
                        title = stringResource(R.string.relay_default_model_label),
                        value = draftRequested.modelID.orEmpty(),
                        options = selectableCatalogModelIDs,
                        label = { modelID ->
                            val currentStored = ModelSelectionUtils.matchingModel(provider.models, modelID)
                                ?: ModelSelectionUtils.matchingModel(provider.catalogModels, modelID)
                            val missing = currentStored?.isManual != true &&
                                ModelSelectionUtils.matchingModel(provider.catalogModels, modelID) == null
                            when {
                                modelID.isBlank() -> stringResource(R.string.relay_default_model_placeholder)
                                missing -> "$modelID · ${stringResource(R.string.relay_model_missing_from_catalog)}"
                                else -> modelID
                            }
                        },
                        onSelect = {
                            draftRequested = draftRequested.copy(modelID = it)
                            viewModel.invalidateRelayConnectionTest()
                        },
                        enabled = !viewModel.isSavingRelaySettings,
                    )
                    ProviderDetailViewModel.RelayCatalogUiState.Loading -> Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = spacing.lg, vertical = spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(spacing.sm),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.height(18.dp))
                        Text(
                            text = stringResource(R.string.relay_catalog_loading),
                            style = OriveoTheme.typography.body,
                            color = OriveoTheme.colors.textSecondary,
                        )
                    }
                    ProviderDetailViewModel.RelayCatalogUiState.Failed,
                    ProviderDetailViewModel.RelayCatalogUiState.Empty,
                    -> RelayInlineTextRow(
                        title = stringResource(R.string.relay_default_model_label),
                        text = draftRequested.modelID.orEmpty(),
                        onValueChange = {
                            draftRequested = draftRequested.copy(modelID = it)
                            viewModel.invalidateRelayConnectionTest()
                        },
                        placeholder = stringResource(R.string.relay_default_model_placeholder),
                        enabled = !viewModel.isSavingRelaySettings,
                    )
                }
            }
            if (catalogState == ProviderDetailViewModel.RelayCatalogUiState.Failed) {
                Text(
                    text = stringResource(R.string.relay_catalog_failed_hint),
                    style = OriveoTheme.typography.caption,
                    color = OriveoTheme.colors.textSecondary,
                )
            }
        }

        val showsAdvanced = draftKind == RelayKind.Custom

        if (showsAdvanced) {

            Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                RelayGroupHeader(
                    title = stringResource(R.string.relay_section_protocol),
                    icon = Icons.Filled.SwapHoriz,
                    tint = OriveoTheme.colors.info,
                )
                RelayRowGroup {
                    RelayMenuRow(
                        title = stringResource(R.string.relay_advanced_transport),
                        value = draftRequested.transport,
                        options = RelayTransport.entries,
                        label = { relayAdvancedTransportLabel(it) },
                        onSelect = { newTransport ->
                            draftRequested = draftRequested.copy(
                                transport = newTransport,
                                webSearchToolName = if (newTransport == RelayTransport.OpenAIResponses) {
                                    draftRequested.webSearchToolName
                                } else {
                                    null
                                },
                            )
                            viewModel.invalidateRelayConnectionTest()
                        },
                    )
                    RelayRowDivider()
                    RelayMenuRow(
                        title = stringResource(R.string.relay_advanced_auth_mode),
                        value = draftRequested.authMode,
                        options = RelayAuthMode.entries,
                        label = { relayAdvancedAuthModeLabel(it) },
                        onSelect = {
                            draftRequested = draftRequested.copy(authMode = it)
                            viewModel.invalidateRelayConnectionTest()
                        },
                    )
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                RelayGroupHeader(
                    title = stringResource(R.string.relay_section_request_behavior),
                    icon = Icons.Filled.Memory,
                    tint = OriveoTheme.colors.primary,
                )
                RelayRowGroup {
                    RelayMenuRow(
                        title = stringResource(R.string.relay_advanced_reasoning_effort),
                        value = draftRequested.reasoningEffort ?: RelayReasoningEffort.Automatic,
                        options = RelayReasoningEffort.entries,
                        label = { relayAdvancedReasoningLabel(it) },
                        onSelect = {
                            draftRequested = draftRequested.copy(reasoningEffort = it)
                            viewModel.invalidateRelayConnectionTest()
                        },
                    )
                    RelayRowDivider()
                    RelayInlineTextRow(
                        title = stringResource(R.string.relay_advanced_service_tier),
                        text = draftRequested.serviceTier.orEmpty(),
                        onValueChange = { value ->
                            draftRequested = draftRequested.copy(serviceTier = value)
                            viewModel.invalidateRelayConnectionTest()
                        },
                        placeholder = stringResource(R.string.relay_advanced_service_tier_placeholder),
                    )
                    RelayRowDivider()
                    RelayToggleRow(
                        title = stringResource(R.string.relay_advanced_stream),
                        isOn = draftRequested.stream != false,
                        onToggle = {
                            draftRequested = draftRequested.copy(stream = it)
                            streamTouched = true
                            viewModel.invalidateRelayConnectionTest()
                        },
                    )
                    RelayRowDivider()
                    RelayToggleRow(
                        title = stringResource(R.string.relay_disable_response_storage_short),
                        isOn = draftRequested.disableResponseStorage == true,
                        onToggle = {
                            draftRequested = draftRequested.copy(
                                disableResponseStorage = it.takeIf { enabled -> enabled },
                            )
                            viewModel.invalidateRelayConnectionTest()
                        },
                        footnote = stringResource(R.string.relay_disable_response_storage_footnote),
                    )
                }
            }

            if (draftRequested.transport == RelayTransport.OpenAIResponses) {
                RelayWebSearchToolNameCard(
                    selected = draftRequested.webSearchToolName ?: RelayWebSearchToolName.WebSearch,
                    onSelect = { selected ->
                        draftRequested = draftRequested.copy(
                            webSearchToolName = selected.takeIf { it != RelayWebSearchToolName.WebSearch },
                        )
                        viewModel.invalidateRelayConnectionTest()
                    },
                )
            }

            RelayAdvancedHttpDisclosure(
                expanded = showAdvancedHttp,
                onToggle = { showAdvancedHttp = !showAdvancedHttp },
                customUserAgent = draftRequested.customUserAgent.orEmpty(),
                onUserAgentChange = {
                    draftRequested = draftRequested.copy(customUserAgent = it)
                    viewModel.invalidateRelayConnectionTest()
                },
                headers = headers,
                onHeadersChange = {
                    headers = it
                    viewModel.invalidateRelayConnectionTest()
                },
                queryParams = queryParams,
                onQueryParamsChange = {
                    queryParams = it
                    viewModel.invalidateRelayConnectionTest()
                },
            )
        } else {

            RelayPresetModeInfoCard(
                relayKind = draftKind,
                onClick = { showKindPicker = !showKindPicker },
            )
        }

        // 10. Save / Cancel
        Row(horizontalArrangement = Arrangement.spacedBy(spacing.md)) {
            OriveoSecondaryButton(
                text = stringResource(R.string.cancel),
                onClick = attemptClose,
                modifier = Modifier.weight(1f),
            )
            OriveoPrimaryButton(
                text = stringResource(
                    if (editPlan.requiresVerification) {
                        R.string.relay_validate_and_save
                    } else {
                        R.string.save
                    },
                ),
                enabled = canSave && !viewModel.isSavingRelaySettings,
                onClick = {

                    val resolvedStream: Boolean? = if (streamTouched) draftRequested.stream else origRequested.stream
                    val normalizedRequested = draftRequested.copy(
                        modelID = draftRequested.modelID?.trim()?.takeIf { it.isNotEmpty() },
                        serviceTier = draftRequested.serviceTier?.trim()?.takeIf { it.isNotEmpty() },
                        stream = resolvedStream,
                        headers = headers.cleanRelayAdvancedPairs(),
                        queryParams = queryParams.cleanRelayAdvancedPairs(),
                        customUserAgent = draftRequested.customUserAgent?.trim()?.takeIf { it.isNotEmpty() },
                        codexCompatIdentity = relayCodexIdentityForSave(draftKind, draftRequested),
                    )
                    viewModel.saveRelaySettings(
                        provider = provider,
                        relayKind = draftKind,
                        relayRequested = normalizedRequested,
                        baseUrlText = normalizedDraftEndpoint,
                        onSaved = onDismiss,
                    )
                },
                modifier = Modifier.weight(1f),
            )
        }
        if (viewModel.canSaveRelaySettingsUnverified) {
            OriveoSecondaryButton(
                text = stringResource(R.string.relay_save_unverified),
                onClick = { viewModel.saveRelaySettingsUnverified(onSaved = onDismiss) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(modifier = Modifier.height(spacing.xxl))
    }
}

@Composable
private fun RelayKindSuggestionBanner(
    suggestedKind: RelayKind,
    onApply: () -> Unit,
    onKeep: () -> Unit,
) {
    val colors = OriveoTheme.colors
    OriveoCard(
        fillColor = colors.primarySoft,
        borderColor = colors.primary.copy(alpha = 0.18f),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Text(
                text = stringResource(R.string.relay_kind_suggestion_title),
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
            )
            Text(
                text = stringResource(R.string.relay_kind_suggestion_body, relayKindTitle(suggestedKind)),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                OriveoPrimaryButton(
                    text = stringResource(R.string.relay_kind_suggestion_apply),
                    onClick = onApply,
                    modifier = Modifier.weight(1f),
                )
                OriveoSecondaryButton(
                    text = stringResource(R.string.relay_kind_suggestion_keep),
                    onClick = onKeep,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}
