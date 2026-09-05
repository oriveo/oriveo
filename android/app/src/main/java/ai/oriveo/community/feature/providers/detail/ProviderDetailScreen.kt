package ai.oriveo.community.feature.providers.detail

import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAvailability
import ai.oriveo.community.feature.providers.SubscriptionAuthorizationViewModel
import ai.oriveo.community.feature.providers.grok.GrokSubscriptionAuthorizationSheet
import ai.oriveo.community.feature.providers.openai.OpenAISubscriptionAuthorizationSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Tune
import ai.oriveo.community.feature.providers.relay.RelayAdvancedSettingsSheet
import ai.oriveo.community.feature.providers.relay.RelayEditFailureDetails
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.model.effectiveStatusKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.navigation.ManualModelEntryContext

import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ModelPricingFormatter
import ai.oriveo.community.feature.providers.ProviderEndpointSelector
import ai.oriveo.community.feature.providers.localizedProviderEndpointLabel
import ai.oriveo.community.feature.providers.relay.RelayConnectionTestResult
import ai.oriveo.community.feature.providers.relay.relayKindMeta
import ai.oriveo.community.ui.component.HeroModelCapabilityStrip
import ai.oriveo.community.ui.component.ModelVendorIcon
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSectionHeader
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.OriveoTextButton
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.StatusPill
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.component.localizedProviderError
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.util.formatRelativeTime
import kotlinx.coroutines.delay
import org.koin.androidx.compose.koinViewModel


private data class RemovalBannerState(
    val modelName: String,
    val onUndo: () -> Unit,
)


private fun LazyListScope.detailSection(
    key: String,
    content: @Composable () -> Unit,
) {
    item(key = key) {
        Box(modifier = Modifier.padding(bottom = OriveoTheme.spacing.lg)) {
            content()
        }
    }
}


@Composable
private fun CapabilityObservationRevisionScope(
    content: @Composable (Long) -> Unit,
) {
    val revision by CapabilityEvidenceObservationBridge.revision.collectAsStateWithLifecycle()
    content(revision)
}


