package ai.oriveo.community.feature.chat.composer

import androidx.activity.compose.BackHandler
import androidx.annotation.StringRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.automirrored.outlined.AltRoute
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.DataObject
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityWebPreferenceLiveness
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.capabilityCustomFragmentAvailable
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import ai.oriveo.community.feature.providers.detail.GenerationParameterDefaultsSheet
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoMotion
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.modelControlTextButtonColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch


internal sealed interface ModelControlsRoute {
    data object ModelBehavior : ModelControlsRoute

    data class SupportedModels(val capability: String) : ModelControlsRoute
}


private data class CapabilityExplanation(
    val capability: String,
    val message: String,
    val escape: ModelControlCapabilityEscape,
)


@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ModelControlsEntrySheet(
    provider: Provider?,
    model: AIModel?,
    conversationId: String,
    finalTransport: String?,
    metadataRevision: String?,
    capabilityObservationRevision: Long,
    runtimeIsReadOnly: Boolean,
    @StringRes runtimeReadOnlyReasonRes: Int?,
    web: CapabilityWebPreference,
    reasoningIntent: String?,
    customOwners: Set<String>,
    generationOverrideCount: Int,
    
    onSelectionChange: (CapabilityWebPreference, String?, Boolean) -> Unit,
    onPersist: (CapabilityPreferenceValues) -> Unit,
    onPromoteToModelDefault: (CapabilityPreferenceValues) -> Unit,
    onAdvancedSettingsClosed: () -> Unit,
    onChooseAnotherModel: () -> Unit,
    onOpenConnectionSettings: () -> Unit,
    onNavigateToProviderSetup: () -> Unit,
    onSelectModel: (providerId: String, modelId: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        
        
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        
        
        containerColor = colors.background,
        contentColor = colors.textPrimary,
        contentWindowInsets = { WindowInsets(0) },
    ) {
        if (provider == null || model == null) {
            ModelControlsMissingModelPanel(
                providerName = provider?.displayName,
                
                
                onChooseConnection = { onDismiss(); onNavigateToProviderSetup() },
                onClose = onDismiss,
            )
        } else {
            ModelControlsPanel(
                provider = provider,
                model = model,
                conversationId = conversationId,
                finalTransport = finalTransport,
                metadataRevision = metadataRevision,
                capabilityObservationRevision = capabilityObservationRevision,
                runtimeIsReadOnly = runtimeIsReadOnly,
                runtimeReadOnlyReasonRes = runtimeReadOnlyReasonRes,
                web = web,
                reasoningIntent = reasoningIntent,
                customOwners = customOwners,
                generationOverrideCount = generationOverrideCount,
                onSelectionChange = onSelectionChange,
                onPersist = onPersist,
                onPromoteToModelDefault = onPromoteToModelDefault,
                onAdvancedSettingsClosed = onAdvancedSettingsClosed,
                onChooseAnotherModel = onChooseAnotherModel,
                onOpenConnectionSettings = onOpenConnectionSettings,
                onSelectModel = onSelectModel,
                onDismiss = onDismiss,
            )
        }
    }
}


@Composable
private fun ModelControlsMissingModelPanel(
    providerName: String?,
    onChooseConnection: () -> Unit,
    onClose: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val rows = listOf(
        R.string.model_control_web_search,
        R.string.model_control_thinking,
        R.string.generation_model_behavior,
    )
    ModelControlsScaffold(onClose = onClose, bottomExtra = null) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Text(
                text = providerName ?: stringResource(R.string.model_controls),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
            )
            Column(
                modifier = Modifier.fillMaxWidth().modelControlSurface().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                ModelControlNote(R.string.model_control_context_unavailable, Icons.Outlined.Lock)
                ModelControlInlineAction(
                    title = stringResource(R.string.model_control_choose_connection),
                    icon = Icons.AutoMirrored.Outlined.AltRoute,
                    onClick = onChooseConnection,
                )
            }
            Column(modifier = Modifier.fillMaxWidth().modelControlSurface()) {
                rows.forEachIndexed { index, titleRes ->
                    ModelControlListRow(
                        title = stringResource(titleRes),
                        status = stringResource(R.string.model_control_state_not_ready),
                    )
                    if (index < rows.lastIndex) ModelControlHairline()
                }
            }
        }
    }
}


@Composable
private fun ModelControlsScaffold(
    onClose: () -> Unit,
    bottomExtra: (@Composable () -> Unit)?,
    content: @Composable () -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
        Box(modifier = Modifier.weight(1f)) { content() }
        bottomExtra?.invoke()
        ModelControlsCloseBar(onClose = onClose)
    }
}

