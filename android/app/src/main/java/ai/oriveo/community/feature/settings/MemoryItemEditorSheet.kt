package ai.oriveo.community.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.theme.OriveoTheme
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * Editor state: [itemId] null = new item; [originalKind] is the edited item's kind (null for new).
 * Episodic items pick [episodicKind] from [EPISODIC_KINDS] and carry a [date] instead of a group.
 */
data class MemoryItemEditorState(
    val itemId: String?,
    val group: MemoryItemGroup,
    val text: String,
    val originalKind: MemoryKind? = null,
    val layer: MemoryLayer = MemoryLayer.SEMANTIC,
    val episodicKind: MemoryKind = MemoryKind.DECISION,
    val date: LocalDate? = null,
) {
    val isNew: Boolean get() = itemId == null
    val isEpisodic: Boolean get() = layer == MemoryLayer.EPISODIC
    val counter: MemoryEditorCounter get() = MemoryEditorCounter.of(text)

    /** Kinds the editor offers: decision / event for episodic; one per group for semantic (never decision / event). */
    val kindOptions: List<MemoryKind> get() = if (isEpisodic) EPISODIC_KINDS else MemoryItemGroup.entries.map(::groupKind)

    /** occurredAt written on save for episodic items: the picked day at 00:00:00Z. */
    val occurredAt: String? get() = if (isEpisodic) date?.let { "${it}T00:00:00Z" } else null

    /** Kind written on save (contract rule 4): an unchanged category keeps the original kind; otherwise mapped by group. */
    val kind: MemoryKind get() = when {
        isEpisodic -> episodicKind
        originalKind != null && MemoryItemGroup.of(originalKind) == group -> originalKind
        else -> groupKind(group)
    }

    companion object {
        val EPISODIC_KINDS: List<MemoryKind> = listOf(MemoryKind.DECISION, MemoryKind.EVENT)

        private fun groupKind(group: MemoryItemGroup): MemoryKind = when (group) {
        MemoryItemGroup.About -> MemoryKind.IDENTITY
        MemoryItemGroup.Preferences -> MemoryKind.PREFERENCE
        MemoryItemGroup.Instructions -> MemoryKind.INSTRUCTION
            MemoryItemGroup.Projects -> MemoryKind.PROJECT
        }
    }
}

/** Editor counter in code points; over the limit shows the error and disables save. */
data class MemoryEditorCounter(val count: Int, val tooLong: Boolean, val canSave: Boolean) {
    companion object {
        const val LIMIT: Int = MemoryItems.CONTENT_MAX_CODE_POINTS

        fun of(text: String): MemoryEditorCounter {
            val count = text.codePointCount(0, text.length)
            val tooLong = count > LIMIT
            return MemoryEditorCounter(count = count, tooLong = tooLong, canSave = !tooLong && text.isNotBlank())
        }
    }
}

private fun categoryTag(group: MemoryItemGroup): String = when (group) {
    MemoryItemGroup.About -> "memory_editor_category_about_button"
    MemoryItemGroup.Preferences -> "memory_editor_category_preferences_button"
    MemoryItemGroup.Instructions -> "memory_editor_category_instructions_button"
    MemoryItemGroup.Projects -> "memory_editor_category_projects_button"
}

