package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.util.modelIdDisplay
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceDisclosureStore
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.realtime.HomeRealtimeSelectionStore
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.feature.modelpicker.RealtimePickerDisclosure
import ai.oriveo.community.feature.modelpicker.acceptRealtimeDisclosure
import ai.oriveo.community.feature.modelpicker.pickRealtimeModel
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

/** Realtime voice group row: this connection x the catalog realtime model; [checked] = the home selection is exactly this connection's model. */
internal data class ProviderDetailRealtimeRow(
    val entry: VoiceRealtimeEntry,
    val checked: Boolean,
)

/** Realtime voice group has a single state: this connection has a realtime row. Null means the group is not shown (including catalog still loading / failed / provider has no realtime model), same as iOS. */
internal data class ProviderDetailRealtimeState(val rows: List<ProviderDetailRealtimeRow>)

/**
 * State of the Realtime voice group on the provider detail page; null = group not shown.
 * Only official apiKey connections show the group (relay / hosted provider / free tier / OpenRouter / subscription never do); rows come from the same source as the picker
 * ([RealtimeModel.pickerRows]: isDefault first, the rest in catalog order); the group is hidden when the catalog is not loaded / fetch failed / server has no voice catalog /
 * provider has no realtime model; no progress or failure row is shown (same as iOS ProviderRealtimeModelsSection).
 */
internal fun providerDetailRealtimeState(
    provider: Provider,
    catalogState: VoiceCatalogState?,
    selection: Pair<String, String>?,
): ProviderDetailRealtimeState? {
    val auth = RealtimeModel.connectionAuth(provider.kind, provider.authMode)
    // OpenRouter is a resale aggregator connection: the group never shows for it, even with apiKey.
    if (auth != RealtimeModel.AUTH_API_KEY || provider.kind == ProviderKind.OpenRouter) return null
    val catalog = (catalogState as? VoiceCatalogState.Available)?.catalog ?: return null
    val entries = catalog.entries(provider.kind, VoiceDirection.Realtime).filterIsInstance<VoiceRealtimeEntry>()
    val result = RealtimeModel.pickerRows(
        context = RealtimeModel.CONTEXT_HOME,
        connections = listOf(RealtimeModel.Connection(id = provider.id, providerKind = provider.kind.rawValue, auth = auth)),
        realtimeCatalog = mapOf(provider.kind.rawValue to entries.map { RealtimeModel.RealtimeCatalogEntry(it.model, it.isDefault) }),
    )
    val byModel = entries.associateBy { it.model }
    val rows = result.groups.filter { it.connectionId == provider.id }.flatMap { group ->
        group.rows.mapNotNull { row ->
            byModel[row.model]?.let { entry ->
                ProviderDetailRealtimeRow(entry = entry, checked = selection == (provider.id to entry.model))
            }
        }
    }
    return if (rows.isEmpty()) null else ProviderDetailRealtimeState(rows)
}

/**
 * Chat button / row tap: if Realtime for this provider is already consented -> write the home selection and [openHome], return null;
 * not yet consented (first-time disclosure) -> do not write or navigate; return the pending choice so the caller shows the disclosure.
 */
internal fun startProviderDetailRealtime(
    providerId: String,
    providerKind: ProviderKind,
    modelId: String,
    disclosure: VoiceDisclosureStore,
    selection: HomeRealtimeSelectionStore,
    openHome: () -> Unit,
): RealtimePickerDisclosure? = pickRealtimeModel(
    providerId = providerId,
    providerKind = providerKind,
    modelId = modelId,
    store = disclosure,
    select = selection::set,
).also { if (it == null) openHome() }

/** Disclosure accepted: record consent, write the home selection, return home. Declining calls nothing. */
internal fun acceptProviderDetailRealtime(
    pending: RealtimePickerDisclosure,
    disclosure: VoiceDisclosureStore,
    selection: HomeRealtimeSelectionStore,
    openHome: () -> Unit,
) {
    acceptRealtimeDisclosure(pending, disclosure, selection::set)
    openHome()
}

/**
 * The "Realtime voice" group after the "Added models" section (same as iOS). The group header has no count: the header "N available models" counts text only.
 * Row layout follows the "Added models" row (name + subtitle, no left thumbnail); check = home selection, trailing open-chat round button; tapping the row and the chat button do the same thing.
 */
internal fun LazyListScope.providerDetailRealtimeModels(
    state: ProviderDetailRealtimeState?,
    onStart: (VoiceRealtimeEntry) -> Unit,
) {
    if (state == null) return
    item(key = "realtime_models_header") {
        ProviderDetailSectionHeader(
            modifier = Modifier.padding(bottom = OriveoTheme.spacing.md),
            title = stringResource(R.string.voice_realtime_model_tag),
        )
    }
    item(key = "realtime_models_card") {
        val colors = OriveoTheme.colors
        val shape = RoundedCornerShape(16.dp)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .testTag("provider_detail_realtime_group")
                .clip(shape)
                .background(colors.surfaceElevated, shape)
                .border(1.dp, colors.border.opacity(0.72f), shape),
        ) {
            state.rows.forEachIndexed { index, row ->
                if (index > 0) {
                    // Row divider follows the Added models row: 0.5dp hairline indented 14dp from the left
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 14.dp)
                            .height(0.5.dp)
                            .background(colors.border.opacity(0.45f)),
                    )
                }
                ProviderDetailRealtimeModelRow(row = row, onStart = { onStart(row.entry) })
            }
        }
    }
    item(key = "realtime_models_bottom_spacer") {
        Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
    }
}

/** Layout copied from the Added models row (ProviderDetailEnabledModels.kt:EnabledModelRow): name + subtitle | check | chat button. */
@Composable
private fun ProviderDetailRealtimeModelRow(
    row: ProviderDetailRealtimeRow,
    onStart: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 14.dp, end = 10.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(8.dp))
                .testTag("provider_detail_realtime_model_row")
                .semantics { selected = row.checked }
                .clickable(onClick = onStart),
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = modelIdDisplay(row.entry.model),
                    modifier = Modifier.semantics { contentDescription = row.entry.model },
                    style = OriveoTheme.typography.title3,
                    color = colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = stringResource(R.string.voice_realtime_model_subtitle),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                    maxLines = 1,
                )
            }
            if (row.checked) {
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = null,
                    modifier = Modifier.size(17.dp),
                    tint = colors.primary,
                )
            }
        }
        RealtimeRowChatButton(
            onClick = onStart,
            contentDescription = stringResource(R.string.new_chat),
            modifier = Modifier
                .testTag("provider_detail_realtime_model_chat_button"),
        )
    }
}

/** Open-chat round button copied from the enabled row (ProviderDetailEnabledModels.kt:EnabledRowChatButton); realtime rows are always available; button semantics are exposed to screen readers. */
@Composable
private fun RealtimeRowChatButton(
    onClick: () -> Unit,
    contentDescription: String?,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Box(
        modifier = modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(color = colors.primarySoft, shape = CircleShape)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Forum,
            contentDescription = contentDescription,
            modifier = Modifier.size(13.dp),
            tint = colors.primary,
        )
    }
}
