package ai.oriveo.community.feature.providers.detail

import androidx.compose.ui.platform.testTag

import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoBackButtonDefaults
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
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
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.feature.providers.ProviderEndpointSelector
import ai.oriveo.community.feature.providers.localizedProviderEndpointLabel
import ai.oriveo.community.feature.providers.relay.RelayConnectionTestResult
import ai.oriveo.community.ui.component.HeroModelCapabilityStrip
import ai.oriveo.community.ui.component.ModelVendorIcon
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSectionHeader
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.StatusPill
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.component.localizedProviderError
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.util.formatRelativeTime
import kotlinx.coroutines.delay
import org.koin.androidx.compose.koinViewModel
import org.koin.compose.koinInject
import androidx.compose.runtime.produceState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastAction
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText

private fun LazyListScope.detailSection(
    key: String,
    content: @Composable () -> Unit,
) {
    // contentType = key: the sections have unrelated structures. Sharing the default null reuse
    // pool lets LazyList hand one section's slot to the next, reuse always fails, and the whole
    // subtree is rebuilt.
    item(key = key, contentType = key) {
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
    /** Arriving from the chat model options "Open web search settings": push the web search settings page first. */
    initialWebSearchLayer: Boolean = false,
    onStartChat: (providerID: String, modelID: String) -> Unit = { _, _ -> },
    manualEntryContext: ManualModelEntryContext = ManualModelEntryContext.ProviderDetail,
    onNavigateToManualEntry: (providerID: String) -> Unit = {},
    onNavigateToAdvancedSettings: (providerID: String) -> Unit = {},
    /** Filter for the first frame of the model library; null = follow the library layer in the stack (a layer with a key filter opens with it). */
    initialRelayCatalogFilter: RelayCatalogFilter? = null,
    viewModel: ProviderDetailViewModel = koinViewModel(),
    authorizationViewModel: SubscriptionAuthorizationViewModel = koinViewModel(),
) {
    val provider by viewModel.provider.collectAsStateWithLifecycle()
    val catalogViewState by viewModel.catalogViewState.collectAsStateWithLifecycle()
    val catalogGroups by viewModel.catalogGroups.collectAsStateWithLifecycle()
    val resolvedCatalog by viewModel.resolvedCatalog.collectAsStateWithLifecycle()
    val colors = OriveoTheme.colors
    val context = LocalContext.current

    var highlightedModelID: String? by remember { mutableStateOf(null) }
    var showConnectionSettingsSheet by remember { mutableStateOf(false) }
    var showGenerationParameters by remember { mutableStateOf(false) }
    var renameProvider: Provider? by remember { mutableStateOf(null) }
    // Sub-page layers of the relay / local board: detail -> model library -> advanced, and detail -> keys page.
    // A saveable stack: restored as is after rotation or process recreation; one BackHandler pops one layer at a time.
    var relayNavStack by rememberSaveable(stateSaver = RelayDetailNavStack.Saver) {
        mutableStateOf(RelayDetailNavStack(listOfNotNull(RelayDetailLayer.WebSearch.takeIf { initialWebSearchLayer })))
    }
    val showModelLibrary = relayNavStack.showsLibrary
    fun popRelayLayer() {
        val leavingAdvanced = relayNavStack.advanced != null
        relayNavStack = relayNavStack.pop()
        if (leavingAdvanced) viewModel.clearRelayAdvancedProbe()
    }
    androidx.activity.compose.BackHandler(enabled = !relayNavStack.isEmpty) { popRelayLayer() }

    // "Removed X · Undo" goes through the global top capsule toast (matching iOS ToastStyle.removed) instead of a separate bottom banner
    val globalSnackbarManager: GlobalSnackbarManager = koinInject()

    var dismissedHealthBanner by remember { mutableStateOf(false) }
    // The × on the relay / local recovery card: dismisses only for this visit to the page and is not persisted.
    var dismissedRelayRecovery by remember { mutableStateOf(false) }

    // One-shot notice after the two-step add-and-save (written only from the providers entry): cleared once taken, kept for the rest of this page visit.
    var addedModelsNotice by rememberSaveable { mutableStateOf<Int?>(null) }
    // One-shot notice after manual setup's "Save anyway (unverified)": the value is the already localized reason line from the failure card.
    var unverifiedNotice by rememberSaveable { mutableStateOf<String?>(null) }
    val noticeProviderId = provider?.id
    LaunchedEffect(noticeProviderId) {
        noticeProviderId?.let { id ->
            ProviderDetailNotice.take(id)?.let { addedModelsNotice = it }
            ProviderDetailNotice.takeUnverified(id)?.let { unverifiedNotice = it }
        }
    }

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
                val usesBoard = RelayDetailBoardModel.appliesTo(currentProvider)
                // The board and the relay recovery card share one action dispatch: the same action goes to the same destination in both places.
                fun handleRelayDetailAction(action: RelayDetailAction) {
                    when (action) {
                        RelayDetailAction.Rename -> renameProvider = currentProvider
                        RelayDetailAction.EditConnection -> {
                            onNavigateToAdvancedSettings(currentProvider.id)
                            showConnectionSettingsSheet = true
                        }
                        RelayDetailAction.EditKey -> viewModel.startEditApiKey()
                        RelayDetailAction.OpenKeys -> relayNavStack = relayNavStack.push(RelayDetailLayer.Keys)
                        RelayDetailAction.RemoveStoredKey -> viewModel.removeApiKey()
                        RelayDetailAction.OpenModelLibrary -> relayNavStack = relayNavStack.push(RelayDetailLayer.Library())
                        RelayDetailAction.OpenWebSearch -> relayNavStack = relayNavStack.push(RelayDetailLayer.WebSearch)
                        RelayDetailAction.OpenParameters -> showGenerationParameters = true
                        RelayDetailAction.Redetect -> viewModel.redetectRelayModels()
                        RelayDetailAction.Reverify -> viewModel.resync()
                        RelayDetailAction.Delete -> viewModel.showDeleteConfirm = true
                    }
                }
                // In board mode the main page draws only the board; the model list and catalog appear only on the "Model library" sub-page.
                val showsModelSections = !usesBoard || showModelLibrary
                val relayCatalogState = if (currentProvider.kind == ProviderKind.Relay) {
                    viewModel.relayCatalogUiState(currentProvider)
                } else {
                    null
                }

                val enabledSortedModels = remember(currentProvider.models) {
                    sortedEnabledModels(currentProvider)
                }
                // Relay "missing from catalog" check: build the index once here (O(catalog)) and
                // let each row only look it up. It is built in remember rather than on a background
                // producer because the value must be null (no badge) while the catalog is
                // unconfirmed; emitting null first and filling it in later would flash the badge.
                val confirmedRelayCatalogIndex = remember(relayCatalogState, currentProvider.catalogModels) {
                    when (relayCatalogState) {
                        ProviderDetailViewModel.RelayCatalogUiState.Available ->
                            ModelSelectionUtils.catalogMembershipIndex(currentProvider.catalogModels, currentProvider.kind)
                        ProviderDetailViewModel.RelayCatalogUiState.Empty -> emptySet()
                        else -> null
                    }
                }
                // Relay / local model library: the filter lives only on this page and resets when the connection changes.
                // A library entered through key(id) shows that filter on its first frame: switching to a library layer with a different filter resets to the new layer.
                val libraryLayer = relayNavStack.layers.lastOrNull { it is RelayDetailLayer.Library }
                var catalogFilter by remember(currentProvider.id, libraryLayer) {
                    mutableStateOf(initialRelayCatalogFilter ?: RelayCatalogBoardModel.initialFilter(relayNavStack))
                }
                val providerRepository: ProviderRepository = koinInject()
                val toolCallMemoryStore: ToolCallMemoryStore = koinInject()
                val toolCallMemoryRevision by toolCallMemoryStore.revision.collectAsStateWithLifecycle()
                // Lazy-verification state of this session (verifying / unreachable): in memory only, read per connection.
                val relayProbeStatesAll by providerRepository.relayModelProbeStateFlow.collectAsStateWithLifecycle()
                val relayProbeStates = remember(relayProbeStatesAll, currentProvider.id) {
                    ProviderRepository.relayModelProbeStatesOf(relayProbeStatesAll, currentProvider.id)
                }
                CapabilityObservationRevisionScope { capabilityObservationRevision ->
                    // The five capabilities and the connection identity are computed once per provider + revision and remembered; rebuilding the board on search / protocol filtering only hits the cache.
                    val capabilityMemo = remember(currentProvider, capabilityObservationRevision, toolCallMemoryRevision) {
                        val identities = java.util.concurrent.ConcurrentHashMap<String, ai.oriveo.community.core.model.CapabilityEvidenceIdentity>()
                        identities to RelayCatalogCapabilityMemo(
                            RelayCatalogCapabilityFacts(
                                identityFor = { identities[it.id] },
                                toolMemoryFor = { providerRepository.toolCallMemoryVerdict(currentProvider, it) },
                            ),
                        )
                    }
                    // The first pass over the whole catalog suspends per model to fetch identities, so it runs in the background; the two sections are not drawn until it finishes, to avoid drawing a wrong state first and then jumping.
                    val catalogBoard by produceState<RelayCatalogBoard?>(
                        initialValue = null,
                        usesBoard && showModelLibrary,
                        capabilityMemo,
                        enabledSortedModels,
                        catalogGroups,
                        catalogFilter,
                        confirmedRelayCatalogIndex,
                        relayCatalogState,
                        relayProbeStates,
                    ) {
                        if (!(usesBoard && showModelLibrary)) {
                            value = null
                            return@produceState
                        }
                        val groups = catalogGroups.orEmpty()
                        val (identities, memo) = capabilityMemo
                        value = withContext(Dispatchers.Default) {
                            val partition = providerRepository.currentCapabilityPartitionId()
                            (enabledSortedModels + groups.flatMap { it.models })
                                .filterNot(memo::isKnown)
                                .map { it.id }
                                .distinct()
                                .filterNot(identities::containsKey)
                                .forEach { id ->
                                    providerRepository.capabilityEvidenceIdentity(currentProvider, id, partition)
                                        ?.let { identities[id] = it }
                                }
                            RelayCatalogBoardModel.build(
                                provider = currentProvider,
                                enabledModels = enabledSortedModels,
                                catalogGroups = groups,
                                filter = catalogFilter,
                                nowSeconds = System.currentTimeMillis() / 1000L,
                                confirmedCatalogIndex = confirmedRelayCatalogIndex,
                                facts = memo,
                                catalogState = relayCatalogState ?: ProviderDetailViewModel.RelayCatalogUiState.Available,
                                probeStates = relayProbeStates,
                                canAddManual = viewModel.canAddManualModel(currentProvider),
                            )
                        }
                    }
                    val boardReady = !usesBoard || catalogBoard != null
                    val advancedLayer = relayNavStack.advanced?.takeIf { usesBoard && showModelLibrary }
                    // Models for read-only Advanced come from the catalog (not enabled yet); editable Advanced accepts enabled models only.
                    val advancedModel = advancedLayer?.let { layer ->
                        currentProvider.models.firstOrNull { it.id == layer.modelId }
                            ?: currentProvider.catalogModels.firstOrNull { it.id == layer.modelId }?.takeIf { layer.readOnly }
                    }
                    if (usesBoard && relayNavStack.showsWebSearch) {
                        RelayWebSearchPage(
                            provider = currentProvider,
                            contentPadding = padding,
                            onBack = ::popRelayLayer,
                            onSave = { texts ->
                                if (viewModel.saveRelayWebSearch(currentProvider, texts)) popRelayLayer()
                            },
                            rejectedModels = androidx.compose.runtime.remember(
                                currentProvider,
                                viewModel.relayWebProbeRevision,
                                viewModel.relayWebFragmentsRevision,
                            ) { RelayWebSearchBoardModel.rejectedModels(currentProvider) },
                            retestingModelID = viewModel.relayWebRetestingModelID,
                            onRetest = { viewModel.retestRelayWebModel(it) },
                        )
                    } else if (usesBoard && relayNavStack.showsKeys) {
                        RelayKeysPage(
                            provider = currentProvider,
                            pageState = viewModel.relayKeysPageState,
                            contentPadding = padding,
                            onBack = ::popRelayLayer,
                            onReplaceSingleKey = { viewModel.startEditApiKey() },
                            onAdd = viewModel::addRelayKey,
                            onRename = viewModel::renameRelayKey,
                            onReplace = viewModel::replaceRelayKeySecret,
                            onMove = viewModel::moveRelayKey,
                            onDelete = viewModel::deleteRelayKey,
                            onOpenLibrary = { keyId -> relayNavStack = relayNavStack.push(RelayKeysBoardModel.libraryLayer(keyId)) },
                        )
                    } else if (advancedModel != null) {
                        RelayModelAdvancedHost(
                            provider = currentProvider,
                            model = advancedModel,
                            viewModel = viewModel,
                            providerRepository = providerRepository,
                            revisionKey = capabilityObservationRevision to toolCallMemoryRevision,
                            contentPadding = padding,
                            onBack = ::popRelayLayer,
                            readOnly = advancedLayer?.readOnly == true,
                        )
                    } else LazyColumn(
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
                                OriveoBackButton(
                                    onClick = {
                                        if (usesBoard && !relayNavStack.isEmpty) popRelayLayer() else onBack()
                                    },
                                    // Line the icon box up with the page margin
                                    modifier = Modifier.offset(x = -OriveoBackButtonDefaults.EdgeInset),
                                )
                                Spacer(modifier = Modifier.weight(1f))
                            }
                        }

                        val libraryBoard = catalogBoard?.takeIf { usesBoard && showModelLibrary }
                        if (libraryBoard != null) {
                            detailSection(key = "relay_library_header") {
                                RelayCatalogLibraryHeader(
                                    provider = currentProvider,
                                    header = libraryBoard.header,
                                    isRefreshing = viewModel.isResyncing,
                                    onRefresh = viewModel::retryRelayCatalog,
                                )
                            }
                        }

                        addedModelsNotice?.takeIf { !(usesBoard && showModelLibrary) }?.let { count ->
                            detailSection(key = "relay_setup_added_notice") {
                                ProviderDetailAddedNotice(count)
                            }
                        }

                        unverifiedNotice?.takeIf { !(usesBoard && showModelLibrary) }?.let { reason ->
                            detailSection(key = "relay_setup_unverified_notice") {
                                ProviderDetailUnverifiedNotice(reason)
                            }
                        }

                        // Subscription kill switch: the instance is not deleted; it becomes read-only and the delivered message is shown as is.
                        // Silent invalidation is the worst kind, since the user would assume something is wrong with their own account.
                        // Ask the provider matching the kind: authMode only says "uses a subscription", not which one. Judging a Codex
                        // instance by Grok's availability would let one provider's kill switch hit the other (both can be connected at once).
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

                        // Relay / local get their own recovery card: edit connection / API key / re-verify, and the top-right × dismisses it for this visit.
                        val relayRecoveryCard = if (usesBoard && !showModelLibrary && !dismissedRelayRecovery) {
                            RelayDetailBoardModel.recoveryCard(
                                provider = currentProvider,
                                isReverifying = viewModel.isResyncing,
                                omitsDetail = unverifiedNotice != null,
                            )
                        } else {
                            null
                        }
                        // A missing key or a real issue both trigger the Recovery Card (judged by effectiveStatusKind.isWarning)
                        if (relayRecoveryCard != null) {
                            detailSection(key = "relay_connection_recovery") {
                                RelayRecoveryCardView(card = relayRecoveryCard, onAction = ::handleRelayDetailAction, onDismiss = { dismissedRelayRecovery = true })
                            }
                        } else if (!usesBoard && currentProvider.effectiveStatusKind.isWarning && !dismissedHealthBanner) {
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

                        if (usesBoard && !showModelLibrary) {
                            detailSection(key = "relay_detail_board") {
                                // Read the revision once: after web search settings are saved the row state must re-read local storage.
                                viewModel.relayWebFragmentsRevision
                                val board = RelayDetailBoardModel.build(currentProvider, viewModel.isRedetecting, viewModel.lastUsedModelRefSnapshot)
                                RelayDetailBoardView(
                                    provider = currentProvider,
                                    board = board,
                                    onAction = ::handleRelayDetailAction,
                                )
                            }
                        } else if (!usesBoard) detailSection(key = "brand_hero_card") {
                            val enabledModelCount = providerSummaryAvailableModelCount(
                                provider = currentProvider,
                                resolvedCatalog = resolvedCatalog,
                            )
                            ProviderDetailBrandHeroCard(
                                provider = currentProvider,
                                enabledModelCount = enabledModelCount,
                                onStartChat = {
                                    viewModel.startChatModelID(currentProvider)?.let { modelId ->
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
                                onEditName = { renameProvider = currentProvider },
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

                        // "Added models" are likewise laid out row by row: "Add all" on the web writes the whole catalog into
                        // provider.models, so this section can reach 400-700 rows just like the catalog section (the other half of an ANR).
                        val board = catalogBoard?.takeIf { usesBoard && showModelLibrary }
                        if (board != null && board.filters.isNotEmpty()) {
                            detailSection(key = "relay_catalog_filters") {
                                RelayCatalogFilterChips(
                                    filters = board.filters,
                                    selected = board.selected,
                                    onSelect = { catalogFilter = it },
                                    keyTitle = board.keyFilterTitle,
                                )
                            }
                        }
                        if (showsModelSections && boardReady) providerDetailEnabledModels(
                            provider = currentProvider,
                            titleRes = viewModel.enabledModelsTitle(currentProvider),
                            capabilityObservationRevision = capabilityObservationRevision,
                            sortedModels = enabledSortedModels,
                            highlightedModelID = highlightedModelID,
                            onToggleModel = { model ->
                                val willDisable = currentProvider.models.any { it.id == model.id }
                                viewModel.toggleModelEnabled(model)
                                if (willDisable && currentProvider.models.size > 1) {
                                    globalSnackbarManager.show(
                                        GlobalSnackbarMessage(
                                            message = UiText.Resource(
                                                R.string.provider_detail_removed_model,
                                                listOf(model.name),
                                            ),
                                            style = GlobalToastStyle.Removed,
                                            action = GlobalToastAction(
                                                label = UiText.Resource(R.string.undo),
                                                onClick = {
                                                    viewModel.toggleModelEnabled(model)
                                                    triggerHaptic()
                                                },
                                            ),
                                            durationMs = 4000,
                                        ),
                                    )
                                }
                            },
                            onSetDefault = if (RelayDetailBoardModel.offersSetDefaultInModelMenu(currentProvider)) {
                                { model -> viewModel.setDefaultModel(model) }
                            } else {
                                null
                            },
                            onStartChat = { model ->
                                onStartChat(currentProvider.id, model.id)
                            },
                            confirmedRelayCatalogIndex = confirmedRelayCatalogIndex,
                            onOpenAdvanced = { model -> relayNavStack = relayNavStack.push(RelayDetailLayer.Advanced(model.id, readOnly = false)) },
                            relayBoard = board?.enabled,
                        )

                        // Catalog section: split into separate LazyColumn items to avoid composing 300+ models at once.
                        // In board mode the groups are replaced by the groups filtered by the board model (same id / title, collapsed by default as before).
                        val groups = if (usesBoard) {
                            board?.takeIf { catalogGroups != null && RelayCatalogPageSection.Library in it.sections }?.library?.groups
                                ?.map {
                                    ProviderCatalogGroup(
                                        id = it.id,
                                        title = it.title,
                                        models = it.rows.map(RelayCatalogRow::model),
                                        titleRes = it.titleRes,
                                    )
                                }
                        } else {
                            catalogGroups.takeIf { showsModelSections }
                        }
                        // Model library: above the catalog groups come the key status strip / loading / a single-key failure card; the failure card has no manual add, and the old catalog stays below as usual.
                        if (board != null && RelayCatalogPageSection.KeyStrip in board.sections) {
                            detailSection(key = "relay_catalog_key_strip") {
                                RelayCatalogKeyStrip(board.keyStrip, onRetry = viewModel::retryRelayKeyCatalog)
                            }
                        }
                        if (board != null && RelayCatalogPageSection.Loading in board.sections) {
                            detailSection(key = "relay_catalog_loading") {
                                OriveoCard {
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
                                }
                            }
                        }
                        if (board != null && RelayCatalogPageSection.FailureCard in board.sections) {
                            detailSection(key = "relay_catalog_failure_card") {
                                RelayCatalogFailureCard(
                                    detail = viewModel.relayCatalogFailureDetail,
                                    onRetry = viewModel::retryRelayCatalog,
                                )
                            }
                        }
                        if (!usesBoard && showsModelSections && currentProvider.kind == ProviderKind.Relay &&
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
                                    ProviderDetailSectionHeader(
                                        title = board?.library?.let { stringResource(it.titleRes, it.count) }
                                            ?: stringResource(R.string.model_library),
                                    )
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
                                    relayBoardRows = board?.library?.groups
                                        ?.flatMap { it.rows }
                                        ?.associateBy { it.model.id },
                                    onOpenRelayModel = { model ->
                                        relayNavStack = relayNavStack.push(RelayDetailLayer.Advanced(model.id, readOnly = true))
                                    },
                                    relayAddAll = board?.library?.groups
                                        ?.associate { it.id to it.enableAllModelIDs },
                                    onAddAll = { modelIDs ->
                                        if (viewModel.enableRelayCatalogModels(modelIDs) > 0) triggerHaptic()
                                    },
                                )
                                item(key = "catalog_groups_bottom_spacer") {
                                    Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                                }
                            }
                        }

                        board?.enableHintRes?.takeIf { RelayCatalogPageSection.EnableHint in board.sections && !groups.isNullOrEmpty() }?.let { hint ->
                            detailSection(key = "relay_catalog_enable_hint") {
                                RelayCatalogEnableHint(hint)
                            }
                        }

                        if (showsModelSections && viewModel.canAddManualModel(currentProvider)) {
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

                        if (board != null) {
                            detailSection(key = "relay_catalog_legend") {
                                RelayCatalogLegend(board)
                            }
                        }

                        if (RelayDetailBoardModel.showsLegacySettingsRows(currentProvider)) detailSection(key = "settings_card") {
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
            OriveoModalBottomSheet(
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

    viewModel.relayCapabilityTest?.let { state ->
        RelayCapabilityTestPanel(
            state = state,
            clockMillis = viewModel::relayCapabilityTestClockMillis,
            onCancel = viewModel::cancelRelayCapabilityTest,
            onDismiss = viewModel::dismissRelayCapabilityTest,
        )
    }

    // Subscription re-authorization: goes through the device code flow and does not show a key input dialog.
    if (viewModel.showGrokReauthorization) {
        val availability = viewModel.grokSubscriptionAvailability
        val config = (availability as? GrokSubscriptionAvailability.Available)?.config
        if (config == null) {

            viewModel.showGrokReauthorization = false
        } else {
            val grokSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            OriveoModalBottomSheet(
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
            OriveoModalBottomSheet(
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
        OriveoModalBottomSheet(
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
            .resolveRegionOption(provider!!.kind, provider!!.baseUrlText, provider!!.endpointSource)
        OriveoModalBottomSheet(
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
                    currentOption = currentEndpoint,
                )
                // Shown when the selected address template contains {workspaceId}; same component and copy as the setup page; save is disabled while the value is invalid.
                viewModel.endpointSetupFieldIds.forEach { fieldId ->
                    if (fieldId == ai.oriveo.community.core.provider.transport.OfficialEndpointSource.WORKSPACE_ID) {
                        Spacer(modifier = Modifier.height(OriveoTheme.spacing.md))
                        ai.oriveo.community.ui.component.OriveoLabeledField(
                            label = stringResource(R.string.provider_setup_workspace_id),
                            value = viewModel.endpointSetupValues[fieldId].orEmpty(),
                            onValueChange = { viewModel.updateEndpointSetupField(fieldId, it) },
                            footnote = stringResource(R.string.provider_setup_workspace_id_hint),
                            enabled = !viewModel.isUpdatingEndpoint,
                        )
                    }
                }
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
                    enabled = viewModel.canSaveEndpoint,
                    loading = viewModel.isUpdatingEndpoint,
                )
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.xxl))
            }
        }
    }

    if (showConnectionSettingsSheet && provider?.let(viewModel::canAccessAdvancedSettings) == true) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        OriveoModalBottomSheet(
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
        .resolveRegionOption(provider.kind, provider.baseUrlText, provider.endpointSource)
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

/**
 * Model count shown in the detail hero.
 *
 * Reads the count the provider already carries instead of resolving the catalog: the hero renders
 * on every recomposition of the detail screen, and resolving there would repeat work the catalog
 * sections have already done.
 */
/** Hero count is the enabled model count; resolvedCatalog is kept only as a reactive dependency so the hero and the list never mismatch across frames. */
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

/** One-shot notice after saving manual setup unverified (same as iOS): light warning-colored fill + 30% warning-colored border, titled "Connection not verified yet", with the reason from the failure card on the next line. */
@Composable
private fun ProviderDetailUnverifiedNotice(reason: String) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoTheme.radius.md)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.warningSoft)
            .border(1.dp, colors.warning.copy(alpha = 0.3f), shape)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(painterResource(R.drawable.ph_warning_circle), contentDescription = null, tint = colors.warning, modifier = Modifier.size(18.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = stringResource(R.string.relay_connection_not_verified),
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(text = reason, style = OriveoTheme.typography.caption, color = colors.textSecondary)
        }
    }
}

/** One-shot notice after the two-step add-and-save: "n models added; you can keep adding in the model library". */
@Composable
private fun ProviderDetailAddedNotice(count: Int) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.md))
            .background(colors.successSoft)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(R.drawable.ph_check_circle), contentDescription = null, tint = colors.success, modifier = Modifier.size(18.dp))
        Text(
            text = pluralStringResource(R.plurals.relay_setup_added_banner, count, count),
            style = OriveoTheme.typography.caption,
            color = colors.textPrimary,
        )
    }
}
