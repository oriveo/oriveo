package ai.oriveo.community.feature.chat.modelcontrols

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.feature.chat.composer.ModelControlHairline
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Capability
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Escape
import ai.oriveo.community.feature.providers.detail.generationParameterTitleRes
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.modelControlTextButtonColors

/**
 * Card components of the model options panel.
 * Rendering only: how a capability card looks comes entirely from [ModelOptionCapabilityShape.resolve], the chips of the parameter card come from
 * [GenerationParameterRowModel.summary] and the status mark comes from [ModelOptionsStatusMark.resolve].
 */

/** Header: model name plus a close button, then a line with connection, protocol and status mark. 24dp of top padding (a sheet without a navigation bar). */
@Composable
internal fun ModelOptionsHeader(
    modelName: String,
    subtitleParts: List<String>,
    isLocal: Boolean,
    mark: ModelOptionsStatusMark,
    onClose: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 6.dp, top = 24.dp, bottom = 4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = modelName,
                fontSize = 22.sp,
                lineHeight = 25.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                val parts = subtitleParts + listOfNotNull(stringResource(R.string.model_options_local).takeIf { isLocal })
                parts.forEachIndexed { index, part ->
                    if (index > 0) SubtitleDot()
                    Text(part, fontSize = 13.sp, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                mark.labelRes?.let { labelRes ->
                    if (parts.isNotEmpty()) SubtitleDot()
                    StatusMark(mark, stringResource(labelRes))
                }
            }
        }
        val closeLabel = stringResource(R.string.close)
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .clickable(onClick = onClose)
                .semantics {
                    role = Role.Button
                    contentDescription = closeLabel
                },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier.size(30.dp).background(colors.surfaceInset, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Close, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(14.dp))
            }
        }
    }
}

@Composable
private fun SubtitleDot() {
    Box(Modifier.size(2.5.dp).background(OriveoTheme.colors.textTertiary, CircleShape))
}

@Composable
private fun StatusMark(mark: ModelOptionsStatusMark, label: String) {
    val colors = OriveoTheme.colors
    val tint = when (mark) {
        ModelOptionsStatusMark.Official -> colors.success
        ModelOptionsStatusMark.Unverified -> colors.warningText
        ModelOptionsStatusMark.None -> colors.textSecondary
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.size(6.dp).background(tint, CircleShape))
        Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = tint, maxLines = 1)
    }
}

/** The actions of one row in a capability card; every criterion lives in the caller and this only wires them up. */
internal class CapabilityRowActions(
    val onToggle: (Boolean) -> Unit,
    val onSelectTier: (String) -> Unit,
    val onSelectTiming: (String) -> Unit,
    val onEscape: (Escape) -> Unit,
    /** When the model itself cannot do it the whole row leads to switching models; null means the row is not tappable. */
    val onDisclosure: (() -> Unit)?,
    /** The chat-template switch cannot be toggled while the additional request body is unavailable or not sent with the request. */
    val toggleEnabled: Boolean = true,
    /** The way out under the explanation when the switch cannot be toggled (go to the additional request body); null when there is none. */
    val toggleEscape: Escape? = null,
    /** The sentence that replaces the explanation when the switch cannot be toggled; null uses the shape's default explanation. */
    @StringRes val toggleBlockedNoteRes: Int? = null,
)

