package ai.oriveo.community.feature.providers.detail

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import ai.oriveo.community.feature.providers.relay.SetupDot
import ai.oriveo.community.feature.providers.relay.relayProtocolColor
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoBackButtonDefaults
import ai.oriveo.community.ui.theme.CapabilityPalette
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * "Model > Advanced" page: renders only [RelayModelAdvancedBoard]; all actions are called back to the detail page host (the ViewModel writes to the database).
 * Same sub-page pattern as the model library: a "current advanced-page model id" state is toggled in the detail page, and back returns to the model library.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun RelayModelAdvancedPage(
    board: RelayModelAdvancedBoard,
    onBack: () -> Unit,
    onRestoreAll: () -> Unit,
    onSelectProtocol: (RelayAdvancedProtocol) -> Unit,
    onSetCapability: (RelayAdvancedCapability, Boolean?) -> Unit,
    onToggleThinking: (ReasoningMode) -> Unit,
    onTestCapabilities: () -> Unit,
    contentPadding: PaddingValues,
    /** Key section menu selection (null = Auto). */
    onSelectKey: (String?) -> Unit = {},
) {
    val colors = OriveoTheme.colors
    // Read-only advanced page (entered from a catalog row): all controls are inoperable.
    val editable = !board.readOnly
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(contentPadding)
            .padding(horizontal = OriveoTheme.layout.screenH)
            .padding(top = OriveoTheme.spacing.sm, bottom = OriveoTheme.spacing.xxl),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OriveoBackButton(
                onClick = onBack,
                modifier = Modifier.offset(x = -OriveoBackButtonDefaults.EdgeInset),
            )
            // Page header: [Back · "Advanced" · Restore] on one row, with the model name and host below.
            Text(
                text = stringResource(R.string.relay_model_advanced_title),
                modifier = Modifier.weight(1f),
                style = OriveoTheme.typography.title2,
                color = colors.textPrimary,
                maxLines = 1,
            )
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(OriveoTheme.radius.sm))
                    .clickable(enabled = board.restoreAllEnabled, onClick = onRestoreAll)
                    .alpha(if (board.restoreAllEnabled) 1f else 0.4f)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    painter = painterResource(R.drawable.ph_arrow_counter_clockwise),
                    contentDescription = null,
                    modifier = Modifier.size(15.dp),
                    tint = colors.primary,
                )
                Text(
                    text = stringResource(R.string.relay_model_advanced_restore_all),
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),
                    color = colors.primary,
                )
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = board.modelName,
                style = OriveoTheme.typography.title3.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(text = board.host, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
        }

        board.readOnlyNoteRes?.let { note ->
            Text(
                text = stringResource(note),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(colors.surfaceInset.opacity(0.6f))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            )
        }

        board.sections.forEach { section ->
            when (section) {
                RelayAdvancedSection.Protocol -> board.protocol?.let { ProtocolCard(it, editable, onSelectProtocol) }
                RelayAdvancedSection.Key -> board.keySection?.let { KeyCard(it, onSelectKey) }
                RelayAdvancedSection.Channel -> board.channel?.let { ChannelCard(it) }
                RelayAdvancedSection.Capabilities -> CapabilitiesCard(board, onSetCapability, onTestCapabilities)
                RelayAdvancedSection.Thinking -> board.thinking?.let { ThinkingCard(it, editable, onToggleThinking) }
                RelayAdvancedSection.Legend -> FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    board.legend.forEach { SourceBadge(it) }
                }
                RelayAdvancedSection.Footer -> Text(
                    text = stringResource(board.footnoteRes),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                )
            }
        }
    }
}

