package ai.oriveo.community.feature.providers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CreditCard
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderEffectiveStatusKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.effectiveStatusKind

import ai.oriveo.community.core.provider.BALANCE_CAPABLE_KINDS
import ai.oriveo.community.ui.component.OriveoFadeHairline
import ai.oriveo.community.ui.component.ProviderListCard
import ai.oriveo.community.ui.component.oriveoSystemBarFadingEdges
import ai.oriveo.community.ui.component.rootTabTopInset
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

@Composable
fun ProvidersScreen(
    onNavigateToSetup: () -> Unit = {},
    onNavigateToDetail: (providerID: String) -> Unit = {},
    viewModel: ProvidersViewModel = koinViewModel(),
) {
    val providers by viewModel.providers.collectAsStateWithLifecycle()
    val availableModelCounts by viewModel.availableModelCounts.collectAsStateWithLifecycle()
    val monthlyCostByProvider by viewModel.mergedMonthlyCostByProvider.collectAsStateWithLifecycle()
    val dailyCostsByProvider by viewModel.dailyCostsLast7DaysByProvider.collectAsStateWithLifecycle()
    val monthlyCostSummary by viewModel.monthlyCostSummary.collectAsStateWithLifecycle()
    val providerBalances by viewModel.providerBalances.collectAsStateWithLifecycle()
    var pendingDelete by remember { mutableStateOf<Provider?>(null) }

    val connectedCount = remember(providers) {
        providers.count { it.effectiveStatusKind == ProviderEffectiveStatusKind.Connected }
    }
    val syncingCount = remember(providers) {
        providers.count { it.effectiveStatusKind == ProviderEffectiveStatusKind.Syncing }
    }
    val issueCount = remember(providers) {
        providers.count { it.effectiveStatusKind.isWarning }
    }
    val totalAvailableModelCount = remember(providers, availableModelCounts) {
        providersClusterAvailableModelCount(
            providers = providers,
            precomputedCounts = availableModelCounts,
        )
    }
    val spotlightProviders = remember(providers, monthlyCostByProvider) {
        computeSpotlightProviders(providers, monthlyCostByProvider)
    }
    val providerBalancesRefreshKey = remember(providers) {
        providers
            .filter { it.kind in BALANCE_CAPABLE_KINDS }
            .map { listOf(it.id, it.kind.name, it.apiKey, it.baseUrlText.orEmpty()) }
    }

    LaunchedEffect(providerBalancesRefreshKey) {
        viewModel.refreshProviderBalances()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        ProvidersScreenBackground()

        val screenH = OriveoTheme.layout.screenH

        val statusBarInset = rootTabTopInset()
        val navigationBarInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .oriveoSystemBarFadingEdges(
                    topInset = statusBarInset,
                    bottomInset = navigationBarInset,
                ),
            contentPadding = PaddingValues(
                start = screenH,

                top = statusBarInset + 8.dp,
                end = screenH,
                bottom = navigationBarInset + OriveoTheme.layout.tabBarOverlay,
            ),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {

            item(key = "providers_title") {
                ProvidersSectionTitle(
                    leading = { ProvidersClusterTitleLabel() },
                    trailing = { ProvidersAddButton(onClick = onNavigateToSetup) },
                )
            }

            if (providers.isEmpty()) {
                item(key = "providers_full_empty") {
                    ProvidersFullEmptyState(onAdd = onNavigateToSetup)
                }
            } else {

                if (spotlightProviders.isNotEmpty()) {
                    item(key = "providers_spotlight") {
                        ProvidersSpotlightSection(
                            providers = spotlightProviders,

                            costForProvider = { p -> monthlyCostByProvider[p.id] ?: 0.0 },
                            dailyCostsForProvider = { p -> dailyCostsByProvider[p.id] ?: emptyList() },
                            availableModelCountForProvider = { p ->
                                providerListAvailableModelCount(
                                    provider = p,
                                    precomputedCount = availableModelCounts[p.id],
                                )
                            },
                            onProviderTap = { onNavigateToDetail(it.id) },
                        )
                    }
                }

                item(key = "providers_summary") {
                    ProvidersSummaryStrip(
                        providerCount = providers.size,
                        availableModelCount = totalAvailableModelCount,
                        connectedCount = connectedCount,
                        syncingCount = syncingCount,
                        issueCount = issueCount,
                    )
                }

                item(key = "providers_all_section") {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        ProvidersSectionHeader(
                            text = stringResource(R.string.providers_all_providers),
                            icon = Icons.Outlined.Layers,
                            tone = ProvidersSectionHeaderTone.All,
                        )
                        ProvidersListCluster {
                            providers.forEachIndexed { index, provider ->
                                key(provider.id) {
                                    if (index > 0) {

                                        OriveoFadeHairline(
                                            insetLeading = 85.dp,
                                            insetTrailing = 14.dp,
                                        )
                                    }
                                    val availableModelCount = providerListAvailableModelCount(
                                        provider = provider,
                                        precomputedCount = availableModelCounts[provider.id],
                                    )
                                    ProviderListCard(
                                        provider = provider,
                                        availableModelCount = availableModelCount,
                                        onClick = { onNavigateToDetail(provider.id) },
                                        onLongClick = if (provider.kind.allowsDeletion) {
                                            { pendingDelete = provider }
                                        } else {
                                            null
                                        },
                                        monthlyEstimatedCost = monthlyCostByProvider[provider.id] ?: 0.0,
                                        providerBalance = providerBalances[provider.id],
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if (monthlyCostSummary.isVisible) {
                item(key = "cost_section") {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        ProvidersSectionHeader(
                            text = stringResource(R.string.costs_title),
                            icon = Icons.Outlined.CreditCard,
                            tone = ProvidersSectionHeaderTone.Costs,
                        )
                        ProvidersCostSummaryCard(
                            summary = monthlyCostSummary,
                            onOpenDetails = {},
                        )
                    }
                }
            }
        }
    }

    pendingDelete?.takeIf { it.kind.allowsDeletion }?.let { provider ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = {
                Text(
                    stringResource(
                        if (provider.kind == ProviderKind.Relay) {
                            R.string.relay_delete_provider_title
                        } else {
                            R.string.providers_delete_this_question
                        },
                        provider.displayName,
                    ),
                )
            },
            text = {
                Text(
                    stringResource(
                        if (provider.kind == ProviderKind.Relay) {
                            R.string.relay_delete_provider_confirm
                        } else {
                            R.string.providers_delete_this_message
                        },
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteProvider(provider.id)
                        pendingDelete = null
                    },
                ) {
                    Text(stringResource(R.string.delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

internal fun computeSpotlightProviders(
    providers: List<Provider>,
    monthlyCostByProvider: Map<String, Double>,
): List<Provider> {
    val eligible = providers
    if (eligible.isEmpty()) return emptyList()

    val withCost = eligible
        .map { it to (monthlyCostByProvider[it.id] ?: 0.0) }
        .filter { it.second > CostFormatter.COST_EPSILON }
        .sortedByDescending { it.second }
    if (withCost.isNotEmpty()) {
        return listOf(withCost.first().first)
    }
    return listOf(
        eligible.sortedBy { statusPriority(it.effectiveStatusKind) }.first()
    )
}

private fun statusPriority(kind: ProviderEffectiveStatusKind): Int = when (kind) {
    ProviderEffectiveStatusKind.Connected -> 0
    ProviderEffectiveStatusKind.Syncing -> 1
    ProviderEffectiveStatusKind.Issue -> 2
    ProviderEffectiveStatusKind.NeedsKey -> 2
}

internal fun providerListAvailableModelCount(
    provider: Provider,
    precomputedCount: Int?,
): Int {
    if (precomputedCount != null) return precomputedCount
    return when {
        provider.kind == ProviderKind.Relay || provider.catalogModels.isNotEmpty() ->
            provider.availableModelCount
        else -> provider.models.count { it.isAvailable }
    }
}

internal fun providersClusterAvailableModelCount(
    providers: List<Provider>,
    precomputedCounts: Map<String, Int>,
): Int = providers.sumOf { provider ->
    providerListAvailableModelCount(
        provider = provider,
        precomputedCount = precomputedCounts[provider.id],
    )
}

internal fun resolveProviderListAvailableModelCount(provider: Provider): Int =
    when {
        provider.kind == ProviderKind.Relay || provider.catalogModels.isNotEmpty() ->
            provider.availableModelCount
        else ->
            ai.oriveo.community.core.provider.ProviderCatalogResolver.resolve(provider).availableModelCount
    }
