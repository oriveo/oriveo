package ai.oriveo.community.feature.chat.modelcontrols

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
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
import ai.oriveo.community.feature.chat.composer.modelControlSurface
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Capability
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Escape
import ai.oriveo.community.feature.providers.detail.generationParameterTitleRes
import ai.oriveo.community.ui.theme.CapabilityPalette
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

/** The actions of one card in the capability grid; every criterion lives in the caller and this only wires them up. */
internal class CapabilityRowActions(
    val onToggle: (Boolean) -> Unit,
    val onSelectTier: (String) -> Unit,
    val onSelectTiming: (String) -> Unit,
    val onEscape: (Escape) -> Unit,
    /** When the model itself cannot do it the whole card leads to switching models; null means the card is not tappable. */
    val onDisclosure: (() -> Unit)?,
    /** The chat-template switch cannot be toggled while the additional request body is unavailable or not sent with the request. */
    val toggleEnabled: Boolean = true,
    /** The way out under the explanation when the switch cannot be toggled (go to the additional request body); null when there is none. */
    val toggleEscape: Escape? = null,
    /** The sentence that replaces the explanation when the switch cannot be toggled; null uses the shape's default explanation. */
    @StringRes val toggleBlockedNoteRes: Int? = null,
    /** Only when the protocol of this row is undecided does the whole card lead to choosing a protocol. */
    val onChooseProtocol: () -> Unit = {},
)

/**
 * The 2x2 grid of the capability area: two equal-height columns; with an accessibility large font (fontScale >= 1.5) it falls back to a single column.
 * The kinds and order of the cards all come from [ModelOptionsTiles.board]; this only lays them out.
 */
@Composable
internal fun ModelOptionsBoard(
    tiles: List<ModelOptionsTiles.Tile>,
    tile: @Composable (ModelOptionsTiles.Tile) -> Unit,
) {
    val columns = if (ModelOptionsTiles.singleColumn(LocalDensity.current.fontScale)) 1 else 2
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        tiles.chunked(columns).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                row.forEach { item -> Box(Modifier.weight(1f).fillMaxHeight()) { tile(item) } }
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

/** Web / thinking card: the look comes from [ModelOptionsTiles.capabilityTile], the actions are wired by shape. */
@Composable
internal fun ModelOptionCapabilityRow(
    capability: Capability,
    shape: ModelOptionCapabilityShape,
    actions: CapabilityRowActions,
) {
    val tile = ModelOptionsTiles.capabilityTile(capability, shape, actions.toggleBlockedNoteRes)
    val title = stringResource(if (capability == Capability.Web) R.string.model_control_web_search else R.string.model_control_thinking)
    val onClick: (() -> Unit)? = when (shape) {
        is ModelOptionCapabilityShape.Notice -> shape.escape?.let { escape -> { actions.onEscape(escape) } }
        is ModelOptionCapabilityShape.Disclosure -> actions.onDisclosure?.takeIf { tile.tappable }
        ModelOptionCapabilityShape.ProtocolUndecided -> actions.onChooseProtocol
        else -> null
    }
    OptionTileFrame(
        tile = tile,
        title = title,
        onClick = onClick,
        corner = {
            when (tile.corner) {
                ModelOptionsTiles.Corner.Switch -> Switch(
                    checked = shape is ModelOptionCapabilityShape.ToggleWithTiming ||
                        (shape as? ModelOptionCapabilityShape.Toggle)?.isOn == true,
                    onCheckedChange = actions.onToggle,
                    enabled = actions.toggleEnabled,
                    modifier = Modifier.semantics { contentDescription = title },
                )
                ModelOptionsTiles.Corner.Levels -> Text(
                    pluralStringResource(R.plurals.model_options_reasoning_level_count, tile.levelCount, tile.levelCount),
                    fontSize = 13.sp,
                    color = OriveoTheme.colors.textSecondary,
                    maxLines = 1,
                )
                else -> CornerMark(tile.corner)
            }
        },
    ) {
        when (shape) {
            is ModelOptionCapabilityShape.Tiers -> Segments(
                options = shape.tiers,
                selected = shape.selected,
                label = { ModelOptionsRender.tierLabelRes(it) },
                // The card has no room for tier words: it draws icons only (automatic sparkle / off dash / bars), and the accessibility name stays the tier word.
                level = { null },
                iconOnly = true,
                onSelect = actions.onSelectTier,
            )
            is ModelOptionCapabilityShape.ToggleWithTiming -> Segments(
                options = shape.timings,
                selected = shape.selectedTiming,
                label = { ModelOptionsRender.timingLabelRes(it) },
                level = { null },
                onSelect = actions.onSelectTiming,
            )
            is ModelOptionCapabilityShape.Toggle -> actions.toggleEscape?.let { escape ->
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = { actions.onEscape(escape) },
                    modifier = Modifier.heightIn(min = 44.dp),
                ) { Text(stringResource(ModelOptionsRender.escapeRes(escape))) }
            }
            else -> Unit
        }
    }
}