@Composable
private fun ModelControlsPanel(
    provider: Provider,
    model: AIModel,
    conversationId: String,
    finalTransport: String?,
    metadataRevision: String?,
    capabilityObservationRevision: Long,
    runtimeIsReadOnly: Boolean,
    @StringRes runtimeReadOnlyReasonRes: Int?,
    web: CapabilityWebPreference,
    reasoningIntent: String?,
    customOwners: Set<String>,
    generationOverrideCount: Int,
    onSelectionChange: (CapabilityWebPreference, String?, Boolean) -> Unit,
    onPersist: (CapabilityPreferenceValues) -> Unit,
    onPromoteToModelDefault: (CapabilityPreferenceValues) -> Unit,
    onAdvancedSettingsClosed: () -> Unit,
    onChooseAnotherModel: () -> Unit,
    onOpenConnectionSettings: () -> Unit,
    onSelectModel: (providerId: String, modelId: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val metadata = MetadataClient.instance

    var route by remember { mutableStateOf<ModelControlsRoute?>(null) }
    
    var routeOrigin by remember { mutableStateOf<ModelControlsRoute?>(null) }
    
    var routeIsForward by remember { mutableStateOf(true) }
    
    var behaviorSubPageOpen by remember { mutableStateOf(false) }

    fun openRoute(next: ModelControlsRoute) {
        routeOrigin = route
        routeIsForward = true
        route = next
    }

    fun popRoute() {
        routeIsForward = false
        route = routeOrigin
        routeOrigin = null
    }

    var explanation by remember { mutableStateOf<CapabilityExplanation?>(null) }
    
    var refreshedIdentity by remember(provider.id, model.id, metadataRevision) {
        mutableStateOf<ModelControlRuntimeIdentity?>(null)
    }
    var isRefreshingRuntime by remember { mutableStateOf(false) }
    var runtimeRefreshFailed by remember { mutableStateOf(false) }
    
    var showsScopeUpgrade by remember { mutableStateOf(false) }
    var scopeUpgradeConfirmed by remember { mutableStateOf(false) }
    var scopeUpgradeConfirmations by remember { mutableIntStateOf(0) }

    val identity = remember(provider, model, metadataRevision, refreshedIdentity) {
        refreshedIdentity ?: ModelControlRuntimeIdentityResolver.resolve(provider, model, metadata)
    }
    val editability = ModelControlsEditability.resolve(
        transportIdentity = identity?.storageIdentity,
        runtimeIsReadOnly = runtimeIsReadOnly,
    )
    val identityGap = remember(provider, metadataRevision, refreshedIdentity) {
        ModelControlsIdentityGap.resolve(
            providerKind = provider.kind,
            relayTransportIsDecided = provider.relayRequested?.transport
                ?.takeIf { it != RelayTransport.Auto } != null,
            runtimeIsReady = metadata.currentCapabilityRuntimeRevision() != null,
        )
    }
    val readOnlyReasonRes: Int? = when (editability) {
        ModelControlsEditability.RuntimeReadOnly -> runtimeReadOnlyReasonRes
        ModelControlsEditability.RuntimeIdentityUnavailable -> identityGap.reasonTextRes
        ModelControlsEditability.Writable -> null
    }

    val customTransport = identity?.finalTransport
    val activeGenerationProfile = remember(provider, model, metadataRevision) {
        GenerationParameterAvailability.profile(provider, model)
    }
    
    val hasSafeCustomSchema = remember(provider, model, customTransport, activeGenerationProfile, metadataRevision) {
        modelControlOwnerOrder.any { owner ->
            customTransport != null && capabilityCustomFragmentAvailable(
                providerKind = provider.kind,
                modelID = model.id,
                finalTransport = customTransport,
                activeProfile = activeGenerationProfile,
                owner = owner,
            )
        }
    }

    val presentations = remember(provider, model, finalTransport, metadataRevision, capabilityObservationRevision) {
        modelControlOwnerOrder.associateWith { capability ->
            CapabilityControlPresentationResolver.presentation(provider, model, capability, metadata, finalTransport)
        }
    }
    fun presentation(capability: String): CapabilityControlPresentation =
        presentations[capability] ?: CapabilityControlPresentation.Unknown

    
    val webIntents = remember(provider, model, finalTransport, metadataRevision, capabilityObservationRevision) {
        val control = finalTransport
            ?.let { metadata.capabilityControlPresentation(provider.kind, model.id, it)["web"] }
        modelControlWebAvailableIntents(control)
    }
    val reasoningIntents = remember(provider, model, finalTransport, metadataRevision, capabilityObservationRevision) {
        CapabilityControlResolution.resolve(provider, model, "reasoning", metadata, finalTransport).intents
    }

    fun isCustomActive(owner: String): Boolean = owner in customOwners

    
    val candidatesByCapability = remember(provider, metadataRevision, capabilityObservationRevision) {
        val resolver = ChatModelCapabilityResolver()
        modelControlOwnerOrder.associateWith { resolver.supportedModelCandidates(provider, it) }
    }
    fun candidates(capability: String): List<AIModel> = candidatesByCapability[capability].orEmpty()

    fun riskTiers(owner: String): List<String> = customTransport?.let { transport ->
        metadata.capabilityCustomControlAuthority(provider.kind, model.id, transport, owner)?.riskTiers
    }.orEmpty()

    fun upstreamRejected(owner: String): Boolean =
        identity != null && owner != "generation" &&
            ModelControlRejectionCache.isRejectedByAnySource(identity, owner)

    
    fun persist(nextWeb: CapabilityWebPreference, nextIntent: String?) {
        
        
        scopeUpgradeConfirmed = false
        
        
        val clamped = ModelControlWebLayout.clamp(nextWeb, presentation("web"), webIntents)
        
        
        
        onSelectionChange(
            clamped,
            nextIntent,
            CapabilityWebPreferenceLiveness.reachesTheWire(presentation("web"), isCustomActive("web")),
        )
        if (!editability.canPersist || identity == null) return
        onPersist(CapabilityPreferenceValues(clamped, nextIntent))
        
        
        if (!showsScopeUpgrade) showsScopeUpgrade = true
    }

    fun promoteToModelDefault() {
        if (!editability.canPersist || identity == null) return
        onPromoteToModelDefault(CapabilityPreferenceValues(web, reasoningIntent))
        scopeUpgradeConfirmed = true
        scopeUpgradeConfirmations += 1
    }

    
    LaunchedEffect(scopeUpgradeConfirmations) {
        if (scopeUpgradeConfirmations == 0) return@LaunchedEffect
        delay(3_000)
        if (scopeUpgradeConfirmed) {
            showsScopeUpgrade = false
            scopeUpgradeConfirmed = false
        }
    }

    
    
    val noCandidatesSentence = stringResource(R.string.model_control_no_supported_models)
    fun presentExplanation(capability: String, message: String, escape: ModelControlCapabilityEscape) {
        var body = message
        var resolved = escape
        if (escape == ModelControlCapabilityEscape.SupportedModels && candidates(capability).isEmpty()) {
            body += "\n\n$noCandidatesSentence"
            resolved = ModelControlCapabilityEscape.None
        }
        explanation = CapabilityExplanation(capability, body, resolved)
    }

    explanation?.let { detail ->
        AlertDialog(
            onDismissRequest = { explanation = null },
            title = { Text(stringResource(modelControlCapabilityTitleRes(detail.capability))) },
            text = { Text(detail.message) },
            confirmButton = {
                when (detail.escape) {
                    ModelControlCapabilityEscape.SupportedModels -> TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = {
                            explanation = null
                            openRoute(ModelControlsRoute.SupportedModels(detail.capability))
                        },
                    ) { Text(stringResource(R.string.model_control_view_supported_models)) }
                    ModelControlCapabilityEscape.AdvancedSettings -> TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = {
                            explanation = null
                            openRoute(ModelControlsRoute.ModelBehavior)
                        },
                    ) { Text(stringResource(R.string.model_control_go_to_advanced_settings)) }
                    ModelControlCapabilityEscape.None -> TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = { explanation = null },
                    ) { Text(stringResource(R.string.ok)) }
                }
            },
            dismissButton = if (detail.escape == ModelControlCapabilityEscape.None) {
                null
            } else {
                {
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = { explanation = null },
                    ) { Text(stringResource(R.string.ok)) }
                }
            },
        )
    }

    
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    val pageMillis = OriveoMotion.modelControlPageMillis(reduceMotion)
    val layoutDirection = LocalLayoutDirection.current
    
    
    
    
    
    BackHandler(enabled = route != null && !behaviorSubPageOpen) { popRoute() }
    ModelControlsScaffold(
        onClose = onDismiss,
        bottomExtra = {
            
            
            
            AnimatedVisibility(
                visible = showsScopeUpgrade && route == null,
                enter = fadeIn(tween(pageMillis)),
                exit = fadeOut(tween(pageMillis)),
            ) {
                ModelControlScopeUpgradeRow(
                    isConfirmed = scopeUpgradeConfirmed,
                    onPromote = ::promoteToModelDefault,
                )
            }
        },
    ) {
        AnimatedContent(
            targetState = route,
            transitionSpec = {
                
                
                val forward = routeIsForward
                
                
                val direction = if (layoutDirection == LayoutDirection.Rtl) -1 else 1
                val slide = tween<IntOffset>(pageMillis)
                val fade = tween<Float>(pageMillis)
                ContentTransform(
                    targetContentEnter = slideInHorizontally(slide) { w ->
                        direction * if (forward) w else -w
                    } + fadeIn(fade),
                    initialContentExit = slideOutHorizontally(slide) { w ->
                        direction * if (forward) -w else w
                    } + fadeOut(fade),
                    sizeTransform = SizeTransform { _, _ -> tween(pageMillis) },
                )
            },
            label = "model-controls-page",
        ) { current ->
            
            
            key(current) {
                when (current) {
                    null -> {
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(horizontal = 16.dp)
                                .padding(top = 14.dp, bottom = 32.dp),
                            verticalArrangement = Arrangement.spacedBy(24.dp),
                        ) {
                            
                            
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    ProviderBadgeIcon(
                                        kind = provider.kind,
                                        size = 20.dp,
                                        relayKind = provider.relayKind,
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        text = model.name,
                                        style = MaterialTheme.typography.titleSmall,
                                        fontWeight = FontWeight.SemiBold,
                                        color = colors.textPrimary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                                Text(
                                    text = subjectSubtitle(provider, customTransport, context),
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        fontSize = 12.sp, lineHeight = 16.sp,
                                    ),
                                    color = colors.textSecondary,
                                )
                                
                                
                                
                            }

                            readOnlyReasonRes?.let { reasonRes ->
                                Column(
                                    modifier = Modifier.fillMaxWidth().modelControlSurface().padding(16.dp),
                                    verticalArrangement = Arrangement.spacedBy(12.dp),
                                ) {
                                    ModelControlNote(reasonRes, Icons.Outlined.Lock)
                                    
                                    
                                    when (editability) {
                                        ModelControlsEditability.RuntimeIdentityUnavailable ->
                                            when (identityGap.recoveryAction) {
                                                ModelControlsIdentityGap.RecoveryAction.RefetchRuntime -> {
                                                    ModelControlInlineAction(
                                                        title = stringResource(
                                                            if (isRefreshingRuntime) R.string.model_control_fetching
                                                            else R.string.model_control_fetch_again,
                                                        ),
                                                        icon = Icons.Outlined.Refresh,
                                                        onClick = {
                                                            if (isRefreshingRuntime) return@ModelControlInlineAction
                                                            isRefreshingRuntime = true
                                                            runtimeRefreshFailed = false
                                                            scope.launch {
                                                                metadata.refresh()
                                                                val resolved = ModelControlRuntimeIdentityResolver
                                                                    .resolve(provider, model, metadata)
                                                                refreshedIdentity = resolved
                                                                isRefreshingRuntime = false
                                                                runtimeRefreshFailed = resolved == null
                                                            }
                                                        },
                                                    )
                                                    if (runtimeRefreshFailed) {
                                                        
                                                        ModelControlNote(R.string.model_control_refresh_failed)
                                                    }
                                                }
                                                ModelControlsIdentityGap.RecoveryAction.OpenConnectionSettings ->
                                                    ModelControlInlineAction(
                                                        title = stringResource(R.string.model_control_set_protocol),
                                                        icon = Icons.Outlined.Settings,
                                                        onClick = { onDismiss(); onOpenConnectionSettings() },
                                                    )
                                                ModelControlsIdentityGap.RecoveryAction.ChooseAnotherModel ->
                                                    ModelControlInlineAction(
                                                        title = stringResource(
                                                            R.string.model_control_choose_other_model,
                                                        ),
                                                        icon = Icons.AutoMirrored.Outlined.AltRoute,
                                                        onClick = { onDismiss(); onChooseAnotherModel() },
                                                    )
                                            }
                                        ModelControlsEditability.RuntimeReadOnly,
                                        ModelControlsEditability.Writable,
                                        -> Unit
                                    }
                                }
                            }

                            
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                ModelControlWebCard(
                                    status = presentation("web"),
                                    overridden = isCustomActive("web"),
                                    canPersist = editability.canPersist,
                                    availableIntents = webIntents,
                                    selection = web,
                                    hasCustomSchema = hasSafeCustomSchema,
                                    readOnlyReasonRes = readOnlyReasonRes,
                                    upstreamRejected = upstreamRejected("web"),
                                    riskTiers = riskTiers("web"),
                                    hasCandidates = candidatesByCapability["web"]?.isNotEmpty() == true,
                                    onSelect = { next -> persist(next, reasoningIntent) },
                                    onExplain = ::presentExplanation,
                                    onRoute = ::openRoute,
                                )
                                ModelControlReasoningCard(
                                    status = presentation("reasoning"),
                                    overridden = isCustomActive("reasoning"),
                                    canPersist = editability.canPersist,
                                    intents = reasoningIntents,
                                    selectedIntent = reasoningIntent,
                                    hasCustomSchema = hasSafeCustomSchema,
                                    readOnlyReasonRes = readOnlyReasonRes,
                                    upstreamRejected = upstreamRejected("reasoning"),
                                    riskTiers = riskTiers("reasoning"),
                                    hasCandidates = candidatesByCapability["reasoning"]?.isNotEmpty() == true,
                                    onSelect = { intent -> persist(web, intent) },
                                    onExplain = ::presentExplanation,
                                    onRoute = ::openRoute,
                                )
                                ModelControlNavigationRow(
                                    icon = Icons.Outlined.Tune,
                                    title = stringResource(R.string.generation_model_behavior),
                                    
                                    subtitle = stringResource(R.string.model_control_advanced_settings_subtitle),
                                    trailingText = generationOverrideCount
                                        .takeIf { it > 0 }
                                        ?.let { stringResource(R.string.model_control_behavior_adjusted, it) },
                                    
                                    
                                    badge = modelControlBadge(
                                        ModelControlBadgeClassification.advancedSettingsCard(
                                            presentation("generation"),
                                        ),
                                        overridden = isCustomActive("generation"),
                                    ),
                                    onClick = { openRoute(ModelControlsRoute.ModelBehavior) },
                                )
                            }
                        }
                    }
                    is ModelControlsRoute.SupportedModels -> CapabilitySupportedModelsPage(
                        provider = provider,
                        capability = current.capability,
                        candidates = candidates(current.capability),
                        
                        
                        onBack = ::popRoute,
                        onSelect = { candidate ->
                            onSelectModel(provider.id, candidate.id)
                            onDismiss()
                        },
                    )
                    ModelControlsRoute.ModelBehavior -> Column(modifier = Modifier.fillMaxSize()) {
                        
                        
                        
                        
                        val notifyAdvancedSettingsClosed by rememberUpdatedState(onAdvancedSettingsClosed)
                        DisposableEffect(Unit) { onDispose { notifyAdvancedSettingsClosed() } }
                        
                        
                        if (!behaviorSubPageOpen) {
                            ModelControlsPageHeader(
                                title = stringResource(R.string.generation_model_behavior),
                                onBack = ::popRoute,
                            )
                        }
                        
                        
                        
                        
                        val headerEntries = ModelControlCapabilityFooter.entries(
                            ModelControlCapabilityFooter.Input(
                                context = ModelControlCapabilityFooter.Context.BehaviorPageHeader,
                                overridden = isCustomActive("generation"),
                                readOnlyReasonRes = readOnlyReasonRes,
                                isConfigurable = presentation("generation").isConfigurable,
                                statusTextRes = modelControlStatusTextRes(presentation("generation")),
                                upstreamRejected = upstreamRejected("generation"),
                                riskTiers = riskTiers("generation"),
                                showsSupportedModelsAction = modelControlShowsSupportedModelsAction(
                                    presentation("generation"),
                                ),
                                hasSupportedModelCandidates = modelControlShowsSupportedModelsAction(
                                    presentation("generation"),
                                ) && candidates("generation").isNotEmpty(),
                                
                                showsAdvancedSettingsAction = false,
                            ),
                        )
                        
                        
                        
                        GenerationParameterDefaultsSheet(
                            provider = provider,
                            initialModelId = model.id,
                            conversationId = conversationId,
                            
                            
                            modifier = Modifier.weight(1f).padding(bottom = 24.dp),
                            
                            
                            isReadOnly = !editability.canPersist,
                            
                            containerProvidesTitle = true,
                            onSubPageVisibleChange = { behaviorSubPageOpen = it },
                            capabilityHeader = if (headerEntries.isEmpty()) {
                                null
                            } else {
                                {
                                    ModelControlCapabilityFooterView(
                                        capability = "generation",
                                        entries = headerEntries,
                                        onRoute = ::openRoute,
                                    )
                                }
                            },
                            
                            
                            onSelectCandidateModel = { candidate ->
                                onSelectModel(provider.id, candidate.id)
                                onDismiss()
                            },
                        )
                    }
                }
            }
        }
    }
}


