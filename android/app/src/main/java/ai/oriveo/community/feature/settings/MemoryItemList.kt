package ai.oriveo.community.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryConflictResolution
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryScopeType
import ai.oriveo.community.core.context.MemoryServerTime
import ai.oriveo.community.core.context.MemorySourceType
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.ui.theme.OriveoTheme
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeParseException

/** List groups in display order (P5·U6 contract rule 3). */
enum class MemoryItemGroup {
    About,
    Preferences,
    Instructions,
    Projects,
    ;

    companion object {
        /** null for kinds that never show in the list (event). */
        fun of(kind: MemoryKind): MemoryItemGroup? = when (kind) {
            MemoryKind.IDENTITY, MemoryKind.FACT -> About
            MemoryKind.PREFERENCE -> Preferences
            MemoryKind.INSTRUCTION, MemoryKind.CONSTRAINT -> Instructions
            MemoryKind.PROJECT, MemoryKind.GOAL, MemoryKind.DECISION -> Projects
            MemoryKind.EVENT -> null
        }
    }
}

data class MemoryItemRow(val item: MemoryItem) {
    val pinned: Boolean get() = item.pinned
    val paused: Boolean get() = item.status == MemoryStatus.PAUSED

    /** Inline [Split into items] only for multi-line migrated items (contract rule 6); the menu offers it for every row. */
    val showsInlineOrganize: Boolean get() = item.source.type == MemorySourceType.MIGRATION && item.content.contains('\n')
}

data class MemoryItemSection(val group: MemoryItemGroup, val rows: List<MemoryItemRow>)

data class MemoryConflictEntry(val item: MemoryItem, val isThisDevice: Boolean)

/** One conflict group: this device's version first. */
data class MemoryConflictPair(val groupId: String, val entries: List<MemoryConflictEntry>)

/** Scope shown on an episodic row's second line (P7·U3 card rule 2). */
sealed interface MemoryEpisodicScope {
    data object AllChats : MemoryEpisodicScope

    /** [name] null when the folder is not found locally. */
    data class Folder(val name: String?) : MemoryEpisodicScope

    data object OneChat : MemoryEpisodicScope
}

/** One episodic row: [date] is YYYY-MM-DD of occurredAt (createdAt when missing). */
data class MemoryEpisodicRow(val item: MemoryItem, val date: String, val scope: MemoryEpisodicScope) {
    val row: MemoryItemRow get() = MemoryItemRow(item)
}

/** The "Events & decisions" group: active / paused episodic items, newest first; folded past [FOLD_LIMIT]. */
data class MemoryEpisodicSection(val rows: List<MemoryEpisodicRow>) {
    val total: Int get() = rows.size
    val isFolded: Boolean get() = rows.size > FOLD_LIMIT

    fun visibleRows(expanded: Boolean): List<MemoryEpisodicRow> = if (expanded) rows else rows.take(FOLD_LIMIT)

    companion object {
        const val FOLD_LIMIT: Int = 20
    }
}

/** One side of an L3 conflict; [monthDay] is MM-DD of its time. */
data class MemoryL3ConflictEntry(val item: MemoryItem, val monthDay: String)

/** An L3 conflict pair (two conflicted episodic items sharing conflictGroupId); newer = later time, tie → larger id. */
data class MemoryL3ConflictPair(val groupId: String, val newer: MemoryL3ConflictEntry, val older: MemoryL3ConflictEntry)

data class MemoryItemListPresentation(
    val conflicts: List<MemoryConflictPair>,
    val sections: List<MemoryItemSection>,
    val l3Conflicts: List<MemoryL3ConflictPair> = emptyList(),
    val episodic: MemoryEpisodicSection = MemoryEpisodicSection(emptyList()),
) {
    val isEmpty: Boolean get() = conflicts.isEmpty() && sections.isEmpty() && l3Conflicts.isEmpty() && episodic.rows.isEmpty()
}

/**
 * Pure list layout: deleted / superseded / expired and episodic (event) items are hidden; conflicted items go to
 * the conflict block paired by conflictGroupId; the rest go to the four groups in listOrder (pinned first), empty
 * groups dropped.
 *
 * Conflict labels look only at the copy (id != conflictGroupId): the original's deviceId is whoever pushed it, so it
 * cannot tell the devices apart. A copy from this device means the original is the other device's, and vice versa.
 */
