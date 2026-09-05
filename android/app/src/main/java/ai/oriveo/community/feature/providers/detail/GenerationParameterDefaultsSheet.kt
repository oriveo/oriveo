package ai.oriveo.community.feature.providers.detail

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.util.launchExternalActivityOrNotify
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.capabilityCustomFragmentAvailable
import ai.oriveo.community.feature.chat.composer.modelControlOwnerOrder
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterPresetStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationParameterSyncCoordinator
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.provider.GenerationAccess
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterEmptyState
import ai.oriveo.community.core.provider.GenerationParameterEntryScope
import ai.oriveo.community.core.provider.GenerationParameterLifecycleRules
import ai.oriveo.community.core.provider.GenerationParameterPanelPresentation
import ai.oriveo.community.core.provider.GenerationParameterProfileHistory
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.GenerationParameterSupportPresentation
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.provider.UnsupportedParamCache
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoMotion
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.modelControlTextButtonColors
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import ai.oriveo.community.core.provider.GenerationParameterDiagnosticStore
import org.koin.compose.koinInject
import kotlinx.coroutines.launch


@Composable
fun GenerationParameterDefaultsSheet(
    provider: Provider,
    initialModelId: String? = null,
    conversationId: String? = null,
    modifier: Modifier = Modifier,
    
    isReadOnly: Boolean = false,
    
    containerProvidesTitle: Boolean = false,
    
    onSubPageVisibleChange: (Boolean) -> Unit = {},
    
    capabilityHeader: (@Composable () -> Unit)? = null,
    
    onSelectCandidateModel: ((ai.oriveo.community.core.model.AIModel) -> Unit)? = null,
) {
    val context = LocalContext.current
    val store = remember(context) { ai.oriveo.community.core.model.GenerationParameterSettingsStore.from(context) }
    val presetStore = remember(context) { GenerationParameterPresetStore.from(context) }
    val syncCoordinator = remember(context) { GenerationParameterSyncCoordinator(context) }
    val snackbarManager = koinInject<GlobalSnackbarManager>()
    val providerRepository = koinInject<ProviderRepository>()
    val coroutineScope = rememberCoroutineScope()
    val prettyJson = remember { Json { prettyPrint = true } }
    var modelId by remember { mutableStateOf(initialModelId ?: provider.models.firstOrNull { it.isDefault }?.id ?: provider.models.firstOrNull()?.id.orEmpty()) }
    val model = provider.models.firstOrNull { it.id == modelId }
    val capabilityPartition = providerRepository.currentCapabilityPartitionId()
    val capabilityObservationRevision by CapabilityEvidenceObservationBridge.revision.collectAsState()
    val capabilityScopeKey = model?.let {
        CapabilityEvidenceObservationBridge.uiIdentityScopeKey(
            provider = provider,
            model = it,
            partitionId = capabilityPartition,
            revision = capabilityObservationRevision,
        )
    }
    val latestCapabilityPartition by rememberUpdatedState(capabilityPartition)
    val latestCapabilityScopeKey by rememberUpdatedState(capabilityScopeKey)
    var localCapabilityIdentity by remember(capabilityPartition, capabilityScopeKey, model) {
        mutableStateOf<CapabilityEvidenceIdentity?>(null)
    }
    // The repository supplies only local epoch/revision identity. The core UI-scope helper is
    // solely responsible for deriving a Relay endpoint, and returns null on any ambiguity.
    LaunchedEffect(capabilityPartition, capabilityScopeKey, model) {
        localCapabilityIdentity = null
        val selectedModel = model
        val capturedPartition = capabilityPartition
        val capturedScopeKey = capabilityScopeKey
        if (provider.kind == ProviderKind.Relay && selectedModel != null) {
            val identity = providerRepository.capabilityEvidenceIdentity(
                provider = provider,
                modelId = selectedModel.id,
                partitionId = capturedPartition,
            )
            if (
                latestCapabilityPartition == capturedPartition &&
                latestCapabilityScopeKey == capturedScopeKey
            ) {
                localCapabilityIdentity = identity
            }
        }
    }
    val profileFingerprint = model?.let { ai.oriveo.community.core.model.GenerationParameterProfileFingerprint.make(provider, it) }
    var values by remember(modelId, profileFingerprint) {
        mutableStateOf(
            if (conversationId != null) {
                store.sessionOverrides(provider.id, modelId, conversationId, profileFingerprint)
            } else {
                store.modelDefaults(provider.id, modelId, profileFingerprint)
            } ?: GenerationParameterOverrides(),
        )
    }
    val activeProfile = model?.let { GenerationParameterAvailability.profile(provider, it) }
    val scope = if (conversationId != null) {
        GenerationParameterEntryScope.Session
    } else {
        GenerationParameterEntryScope.ConnectionDefaults
    }
    val generationAccess = GenerationAccess(true)
    // The legacy lifecycle helper remains responsible for scope and wire shape.
    // Evidence support, source/grade and the Relay explicit-value exception are only read from
    // the common projection below. UI scope is derived in core only for an unambiguous requested
    // Relay branch; a missing local identity or ambiguous endpoint remains fail-closed.
    val capabilityProjection = remember(
        provider,
        model,
        values,
        localCapabilityIdentity,
        capabilityObservationRevision,
    ) {
        model?.let { selected ->
            CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
                provider = provider,
                model = selected,
                localIdentity = localCapabilityIdentity,
                // Partition also needs decisions for values that are hidden by the current entry
                // scope, so derive one projection for the complete resolved profile.
                parameters = activeProfile?.parameters.orEmpty(),
                values = values,
            )
        }
    }
    
    
    // It receives the same UI projection as row editing and dormant partitioning.
    val lifecycleVisibleParameters = model?.let {
        GenerationParameterPanelPresentation.visibleParameters(
            provider = provider,
            model = it,
            scope = scope,
            access = generationAccess,
            capabilityProjection = capabilityProjection ?: return@let emptyList(),
        )
    }.orEmpty()
    val parameters = lifecycleVisibleParameters
    val profileHistory = remember(context) { GenerationParameterProfileHistory.from(context) }
    
    
    LaunchedEffect(provider.id, modelId, activeProfile?.parameters?.size) {
        profileHistory.recordSeenProfile(provider.id, modelId, activeProfile?.parameters?.size ?: 0)
    }
    
    
    val declaredEmptyState = model?.let {
        GenerationParameterPanelPresentation.emptyState(
            provider = provider,
            model = it,
            scope = scope,
            access = generationAccess,
            hasSeenNonEmptyProfile = profileHistory.hasSeenNonEmptyProfile(provider.id, modelId),
            capabilityProjection = capabilityProjection ?: return@let GenerationParameterEmptyState.NotVerified,
        )
    } ?: GenerationParameterEmptyState.NotVerified
    val emptyState = if (parameters.isEmpty()) {
        declaredEmptyState ?: GenerationParameterEmptyState.NotVerified
    } else {
        declaredEmptyState
    }
    val persist: (GenerationParameterOverrides) -> Unit = { updated ->
        if (conversationId != null) {
            store.setSessionOverrides(updated, provider.id, modelId, conversationId, profileFingerprint)
        } else {
            store.setModelDefaults(updated, provider.id, modelId, profileFingerprint)
        }
    }
    val basicParameters = buildList {
        parameters.firstOrNull { it.id == "max_output_tokens" }?.let(::add)
        (parameters.firstOrNull { it.id == "temperature" } ?: parameters.firstOrNull { it.id == "top_p" })?.let(::add)
    }
    val basicIds = basicParameters.mapNotNull { it.id }.toSet()
    val groupOrder = listOf("budget", "reasoning", "sampling", "repetition", "reproducibility", "output_contract", "engine_runtime")
    var expandedGroup by remember { mutableStateOf<String?>(null) }
    var presetName by remember { mutableStateOf("") }
    var presetRevision by remember { mutableStateOf(0) }
    var schemaDrafts by remember { mutableStateOf(emptyMap<String, String>()) }
    var invalidSchemaIds by remember { mutableStateOf(emptySet<String>()) }
    var diagnosticRevision by remember { mutableStateOf(0) }
    val exportSettings = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        uri?.let { context.contentResolver.openOutputStream(it)?.bufferedWriter()?.use { writer -> writer.write(syncCoordinator.exportJSON()) } }
    }
    val importSettings = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let {
            context.contentResolver.openInputStream(it)?.bufferedReader()?.use { reader ->
                runCatching { syncCoordinator.importJSON(reader.readText()) }.onSuccess {
                    values = store.modelDefaults(provider.id, modelId, profileFingerprint) ?: GenerationParameterOverrides()
                    presetRevision += 1
                }
            }
        }
    }
    val exportDiagnostics = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        uri?.let { context.contentResolver.openOutputStream(it)?.bufferedWriter()?.use { writer -> writer.write(GenerationParameterDiagnosticStore.redactedJSON()) } }
    }
    
    
    val partition = model?.let {
        GenerationParameterLifecycleRules.partition(
            provider = provider,
            model = it,
            values = values,
            capabilityProjection = capabilityProjection,
        )
    }
    val dormantIds = partition?.dormantIds.orEmpty()
    var dormantExpanded by remember(modelId) { mutableStateOf(false) }
    
    var page by remember(modelId) { mutableStateOf<GenerationParameterPage?>(null) }
    
    
    val notifySubPageVisible by rememberUpdatedState(onSubPageVisibleChange)
    LaunchedEffect(page != null) { notifySubPageVisible(page != null) }
    DisposableEffect(Unit) { onDispose { notifySubPageVisible(false) } }
    BackHandler(enabled = page != null) { page = null }
    var showsCustomFieldsUnsupportedAlert by remember(modelId) { mutableStateOf(false) }
    
    var pendingDestruction by remember(modelId) { mutableStateOf<GenerationDestructiveAction?>(null) }
    
    var customFieldsEntry by remember(modelId) { mutableStateOf(CustomFieldsEntry.Unsupported) }
    
    
    val customFieldsIdentity = remember(provider, model, capabilityObservationRevision) {
        model?.let { ModelControlRuntimeIdentityResolver.resolve(provider, it) }
    }
    val customFieldsStore = remember(context) { LocalCapabilityCustomFragmentStore.from(context) }
    
    val customFieldsCandidates = remember(provider, capabilityObservationRevision) {
        run {
            provider.models.filter { candidate ->
                val identity = ModelControlRuntimeIdentityResolver.resolve(provider, candidate)
                identity != null && modelControlOwnerOrder.any { owner ->
                    capabilityCustomFragmentAvailable(
                        providerKind = provider.kind,
                        modelID = candidate.id,
                        finalTransport = identity.finalTransport,
                        activeProfile = GenerationParameterAvailability.profile(provider, candidate),
                        owner = owner,
                    )
                }
            }
        }
    }
    LaunchedEffect(provider.id, modelId, conversationId, customFieldsIdentity, page) {
        
        if (page != null) return@LaunchedEffect
        customFieldsEntry = resolveCustomFieldsEntry(
            store = customFieldsStore,
            provider = provider,
            model = model,
            identity = customFieldsIdentity,
            conversationId = conversationId,
            activeProfile = activeProfile,
        )
    }
    
    var previousDormantIds by remember(provider.id, modelId, conversationId) { mutableStateOf<List<String>?>(null) }
    
    
    LaunchedEffect(dormantIds.joinToString("|")) {
        val previous = previousDormantIds
        previousDormantIds = dormantIds
        if (previous == null) return@LaunchedEffect
        val restored = previous.count { it !in dormantIds && values.values.containsKey(it) }
        if (restored > 0) {
            snackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.generation_parameter_dormant_restored, listOf(restored)),
                    style = GlobalToastStyle.Success,
                ),
            )
        }
    }
    val advancedParameters = parameters.filterNot { it.id?.let(basicIds::contains) == true }
    val visibleParameters = basicParameters + advancedParameters.filter { (it.group ?: "sampling") == expandedGroup }
    val activeParameterIds = values.values.filterValues { it.state == GenerationOverrideState.Value }.keys
    val compatibilityConflicts = parameters.mapNotNull { parameter ->
        parameter.id?.takeIf { it in activeParameterIds && parameter.conflictsWith.any(activeParameterIds::contains) }
    }.toSet()
    val portableSemanticMapping = parameters.mapNotNull { parameter ->
        parameter.id?.takeIf { parameter.portability == "portable" }?.let { it to it }
    }.toMap()

    
    
    
    
    
    
    
    
    
    
    
    
    val supportedModelsTransitionMillis =
        OriveoMotion.modelControlPageMillis(isReduceMotionEnabled(context))
    
    
    pendingDestruction?.let { action ->
        val conflictTitles = mutableListOf<String>()
        if (action == GenerationDestructiveAction.RemoveConflicts) {
            for (id in compatibilityConflicts.sorted()) conflictTitles += generationParameterTitle(id)
        }
        val confirmLabel = stringResource(action.confirmLabelRes)
        AlertDialog(
            onDismissRequest = { pendingDestruction = null },
            title = { Text(confirmLabel) },
            text = {
                Text(
                    
                    
                    if (action == GenerationDestructiveAction.RemoveConflicts) {
                        conflictTitles.joinToString(" · ")
                    } else {
                        stringResource(action.messageRes)
                    },
                )
            },
            confirmButton = {
                TextButton(
                    colors = ButtonDefaults.textButtonColors(contentColor = OriveoTheme.colors.danger),
                    onClick = {
                        val next = when (action) {
                            GenerationDestructiveAction.RestoreDefaults -> GenerationParameterOverrides()
                            GenerationDestructiveAction.ClearDormant -> {
                                dormantExpanded = false
                                partition?.active ?: values
                            }
                            GenerationDestructiveAction.RemoveConflicts ->
                                GenerationParameterOverrides(values.values - compatibilityConflicts)
                        }
                        values = next
                        persist(next)
                        pendingDestruction = null
                    },
                ) { Text(confirmLabel) }
            },
            dismissButton = {
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = { pendingDestruction = null },
                ) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
    if (showsCustomFieldsUnsupportedAlert) {
        
        
        val base = stringResource(R.string.generation_parameter_custom_fields_requires_schema)
        val noCandidates = stringResource(R.string.model_control_no_supported_models)
        AlertDialog(
            onDismissRequest = { showsCustomFieldsUnsupportedAlert = false },
            title = { Text(stringResource(R.string.model_control_custom_request_fields)) },
            text = {
                Text(if (customFieldsCandidates.isEmpty()) "$base\n\n$noCandidates" else base)
            },
            confirmButton = {
                if (customFieldsCandidates.isEmpty()) {
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = { showsCustomFieldsUnsupportedAlert = false },
                    ) { Text(stringResource(R.string.ok)) }
                } else {
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = {
                            showsCustomFieldsUnsupportedAlert = false
                            page = GenerationParameterPage.CustomFieldsSupportedModels
                        },
                    ) { Text(stringResource(R.string.model_control_view_supported_models)) }
                }
            },
            dismissButton = if (customFieldsCandidates.isEmpty()) {
                null
            } else {
                {
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = { showsCustomFieldsUnsupportedAlert = false },
                    ) { Text(stringResource(R.string.ok)) }
                }
            },
        )
    }
    AnimatedContent(
        targetState = page,
        modifier = modifier,
        transitionSpec = {
            val forward = targetState != null
            val spec = tween<IntOffset>(supportedModelsTransitionMillis)
            val fade = tween<Float>(supportedModelsTransitionMillis)
            ContentTransform(
                targetContentEnter = slideInHorizontally(spec) { width ->
                    if (forward) width else -width
                } + fadeIn(fade),
                initialContentExit = slideOutHorizontally(spec) { width ->
                    if (forward) -width else width
                } + fadeOut(fade),
                sizeTransform = SizeTransform { _, _ -> tween(supportedModelsTransitionMillis) },
            )
        },
        label = "generation-parameter-page",
    ) { currentPage ->
        if (currentPage is GenerationParameterPage.SupportedModels) {
            GenerationParameterSupportedModelsPage(
                provider = provider,
                parameterId = currentPage.parameterId,
                scope = scope,
                access = generationAccess,
                onBack = { page = null },
            )
        } else if (currentPage == GenerationParameterPage.CustomFieldsSupportedModels) {
            CustomFieldsSupportedModelsPage(
                provider = provider,
                candidates = customFieldsCandidates,
                onSelect = onSelectCandidateModel?.let { select -> { candidate -> select(candidate) } },
                onBack = { page = null },
            )
        } else if (currentPage == GenerationParameterPage.CustomFields &&
            model != null && customFieldsIdentity != null
        ) {
            CustomRequestFieldsPage(
                provider = provider,
                model = model,
                canonicalModelId = customFieldsIdentity.canonicalModelId,
                conversationId = conversationId,
                transportIdentity = customFieldsIdentity.storageIdentity,
                finalTransport = customFieldsIdentity.finalTransport,
                activeProfile = activeProfile,
                onBack = { page = null },
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                
                
                
                
                if (!containerProvidesTitle) {
                    Text(
                        stringResource(R.string.generation_model_behavior),
                        style = OriveoTheme.typography.title2,
                    )
                }
                
                
                capabilityHeader?.invoke()
                if (conversationId == null) {
                    Text(
                        stringResource(R.string.generation_connection_defaults, provider.displayName),
                        style = OriveoTheme.typography.caption,
                    )
                    
                    
                    
                    
                    
                    
                    
                    
                    LazyRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        items(items = provider.models, key = { it.id }) { candidate ->
                            FilterChip(
                                selected = candidate.id == modelId,
                                onClick = { modelId = candidate.id },
                                label = { Text(candidate.name) },
                            )
                        }
                    }
                } else if (model != null) {
                    Text(
                        "${stringResource(R.string.generation_current_conversation)} · ${model.name}",
                        style = OriveoTheme.typography.title3,
                    )
                    Text(
                        stringResource(R.string.generation_conversation_scope_hint),
                        style = OriveoTheme.typography.caption,
                    )
                }
                
                
                
                
                
                
                if (!isReadOnly && conversationId == null && profileFingerprint != null) {
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(
                            value = presetName,
                            onValueChange = { presetName = it },
                            modifier = Modifier.weight(1f),
                            label = { Text(stringResource(R.string.relay_field_name)) },
                            singleLine = true,
                        )
                        TextButton(
                            colors = modelControlTextButtonColors(),
                            enabled = presetName.isNotBlank(),
                            onClick = {
                                
                                
                                presetStore.save(presetName, provider.id, modelId, profileFingerprint, values)
                                presetName = ""
                                presetRevision += 1
                            },
                        ) { Text(stringResource(R.string.save)) }
                    }
                    presetStore.list(provider.id, modelId, profileFingerprint, portableSemanticMapping.keys).forEach { preset ->
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            TextButton(colors = modelControlTextButtonColors(), onClick = {
                                presetStore.apply(preset, provider.id, modelId, profileFingerprint, portableSemanticMapping)?.let { applied ->
                                    values = applied
                                    persist(applied)
                                }
                            }) { Text(preset.name) }
                            androidx.compose.foundation.layout.Spacer(modifier = Modifier.weight(1f))
                            TextButton(colors = modelControlTextButtonColors(), onClick = {
                                presetStore.apply(preset, provider.id, modelId, profileFingerprint, portableSemanticMapping)?.let { copied ->
                                    presetStore.save(preset.name, provider.id, modelId, profileFingerprint, copied)
                                    presetRevision += 1
                                }
                            }) { Text(stringResource(R.string.copy)) }
                            TextButton(colors = modelControlTextButtonColors(), onClick = {
                                presetStore.remove(preset.id)
                                presetRevision += 1
                            }) { Text(stringResource(R.string.delete)) }
                        }
                    }
                    presetRevision.hashCode()
                }
                if (!isReadOnly && conversationId == null) {
                    Text(stringResource(R.string.relay_section_connection), style = OriveoTheme.typography.title3)
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(colors = modelControlTextButtonColors(), onClick = {
                            val portableIds = parameters.filter { it.portability == "portable" }.mapNotNull { it.id }.toSet()
                            store.setConnectionDefaults(
                                GenerationParameterOverrides(values.values.filterKeys(portableIds::contains)),
                                provider.id,
                            )
                        }) { Text(stringResource(R.string.save)) }
                        TextButton(colors = modelControlTextButtonColors(), onClick = {
                            launchExternalActivityOrNotify(context) {
                                exportSettings.launch("oriveo-generation-parameters.v1.json")
                            }
                        }) {
                            Text(stringResource(R.string.export_backup_title))
                        }
                        TextButton(colors = modelControlTextButtonColors(), onClick = {
                            launchExternalActivityOrNotify(context) {
                                importSettings.launch(arrayOf("application/json", "text/json"))
                            }
                        }) {
                            Text(stringResource(R.string.import_action))
                        }
                    }
                }
                
                if (conversationId == null && true) {
                    val diagnostics = GenerationParameterDiagnosticStore.list(modelId)
                    Text(stringResource(R.string.provider_detail_badge_recent), style = OriveoTheme.typography.title3)
                    if (diagnostics.isEmpty()) {
                        Text(stringResource(R.string.no_tracked_usage_in_period), style = OriveoTheme.typography.caption)
                    }
                    diagnostics.take(20).forEach { entry ->
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(generationParameterTitle(entry.parameter), style = OriveoTheme.typography.body)
                            Text(
                                "${stringResource(if (entry.status == "recovered") R.string.status_connected else R.string.status_issue)} · " +
                                    stringResource(generationTransportTitleRes(entry.transport)),
                                style = OriveoTheme.typography.caption,
                            )
                        }
                    }
                    if (diagnostics.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(colors = modelControlTextButtonColors(), onClick = {
                                launchExternalActivityOrNotify(context) {
                                    exportDiagnostics.launch("oriveo-generation-diagnostics.redacted.json")
                                }
                            }) {
                                Text(stringResource(R.string.export_backup_title))
                            }
                            TextButton(colors = modelControlTextButtonColors(), onClick = {
                                GenerationParameterDiagnosticStore.clear()
                                diagnosticRevision += 1
                            }) { Text(stringResource(R.string.delete)) }
                        }
                    }
                    diagnosticRevision.hashCode()
                }
                if (compatibilityConflicts.isNotEmpty()) {
                    
                    
                    
                    val localizedConflictTitles = mutableListOf<String>()
                    for (id in compatibilityConflicts.sorted()) {
                        localizedConflictTitles += generationParameterTitle(id)
                    }
                    val conflictSummary = localizedConflictTitles.joinToString(" · ")
                    val removeLabel = stringResource(R.string.generation_parameter_remove_conflicts)
                    
                    
                    
                    
                    Text(
                        stringResource(R.string.generation_parameter_compatibility),
                        style = OriveoTheme.typography.title3,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().semantics(mergeDescendants = true) {
                            contentDescription = conflictSummary
                        },
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Warning,
                            contentDescription = null,
                            
                            tint = OriveoTheme.colors.warning,
                            modifier = Modifier.padding(end = 6.dp).size(14.dp),
                        )
                        Text(
                            conflictSummary,
                            style = OriveoTheme.typography.caption,
                            color = OriveoTheme.colors.warningText,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    
                    if (!isReadOnly) {
                        TextButton(
                            colors = ButtonDefaults.textButtonColors(
                                contentColor = OriveoTheme.colors.danger,
                            ),
                            onClick = { pendingDestruction = GenerationDestructiveAction.RemoveConflicts },
                            modifier = Modifier.semantics {
                                contentDescription = "$removeLabel · $conflictSummary"
                            },
                        ) { Text(removeLabel) }
                    }
                }
                
                if (!isReadOnly && conversationId == null && provider.kind == ProviderKind.Relay) {
                    TextButton(colors = modelControlTextButtonColors(), onClick = {
                        coroutineScope.launch {
                            val capturedPartition = capabilityPartition
                            val capturedScopeKey = capabilityScopeKey
                            providerRepository.capabilityEvidenceIdentity(
                                provider = provider,
                                modelId = modelId,
                                partitionId = capturedPartition,
                            )?.takeIf {
                                latestCapabilityPartition == capturedPartition &&
                                    latestCapabilityScopeKey == capturedScopeKey
                            }?.let { identity ->
                                UnsupportedParamCache.clearConnection(
                                    partitionId = identity.partitionId,
                                    connectionInstanceId = identity.connectionInstanceId,
                                    connectionGeneration = identity.connectionGeneration,
                                    credentialEpoch = identity.credentialEpoch,
                                    providerKind = identity.providerKind,
                                    effectiveModelId = modelId,
                                )
                            }
                        }
                    }) {
                        Text(stringResource(R.string.generation_parameter_clear_learned_capabilities))
                    }
                }
                
                if (parameters.isEmpty()) {
                    Text(stringResource(R.string.generation_parameters_section), style = OriveoTheme.typography.title3)
                    Text(stringResource(emptyState.titleRes), style = OriveoTheme.typography.body)
                    emptyState.detailRes?.let { detail ->
                        Text(stringResource(detail), style = OriveoTheme.typography.caption)
                    }
                }
                
                if (capabilityProjection != null &&
                    GenerationParameterPanelPresentation.showsUnverifiedGroupNote(parameters, capabilityProjection)
                ) {
                    Text(
                        stringResource(R.string.generation_parameter_unverified_group_note),
                        style = OriveoTheme.typography.caption,
                    )
                }
                if (visibleParameters.any { it.id?.let(basicIds::contains) == true }) {
                    Text(stringResource(R.string.generation_basic_settings), style = OriveoTheme.typography.title3)
                }
                var previousGroup: String? = null
                visibleParameters.forEach { parameter ->
                    val id = parameter.id ?: return@forEach
                    if (id !in basicIds && parameter.group != previousGroup) {
                        Text(groupLabel(parameter.group), style = OriveoTheme.typography.title3)
                        previousGroup = parameter.group
                    }
                    val currentOverride = values.values[id]
                    val current = currentOverride?.value
                    val decision = capabilityProjection?.let { projection ->
                        GenerationParameterPanelPresentation.generationParameterDecision(parameter, projection)
                    }
                    // The projection owns support/request policy; wire absence is a schema constraint,
                    // not a capability re-interpretation, so it still keeps this control read-only.
                    val editable = decision?.editable == true && !isReadOnly &&
                        !activeProfile?.wire?.get(id).isNullOrEmpty()
                    
                    
                    
                    val supportKey = GenerationParameterSupportPresentation
                        .effectiveSupport(parameter.support, decision?.resolution?.support)
                    val supportPresentation = GenerationParameterSupportPresentation.entry(supportKey)
                    val statusNote = supportPresentation.labelRes?.takeIf { supportPresentation.renders }?.let { labelRes ->
                        generationParameterStatusText(
                            supportLabel = stringResource(labelRes),
                            sourceLabel = stringResource(R.string.generation_parameter_source),
                            localizedSource = generationParameterSourceTitle(decision?.resolution?.source),
                        )
                    }
                    
                    val supportDetail = supportPresentation.detailRes
                        ?.takeIf { supportPresentation.renders }
                        ?.let { stringResource(it) }
                    val showsUnverified = capabilityProjection != null &&
                        GenerationParameterPanelPresentation.showsUnverifiedBadge(parameter, capabilityProjection)
                    val unverifiedBadge = if (showsUnverified) {
                        stringResource(R.string.generation_parameter_unverified_badge)
                    } else null
                    val parameterTitle = generationParameterTitle(id)
                    val rowLabel = generationParameterAccessibilityLabel(parameterTitle, unverifiedBadge, statusNote)
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            
                            
                            modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = rowLabel },
                        ) {
                            Text(parameterTitle, style = OriveoTheme.typography.body)
                            
                            
                            if (unverifiedBadge != null) {
                                Text(
                                    unverifiedBadge,
                                    style = OriveoTheme.typography.caption,
                                    modifier = Modifier
                                        .background(
                                            OriveoTheme.colors.textSecondary.copy(alpha = 0.12f),
                                            RoundedCornerShape(8.dp),
                                        )
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                )
                            }
                        }
                        
                        
                        basicParameterAnnotationRes(id)?.let { annotationRes ->
                            Text(stringResource(annotationRes), style = OriveoTheme.typography.caption)
                        }
                        if (statusNote != null) {
                            Text(statusNote, style = OriveoTheme.typography.caption)
                        }
                        if (supportDetail != null) {
                            Text(supportDetail, style = OriveoTheme.typography.caption)
                        }
                        
                        
                        
                        supportPresentation.primaryActionRes
                            ?.takeIf { supportPresentation.renders }
                            ?.let { actionRes ->
                                val actionLabel = stringResource(actionRes)
                                TextButton(
                                    colors = modelControlTextButtonColors(),
                                    onClick = { page = GenerationParameterPage.SupportedModels(id) },
                                    modifier = Modifier.semantics {
                                        contentDescription = "$actionLabel · $parameterTitle"
                                    },
                                ) { Text(actionLabel) }
                            }
                    if (parameter.fixedValue != null) {
                        Text(parameter.fixedValue?.toString().orEmpty(), modifier = Modifier.fillMaxWidth())
                    } else if (parameter.valueSchema == "enum" && parameter.enumValues.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            val choices = (parameter.enumValues + listOfNotNull(current)).distinct()
                            choices.forEach { choice ->
                                val choiceText = (choice as? JsonPrimitive)?.content ?: choice.toString()
                                FilterChip(
                                    selected = currentOverride?.state == GenerationOverrideState.Value && current == choice,
                                    enabled = editable && currentOverride?.state != GenerationOverrideState.Omit,
                                    onClick = { updateValue(values, id, choice, parameter, parameters, persist) { values = it } },
                                    label = { Text(choiceText) },
                                    
                                    modifier = Modifier.semantics { contentDescription = "$parameterTitle · $choiceText" },
                                )
                            }
                        }
                    } else if (parameter.valueSchema == "json-schema") {
                        val draft = schemaDrafts[id] ?: (current as? JsonObject)?.let {
                            prettyJson.encodeToString(JsonObject.serializer(), it)
                        }.orEmpty()
                        OutlinedTextField(
                            value = draft,
                            enabled = editable && currentOverride?.state != GenerationOverrideState.Omit,
                            isError = id in invalidSchemaIds,
                            onValueChange = { raw ->
                                schemaDrafts = schemaDrafts + (id to raw)
                                if (raw.isBlank()) {
                                    invalidSchemaIds = invalidSchemaIds - id
                                    val next = GenerationParameterOverrides(values.values - id)
                                    values = next
                                    persist(next)
                                } else {
                                    val parsed = runCatching { Json.parseToJsonElement(raw) }.getOrNull()
                                    if (parsed == null || !GenerationParameterResolver.isValidGenerationValue(parsed, parameter)) {
                                        invalidSchemaIds = invalidSchemaIds + id
                                    } else {
                                        invalidSchemaIds = invalidSchemaIds - id
                                        updateValue(values, id, parsed, parameter, parameters, persist) { values = it }
                                    }
                                }
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .semantics { contentDescription = parameterTitle },
                            label = { Text(stringResource(R.string.generation_parameter_json_schema_label)) },
                            minLines = 5,
                            singleLine = false,
                        )
                    } else if (parameter.valueSchema == "boolean") {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            androidx.compose.foundation.layout.Spacer(modifier = Modifier.weight(1f))
                            Switch(
                                checked = currentOverride?.state == GenerationOverrideState.Value && current?.let { it is JsonPrimitive && it.content == "true" } == true,
                                enabled = editable && currentOverride?.state != GenerationOverrideState.Omit,
                                onCheckedChange = { checked ->
                                    updateValue(values, id, JsonPrimitive(checked), parameter, parameters, persist) { values = it }
                                },
                                
                                modifier = Modifier.semantics { contentDescription = parameterTitle },
                            )
                        }
                    } else {
                        val text = when (current) {
                            is JsonArray -> current.joinToString(", ") { (it as? JsonPrimitive)?.content.orEmpty() }
                            is JsonPrimitive -> current.content
                            else -> ""
                        }
                        OutlinedTextField(
                            value = text,
                            enabled = editable && currentOverride?.state != GenerationOverrideState.Omit,
                            onValueChange = { raw ->
                                val next = values.values.toMutableMap()
                                if (raw.isEmpty()) {
                                    next.remove(id)
                                } else {
                                    val value = if (parameter.valueSchema == "integer" || parameter.valueSchema == "number") {
                                        raw.toDoubleOrNull()?.let(::JsonPrimitive) ?: return@OutlinedTextField
                                    } else if (parameter.valueSchema == "string-list") {
                                        JsonArray(raw.split(',').map(String::trim).filter(String::isNotEmpty).map(::JsonPrimitive))
                                    } else {
                                        JsonPrimitive(raw)
                                    }
                                    parameter.conflictsWith.forEach(next::remove)
                                    parameters.filter { id in it.conflictsWith }.mapNotNull { it.id }.forEach(next::remove)
                                    next[id] = GenerationParameterOverride(GenerationOverrideState.Value, value)
                                }
                                values = GenerationParameterOverrides(next)
                                persist(values)
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .semantics { contentDescription = parameterTitle },
                            label = { Text(parameterTitle) },
                            placeholder = { Text(stringResource(R.string.restore_defaults)) },
                            keyboardOptions = KeyboardOptions(keyboardType = if (parameter.valueSchema == "integer" || parameter.valueSchema == "number") KeyboardType.Decimal else KeyboardType.Text),
                            singleLine = true,
                        )
                    }
                        if (editable) {
                            
                            val defaultLabel = stringResource(R.string.generation_parameter_default)
                            val omitLabel = stringResource(R.string.generation_parameter_omit)
                            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                                TextButton(
                                    colors = modelControlTextButtonColors(),
                                    onClick = {
                                        val next = GenerationParameterOverrides(values.values - id)
                                        values = next
                                        persist(next)
                                    },
                                    modifier = Modifier.semantics { contentDescription = "$defaultLabel · $parameterTitle" },
                                ) { Text(defaultLabel) }
                                TextButton(
                                    colors = modelControlTextButtonColors(),
                                    onClick = {
                                        val next = GenerationParameterOverrides(values.values + (id to GenerationParameterOverride(GenerationOverrideState.Omit)))
                                        values = next
                                        persist(next)
                                    },
                                    modifier = Modifier.semantics { contentDescription = "$omitLabel · $parameterTitle" },
                                ) { Text(omitLabel) }
                            }
                        }
                    }
                }
                groupOrder.forEach { group ->
                    if (advancedParameters.any { (it.group ?: "sampling") == group }) {
                        TextButton(colors = modelControlTextButtonColors(), onClick = { expandedGroup = if (expandedGroup == group) null else group }) {
                            Text("${if (expandedGroup == group) "▾" else "›"} ${groupLabel(group)}")
                        }
                    }
                }
                
                
                
                Text(
                    stringResource(R.string.generation_parameter_unset_note),
                    style = OriveoTheme.typography.caption,
                )
                
                
                
                if (dormantIds.isNotEmpty() && partition != null) {
                    Text(
                        stringResource(R.string.generation_parameter_dormant_summary, dormantIds.size),
                        style = OriveoTheme.typography.caption,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(colors = modelControlTextButtonColors(), onClick = { dormantExpanded = !dormantExpanded }) {
                            Text(stringResource(R.string.generation_parameter_dormant_view))
                        }
                        if (!isReadOnly) {
                            
                            
                            
                            TextButton(
                                colors = ButtonDefaults.textButtonColors(
                                    contentColor = OriveoTheme.colors.danger,
                                ),
                                onClick = { pendingDestruction = GenerationDestructiveAction.ClearDormant },
                            ) { Text(stringResource(R.string.generation_parameter_dormant_clear)) }
                        }
                    }
                    if (dormantExpanded) {
                        dormantIds.forEach { id ->
                            val dormantTitle = generationParameterTitle(id)
                            val dormantValue = dormantValueText(
                                partition.dormant.values[id],
                                stringResource(R.string.generation_parameter_omit),
                            )
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    
                                    .semantics(mergeDescendants = true) {
                                        contentDescription = listOf(dormantTitle, dormantValue)
                                            .filter(String::isNotBlank)
                                            .joinToString(" · ")
                                    },
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(dormantTitle, style = OriveoTheme.typography.caption)
                                androidx.compose.foundation.layout.Spacer(modifier = Modifier.weight(1f))
                                Text(dormantValue, style = OriveoTheme.typography.caption)
                            }
                        }
                    }
                }
                if (!isReadOnly && values.values.isNotEmpty()) {
                    
                    TextButton(
                        colors = ButtonDefaults.textButtonColors(contentColor = OriveoTheme.colors.danger),
                        onClick = { pendingDestruction = GenerationDestructiveAction.RestoreDefaults },
                    ) {
                        Text(stringResource(R.string.restore_defaults))
                    }
                }
                
                
                
                
                Text(
                    stringResource(R.string.generation_parameter_developer),
                    style = OriveoTheme.typography.title3,
                )
                CustomFieldsEntryRow(
                    entry = customFieldsEntry,
                    
                    isReadOnly = isReadOnly,
                    onClick = {
                        if (customFieldsEntry == CustomFieldsEntry.Unsupported) {
                            showsCustomFieldsUnsupportedAlert = true
                        } else {
                            page = GenerationParameterPage.CustomFields
                        }
                    },
                )
            }
        }
    }
}