@Composable
private fun ModelControlsPageHeader(title: String, onBack: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(colors = modelControlTextButtonColors(), onClick = onBack) {
            Text(stringResource(R.string.back))
        }
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = OriveoTheme.colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}


@Composable
private fun CapabilitySupportedModelsPage(
    provider: Provider,
    capability: String,
    candidates: List<AIModel>,
    onBack: () -> Unit,
    onSelect: (AIModel) -> Unit,
) {
    val colors = OriveoTheme.colors
    val switchHint = stringResource(R.string.model_control_switch_model_hint)
    Column(modifier = Modifier.fillMaxSize()) {
        ModelControlsPageHeader(
            title = stringResource(modelControlCapabilityTitleRes(capability)),
            onBack = onBack,
        )
        
        
        
        
        
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 28.dp),
        ) {
            item(key = "supported_models_note", contentType = SupportedModelsNoteContentType) {
                Box(modifier = Modifier.padding(bottom = 12.dp)) {
                    ModelControlNote(
                        textRes = R.string.model_control_supported_models_header,
                        icon = Icons.Outlined.SwapHoriz,
                        tone = colors.textSecondary,
                    )
                }
            }
            itemsIndexed(
                items = candidates,
                key = { _, candidate -> candidate.id },
                contentType = { _, _ -> SupportedModelsRowContentType },
            ) { index, candidate ->
                val isFirst = index == 0
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .supportedModelsRowSurface(isFirst = isFirst, isLast = index == candidates.lastIndex),
                ) {
                    if (!isFirst) ModelControlHairline(leadingInset = 54)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 52.dp)
                            .clickable { onSelect(candidate) }
                            .semantics(mergeDescendants = true) {
                                role = Role.Button
                                contentDescription = candidate.name
                                stateDescription = switchHint
                            }
                            .padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ProviderBadgeIcon(kind = provider.kind, size = 26.dp, relayKind = provider.relayKind)
                        Spacer(Modifier.width(12.dp))
                        Text(
                            text = candidate.name,
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = stringResource(R.string.model_control_switch_to_model),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.primaryTextSafe,
                        )
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                            contentDescription = null,
                            tint = colors.textSecondary,
                            modifier = Modifier.padding(start = 4.dp).size(14.dp),
                        )
                    }
                }
            }
        }
    }
}

