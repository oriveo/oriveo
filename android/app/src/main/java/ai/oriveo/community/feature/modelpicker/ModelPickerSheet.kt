@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package ai.oriveo.community.feature.modelpicker

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.stateDescription
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.resolveProviderLogoKind
import ai.oriveo.community.core.model.RelayAvatar
import ai.oriveo.community.core.model.RelayAvatarResolver
import ai.oriveo.community.core.provider.ModelRetirement
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.DeliveredCostResolver
import ai.oriveo.community.core.provider.ModelPricingFormatter
import ai.oriveo.community.core.provider.connectionPriceLabelKey
import ai.oriveo.community.core.provider.pricedForConnection
import ai.oriveo.community.ui.component.rememberCostLocale
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.feature.providers.detail.comparePickerModels
import ai.oriveo.community.feature.providers.detail.sortedEnabledModels
import ai.oriveo.community.feature.providers.detail.sortedProvidersForModelPicker
import ai.oriveo.community.ui.component.FixedHeroModelCapabilityStrip
import ai.oriveo.community.ui.component.MODEL_ROW_MAX_CAPABILITIES
import ai.oriveo.community.ui.component.OriveoBackButtonDefaults
import ai.oriveo.community.ui.component.OriveoCloseButton
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.localizedPriceTier
import ai.oriveo.community.ui.component.normalizedPriceTier
import ai.oriveo.community.ui.component.visibleMetadataCapabilities
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogClient
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceDisclosureStore
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.ui.theme.CapabilityPalette
import ai.oriveo.community.ui.theme.DetailRowPalette
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.OriveoV2ScreenBackground
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.util.modelIdDisplay
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.koin.compose.koinInject

enum class ModelPickerContext {
    Home,
    Chat,
    Crosscheck,
}

private data class V2PickerColors(
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val primary: Color,
    val primarySubtle: Color,
    val surfaceDefault: Color,
    val bgInset: Color,
    val borderDefault: Color,
    val borderSubtle: Color,
    val shadowSm: Color,
)

@Composable
private fun rememberV2PickerColors(): V2PickerColors {
    val base = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    return remember(base, isDark) {
        V2PickerColors(
            textPrimary = base.textPrimary,
            textSecondary = base.textSecondary,
            textTertiary = base.textTertiary,
            primary = base.primary,

            primarySubtle = base.primarySoft,

            surfaceDefault = if (isDark) base.surface else Color.White,
            bgInset = base.surfaceInset,

            borderDefault = if (isDark) Color(0x1AFFFFFF) else Color(0x14000000),
            borderSubtle = if (isDark) Color(0x0FFFFFFF) else Color(0x0A000000),
            shadowSm = base.shadow,
        )
    }
}

private fun Modifier.groupedCardSurface(
    shape: RoundedCornerShape,
    v2: V2PickerColors,
    isDark: Boolean,
): Modifier {
    val sheen = Brush.linearGradient(
        colors = listOf(
            Color.White.copy(alpha = if (isDark) 0.02f else 0.40f),
            Color.Transparent,
            v2.primary.copy(alpha = if (isDark) 0.01f else 0.008f),
        ),
    )
    val shineColor = Color.White.copy(alpha = if (isDark) 0.05f else 0.70f)

    val shadowColor = if (isDark) Color.Black.copy(alpha = 0.20f) else Color.Black.copy(alpha = 0.04f)
    return this

        .drawBehind {
            // The soft drop shadow needs setShadowLayer, which only the platform Paint exposes.
            val r = shape.topStart.toPx(size, this)
            val paint = android.graphics.Paint().apply {
                color = android.graphics.Color.TRANSPARENT
                setShadowLayer(14.dp.toPx(), 0f, 5.dp.toPx(), shadowColor.toArgb())
            }
            drawIntoCanvas { canvas ->
                canvas.nativeCanvas.drawRoundRect(0f, 0f, size.width, size.height, r, r, paint)
            }
        }
        .clip(shape)

        .drawWithContent {
            drawContent()
            val inset = 1.dp.toPx()
            val lineY = 1.dp.toPx() / 2f
            drawLine(
                color = shineColor,
                start = Offset(inset, lineY),
                end = Offset(size.width - inset, lineY),
                strokeWidth = 1.dp.toPx(),
            )
        }
        .background(v2.surfaceDefault, shape)
        .drawBehind { drawRect(brush = sheen) }

        .border(0.5.dp, v2.borderDefault, shape)
}