internal enum class GenerationDestructiveAction {
    RestoreDefaults,
    ClearDormant,
    RemoveConflicts;

    @get:androidx.annotation.StringRes
    val confirmLabelRes: Int
        get() = when (this) {
            RestoreDefaults -> R.string.restore_defaults
            ClearDormant -> R.string.generation_parameter_dormant_clear
            RemoveConflicts -> R.string.generation_parameter_remove_conflicts
        }

    
    @get:androidx.annotation.StringRes
    val messageRes: Int
        get() = when (this) {
            RestoreDefaults -> R.string.generation_parameter_restore_defaults_confirm
            ClearDormant -> R.string.generation_parameter_dormant_clear_confirm
            RemoveConflicts -> R.string.generation_parameter_compatibility
        }
}


internal sealed interface GenerationParameterPage {
    
    data class SupportedModels(val parameterId: String) : GenerationParameterPage

    
    data object CustomFields : GenerationParameterPage

    
    data object CustomFieldsSupportedModels : GenerationParameterPage
}


internal enum class CustomFieldsEntry {
    Unsupported,
    Idle,
    InUse;

    @get:androidx.annotation.StringRes
    val statusTextRes: Int
        get() = when (this) {
            Unsupported -> R.string.model_control_not_supported_by_model
            Idle -> R.string.generation_parameter_custom_fields_not_in_use
            InUse -> R.string.generation_parameter_custom_fields_in_use
        }
}