fun buildMemoryItemListPresentation(
    items: List<MemoryItem>,
    deviceId: String?,
    folderNames: Map<String, String> = emptyMap(),
): MemoryItemListPresentation {
    val visible = MemoryItems.listOrder(items).filter {
        it.status !in HIDDEN_STATUSES && it.layer != MemoryLayer.EPISODIC && MemoryItemGroup.of(it.kind) != null
    }
    val conflicts = visible
        .filter { it.status == MemoryStatus.CONFLICTED }
        .groupBy { it.conflictGroupId ?: it.id }
        .map { (groupId, members) ->
            val copyIsThisDevice = members.firstOrNull { it.id != groupId }?.let { deviceId != null && it.deviceId == deviceId } ?: false
            val entries = members.map { member ->
                MemoryConflictEntry(member, isThisDevice = if (member.id == groupId) !copyIsThisDevice else copyIsThisDevice)
            }
            MemoryConflictPair(groupId, entries.sortedByDescending { it.isThisDevice })
        }
    val byGroup = visible.filter { it.status != MemoryStatus.CONFLICTED }.groupBy { MemoryItemGroup.of(it.kind)!! }
    val sections = MemoryItemGroup.entries.mapNotNull { group ->
        byGroup[group]?.takeIf { it.isNotEmpty() }?.let { rows -> MemoryItemSection(group, rows.map(::MemoryItemRow)) }
    }
    return MemoryItemListPresentation(
        conflicts = conflicts,
        sections = sections,
        l3Conflicts = buildL3Conflicts(items),
        episodic = buildEpisodicSection(items, folderNames),
    )
}

private val HIDDEN_STATUSES = setOf(MemoryStatus.DELETED, MemoryStatus.SUPERSEDED, MemoryStatus.EXPIRED)
private val EPISODIC_LISTED_STATUSES = setOf(MemoryStatus.ACTIVE, MemoryStatus.PAUSED)

/** occurredAt, else createdAt; null when neither parses. */
private fun episodicTime(item: MemoryItem): Instant? =
    listOfNotNull(item.occurredAt, (item.createdAt as? MemoryServerTime.At)?.rfc3339).firstNotNullOfOrNull { text ->
        try {
            OffsetDateTime.parse(text).toInstant()
        } catch (_: DateTimeParseException) {
            null
        }
    }

/** Newest first; items without a time go last; ties by larger id first. */
private val episodicNewestFirst: Comparator<MemoryItem> =
    compareByDescending<MemoryItem, Instant?>(nullsFirst()) { episodicTime(it) }.thenByDescending { it.id.lowercase() }

private fun episodicDate(item: MemoryItem): String =
    episodicTime(item)?.atOffset(ZoneOffset.UTC)?.toLocalDate()?.toString()
        ?: (item.occurredAt ?: (item.createdAt as? MemoryServerTime.At)?.rfc3339).orEmpty().take(10)

private fun buildEpisodicSection(items: List<MemoryItem>, folderNames: Map<String, String>): MemoryEpisodicSection {
    val rows = items
        .filter { it.layer == MemoryLayer.EPISODIC && it.status in EPISODIC_LISTED_STATUSES }
        .sortedWith(episodicNewestFirst)
        .map { item ->
            val scope = when (item.scope.type) {
                MemoryScopeType.GLOBAL -> MemoryEpisodicScope.AllChats
                MemoryScopeType.FOLDER -> MemoryEpisodicScope.Folder(item.scope.id?.let { folderNames[it] })
                MemoryScopeType.CONVERSATION -> MemoryEpisodicScope.OneChat
            }
            MemoryEpisodicRow(item, episodicDate(item), scope)
        }
    return MemoryEpisodicSection(rows)
}

private fun buildL3Conflicts(items: List<MemoryItem>): List<MemoryL3ConflictPair> = items
    .filter { it.layer == MemoryLayer.EPISODIC && it.status == MemoryStatus.CONFLICTED && it.conflictGroupId != null }
    .groupBy { it.conflictGroupId!!.lowercase() }
    .mapNotNull { (groupId, members) ->
        if (members.size != 2) return@mapNotNull null
        val (newer, older) = members.sortedWith(episodicNewestFirst)
        fun entry(item: MemoryItem) = MemoryL3ConflictEntry(item, episodicDate(item).drop(5))
        MemoryL3ConflictPair(groupId, entry(newer), entry(older))
    }
    .sortedWith(compareByDescending<MemoryL3ConflictPair, Instant?>(nullsFirst()) { episodicTime(it.newer.item) })

@Composable
internal fun memoryItemGroupTitle(group: MemoryItemGroup): String = stringResource(
    when (group) {
        MemoryItemGroup.About -> R.string.memory_group_about
        MemoryItemGroup.Preferences -> R.string.memory_group_preferences
        MemoryItemGroup.Instructions -> R.string.memory_group_instructions
        MemoryItemGroup.Projects -> R.string.memory_group_projects
    },
)

/** Item operations the list exposes; organize / raw view entries are hidden while null. */
data class MemoryItemListActions(
    val onAdd: (MemoryItemGroup) -> Unit,
    val onEdit: (MemoryItem) -> Unit,
    val onTogglePin: (MemoryItem) -> Unit,
    val onTogglePause: (MemoryItem) -> Unit,
    val onDelete: (MemoryItem) -> Unit,
    val onKeepConflict: (MemoryItem) -> Unit,
    /** Opens the editor for a new episodic item (kind decision). */
    val onAddEpisodic: () -> Unit = {},
    val onResolveL3Conflict: (MemoryL3ConflictPair, MemoryConflictResolution) -> Unit = { _, _ -> },
    val onOrganize: ((MemoryItem) -> Unit)? = null,
    val onRawView: (() -> Unit)? = null,
)

// ── Memory atlas kit (P11): glyphs, hues, cards shared by the memory pages ──