private const val SupportedModelsNoteContentType = "supported_models_note"
private const val SupportedModelsRowContentType = "supported_models_row"
private val SupportedModelsCardRadius = 20.dp


private val SupportedModelsShadowInset = 28.dp


@Composable
private fun Modifier.supportedModelsRowSurface(isFirst: Boolean, isLast: Boolean): Modifier {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val radius = SupportedModelsCardRadius
    val shape = when {
        isFirst && isLast -> RoundedCornerShape(radius)
        isFirst -> RoundedCornerShape(topStart = radius, topEnd = radius, bottomStart = 0.dp, bottomEnd = 0.dp)
        isLast -> RoundedCornerShape(topStart = 0.dp, topEnd = 0.dp, bottomStart = radius, bottomEnd = radius)
        else -> RoundedCornerShape(0.dp)
    }
    val shadowColor = Color.Black.copy(alpha = if (isDark) 0.28f else 0.045f)
    return this
        .then(
            if (isFirst || isLast) {
                Modifier.shadow(
                    elevation = if (isDark) 10.dp else 14.dp,
                    shape = SupportedModelsShadowShape(roundedTop = isFirst, roundedBottom = isLast),
                    clip = false,
                    ambientColor = shadowColor,
                    spotColor = shadowColor,
                )
            } else {
                Modifier
            },
        )
        .background(color = if (isDark) colors.surfaceElevated else colors.surface, shape = shape)
}