internal fun resolveCustomFieldsEntry(
    store: LocalCapabilityCustomFragmentStore,
    provider: Provider,
    model: ai.oriveo.community.core.model.AIModel?,
    identity: ai.oriveo.community.core.provider.ModelControlRuntimeIdentity?,
    conversationId: String?,
    activeProfile: ai.oriveo.community.core.model.GenerationProfileRef?,
): CustomFieldsEntry {
    if (model == null || identity == null) return CustomFieldsEntry.Unsupported
    var reachable = false
    var inUse = false
    modelControlOwnerOrder.forEach { owner ->
        if (capabilityCustomFragmentAvailable(
                providerKind = provider.kind,
                modelID = model.id,
                finalTransport = identity.finalTransport,
                activeProfile = activeProfile,
                owner = owner,
            )
        ) {
            reachable = true
        }
        val namespace = LocalCapabilityCustomFragmentStore.namespaceForOwner(owner) ?: return@forEach
        
        
        
        
        val configuration = store.effectiveConfiguration(
            providerID = provider.id,
            modelID = identity.canonicalModelId,
            conversationID = conversationId,
            transportIdentity = identity.storageIdentity,
            namespace = namespace,
            forwardPort = LocalCapabilityCustomFragmentStore.ForwardPortContext(
                providerKind = provider.kind,
                schemaModelID = model.id,
                activeProfile = activeProfile,
            ),
        )
        if (configuration.enabled) {
            inUse = true
            reachable = true
        }
        if (configuration.rawJSON.isNotBlank()) reachable = true
    }
    return when {
        inUse -> CustomFieldsEntry.InUse
        reachable -> CustomFieldsEntry.Idle
        else -> CustomFieldsEntry.Unsupported
    }
}