/** Detail page host: computes the board in the background (getting the connection identity suspends) and forwards actions to the ViewModel. */
@Composable
internal fun RelayModelAdvancedHost(
    provider: ai.oriveo.community.core.model.Provider,
    model: ai.oriveo.community.core.model.AIModel,
    viewModel: ProviderDetailViewModel,
    providerRepository: ai.oriveo.community.core.data.repository.ProviderRepository,
    revisionKey: Any,
    contentPadding: PaddingValues,
    onBack: () -> Unit,
    /** Entered from a catalog row (model not enabled yet): read-only, and opening sends no request. */
    readOnly: Boolean = false,
) {
    val probe = viewModel.relayAdvancedProbe.takeUnless { readOnly }
    val computed by produceState<Pair<RelayModelAdvancedBoard, List<ReasoningMode>>?>(null, provider, model, probe, revisionKey, readOnly) {
        value = withContext(Dispatchers.Default) {
            val identity = providerRepository.capabilityEvidenceIdentity(
                provider,
                model.id,
                providerRepository.currentCapabilityPartitionId(),
            )
            val toolMemory = providerRepository.toolCallMemoryVerdict(provider, model)
            val automatic = RelayModelAdvancedBoard.automaticReasoning(provider, model)
            RelayModelAdvancedBoard.build(
                provider = provider,
                model = model,
                nowSeconds = System.currentTimeMillis() / 1000L,
                probe = probe,
                facts = RelayCatalogCapabilityFacts(identityFor = { identity }, toolMemoryFor = { toolMemory }),
                negativeCache = RelayNegativeCache.shared,
                toolMemory = toolMemory,
                automaticReasoning = automatic,
                readOnly = readOnly,
                identity = identity,
            ) to automatic
        }
    }
    val (board, automatic) = computed ?: return
    RelayModelAdvancedPage(
        board = board,
        onBack = onBack,
        onRestoreAll = { viewModel.restoreRelayModelAutomatic(model) },
        onSelectProtocol = { viewModel.setRelayModelTransport(model, it.transport) },
        onSetCapability = { capability, value -> viewModel.setRelayCapabilityOverride(model, capability, value) },
        onToggleThinking = { mode ->
            val current = model.relayCapabilityOverrides?.reasoningLevels
            val next = RelayModelAdvancedEdits.toggledReasoningLevels(automatic, current, mode)
            if (next != current) viewModel.setRelayReasoningLevels(model, next)
        },
        onTestCapabilities = {
            viewModel.requestRelayCapabilityTest(
                model = model,
                // The protocol shown in the panel = the first-send protocol the test actually sends.
                transport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model),
                // Key chip and the name in the description row: same criterion as the "Key" section, present only with 2 or more keys.
                keyName = board.keySection?.current?.title,
            )
        },
        contentPadding = contentPadding,
        onSelectKey = { choice ->
            board.keySection?.rebindTarget(choice)?.let { keyID -> viewModel.rebindRelayModelKey(model, keyID) }
        },
    )
}

@Composable
private fun AdvancedCard(@DrawableRes icon: Int, title: String, content: @Composable () -> Unit) {
    val colors = OriveoTheme.colors
    // Section layout: icon + title above the card; the card has only a background color and no border.
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(painter = painterResource(icon), contentDescription = null, modifier = Modifier.size(16.dp), tint = colors.textSecondary)
            Text(
                text = title,
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textSecondary,
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(colors.surfaceElevated)
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            content()
        }
    }
}

@Composable
private fun ProtocolCard(row: RelayAdvancedProtocolRow, editable: Boolean, onSelect: (RelayAdvancedProtocol) -> Unit) {
    val colors = OriveoTheme.colors
    AdvancedCard(R.drawable.ph_hard_drives, stringResource(R.string.relay_section_protocol)) {
        // Horizontally scrolling capsules; protocols carry a color dot (Auto has none).
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            row.segments.forEach { segment ->
                val selected = segment == row.selected
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (selected) colors.primarySoft else colors.surfaceInset.opacity(0.6f))
                        .clickable(enabled = editable && !selected) { onSelect(segment) }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    segment.transport?.let { SetupDot(relayProtocolColor(RelayBoardProtocol.of(it))) }
                    Text(
                        text = protocolLabel(segment),
                        style = OriveoTheme.typography.caption.copy(
                            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        ),
                        color = if (selected) colors.primary else colors.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
        // Two description rows: row 1 appears only when Auto is selected; row 2 = status word · root address.
        row.autoEquals?.let { protocol ->
            Text(
                text = if (row.autoFollowsConnection) {
                    stringResource(R.string.relay_model_advanced_auto_equals_connection, protocol.legend)
                } else {
                    stringResource(R.string.relay_model_advanced_auto_equals, protocol.legend)
                },
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
        Text(
            text = listOf(
                stringResource(row.status.textRes),
                stringResource(R.string.relay_model_advanced_api_root, row.apiRootPath),
            ).joinToString(" · "),
            style = OriveoTheme.typography.footnote,
            color = if (row.status == RelayAdvancedProtocolStatus.NotReachable) colors.warningText else colors.textSecondary,
        )
    }
}

@Composable
private fun protocolLabel(segment: RelayAdvancedProtocol): String = when (segment) {
    RelayAdvancedProtocol.Auto -> stringResource(R.string.relay_profile_auto)
    // Protocol names are literals and are not translated (same as the model library protocol chips).
    else -> RelayBoardProtocol.of(requireNotNull(segment.transport)).legend
}

/** "Key" section: current binding + the "Auto" menu entry and every key; a note below the section explains what Auto means. */
@Composable
private fun KeyCard(section: RelayAdvancedKeySection, onSelect: (String?) -> Unit) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    AdvancedCard(R.drawable.ph_key, stringResource(R.string.relay_advanced_key_section)) {
        // Advanced key row: left column [name / mask / hint] | menu, with the menu vertically centered over the whole row. (whole-row vertical centering)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = section.current.title,
                    style = OriveoTheme.typography.body,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                )
                if (section.current.maskedSecret != section.current.title) {
                    Text(
                        text = section.current.maskedSecret,
                        style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
                        color = colors.textSecondary,
                    )
                }
                Text(text = stringResource(section.hintRes), style = OriveoTheme.typography.footnote, color = colors.textTertiary)
            }
            Box {
                MenuChip(
                    text = if (section.followsAuto) stringResource(R.string.relay_profile_auto) else section.current.title,
                    isAuto = section.followsAuto,
                    enabled = section.interactive,
                    onClick = { expanded = true },
                )
                if (expanded) {
                    DropdownMenu(expanded = true, onDismissRequest = { expanded = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.relay_profile_auto)) },
                            onClick = {
                                expanded = false
                                onSelect(null)
                            },
                            modifier = Modifier,
                        )
                        section.keys.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option.title) },
                                onClick = {
                                    expanded = false
                                    onSelect(option.keyId)
                                },
                                modifier = Modifier,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** Menu chip: capsule; Auto = secondary, the others primary. */