/** One row of a capability card: draws a switch, segments, timing, a notice or a status row according to the shape. */
@Composable
internal fun ModelOptionCapabilityRow(
    capability: Capability,
    shape: ModelOptionCapabilityShape,
    actions: CapabilityRowActions,
) {
    val title = stringResource(if (capability == Capability.Web) R.string.model_control_web_search else R.string.model_control_thinking)
    val toggleTag = if (capability == Capability.Web) "model_options_web_toggle" else "model_options_thinking_toggle"
    when (shape) {
        is ModelOptionCapabilityShape.Toggle -> Column {
            ToggleRow(
                title = title,
                note = stringResource(actions.toggleBlockedNoteRes ?: ModelOptionsRender.toggleNoteRes(capability, shape.kind)),
                isOn = shape.isOn == true,
                enabled = actions.toggleEnabled,
                onToggle = actions.onToggle,
            )
            actions.toggleEscape?.let { escape ->
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = { actions.onEscape(escape) },
                    modifier = Modifier.padding(start = 4.dp).heightIn(min = 44.dp),
                ) { Text(stringResource(ModelOptionsRender.escapeRes(escape))) }
            }
        }
        is ModelOptionCapabilityShape.ToggleWithTiming -> Column {
            ToggleRow(
                title = title,
                note = stringResource(ModelOptionsRender.toggleNoteRes(capability, ModelOptionCapabilityShape.ToggleKind.Capability)),
                isOn = true,
                enabled = actions.toggleEnabled,
                onToggle = actions.onToggle,
            )
            Box(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 14.dp)) {
                Segments(
                    options = shape.timings,
                    selected = shape.selectedTiming,
                    label = { ModelOptionsRender.timingLabelRes(it) },
                    level = { null },
                    onSelect = actions.onSelectTiming,
                )
            }
        }
        is ModelOptionCapabilityShape.Tiers -> TiersBlock(title, shape, actions.onSelectTier)
        is ModelOptionCapabilityShape.Notice -> Column(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 15.dp, bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            TitleWithTrailing(title, stringResource(ModelOptionsRender.noticeStatusRes(shape.status)))
            Text(stringResource(ModelOptionsRender.noticeBodyRes(shape.body)), fontSize = 12.5.sp, color = OriveoTheme.colors.textSecondary)
            TextButton(
                colors = modelControlTextButtonColors(),
                onClick = { actions.onEscape(shape.escape) },
                modifier = Modifier.heightIn(min = 44.dp),
            ) { Text(stringResource(ModelOptionsRender.escapeRes(shape.escape))) }
        }
        is ModelOptionCapabilityShape.Disclosure -> StatusRow(
            title = title,
            trailing = if (shape.status == ModelOptionCapabilityShape.DisclosureStatus.ReadOnlyValue) {
                shape.value?.let { readOnlyValueLabel(capability, it) } ?: stringResource(R.string.model_options_cant_switch_here)
            } else {
                stringResource(ModelOptionsRender.disclosureRes(shape.status))
            },
            onClick = actions.onDisclosure,
        )
        // While the protocol is undecided the whole card is replaced by [ModelOptionsProtocolCard], so a row never gets here.
        ModelOptionCapabilityShape.ProtocolUndecided -> Unit
    }
}

@Composable
private fun readOnlyValueLabel(capability: Capability, value: String): String = when {
    capability == Capability.Reasoning -> stringResource(ModelOptionsRender.tierLabelRes(value))
    value == ModelOptionCapabilityShape.OFF -> stringResource(R.string.model_control_off)
    else -> stringResource(ModelOptionsRender.timingLabelRes(value))
}

@Composable
private fun ToggleRow(title: String, note: String, isOn: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 58.dp).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
            Text(note, fontSize = 12.5.sp, color = colors.textSecondary)
        }
        Spacer(Modifier.width(10.dp))
        Switch(
            checked = isOn,
            onCheckedChange = onToggle,
            enabled = enabled,
            modifier = Modifier.semantics { contentDescription = title },
        )
    }
}

@Composable
private fun TitleWithTrailing(title: String, trailing: String?) {
    val colors = OriveoTheme.colors
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary, modifier = Modifier.weight(1f))
        trailing?.let { Text(it, fontSize = 12.5.sp, color = colors.textSecondary) }
    }
}

@Composable
private fun TiersBlock(title: String, shape: ModelOptionCapabilityShape.Tiers, onSelect: (String) -> Unit) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 15.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val rejected = shape.rejected
        TitleWithTrailing(
            title,
            shape.trailingNote?.let { stringResource(R.string.model_options_always_thinks) },
        )
        Segments(
            options = shape.tiers,
            selected = shape.selected,
            label = { ModelOptionsRender.tierLabelRes(it) },
            level = { tier -> ModelOptionCapabilityShape.TIER_ORDER.indexOf(tier).takeIf { it >= 0 }?.plus(1) },
            onSelect = onSelect,
        )
        if (rejected != null) {
            val tierLabel = stringResource(ModelOptionsRender.tierLabelRes(rejected.tier))
            Text(stringResource(R.string.model_options_tier_rejected_title, tierLabel), fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.warningText)
            val fallback = rejected.fallback?.let { stringResource(ModelOptionsRender.tierLabelRes(it)) }
            if (fallback != null) {
                Text(stringResource(R.string.model_options_tier_rejected_body, tierLabel, fallback), fontSize = 12.5.sp, color = colors.textSecondary)
            }
        } else {
            shape.footnote?.let { footnote ->
                val note = ModelOptionsRender.tierNoteRes(footnote.tierCaption)?.let { stringResource(it) }
                val more = stringResource(R.string.model_options_higher_levels_note)
                    .takeIf { ModelOptionsRender.appendsHigherLevelsNote(footnote.tierCaption) }
                listOfNotNull(note, more).joinToString(" ").takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 12.5.sp, color = colors.textPrimary.copy(alpha = 0.82f))
                }
            }
        }
    }
}