@Composable
private fun CustomFieldsEntryRow(
    entry: CustomFieldsEntry,
    isReadOnly: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val title = stringResource(R.string.model_control_custom_request_fields)
    val status = stringResource(entry.statusTextRes)
    val base = Modifier
        .fillMaxWidth()
        .heightIn(min = 44.dp)
    Row(
        modifier = if (isReadOnly) {
            base.semantics(mergeDescendants = true) {
                contentDescription = title
                stateDescription = status
            }
        } else {
            base
                .clickable(onClick = onClick)
                .semantics(mergeDescendants = true) {
                    role = Role.Button
                    contentDescription = title
                    stateDescription = status
                }
        },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = OriveoTheme.typography.body, modifier = Modifier.weight(1f))
        Text(status, style = OriveoTheme.typography.caption, color = colors.textSecondary)
        if (!isReadOnly) {
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.padding(start = 4.dp).size(14.dp),
            )
        }
    }
}


@Composable
private fun CustomFieldsSupportedModelsPage(
    provider: Provider,
    candidates: List<ai.oriveo.community.core.model.AIModel>,
    onSelect: ((ai.oriveo.community.core.model.AIModel) -> Unit)?,
    onBack: () -> Unit,
) {
    val switchHint = stringResource(R.string.model_control_switch_model_hint)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(colors = modelControlTextButtonColors(), onClick = onBack) {
                Text(stringResource(R.string.back))
            }
            Text(
                stringResource(R.string.model_control_custom_request_fields),
                style = OriveoTheme.typography.title3,
            )
        }
        Text(
            stringResource(
                if (candidates.isEmpty()) {
                    R.string.model_control_no_supported_models
                } else {
                    R.string.model_control_supported_models_header
                },
            ),
            style = OriveoTheme.typography.caption,
            color = OriveoTheme.colors.textSecondary,
        )
        candidates.forEach { candidate ->
            if (onSelect == null) {
                Text(candidate.name, style = OriveoTheme.typography.body, modifier = Modifier.fillMaxWidth())
            } else {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 52.dp)
                        .clickable { onSelect(candidate) }
                        .semantics(mergeDescendants = true) {
                            role = Role.Button
                            contentDescription = candidate.name
                            stateDescription = switchHint
                        },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ProviderBadgeIcon(kind = provider.kind, size = 26.dp, relayKind = provider.relayKind)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        candidate.name,
                        style = OriveoTheme.typography.body,
                        modifier = Modifier.weight(1f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        stringResource(R.string.model_control_switch_to_model),
                        style = OriveoTheme.typography.caption,
                        color = OriveoTheme.colors.primaryTextSafe,
                    )
                    Icon(
                        imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                        contentDescription = null,
                        tint = OriveoTheme.colors.textSecondary,
                        modifier = Modifier.padding(start = 4.dp).size(14.dp),
                    )
                }
            }
        }
    }
}


