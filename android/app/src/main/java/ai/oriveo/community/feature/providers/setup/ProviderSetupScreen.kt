package ai.oriveo.community.feature.providers.setup

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddLink
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.navigation.ProviderSetupEntryPoint
import ai.oriveo.community.feature.providers.ProviderEndpointSelector
import ai.oriveo.community.feature.providers.localizedProviderEndpointLabel
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.feature.providers.SubscriptionAuthorizationViewModel
import ai.oriveo.community.feature.providers.grok.GrokSubscriptionAuthorizationSheet
import ai.oriveo.community.feature.providers.openai.OpenAISubscriptionAuthorizationSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.component.OriveoLabeledField
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.OriveoTextButton
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.brandWatermarkIcon
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.ProviderBadgeColors
import ai.oriveo.community.ui.theme.oriveoSurface
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
fun ProviderSetupScreen(
    entryPoint: ProviderSetupEntryPoint = ProviderSetupEntryPoint.Onboarding,
    preselectedKind: ProviderKind? = null,
    onOpenRelaySetup: () -> Unit,
    onOpenLocalComputeSetup: () -> Unit,
    onProviderRegistered: (providerID: String) -> Unit,
    onManageExistingProvider: (providerID: String) -> Unit,
    onBack: () -> Unit,
    viewModel: ProviderSetupViewModel = koinViewModel(),
    authorizationViewModel: SubscriptionAuthorizationViewModel = koinViewModel(),
) {
    LaunchedEffect(viewModel.registeredProvider) {
        viewModel.registeredProvider?.let { onProviderRegistered(it.id) }
    }

    LaunchedEffect(Unit) {
    }

    val colors = OriveoTheme.colors
    val isDark = colors.backgroundBase == DarkOriveoColors.backgroundBase
    val selectedKind = viewModel.selectedKind
    val connectedProviders by viewModel.connectedProviders.collectAsState()
    var selectedCategory by remember { mutableStateOf(ProviderCategory.All) }
    var showConnectionSettingsSheet by remember { mutableStateOf(false) }
    var providerSelectionIsManual by remember { mutableStateOf(false) }

    LaunchedEffect(preselectedKind) {
        val kind = preselectedKind ?: return@LaunchedEffect
        providerSelectionIsManual = true
        viewModel.selectKindPreservingInput(kind)
    }

    val onSelectProvider: (ProviderKind) -> Unit = { kind ->
        providerSelectionIsManual = true
        viewModel.selectKindPreservingInput(kind)
    }

    val scrollState = rememberScrollState()
    LaunchedEffect(selectedKind) {
        if (selectedKind != null) {
            kotlinx.coroutines.delay(150)
            scrollState.animateScrollTo(scrollState.maxValue)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()

        Box(modifier = Modifier.fillMaxSize().imePadding()) {
            Column(modifier = Modifier.fillMaxSize()) {

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
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

                    Text(
                        text = stringResource(R.string.add_provider),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                        modifier = Modifier.weight(1f),
                        textAlign = TextAlign.Center,
                    )

                    Spacer(modifier = Modifier.size(32.dp))
                }

                AnimatedVisibility(
                    visible = viewModel.error != null,
                    enter = fadeIn() + expandVertically(animationSpec = spring(stiffness = Spring.StiffnessMediumLow)),
                    exit = fadeOut() + shrinkVertically(),
                ) {
                    viewModel.error?.let { error ->
                        ProviderSetupTopErrorBanner(
                            error = error,
                            onDismiss = { viewModel.dismissError() },
                            modifier = Modifier
                                .padding(horizontal = 24.dp)
                                .padding(bottom = 12.dp),
                        )
                    }
                }

                AnimatedVisibility(
                    visible = viewModel.isLoading,
                    enter = fadeIn() + expandVertically(animationSpec = spring(stiffness = Spring.StiffnessMediumLow)),
                    exit = fadeOut() + shrinkVertically(),
                ) {
                    ProviderSetupLoadingStatusBanner(
                        modifier = Modifier
                            .padding(horizontal = 24.dp)
                            .padding(bottom = 12.dp),
                    )
                }

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(scrollState)
                        .padding(start = 24.dp, end = 24.dp, top = 4.dp, bottom = 108.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    SetupHeroSection(compact = preselectedKind != null)

                    ProviderCategoryChips(
                        selected = selectedCategory,
                        onSelect = { selectedCategory = it },
                    )

                    if (selectedCategory == ProviderCategory.Custom) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            LocalComputeEntry(
                                isDark = isDark,
                                onClick = {
                                    onOpenLocalComputeSetup()
                                },
                            )
                            RelayCustomEntry(
                                isDark = isDark,
                                onClick = {
                                    onOpenRelaySetup()
                                },
                            )
                        }
                    } else {
                        if (selectedCategory == ProviderCategory.All || selectedCategory == ProviderCategory.Direct) {
                            ProviderShowcaseSection(
                                label = stringResource(R.string.provider_setup_direct_title),
                                providers = viewModel.setupCatalog.directProviders,
                                setupCatalog = viewModel.setupCatalog,
                                selectedKind = selectedKind,
                                onSelect = onSelectProvider,
                            )
                        }

                        if (selectedCategory == ProviderCategory.All || selectedCategory == ProviderCategory.Aggregators) {
                            ProviderShowcaseSection(
                                label = stringResource(R.string.provider_category_aggregators),
                                providers = viewModel.setupCatalog.aggregatorProviders,
                                setupCatalog = viewModel.setupCatalog,
                                selectedKind = selectedKind,
                                onSelect = onSelectProvider,
                            )
                        }

                        selectedKind?.let { kind ->

                            val existingProviderId = connectedProviders[kind]
                            if (existingProviderId != null && !viewModel.isAdditionalInstance) {
                                ProviderAlreadyConnectedSection(
                                    kind = kind,
                                    setupCatalog = viewModel.setupCatalog,
                                    onManageExisting = { onManageExistingProvider(existingProviderId) },
                                    onAddAnother = { viewModel.isAdditionalInstance = true },
                                )
                            } else {

                                if (kind == ProviderKind.Grok && viewModel.grokSubscriptionConfig != null) {
                                    GrokConnectionModeSection(
                                        mode = viewModel.grokAuthMode,
                                        onSelect = { viewModel.grokAuthMode = it },
                                    )
                                } else if (kind == ProviderKind.OpenAI && viewModel.openAISubscriptionConfig != null) {
                                    OpenAIConnectionModeSection(
                                        mode = viewModel.openAIAuthMode,
                                        onSelect = { viewModel.openAIAuthMode = it },
                                    )
                                }

                                if (viewModel.usesGrokSubscriptionFlow) {
                                    GrokSubscriptionConnectSection(
                                        isLoading = viewModel.isLoading,
                                        onConnect = { viewModel.showGrokSubscriptionSheet = true },
                                    )
                                } else if (viewModel.usesOpenAISubscriptionFlow) {
                                    OpenAISubscriptionConnectSection(
                                        isLoading = viewModel.isLoading,
                                        onConnect = { viewModel.showOpenAISubscriptionSheet = true },
                                    )
                                } else {
                                    ApiKeyConnectionSection(
                                        kind = kind,
                                        setupCatalog = viewModel.setupCatalog,
                                        apiKey = viewModel.apiKey,
                                        isLoading = viewModel.isLoading,
                                        onValueChange = { newValue ->
                                            viewModel.updateApiKey(
                                                value = newValue,
                                                allowAutoDetect = !providerSelectionIsManual,
                                            )
                                        },
                                        onConnectionSettings = { showConnectionSettingsSheet = true },
                                    )

                                    if (viewModel.regionOptions.isNotEmpty()) {
                                        ProviderEndpointSelector(
                                            kind = kind,
                                            selectedOptionId = viewModel.selectedRegion?.id,
                                            onSelect = { viewModel.selectRegion(it) },
                                            enabled = !viewModel.isLoading,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (selectedCategory != ProviderCategory.Custom && !viewModel.usesSubscriptionFlow) {
                Column(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .background(colors.surfaceChrome),
                ) {
                    HorizontalDivider(color = colors.border)

                    OriveoPrimaryButton(
                        text = if (viewModel.isLoading) {
                            stringResource(R.string.validating)
                        } else {
                            stringResource(R.string.continue_generation)
                        },
                        onClick = { viewModel.submitApiKey() },
                        enabled = viewModel.canSubmit,
                        loading = viewModel.isLoading,
                        modifier = Modifier
                            .padding(horizontal = 24.dp)
                            .padding(top = 16.dp, bottom = 16.dp),
                    )
                }
            }
        }

        if (viewModel.showGrokSubscriptionSheet) {
            val config = viewModel.grokSubscriptionConfig
            val grokSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            if (config == null) {

                viewModel.showGrokSubscriptionSheet = false
            } else {
                ModalBottomSheet(
                    onDismissRequest = {
                        authorizationViewModel.grok.cancel()
                        viewModel.showGrokSubscriptionSheet = false
                    },
                    sheetState = grokSheetState,
                    dragHandle = { OriveoSheetDragHandle() },
                ) {
                    GrokSubscriptionAuthorizationSheet(
                        config = config,
                        model = authorizationViewModel.grok,
                        onAuthorized = { tokens ->
                            viewModel.showGrokSubscriptionSheet = false
                            viewModel.completeGrokSubscriptionSetup(tokens)
                        },

                        onDismiss = {
                            authorizationViewModel.grok.cancel()
                            viewModel.showGrokSubscriptionSheet = false
                        },
                    )
                }
            }
        }

        if (viewModel.showOpenAISubscriptionSheet) {
            val config = viewModel.openAISubscriptionConfig
            val openAISheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            if (config == null) {

                viewModel.showOpenAISubscriptionSheet = false
            } else {
                ModalBottomSheet(
                    onDismissRequest = {
                        authorizationViewModel.openAI.cancel()
                        viewModel.showOpenAISubscriptionSheet = false
                    },
                    sheetState = openAISheetState,
                    dragHandle = { OriveoSheetDragHandle() },
                ) {
                    OpenAISubscriptionAuthorizationSheet(
                        config = config,
                        model = authorizationViewModel.openAI,
                        onAuthorized = { tokens ->
                            viewModel.showOpenAISubscriptionSheet = false
                            viewModel.completeOpenAISubscriptionSetup(tokens)
                        },
                        onDismiss = {
                            authorizationViewModel.openAI.cancel()
                            viewModel.showOpenAISubscriptionSheet = false
                        },
                    )
                }
            }
        }

        if (showConnectionSettingsSheet) {
            val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            ModalBottomSheet(
                onDismissRequest = { showConnectionSettingsSheet = false },
                sheetState = sheetState,
                dragHandle = { OriveoSheetDragHandle() },
            ) {
                ProviderSetupConnectionSettingsSheet(
                    selectedKind = selectedKind,
                    setupCatalog = viewModel.setupCatalog,
                    selectedEndpoint = selectedKind?.let {
                        viewModel.setupCatalog.resolveRegionOption(
                            it,
                            viewModel.selectedRegion?.baseURL ?: viewModel.setupCatalog.defaultBaseUrl(it),
                        )
                    },
                    selectedBaseUrl = selectedKind?.let {
                        viewModel.selectedRegion?.baseURL ?: viewModel.setupCatalog.defaultBaseUrl(it)
                    },
                    onDismiss = { showConnectionSettingsSheet = false },
                )
            }
        }
    }
}

@Composable
private fun SetupHeroSection(compact: Boolean) {
    val colors = OriveoTheme.colors
    val iconSize = if (compact) 54.dp else 66.dp
    val iconRadius = if (compact) 16.dp else 20.dp
    val symbolSize = if (compact) 23.dp else 28.dp
    val glowSize = if (compact) 108.dp else 138.dp

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = if (compact) 0.dp else 2.dp, bottom = if (compact) 4.dp else 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else 12.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {

            Box(
                modifier = Modifier
                    .size(glowSize)
                    .blur(14.dp)
                    .background(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                colors.primary.copy(alpha = 0.22f),
                                colors.primary.copy(alpha = 0.06f),
                                Color.Transparent,
                            ),
                        ),
                        shape = CircleShape,
                    ),
            )

            Box(
                modifier = Modifier
                    .size(iconSize)
                    .shadow(
                        elevation = 12.dp,
                        shape = RoundedCornerShape(iconRadius),
                        ambientColor = colors.primary.copy(alpha = 0.40f),
                        spotColor = colors.primary.copy(alpha = 0.40f),
                    )
                    .clip(RoundedCornerShape(iconRadius))
                    .background(OriveoGradients.primary),
                contentAlignment = Alignment.Center,
            ) {

                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .background(
                            Brush.verticalGradient(
                                colors = listOf(
                                    Color.White.copy(alpha = 0.45f),
                                    Color.White.copy(alpha = 0.10f),
                                    Color.Transparent,
                                ),
                            ),
                        ),
                )

                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .padding(5.dp)
                        .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(iconRadius - 4.dp)),
                )

                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .border(
                            width = 0.75.dp,
                            brush = Brush.verticalGradient(
                                colors = listOf(
                                    Color.White.copy(alpha = 0.6f),
                                    Color.White.copy(alpha = 0.05f),
                                    Color.Transparent,
                                ),
                            ),
                            shape = RoundedCornerShape(iconRadius),
                        ),
                )

                Icon(
                    imageVector = Icons.Filled.AddLink,
                    contentDescription = null,
                    modifier = Modifier.size(symbolSize),
                    tint = Color.White,
                )
            }
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = stringResource(R.string.provider_setup_hero_title),
                style = OriveoTheme.typography.title3.copy(
                    fontSize = if (compact) 18.sp else 20.sp,
                    fontWeight = FontWeight.Bold,
                ),
                color = colors.textPrimary,
            )
            Text(
                text = stringResource(R.string.provider_setup_hero_subtitle),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

private enum class ProviderCategory(@get:androidx.annotation.StringRes val labelRes: Int, val icon: ImageVector) {
    All(R.string.provider_category_all, Icons.Filled.GridView),
    Direct(R.string.provider_category_direct, Icons.Filled.Bolt),
    Aggregators(R.string.provider_category_aggregators, Icons.Filled.Layers),
    Custom(R.string.provider_category_custom, Icons.Filled.Tune),
}

@Composable
private fun ProviderCategoryChips(
    selected: ProviderCategory,
    onSelect: (ProviderCategory) -> Unit,
) {
    val colors = OriveoTheme.colors

    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val rowMinWidth = maxWidth
        Row(
            modifier = Modifier
                .horizontalScroll(rememberScrollState())
                .widthIn(min = rowMinWidth),
            horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ProviderCategory.entries.forEach { category ->
                val active = selected == category
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (active) colors.primarySoft else colors.surface)
                        .border(
                            width = 0.5.dp,
                            color = if (active) colors.primary.copy(alpha = 0.25f) else colors.border,
                            shape = CircleShape,
                        )
                        .clickable { onSelect(category) }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Icon(
                        imageVector = category.icon,
                        contentDescription = null,
                        modifier = Modifier.size(11.dp),
                        tint = if (active) colors.primary else colors.textSecondary,
                    )
                    Text(
                        text = stringResource(category.labelRes),
                        style = OriveoTheme.typography.caption.copy(
                            fontSize = 13.sp,
                            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        ),
                        color = if (active) colors.primary else colors.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProviderShowcaseSection(
    label: String,
    providers: List<ProviderKind>,
    setupCatalog: ProviderSetupCatalog,
    selectedKind: ProviderKind?,
    onSelect: (ProviderKind) -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            text = label.uppercase(),
            style = OriveoTheme.typography.caption.copy(
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.4.sp,
            ),
            color = colors.textTertiary,
            modifier = Modifier.padding(start = 2.dp),
        )

        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            maxItemsInEachRow = 2,
        ) {
            providers.forEach { kind ->
                ProviderShowcaseCard(
                    kind = kind,
                    setupCatalog = setupCatalog,
                    isSelected = selectedKind == kind,
                    onClick = { onSelect(kind) },
                    modifier = Modifier.weight(1f),
                )
            }

            if (providers.size % 2 == 1) {
                Spacer(modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ProviderShowcaseCard(
    kind: ProviderKind,
    setupCatalog: ProviderSetupCatalog,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val brand = ProviderBadgeColors.forProvider(kind)
    val accent = ProviderBadgeColors.usageBreakdown(kind)
    val taglineRes = ProviderSetupCopy.tagline(kind)
    val cardShape = RoundedCornerShape(16.dp)

    Box(
        modifier = modifier

            .shadow(
                elevation = if (isSelected) 12.dp else 8.dp,
                shape = cardShape,
                ambientColor = if (isSelected) accent.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.10f),
                spotColor = if (isSelected) accent.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.10f),
            )
            .clip(cardShape)

            .background(brand.background)

            .clickable(onClick = onClick),
    ) {

        ShowcaseWatermark(kind = kind, accent = accent, isSelected = isSelected)

        Column(
            modifier = Modifier
                .heightIn(min = 88.dp)
                .padding(12.dp),
        ) {

            Row(verticalAlignment = Alignment.Top) {
                Box(
                    modifier = Modifier.size(36.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    ProviderBadgeIcon(kind = kind, size = 36.dp)
                }

                Spacer(modifier = Modifier.weight(1f))

                if (isSelected) {
                    Box(
                        modifier = Modifier
                            .size(18.dp)
                            .clip(CircleShape)
                            .background(accent),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Check,
                            contentDescription = null,
                            modifier = Modifier.size(11.dp),
                            tint = Color.White,
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = setupCatalog.displayName(kind),
                style = OriveoTheme.typography.body.copy(
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = if (isSelected) accent else colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )

            if (taglineRes != null) {
                Text(
                    text = stringResource(taglineRes),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

@Composable
private fun BoxScope.ShowcaseWatermark(kind: ProviderKind, accent: Color, isSelected: Boolean) {
    val symbol = kind.brandWatermarkIcon()
    Box(
        modifier = Modifier
            .align(Alignment.BottomEnd)
            .offset(x = 24.dp, y = 22.dp),
    ) {
        if (symbol != null) {
            Icon(
                imageVector = symbol,
                contentDescription = null,
                modifier = Modifier
                    .size(102.dp)
                    .rotate(-8f),
                tint = accent.copy(alpha = if (isSelected) 0.16f else 0.11f),
            )
        } else {
            Box(
                modifier = Modifier
                    .size(112.dp)
                    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                    .drawWithContent {
                        drawContent()
                        drawRect(
                            color = accent.copy(alpha = if (isSelected) 0.14f else 0.09f),
                            blendMode = BlendMode.SrcIn,
                        )
                    },
                contentAlignment = Alignment.Center,
            ) {
                ProviderBadgeIcon(kind = kind, size = 112.dp)
            }
        }
    }
}

@Composable
private fun ApiKeyConnectionSection(
    kind: ProviderKind,
    setupCatalog: ProviderSetupCatalog,
    apiKey: String,
    isLoading: Boolean,
    onValueChange: (String) -> Unit,
    onConnectionSettings: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val accent = ProviderBadgeColors.usageBreakdown(kind)
    val cardShape = RoundedCornerShape(OriveoTheme.radius.lg)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(elevation = 6.dp, shape = cardShape, ambientColor = accent.copy(alpha = 0.08f), spotColor = accent.copy(alpha = 0.08f))
            .clip(cardShape)
            .background(colors.surface)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ProviderBadgeIcon(kind = kind, size = 36.dp)

            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    text = stringResource(R.string.connect_provider_named, setupCatalog.displayName(kind)),
                    style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = stringResource(R.string.provider_setup_enter_key_subtitle),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
        }

        OriveoLabeledField(
            label = stringResource(R.string.api_key),
            value = apiKey,
            onValueChange = onValueChange,
            placeholder = setupCatalog.apiKeyPlaceholder(kind),
            footnote = if (ProviderSetupCopy.shouldShowAutoFillNote(kind)) {
                stringResource(R.string.auto_fill_note)
            } else {
                ""
            },
            isSecure = true,
            enabled = !isLoading,
        )

        OriveoTextButton(
            text = stringResource(R.string.provider_detail_connection_settings),
            onClick = onConnectionSettings,
        )
    }
}

@Composable
private fun GrokConnectionModeSection(
    mode: ProviderAuthMode,
    onSelect: (ProviderAuthMode) -> Unit,
) {
    val colors = OriveoTheme.colors

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            text = stringResource(R.string.grok_connect_mode_title),
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            ProviderConnectionModeOption(
                selected = mode == ProviderAuthMode.ApiKey,
                icon = Icons.Filled.Key,
                title = stringResource(R.string.grok_connect_mode_api_key),
                subtitle = stringResource(R.string.grok_connect_mode_api_key_desc),
                onClick = { onSelect(ProviderAuthMode.ApiKey) },
            )
            ProviderConnectionModeOption(
                selected = mode == ProviderAuthMode.Subscription,
                icon = Icons.Filled.VerifiedUser,
                title = stringResource(R.string.grok_connect_mode_subscription),
                subtitle = stringResource(R.string.grok_connect_mode_subscription_desc),
                onClick = { onSelect(ProviderAuthMode.Subscription) },
            )
        }
    }
}

@Composable
private fun ProviderConnectionModeOption(
    selected: Boolean,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoTheme.radius.md)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 74.dp)
            .clip(shape)
            .background(if (selected) colors.primarySoft else colors.surfaceElevated)
            .border(
                width = 1.dp,
                color = if (selected) colors.primary.copy(alpha = 0.28f) else colors.border,
                shape = shape,
            )
            .clickable(onClick = onClick)
            .padding(12.dp),

        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (selected) colors.primary else colors.textSecondary,

            modifier = Modifier.size(24.dp),
        )

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                text = title,
                style = OriveoTheme.typography.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                text = subtitle,
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }

        Icon(
            imageVector = if (selected) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
            contentDescription = null,
            tint = if (selected) colors.primary else colors.textTertiary,
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
private fun GrokSubscriptionConnectSection(
    isLoading: Boolean,
    onConnect: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val cardShape = RoundedCornerShape(OriveoTheme.radius.lg)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(cardShape)
            .background(colors.surfaceElevated)
            .border(width = 1.dp, color = colors.border, shape = cardShape)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = stringResource(R.string.grok_subscription_connect_hint),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )

        OriveoPrimaryButton(
            text = stringResource(R.string.grok_subscription_connect_action),
            onClick = onConnect,
            enabled = !isLoading,
            loading = isLoading,
        )
    }
}

@Composable
private fun OpenAIConnectionModeSection(
    mode: ProviderAuthMode,
    onSelect: (ProviderAuthMode) -> Unit,
) {
    val colors = OriveoTheme.colors

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            text = stringResource(R.string.openai_connect_mode_title),
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            ProviderConnectionModeOption(
                selected = mode == ProviderAuthMode.ApiKey,
                icon = Icons.Filled.Key,
                title = stringResource(R.string.openai_connect_mode_api_key),
                subtitle = stringResource(R.string.openai_connect_mode_api_key_desc),
                onClick = { onSelect(ProviderAuthMode.ApiKey) },
            )
            ProviderConnectionModeOption(
                selected = mode == ProviderAuthMode.Subscription,
                icon = Icons.Filled.VerifiedUser,
                title = stringResource(R.string.openai_connect_mode_subscription),
                subtitle = stringResource(R.string.openai_connect_mode_subscription_desc),
                onClick = { onSelect(ProviderAuthMode.Subscription) },
            )
        }
    }
}

@Composable
private fun OpenAISubscriptionConnectSection(
    isLoading: Boolean,
    onConnect: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val cardShape = RoundedCornerShape(OriveoTheme.radius.lg)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(cardShape)
            .background(colors.surfaceElevated)
            .border(width = 1.dp, color = colors.border, shape = cardShape)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = stringResource(R.string.openai_subscription_connect_hint),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )

        OriveoPrimaryButton(
            text = stringResource(R.string.openai_subscription_connect_action),
            onClick = onConnect,
            enabled = !isLoading,
            loading = isLoading,
        )
    }
}

@Composable
private fun ProviderAlreadyConnectedSection(
    kind: ProviderKind,
    setupCatalog: ProviderSetupCatalog,
    onManageExisting: () -> Unit,
    onAddAnother: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val accent = ProviderBadgeColors.usageBreakdown(kind)
    val cardShape = RoundedCornerShape(OriveoTheme.radius.lg)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(elevation = 6.dp, shape = cardShape, ambientColor = accent.copy(alpha = 0.08f), spotColor = accent.copy(alpha = 0.08f))
            .clip(cardShape)
            .background(colors.surface)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ProviderBadgeIcon(kind = kind, size = 36.dp)

            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    text = stringResource(R.string.provider_already_connected, setupCatalog.displayName(kind)),
                    style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = stringResource(R.string.provider_already_connected_subtitle),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
        }

        OriveoPrimaryButton(
            text = stringResource(R.string.provider_manage_existing),
            onClick = onManageExisting,
        )

        OriveoSecondaryButton(
            text = stringResource(R.string.provider_add_another_account),
            onClick = onAddAnother,
        )
    }
}