private fun circlePath(cx: Float, cy: Float, r: Float): String =
    "M${cx - r} ${cy}a$r $r 0 1 0 ${2 * r} 0a$r $r 0 1 0 ${-2 * r} 0"

private fun glyph(
    name: String,
    stroked: List<String> = emptyList(),
    filled: List<String> = emptyList(),
    strokeWidth: Float = 2f,
    autoMirror: Boolean = false,
): ImageVector = ImageVector.Builder(
    name = name,
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
    autoMirror = autoMirror,
).apply {
    filled.forEach { addPath(pathData = addPathNodes(it), fill = SolidColor(Color.Black)) }
    stroked.forEach {
        addPath(
            pathData = addPathNodes(it),
            stroke = SolidColor(Color.Black),
            strokeLineWidth = strokeWidth,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }
}.build()

/** Line glyphs from the memory atlas boards (24 viewport, drawn with the tint; never on a plate). */
internal object MemoryGlyphs {
    val About = glyph("about", stroked = listOf(circlePath(12f, 8.5f, 3.5f), "M5 20c1.4-3.6 4-5.5 7-5.5s5.6 1.9 7 5.5"))
    val Preferences = glyph(
        "preferences",
        stroked = listOf("M4 8h16M4 16h16", circlePath(9f, 8f, 2.4f), circlePath(15f, 16f, 2.4f)),
        filled = listOf(circlePath(9f, 8f, 2.4f), circlePath(15f, 16f, 2.4f)),
    )
    val Instructions = glyph("instructions", stroked = listOf("M17 4l3 3-3 3", "M20 7H9a5 5 0 000 10h2", "M14 17h6"))
    val WorkingOn = glyph("working_on", stroked = listOf("M12 3l9 4.5-9 4.5-9-4.5z", "M3 12l9 4.5 9-4.5M3 16.5L12 21l9-4.5"))
    val Episodic = glyph("episodic", stroked = listOf("M12 2v4M12 18v4", "M12 7l5 5-5 5-5-5z"))
    val Fork = glyph(
        "fork",
        stroked = listOf(circlePath(6f, 5f, 2f), circlePath(6f, 19f, 2f), circlePath(18f, 12f, 2f), "M6 7v10M6 12h4a4 4 0 004-4V7M14 12h2"),
    )
    val Inbox = glyph("inbox", stroked = listOf("M4 13l2.5-7h11L20 13v5a1 1 0 01-1 1H5a1 1 0 01-1-1v-5z", "M4 13h4.5l1 2h5l1-2H20"), strokeWidth = 1.8f)
    val Sparkle = glyph(
        "sparkle",
        filled = listOf(
            "M12 2l2.2 6.3L20.5 10.5l-6.3 2.2L12 19l-2.2-6.3L3.5 10.5l6.3-2.2z",
            "M19 15l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z",
        ),
    )
    val Shield = glyph("shield", stroked = listOf("M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6z"), strokeWidth = 1.8f)
    val Device = glyph(
        "device",
        stroked = listOf("M9.5 3h5A2.5 2.5 0 0117 5.5v13a2.5 2.5 0 01-2.5 2.5h-5A2.5 2.5 0 017 18.5v-13A2.5 2.5 0 019.5 3z", "M11 18h2"),
        strokeWidth = 1.8f,
    )
    val Folder = glyph("folder", stroked = listOf("M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"))
    val Globe = glyph(
        "globe",
        stroked = listOf(circlePath(12f, 12f, 8.5f), "M3.5 12h17M12 3.5c2.5 2.6 2.5 14.4 0 17M12 3.5c-2.5 2.6-2.5 14.4 0 17"),
    )
    val Bubble = glyph("bubble", stroked = listOf("M4 5h16v11H9l-5 4z"))
    val Chevron = glyph("chevron", stroked = listOf("M9 5l7 7-7 7"), strokeWidth = 2.2f, autoMirror = true)
    val Plus = glyph("plus", stroked = listOf("M12 5v14M5 12h14"))
    val Check = glyph("check", stroked = listOf("M5 12l5 5 9-10"), strokeWidth = 3.4f)
    val Pin = glyph("pin", filled = listOf("M9 3h6l-1 6 3.5 3.5V15h-11v-2.5L10 9 9 3zM11.2 15h1.6v6l-.8 1-.8-1z"))
    val KeepBoth = glyph("keep_both", stroked = listOf("M7 6v12M17 6v12"))
    val ErrorCircle = glyph("error_circle", stroked = listOf(circlePath(12f, 12f, 9f), "M12 7.5v5.5M12 16.5v.5"))
    val Diamond = glyph("diamond", filled = listOf("M12 3l9 9-9 9-9-9z"))
    val Ring = glyph("ring", stroked = listOf(circlePath(12f, 12f, 7.5f)), strokeWidth = 2.6f)
    val More = glyph("more", filled = listOf(circlePath(5f, 12f, 1.7f), circlePath(12f, 12f, 1.7f), circlePath(19f, 12f, 1.7f)))
}

internal val MemoryItemGroup.glyph: ImageVector
    get() = when (this) {
        MemoryItemGroup.About -> MemoryGlyphs.About
        MemoryItemGroup.Preferences -> MemoryGlyphs.Preferences
        MemoryItemGroup.Instructions -> MemoryGlyphs.Instructions
        MemoryItemGroup.Projects -> MemoryGlyphs.WorkingOn
    }

/** Group hue: graphics only (glyphs, swatches, rails); text always uses the text colors. */
@Composable
internal fun memoryGroupHue(group: MemoryItemGroup): Color {
    val colors = OriveoTheme.colors
    return when (group) {
        MemoryItemGroup.About -> colors.memoryHueAbout
        MemoryItemGroup.Preferences -> colors.memoryHuePreferences
        MemoryItemGroup.Instructions -> colors.memoryHueInstructions
        MemoryItemGroup.Projects -> colors.memoryHueWorkingOn
    }
}

/** Hue wash for pinned rows / selected tiles: 7% light, 10% dark. */
@Composable
internal fun memoryHueTint(hue: Color): Color = hue.copy(alpha = if (OriveoTheme.isDark) 0.10f else 0.07f)

/** Stronger hairline (board `--ln2`): ink 14% light, white 16% dark. */
@Composable
internal fun memoryLineStrong(): Color =
    if (OriveoTheme.isDark) Color.White.copy(alpha = 0.16f) else Color.Black.copy(alpha = 0.14f)

/** Opaque card surface of the memory pages. */
@Composable
internal fun memoryCardFill(): Color = OriveoTheme.colors.surface.copy(alpha = 1f)

/** Base for the memory pages' system-font text (titles, rows): no brand family. */
@Composable
internal fun memoryText(size: Float, lineHeight: Float? = null, weight: FontWeight = FontWeight.Normal): TextStyle =
    OriveoTheme.typography.footnote.copy(
        fontSize = size.sp,
        lineHeight = (lineHeight ?: (size * 1.35f)).sp,
        fontWeight = weight,
    )

@Composable
internal fun memoryDigits(size: Float): TextStyle = OriveoTheme.typography.brandDigits.copy(fontSize = size.sp)

internal val MemoryMonoFamily: FontFamily = FontFamily.Monospace

/**
 * Card of the memory pages: opaque surface, light soft shadow / dark 1px top highlight,
 * optional hairline ring ([outlined]) or a 1dp [outline] (the amber conflict card).
 */
@Composable
internal fun Modifier.memoryCard(radius: Dp = 20.dp, outlined: Boolean = false, outline: Color? = null): Modifier {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(radius)
    val ring = outline ?: colors.border.takeIf { outlined }
    val shadowed = if (isDark) this else this.shadow(3.dp, shape, ambientColor = colors.shadowStrong, spotColor = colors.shadowStrong)
    return shadowed
        .clip(shape)
        .background(memoryCardFill())
        .then(if (ring != null) Modifier.border(1.dp, ring, shape) else Modifier)
        .then(
            if (isDark) {
                Modifier.drawBehind {
                    drawLine(Color.White.copy(alpha = 0.04f), Offset(radius.toPx(), 0.5f), Offset(size.width - radius.toPx(), 0.5f), 1.dp.toPx())
                }
            } else {
                Modifier
            },
        )
}

/** Hairline at the top of a row, inset from the start by [inset]. */
internal fun DrawScope.memoryTopDivider(color: Color, inset: Dp) {
    val start = inset.toPx()
    val (x0, x1) = if (layoutDirection == androidx.compose.ui.unit.LayoutDirection.Rtl) 0f to size.width - start else start to size.width
    drawLine(color, Offset(x0, 0.5f), Offset(x1, 0.5f), 1.dp.toPx())
}

@Composable
internal fun MemoryIconButton(
    icon: ImageVector,
    contentDescription: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = OriveoTheme.colors.textTertiary,
) {
    IconButton(onClick = onClick, modifier = modifier.size(40.dp)) {
        Icon(imageVector = icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(18.dp))
    }
}

/** Footnote on the page background: icon + text in textDisabledOnControl. */
@Composable
internal fun MemoryFootnote(icon: ImageVector, text: String, modifier: Modifier = Modifier, size: Float = 13f) {
    val color = OriveoTheme.colors.textDisabledOnControl
    Row(modifier = modifier.fillMaxWidth().padding(horizontal = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.padding(top = 2.dp).size(14.dp))
        Text(text = text, style = memoryText(size, 18f), color = color, modifier = Modifier.weight(1f))
    }
}

/** Group header: hue glyph, name, count, optional trailing add button. */
@Composable
private fun MemoryGroupHeader(
    glyph: ImageVector,
    hue: Color,
    title: String,
    count: Int,
    topSpacing: Dp,
    onAdd: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = topSpacing, bottom = 10.dp)
            .padding(start = 4.dp)
            .heightIn(min = 36.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(glyph, contentDescription = null, tint = hue, modifier = Modifier.size(18.dp))
        Text(text = title, style = memoryText(15f, 20f, FontWeight.SemiBold), color = colors.textPrimary)
        Text(text = count.toString(), style = memoryDigits(13f), color = colors.textTertiary)
        Spacer(modifier = Modifier.weight(1f))
        if (onAdd != null) {
            MemoryIconButton(MemoryGlyphs.Plus, stringResource(R.string.memory_add_item), onAdd)
        }
    }
}