private data class SupportedModelsShadowShape(
    val roundedTop: Boolean,
    val roundedBottom: Boolean,
) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val radiusPx = with(density) { SupportedModelsCardRadius.toPx() }
        val insetPx = with(density) { SupportedModelsShadowInset.toPx() }.coerceAtMost(size.height / 2f)
        val corner = CornerRadius(radiusPx, radiusPx)
        val topCorner = if (roundedTop) corner else CornerRadius.Zero
        val bottomCorner = if (roundedBottom) corner else CornerRadius.Zero
        return Outline.Rounded(
            RoundRect(
                left = 0f,
                top = if (roundedTop) 0f else insetPx,
                right = size.width,
                bottom = size.height,
                topLeftCornerRadius = topCorner,
                topRightCornerRadius = topCorner,
                bottomLeftCornerRadius = bottomCorner,
                bottomRightCornerRadius = bottomCorner,
            ),
        )
    }
}


@Composable
private fun ModelControlWebCard(
    status: CapabilityControlPresentation,
    overridden: Boolean,
    canPersist: Boolean,
    availableIntents: List<String>,
    selection: CapabilityWebPreference,
    hasCustomSchema: Boolean,
    @StringRes readOnlyReasonRes: Int?,
    upstreamRejected: Boolean,
    riskTiers: List<String>,
    hasCandidates: Boolean,
    onSelect: (CapabilityWebPreference) -> Unit,
    onExplain: (String, String, ModelControlCapabilityEscape) -> Unit,
    onRoute: (ModelControlsRoute) -> Unit,
) {
    val layout = ModelControlWebLayout.layout(
        status = status,
        availableIntents = availableIntents,
        rawSelection = selection,
        isEditable = canPersist && !overridden,
        hasCustomSchema = hasCustomSchema,
    )
    val title = stringResource(R.string.model_control_web_search)
    ModelControlCard(
        icon = Icons.Outlined.Language,
        title = title,
        badge = modelControlBadge(
            ModelControlBadgeClassification.capabilityCard(status), overridden = overridden,
        ),
        toggle = layout.isOn.takeIf { layout.form == ModelControlWebLayout.Form.Toggle },
        onToggle = if (layout.form == ModelControlWebLayout.Form.Toggle) {
            { enabled ->
                
                
                onSelect(if (enabled) CapabilityWebPreference.Automatic else CapabilityWebPreference.Off)
            }
        } else {
            null
        },
    ) {
        when (layout.form) {
            ModelControlWebLayout.Form.Toggle -> {
                layout.captionRes?.let { ModelControlNote(it) }
                if (layout.timingOptions.isNotEmpty()) {
                    ModelControlIntentPicker(
                        options = layout.timingOptions,
                        selection = layout.timingSelection,
                    ) { id -> onSelect(ModelControlWebLayout.preferenceFor(id)) }
                }
            }
            ModelControlWebLayout.Form.StatusRow -> ModelControlStatusRowFor(
                capability = "web",
                statusTextRes = layout.statusTextRes,
                explanationRes = layout.explanationRes,
                escape = layout.escape,
                onExplain = onExplain,
            )
        }
        ModelControlCapabilityFooterView(
            capability = "web",
            entries = ModelControlCapabilityFooter.entries(
                ModelControlCapabilityFooter.Input(
                    context = ModelControlCapabilityFooter.Context.PanelCard,
                    overridden = overridden,
                    readOnlyReasonRes = readOnlyReasonRes,
                    isConfigurable = status.isConfigurable,
                    statusTextRes = modelControlStatusTextRes(status),
                    upstreamRejected = upstreamRejected,
                    riskTiers = riskTiers,
                    showsSupportedModelsAction = modelControlShowsSupportedModelsAction(status),
                    hasSupportedModelCandidates = modelControlShowsSupportedModelsAction(status) && hasCandidates,
                    showsAdvancedSettingsAction = overridden,
                    
                    statusRowEscape = if (layout.form == ModelControlWebLayout.Form.StatusRow) {
                        layout.escape
                    } else {
                        ModelControlCapabilityEscape.None
                    },
                ),
            ),
            onRoute = onRoute,
        )
    }
}