@Composable
fun ModelPickerSheet(
    context: ModelPickerContext,
    providers: List<Provider>,
    activeProviderId: String?,
    activeModelId: String?,
    onModelSelected: (providerId: String, modelId: String) -> Unit,
    onEnableModel: (providerId: String, modelId: String) -> Unit,
    onDismiss: () -> Unit,
    /**
     * If the realtime disclosure was never accepted for this provider, the picker has already collapsed and the page shows VoiceDisclosureSheet.
     * The crosscheck page does not list realtime rows (Crosscheck has no realtime entry), so it keeps the default empty implementation.
     */
    onRequestRealtimeDisclosure: (RealtimePickerDisclosure) -> Unit = {},
) {
    val isHome = context == ModelPickerContext.Home
    val isCrosscheck = context == ModelPickerContext.Crosscheck
    var searchText by remember { mutableStateOf("") }
    var expandedProviderIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var catalogProviderId by remember { mutableStateOf<String?>(null) }

    val currentProvider = remember(providers, activeProviderId) {
        providers.firstOrNull { it.id == activeProviderId }
    }
    val currentModel = remember(currentProvider, activeModelId) {
        activeModelId?.let { modelId ->
            currentProvider?.let { provider ->
                // A relay's stored value is resolved among enabled models only (same rule on all three platforms); official providers still search the whole catalog.
                if (provider.kind == ProviderKind.Relay) {
                    ModelSelectionUtils.resolveStoredModel(provider.models, modelId, provider.kind)
                } else {
                    ModelSelectionUtils.matchingModel(provider.allModels, modelId, provider.kind)
                }
            }
        }
    }
    val currentModelId = currentModel?.id ?: activeModelId
    val sortedProviders = remember(providers, activeProviderId, isHome) {
        if (isHome) {
            sortedProvidersForModelPicker(providers)
        } else {
            providers.sortedWith(
                compareByDescending<Provider> { it.id == activeProviderId }
                    .thenBy { it.displayName.lowercase() },
            )
        }
    }
    var selectedCapabilityFilters by remember {
        mutableStateOf<Set<ModelPickerCapabilityFilterKind>>(emptySet())
    }
    // Realtime voice rows come from the voice catalog cache (a read-only snapshot, no request); the "realtime voice" filter intersects with the capability filter.
    val voiceCatalogClient: VoiceCatalogClient = koinInject()
    val voiceCatalogState by voiceCatalogClient.state.collectAsStateWithLifecycle()
    val realtimeCatalog = (voiceCatalogState as? VoiceCatalogState.Available)?.catalog
    // Selected-row check at read time: when the selection is on a realtime row, text rows are not checked, so only one row is checked at a time; while the catalog is not ready, judge by text rows and do not rewrite the selected field.
    val selectedRealtimeModelId = modelPickerSelectedRealtimeModel(context, currentProvider, activeModelId, realtimeCatalog)
    var realtimeFilterSelected by remember { mutableStateOf(false) }
    val disclosureStore: VoiceDisclosureStore = koinInject<VoiceEngineSettings>().disclosure
    // The expansion state only cares about the provider dimension: which providers exist. Previously it depended on the model.id+groupKey list,
    // so enabling or disabling any model reset the whole expansion state (expanded state collapsed after a user action).
    // Now it uses a hash of the stable provider id list.
    val expansionSignature = remember(providers) {
        providers.map { it.id }
    }
    val catalogProvider = catalogProviderId?.let { providerId ->
        providers.firstOrNull { it.id == providerId }
    }

    val haptics = LocalHapticFeedback.current
    val lazyListState = rememberLazyListState()

    val capabilityObservationRevision by CapabilityEvidenceObservationBridge.revision.collectAsStateWithLifecycle()
    val providerRepository: ProviderRepository = koinInject()
    val toolCallMemoryStore: ToolCallMemoryStore = koinInject()
    val toolCallMemoryRevision by toolCallMemoryStore.revision.collectAsStateWithLifecycle()
    val toolCallMemoryVerdict: (Provider, AIModel) -> Boolean? = { provider, model ->
        providerRepository.toolCallMemoryVerdict(provider, model)
    }

    // Grouping, counting and filtering run together off the main thread. Each model needs its
    // capabilities resolved from metadata, which cost a single 719ms main-thread frame with 700+ models
    // on a low-end phone, and the search text is an input, so every keystroke used to rerun all of it.
    // Counts and filtering still come from one function over one input, otherwise the screen says 358
    // and the list shows 12.
    //
    // produceState keeps the previous value while its keys change, so the list keeps showing the old
    // result during a search or filter change instead of flashing empty. Only the first frame is null
    // (nothing computed yet), which downstream renders as nothing rather than as an empty state.
    val sectionsResult: ModelPickerSectionsResult? by produceState<ModelPickerSectionsResult?>(
        initialValue = null,
        sortedProviders,
        activeProviderId,
        currentModel,
        searchText,
        selectedCapabilityFilters,
        capabilityObservationRevision,
        // Filters no longer include tools; reading it here makes the whole sheet recompose when tool memory changes, so the tool badge on each row refreshes.
        toolCallMemoryRevision,
        realtimeCatalog,
        realtimeFilterSelected,
    ) {
        value = withContext(Dispatchers.Default) {
            buildModelPickerSectionsResult(
                context = context,
                providers = sortedProviders,
                activeProviderId = activeProviderId,
                currentModel = currentModel,
                searchText = searchText,
                selectedCapabilityFilters = selectedCapabilityFilters,
                realtimeCatalog = realtimeCatalog,
                realtimeFilterSelected = realtimeFilterSelected,
            )
        }
    }
    val providerSections = sectionsResult?.providerSections.orEmpty()
    val homeHeaderCounts = remember(providerSections) { modelPickerHomeHeaderCounts(providerSections) }
    LaunchedEffect(expansionSignature, isHome, activeProviderId, sortedProviders) {
        expandedProviderIds = defaultExpandedModelPickerProviderIds(
            providers = sortedProviders,
            selectedProviderId = activeProviderId,
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight()
            .testTag("model_picker")
            .background(OriveoTheme.colors.backgroundBase),
    ) {
        OriveoV2ScreenBackground()
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding(),
        ) {
            OriveoSheetDragHandle()
            if (catalogProvider != null) {
                InlineModelCatalog(
                    provider = catalogProvider,
                    capabilityObservationRevision = capabilityObservationRevision,
                    onEnableModel = { modelId ->
                        // Same tap feel as the provider detail screen; the "added" toast follows.
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        onEnableModel(catalogProvider.id, modelId)
                    },
                    onBack = { catalogProviderId = null },
                )
            } else {
                ModelPickerContent(
                    context = context,
                    currentModelName = currentModel?.name,
                    currentProviderName = currentProvider?.displayName,
                    providerSections = providerSections,
                    capabilityFilterCounts = sectionsResult?.capabilityFilterCounts,
                    isComputing = sectionsResult == null,
                    selectedCapabilityFilters = selectedCapabilityFilters,
                    onToggleCapabilityFilter = { kind ->
                        selectedCapabilityFilters = if (kind in selectedCapabilityFilters) {
                            selectedCapabilityFilters - kind
                        } else {
                            selectedCapabilityFilters + kind
                        }
                    },
                    searchText = searchText,
                    onSearchChange = { searchText = it },
                    onSearchClear = { searchText = "" },
                    expandedProviderIds = expandedProviderIds,
                    onToggleProvider = { providerId ->
                        if (searchText.isBlank()) {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            expandedProviderIds = expandedProviderIds.toggle(providerId)
                        }
                    },
                    showsRealtimeFilter = sectionsResult?.showsRealtimeFilter == true,
                    realtimeFilterCount = sectionsResult?.realtimeFilterCount ?: 0,
                    realtimeFilterSelected = realtimeFilterSelected,
                    onToggleRealtimeFilter = { realtimeFilterSelected = !realtimeFilterSelected },
                    onSelectModel = { providerId, modelId ->
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        selectModelAndDismiss(
                            providerId = providerId,
                            modelId = modelId,
                            select = onModelSelected,
                            dismiss = onDismiss,
                        )
                    },
                    onSelectRealtimeModel = { provider, entry ->
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        // Tapping collapses at once; when a realtime model of a provider is first picked, the page shows the cloud disclosure, and it is selected only after consent.
                        pickRealtimeModelAndDismiss(
                            providerId = provider.id,
                            providerKind = provider.kind,
                            modelId = entry.model,
                            store = disclosureStore,
                            select = onModelSelected,
                            dismiss = onDismiss,
                            requestDisclosure = onRequestRealtimeDisclosure,
                        )
                    },
                    isRealtimeModelSelected = { providerId, modelId ->
                        selectedRealtimeModelId != null && isModelSelected(
                            activeProviderId = activeProviderId,
                            activeModelId = activeModelId,
                            providerId = providerId,
                            realtimeModelId = modelId,
                        )
                    },
                    isModelSelected = { providerId, model ->
                        isModelSelected(
                            context = context,
                            selectedRealtimeModelId = selectedRealtimeModelId,
                            activeProviderId = activeProviderId,
                            activeModelId = activeModelId,
                            currentModelId = currentModelId,
                            providerId = providerId,
                            providerKind = providers.firstOrNull { it.id == providerId }?.kind,
                            model = model,
                        )
                    },
                    onOpenCatalog = { providerId -> catalogProviderId = providerId },
                    isSingleProvider = providers.size == 1,
                    isCrosscheck = isCrosscheck,
                    onDismiss = onDismiss,
                    // "N providers" and "M models" come from the same group set after filtering / search
                    providerCount = homeHeaderCounts.providerCount,
                    modelCountTotal = homeHeaderCounts.modelCount,
                    lazyListState = lazyListState,
                    capabilityObservationRevision = capabilityObservationRevision,
                    toolCallMemoryVerdict = toolCallMemoryVerdict,
                )
            }
        }
    }
}