// ── Spectrum ──

/** Page-top spectrum: one segment per non-empty group sized by its count, a two-column legend, then the episodic total. */
@Composable
internal fun MemorySpectrum(presentation: MemoryItemListPresentation, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val segments = presentation.sections.map { it.group to it.rows.size }
    val dash = memoryLineStrong()
    Column(modifier = modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
        if (segments.isNotEmpty()) {
            Row(modifier = Modifier.fillMaxWidth().height(10.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                segments.forEachIndexed { index, (group, count) ->
                    val start = if (index == 0) 6.dp else 3.dp
                    val end = if (index == segments.lastIndex) 6.dp else 3.dp
                    Box(
                        modifier = Modifier
                            .weight(count.toFloat())
                            .fillMaxHeight()
                            .background(memoryGroupHue(group), RoundedCornerShape(start, end, end, start)),
                    )
                }
            }
            Column(modifier = Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                segments.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        pair.forEach { (group, count) ->
                            SpectrumLegendItem(memoryGroupHue(group), memoryItemGroupTitle(group), count, Modifier.weight(1f))
                        }
                        if (pair.size == 1) Spacer(modifier = Modifier.weight(1f))
                    }
                }
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = if (segments.isEmpty()) 0.dp else 12.dp)
                .drawBehind {
                    if (segments.isNotEmpty()) {
                        drawLine(
                            dash,
                            Offset(0f, 0.5f),
                            Offset(size.width, 0.5f),
                            1.dp.toPx(),
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())),
                        )
                    }
                }
                .padding(top = if (segments.isEmpty()) 0.dp else 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(MemoryGlyphs.Diamond, contentDescription = null, tint = colors.memoryHueEpisodic, modifier = Modifier.size(12.dp))
            Text(
                text = stringResource(R.string.memory_group_episodic),
                style = memoryText(13f, 18f),
                color = colors.textSecondary,
                modifier = Modifier.weight(1f),
            )
            Text(text = presentation.episodic.total.toString(), style = memoryDigits(13f), color = colors.textPrimary)
        }
    }
}