@Composable
private fun LocalComputeEntry(isDark: Boolean, onClick: () -> Unit) {
    CustomProviderEntry(
        title = stringResource(R.string.local_compute_title),
        subtitle = stringResource(R.string.local_compute_entry_subtitle),
        icon = Icons.Filled.Bolt,
        iconColor = OriveoTheme.colors.primary,
        isDark = isDark,
        onClick = onClick,
    )
}

@Composable
private fun RelayCustomEntry(isDark: Boolean, onClick: () -> Unit) {
    CustomProviderEntry(
        title = stringResource(R.string.provider_setup_relay_title),
        subtitle = stringResource(R.string.provider_setup_relay_subtitle),
        icon = Icons.Outlined.SwapHoriz,
        iconColor = Color(0xFFF59E0B),
        isDark = isDark,
        onClick = onClick,
    )
}

@Composable
private fun CustomProviderEntry(
    title: String,
    subtitle: String,
    icon: ImageVector,
    iconColor: Color,
    isDark: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .oriveoSurface(
                colors = colors,
                isDark = isDark,
                fill = colors.surfaceElevated,
                borderColor = colors.border,
                radius = 16.dp,
                shadowStyle = OriveoSurfaceStyle.Soft,
            )
            .clickable(onClick = onClick)
            .heightIn(min = 70.dp)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(42.dp).padding(9.dp),
            tint = iconColor,
        )

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                text = subtitle,
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        Icon(
            imageVector = Icons.Filled.ChevronRight,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
            tint = colors.textTertiary,
        )
    }
}