@Composable
private fun ColumnScope.ModelPickerContent(
    context: ModelPickerContext,
    currentModelName: String?,
    currentProviderName: String?,
    providerSections: List<ModelPickerSection>,
    /** Null while the counts are still being computed; blank is better than rendering 0. */
    capabilityFilterCounts: Map<ModelPickerCapabilityFilterKind, Int>?,
    /** The first grouping result has not arrived yet; draw neither rows nor the empty state. */
    isComputing: Boolean,
    selectedCapabilityFilters: Set<ModelPickerCapabilityFilterKind>,
    onToggleCapabilityFilter: (ModelPickerCapabilityFilterKind) -> Unit,
    showsRealtimeFilter: Boolean,
    realtimeFilterCount: Int,
    realtimeFilterSelected: Boolean,
    onToggleRealtimeFilter: () -> Unit,
    searchText: String,
    onSearchChange: (String) -> Unit,
    onSearchClear: () -> Unit,
    expandedProviderIds: Set<String>,
    onToggleProvider: (String) -> Unit,
    onSelectModel: (providerId: String, modelId: String) -> Unit,
    onSelectRealtimeModel: (Provider, VoiceRealtimeEntry) -> Unit,
    isModelSelected: (providerId: String, model: AIModel) -> Boolean,
    isRealtimeModelSelected: (providerId: String, modelId: String) -> Boolean,
    onOpenCatalog: (providerId: String) -> Unit,
    isSingleProvider: Boolean,
    isCrosscheck: Boolean,
    onDismiss: () -> Unit,
    providerCount: Int,
    modelCountTotal: Int,
    lazyListState: androidx.compose.foundation.lazy.LazyListState,
    capabilityObservationRevision: Long,
    toolCallMemoryVerdict: (Provider, AIModel) -> Boolean?,
) {
    val isHome = context == ModelPickerContext.Home
    // Deliberately kept on the main thread: it only flattens the finished sections into rows, with no
    // metadata resolution, and expanding, collapsing and searching need it in the same frame.
    val entries = remember(
        providerSections,
        searchText,
        expandedProviderIds,
        isSingleProvider,
        isHome,
        isCrosscheck,
    ) {
        buildModelPickerListEntries(
            providerSections = providerSections,
            searchText = searchText,
            expandedProviderIds = expandedProviderIds,
            isSingleProvider = isSingleProvider,
            isHome = isHome,
            isCrosscheck = isCrosscheck,
        )
    }

    Box(
        modifier = Modifier
            .weight(1f, fill = true)
            .fillMaxWidth(),
    ) {
        LazyColumn(
            state = lazyListState,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("model_picker_list"),
            contentPadding = PaddingValues(
                start = 20.dp,
                end = 20.dp,
                top = if (isHome) 4.dp else 16.dp,
                bottom = 28.dp,
            ),
        ) {
            item(key = "header") {
                Column {
                    if (isHome) {
                        HomeHeader(
                            providerCount = providerCount,
                            modelCount = modelCountTotal,
                        )
                    } else {
                        ChatHeader(
                            currentModelName = currentModelName,
                            currentProviderName = currentProviderName,
                            onDismiss = onDismiss,
                        )
                    }
                    Spacer(modifier = Modifier.height(16.dp))
                }
            }

            item(key = "search") {
                Column {
                    SearchBar(
                        searchValue = searchText,
                        onSearchChange = onSearchChange,
                        onSearchClear = onSearchClear,
                    )
                    Spacer(modifier = Modifier.height(12.dp))

                    ModelPickerCapabilityFilterRow(
                        counts = capabilityFilterCounts,
                        selected = selectedCapabilityFilters,
                        onToggle = onToggleCapabilityFilter,
                        showsRealtime = showsRealtimeFilter,
                        realtimeCount = realtimeFilterCount,
                        realtimeSelected = realtimeFilterSelected,
                        onToggleRealtime = onToggleRealtimeFilter,
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                }
            }

            if (isComputing) {
                // Still grouping on the background thread. An empty state here would tell the user there
                // are no models at all, when the real list replaces it a few milliseconds later.
                Unit
            } else if (providerSections.isEmpty()) {

                item(key = "empty") {
                    if (selectedCapabilityFilters.isEmpty() && !realtimeFilterSelected) {
                        EmptyModelState()
                    } else {
                        CapabilityFilterEmptyState()
                    }
                }
            } else {
                items(
                    items = entries,
                    key = ModelPickerListEntry::key,
                    contentType = ModelPickerListEntry::contentType,
                ) { positionedEntry ->
                    ModelPickerListEntryRow(
                        positionedEntry = positionedEntry,
                        capabilityObservationRevision = capabilityObservationRevision,
                        toolCallMemoryVerdict = toolCallMemoryVerdict,
                        onToggleProvider = onToggleProvider,
                        onSelectModel = onSelectModel,
                        onSelectRealtimeModel = onSelectRealtimeModel,
                        isModelSelected = isModelSelected,
                        isRealtimeModelSelected = isRealtimeModelSelected,
                        onOpenCatalog = onOpenCatalog,
                    )
                }
            }
        }
    }
}

@Composable
private fun HomeHeader(
    providerCount: Int,
    modelCount: Int,
) {
    val v2 = rememberV2PickerColors()

    val rawWidthDp = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp
    val isCompact = rawWidthDp < 390
    val titleSize = if (isCompact) 24.sp else 28.sp
    val titleLineHeight = if (isCompact) 30.sp else 34.sp
    val statFontSize = if (isCompact) 12.sp else 13.sp
    val statIconSize = if (isCompact) 10.dp else 11.dp
    val statSpacing = if (isCompact) 6.dp else 8.dp

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = stringResource(R.string.choose_model),
            style = OriveoTheme.typography.hero.copy(
                fontSize = titleSize,
                lineHeight = titleLineHeight,
                fontWeight = FontWeight.Bold,
            ),
            color = v2.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        Spacer(modifier = Modifier.weight(1f))

        if (providerCount > 0) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(statSpacing),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(top = if (isCompact) 4.dp else 6.dp),
            ) {
                StatBadge(
                    icon = Icons.Filled.GridView,
                    text = pluralProvidersLabel(providerCount),
                    iconSize = statIconSize,
                    fontSize = statFontSize,
                )
                if (!isCompact) {
                    Box(
                        modifier = Modifier
                            .size(3.dp)
                            .background(v2.textTertiary.copy(alpha = 0.35f), CircleShape),
                    )
                }
                StatBadge(
                    icon = Icons.Filled.AutoAwesome,
                    text = stringResource(R.string.n_models_enabled, modelCount),
                    iconSize = statIconSize,
                    fontSize = statFontSize,
                )
            }
        }
    }
}

@Composable
private fun StatBadge(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    iconSize: androidx.compose.ui.unit.Dp = 11.dp,
    fontSize: androidx.compose.ui.unit.TextUnit = 13.sp,
) {
    val v2 = rememberV2PickerColors()
    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(iconSize),
            tint = v2.primary,
        )
        Text(
            text = text,
            style = OriveoTheme.typography.footnote.copy(
                fontSize = fontSize,
                fontFeatureSettings = "tnum",
            ),
            color = v2.textSecondary,
            maxLines = 1,
        )
    }
}

@Composable
private fun pluralProvidersLabel(count: Int): String =
    stringResource(R.string.n_providers, count)

@Composable
private fun ChatHeader(
    currentModelName: String?,
    currentProviderName: String?,
    onDismiss: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 2.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .testTag("model_picker_search"),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = stringResource(R.string.switch_model),
                style = OriveoTheme.typography.title1.copy(
                    fontSize = 22.sp,
                    lineHeight = 28.sp,
                    fontWeight = FontWeight.Bold,
                ),
                color = v2.textPrimary,
            )
            if (currentModelName != null && currentProviderName != null) {
                Text(
                    text = stringResource(
                        R.string.current_model_subtitle,
                        currentModelName,
                        currentProviderName,
                    ),
                    style = OriveoTheme.typography.footnote.copy(fontSize = 13.sp),
                    color = v2.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            } else {
                Text(
                    text = stringResource(R.string.switch_model_description),
                    style = OriveoTheme.typography.footnote.copy(fontSize = 13.sp),
                    color = v2.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        OriveoCloseButton(
            onClick = onDismiss,
            contentDescription = stringResource(R.string.cancel),
            // Line the icon box up with the trailing margin
            modifier = Modifier.offset(x = OriveoBackButtonDefaults.EdgeInset),
        )
    }
}

@Composable
private fun SearchBar(
    searchValue: String,
    onSearchChange: (String) -> Unit,
    onSearchClear: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    val searchShape = CircleShape

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(36.dp)
            .clip(searchShape)
            .background(v2.bgInset, searchShape)
            .border(1.dp, v2.borderSubtle, searchShape)
            .padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Filled.Search,
            contentDescription = null,
            modifier = Modifier.size(13.dp),
            tint = v2.textTertiary,
        )

        BasicTextField(
            value = searchValue,
            onValueChange = onSearchChange,
            modifier = Modifier.weight(1f),
            singleLine = true,
            textStyle = OriveoTheme.typography.body.copy(
                fontSize = 15.sp,
                color = v2.textPrimary,
            ),
            cursorBrush = SolidColor(v2.primary),
            decorationBox = { innerTextField ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (searchValue.isBlank()) {
                        Text(
                            text = stringResource(R.string.search_models),
                            style = OriveoTheme.typography.body.copy(fontSize = 15.sp),
                            color = v2.textTertiary,
                            maxLines = 1,
                        )
                    }
                    innerTextField()
                }
            },
        )

        if (searchValue.isNotEmpty()) {
            Box(
                modifier = Modifier
                    .size(20.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onSearchClear),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = v2.textTertiary,
                )
            }
        }
    }
}

/**
 * [counts] is null while the counts are still being computed on a background thread. Only a
 * placeholder is drawn then: rendering "Web 0" would read as "none available". The placeholder keeps
 * the row height so the chips appear in place without shifting the layout.
 */
