package ai.oriveo.community.feature.chat

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.navigation.AppRoute
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.oriveoSurface

/** One row of the "memory used" sheet; [firstLine] is null when the item is tombstoned or missing locally. */
data class MemoryUsedRow(val itemId: String, val firstLine: String?) {
    val canFix: Boolean get() = firstLine != null
}

/** Pure rules of the "memory used" chip, its sheet and the chat memory indicator. */
object MemoryUsed {
    const val FIRST_LINE_MAX_GRAPHEMES: Int = 60

    /** Settled assistant message that recorded the memory items it was sent with. */
    fun chipVisible(message: ChatMessage): Boolean =
        message.role == ChatRole.Assistant &&
            message.state != ChatMessageState.Generating &&
            !message.memoryItemIds.isNullOrEmpty()

    /** Rows in the message's id order; ids compare case-insensitively (iOS writes uppercase UUIDs). */
    fun rows(ids: List<String>, items: List<MemoryItem>): List<MemoryUsedRow> {
        val byId = items.associateBy { it.id.lowercase() }
        return ids.distinctBy { it.lowercase() }.map { id ->
            val item = byId[id.lowercase()]
            if (item == null || item.status == MemoryStatus.DELETED) {
                MemoryUsedRow(itemId = item?.id ?: id, firstLine = null)
            } else {
                MemoryUsedRow(itemId = item.id, firstLine = firstLine(item.content))
            }
        }
    }

    /** First non-blank line, capped at [FIRST_LINE_MAX_GRAPHEMES] graphemes with an ellipsis. */
    fun firstLine(content: String): String {
        val line = content.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty()
        return if (line.graphemeCount() > FIRST_LINE_MAX_GRAPHEMES) {
            line.takeGraphemes(FIRST_LINE_MAX_GRAPHEMES) + "…"
        } else {
            line
        }
    }

    /** Settings memory page opening the editor on this row's item; null for a deleted row (no button). */
    fun editRoute(row: MemoryUsedRow): AppRoute.Memory? =
        if (row.canFix) AppRoute.Memory(editItemId = row.itemId) else null

    /** Active semantic items, the ones the chat memory indicator and the conversation toggle look at. */
    fun activeSemantic(items: List<MemoryItem>): List<MemoryItem> =
        items.filter { it.layer == MemoryLayer.SEMANTIC && it.status == MemoryStatus.ACTIVE }

    fun hasActiveSemantic(items: List<MemoryItem>): Boolean = activeSemantic(items).isNotEmpty()

    /** Preview text of the chat memory indicator: one first line per active semantic item. */
    fun indicatorPreview(items: List<MemoryItem>): String =
        activeSemantic(items).joinToString("\n") { firstLine(it.content) }
}

/** Opens the "memory used" sheet for a message's item ids; provided by the chat screen, null elsewhere. */
val LocalMemoryUsedOpener = compositionLocalOf<((List<String>) -> Unit)?> { null }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryUsedSheet(
    rows: List<MemoryUsedRow>,
    onDismiss: () -> Unit,
    onFix: (itemId: String) -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark

    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        dragHandle = { OriveoSheetDragHandle() },
        containerColor = colors.surface,
        contentColor = colors.textPrimary,
        scrimColor = colors.overlay,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.layout.screenH)
                .padding(bottom = OriveoTheme.spacing.xxl),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
        ) {
            Text(
                text = stringResource(R.string.memory_used_title),
                style = OriveoTheme.typography.title2,
                color = colors.textPrimary,
            )

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 360.dp)
                    .oriveoSurface(
                        colors = colors,
                        isDark = isDark,
                        fill = colors.surfaceInset,
                        borderColor = colors.border,
                        radius = 18.dp,
                        shadowStyle = OriveoSurfaceStyle.None,
                    )
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm),
            ) {
                rows.forEach { row ->
                    MemoryUsedRowView(row = row, onFix = { onFix(row.itemId) })
                }
            }
        }
    }
}

@Composable
private fun MemoryUsedRowView(row: MemoryUsedRow, onFix: () -> Unit) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        val line = row.firstLine
        Text(
            text = line ?: stringResource(R.string.memory_used_deleted),
            style = OriveoTheme.typography.body,
            color = if (line != null) colors.textPrimary else colors.textTertiary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (row.canFix) {
            TextButton(
                onClick = onFix,
                modifier = Modifier,
            ) {
                Text(
                    text = stringResource(R.string.memory_used_wrong),
                    style = OriveoTheme.typography.footnote,
                    color = colors.primary,
                )
            }
        }
    }
}