@Composable
private fun ProviderSetupLoadingStatusBanner(
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors

    OriveoCard(
        modifier = modifier,
        fillColor = colors.primarySoft,
        borderColor = colors.primary.copy(alpha = 0.2f),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = colors.primary,
            )
            Text(
                text = stringResource(R.string.provider_setup_syncing_status),
                style = OriveoTheme.typography.caption,
                color = colors.primary,
            )
        }
    }
}

@Composable
private fun ProviderSetupTopErrorBanner(
    error: OriveoError,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val (foreground, background, leadingIcon) = when (error.severity) {
        OriveoErrorSeverity.Warning -> Triple(
            colors.warning,
            colors.warningSoft,
            Icons.Outlined.Warning,
        )
        OriveoErrorSeverity.Critical -> Triple(
            colors.danger,
            colors.dangerSoft,
            Icons.Outlined.Warning,
        )
    }

    OriveoCard(
        modifier = modifier,
        fillColor = background,
        borderColor = foreground.copy(alpha = 0.28f),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                imageVector = leadingIcon,
                contentDescription = null,
                tint = foreground,
                modifier = Modifier
                    .padding(top = 2.dp)
                    .size(18.dp),
            )

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = error.title,
                    style = OriveoTheme.typography.title3,
                    color = colors.textPrimary,
                )
                if (error.message.isNotEmpty()) {
                    Text(
                        text = error.message,
                        style = OriveoTheme.typography.caption,
                        color = colors.textSecondary,
                    )
                }
            }

            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = stringResource(R.string.close),
                    tint = colors.textSecondary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