@Composable
private fun SpectrumLegendItem(hue: Color, name: String, count: Int, modifier: Modifier) {
    val colors = OriveoTheme.colors
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(modifier = Modifier.size(8.dp).background(hue, RoundedCornerShape(2.5.dp)))
        Text(
            text = name,
            style = memoryText(13f, 18f),
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text(text = count.toString(), style = memoryDigits(13f), color = colors.textPrimary)
    }
}

// ── List content ──

/** Conflicts, the four groups and the episodic timeline, stacked on the page background. */
@Composable
internal fun MemoryItemListContent(
    presentation: MemoryItemListPresentation,
    actions: MemoryItemListActions,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        if (presentation.conflicts.isNotEmpty() || presentation.l3Conflicts.isNotEmpty()) {
            MemoryConflictBlock(presentation.conflicts, presentation.l3Conflicts, actions)
        }
        presentation.sections.forEach { section ->
            MemoryItemSectionView(section, actions)
        }
        MemoryEpisodicSectionView(presentation.episodic, actions)
    }
}

@Composable
private fun MemoryConflictBlock(
    conflicts: List<MemoryConflictPair>,
    l3Conflicts: List<MemoryL3ConflictPair>,
    actions: MemoryItemListActions,
) {
    val colors = OriveoTheme.colors
    MemoryGroupHeader(
        glyph = MemoryGlyphs.Fork,
        hue = colors.warning,
        title = stringResource(R.string.memory_group_conflicts),
        count = conflicts.size + l3Conflicts.size,
        topSpacing = 22.dp,
    )
    conflicts.forEach { pair ->
        Column(modifier = Modifier.padding(bottom = 12.dp).fillMaxWidth().memoryCard(outline = colors.warningLine)) {
            pair.entries.forEachIndexed { index, entry ->
                MemoryConflictRow(
                    eyebrow = AnnotatedString(
                        stringResource(
                            if (entry.isThisDevice) R.string.memory_conflict_this_device else R.string.memory_conflict_other_device,
                        ),
                    ),
                    content = entry.item.content,
                    filled = entry.isThisDevice,
                    diamond = false,
                    linkUp = index > 0,
                    linkDown = index < pair.entries.lastIndex,
                    keepTag = "memory_conflict_keep_button",
                    onKeep = { actions.onKeepConflict(entry.item) },
                )
            }
        }
    }
    l3Conflicts.forEach { pair -> MemoryL3ConflictPairView(pair, actions.onResolveL3Conflict) }
}