/** Bottom sheet: grabber, cancel / title / save bar, category tiles (L3: kind tiles + date block), ruled text area, counter. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MemoryItemEditorSheet(
    state: MemoryItemEditorState,
    onGroupChange: (MemoryItemGroup) -> Unit,
    onTextChange: (String) -> Unit,
    onEpisodicKindChange: (MemoryKind) -> Unit = {},
    onDateChange: (LocalDate) -> Unit = {},
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val counter = remember(state.text) { state.counter }
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        // Open fully: the text area and its counter ring must be visible without dragging.
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { OriveoSheetDragHandle() },
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        containerColor = memoryCardFill(),
        contentColor = colors.textPrimary,
        scrimColor = colors.overlay,
    ) {
        Column(modifier = Modifier.fillMaxWidth().padding(bottom = OriveoTheme.spacing.xxl)) {
            Row(
                modifier = Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDismiss, modifier = Modifier) {
                    Text(stringResource(R.string.cancel), style = memoryText(17f, 22f), color = colors.textSecondary)
                }
                Text(
                    text = stringResource(if (state.isNew) R.string.memory_editor_title_new else R.string.memory_editor_title_edit),
                    style = memoryText(17f, 22f, FontWeight.SemiBold),
                    color = colors.textPrimary,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = onSave,
                    enabled = counter.canSave,
                    modifier = Modifier,
                ) {
                    Text(
                        text = stringResource(R.string.save),
                        style = memoryText(17f, 22f, FontWeight.SemiBold),
                        color = if (counter.canSave) colors.primaryTextSafe else colors.textTertiary,
                    )
                }
            }
            Column(modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 8.dp)) {
                Text(
                    text = stringResource(R.string.memory_editor_category),
                    style = memoryText(12.5f, 16f, FontWeight.SemiBold).copy(letterSpacing = 0.04.em),
                    color = colors.textTertiary,
                    modifier = Modifier.padding(start = 2.dp, bottom = 10.dp),
                )
                if (state.isEpisodic) {
                    MemoryEpisodicEditorFields(state, onEpisodicKindChange, onDateChange)
                } else {
                    MemoryCategoryTiles(selected = state.group, onSelect = onGroupChange)
                }
                MemoryRuledTextField(
                    value = state.text,
                    onValueChange = onTextChange,
                    height = if (state.isEpisodic) 200.dp else 232.dp,
                    isError = counter.tooLong,
                    modifier = Modifier.padding(top = if (state.isEpisodic) 16.dp else 18.dp),
                )
                MemoryEditorCounterRow(counter)
            }
        }
    }
}

@Composable
private fun MemoryCategoryTiles(selected: MemoryItemGroup, onSelect: (MemoryItemGroup) -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().selectableGroup(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        MemoryItemGroup.entries.chunked(2).forEach { pair ->
            Row(modifier = Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                pair.forEach { group ->
                    MemoryCategoryTile(
                        glyph = group.glyph,
                        glyphSize = 18.dp,
                        hue = memoryGroupHue(group),
                        label = memoryItemGroupTitle(group),
                        selected = selected == group,
                        tag = categoryTag(group),
                        onClick = { onSelect(group) },
                        modifier = Modifier.weight(1f).fillMaxHeight(),
                    )
                }
            }
        }
    }
}

/** Category tile: hue glyph + name; selected = hue wash, 1.5dp hue ring and a check badge. */
@Composable
private fun MemoryCategoryTile(
    glyph: ImageVector,
    glyphSize: Dp,
    hue: Color,
    label: String,
    selected: Boolean,
    tag: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(14.dp)
    val fill = memoryCardFill()
    Row(
        modifier = modifier
            .heightIn(min = 52.dp)
            .clip(shape)
            .background(if (selected) memoryHueTint(hue).compositeOver(fill) else colors.surfaceInset)
            .border(if (selected) 1.5.dp else 1.dp, if (selected) hue else colors.border, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Icon(glyph, contentDescription = null, tint = hue, modifier = Modifier.size(glyphSize))
        Text(
            text = label,
            style = memoryText(15f, 20f, if (selected) FontWeight.SemiBold else FontWeight.Medium),
            color = colors.textPrimary,
            // Long names (e.g. "Standing instructions") wrap to a second line; the tile grows with them.
            maxLines = 2,
            modifier = Modifier.weight(1f),
        )
        if (selected) {
            Box(modifier = Modifier.size(18.dp).background(hue, CircleShape), contentAlignment = Alignment.Center) {
                Icon(MemoryGlyphs.Check, contentDescription = null, tint = fill, modifier = Modifier.size(11.dp))
            }
        }
    }
}

/**
 * Text area on 28sp ruled lines (ink 6%), inset fill. The text and its rules share one scroll container,
 * and rules sit under each laid-out line, so they move with the text.
 */
@Composable
private fun MemoryRuledTextField(
    value: String,
    onValueChange: (String) -> Unit,
    height: Dp,
    isError: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val rule = colors.textPrimary.copy(alpha = 0.06f)
    val shape = RoundedCornerShape(16.dp)
    val scroll = rememberScrollState()
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        textStyle = memoryText(17f, 28f).copy(
            color = colors.textPrimary,
            lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None),
        ),
        cursorBrush = SolidColor(colors.primary),
        onTextLayout = { layout = it },
        modifier = modifier.fillMaxWidth().height(height),
        decorationBox = { inner ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(shape)
                    .background(colors.surfaceInset)
                    .border(1.dp, if (isError) colors.error else colors.border, shape)
                    .verticalScroll(scroll),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = height)
                        .drawBehind {
                            val top = 12.dp.toPx()
                            val inset = 16.dp.toPx()
                            val stroke = 1.dp.toPx()
                            val result = layout
                            var lastBottom = top
                            var step = 28.sp.toPx()
                            if (result != null && result.lineCount > 0) {
                                for (line in 0 until result.lineCount) {
                                    val y = top + result.getLineBottom(line) - 0.5f
                                    drawLine(rule, Offset(inset, y), Offset(size.width - inset, y), stroke)
                                }
                                lastBottom = top + result.getLineBottom(result.lineCount - 1)
                                step = result.getLineBottom(0) - result.getLineTop(0)
                            }
                            // Empty ruled lines below the text fill the rest of the box.
                            var y = lastBottom + step - 0.5f
                            while (step > 0f && y < size.height - 4.dp.toPx()) {
                                drawLine(rule, Offset(inset, y), Offset(size.width - inset, y), stroke)
                                y += step
                            }
                        }
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    inner()
                }
            }
        },
    )
}