@Composable
private fun MenuChip(text: String, isAuto: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    val tint = if (isAuto) colors.textSecondary else colors.primary
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(colors.surfaceInset.opacity(0.6f))
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.5f)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(text = text, style = OriveoTheme.typography.footnote, color = tint, maxLines = 1)
        Icon(painter = painterResource(R.drawable.ph_caret_down), contentDescription = null, modifier = Modifier.size(12.dp), tint = tint)
    }
}

@Composable
private fun ChannelCard(row: RelayAdvancedChannelRow) {
    val colors = OriveoTheme.colors
    AdvancedCard(R.drawable.ph_hard_drives, stringResource(R.string.local_setup_tile_channel)) {
        // Channel row: left column "Channel" + hint | value, with the value vertically centered over the whole row. (whole-row vertical centering)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(text = stringResource(R.string.local_setup_tile_channel), style = OriveoTheme.typography.body, color = colors.textPrimary)
                if (row.showsHint) {
                    Text(
                        text = stringResource(R.string.relay_model_advanced_channel_hint),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textTertiary,
                    )
                }
            }
            Text(text = stringResource(row.valueRes), style = OriveoTheme.typography.body, color = colors.textSecondary)
        }
    }
}

@DrawableRes
private fun capabilityIcon(capability: RelayAdvancedCapability): Int = when (capability) {
    RelayAdvancedCapability.Image -> R.drawable.ph_eye
    RelayAdvancedCapability.File -> R.drawable.ph_paperclip
    RelayAdvancedCapability.ImageGeneration -> R.drawable.ph_image
    RelayAdvancedCapability.ToolCall -> R.drawable.ph_wrench
    RelayAdvancedCapability.Web -> R.drawable.ph_globe
}

@Composable
private fun capabilityTint(capability: RelayAdvancedCapability): Color = when (capability) {
    RelayAdvancedCapability.Image -> CapabilityPalette.vision
    RelayAdvancedCapability.File -> CapabilityPalette.attachment
    // Image generation is not in the five-color capability palette, so a neutral color is used.
    RelayAdvancedCapability.ImageGeneration -> OriveoTheme.colors.textSecondary
    RelayAdvancedCapability.ToolCall -> CapabilityPalette.tools
    RelayAdvancedCapability.Web -> CapabilityPalette.webSearch
}

@DrawableRes
private fun sourceIcon(source: RelayAdvancedSource): Int = when (source) {
    RelayAdvancedSource.Catalog -> R.drawable.ph_database
    RelayAdvancedSource.Detected -> R.drawable.ph_scan
    RelayAdvancedSource.Tested -> R.drawable.ph_check_circle
    RelayAdvancedSource.Engine -> R.drawable.ph_hard_drives
    RelayAdvancedSource.User -> R.drawable.ph_user
}