/** Vision / file info card: read-only, with a check / question / x at the top right. */
@Composable
internal fun ModelOptionInfoTile(tile: ModelOptionsTiles.Tile) {
    val title = stringResource(if (tile.kind == ModelOptionsTiles.Kind.Vision) R.string.capability_image else R.string.capability_file)
    OptionTileFrame(tile = tile, title = title, onClick = null, corner = { CornerMark(tile.corner) }) {}
}

@Composable
private fun OptionTileFrame(
    tile: ModelOptionsTiles.Tile,
    title: String,
    onClick: (() -> Unit)?,
    corner: @Composable () -> Unit,
    extra: @Composable () -> Unit,
) {
    val colors = OriveoTheme.colors
    val (iconRes, tint) = when (tile.kind) {
        ModelOptionsTiles.Kind.Web -> R.drawable.ph_globe_duotone to CapabilityPalette.webSearch
        ModelOptionsTiles.Kind.Reasoning -> R.drawable.ph_brain_duotone to CapabilityPalette.reasoning
        ModelOptionsTiles.Kind.Vision -> R.drawable.ph_eye_duotone to CapabilityPalette.vision
        ModelOptionsTiles.Kind.File -> R.drawable.ph_paperclip_duotone to CapabilityPalette.attachment
    }
    val base = Modifier.fillMaxSize().modelControlSurface().clip(RoundedCornerShape(20.dp))
    Column(
        modifier = (if (onClick != null) base.clickable(onClick = onClick).semantics { role = Role.Button } else base)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth().heightIn(min = 32.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(iconRes), contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
            Spacer(Modifier.weight(1f))
            corner()
        }
        Spacer(Modifier.height(6.dp))
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
        Text(stringResource(tile.statusRes), fontSize = 12.5.sp, color = colors.textSecondary)
        tile.bodyRes?.let { Text(stringResource(it), fontSize = 12.sp, color = colors.textTertiary) }
        extra()
    }
}