@Composable
private fun ModelControlReasoningCard(
    status: CapabilityControlPresentation,
    overridden: Boolean,
    canPersist: Boolean,
    intents: List<String>,
    selectedIntent: String?,
    hasCustomSchema: Boolean,
    @StringRes readOnlyReasonRes: Int?,
    upstreamRejected: Boolean,
    riskTiers: List<String>,
    hasCandidates: Boolean,
    onSelect: (String?) -> Unit,
    onExplain: (String, String, ModelControlCapabilityEscape) -> Unit,
    onRoute: (ModelControlsRoute) -> Unit,
) {
    val layout = ModelControlReasoningLayout.layout(
        status = status,
        intents = intents,
        selectedIntent = selectedIntent,
        isEditable = canPersist && !overridden,
        hasCustomSchema = hasCustomSchema,
    )
    ModelControlCard(
        icon = Icons.Outlined.Psychology,
        title = stringResource(R.string.model_control_thinking),
        badge = modelControlBadge(
            ModelControlBadgeClassification.capabilityCard(status), overridden = overridden,
        ),
        toggle = null,
        onToggle = null,
    ) {
        when (layout.form) {
            ModelControlReasoningLayout.Form.PillRow -> {
                ModelControlIntentPicker(options = layout.options, selection = layout.selection) { intent ->
                    
                    onSelect(intent.takeIf { it != ModelControlReasoningLayout.AUTOMATIC_INTENT })
                }
                
                layout.selectedAnnotationRes?.let { ModelControlNote(it) }
            }
            ModelControlReasoningLayout.Form.StatusRow -> ModelControlStatusRowFor(
                capability = "reasoning",
                statusTextRes = layout.statusTextRes,
                explanationRes = layout.explanationRes,
                escape = layout.escape,
                onExplain = onExplain,
            )
        }
        layout.footnoteRes?.let { ModelControlNote(it) }
        ModelControlCapabilityFooterView(
            capability = "reasoning",
            entries = ModelControlCapabilityFooter.entries(
                ModelControlCapabilityFooter.Input(
                    context = ModelControlCapabilityFooter.Context.PanelCard,
                    overridden = overridden,
                    readOnlyReasonRes = readOnlyReasonRes,
                    isConfigurable = status.isConfigurable,
                    statusTextRes = modelControlStatusTextRes(status),
                    upstreamRejected = upstreamRejected,
                    riskTiers = riskTiers,
                    showsSupportedModelsAction = modelControlShowsSupportedModelsAction(status),
                    hasSupportedModelCandidates = modelControlShowsSupportedModelsAction(status) && hasCandidates,
                    showsAdvancedSettingsAction = overridden,
                    statusRowEscape = if (layout.form == ModelControlReasoningLayout.Form.StatusRow) {
                        layout.escape
                    } else {
                        ModelControlCapabilityEscape.None
                    },
                ),
            ),
            onRoute = onRoute,
        )
    }
}