@Composable
private fun MemoryL3ConflictPairView(
    pair: MemoryL3ConflictPair,
    onResolve: (MemoryL3ConflictPair, MemoryConflictResolution) -> Unit,
) {
    val colors = OriveoTheme.colors
    val digits = memoryDigits(11.5f).copy(color = colors.textSecondary).toSpanStyle()
    Column(modifier = Modifier.padding(bottom = 12.dp).fillMaxWidth().memoryCard(outline = colors.warningLine)) {
        listOf(
            Triple(pair.newer, R.string.memory_conflict_newer, MemoryConflictResolution.USE_NEW),
            Triple(pair.older, R.string.memory_conflict_older, MemoryConflictResolution.USE_OLD),
        ).forEachIndexed { index, (entry, labelRes, resolution) ->
            val label = stringResource(labelRes)
            MemoryConflictRow(
                eyebrow = buildAnnotatedString {
                    append("$label · ")
                    // Full date, same formatting as the timeline's date column.
                    withStyle(digits) { append(episodicDate(entry.item)) }
                },
                content = entry.item.content,
                filled = index == 0,
                diamond = true,
                linkUp = index > 0,
                linkDown = index == 0,
                keepTag = "memory_l3_conflict_keep_button",
                onKeep = { onResolve(pair, resolution) },
            )
        }
        val line = colors.warningLine
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp)
                .background(colors.warning.copy(alpha = 0.06f))
                .drawBehind { drawLine(line, Offset(0f, 0.5f), Offset(size.width, 0.5f), 1.dp.toPx()) }
                .clickable { onResolve(pair, MemoryConflictResolution.KEEP_BOTH) },
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(MemoryGlyphs.KeepBoth, contentDescription = null, tint = colors.textPrimary, modifier = Modifier.size(16.dp))
            Text(
                text = stringResource(R.string.memory_conflict_keep_both),
                style = memoryText(15f, 20f, FontWeight.SemiBold),
                color = colors.textPrimary,
            )
        }
    }
}

/** One version in a conflict card: fork slot (filled = this device / newer), eyebrow, text, keep pill. */
@Composable
private fun MemoryConflictRow(
    eyebrow: AnnotatedString,
    content: String,
    filled: Boolean,
    diamond: Boolean,
    linkUp: Boolean,
    linkDown: Boolean,
    keepTag: String,
    onKeep: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val divider = colors.border
    val amber = colors.warning
    val amberLine = colors.warningLine
    val fill = memoryCardFill()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .drawBehind { if (linkUp) memoryTopDivider(divider, 16.dp) }
            .padding(end = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .width(36.dp)
                .fillMaxHeight()
                .drawBehind {
                    val cx = 18.dp.toPx()
                    val top = 20.dp.toPx()
                    val node = 10.dp.toPx()
                    val lineWidth = 1.dp.toPx()
                    if (linkUp) drawLine(amberLine, Offset(cx, 0f), Offset(cx, top), lineWidth)
                    if (linkDown) drawLine(amberLine, Offset(cx, top + node), Offset(cx, size.height), lineWidth)
                    drawForkNode(Offset(cx, top + node / 2f), filled, diamond, amber, fill)
                },
        )
        Column(modifier = Modifier.weight(1f).padding(vertical = 14.dp)) {
            Text(
                text = eyebrow,
                style = memoryText(11.5f, 15f, FontWeight.SemiBold).copy(letterSpacing = 0.04.em),
                color = colors.textTertiary,
                modifier = Modifier.padding(bottom = 4.dp),
            )
            Text(
                text = content,
                style = memoryText(16f, 23f),
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box(
            modifier = Modifier
                .height(32.dp)
                .clip(CircleShape)
                .background(colors.primarySoft)
                .clickable(onClick = onKeep)
                .padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = stringResource(R.string.memory_conflict_keep),
                style = memoryText(13.5f, 18f, FontWeight.SemiBold),
                color = colors.primaryTextSafe,
                maxLines = 1,
            )
        }
    }
}

private fun DrawScope.drawForkNode(center: Offset, filled: Boolean, diamond: Boolean, amber: Color, fill: Color) {
    val ring = 2.dp.toPx()
    if (diamond) {
        val side = 9.dp.toPx()
        val corner = CornerRadius(2.dp.toPx())
        val topLeft = Offset(center.x - side / 2f, center.y - side / 2f)
        rotate(45f, pivot = center) {
            drawRoundRect(if (filled) amber else fill, topLeft, Size(side, side), corner)
            if (!filled) {
                drawRoundRect(
                    amber,
                    Offset(topLeft.x + ring / 2f, topLeft.y + ring / 2f),
                    Size(side - ring, side - ring),
                    corner,
                    style = Stroke(ring),
                )
            }
        }
    } else {
        val radius = 5.dp.toPx()
        if (filled) {
            drawCircle(amber, radius, center)
        } else {
            drawCircle(fill, radius, center)
            drawCircle(amber, radius - ring / 2f, center, style = Stroke(ring))
        }
    }
}

@Composable
private fun MemoryItemSectionView(section: MemoryItemSection, actions: MemoryItemListActions) {
    val hue = memoryGroupHue(section.group)
    MemoryGroupHeader(
        glyph = section.group.glyph,
        hue = hue,
        title = memoryItemGroupTitle(section.group),
        count = section.rows.size,
        topSpacing = 18.dp,
        onAdd = { actions.onAdd(section.group) },
    )
    Column(modifier = Modifier.fillMaxWidth().memoryCard()) {
        section.rows.forEachIndexed { index, row -> MemoryItemRowView(row, actions, hue, showsDivider = index > 0) }
    }
}