@Composable
private fun MemoryEditorCounterRow(counter: MemoryEditorCounter) {
    val colors = OriveoTheme.colors
    val track = memoryLineStrong()
    val progress = if (counter.tooLong) colors.error else colors.primary
    val fraction = (counter.count.toFloat() / MemoryEditorCounter.LIMIT).coerceIn(0f, 1f)
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = if (counter.tooLong) stringResource(R.string.memory_editor_too_long) else "",
            style = memoryText(13f, 18f),
            color = colors.error,
            modifier = Modifier.weight(1f),
        )
        Box(
            modifier = Modifier.size(16.dp).drawBehind {
                val stroke = 2.2.dp.toPx()
                val inset = stroke / 2f + 1.25.dp.toPx()
                val arcSize = Size(size.width - inset * 2, size.height - inset * 2)
                drawArc(track, 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(stroke))
                drawArc(progress, -90f, 360f * fraction, false, Offset(inset, inset), arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
            },
        )
        Text(
            text = "${counter.count} / ${MemoryEditorCounter.LIMIT}",
            style = memoryText(12f, 16f).copy(fontFamily = MemoryMonoFamily),
            color = if (counter.tooLong) colors.error else colors.textTertiary,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MemoryEpisodicEditorFields(
    state: MemoryItemEditorState,
    onKindChange: (MemoryKind) -> Unit,
    onDateChange: (LocalDate) -> Unit,
) {
    val colors = OriveoTheme.colors
    val hue = colors.memoryHueEpisodic
    var pickingDate by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Min).selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        state.kindOptions.forEach { kind ->
            val isEvent = kind == MemoryKind.EVENT
            MemoryCategoryTile(
                glyph = if (isEvent) MemoryGlyphs.Ring else MemoryGlyphs.Diamond,
                glyphSize = 16.dp,
                hue = hue,
                label = stringResource(if (isEvent) R.string.memory_kind_event else R.string.memory_kind_decision),
                selected = state.episodicKind == kind,
                tag = if (isEvent) "memory_editor_kind_event_button" else "memory_editor_kind_decision_button",
                onClick = { onKindChange(kind) },
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
        }
    }
    MemoryDateBlock(date = state.date, onClick = { pickingDate = true })
    if (pickingDate) {
        val pickerState = rememberDatePickerState(
            initialSelectedDateMillis = state.date?.atStartOfDay(ZoneOffset.UTC)?.toInstant()?.toEpochMilli(),
        )
        val pickerColors = DatePickerDefaults.colors(
            containerColor = memoryCardFill(),
            selectedDayContainerColor = colors.primaryTextSafe,
            selectedDayContentColor = colors.onPrimary,
            selectedYearContainerColor = colors.primaryTextSafe,
            selectedYearContentColor = colors.onPrimary,
            todayDateBorderColor = colors.primary,
            todayContentColor = colors.primaryTextSafe,
        )
        DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        // The picker reports the chosen day as UTC midnight.
                        pickerState.selectedDateMillis?.let { millis ->
                            onDateChange(Instant.ofEpochMilli(millis).atOffset(ZoneOffset.UTC).toLocalDate())
                        }
                        pickingDate = false
                    },
                    modifier = Modifier,
                ) {
                    Text(stringResource(R.string.ok), color = colors.primaryTextSafe)
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { pickingDate = false },
                    modifier = Modifier,
                ) {
                    Text(stringResource(R.string.cancel), color = colors.primaryTextSafe)
                }
            },
            colors = pickerColors,
        ) {
            DatePicker(state = pickerState, colors = pickerColors)
        }
    }
}

/** Calendar block button: hue-topped day tile, label + full date, chevron; opens the system date picker. */
@Composable
private fun MemoryDateBlock(date: LocalDate?, onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(14.dp)
    val tileShape = RoundedCornerShape(9.dp)
    Row(
        modifier = Modifier
            .padding(top = 16.dp)
            .fillMaxWidth()
            .height(64.dp)
            .clip(shape)
            .background(colors.surfaceInset)
            .border(1.dp, colors.border, shape)
            .clickable(onClick = onClick)
            .padding(start = 12.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier
                .size(width = 40.dp, height = 44.dp)
                .clip(tileShape)
                .background(memoryCardFill())
                .border(1.dp, colors.border, tileShape),
        ) {
            Box(modifier = Modifier.fillMaxWidth().height(12.dp).background(colors.memoryHueEpisodic))
            Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text(
                    text = date?.dayOfMonth?.toString().orEmpty(),
                    style = memoryDigits(18f).copy(fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.5).sp),
                    color = colors.textPrimary,
                )
            }
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = stringResource(R.string.memory_item_date),
                style = memoryText(12.5f, 16f, FontWeight.SemiBold),
                color = colors.textTertiary,
            )
            Text(
                text = date?.toString().orEmpty(),
                style = memoryDigits(16f),
                color = colors.textPrimary,
                modifier = Modifier.padding(top = 1.dp),
            )
        }
        Icon(MemoryGlyphs.Chevron, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
    }
}