@Composable
private fun ModelPickerCapabilityFilterRow(
    counts: Map<ModelPickerCapabilityFilterKind, Int>?,
    selected: Set<ModelPickerCapabilityFilterKind>,
    onToggle: (ModelPickerCapabilityFilterKind) -> Unit,
    showsRealtime: Boolean,
    realtimeCount: Int,
    realtimeSelected: Boolean,
    onToggleRealtime: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    if (counts == null) {
        Spacer(modifier = Modifier.height(32.dp))
        return
    }
    // The fourth "realtime voice" capsule would be pushed off screen on narrow screens: the whole row scrolls horizontally
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ModelPickerCapabilityFilterKind.entries.forEach { kind ->
            val count = counts[kind] ?: 0
            val isSelected = kind in selected
            val label = stringResource(kind.filterLabelRes, count)
            val stateText = stringResource(
                if (isSelected) R.string.selected_state else R.string.model_control_not_selected,
            )
            Box(
                modifier = Modifier
                    .heightIn(min = 32.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (isSelected) v2.primary else v2.textPrimary.copy(alpha = 0.06f))
                    .clickable(enabled = count > 0) { onToggle(kind) }
                    .padding(horizontal = 12.dp, vertical = 6.dp)
                    .semantics {
                        role = Role.Checkbox
                        contentDescription = label
                        stateDescription = stateText
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = label,
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),

                    color = when {
                        isSelected -> OriveoTheme.colors.textInverse
                        count > 0 -> v2.textPrimary
                        else -> v2.textTertiary
                    },
                    maxLines = 1,
                )
            }
        }
        // The "realtime voice" capsule appears only when this list actually contains realtime rows; the selected state is a solid cyan-purple gradient
        if (showsRealtime) {
            ModelPickerRealtimeFilterChip(
                count = realtimeCount,
                selected = realtimeSelected,
                onToggle = onToggleRealtime,
            )
        }
    }
}