@Composable
private fun MemoryItemRowView(
    row: MemoryItemRow,
    actions: MemoryItemListActions,
    hue: Color,
    showsDivider: Boolean,
) {
    val colors = OriveoTheme.colors
    val divider = colors.border
    val pinnedA11y = stringResource(R.string.memory_item_pinned_a11y)
    val text = buildAnnotatedString {
        if (row.pinned) appendInlineContent(PIN_INLINE_ID, pinnedA11y)
        append(row.item.content)
    }
    val inline = if (row.pinned) {
        mapOf(
            PIN_INLINE_ID to InlineTextContent(Placeholder(19.sp, 13.sp, PlaceholderVerticalAlign.TextCenter)) {
                Icon(MemoryGlyphs.Pin, contentDescription = null, tint = hue, modifier = Modifier.padding(end = 6.dp).size(13.dp))
            },
        )
    } else {
        emptyMap()
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (row.pinned) Modifier.background(memoryHueTint(hue)) else Modifier)
            .drawBehind { if (showsDivider) memoryTopDivider(divider, 16.dp) }
            .heightIn(min = 56.dp)
            .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(modifier = Modifier.weight(1f).padding(vertical = 5.dp)) {
            Text(
                text = text,
                inlineContent = inline,
                style = memoryText(16f, 23f),
                color = if (row.paused) colors.textTertiary else colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            val onOrganize = actions.onOrganize
            if (onOrganize != null && row.showsInlineOrganize) {
                MemoryOrganizePill(onClick = { onOrganize(row.item) })
            }
        }
        if (row.paused) MemoryPausedBadge()
        MemoryRowMenuButton(row, actions)
    }
}

private const val PIN_INLINE_ID = "pin"

@Composable
private fun MemoryOrganizePill(onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .padding(top = 10.dp)
            .clip(CircleShape)
            .border(1.dp, colors.primary.copy(alpha = 0.4f), CircleShape)
            .clickable(onClick = onClick)
            .padding(start = 10.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(MemoryGlyphs.Sparkle, contentDescription = null, tint = colors.primaryTextSafe, modifier = Modifier.size(13.dp))
        Text(
            text = stringResource(R.string.memory_action_organize),
            style = memoryText(13f, 18f, FontWeight.SemiBold),
            color = colors.primaryTextSafe,
        )
    }
}

@Composable
private fun MemoryPausedBadge() {
    val colors = OriveoTheme.colors
    Text(
        text = stringResource(R.string.memory_item_paused_badge),
        style = memoryText(11.5f, 15f, FontWeight.SemiBold),
        color = colors.textTertiary,
        maxLines = 1,
        modifier = Modifier
            .background(colors.surfaceElevated, RoundedCornerShape(6.dp))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

/** Trailing horizontal ⋯ (always visible) opening the system menu. */
@Composable
private fun MemoryRowMenuButton(row: MemoryItemRow, actions: MemoryItemListActions) {
    val colors = OriveoTheme.colors
    var menuOpen by remember { mutableStateOf(false) }
    val onOrganize = actions.onOrganize
    Box {
        MemoryIconButton(
            icon = MemoryGlyphs.More,
            contentDescription = stringResource(R.string.provider_list_more_actions),
            onClick = { menuOpen = true },
        )
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            fun pick(action: (MemoryItem) -> Unit): () -> Unit = {
                menuOpen = false
                action(row.item)
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.memory_action_edit)) },
                onClick = pick(actions.onEdit),
                modifier = Modifier,
            )
            DropdownMenuItem(
                text = { Text(stringResource(if (row.pinned) R.string.memory_action_unpin else R.string.memory_action_pin)) },
                onClick = pick(actions.onTogglePin),
                modifier = Modifier,
            )
            DropdownMenuItem(
                text = { Text(stringResource(if (row.paused) R.string.memory_action_resume else R.string.memory_action_pause)) },
                onClick = pick(actions.onTogglePause),
                modifier = Modifier,
            )
            if (onOrganize != null) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.memory_action_organize)) },
                    onClick = pick(onOrganize),
                    modifier = Modifier,
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.memory_action_delete), color = colors.error) },
                onClick = pick(actions.onDelete),
                modifier = Modifier,
            )
        }
    }
}

// ── Episodic timeline ──

@Composable
private fun memoryEpisodicScopeLabel(scope: MemoryEpisodicScope): String = when (scope) {
    MemoryEpisodicScope.AllChats -> stringResource(R.string.memory_scope_all)
    is MemoryEpisodicScope.Folder ->
        scope.name?.let { stringResource(R.string.memory_scope_folder_named, it) } ?: stringResource(R.string.memory_scope_folder)
    MemoryEpisodicScope.OneChat -> stringResource(R.string.memory_scope_conversation)
}

private fun MemoryEpisodicScope.glyph(): ImageVector = when (this) {
    MemoryEpisodicScope.AllChats -> MemoryGlyphs.Globe
    is MemoryEpisodicScope.Folder -> MemoryGlyphs.Folder
    MemoryEpisodicScope.OneChat -> MemoryGlyphs.Bubble
}

