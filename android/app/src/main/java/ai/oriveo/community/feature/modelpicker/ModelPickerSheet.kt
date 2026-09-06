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
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.resolveProviderLogoKind
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ModelPricingFormatter
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.feature.providers.detail.comparePickerModels
import ai.oriveo.community.feature.providers.detail.sortedEnabledModels
import ai.oriveo.community.feature.providers.detail.sortedProvidersForModelPicker
import ai.oriveo.community.ui.component.FixedHeroModelCapabilityStrip
import ai.oriveo.community.ui.component.ModelVendorIcon
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.localizedPriceTier
import ai.oriveo.community.ui.component.normalizedPriceTier
import ai.oriveo.community.ui.component.visibleMetadataCapabilities
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.OriveoV2ScreenBackground
import ai.oriveo.community.ui.theme.opacity
import java.util.Locale
import kotlin.math.roundToInt
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
) {
    val isHome = context == ModelPickerContext.Home
    val isCrosscheck = context == ModelPickerContext.Crosscheck
    var searchText by remember { mutableStateOf("") }
    var expandedProviderIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var expandedVendorGroupIds by remember { mutableStateOf<Map<String, Set<String>>>(emptyMap()) }
    var catalogProviderId by remember { mutableStateOf<String?>(null) }

    val currentProvider = remember(providers, activeProviderId) {
        providers.firstOrNull { it.id == activeProviderId }
    }
    val currentModel = remember(currentProvider, activeModelId) {
        activeModelId?.let { modelId ->
            currentProvider?.allModels?.let { allModels ->
                ModelSelectionUtils.matchingModel(allModels, modelId)
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
    val unfilteredProviderSections = remember(
        sortedProviders,
        searchText,
        isHome,
        activeProviderId,
        currentModel,
    ) {
        buildProviderSections(
            context = context,
            providers = sortedProviders,
            currentProviderId = activeProviderId,
            currentModel = currentModel,
            searchText = searchText,
        )
    }

    var selectedCapabilityFilters by remember {
        mutableStateOf<Set<ModelPickerCapabilityFilterKind>>(emptySet())
    }

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

    val capabilityFilterCounts = remember(
        unfilteredProviderSections,
        capabilityObservationRevision,
        toolCallMemoryRevision,
    ) {
        modelPickerCapabilityFilterCounts(unfilteredProviderSections, toolCallMemoryVerdict = toolCallMemoryVerdict)
    }
    val providerSections = remember(
        unfilteredProviderSections,
        selectedCapabilityFilters,
        capabilityObservationRevision,
        toolCallMemoryRevision,
    ) {
        applyModelPickerCapabilityFilter(
            unfilteredProviderSections,
            selectedCapabilityFilters,
            toolCallMemoryVerdict = toolCallMemoryVerdict,
        )
    }
    LaunchedEffect(expansionSignature, isHome, activeProviderId, sortedProviders) {
        expandedProviderIds = defaultExpandedModelPickerProviderIds(
            providers = sortedProviders,
            selectedProviderId = activeProviderId,
        )
    }

    LaunchedEffect(providerSections, activeProviderId, currentModelId) {
        expandedVendorGroupIds = buildMap {
            providerSections.forEach { section ->
                if (section.provider.kind != ProviderKind.OpenAI) return@forEach
                val groups = groupModelPickerModelsByVendor(section.models)
                if (groups.size <= 1) return@forEach
                val availableIds = groups.mapTo(linkedSetOf()) { it.id }
                val existing = expandedVendorGroupIds[section.provider.id]
                    .orEmpty()
                    .intersect(availableIds)
                    .toMutableSet()
                if (section.provider.id == activeProviderId && currentModelId != null) {
                    groups.firstOrNull { group -> group.models.any { it.id == currentModelId } }
                        ?.let { existing += it.id }
                }
                put(section.provider.id, existing)
            }
        }
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
                    capabilityFilterCounts = capabilityFilterCounts,
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
                    expandedVendorGroupIds = expandedVendorGroupIds,
                    onToggleProvider = { providerId ->
                        if (searchText.isBlank()) {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            expandedProviderIds = expandedProviderIds.toggle(providerId)
                        }
                    },
                    onToggleVendorGroup = { providerId, groupId ->
                        if (searchText.isBlank()) {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            val current = expandedVendorGroupIds[providerId].orEmpty()
                            expandedVendorGroupIds = expandedVendorGroupIds +
                                (providerId to current.toggle(groupId))
                        }
                    },
                    onSelectModel = { providerId, modelId ->
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        onModelSelected(providerId, modelId)
                    },
                    isModelSelected = { providerId, model ->
                        isModelSelected(
                            context = context,
                            activeProviderId = activeProviderId,
                            activeModelId = activeModelId,
                            currentModelId = currentModelId,
                            providerId = providerId,
                            model = model,
                        )
                    },
                    onOpenCatalog = { providerId -> catalogProviderId = providerId },
                    isSingleProvider = providers.size == 1,
                    isCrosscheck = isCrosscheck,
                    onDismiss = onDismiss,
                    providerCount = providers.size,
                    modelCountTotal = remember(providers) { providers.sumOf { it.models.size } },
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
    capabilityFilterCounts: Map<ModelPickerCapabilityFilterKind, Int>,
    selectedCapabilityFilters: Set<ModelPickerCapabilityFilterKind>,
    onToggleCapabilityFilter: (ModelPickerCapabilityFilterKind) -> Unit,
    searchText: String,
    onSearchChange: (String) -> Unit,
    onSearchClear: () -> Unit,
    expandedProviderIds: Set<String>,
    expandedVendorGroupIds: Map<String, Set<String>>,
    onToggleProvider: (String) -> Unit,
    onToggleVendorGroup: (providerId: String, groupId: String) -> Unit,
    onSelectModel: (providerId: String, modelId: String) -> Unit,
    isModelSelected: (providerId: String, model: AIModel) -> Boolean,
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
    val entries = remember(
        providerSections,
        searchText,
        expandedProviderIds,
        expandedVendorGroupIds,
        isSingleProvider,
        isHome,
        isCrosscheck,
    ) {
        buildModelPickerListEntries(
            providerSections = providerSections,
            searchText = searchText,
            expandedProviderIds = expandedProviderIds,
            expandedVendorGroupIds = expandedVendorGroupIds,
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
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                }
            }

            if (providerSections.isEmpty()) {

                item(key = "empty") {
                    if (selectedCapabilityFilters.isEmpty()) {
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
                        onToggleVendorGroup = onToggleVendorGroup,
                        onSelectModel = onSelectModel,
                        isModelSelected = isModelSelected,
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

        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(v2.bgInset, CircleShape)
                .border(1.dp, v2.borderSubtle, CircleShape)
                .clickable(onClick = onDismiss),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = stringResource(R.string.cancel),
                modifier = Modifier.size(12.dp),
                tint = v2.textSecondary,
            )
        }
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

@Composable
private fun ModelPickerCapabilityFilterRow(
    counts: Map<ModelPickerCapabilityFilterKind, Int>,
    selected: Set<ModelPickerCapabilityFilterKind>,
    onToggle: (ModelPickerCapabilityFilterKind) -> Unit,
) {
    val v2 = rememberV2PickerColors()
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
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

    data class VendorHeader(
        val providerId: String,
        val group: ModelPickerVendorGroup,
        val isExpanded: Boolean,
    ) : ModelPickerListContent

    data class ModelRow(
        val provider: Provider,
        val model: AIModel,
        val groupId: String,
        val isNestedUnderVendor: Boolean,
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
    expandedVendorGroupIds: Map<String, Set<String>>,
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
                        modelCount = section.models.size,
                        isExpanded = isExpanded,
                        isCollapsible = true,
                    ),
                )
            }

            if (isExpanded) {
                val groups = groupModelPickerModelsByVendor(section.models)

                if (groups.size > 1 && provider.kind == ProviderKind.OpenAI) {
                    groups.forEach { group ->
                        val groupExpanded = searchText.isNotBlank() ||
                            expandedVendorGroupIds[providerId].orEmpty().contains(group.id)
                        add(
                            "provider/$providerId/vendor/${group.id}" to
                                ModelPickerListContent.VendorHeader(providerId, group, groupExpanded),
                        )
                        if (groupExpanded) {
                            group.models.forEach { model ->
                                add(
                                    "provider/$providerId/vendor/${group.id}/model/${model.id}" to
                                        ModelPickerListContent.ModelRow(
                                            provider = provider,
                                            model = model,
                                            groupId = group.id,
                                            isNestedUnderVendor = true,
                                        ),
                                )
                            }
                        }
                    }
                } else {
                    val groupId = groups.firstOrNull()?.id ?: "ungrouped"
                    section.models.forEach { model ->
                        add(
                            "provider/$providerId/model/$groupId/${model.id}" to
                                ModelPickerListContent.ModelRow(
                                    provider = provider,
                                    model = model,
                                    groupId = groupId,
                                    isNestedUnderVendor = false,
                                ),
                        )
                    }
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
        is ModelPickerListContent.VendorHeader -> "vendor_header"
        is ModelPickerListContent.ModelRow -> "model_row"
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
    onToggleVendorGroup: (providerId: String, groupId: String) -> Unit,
    onSelectModel: (providerId: String, modelId: String) -> Unit,
    isModelSelected: (providerId: String, model: AIModel) -> Boolean,
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
                    startIndent = if (content.isNestedUnderVendor) 52.dp else 16.dp,
                )
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
            is ModelPickerListContent.VendorHeader -> ModelPickerVendorGroupHeader(
                group = content.group,
                isExpanded = content.isExpanded,
                onToggle = { onToggleVendorGroup(content.providerId, content.group.id) },
            )
            is ModelPickerListContent.ModelRow -> ModelPickerRow(
                provider = content.provider,
                model = content.model,
                capabilityObservationRevision = capabilityObservationRevision,
                toolCallMemoryVerdict = toolCallMemoryVerdict(content.provider, content.model),
                isNestedUnderVendor = content.isNestedUnderVendor,
                isSelected = isModelSelected(content.provider.id, content.model),
                onClick = { onSelectModel(content.provider.id, content.model.id) },
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
    val resolvedRelay: RelayKind? =
        if (provider.kind == ProviderKind.Relay && resolvedKind == ProviderKind.Relay) provider.relayKind else null

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
            ProviderBadgeIcon(
                kind = resolvedKind,
                size = 28.dp,
                relayKind = resolvedRelay,
            )
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
                    modifier = Modifier.size(13.dp),
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
            modifier = Modifier.size(11.dp),
            tint = v2.textTertiary,
        )
    }
}

@Composable
private fun ModelPickerVendorGroupHeader(
    group: ModelPickerVendorGroup,
    isExpanded: Boolean,
    onToggle: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(v2.bgInset.copy(alpha = 0.32f))
            .clickable(onClick = onToggle)
            // heightIn must wrap padding; reversing these makes the row 48 + 20 = 68dp.
            .heightIn(min = 48.dp)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        ModelVendorIcon(groupKey = group.id, groupName = group.name, size = 24.dp)
        Text(
            text = group.name,
            style = OriveoTheme.typography.body.copy(
                fontSize = 14.sp,
                lineHeight = 17.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = v2.textPrimary,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = group.models.size.toString(),
            style = OriveoTheme.typography.footnote.copy(
                fontSize = 12.sp,
                lineHeight = 14.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = v2.textTertiary,
        )
        Icon(
            imageVector = if (isExpanded) Icons.Filled.ExpandMore else Icons.Filled.ChevronRight,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
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
    isNestedUnderVendor: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val v2 = rememberV2PickerColors()
    val pricing = remember(model.priceTier, model.promptPrice, model.completionPrice, model.pricingUnit) {
        model.modelPickerPricePresentation()
    }
    val title = model.modelPickerDisplayTitle()
    val contextLengthLabel = remember(model.contextLength) {
        formatModelPickerContextLength(model.contextLength)
    }
    val sourceName = model.groupName
        ?.trim()
        ?.takeIf {
            !isNestedUnderVendor &&
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
            maxCapabilities = 2,
            modelFactsToolCall = CapabilityEvidenceProductionAdapter.toolCallVerdict(
                provider,
                model,
                memoryVerdict = toolCallMemoryVerdict,
            ),
        )
    }

    val capabilityBadges = remember(provider, model, capabilityObservationRevision, toolCallMemoryVerdict) {
        modelPickerCapabilityBadges(provider, model, toolCallMemoryVerdict = toolCallMemoryVerdict)
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
                    start = if (isNestedUnderVendor) 52.dp else 16.dp,
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
                            maximumVisibleItems = 2,
                            compact = true,
                        )
                        capabilityBadges.forEach { kind ->
                            val badgeLabel = stringResource(kind.badgeLabelRes)
                            Text(
                                text = badgeLabel,
                                style = OriveoTheme.typography.footnote.copy(
                                    fontSize = 11.sp,
                                    lineHeight = 13.sp,
                                    fontWeight = FontWeight.Medium,
                                ),
                                color = v2.primary,
                                maxLines = 1,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(999.dp))
                                    .background(v2.primary.copy(alpha = if (OriveoTheme.isDark) 0.20f else 0.12f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                                    .semantics { contentDescription = badgeLabel },
                            )
                        }
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

internal fun AIModel.modelPickerPricePresentation(): ModelPickerPricePresentation {
    val hasStructuredPricing = promptPrice != null || completionPrice != null
    if (pricingUnit == "per_token" && hasStructuredPricing) {
        if (promptPrice == 0.0 && completionPrice == 0.0) {
            return ModelPickerPricePresentation(input = null, output = null, fallback = "Free")
        }
        return ModelPickerPricePresentation(
            input = promptPrice?.let(ModelPricingFormatter::formatPerMillionValue),
            output = completionPrice?.let(ModelPricingFormatter::formatPerMillionValue),
            fallback = null,
        )
    }

    return ModelPickerPricePresentation(
        input = null,
        output = null,
        fallback = normalizedPriceTier().takeIf(String::isNotBlank),
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
                    filteredModels.sortedWith { lhs, rhs -> comparePickerModels(lhs, rhs) }
                }
            }

        if (shouldRenderModelPickerProviderSection(provider, query, models)) {
            ModelPickerSection(
                provider = provider,
                models = models,
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

private fun isModelSelected(
    context: ModelPickerContext,
    activeProviderId: String?,
    activeModelId: String?,
    currentModelId: String?,
    providerId: String,
    model: AIModel,
): Boolean {
    return when (context) {
        ModelPickerContext.Home -> {
            providerId == activeProviderId &&
                activeModelId == ModelSelectionUtils.preferredStoredModelIdentifier(model)
        }

        ModelPickerContext.Chat,
        ModelPickerContext.Crosscheck -> {
            providerId == activeProviderId && model.id == currentModelId
        }
    }
}

private fun Set<String>.toggle(value: String): Set<String> {
    return if (contains(value)) this - value else this + value
}

data class ModelPickerSection(
    val provider: Provider,
    val models: List<AIModel>,
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

fun defaultExpandedModelPickerVendorGroupIds(
    groups: List<ModelPickerVendorGroup>,
    selectedModelId: String?,
    searchText: String,
): Set<String> {
    if (searchText.isNotBlank()) return groups.mapTo(linkedSetOf()) { it.id }
    val activeGroup = selectedModelId?.let { selectedId ->
        groups.firstOrNull { group -> group.models.any { it.id == selectedId } }
    }
    return activeGroup?.let { setOf(it.id) }.orEmpty()
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