@Composable
private fun ProviderSetupConnectionSettingsSheet(
    selectedKind: ProviderKind?,
    setupCatalog: ProviderSetupCatalog,
    selectedEndpoint: ai.oriveo.community.core.model.RegionOption? = null,
    selectedBaseUrl: String? = null,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = layout.screenH)
            .padding(top = spacing.md, bottom = spacing.xl),
        verticalArrangement = Arrangement.spacedBy(layout.cardRowGap),
    ) {

        Text(
            text = stringResource(R.string.provider_detail_connection_settings),
            style = OriveoTheme.typography.title1,
            color = colors.textPrimary,
        )

        OriveoCard {

            Column(verticalArrangement = Arrangement.spacedBy(spacing.md)) {
                ProviderSetupConnectionInfoRow(
                    title = stringResource(R.string.provider_label),
                    value = selectedKind?.let { setupCatalog.displayName(it) }
                        ?: stringResource(R.string.reasoning_auto),
                )
                if (selectedKind != null && selectedEndpoint != null &&
                    setupCatalog.regionOptions(selectedKind).isNotEmpty()
                ) {
                    ProviderSetupConnectionInfoRow(
                        title = stringResource(R.string.official_endpoint),
                        value = localizedProviderEndpointLabel(selectedKind, selectedEndpoint),
                    )
                }
                ProviderSetupConnectionInfoRow(
                    title = stringResource(R.string.request_url_label),
                    value = selectedBaseUrl ?: stringResource(
                        if (selectedKind != null && ProviderSetupCopy.shouldShowAutoFillNote(selectedKind)) {
                            R.string.endpoint_auto_filled
                        } else {
                            R.string.endpoint_manual
                        },
                    ),
                )
            }
        }

        Text(
            text = if (selectedKind != null && ProviderSetupCopy.shouldShowAutoFillNote(selectedKind)) {
                stringResource(R.string.auto_fill_note)
            } else {
                stringResource(R.string.provider_setup_continue_hint_select)
            },
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )

        OriveoPrimaryButton(
            text = stringResource(R.string.done),
            onClick = onDismiss,
        )
    }
}

@Composable
private fun ProviderSetupConnectionInfoRow(title: String, value: String) {
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