@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun ProviderDetailScreen(
    onBack: () -> Unit,
    onStartChat: (providerID: String, modelID: String) -> Unit = { _, _ -> },
    manualEntryContext: ManualModelEntryContext = ManualModelEntryContext.ProviderDetail,
    onNavigateToManualEntry: (providerID: String) -> Unit = {},
    onNavigateToAdvancedSettings: (providerID: String) -> Unit = {},
    viewModel: ProviderDetailViewModel = koinViewModel(),
    authorizationViewModel: SubscriptionAuthorizationViewModel = koinViewModel(),
) {
    val provider by viewModel.provider.collectAsStateWithLifecycle()
    val catalogViewState by viewModel.catalogViewState.collectAsStateWithLifecycle()
    val catalogGroups by viewModel.catalogGroups.collectAsStateWithLifecycle()
    val resolvedCatalog by viewModel.resolvedCatalog.collectAsStateWithLifecycle()
    val managedWalletState by viewModel.managedWalletState.collectAsStateWithLifecycle()
    val managedWeeklyQuotaOffer by viewModel.managedWeeklyQuotaOffer.collectAsStateWithLifecycle()
    val colors = OriveoTheme.colors
    val context = LocalContext.current

    
    var highlightedModelID: String? by remember { mutableStateOf(null) }
    var showConnectionSettingsSheet by remember { mutableStateOf(false) }
    var showGenerationParameters by remember { mutableStateOf(false) }
    var renameProvider: Provider? by remember { mutableStateOf(null) }

    
    var removalBanner: RemovalBannerState? by remember { mutableStateOf(null) }

    
    var dismissedHealthBanner by remember { mutableStateOf(false) }

    
    val vibrator = remember {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(VibratorManager::class.java)
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }
    }

    fun triggerHaptic() {
        vibrator?.vibrate(VibrationEffect.createOneShot(20, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    
    LaunchedEffect(removalBanner) {
        if (removalBanner != null) {
            delay(4000)
            removalBanner = null
        }
    }

    
    LaunchedEffect(highlightedModelID) {
        if (highlightedModelID != null) {
            delay(1200)
            highlightedModelID = null
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()

        Scaffold(
            containerColor = Color.Transparent,
        ) { padding ->
            val currentProvider = provider
            if (currentProvider == null) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator()
                }
            } else {
                val relayCatalogState = if (currentProvider.kind == ProviderKind.Relay) {
                    viewModel.relayCatalogUiState(currentProvider)
                } else {
                    null
                }
                
                
                val enabledSortedModels = remember(currentProvider.models) {
                    sortedEnabledModels(currentProvider)
                }
                val enabledServerGroups = remember(currentProvider.models) {
                    detailEnabledModelGroups(currentProvider)
                }
                var enabledServerExpandedGroups by remember(currentProvider.id) {
                    mutableStateOf(emptySet<String>())
                }
                CapabilityObservationRevisionScope { capabilityObservationRevision ->
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(padding),
                        contentPadding = PaddingValues(
                            start = OriveoTheme.layout.screenH,
                            end = OriveoTheme.layout.screenH,
                            top = OriveoTheme.spacing.sm,
                            
                            bottom = OriveoTheme.spacing.lg,
                        ),
                        
                        
                    ) {
                        
                        detailSection(key = "back_button") {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(32.dp)
                                        .clip(CircleShape)
                                        .clickable(onClick = onBack),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                        contentDescription = stringResource(R.string.back),
                                        modifier = Modifier.size(18.dp),
                                        tint = colors.textPrimary,
                                    )
                                }
                                Spacer(modifier = Modifier.weight(1f))
                            }
                        }

                        
                        
                        
                        
                        if (viewModel.isSubscriptionProvider(currentProvider)) {
                            if (currentProvider.kind == ProviderKind.OpenAI) {
                                (viewModel.openAISubscriptionAvailability as? OpenAISubscriptionAvailability.Disabled)
                                    ?.let { disabled ->
                                        detailSection(key = "openai_subscription_disabled_notice") {
                                            SubscriptionDisabledNotice(
                                                notice = disabled.notice,
                                                fallbackRes = R.string.openai_subscription_error_unavailable,
                                            )
                                        }
                                    }
                            } else {
                                (viewModel.grokSubscriptionAvailability as? GrokSubscriptionAvailability.Disabled)
                                    ?.let { disabled ->
                                        detailSection(key = "grok_subscription_disabled_notice") {
                                            SubscriptionDisabledNotice(
                                                notice = disabled.notice,
                                                fallbackRes = R.string.grok_subscription_error_unavailable,
                                            )
                                        }
                                    }
                            }
                        }

                        
                        if (currentProvider.effectiveStatusKind.isWarning && !dismissedHealthBanner) {
                            detailSection(key = "provider_connection_issue_recovery") {
                                val canEditEndpoint = viewModel.canEditEndpoint(currentProvider)
                                ProviderConnectionIssueRecoveryCard(
                                    provider = currentProvider,
                                    onUpdateAPIKey = { viewModel.startEditApiKey() },
                                    onRetryConnection = { viewModel.resync() },
                                    onDismiss = { dismissedHealthBanner = true },
                                    onCheckEndpoint = if (canEditEndpoint) {
                                        { viewModel.startEditEndpoint() }
                                    } else {
                                        null
                                    },
                                    endpointTitleRes = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
                                        .endpointTitle(currentProvider.kind),
                                )
                            }
                        }

                        detailSection(key = "brand_hero_card") {
                            val enabledModelCount = providerSummaryAvailableModelCount(
                                provider = currentProvider,
                                resolvedCatalog = resolvedCatalog,
                            )
                            ProviderDetailBrandHeroCard(
                                provider = currentProvider,
                                enabledModelCount = enabledModelCount,
                                onStartChat = {
                                    currentProvider.defaultModel?.id?.let { modelId ->
                                        onStartChat(currentProvider.id, modelId)
                                    }
                                },
                                onResync = { viewModel.resync() },
                                onEditApiKey = { viewModel.startEditApiKey() },
                                onRemoveResidualApiKey = {
                                    if (currentProvider.kind == ProviderKind.Relay &&
                                        !currentProvider.relayRequested.requiresCredential &&
                                        viewModel.hasStoredKey(currentProvider)
                                    ) {
                                        viewModel.removeApiKey()
                                    }
                                },
                                onEditName = if (viewModel.canRenameProvider(currentProvider)) {
                                    { renameProvider = currentProvider }
                                } else {
                                    null
                                },
                                isResyncing = viewModel.isResyncing,
                            )
                        }


                        
                        if (currentProvider.kind in ai.oriveo.community.core.provider.BALANCE_CAPABLE_KINDS) {
                            detailSection(key = "provider_balance_card") {
                                val balanceState by viewModel.balanceState.collectAsStateWithLifecycle()
                                LaunchedEffect(currentProvider.id) {
                                    viewModel.ensureBalanceLoaded()
                                }
                                ProviderBalanceCard(
                                    state = balanceState,
                                    providerKind = currentProvider.kind,
                                    onRefresh = { viewModel.refreshBalance() },
                                )
                            }
                        }

                        
                        
                        providerDetailEnabledModels(
                            provider = currentProvider,
                            titleRes = viewModel.enabledModelsTitle(currentProvider),
                            capabilityObservationRevision = capabilityObservationRevision,
                            sortedModels = enabledSortedModels,
                            serverGroups = enabledServerGroups,
                            serverExpandedGroupIds = enabledServerExpandedGroups,
                            onToggleServerGroup = { groupId ->
                                enabledServerExpandedGroups = if (groupId in enabledServerExpandedGroups) {
                                    enabledServerExpandedGroups - groupId
                                } else {
                                    enabledServerExpandedGroups + groupId
                                }
                            },
                            highlightedModelID = highlightedModelID,
                            onToggleModel = { model ->
                                val willDisable = currentProvider.models.any { it.id == model.id }
                                viewModel.toggleModelEnabled(model)
                                if (willDisable && currentProvider.models.size > 1) {
                                    removalBanner = RemovalBannerState(
                                        modelName = model.name,
                                        onUndo = {
                                            viewModel.toggleModelEnabled(model)
                                            removalBanner = null
                                            triggerHaptic()
                                        },
                                    )
                                }
                            },
                            onSetDefault = { model -> viewModel.setDefaultModel(model) },
                            onStartChat = { model ->
                                onStartChat(currentProvider.id, model.id)
                            },
                            confirmedRelayCatalogModels = when (relayCatalogState) {
                                ProviderDetailViewModel.RelayCatalogUiState.Available ->
                                    currentProvider.catalogModels
                                ProviderDetailViewModel.RelayCatalogUiState.Empty -> emptyList()
                                else -> null
                            },
                        )

                        
                        val groups = catalogGroups
                        if (currentProvider.kind == ProviderKind.Relay &&
                            (relayCatalogState == ProviderDetailViewModel.RelayCatalogUiState.Loading ||
                                relayCatalogState == ProviderDetailViewModel.RelayCatalogUiState.Failed)
                        ) {
                            detailSection(key = "relay_catalog_header") {
                                ProviderDetailSectionHeader(title = stringResource(R.string.model_library))
                            }
                            detailSection(key = "relay_catalog_status") {
                                OriveoCard {
                                    if (relayCatalogState == ProviderDetailViewModel.RelayCatalogUiState.Loading) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                                        ) {
                                            CircularProgressIndicator(modifier = Modifier.size(18.dp))
                                            Text(
                                                text = stringResource(R.string.relay_catalog_loading),
                                                style = OriveoTheme.typography.body,
                                                color = colors.textSecondary,
                                            )
                                        }
                                    } else {
                                        Column(
                                            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                                        ) {
                                            Text(
                                                text = stringResource(R.string.relay_catalog_failed),
                                                style = OriveoTheme.typography.title3,
                                                color = colors.textPrimary,
                                            )
                                            Text(
                                                text = stringResource(R.string.relay_catalog_failed_hint),
                                                style = OriveoTheme.typography.body,
                                                color = colors.textSecondary,
                                            )
                                            TextButton(onClick = { viewModel.retryRelayCatalog() }) {
                                                Text(stringResource(R.string.retry))
                                            }
                                            TextButton(
                                                onClick = { onNavigateToManualEntry(currentProvider.id) },
                                            ) {
                                                Text(stringResource(R.string.provider_detail_add_model_manually))
                                            }
                                        }
                                    }
                                }
                            }
                        } else if (groups != null) {
                            detailSection(key = "catalog_header") {
                                Column(
                                    verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                                ) {
                                    ProviderDetailSectionHeader(title = stringResource(R.string.model_library))
                                    SearchField(
                                        value = viewModel.modelSearchQuery,
                                        onValueChange = viewModel::updateModelSearchQuery,
                                    )
                                }
                            }

                            
                            when (catalogViewState) {
                                ProviderDetailViewModel.CatalogViewState.Offline -> {
                                    detailSection(key = "catalog_offline") {
                                        OriveoCard {
                                            Column(
                                                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                                            ) {
                                                Text(
                                                    text = stringResource(R.string.catalog_state_offline_title),
                                                    style = OriveoTheme.typography.title3,
                                                    color = colors.textPrimary,
                                                )
                                                Text(
                                                    text = stringResource(R.string.catalog_state_offline_subtitle),
                                                    style = OriveoTheme.typography.body,
                                                    color = colors.textSecondary,
                                                )
                                                androidx.compose.material3.TextButton(
                                                    onClick = { viewModel.resync() },
                                                ) {
                                                    Text(stringResource(R.string.catalog_state_offline_retry))
                                                }
                                            }
                                        }
                                    }
                                }

                                ProviderDetailViewModel.CatalogViewState.ManualRetainedOnly -> {
                                    detailSection(key = "catalog_manual_retained_banner") {
                                        OriveoCard {
                                            Column(
                                                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
                                            ) {
                                                Text(
                                                    text = stringResource(R.string.catalog_state_manual_retained_header),
                                                    style = OriveoTheme.typography.title3,
                                                    color = colors.textPrimary,
                                                )
                                                Text(
                                                    text = stringResource(R.string.catalog_state_manual_retained_subtitle),
                                                    style = OriveoTheme.typography.caption,
                                                    color = colors.textSecondary,
                                                )
                                            }
                                        }
                                    }
                                }

                                ProviderDetailViewModel.CatalogViewState.UsingCachedMetadata -> {
                                    detailSection(key = "catalog_using_cached_banner") {
                                        OriveoCard {
                                            Text(
                                                text = stringResource(R.string.catalog_state_using_cached_banner),
                                                style = OriveoTheme.typography.caption,
                                                color = colors.textSecondary,
                                            )
                                        }
                                    }
                                }

                                ProviderDetailViewModel.CatalogViewState.Normal -> Unit
                            }

                            if (groups.isEmpty() &&
                                (catalogViewState == ProviderDetailViewModel.CatalogViewState.Normal ||
                                    catalogViewState == ProviderDetailViewModel.CatalogViewState.UsingCachedMetadata)
                            ) {
                                detailSection(key = "catalog_empty") {
                                    OriveoCard {
                                        Text(
                                            text = stringResource(R.string.no_matching_models),
                                            style = OriveoTheme.typography.body,
                                            color = colors.textSecondary,
                                        )
                                    }
                                }
                            } else if (groups.isNotEmpty()) {
                                
                                
                                
                                
                                
                                
                                
                                providerCatalogGroups(
                                    provider = currentProvider,
                                    groups = groups,
                                    searchQuery = viewModel.modelSearchQuery,
                                    expandedGroups = viewModel.expandedGroups,
                                    onToggleGroup = { groupId -> viewModel.toggleGroup(groupId) },
                                    onEnableModel = { model ->
                                        viewModel.toggleModelEnabled(model)
                                        highlightedModelID = model.id
                                        triggerHaptic()
                                    },
                                    capabilityObservationRevision = capabilityObservationRevision,
                                )
                                item(key = "catalog_groups_bottom_spacer") {
                                    Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                                }
                            }
                        }

                        if (viewModel.canAddManualModel(currentProvider)) {
                            detailSection(key = "add_manual_model") {
                                val dashedBorderColor = colors.borderStrong
                                val dashedRadius = OriveoTheme.radius.md
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(52.dp)
                                        .clip(RoundedCornerShape(dashedRadius))
                                        .drawBehind {
                                            drawRoundRect(
                                                color = dashedBorderColor,
                                                cornerRadius = CornerRadius(dashedRadius.toPx()),
                                                style = Stroke(
                                                    width = 1.dp.toPx(),
                                                    pathEffect = PathEffect.dashPathEffect(
                                                        floatArrayOf(6.dp.toPx(), 6.dp.toPx()),
                                                    ),
                                                ),
                                            )
                                        }
                                        .clickable { onNavigateToManualEntry(currentProvider.id) },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = if (manualEntryContext == ManualModelEntryContext.Onboarding) {
                                            stringResource(R.string.provider_detail_add_model_finish_setup)
                                        } else {
                                            stringResource(R.string.provider_detail_add_model_manually)
                                        },
                                        style = OriveoTheme.typography.body,
                                        color = colors.textSecondary,
                                    )
                                }
                            }
                        }

                        detailSection(key = "settings_card") {
                            val canEditEndpoint = viewModel.canEditEndpoint(currentProvider)
                            val canAccessAdvancedSettings = viewModel.canAccessAdvancedSettings(currentProvider)
                            val canDeleteProvider = viewModel.canDeleteProvider(currentProvider)
                            
                            
                            Column(
                                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
                            ) {
                                ProviderDetailSectionHeader(title = stringResource(R.string.settings_title))
                                ProviderDetailSettingsCard(
                                    provider = currentProvider,
                                    onEditEndpoint = if (canEditEndpoint) {
                                        { viewModel.startEditEndpoint() }
                                    } else {
                                        null
                                    },
                                    onAdvancedSettings = if (canAccessAdvancedSettings) {
                                        {
                                            onNavigateToAdvancedSettings(currentProvider.id)
                                            showConnectionSettingsSheet = true
                                        }
                                    } else {
                                        null
                                    },
                                    
                                    
                                    
                                    
                                    onGenerationParameters = { showGenerationParameters = true },
                                    onDeleteProvider = if (canDeleteProvider) {
                                        { viewModel.showDeleteConfirm = true }
                                    } else {
                                        null
                                    },
                                )
                            }
                        }

                    }
                }
            }
        }

        if (showGenerationParameters) {
            ModalBottomSheet(
                onDismissRequest = { showGenerationParameters = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            ) {
                provider?.let { target ->
                    GenerationParameterDefaultsSheet(
                        provider = target,
                    )
                }
            }
        }

        
        AnimatedVisibility(
            visible = removalBanner != null,
            enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
            exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(tween(220)),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            removalBanner?.let { banner ->
                RemovalBanner(
                    modelName = banner.modelName,
                    onUndo = banner.onUndo,
                    modifier = Modifier
                        .padding(horizontal = OriveoTheme.layout.screenH)
                        .padding(bottom = OriveoTheme.spacing.lg),
                )
            }
        }
    } // Box

    if (viewModel.showDeleteConfirm && provider?.let(viewModel::canDeleteProvider) == true) {
        AlertDialog(
            onDismissRequest = { viewModel.showDeleteConfirm = false },
            title = {
                Text(
                    stringResource(
                        if (provider?.kind == ProviderKind.Relay) {
                            R.string.relay_delete_provider_title
                        } else {
                            R.string.delete_provider
                        },
                        provider?.displayName.orEmpty(),
                    ),
                )
            },
            text = {
                Text(
                    text = stringResource(
                        if (provider?.kind == ProviderKind.Relay) {
                            R.string.relay_delete_provider_confirm
                        } else {
                            R.string.delete_provider_confirm
                        },
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.showDeleteConfirm = false
                        viewModel.deleteProvider(onDeleted = onBack)
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                ) {
                    Text(stringResource(R.string.delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.showDeleteConfirm = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    
    if (viewModel.showGrokReauthorization) {
        val availability = viewModel.grokSubscriptionAvailability
        val config = (availability as? GrokSubscriptionAvailability.Available)?.config
        if (config == null) {
            
            viewModel.showGrokReauthorization = false
        } else {
            val grokSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            ModalBottomSheet(
                onDismissRequest = {
                    authorizationViewModel.grok.cancel()
                    viewModel.showGrokReauthorization = false
                },
                sheetState = grokSheetState,
                dragHandle = { OriveoSheetDragHandle() },
            ) {
                GrokSubscriptionAuthorizationSheet(
                    config = config,
                    model = authorizationViewModel.grok,
                    onAuthorized = { tokens -> viewModel.completeGrokReauthorization(tokens) },
                    
                    
                    onDismiss = {
                        authorizationViewModel.grok.cancel()
                        viewModel.showGrokReauthorization = false
                    },
                )
            }
        }
    }

    if (viewModel.showOpenAIReauthorization) {
        val availability = viewModel.openAISubscriptionAvailability
        val config = (availability as? OpenAISubscriptionAvailability.Available)?.config
        if (config == null) {
            
            viewModel.showOpenAIReauthorization = false
        } else {
            val openAISheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            ModalBottomSheet(
                onDismissRequest = {
                    authorizationViewModel.openAI.cancel()
                    viewModel.showOpenAIReauthorization = false
                },
                sheetState = openAISheetState,
                dragHandle = { OriveoSheetDragHandle() },
            ) {
                OpenAISubscriptionAuthorizationSheet(
                    config = config,
                    model = authorizationViewModel.openAI,
                    onAuthorized = { tokens -> viewModel.completeOpenAIReauthorization(tokens) },
                    
                    
                    onDismiss = {
                        authorizationViewModel.openAI.cancel()
                        viewModel.showOpenAIReauthorization = false
                    },
                )
            }
        }
    }

    if (viewModel.showApiKeyEditor && provider?.let(viewModel::canEditApiKey) == true) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { viewModel.showApiKeyEditor = false },
            sheetState = sheetState,
            dragHandle = { OriveoSheetDragHandle() },
        ) {
            Column(modifier = Modifier.padding(OriveoTheme.spacing.lg)) {
                Text(
                    text = stringResource(R.string.change_api_key),
                    style = OriveoTheme.typography.title2,
                )
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                androidx.compose.material3.OutlinedTextField(
                    value = viewModel.editingApiKey,
                    onValueChange = { viewModel.editingApiKey = it },
                    label = { Text(stringResource(R.string.api_key)) },
                    placeholder = {
                        Text(
                            provider?.kind
                                ?.let { kind ->
                                    ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver
                                        .current()
                                        .apiKeyPlaceholder(kind)
                                }
                                ?: "",
                        )
                    },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !viewModel.isUpdatingApiKey,
                )
                val apiKeyError = viewModel.apiKeyEditErrorRes?.let { stringResource(it) }
                    ?: viewModel.apiKeyEditError
                if (!apiKeyError.isNullOrBlank()) {
                    Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
                    Text(
                        text = apiKeyError,
                        style = OriveoTheme.typography.footnote,
                        color = colors.danger,
                    )
                }
                viewModel.relayConnectionTestResult
                    ?.takeUnless { it.isSuccess }
                    ?.failurePresentation
                    ?.let { presentation ->
                        Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
                        OriveoCard {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                RelayEditFailureDetails(presentation)
                            }
                        }
                    }
                if (provider?.kind == ProviderKind.Relay) {
                    Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
                    Text(
                        text = stringResource(
                            if (viewModel.isUpdatingApiKey) {
                                R.string.provider_api_key_verifying
                            } else {
                                R.string.provider_api_key_resync_note
                            },
                        ),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                    )
                }
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                OriveoPrimaryButton(
                    text = stringResource(R.string.save),
                    onClick = { viewModel.saveApiKey() },
                    enabled = viewModel.editingApiKey.isNotBlank(),
                    loading = viewModel.isUpdatingApiKey,
                )
                
                
                if (provider?.let(viewModel::hasStoredKey) == true) {
                    TextButton(
                        onClick = { viewModel.removeApiKey() },
                        enabled = !viewModel.isUpdatingApiKey,
                    ) {
                        Text(
                            text = stringResource(R.string.relay_remove_api_key),
                            color = colors.danger,
                        )
                    }
                }
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.xxl))
            }
        }
    }

    if (viewModel.showEndpointEditor && provider?.let(viewModel::canEditEndpoint) == true) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        val currentEndpoint = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
            .resolveRegionOption(provider!!.kind, provider!!.baseUrlText)
        ModalBottomSheet(
            onDismissRequest = { viewModel.showEndpointEditor = false },
            sheetState = sheetState,
            dragHandle = { OriveoSheetDragHandle() },
        ) {
            Column(modifier = Modifier.padding(OriveoTheme.spacing.lg)) {
                Text(
                    text = stringResource(ai.oriveo.community.feature.providers.setup.ProviderSetupCopy.endpointTitle(provider!!.kind)),
                    style = OriveoTheme.typography.title2,
                )
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                OriveoCard {
                    
                    Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs)) {
                        Text(
                            text = provider!!.displayName,
                            style = OriveoTheme.typography.title3,
                            color = colors.textPrimary,
                        )
                        Text(
                            text = stringResource(
                                R.string.current_value,
                                currentEndpoint?.let {
                                    localizedProviderEndpointLabel(provider!!.kind, it)
                                } ?: (provider!!.baseUrlText ?: provider!!.displayName),
                            ),
                            style = OriveoTheme.typography.caption,
                            color = colors.textSecondary,
                        )
                        (currentEndpoint?.baseURL ?: provider!!.baseUrlText)?.let { baseUrl ->
                            Text(
                                text = baseUrl.removePrefix("https://").removePrefix("http://"),
                                style = OriveoTheme.typography.caption,
                                color = colors.textTertiary,
                            )
                        }
                    }
                }
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                ProviderEndpointSelector(
                    kind = provider!!.kind,
                    selectedOptionId = viewModel.selectedEndpointId,
                    onSelect = { viewModel.selectEndpoint(it.id) },
                    enabled = !viewModel.isUpdatingEndpoint,
                )
                val endpointError = viewModel.endpointEditErrorRes?.let { stringResource(it) }
                    ?: viewModel.endpointEditError
                if (!endpointError.isNullOrBlank()) {
                    Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))
                    Text(
                        text = endpointError,
                        style = OriveoTheme.typography.footnote,
                        color = colors.danger,
                    )
                }
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                OriveoPrimaryButton(
                    text = stringResource(R.string.save),
                    onClick = { viewModel.saveEndpoint() },
                    enabled = viewModel.selectedEndpointId.isNotBlank(),
                    loading = viewModel.isUpdatingEndpoint,
                )
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.xxl))
            }
        }
    }

    if (showConnectionSettingsSheet && provider?.let(viewModel::canAccessAdvancedSettings) == true) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { showConnectionSettingsSheet = false },
            sheetState = sheetState,
            dragHandle = { OriveoSheetDragHandle() },
        ) {
            ProviderDetailConnectionSettingsSheet(
                provider = provider!!,
                viewModel = viewModel,
                onDismiss = { showConnectionSettingsSheet = false },
            )
        }
    }

    
    renameProvider?.let { targetProvider ->
        RenameProviderDialog(
            provider = targetProvider,
            onDismiss = { renameProvider = null },
            onSave = { newName ->
                viewModel.renameProvider(targetProvider, newName)
                renameProvider = null
            },
        )
    }
}