@Composable
private fun CapabilityFilterEmptyState() {
    val v2 = rememberV2PickerColors()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = stringResource(R.string.model_picker_capability_filter_empty),
            style = OriveoTheme.typography.footnote,
            color = v2.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun EmptyModelState() {
    val v2 = rememberV2PickerColors()
    val shape = RoundedCornerShape(18.dp)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .groupedCardSurface(shape, v2, OriveoTheme.isDark)
            .padding(vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.Search,
            contentDescription = null,
            modifier = Modifier.size(22.dp),
            tint = v2.textTertiary,
        )
        Text(
            text = stringResource(R.string.no_matching_models),
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp),
            color = v2.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

internal enum class ModelPickerRowPosition { Single, First, Middle, Last }

internal sealed interface ModelPickerListContent {
    data class ProviderHeader(
        val provider: Provider,
        val modelCount: Int,
        val isExpanded: Boolean,
        val isCollapsible: Boolean,
    ) : ModelPickerListContent

    data class ModelRow(
        val provider: Provider,
        val model: AIModel,
        val groupId: String,
    ) : ModelPickerListContent

    /** Under an official apiKey connection, one row of voice catalog realtime[], listed after that connection's text models. */
    data class RealtimeRow(
        val provider: Provider,
        val entry: VoiceRealtimeEntry,
    ) : ModelPickerListContent

    data class AddModels(val providerId: String) : ModelPickerListContent
    data class Gap(val providerId: String) : ModelPickerListContent
}

internal data class ModelPickerListEntry(
    val key: String,
    val contentType: String,
    val position: ModelPickerRowPosition,
    val content: ModelPickerListContent,
)

internal fun buildModelPickerListEntries(
    providerSections: List<ModelPickerSection>,
    searchText: String,
    expandedProviderIds: Set<String>,
    isSingleProvider: Boolean,
    isHome: Boolean,
    isCrosscheck: Boolean = false,
): List<ModelPickerListEntry> = buildList {
    providerSections.forEach { section ->
        val provider = section.provider
        val providerId = provider.id
        val showHeader = !isSingleProvider || isHome || isCrosscheck
        val isExpanded = !showHeader || searchText.isNotBlank() || providerId in expandedProviderIds
        val rawEntries = buildList<Pair<String, ModelPickerListContent>> {
            if (showHeader) {
                add(
                    "provider/$providerId" to ModelPickerListContent.ProviderHeader(
                        provider = provider,
                        // Count the rows the user can see: text + realtime (same basis as iOS visibleRowCount)
                        modelCount = section.visibleRowCount,
                        isExpanded = isExpanded,
                        isCollapsible = true,
                    ),
                )
            }

            if (isExpanded) {
                val groupId = groupModelPickerModelsByVendor(section.models).firstOrNull()?.id ?: "ungrouped"
                section.models.forEach { model ->
                    add(
                        "provider/$providerId/model/$groupId/${model.id}" to
                            ModelPickerListContent.ModelRow(
                                provider = provider,
                                model = model,
                                groupId = groupId,
                            ),
                    )
                }

                section.realtimeModels.forEach { entry ->
                    add(
                        "provider/$providerId/realtime/${entry.model}" to
                            ModelPickerListContent.RealtimeRow(provider = provider, entry = entry),
                    )
                }

                if (!isCrosscheck && searchText.isBlank() && provider.hasMoreModelsForPicker()) {
                    add(
                        "provider/$providerId/add" to ModelPickerListContent.AddModels(providerId),
                    )
                }
            }
        }

        rawEntries.forEachIndexed { index, (key, content) ->
            val position = when {
                rawEntries.size == 1 -> ModelPickerRowPosition.Single
                index == 0 -> ModelPickerRowPosition.First
                index == rawEntries.lastIndex -> ModelPickerRowPosition.Last
                else -> ModelPickerRowPosition.Middle
            }
            add(
                ModelPickerListEntry(
                    key = key,
                    contentType = content.contentType,
                    position = position,
                    content = content,
                ),
            )
        }
        add(
            ModelPickerListEntry(
                key = "provider/$providerId/gap",
                contentType = "gap",
                position = ModelPickerRowPosition.Single,
                content = ModelPickerListContent.Gap(providerId),
            ),
        )
    }
}

private val ModelPickerListContent.contentType: String
    get() = when (this) {
        is ModelPickerListContent.ProviderHeader -> "provider_header"
        is ModelPickerListContent.ModelRow -> "model_row"
        is ModelPickerListContent.RealtimeRow -> "realtime_row"
        is ModelPickerListContent.AddModels -> "add_models"
        is ModelPickerListContent.Gap -> "gap"
    }

private fun Provider.hasMoreModelsForPicker(): Boolean =
    if (kind == ProviderKind.Relay) {
        catalogModels.size > models.size
    } else {
        kind.isAggregatedProvider
    }

@Composable
private fun ModelPickerListEntryRow(
    positionedEntry: ModelPickerListEntry,
    capabilityObservationRevision: Long,
    toolCallMemoryVerdict: (Provider, AIModel) -> Boolean?,
    modifier: Modifier = Modifier,
    onToggleProvider: (String) -> Unit,
    onSelectModel: (providerId: String, modelId: String) -> Unit,
    onSelectRealtimeModel: (Provider, VoiceRealtimeEntry) -> Unit,
    isModelSelected: (providerId: String, model: AIModel) -> Boolean,
    isRealtimeModelSelected: (providerId: String, modelId: String) -> Boolean,
    onOpenCatalog: (providerId: String) -> Unit,
) {
    val content = positionedEntry.content
    if (content is ModelPickerListContent.Gap) {
        Spacer(modifier = Modifier.height(12.dp))
        return
    }

    val v2 = rememberV2PickerColors()
    Column(
        modifier = modifier
            .fillMaxWidth()
            .modelPickerSegmentSurface(positionedEntry.position, v2),
    ) {
        if (
            positionedEntry.position == ModelPickerRowPosition.Middle ||
            positionedEntry.position == ModelPickerRowPosition.Last
        ) {
            if (content is ModelPickerListContent.ModelRow) {
                IndentedHairline(
                    startIndent = 16.dp,
                )
            } else if (content is ModelPickerListContent.RealtimeRow) {
                IndentedHairline(startIndent = 16.dp)
            } else {
                HairlineDivider()
            }
        }

        when (content) {
            is ModelPickerListContent.ProviderHeader -> ProviderSectionHeader(
                provider = content.provider,
                modelCount = content.modelCount,
                isExpanded = content.isExpanded,
                isCollapsible = content.isCollapsible,
                onToggle = { onToggleProvider(content.provider.id) },
            )
            is ModelPickerListContent.ModelRow -> ModelPickerRow(
                provider = content.provider,
                model = content.model,
                capabilityObservationRevision = capabilityObservationRevision,
                toolCallMemoryVerdict = toolCallMemoryVerdict(content.provider, content.model),
                isSelected = isModelSelected(content.provider.id, content.model),
                onClick = { onSelectModel(content.provider.id, content.model.id) },
            )
            is ModelPickerListContent.RealtimeRow -> ModelPickerRealtimeRow(
                entry = content.entry,
                isSelected = isRealtimeModelSelected(content.provider.id, content.entry.model),
                onClick = { onSelectRealtimeModel(content.provider, content.entry) },
                sentryTag = "model_picker_realtime_model_row",
            )
            is ModelPickerListContent.AddModels -> AddModelsRow(
                onClick = { onOpenCatalog(content.providerId) },
            )
            is ModelPickerListContent.Gap -> Unit
        }
    }
}

private fun Modifier.modelPickerSegmentSurface(
    position: ModelPickerRowPosition,
    v2: V2PickerColors,
): Modifier {
    val shape = when (position) {
        ModelPickerRowPosition.Single -> RoundedCornerShape(16.dp)
        ModelPickerRowPosition.First -> RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp)
        ModelPickerRowPosition.Middle -> RoundedCornerShape(0.dp)
        ModelPickerRowPosition.Last -> RoundedCornerShape(bottomStart = 16.dp, bottomEnd = 16.dp)
    }
    return clip(shape)
        .background(v2.surfaceDefault, shape)
        .drawWithCache {
            val borderWidth = 0.5.dp.toPx()
            onDrawBehind {
                drawLine(v2.borderDefault, Offset.Zero, Offset(0f, size.height), borderWidth)
                drawLine(
                    v2.borderDefault,
                    Offset(size.width, 0f),
                    Offset(size.width, size.height),
                    borderWidth,
                )
                if (position == ModelPickerRowPosition.First || position == ModelPickerRowPosition.Single) {
                    drawLine(v2.borderDefault, Offset.Zero, Offset(size.width, 0f), borderWidth)
                }
                if (position == ModelPickerRowPosition.Last || position == ModelPickerRowPosition.Single) {
                    drawLine(
                        v2.borderDefault,
                        Offset(0f, size.height),
                        Offset(size.width, size.height),
                        borderWidth,
                    )
                }
            }
        }
}

@Composable
private fun ProviderSectionHeader(
    provider: Provider,
    modelCount: Int,
    isExpanded: Boolean,
    isCollapsible: Boolean,
    onToggle: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    val resolvedKind = remember(provider) { resolveProviderLogoKind(provider) }

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val bg by animateColorAsState(
        targetValue = if (isPressed && isCollapsible) v2.textPrimary.copy(alpha = 0.05f) else Color.Transparent,
        animationSpec = tween(120),
        label = "sectionHeaderPress",
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(bg)
            .clickable(
                enabled = isCollapsible,
                interactionSource = interactionSource,
                indication = null,
                onClick = onToggle,
            )
            .heightIn(min = 64.dp)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(30.dp),
            contentAlignment = Alignment.Center,
        ) {
            // Relay connections draw the unified avatar; official and local keep the original logo.
            if (RelayAvatarResolver.appliesTo(provider)) {
                RelayAvatar(provider = provider, size = 28.dp)
            } else {
                ProviderBadgeIcon(kind = resolvedKind, size = 28.dp)
            }
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = provider.displayName,
                style = OriveoTheme.typography.title3.copy(
                    fontSize = 16.sp,
                    lineHeight = 19.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = v2.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = stringResource(R.string.n_models_enabled, modelCount),
                style = OriveoTheme.typography.footnote.copy(
                    fontSize = 12.sp,
                    lineHeight = 14.sp,
                    fontWeight = FontWeight.Medium,
                    fontFeatureSettings = "tnum",
                ),
                color = v2.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (isCollapsible) {
            Box(
                modifier = Modifier.width(14.dp),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (isExpanded) Icons.Filled.ExpandMore else Icons.Filled.ChevronRight,
                    contentDescription = null,
                    // Collapsed points along the reading direction; expanded points down and is not flipped.
                    modifier = Modifier
                        .size(13.dp)
                        .then(if (LocalLayoutDirection.current == LayoutDirection.Rtl && !isExpanded) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
                    tint = v2.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun HairlineDivider() {
    val v2 = rememberV2PickerColors()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(0.5.dp)
            .background(v2.borderSubtle),
    )
}

@Composable
private fun IndentedHairline(startIndent: Dp = 56.dp) {
    val v2 = rememberV2PickerColors()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = startIndent)
            .height(0.5.dp)
            .background(v2.borderSubtle),
    )
}

@Composable
private fun AddModelsRow(onClick: () -> Unit) {
    val v2 = rememberV2PickerColors()
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val bg by animateColorAsState(
        targetValue = if (isPressed) v2.textPrimary.copy(alpha = 0.05f) else Color.Transparent,
        animationSpec = tween(120),
        label = "addRowPress",
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(bg)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(v2.primarySubtle, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Add,
                contentDescription = null,
                modifier = Modifier.size(13.dp),
                tint = v2.primary,
            )
        }
        Text(
            text = stringResource(R.string.add_models),
            style = OriveoTheme.typography.body.copy(
                fontSize = 15.sp,
                lineHeight = 18.sp,
                fontWeight = FontWeight.Medium,
            ),
            color = v2.primary,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Icon(
            imageVector = Icons.Filled.ChevronRight,
            contentDescription = null,
            modifier = Modifier
                .size(11.dp)
                .then(if (LocalLayoutDirection.current == LayoutDirection.Rtl) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
            tint = v2.textTertiary,
        )
    }
}

@Composable
private fun ModelPickerRow(
    provider: Provider,
    model: AIModel,
    capabilityObservationRevision: Long,
    toolCallMemoryVerdict: Boolean?,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    // Unit price label picks the price by the connection's effective region (same entry point as delivered-cost billing)
    val priceLocale = rememberCostLocale()
    val pricing = remember(connectionPriceLabelKey(provider, model), priceLocale) {
        val priced = model.pricedForConnection(provider)
        priced.model.modelPickerPricePresentation(priced.currencyCode, priceLocale)
    }
    val rawTitle = model.modelPickerDisplayTitle()
    // Separator breakpoints for display only; screen readers use the original title
    val title = modelIdDisplay(rawTitle)
    val contextLengthLabel = remember(model.contextLength) {
        formatModelPickerContextLength(model.contextLength)
    }
    val sourceName = model.groupName
        ?.trim()
        ?.takeIf {
            shouldShowModelPickerVendorSource(provider) &&
                it.isNotEmpty() &&
                it != provider.displayName
        }
    val visibleCapabilities = remember(provider, model, capabilityObservationRevision, toolCallMemoryVerdict) {
        model.copy(
            capabilities = CapabilityEvidenceProductionAdapter
                .governedMetadataCapabilities(provider, model)
                .toList(),
        ).visibleMetadataCapabilities(
            // Same limit as the provider detail "added models" row: both places must show the same badges.
            maxCapabilities = MODEL_ROW_MAX_CAPABILITIES,
            modelFactsToolCall = CapabilityEvidenceProductionAdapter.toolCallVerdict(
                provider,
                model,
                memoryVerdict = toolCallMemoryVerdict,
            ),
        )
    }

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()

    val tintAlpha = if (isSelected) 0.08f else 0f
    val pressOverlayAlpha by animateFloatAsState(
        targetValue = if (isPressed) 0.04f else 0f,
        animationSpec = tween(140),
        label = "pressOverlay",
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("model_picker_row")
            .semantics { selected = isSelected }
            .graphicsLayer { alpha = if (model.isAvailable) 1f else 0.68f }
            .background(v2.primary.copy(alpha = tintAlpha))
            .background(v2.textPrimary.copy(alpha = pressOverlayAlpha))
            .clickable(
                enabled = model.isAvailable,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = 16.dp,
                    end = 16.dp,
                    top = 13.dp,
                    bottom = 13.dp,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = title,
                    modifier = Modifier.semantics { contentDescription = rawTitle },
                    style = OriveoTheme.typography.title3.copy(
                        fontSize = 15.sp,
                        lineHeight = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                    ),
                    color = v2.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (sourceName != null || visibleCapabilities.isNotEmpty()) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (sourceName != null) {
                            Text(
                                text = sourceName,
                                style = OriveoTheme.typography.footnote.copy(
                                    fontSize = 12.sp,
                                    lineHeight = 14.sp,
                                    fontWeight = FontWeight.Medium,
                                ),
                                color = v2.textTertiary,
                                modifier = Modifier.weight(1f, fill = false),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        FixedHeroModelCapabilityStrip(
                            capabilities = visibleCapabilities,
                            compact = true,
                        )
                    }
                }
                ModelPickerPriceRow(
                    pricing = pricing,
                    contextLengthLabel = contextLengthLabel,
                    v2 = v2,
                )
            }

            Box(modifier = Modifier.size(18.dp), contentAlignment = Alignment.Center) {
                if (isSelected) {
                    Icon(
                        imageVector = Icons.Filled.CheckCircle,
                        contentDescription = null,
                        modifier = Modifier.size(17.dp),
                        tint = v2.primary,
                    )
                }
            }
        }
    }
}

internal fun formatModelPickerContextLength(tokens: Int?): String? {
    if (tokens == null || tokens <= 0) return null
    if (tokens >= 1_000_000) {
        val millions = tokens.toDouble() / 1_000_000
        if (millions >= 10) return "${millions.roundToInt()}M"
        val rounded = (millions * 10).roundToInt() / 10.0
        return if (rounded == rounded.roundToInt().toDouble()) {
            "${rounded.roundToInt()}M"
        } else {
            "${"%.1f".format(Locale.US, rounded)}M"
        }
    }
    if (tokens >= 1_000) return "${(tokens.toDouble() / 1_000).roundToInt()}K"
    return tokens.toString()
}

internal data class ModelPickerPricePresentation(
    val input: String?,
    val output: String?,
    val fallback: String?,
)

internal fun AIModel.modelPickerPricePresentation(
    currencyCode: String = DeliveredCostResolver.USD,
    locale: Locale = Locale.getDefault(),
): ModelPickerPricePresentation {
    val hasStructuredPricing = promptPrice != null || completionPrice != null
    if (pricingUnit == "per_token" && hasStructuredPricing) {
        if (promptPrice == 0.0 && completionPrice == 0.0) {
            return ModelPickerPricePresentation(input = null, output = null, fallback = "Free")
        }
        return ModelPickerPricePresentation(
            input = promptPrice?.let { ModelPricingFormatter.formatPerMillionValue(it, currencyCode, locale) },
            output = completionPrice?.let { ModelPricingFormatter.formatPerMillionValue(it, currencyCode, locale) },
            fallback = null,
        )
    }

    return ModelPickerPricePresentation(
        input = null,
        output = null,
        fallback = normalizedPriceTier(currencyCode, locale).takeIf(String::isNotBlank),
    )
}

@Composable
private fun ModelPickerPriceRow(
    pricing: ModelPickerPricePresentation,
    contextLengthLabel: String?,
    v2: V2PickerColors,
) {
    val hasPricing = pricing.input != null || pricing.output != null || pricing.fallback != null
    if (contextLengthLabel == null && !hasPricing) return

    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (contextLengthLabel != null) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Memory,
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                    tint = v2.textTertiary,
                )
                Text(
                    text = contextLengthLabel,
                    style = OriveoTheme.typography.footnote.copy(
                        fontSize = 11.sp,
                        lineHeight = 13.sp,
                        fontWeight = FontWeight.Medium,
                        fontFeatureSettings = "tnum",
                    ),
                    color = v2.textTertiary,
                    maxLines = 1,
                )
            }
        }
        if (contextLengthLabel != null && hasPricing) {
            Box(
                modifier = Modifier
                    .size(3.dp)
                    .background(v2.textTertiary.opacity(0.45f), CircleShape),
            )
        }
        if (pricing.input != null || pricing.output != null) {
            FlowRow(
                modifier = if (contextLengthLabel != null) {
                    Modifier.weight(1f, fill = false)
                } else {
                    Modifier
                },
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                pricing.input?.let { value ->
                    ModelPickerPriceItem(
                        label = stringResource(R.string.price_input),
                        value = value,
                        v2 = v2,
                    )
                }
                pricing.output?.let { value ->
                    ModelPickerPriceItem(
                        label = stringResource(R.string.price_output),
                        value = value,
                        v2 = v2,
                    )
                }
            }
        } else if (pricing.fallback != null) {
            Text(

                text = localizedPriceTier(pricing.fallback),
                style = OriveoTheme.typography.footnote.copy(
                    fontSize = 11.sp,
                    lineHeight = 13.sp,
                    fontWeight = FontWeight.Medium,
                    fontFeatureSettings = "tnum",
                ),
                color = v2.textTertiary,
                modifier = if (contextLengthLabel != null) {
                    Modifier.weight(1f, fill = false)
                } else {
                    Modifier
                },
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun ModelPickerPriceItem(
    label: String,
    value: String,
    v2: V2PickerColors,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.footnote.copy(fontSize = 11.sp, lineHeight = 13.sp),
            color = v2.textTertiary,
            maxLines = 1,
        )
        Text(
            text = value,
            style = OriveoTheme.typography.footnote.copy(
                fontSize = 11.sp,
                lineHeight = 13.sp,
                fontWeight = FontWeight.SemiBold,
                fontFeatureSettings = "tnum",
            ),
            color = v2.textSecondary,
            maxLines = 1,
        )
    }
}

fun buildProviderSections(
    context: ModelPickerContext,
    providers: List<Provider>,
    currentProviderId: String?,
    currentModel: AIModel?,
    searchText: String,
    realtimeCatalog: VoiceCatalog? = null,
): List<ModelPickerSection> {
    val query = searchText.trim()
    val isHome = context == ModelPickerContext.Home

    return providers.mapNotNull { provider ->
        val candidateModels = if (isHome) {
            sortedEnabledModels(provider)
        } else {
            buildList {
                if (
                    provider.id == currentProviderId &&
                    currentModel != null &&
                    provider.models.none { it.id == currentModel.id }
                ) {
                    add(currentModel)
                }
                addAll(provider.models)
            }
        }
            .filter { model -> isModelTransportSupportedForModelPicker(provider, model) }
            .filter { model ->
                // Retired models are hidden (missing stays visible); the current conversation model is kept in Chat.
                val isCurrentConversationModel = !isHome &&
                    provider.id == currentProviderId &&
                    currentModel != null &&
                    model.id == currentModel.id
                isCurrentConversationModel || !isModelRetiredForModelPicker(provider, model)
            }

        val models = candidateModels
            .filter { model ->
                query.isBlank() ||
                    model.name.contains(query, ignoreCase = true) ||
                    model.id.contains(query, ignoreCase = true) ||
                    provider.displayName.contains(query, ignoreCase = true) ||
                    (model.groupName?.contains(query, ignoreCase = true) == true) ||
                    (model.groupKey?.contains(query, ignoreCase = true) == true) ||
                    (model.summary?.contains(query, ignoreCase = true) == true)
            }
            .let { filteredModels ->

                if (isHome || provider.kind.usesServerOrderedModels) {
                    filteredModels
                } else {
                    filteredModels.sortedWith { lhs, rhs ->
                        comparePickerModels(lhs, rhs, ignoreDefault = provider.kind == ProviderKind.Relay)
                    }
                }
            }

        val realtimeModels = modelPickerRealtimeEntries(context, provider, realtimeCatalog)
            .filter { entry ->
                query.isBlank() ||
                    entry.model.contains(query, ignoreCase = true) ||
                    provider.displayName.contains(query, ignoreCase = true)
            }

        if (realtimeModels.isNotEmpty() || shouldRenderModelPickerProviderSection(provider, query, models)) {
            ModelPickerSection(
                provider = provider,
                models = models,
                realtimeModels = realtimeModels,
            )
        } else {
            null
        }
    }
}

fun shouldRenderModelPickerProviderSection(
    provider: Provider,
    query: String,
    models: List<AIModel>,
): Boolean =
    models.isNotEmpty() || (query.isBlank() && provider.canAddModelsInModelPicker())

/**
 * The realtime rows this connection lists in the picker (catalog realtime[] x official apiKey connections; Crosscheck does not list them);
 * ordering and visibility all go through [RealtimeModel.pickerRows]: isDefault first, the rest in catalog order.
 */
internal fun modelPickerRealtimeEntries(
    context: ModelPickerContext,
    provider: Provider,
    catalog: VoiceCatalog?,
): List<VoiceRealtimeEntry> {
    val entries = catalog?.entries(provider.kind, VoiceDirection.Realtime)
        ?.filterIsInstance<VoiceRealtimeEntry>()
        .orEmpty()
    if (entries.isEmpty()) return emptyList()
    val pickerContext = when (context) {
        ModelPickerContext.Home -> RealtimeModel.CONTEXT_HOME
        ModelPickerContext.Chat -> RealtimeModel.CONTEXT_CHAT
        ModelPickerContext.Crosscheck -> RealtimeModel.CONTEXT_CROSSCHECK
    }
    val rows = RealtimeModel.pickerRows(
        context = pickerContext,
        connections = listOf(
            RealtimeModel.Connection(
                id = provider.id,
                providerKind = provider.kind.rawValue,
                auth = RealtimeModel.connectionAuth(provider.kind, provider.authMode),
            ),
        ),
        realtimeCatalog = mapOf(
            provider.kind.rawValue to entries.map { RealtimeModel.RealtimeCatalogEntry(it.model, it.isDefault) },
        ),
    ).groups.flatMap { it.rows }
    val byModel = entries.associateBy { it.model }
    return rows.mapNotNull { row -> byModel[row.model] }
}

/**
 * The output of one sheet recomputation. Group results and chip counts must come from the same input and the same computation,
 * one count with one filter is exactly the source of "358 on screen, 12 after tapping in".
 */
internal data class ModelPickerSectionsResult(
    val providerSections: List<ModelPickerSection>,
    val capabilityFilterCounts: Map<ModelPickerCapabilityFilterKind, Int>,
    /** The "realtime voice" capsule appears only when this list (before filtering) has realtime rows. */
    val showsRealtimeFilter: Boolean = false,
    /** Hit count of the "realtime voice" capsule = total realtime rows before filtering. */
    val realtimeFilterCount: Int = 0,
)

/**
 * The whole grouping, capability counting and capability filtering chain as a pure function, so it can
 * move to a background thread as one piece.
 *
 * It runs [modelPickerCapabilityBadges] for every model, which goes through metadata resolution and
 * capability control resolution; with 700+ models that took 719ms in a single frame on a low-end
 * phone, and because the search text is an input it reran in full on every keystroke. Nothing in it
 * reads Compose state or Android resources and every input is immutable, so the result is the same on
 * the main thread and on Dispatchers.Default.
 *
 * `providers` must already be sorted: the sort key (the provider set) does not depend on search or
 * filters, and keeping it in the caller's remember keeps the expansion effect's keys stable while
 * searching.
 */
internal fun buildModelPickerSectionsResult(
    context: ModelPickerContext,
    providers: List<Provider>,
    activeProviderId: String?,
    currentModel: AIModel?,
    searchText: String,
    selectedCapabilityFilters: Set<ModelPickerCapabilityFilterKind>,
    realtimeCatalog: VoiceCatalog? = null,
    realtimeFilterSelected: Boolean = false,
): ModelPickerSectionsResult {
    val unfiltered = buildProviderSections(
        context = context,
        providers = providers,
        currentProviderId = activeProviderId,
        currentModel = currentModel,
        searchText = searchText,
        realtimeCatalog = realtimeCatalog,
    )
    return ModelPickerSectionsResult(
        providerSections = applyModelPickerCapabilityFilter(
            unfiltered,
            selectedCapabilityFilters,
            realtimeSelected = realtimeFilterSelected,
        ),
        capabilityFilterCounts = modelPickerCapabilityFilterCounts(unfiltered),
        showsRealtimeFilter = unfiltered.any { it.realtimeModels.isNotEmpty() },
        realtimeFilterCount = modelPickerRealtimeFilterCount(unfiltered),
    )
}

fun defaultExpandedModelPickerProviderIds(
    providers: List<Provider>,
    selectedProviderId: String? = null,
): Set<String> {
    if (selectedProviderId != null && providers.any { it.id == selectedProviderId }) {
        return setOf(selectedProviderId)
    }
    return providers.firstOrNull()?.let { setOf(it.id) } ?: emptySet()
}

private fun Provider.canAddModelsInModelPicker(): Boolean =
    if (kind == ProviderKind.Relay) {
        catalogModels.size > models.size
    } else {
        kind.isAggregatedProvider
    }

internal fun isModelSelected(
    context: ModelPickerContext,
    selectedRealtimeModelId: String?,
    activeProviderId: String?,
    activeModelId: String?,
    currentModelId: String?,
    providerId: String,
    providerKind: ProviderKind?,
    model: AIModel,
): Boolean {
    // A realtime row is selected: text rows are never checked
    if (selectedRealtimeModelId != null) return false
    return when (context) {
        ModelPickerContext.Home -> {
            providerId == activeProviderId &&
                activeModelId == ModelSelectionUtils.preferredStoredModelIdentifier(model, providerKind)
        }

        ModelPickerContext.Chat,
        ModelPickerContext.Crosscheck -> {
            providerId == activeProviderId && model.id == currentModelId
        }
    }
}

/** Realtime rows are checked by providerId + catalog model (realtime models are not in the enabled list, so they do not go through the stored-value lookup). */
internal fun isModelSelected(
    activeProviderId: String?,
    activeModelId: String?,
    providerId: String,
    realtimeModelId: String,
): Boolean = providerId == activeProviderId && activeModelId?.trim() == realtimeModelId

/**
 * The selected-row judgment shared by both row kinds (isomorphic to RealtimeModel.pickerRows' selectedRow): when the selection is on a realtime row listed by the active connection,
 * and that connection has no text row with the same id (text rows come first and match first), return that realtime model; otherwise null, and judge by text rows. Null while the catalog is not ready.
 */
internal fun modelPickerSelectedRealtimeModel(
    context: ModelPickerContext,
    activeProvider: Provider?,
    activeModelId: String?,
    catalog: VoiceCatalog?,
): String? {
    val provider = activeProvider ?: return null
    val target = activeModelId?.trim().orEmpty()
    if (target.isEmpty() || provider.models.any { it.id == target }) return null
    return modelPickerRealtimeEntries(context, provider, catalog)
        .firstOrNull { isModelSelected(provider.id, activeModelId, provider.id, it.model) }
        ?.model
}

/** Tapping a text row: select that model and then collapse the picker (tap to select closes it). */
internal fun selectModelAndDismiss(
    providerId: String,
    modelId: String,
    select: (providerId: String, modelId: String) -> Unit,
    dismiss: () -> Unit,
) {
    select(providerId, modelId)
    dismiss()
}

/** The realtime model selection that is waiting for the cloud disclosure conclusion. */
data class RealtimePickerDisclosure(
    val providerId: String,
    val providerKind: ProviderKind,
    val modelId: String,
)

/**
 * Selecting a realtime row: if this provider's Realtime direction was already accepted -> [select] directly and return null;
 * if not accepted -> do not select, return the pending selection, and the caller shows VoiceDisclosureSheet.
 */
internal fun pickRealtimeModel(
    providerId: String,
    providerKind: ProviderKind,
    modelId: String,
    store: VoiceDisclosureStore,
    select: (providerId: String, modelId: String) -> Unit,
): RealtimePickerDisclosure? {
    if (!store.isAccepted(providerKind, VoiceDirection.Realtime)) {
        return RealtimePickerDisclosure(providerId, providerKind, modelId)
    }
    select(providerId, modelId)
    return null
}

/**
 * Tapping a realtime row collapses the picker: if already accepted -> select first, then collapse;
 * if not accepted -> do not select, collapse first, then [requestDisclosure], and the page shows the disclosure.
 */
internal fun pickRealtimeModelAndDismiss(
    providerId: String,
    providerKind: ProviderKind,
    modelId: String,
    store: VoiceDisclosureStore,
    select: (providerId: String, modelId: String) -> Unit,
    dismiss: () -> Unit,
    requestDisclosure: (RealtimePickerDisclosure) -> Unit,
) {
    val pending = pickRealtimeModel(providerId, providerKind, modelId, store, select)
    dismiss()
    pending?.let(requestDisclosure)
}

/** The user tapped accept on the disclosure: record consent first, then select. Rejecting calls nothing. */
internal fun acceptRealtimeDisclosure(
    pending: RealtimePickerDisclosure,
    store: VoiceDisclosureStore,
    select: (providerId: String, modelId: String) -> Unit,
) {
    store.markAccepted(pending.providerKind, VoiceDirection.Realtime)
    select(pending.providerId, pending.modelId)
}

private fun Set<String>.toggle(value: String): Set<String> {
    return if (contains(value)) this - value else this + value
}

data class ModelPickerSection(
    val provider: Provider,
    val models: List<AIModel>,
    /** Realtime voice models this connection lists after its text models (catalog order, isDefault first). */
    val realtimeModels: List<VoiceRealtimeEntry> = emptyList(),
) {
    /** Group header "N models": the number of rows currently shown for this group (text + realtime). */
    val visibleRowCount: Int get() = models.size + realtimeModels.size
}

/** Home header "N providers · M models"; both come from the same (filtered / searched) groups. */
internal data class ModelPickerHomeHeaderCounts(
    val providerCount: Int,
    val modelCount: Int,
)

internal fun modelPickerHomeHeaderCounts(sections: List<ModelPickerSection>): ModelPickerHomeHeaderCounts =
    ModelPickerHomeHeaderCounts(
        providerCount = sections.size,
        modelCount = sections.sumOf { it.visibleRowCount },
    )

data class ModelPickerVendorGroup(
    val id: String,
    val name: String,
    val models: List<AIModel>,
)

fun groupModelPickerModelsByVendor(models: List<AIModel>): List<ModelPickerVendorGroup> {
    data class MutableVendorGroup(
        val name: String,
        val models: MutableList<AIModel>,
    )

    val groups = linkedMapOf<String, MutableVendorGroup>()
    models.forEach { model ->
        val rawKey = model.groupKey?.trim().orEmpty()
        val key = rawKey.ifEmpty { "__ungrouped__" }
        val name = model.groupName?.trim().orEmpty().ifEmpty { rawKey.ifEmpty { "Other" } }
        groups.getOrPut(key) { MutableVendorGroup(name, mutableListOf()) }.models += model
    }
    return groups.map { (id, group) ->
        ModelPickerVendorGroup(id = id, name = group.name, models = group.models.toList())
    }
}

fun AIModel.modelPickerDisplayTitle(): String {
    var title = name.trim()
    val vendorName = groupName?.trim().orEmpty()
    if (vendorName.isNotEmpty()) {
        val prefix = "$vendorName: "
        if (title.startsWith(prefix, ignoreCase = true)) {
            title = title.drop(prefix.length).trim()
        }
    }
    if (title.endsWith(" (free)", ignoreCase = true)) {
        title = title.dropLast(" (free)".length).trim()
    }
    return title.ifBlank { name }
}

fun shouldShowModelPickerVendorSource(provider: Provider): Boolean =
    provider.kind.isAggregatedProvider

fun isModelRetiredForModelPicker(provider: Provider, model: AIModel): Boolean =
    ProviderSelectionSnapshot.modelRetirement(provider, model.id)?.status == ModelRetirement.Status.Retired

fun isModelTransportSupportedForModelPicker(provider: Provider, model: AIModel): Boolean {
    if (provider.kind == ProviderKind.Relay) {
        return true
    }
    val rawTransport = MetadataClient.resolveCatalogModel(model.id, provider.kind)
        ?.transport
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: return true
    return TransportKind.fromWireValue(rawTransport) != null
}

/** Attribution name of each capability filter chip for analytics, hard-coded one by one and not built from [ModelPickerCapabilityFilterKind.owner] (the tag is a primary key in live data). */
private fun capabilityFilterSentryTag(kind: ModelPickerCapabilityFilterKind): String = when (kind) {
    ModelPickerCapabilityFilterKind.Web -> "model_picker_filter_web_option"
    ModelPickerCapabilityFilterKind.Reasoning -> "model_picker_filter_reasoning_option"
}

/**
 * Realtime voice model row, minimum 64dp. A 36dp cyan-purple gradient rounded block with a waveform on the left; the name is the catalog model, at most two lines;
 * the subtitle is "Realtime voice"; no capability badge and no price; the selected mark matches text rows (primary-colored CheckCircle).
 * The Settings > Voice "realtime voice" group reuses this row: the subtitle appends " · connection name", and the testTag / tap attribution is supplied separately.
 */
@Composable
internal fun ModelPickerRealtimeRow(
    entry: VoiceRealtimeEntry,
    isSelected: Boolean,
    onClick: () -> Unit,
    connectionName: String? = null,
    tag: String = "model_picker_realtime_row",
    sentryTag: String = "model_picker_realtime_model_row",
) {
    val v2 = rememberV2PickerColors()
    val tileStops = listOf(DetailRowPalette.cyan, CapabilityPalette.reasoning)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .testTag(tag)
            .semantics { selected = isSelected }
            .background(v2.primary.copy(alpha = if (isSelected) 0.08f else 0f))
            
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Brush.linearGradient(tileStops)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Rounded.GraphicEq,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = Color.White,
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = modelIdDisplay(entry.model),
                modifier = Modifier.semantics { contentDescription = entry.model },
                style = OriveoTheme.typography.title3.copy(
                    fontSize = 16.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = v2.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = listOfNotNull(stringResource(R.string.voice_realtime_model_subtitle), connectionName)
                    .joinToString(" · "),
                style = OriveoTheme.typography.footnote.copy(fontSize = 13.sp, lineHeight = 16.sp),
                color = v2.textSecondary,
                maxLines = 1,
            )
        }
        Box(modifier = Modifier.size(18.dp), contentAlignment = Alignment.Center) {
            if (isSelected) {
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = null,
                    modifier = Modifier.size(17.dp),
                    tint = v2.primary,
                )
            }
        }
    }
}

/** The "realtime voice" filter capsule; the selected state is a solid cyan-purple gradient, and unselected matches the capability chips' background color. */
@Composable
private fun ModelPickerRealtimeFilterChip(
    count: Int,
    selected: Boolean,
    onToggle: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    // Like the capability chips, it carries a hit count (count = total realtime rows before filtering)
    val label = stringResource(R.string.voice_realtime_filter_count, count)
    val stateText = stringResource(
        if (selected) R.string.selected_state else R.string.model_control_not_selected,
    )
    val fill = if (selected) {
        Brush.linearGradient(listOf(DetailRowPalette.cyan, CapabilityPalette.reasoning))
    } else {
        SolidColor(v2.textPrimary.copy(alpha = 0.06f))
    }
    Box(
        modifier = Modifier
            .heightIn(min = 32.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(fill)
            
            .clickable { onToggle() }
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .semantics {
                role = Role.Checkbox
                contentDescription = label
                stateDescription = stateText
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),
            color = if (selected) Color.White else v2.textPrimary,
            maxLines = 1,
        )
    }
}