@Composable
private fun ModelControlStatusRowFor(
    capability: String,
    @StringRes statusTextRes: Int?,
    @StringRes explanationRes: Int?,
    escape: ModelControlCapabilityEscape,
    onExplain: (String, String, ModelControlCapabilityEscape) -> Unit,
) {
    if (statusTextRes == null) return
    val explanation = explanationRes?.let { stringResource(it) }
    ModelControlStatusRow(
        text = stringResource(statusTextRes),
        onClick = explanation?.let { message -> { onExplain(capability, message, escape) } },
    )
}


@Composable
private fun ModelControlCapabilityFooterView(
    capability: String,
    entries: List<ModelControlCapabilityFooter.Entry>,
    onRoute: (ModelControlsRoute) -> Unit,
) {
    if (entries.isEmpty()) return
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        entries.forEach { entry ->
            when (entry) {
                is ModelControlCapabilityFooter.Entry.Note -> ModelControlNote(
                    textRes = entry.textRes,
                    icon = entry.icon?.let(::modelControlNoteIcon),
                    tone = when (entry.tone) {
                        
                        ModelControlCapabilityFooter.Tone.Tertiary -> colors.textSecondary
                        ModelControlCapabilityFooter.Tone.Warning -> colors.warningText
                    },
                )
                ModelControlCapabilityFooter.Entry.SupportedModelsLink -> ModelControlInlineAction(
                    title = stringResource(R.string.model_control_view_supported_models),
                    icon = Icons.Outlined.SwapHoriz,
                    onClick = { onRoute(ModelControlsRoute.SupportedModels(capability)) },
                )
                ModelControlCapabilityFooter.Entry.AdvancedSettingsLink -> ModelControlInlineAction(
                    title = stringResource(R.string.model_control_go_to_advanced_settings),
                    icon = Icons.Outlined.DataObject,
                    tint = colors.textSecondary,
                    onClick = { onRoute(ModelControlsRoute.ModelBehavior) },
                )
            }
        }
    }
}