@Composable
private fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.md))
            .background(colors.surface)
            .border(OriveoBorderWidth.standard, colors.border, RoundedCornerShape(OriveoTheme.radius.md))
            .padding(horizontal = spacing.md, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Filled.Search,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.textTertiary,
        )
        Spacer(modifier = Modifier.width(spacing.sm))
        androidx.compose.foundation.text.BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = OriveoTheme.typography.body.copy(color = colors.textPrimary),
            modifier = Modifier.weight(1f),
            decorationBox = { innerTextField ->
                Box {
                    if (value.isEmpty()) {
                        Text(
                            text = stringResource(R.string.search_models),
                            style = OriveoTheme.typography.body,
                            color = colors.textTertiary,
                        )
                    }
                    innerTextField()
                }
            },
        )
    }
}


@Composable
private fun RemovalBanner(
    modelName: String,
    onUndo: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing

    Row(
        modifier = modifier
            .fillMaxWidth()
            .shadow(18.dp, RoundedCornerShape(OriveoTheme.radius.md))
            .clip(RoundedCornerShape(OriveoTheme.radius.md))
            .background(colors.surfaceElevated)
            .border(OriveoBorderWidth.standard, colors.borderStrong, RoundedCornerShape(OriveoTheme.radius.md))
            .padding(horizontal = spacing.lg, vertical = spacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spacing.md),
    ) {
        Icon(
            imageVector = Icons.Filled.RemoveCircle,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.warning,
        )
        Text(
            text = stringResource(R.string.provider_detail_removed_model, modelName),
            style = OriveoTheme.typography.caption,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        OriveoTextButton(
            text = stringResource(R.string.undo),
            onClick = onUndo,
        )
    }
}

@Composable
private fun RenameProviderDialog(
    provider: Provider,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var draft by remember(provider.id, provider.displayName) {
        mutableStateOf(provider.displayName)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.rename)) },
        text = {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                label = { Text(stringResource(R.string.relay_field_name)) },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(draft) },
                enabled = draft.trim().isNotEmpty(),
            ) {
                Text(stringResource(R.string.save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}

@Composable
private fun ProviderDetailConnectionSettingsSheet(
    provider: Provider,
    viewModel: ProviderDetailViewModel,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val scrollState = rememberScrollState()

    if (provider.kind == ai.oriveo.community.core.model.ProviderKind.Relay) {
        RelayAdvancedSettingsSheet(
            provider = provider,
            viewModel = viewModel,
            onDismiss = onDismiss,
        )
        return
    }

    val endpointOption = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
        .resolveRegionOption(provider.kind, provider.baseUrlText)
    val autoFillNoteRes = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
        .autoFillNote(provider.kind)

    Column(
        modifier = Modifier
            .padding(OriveoTheme.spacing.lg)
            .verticalScroll(scrollState),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
    ) {
        
        
        Text(
            text = stringResource(R.string.provider_detail_connection_settings),
            style = OriveoTheme.typography.title2,
            color = colors.textPrimary,
        )

        OriveoCard {
            
            
            
            Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md)) {
                ConnectionInfoRow(
                    title = stringResource(R.string.provider_label),
                    value = provider.displayName,
                )
                if (endpointOption != null) {
                    ConnectionInfoRow(
                        title = stringResource(
                            ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
                                .endpointTitle(provider.kind),
                        ),
                        value = localizedProviderEndpointLabel(provider.kind, endpointOption),
                    )
                }
                
                
                ConnectionInfoRow(
                    title = stringResource(R.string.request_url_label),
                    value = provider.baseUrlText ?: stringResource(
                        if (autoFillNoteRes != null) {
                            R.string.endpoint_auto_filled
                        } else {
                            R.string.endpoint_manual
                        },
                    ),
                )
            }
        }

        val footnoteRes = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
            .endpointDescription(provider.kind) ?: autoFillNoteRes
        if (footnoteRes != null) {
            Text(
                text = stringResource(footnoteRes),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }

        OriveoPrimaryButton(
            text = stringResource(R.string.done),
            onClick = onDismiss,
        )
        Spacer(modifier = Modifier.height(OriveoTheme.spacing.xxl))
    }
}


@Composable
private fun ConnectionInfoRow(title: String, value: String) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.body,
            color = colors.textPrimary,
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = value,
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}


internal fun providerSummaryAvailableModelCount(
    provider: Provider,
    resolvedCatalog: ai.oriveo.community.core.provider.ResolvedProviderCatalog?,
): Int {
    @Suppress("UNUSED_VARIABLE")
    val ignoredResolvedCatalog = resolvedCatalog
    return provider.enabledModelCount
}


@Composable
private fun SubscriptionDisabledNotice(notice: String?, fallbackRes: Int) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoTheme.radius.md)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.warningSoft)
            .border(width = 1.dp, color = colors.warning.copy(alpha = 0.28f), shape = shape)
            .padding(OriveoTheme.spacing.lg),
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = Icons.Outlined.Warning,
            contentDescription = null,
            tint = colors.warningText,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = notice?.takeIf { it.isNotBlank() } ?: stringResource(fallbackRes),
            style = OriveoTheme.typography.footnote,
            color = colors.textPrimary,
        )
    }
}