/** "MM·DD" and "YYYY" of a YYYY-MM-DD date; anything else is shown as is. */
private fun episodicDateParts(date: String): Pair<String, String> =
    if (date.length >= 10 && date[4] == '-' && date[7] == '-') {
        "${date.substring(5, 7)}·${date.substring(8, 10)}" to date.take(4)
    } else {
        date to ""
    }

private const val TIMELINE_TEXT_INSET = 86

/** Always shown: it is the only manual entry point for new episodic items. */
@Composable
private fun MemoryEpisodicSectionView(section: MemoryEpisodicSection, actions: MemoryItemListActions) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    // Organize does not apply to episodic items.
    val rowActions = actions.copy(onOrganize = null)
    val divider = colors.border
    MemoryGroupHeader(
        glyph = MemoryGlyphs.Episodic,
        hue = colors.memoryHueEpisodic,
        title = stringResource(R.string.memory_group_episodic),
        count = section.total,
        topSpacing = 18.dp,
        onAdd = actions.onAddEpisodic,
    )
    val rows = section.visibleRows(expanded)
    if (rows.isNotEmpty()) {
        Column(modifier = Modifier.fillMaxWidth().memoryCard()) {
            rows.forEachIndexed { index, row -> MemoryTimelineRow(row, rowActions, isFirst = index == 0) }
            if (section.isFolded && !expanded) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp)
                        .drawBehind { memoryTopDivider(divider, TIMELINE_TEXT_INSET.dp) }
                        .clickable { expanded = true }
                        .padding(start = TIMELINE_TEXT_INSET.dp, end = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = stringResource(R.string.memory_show_all, section.total),
                        style = memoryText(15f, 20f, FontWeight.SemiBold),
                        color = colors.primaryTextSafe,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(MemoryGlyphs.Chevron, contentDescription = null, tint = colors.primaryTextSafe, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
    MemoryFootnote(
        icon = MemoryGlyphs.Device,
        text = stringResource(R.string.memory_episodic_local_only),
        modifier = Modifier.padding(top = 10.dp),
    )
}

@Composable
private fun MemoryTimelineRow(row: MemoryEpisodicRow, actions: MemoryItemListActions, isFirst: Boolean) {
    val colors = OriveoTheme.colors
    val divider = colors.border
    val rail = memoryLineStrong()
    val hue = colors.memoryHueEpisodic
    val fill = memoryCardFill()
    val paused = row.row.paused
    val isEvent = row.item.kind == MemoryKind.EVENT
    val (monthDay, year) = episodicDateParts(row.date)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .heightIn(min = 60.dp)
            .drawBehind { if (!isFirst) memoryTopDivider(divider, TIMELINE_TEXT_INSET.dp) }
            .padding(end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.width(58.dp).align(Alignment.Top).padding(top = 14.dp, end = 10.dp),
            horizontalAlignment = Alignment.End,
        ) {
            Text(text = monthDay, style = memoryDigits(14f).copy(lineHeight = 18.sp, letterSpacing = (-0.2).sp), color = colors.textPrimary, maxLines = 1)
            if (year.isNotEmpty()) {
                Text(
                    text = year,
                    style = memoryText(10f, 14f).copy(fontFamily = MemoryMonoFamily, letterSpacing = 0.02.em),
                    color = colors.textTertiary,
                )
            }
        }
        Box(
            modifier = Modifier
                .width(16.dp)
                .fillMaxHeight()
                .drawBehind {
                    val cx = 8.dp.toPx()
                    val markerCenter = 22.5.dp.toPx()
                    drawLine(rail, Offset(cx, if (isFirst) markerCenter else 0f), Offset(cx, size.height), 1.dp.toPx())
                    val alpha = if (paused) 0.4f else 1f
                    if (isEvent) {
                        val radius = 5.dp.toPx()
                        drawCircle(fill, radius, Offset(cx, markerCenter))
                        drawCircle(hue.copy(alpha = alpha), radius - 1.dp.toPx(), Offset(cx, markerCenter), style = Stroke(2.dp.toPx()))
                    } else {
                        val side = 9.dp.toPx()
                        rotate(45f, pivot = Offset(cx, markerCenter)) {
                            drawRoundRect(
                                hue.copy(alpha = alpha),
                                Offset(cx - side / 2f, markerCenter - side / 2f),
                                Size(side, side),
                                CornerRadius(2.dp.toPx()),
                            )
                        }
                    }
                },
        )
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f).padding(vertical = 12.dp)) {
            Text(
                text = row.item.content,
                style = memoryText(16f, 23f),
                color = if (paused) colors.textTertiary else colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                modifier = Modifier
                    .padding(top = 6.dp)
                    .height(22.dp)
                    .background(colors.surfaceElevated, RoundedCornerShape(6.dp))
                    .padding(start = 6.dp, end = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(row.scope.glyph(), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(12.dp))
                Text(
                    text = memoryEpisodicScopeLabel(row.scope),
                    style = memoryText(12f, 16f),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (paused) {
            Spacer(modifier = Modifier.width(8.dp))
            MemoryPausedBadge()
        }
        MemoryRowMenuButton(row.row, actions)
    }
}
