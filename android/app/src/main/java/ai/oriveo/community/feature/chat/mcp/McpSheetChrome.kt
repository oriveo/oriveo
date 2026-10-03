package ai.oriveo.community.feature.chat.mcp

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.theme.OriveoTheme

// Shared look of the chat-side remote MCP bottom sheets:
// top corner radius 28, grabber 36 × 5, 30 of top padding, 18 between blocks. Sheet height follows the content, and the content holds no lazy containers.

internal val McpSheetShape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)

/**
 * Bottom sheet shell. When [dismissible] is false, swipe-to-dismiss is truly disabled (confirmation sheet: once swiped away nobody answers the step and the loop would hang forever).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun McpBottomSheet(
    onDismiss: () -> Unit,
    dismissible: Boolean = true,
    contentPadding: PaddingValues = McpSheetContentPadding,
    content: @Composable ColumnScope.() -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { dismissible || it != SheetValue.Hidden },
    )
    OriveoModalBottomSheet(
        onDismissRequest = { if (dismissible) onDismiss() },
        sheetState = sheetState,
        dragHandle = null,
        shape = McpSheetShape,
        containerColor = OriveoTheme.colors.background,
        scrimColor = OriveoTheme.colors.overlay,
        contentWindowInsets = { WindowInsets(0) },
    ) {
        McpSheetBody(contentPadding = contentPadding, content = content)
    }
}

/** Bottom sheet padding: 20 horizontal, 34 bottom; the 30 at the top comes from [McpSheetBody]. */
internal const val MCP_SHEET_BODY_TAG = "mcp_sheet_body"

internal val McpSheetContentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 34.dp)

/** Sheet content skeleton: grabber + 30 of top padding + 18 between blocks. A separate function so UI tests can render it without the sheet window. */
@Composable
internal fun McpSheetBody(
    contentPadding: PaddingValues = McpSheetContentPadding,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = OriveoTheme.colors
    Box(modifier = Modifier.fillMaxWidth().navigationBarsPadding().testTag(MCP_SHEET_BODY_TAG)) {
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 8.dp)
                .size(width = 36.dp, height = 5.dp)
                .background(colors.borderStrong, RoundedCornerShape(999.dp))
                .clearAndSetSemantics { },
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 30.dp)
                .padding(contentPadding),
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(18.dp),
            content = content,
        )
    }
}

/** Sheet title (brand font 20 / 700) + subtitle (14, secondary text colour). */
@Composable
internal fun McpSheetHeader(title: String, subtitle: String? = null, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    Column(
        modifier = modifier.padding(horizontal = 4.dp),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(5.dp),
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.title1.copy(fontSize = 20.sp, lineHeight = 26.sp),
            color = colors.textPrimary,
        )
        if (!subtitle.isNullOrEmpty()) {
            Text(text = subtitle, style = OriveoTheme.typography.caption, color = colors.textSecondary)
        }
    }
}

/**
 * Initial tile for a server (used when the server has no icon of its own). The same name always lands on the same colour pair.
 */
@Composable
internal fun McpServerTile(name: String, size: Dp = 40.dp, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val palette = listOf(
        colors.primarySoft to colors.primaryTextSafe,
        colors.surfaceInset to colors.textPrimary,
        colors.successSoft to colors.success,
        colors.infoSoft to colors.info,
    )
    val trimmed = name.trim()
    val letter = if (trimmed.isEmpty()) "?" else String(Character.toChars(trimmed.codePointAt(0))).uppercase()
    val (fill, ink) = palette[(trimmed.fold(0) { acc, char -> acc * 31 + char.code }).mod(palette.size)]
    val shape = RoundedCornerShape(size * 0.28f)
    Box(
        modifier = modifier
            .size(size)
            .background(fill, shape)
            .border(1.dp, colors.border, shape)
            .clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = letter,
            style = OriveoTheme.typography.title1.copy(fontSize = (size.value * 0.44f).sp, lineHeight = (size.value * 0.5f).sp),
            color = ink,
            maxLines = 1,
        )
    }
}

/** Card: card background + 1dp outline + corner radius 20. */
@Composable
internal fun McpCard(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(horizontal = 14.dp, vertical = 2.dp),
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(20.dp)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surface, shape)
            .border(1.dp, colors.border, shape)
            .padding(contentPadding),
        content = content,
    )
}

@Composable
internal fun McpHairline(modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxWidth().height(1.dp).background(OriveoTheme.colors.border))
}

/** Monospace code block (arguments / result / full text). Scrolls internally beyond [maxHeight]. */
@Composable
internal fun McpCodeBlock(text: String, modifier: Modifier = Modifier, maxHeight: Dp = 220.dp, monospace: Boolean = true) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(max = maxHeight)
            .background(colors.surfaceInset, shape)
            .border(1.dp, colors.border, shape)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        SelectionContainer {
            Text(
                text = text,
                style = if (monospace) {
                    OriveoTheme.typography.code.copy(fontSize = 12.5.sp, lineHeight = 20.sp)
                } else {
                    OriveoTheme.typography.caption.copy(lineHeight = 22.sp)
                },
                color = colors.textPrimary,
            )
        }
    }
}

/** Secondary button: card background + strong outline + primary text colour; height uses the same token as the primary button. */
@Composable
internal fun McpSecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(OriveoTheme.layout.buttonHeight)
            .clip(shape)
            .background(if (pressed) colors.surfaceInset else colors.surface)
            .border(1.dp, colors.borderStrong, shape)
            .clickable(interactionSource = interactionSource, indication = null, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = OriveoTheme.typography.title3,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Text button: height 44, secondary text colour 15 / 500 (the lightest option, such as "Deny"). */
@Composable
internal fun McpQuietButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = OriveoTheme.colors.textSecondary) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(12.dp))
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.Medium),
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Inline text button ("Re-authorize", "View full text", "Copy"): 44-high touch target, brand-coloured text at weight 600. */
@Composable
internal fun McpInlineAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
            color = OriveoTheme.colors.primaryTextSafe,
            maxLines = 1,
        )
    }
}

@Composable
internal fun McpFootnote(text: String, modifier: Modifier = Modifier, color: Color = OriveoTheme.colors.textTertiary) {
    Text(
        text = text,
        style = OriveoTheme.typography.footnote.copy(lineHeight = 18.sp),
        color = color,
        modifier = modifier.padding(horizontal = 6.dp),
    )
}

internal val McpKeyColumnWidth = 64.dp

@Composable
internal fun McpSpacerWidth(width: Dp) = androidx.compose.foundation.layout.Spacer(Modifier.width(width))