private fun modelControlNoteIcon(icon: ModelControlCapabilityFooter.NoteIcon): ImageVector = when (icon) {
    ModelControlCapabilityFooter.NoteIcon.Lock -> Icons.Outlined.Lock
    ModelControlCapabilityFooter.NoteIcon.CustomFields -> Icons.Outlined.DataObject
    ModelControlCapabilityFooter.NoteIcon.UpstreamRejected -> Icons.Outlined.Block
    ModelControlCapabilityFooter.NoteIcon.Privacy -> Icons.Filled.PanTool
    ModelControlCapabilityFooter.NoteIcon.Cost -> Icons.Filled.CreditCard
}


@Composable
private fun modelControlBadge(
    classification: ModelControlBadgeClassification,
    overridden: Boolean,
): Pair<ModelControlStatusTone, String>? {
    if (overridden) {
        return ModelControlStatusTone.Manual to stringResource(R.string.model_control_state_custom)
    }
    return when (classification) {
        ModelControlBadgeClassification.None -> null
        ModelControlBadgeClassification.Manual ->
            ModelControlStatusTone.Manual to stringResource(R.string.model_control_state_manual)
        ModelControlBadgeClassification.NotReady ->
            ModelControlStatusTone.Manual to stringResource(R.string.model_control_state_not_ready)
        ModelControlBadgeClassification.Unavailable ->
            ModelControlStatusTone.Unavailable to stringResource(R.string.model_control_state_unavailable)
    }
}

private fun subjectSubtitle(
    provider: Provider,
    transport: String?,
    context: android.content.Context,
): String {
    val parts = mutableListOf(provider.displayName)
    if (!transport.isNullOrBlank()) {
        parts += CapabilityTransportLabel.display(transport)
            ?: context.getString(R.string.relay_section_protocol)
    }
    return parts.joinToString(" · ")
}


internal val modelControlOwnerOrder: List<String> = listOf("web", "reasoning", "generation")


