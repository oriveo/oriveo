package ai.oriveo.community.feature.modelpicker

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.feature.providers.detail.ProviderCatalogGroup
import ai.oriveo.community.feature.providers.detail.buildProviderCatalogGroups
import ai.oriveo.community.feature.providers.detail.providerCatalogGroups
import ai.oriveo.community.feature.providers.detail.shouldAutoExpandCatalogGroups
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun InlineModelCatalog(
    provider: Provider,
    capabilityObservationRevision: Long,
    onEnableModel: (modelID: String) -> Unit,
    onBack: () -> Unit,
) {
    var searchText by remember { mutableStateOf("") }
    var expandedGroups by remember(provider.id) { mutableStateOf(emptySet<String>()) }
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout

    var groupedModels by remember(provider.id) { mutableStateOf(emptyList<ProviderCatalogGroup>()) }

    var appliedSearchText: String? by remember(provider.id) { mutableStateOf(null) }
    LaunchedEffect(provider.kind, provider.models, searchText) {
        val applied = appliedSearchText
        if (applied != null && applied != searchText) {
            delay(InlineCatalogSearchDebounceMillis)
        }
        val groups = withContext(Dispatchers.Default) {
            buildProviderCatalogGroups(provider = provider, searchQuery = searchText)
        }
        groupedModels = groups
        appliedSearchText = searchText
    }
    val catalogReady = appliedSearchText != null

    LaunchedEffect(groupedModels.map { it.id }) {
        expandedGroups = expandedGroups.intersect(groupedModels.map { it.id }.toSet())
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = spacing.sm, vertical = spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.back),
                    tint = colors.primary,
                )
            }
            Text(
                text = stringResource(R.string.add_models),
                style = OriveoTheme.typography.title2,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.width(48.dp))
        }

        if (groupedModels.isNotEmpty() || searchText.isNotEmpty()) {
            CatalogSearchField(
                value = searchText,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = layout.screenH, vertical = spacing.sm),
                onValueChange = { searchText = it },
                onClear = { searchText = "" },
            )
        }

        if (groupedModels.isEmpty() && catalogReady) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = layout.screenH, vertical = spacing.xxl),
            ) {
                Text(
                    text = if (searchText.isNotBlank()) {
                        stringResource(R.string.no_matching_models)
                    } else {
                        stringResource(R.string.all_models_enabled)
                    },
                    style = OriveoTheme.typography.body,
                    color = colors.textSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        } else {

            LazyColumn(
                modifier = Modifier.weight(1f, fill = true),
                contentPadding = PaddingValues(
                    start = layout.screenH,
                    top = spacing.sm,
                    end = layout.screenH,
                    bottom = spacing.lg,
                ),
            ) {
                providerCatalogGroups(
                    provider = provider,
                    groups = groupedModels,
                    searchQuery = searchText,
                    expandedGroups = expandedGroups,
                    onToggleGroup = { groupId ->
                        if (!shouldAutoExpandCatalogGroups(searchText)) {
                            expandedGroups = expandedGroups.toMutableSet().apply {
                                if (!add(groupId)) {
                                    remove(groupId)
                                }
                            }
                        }
                    },
                    onEnableModel = { model -> onEnableModel(model.id) },
                    capabilityObservationRevision = capabilityObservationRevision,
                )
            }
        }
    }
}

private const val InlineCatalogSearchDebounceMillis = 120L

@Composable
private fun CatalogSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val shape = RoundedCornerShape(16.dp)

    Row(
        modifier = modifier
            .clip(shape)
            .background(colors.surface)
            .border(OriveoBorderWidth.standard, colors.border, shape)
            .padding(horizontal = spacing.md, vertical = spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Filled.Search,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.textSecondary,
        )

        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.weight(1f),
            singleLine = true,
            textStyle = OriveoTheme.typography.body.copy(color = colors.textPrimary),
            cursorBrush = SolidColor(colors.primary),
            decorationBox = { innerTextField ->
                Box {
                    if (value.isBlank()) {
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

        if (value.isNotEmpty()) {
            Box(
                modifier = Modifier
                    .size(20.dp)
                    .clickable(onClick = onClear),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = colors.textTertiary,
                )
            }
        }
    }
}