@Composable
private fun CornerMark(corner: ModelOptionsTiles.Corner) {
    val colors = OriveoTheme.colors
    val (iconRes, tint) = when (corner) {
        ModelOptionsTiles.Corner.Check -> R.drawable.ph_check to colors.success
        ModelOptionsTiles.Corner.Question -> R.drawable.ph_question to colors.textSecondary
        ModelOptionsTiles.Corner.Cross -> R.drawable.ph_x to colors.textTertiary
        ModelOptionsTiles.Corner.Chevron -> {
            Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
            return
        }
        else -> return
    }
    Icon(painterResource(iconRes), contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
}

/** The footnote and the rejected-tier warning of the thinking tiers stay below the grid, not inside the card. */
@Composable
internal fun ModelOptionTierNotes(shape: ModelOptionCapabilityShape) {
    val tiers = shape as? ModelOptionCapabilityShape.Tiers ?: return
    val colors = OriveoTheme.colors
    Column(modifier = Modifier.padding(horizontal = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val rejected = tiers.rejected
        if (rejected != null) {
            val tierLabel = stringResource(ModelOptionsRender.tierLabelRes(rejected.tier))
            Text(stringResource(R.string.model_options_tier_rejected_title, tierLabel), fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.warningText)
            val fallback = rejected.fallback?.let { stringResource(ModelOptionsRender.tierLabelRes(it)) }
            if (fallback != null) {
                Text(stringResource(R.string.model_options_tier_rejected_body, tierLabel, fallback), fontSize = 12.5.sp, color = colors.textSecondary)
            }
        } else {
            tiers.footnote?.let { footnote ->
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

/** The "this turn actually sends" summary strip: nothing is shown when there is no item at all. */
@Composable
internal fun ModelOptionsTurnSummary(items: List<ModelOptionsTiles.SummaryItem>) {
    if (items.isEmpty()) return
    val colors = OriveoTheme.colors
    val text = items.map { item ->
        when (item) {
            ModelOptionsTiles.SummaryItem.WebOn -> stringResource(R.string.model_options_summary_web_on)
            ModelOptionsTiles.SummaryItem.ThinkingOn -> stringResource(R.string.model_options_summary_thinking_on)
            is ModelOptionsTiles.SummaryItem.ThinkingLevel ->
                stringResource(R.string.model_options_summary_thinking_level, stringResource(item.tierRes))
        }
    }.joinToString(" · ")
    Text(
        stringResource(R.string.model_options_turn_summary, text),
        fontSize = 13.sp,
        color = colors.primaryTextSafe,
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.primarySoft, RoundedCornerShape(16.dp))
            .padding(horizontal = 16.dp, vertical = 12.dp),
    )
}

/** Segments: equal-width cells, the selected one drawn with a white background and purple text. When [level] is set an effort bar is drawn; with [iconOnly] only the icon is drawn and the tier word goes into the accessibility name only. */
@Composable
private fun Segments(
    options: List<String>,
    selected: String?,
    label: (String) -> Int,
    level: (String) -> Int?,
    onSelect: (String) -> Unit,
    iconOnly: Boolean = false,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp)
            .background(colors.surfaceInset, RoundedCornerShape(14.dp))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { option ->
            val isSelected = option == selected
            val tint = if (isSelected) colors.primaryTextSafe else colors.textSecondary
            val name = stringResource(label(option))
            Column(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(if (isSelected) colors.surfaceElevated else Color.Transparent)
                    .clickable { onSelect(option) }
                    .semantics {
                        role = Role.RadioButton
                        this.selected = isSelected
                        if (iconOnly) contentDescription = name
                    },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterVertically),
            ) {
                if (iconOnly) TierGlyphIcon(ModelOptionsTiles.tierGlyph(option), tint)
                level(option)?.let { LevelBars(it, tint) }
                if (!iconOnly) {
                    Text(
                        name,
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
}

/** Eight short strokes on the same 15x13 viewBox as the web (the counterpart of the iOS SF Symbol rays), stroke 1.6, round caps. */
private const val AUTOMATIC_RAYS_PATH =
    "M7.5 1v2.2M7.5 9.8V12M2 6.5h2.2M10.8 6.5H13M3.6 2.6l1.5 1.5M9.9 8.9l1.5 1.5M11.4 2.6L9.9 4.1M5.1 8.9l-1.5 1.5"
private val automaticRays = PathParser().parsePathString(AUTOMATIC_RAYS_PATH).toPath()

@Composable
private fun TierGlyphIcon(glyph: ModelOptionsTiles.TierGlyph, tint: Color) {
    when (glyph) {
        ModelOptionsTiles.TierGlyph.Automatic -> Canvas(Modifier.width(15.dp).height(13.dp)) {
            scale(scaleX = size.width / 15f, scaleY = size.height / 13f, pivot = Offset.Zero) {
                drawPath(automaticRays, tint, style = Stroke(width = 1.6f, cap = StrokeCap.Round))
            }
        }
        ModelOptionsTiles.TierGlyph.Off -> OffDash(tint)
        is ModelOptionsTiles.TierGlyph.Bars -> LevelBars(glyph.filled, tint)
    }
}

/** "Off": a rounded horizontal dash, the current tint dimmed to 0.55. */
@Composable
private fun OffDash(tint: Color) {
    Box(Modifier.height(13.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.width(13.dp).height(2.5.dp).background(tint.copy(alpha = 0.55f), RoundedCornerShape(1.25.dp)))
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

/**
 * The parameter card: a temperature row (shown only when advancedRows has one) plus the original advanced settings entry row (its chips no longer include temperature);
 * both rows lead to the advanced settings page.
 */
@Composable
internal fun ModelOptionParameterCard(
    temperature: GenerationParameterRowModel?,
    summary: GenerationParameterRowModel.Summary,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    AdvancedCard {
        temperature?.let { row ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 58.dp)
                    .clickable(onClick = onClick)
                    .semantics { role = Role.Button }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ModelOptionParameterCardIcon(ModelOptionParameterCardIcons.temperature)
                Text(
                    stringResource(generationParameterTitleRes(row.id)),
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    generationParameterDisplayText(row.display),
                    fontSize = 14.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 8.dp),
                )
                Icon(
                    Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                    contentDescription = null,
                    tint = colors.textTertiary,
                    modifier = Modifier.padding(start = 4.dp).size(16.dp),
                )
            }
            ModelControlHairline()
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 58.dp)
                .clickable(onClick = onClick)
                .semantics { role = Role.Button }
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ModelOptionParameterCardIcon(ModelOptionParameterCardIcons.entry)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.generation_parameters_section), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
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

/** The leading icons of the two parameter card rows: neutral secondary color, not a capability color. */
internal object ModelOptionParameterCardIcons {
    @DrawableRes val temperature: Int = R.drawable.ph_thermometer_simple_duotone
    @DrawableRes val entry: Int = R.drawable.ph_sliders_horizontal_duotone
    val size = 22.dp
}

@Composable
private fun ModelOptionParameterCardIcon(@DrawableRes iconRes: Int) {
    Icon(
        painterResource(iconRes),
        contentDescription = null,
        tint = OriveoTheme.colors.textSecondary,
        modifier = Modifier.padding(end = 12.dp).size(ModelOptionParameterCardIcons.size),
    )
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