/** Segments: equal-width cells, the selected one drawn with a white background and purple text. When [level] is set an effort bar is drawn. */
@Composable
private fun Segments(
    options: List<String>,
    selected: String?,
    label: (String) -> Int,
    level: (String) -> Int?,
    onSelect: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surfaceInset, RoundedCornerShape(14.dp))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { option ->
            val isSelected = option == selected
            val tint = if (isSelected) colors.primaryTextSafe else colors.textSecondary
            Column(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 56.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(if (isSelected) colors.surfaceElevated else Color.Transparent)
                    .clickable { onSelect(option) }
                    .semantics {
                        role = Role.RadioButton
                        this.selected = isSelected
                    },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterVertically),
            ) {
                level(option)?.let { LevelBars(it, tint) }
                Text(
                    stringResource(label(option)),
                    fontSize = 13.sp,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    color = tint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun LevelBars(filled: Int, tint: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(2.5.dp), verticalAlignment = Alignment.Bottom, modifier = Modifier.height(13.dp)) {
        listOf(4, 7, 10, 13).forEachIndexed { index, height ->
            Box(
                Modifier
                    .width(3.dp)
                    .height(height.dp)
                    .background(if (index < filled) tint else OriveoTheme.colors.border, RoundedCornerShape(1.5.dp)),
            )
        }
    }
}

@Composable
private fun StatusRow(title: String, trailing: String, onClick: (() -> Unit)?) {
    val colors = OriveoTheme.colors
    val base = Modifier.fillMaxWidth().heightIn(min = 58.dp)
    Row(
        modifier = (if (onClick != null) base.clickable(onClick = onClick) else base)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary, modifier = Modifier.weight(1f))
        Text(trailing, fontSize = 14.sp, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (onClick != null) {
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.padding(start = 4.dp).size(16.dp),
            )
        }
    }
}

/** The protocol is still "automatic": the whole card collapses to one ask, choose a protocol first. */
@Composable
internal fun ModelOptionsProtocolCard(onChooseProtocol: () -> Unit) {
    AdvancedCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 15.dp, bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(stringResource(R.string.model_options_choose_protocol_first), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = OriveoTheme.colors.textPrimary)
            Text(stringResource(R.string.model_options_protocol_auto_note), fontSize = 12.5.sp, color = OriveoTheme.colors.textSecondary)
            TextButton(
                colors = modelControlTextButtonColors(),
                onClick = onChooseProtocol,
                modifier = Modifier.heightIn(min = 44.dp),
            ) { Text(stringResource(R.string.model_options_choose_protocol)) }
        }
    }
}

/** The capability card: web search on top, thinking below, with an indented divider between them. */
@Composable
internal fun ModelOptionCapabilityCard(rows: List<@Composable () -> Unit>) {
    AdvancedCard {
        rows.forEachIndexed { index, row ->
            if (index > 0) ModelControlHairline()
            row()
        }
    }
}

/** The parameter card: one row leading to the advanced settings, with at most two chips for set items plus "N more" and an arrow. */
@Composable
internal fun ModelOptionParameterCard(summary: GenerationParameterRowModel.Summary, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    AdvancedCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 58.dp)
                .clickable(onClick = onClick)
                .semantics { role = Role.Button }
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.generation_model_behavior), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                if (summary.chips.isEmpty()) {
                    Text(stringResource(R.string.advanced_not_adjusted), fontSize = 14.sp, color = colors.textSecondary)
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        summary.chips.forEach { chip -> SetChip(chip) }
                        if (summary.moreCount > 0) {
                            Text(
                                stringResource(R.string.model_options_more_count, summary.moreCount),
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                color = colors.textSecondary,
                                maxLines = 1,
                                modifier = Modifier
                                    .background(colors.surfaceInset, RoundedCornerShape(13.dp))
                                    .padding(horizontal = 9.dp, vertical = 4.dp),
                            )
                        }
                    }
                }
            }
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun SetChip(chip: GenerationParameterRowModel.Chip) {
    val colors = OriveoTheme.colors
    val value = when (val display = chip.display) {
        is GenerationParameterRowModel.DisplayValue.Value -> display.text
        GenerationParameterRowModel.DisplayValue.Omitted -> stringResource(R.string.generation_parameter_omitted_value)
        is GenerationParameterRowModel.DisplayValue.Fallback -> display.text ?: stringResource(R.string.generation_parameter_default)
    }
    Row(
        modifier = Modifier
            .background(colors.primarySoft, RoundedCornerShape(13.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(stringResource(generationParameterTitleRes(chip.id)), fontSize = 13.sp, color = colors.primaryTextSafe.copy(alpha = 0.85f), maxLines = 1)
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = colors.primaryTextSafe, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