@Composable
private fun SourceBadge(
    source: RelayAdvancedSource,
    style: TextStyle = OriveoTheme.typography.caption,
    tint: Color = OriveoTheme.colors.textTertiary,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(painter = painterResource(sourceIcon(source)), contentDescription = null, modifier = Modifier.size(12.dp), tint = tint)
        Text(text = stringResource(source.labelRes), style = style, color = tint)
    }
}

@Composable
private fun controlLabel(control: RelayAdvancedControl): String = stringResource(
    when (control) {
        RelayAdvancedControl.Auto -> R.string.relay_profile_auto
        RelayAdvancedControl.On -> R.string.advanced_state_on
        RelayAdvancedControl.Off -> R.string.model_control_off
    },
)

@Composable
private fun CapabilitiesCard(
    board: RelayModelAdvancedBoard,
    onSetCapability: (RelayAdvancedCapability, Boolean?) -> Unit,
    onTestCapabilities: () -> Unit,
) {
    val colors = OriveoTheme.colors
    AdvancedCard(R.drawable.ph_lightning, stringResource(R.string.relay_model_advanced_capabilities)) {
        board.capabilities.forEachIndexed { index, row ->
            if (index > 0) {
                Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.border.opacity(0.72f)))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(
                    painter = painterResource(capabilityIcon(row.capability)),
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = if (row.state == RelayCatalogCapabilityState.Supported) capabilityTint(row.capability) else colors.textTertiary,
                )
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(text = stringResource(row.capability.titleRes), style = OriveoTheme.typography.body, color = colors.textPrimary)
                    // "Status · badge" is entirely footnote secondary.
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(text = stringResource(row.statusRes), style = OriveoTheme.typography.footnote, color = colors.textSecondary)
                        row.source?.let {
                            Text(text = "·", style = OriveoTheme.typography.footnote, color = colors.textSecondary)
                            SourceBadge(it, style = OriveoTheme.typography.footnote, tint = colors.textSecondary)
                        }
                    }
                }
                CapabilityControl(row, enabled = !board.readOnly) { value -> onSetCapability(row.capability, value) }
            }
        }
        // Test entry: plain-text primary at the start of the row.
        if (board.offersCapabilityTest) {
            Text(
                text = stringResource(R.string.relay_capability_test),
                style = OriveoTheme.typography.body,
                color = colors.primary,
                modifier = Modifier
                    .clickable(onClick = onTestCapabilities)
                    .padding(vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun CapabilityControl(row: RelayAdvancedCapabilityRow, enabled: Boolean, onSelect: (Boolean?) -> Unit) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    Box {
        MenuChip(
            text = controlLabel(row.control),
            isAuto = row.control == RelayAdvancedControl.Auto,
            enabled = enabled,
            onClick = { expanded = true },
        )
        if (expanded) {
            DropdownMenu(expanded = true, onDismissRequest = { expanded = false }) {
                RelayAdvancedControl.entries.forEach { control ->
                    DropdownMenuItem(
                        text = { Text(controlLabel(control)) },
                        onClick = {
                            expanded = false
                            if (control != row.control) {
                                onSelect(
                                    when (control) {
                                        RelayAdvancedControl.Auto -> null
                                        RelayAdvancedControl.On -> true
                                        RelayAdvancedControl.Off -> false
                                    },
                                )
                            }
                        },
                        modifier = Modifier,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ThinkingCard(thinking: RelayAdvancedThinking, editable: Boolean, onToggle: (ReasoningMode) -> Unit) {
    val colors = OriveoTheme.colors
    AdvancedCard(R.drawable.ph_brain, stringResource(R.string.relay_model_advanced_thinking_levels)) {
        when (thinking) {
            // Outlined capsules, horizontal scrolling, thinking color.
            is RelayAdvancedThinking.Levels -> Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                thinking.cells.forEach { cell ->
                    Text(
                        text = stringResource(cell.mode.titleResId),
                        style = OriveoTheme.typography.footnote.copy(
                            fontWeight = if (cell.selected) FontWeight.SemiBold else FontWeight.Normal,
                            textDecoration = if (cell.available) null else TextDecoration.LineThrough,
                        ),
                        color = when {
                            cell.selected -> CapabilityPalette.reasoning
                            cell.available -> colors.textPrimary
                            else -> colors.textTertiary
                        },
                        modifier = Modifier
                            .clip(CircleShape)
                            .border(1.dp, if (cell.selected) CapabilityPalette.reasoning else colors.border, CircleShape)
                            .background(if (cell.selected) CapabilityPalette.reasoning.opacity(0.12f) else Color.Transparent)
                            .clickable(enabled = editable && cell.available) { onToggle(cell.mode) }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
            }
        }
    }
}