@androidx.annotation.StringRes
internal fun basicParameterAnnotationRes(id: String): Int? = when (id) {
    "temperature" -> R.string.generation_parameter_temperature_note
    "max_output_tokens" -> R.string.generation_parameter_max_tokens_note
    else -> null
}


@Composable
private fun GenerationParameterSupportedModelsPage(
    provider: Provider,
    parameterId: String,
    scope: GenerationParameterEntryScope,
    access: GenerationAccess,
    onBack: () -> Unit,
) {
    
    val candidates = remember(provider, parameterId, scope, access) {
        GenerationParameterPanelPresentation.modelsAcceptingParameter(
            provider = provider,
            parameterId = parameterId,
            scope = scope,
            access = access,
        )
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(colors = modelControlTextButtonColors(), onClick = onBack) { Text(stringResource(R.string.back)) }
            Text(generationParameterTitle(parameterId), style = OriveoTheme.typography.title3)
        }
        Text(
            stringResource(
                if (candidates.isEmpty()) {
                    
                    R.string.generation_parameter_supported_models_empty
                } else {
                    R.string.generation_parameter_supported_models_intro
                },
            ),
            style = OriveoTheme.typography.caption,
            color = OriveoTheme.colors.textSecondary,
        )
        candidates.forEach { candidate ->
            Text(
                candidate.name,
                style = OriveoTheme.typography.body,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * Read-only display for a dormant override value. Echo the stored value as-is
 * (no silent conversion) so users can confirm what they originally set.
 */
private fun dormantValueText(override: GenerationParameterOverride?, omitLabel: String): String = when {
    override == null || override.state == GenerationOverrideState.Inherit -> ""
    override.state == GenerationOverrideState.Omit -> omitLabel
    else -> when (val value = override.value) {
        null -> ""
        is JsonArray -> value.joinToString(", ") { (it as? JsonPrimitive)?.content.orEmpty() }
        is JsonPrimitive -> value.content
        else -> value.toString()
    }
}

private fun updateValue(
    current: GenerationParameterOverrides,
    id: String,
    value: kotlinx.serialization.json.JsonElement,
    parameter: ai.oriveo.community.core.model.GenerationParameterRef,
    parameters: List<ai.oriveo.community.core.model.GenerationParameterRef>,
    persist: (GenerationParameterOverrides) -> Unit,
    apply: (GenerationParameterOverrides) -> Unit,
) {
    val next = current.values.toMutableMap()
    parameter.conflictsWith.forEach(next::remove)
    parameters.filter { id in it.conflictsWith }.mapNotNull { it.id }.forEach(next::remove)
    next[id] = GenerationParameterOverride(GenerationOverrideState.Value, value)
    val updated = GenerationParameterOverrides(next)
    apply(updated)
    persist(updated)
}

/**
 * Single display formatter for generation parameter names / source tokens.
 * Row titles, editor labels, dormant lists, conflict summaries, and a11y share this.
 */
@androidx.annotation.StringRes
internal fun generationParameterTitleRes(raw: String): Int = when (raw) {
    "max_output_tokens" -> R.string.max_tokens
    "stop" -> R.string.stop
    "temperature" -> R.string.temperature
    "top_p" -> R.string.generation_parameter_name_top_p
    "top_k" -> R.string.generation_parameter_name_top_k
    "min_p" -> R.string.generation_parameter_name_min_p
    "typical_p" -> R.string.generation_parameter_name_typical_p
    "frequency_penalty" -> R.string.generation_parameter_name_frequency_penalty
    "presence_penalty" -> R.string.generation_parameter_name_presence_penalty
    "repeat_penalty" -> R.string.generation_parameter_name_repeat_penalty
    "seed" -> R.string.generation_parameter_name_seed
    "response_format" -> R.string.generation_parameter_name_response_format
    "json_schema" -> R.string.generation_parameter_json_schema_label
    "verbosity" -> R.string.generation_parameter_name_verbosity
    "logprobs" -> R.string.generation_parameter_name_log_probabilities
    "top_logprobs" -> R.string.generation_parameter_name_top_log_probabilities
    "reasoning_effort" -> R.string.generation_parameter_name_reasoning_effort
    "reasoning_budget" -> R.string.generation_parameter_name_reasoning_budget
    "reasoning_mode" -> R.string.generation_parameter_name_reasoning_mode
    "route_require_parameters" -> R.string.generation_parameter_name_route_require_parameters
    "dry_allowed_length" -> R.string.generation_parameter_name_dry_allowed_length
    "dry_base" -> R.string.generation_parameter_name_dry_base
    "dry_multiplier" -> R.string.generation_parameter_name_dry_multiplier
    "dry_penalty_last_n" -> R.string.generation_parameter_name_dry_penalty_last_n
    "dry_sequence_breakers" -> R.string.generation_parameter_name_dry_sequence_breakers
    "dynatemp_exponent" -> R.string.generation_parameter_name_dynatemp_exponent
    "dynatemp_range" -> R.string.generation_parameter_name_dynatemp_range
    "ignore_eos" -> R.string.generation_parameter_name_ignore_eos
    "llamacpp_native" -> R.string.generation_parameter_name_llamacpp_native
    "min_keep" -> R.string.generation_parameter_name_min_keep
    "mirostat" -> R.string.generation_parameter_name_mirostat
    "mirostat_eta" -> R.string.generation_parameter_name_mirostat_eta
    "mirostat_tau" -> R.string.generation_parameter_name_mirostat_tau
    "n_indent" -> R.string.generation_parameter_name_n_indent
    "n_keep" -> R.string.generation_parameter_name_n_keep
    "n_probs" -> R.string.generation_parameter_name_n_probabilities
    "post_sampling_probs" -> R.string.generation_parameter_name_post_sampling_probabilities
    "repeat_last_n" -> R.string.generation_parameter_name_repeat_last_n
    "samplers" -> R.string.generation_parameter_name_samplers
    "t_max_predict_ms" -> R.string.generation_parameter_name_max_predict_time
    "top_n_sigma" -> R.string.generation_parameter_name_top_n_sigma
    "xtc_probability" -> R.string.generation_parameter_name_xtc_probability
    "xtc_threshold" -> R.string.generation_parameter_name_xtc_threshold
    else -> R.string.generation_parameter_name_other
}

@Composable
private fun generationParameterTitle(raw: String): String = stringResource(generationParameterTitleRes(raw))

@androidx.annotation.StringRes
internal fun generationParameterSourceTitleRes(raw: String?): Int = when (raw?.trim()) {
    "authoritative_metadata", "official_catalog", "provider_recipe", "server_profile", "server_typed" ->
        R.string.generation_parameter_source_official
    "provider_metadata", "relay_declaration", "relay_declared", "engine_introspection" ->
        R.string.generation_parameter_source_connection
    "runtime_feedback", "runtime_observation" -> R.string.generation_parameter_source_runtime
    "connection", "connection_model", "conversation_connection_model", "single_send", "user_declared" ->
        R.string.generation_parameter_source_preference
    "custom", "explicit_omit", "operator_override" -> R.string.generation_parameter_source_override
    "legacy_metadata" -> R.string.generation_parameter_source_legacy
    else -> R.string.generation_parameter_source_other
}

@Composable
private fun generationParameterSourceTitle(raw: String?): String? = raw
    ?.takeIf { it.isNotBlank() }
    ?.let { stringResource(generationParameterSourceTitleRes(it)) }

@androidx.annotation.StringRes
internal fun generationTransportTitleRes(raw: String): Int = when (raw.trim().lowercase()) {
    "openai_responses", "responses_api" -> R.string.relay_transport_openai_responses
    "openai_chat", "openai_chat_completions", "chat_completions" ->
        R.string.relay_transport_openai_chat_completions
    "anthropic_messages" -> R.string.relay_transport_anthropic_messages
    "gemini_generate", "gemini_generate_content" -> R.string.relay_transport_gemini_generate_content
    "llamacpp_native" -> R.string.relay_transport_llamacpp_native
    else -> R.string.generation_parameter_transport_other
}


internal fun generationParameterStatusText(
    supportLabel: String,
    sourceLabel: String,
    localizedSource: String?,
): String {
    val text = localizedSource.orEmpty().trim()
    return if (text.isEmpty()) supportLabel else "$supportLabel · $sourceLabel: $text"
}


internal fun generationParameterAccessibilityLabel(
    parameterTitle: String,
    unverifiedBadge: String?,
    statusNote: String?,
): String = listOfNotNull(
    parameterTitle,
    unverifiedBadge?.takeIf { it.isNotBlank() },
    statusNote?.takeIf { it.isNotBlank() },
).joinToString(" · ")

/**
 * Compose must not keep a Relay identity across a same-id route or credential update. Deliberately
 * exclude API keys and custom headers: `updatedAt` observes their local epoch change without
 * placing secret material in a composition key.
 */
@Composable
private fun groupLabel(group: String?): String = when (group) {
    "budget" -> stringResource(R.string.generation_group_budget)
    "reasoning" -> stringResource(R.string.generation_group_reasoning)
    "sampling" -> stringResource(R.string.generation_group_sampling)
    "repetition" -> stringResource(R.string.generation_group_repetition)
    "reproducibility" -> stringResource(R.string.generation_group_reproducibility)
    "output_contract" -> stringResource(R.string.generation_group_output_contract)
    else -> stringResource(R.string.generation_group_engine_runtime)
}
