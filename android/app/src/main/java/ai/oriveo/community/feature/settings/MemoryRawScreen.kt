package ai.oriveo.community.feature.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Raw view state (P5·U6 contract rule 5): [items] is the snapshot the text was rendered from;
 * [tooLongIndex] is the 1-based segment shown in the error line, null when there is no error.
 */
data class MemoryRawState(
    val items: List<MemoryItem>,
    val text: String = MemoryItems.rawRender(items),
    val tooLongIndex: Int? = null,
)

/** One logical line of the raw text: [start] offset, separator line, or part of the too-long segment. */
private data class RawLine(val start: Int, val end: Int, val separator: Boolean, val error: Boolean)

/** Splits like MemoryItems.rawSegments: segments between separator lines, blank ones not counted. */
private fun rawLines(text: String, tooLongIndex: Int?): List<RawLine> {
    val lines = text.split("\n")
    val starts = lines.runningFold(0) { offset, line -> offset + line.length + 1 }
    val isSeparator = lines.map { it.removeSuffix("\r") == MemoryItems.RAW_VIEW_SEPARATOR }
    val ordinal = IntArray(lines.size)
    var segment = 0
    var groupStart = 0
    for (index in 0..lines.size) {
        if (index == lines.size || isSeparator[index]) {
            val group = groupStart until index
            if (group.any { lines[it].isNotBlank() }) {
                segment += 1
                group.forEach { ordinal[it] = segment }
            }
            groupStart = index + 1
        }
    }
    return lines.indices.map { index ->
        RawLine(
            start = starts[index],
            end = starts[index] + lines[index].length,
            separator = isSeparator[index],
            error = tooLongIndex != null && ordinal[index] == tooLongIndex,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MemoryRawScreen(
    state: MemoryRawState,
    onTextChange: (String) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    val colors = OriveoTheme.colors
    BackHandler(onBack = onCancel)
    Box(modifier = Modifier.fillMaxSize().background(colors.backgroundGrouped)) {
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                CenterAlignedTopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.memory_raw_view),
                            style = memoryText(17f, 22f, FontWeight.SemiBold),
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = {
                        TextButton(onClick = onCancel, modifier = Modifier) {
                            Text(stringResource(R.string.cancel), style = memoryText(17f, 22f), color = colors.textSecondary)
                        }
                    },
                    actions = {
                        TextButton(onClick = onSave, modifier = Modifier) {
                            Text(
                                text = stringResource(R.string.memory_raw_view_save),
                                style = memoryText(17f, 22f, FontWeight.SemiBold),
                                color = colors.primaryTextSafe,
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->
            Box(
                modifier = Modifier.fillMaxSize().padding(padding).imePadding(),
                contentAlignment = Alignment.TopCenter,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = 600.dp)
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp)
                        .padding(top = 8.dp, bottom = OriveoTheme.spacing.xl),
                ) {
                    Row(
                        modifier = Modifier
                            .padding(horizontal = 4.dp)
                            .fillMaxWidth()
                            .background(colors.surfaceElevated, RoundedCornerShape(12.dp))
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            text = MemoryItems.RAW_VIEW_SEPARATOR,
                            style = memoryText(12f, 16f).copy(fontFamily = MemoryMonoFamily),
                            color = colors.primary,
                            modifier = Modifier
                                .background(memoryCardFill(), RoundedCornerShape(5.dp))
                                .padding(horizontal = 6.dp, vertical = 1.dp),
                        )
                        Text(
                            text = stringResource(R.string.memory_raw_view_hint),
                            style = memoryText(13f, 18f),
                            color = colors.textSecondary,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    MemoryRawEditor(
                        text = state.text,
                        onTextChange = onTextChange,
                        tooLongIndex = state.tooLongIndex,
                        modifier = Modifier.padding(top = 14.dp),
                    )
                    state.tooLongIndex?.let { index ->
                        Row(
                            modifier = Modifier.padding(top = 14.dp, start = 4.dp, end = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(MemoryGlyphs.ErrorCircle, contentDescription = null, tint = colors.error, modifier = Modifier.padding(top = 1.dp).size(16.dp))
                            Text(
                                text = stringResource(R.string.memory_raw_view_too_long, index),
                                style = memoryText(13.5f, 19f, FontWeight.Medium),
                                color = colors.error,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }
        }
    }
}

private val GUTTER = 38.dp
private val EDITOR_VERTICAL_PADDING = 10.dp
private val EDITOR_END_PADDING = 14.dp

/** Raw text with a line-number gutter, mono separator lines and the too-long segment banded red. */
@Composable
private fun MemoryRawEditor(
    text: String,
    onTextChange: (String) -> Unit,
    tooLongIndex: Int?,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(16.dp)
    val measurer = rememberTextMeasurer()
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val lines = remember(text, tooLongIndex) { rawLines(text, tooLongIndex) }
    val separatorStyle = SpanStyle(fontFamily = MemoryMonoFamily, fontSize = 13.sp, color = colors.textTertiary)
    val transformation = remember(lines, separatorStyle) {
        VisualTransformation { input ->
            val builder = AnnotatedString.Builder(input)
            lines.filter { it.separator && it.end <= input.length }.forEach { builder.addStyle(separatorStyle, it.start, it.end) }
            TransformedText(builder.toAnnotatedString(), OffsetMapping.Identity)
        }
    }
    val numberStyle = TextStyle(fontFamily = MemoryMonoFamily, fontSize = 11.sp)
    val numberColor = colors.textTertiary.copy(alpha = colors.textTertiary.alpha * 0.7f)
    val errorColor = colors.error
    val errorFill = colors.errorSoft
    val dash = memoryLineStrong()
    BasicTextField(
        value = text,
        onValueChange = onTextChange,
        textStyle = memoryText(16f, 28f).copy(color = colors.textPrimary),
        cursorBrush = SolidColor(colors.primary),
        visualTransformation = transformation,
        onTextLayout = { layout = it },
        modifier = modifier.fillMaxWidth(),
        decorationBox = { inner ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 280.dp)
                    .clip(shape)
                    .background(colors.surfaceInset)
                    .border(1.dp, colors.border, shape)
                    .drawBehind {
                        val result = layout ?: return@drawBehind
                        val length = result.layoutInput.text.length
                        val rtl = layoutDirection == LayoutDirection.Rtl
                        val top0 = EDITOR_VERTICAL_PADDING.toPx()
                        val gutter = GUTTER.toPx()
                        lines.forEachIndexed { index, line ->
                            if (line.start > length) return@forEachIndexed
                            val first = result.getLineForOffset(line.start)
                            val last = result.getLineForOffset(line.end.coerceAtMost(length))
                            val top = top0 + result.getLineTop(first)
                            val bottom = top0 + result.getLineBottom(last)
                            if (line.error) {
                                drawRect(errorFill, Offset(0f, top), Size(size.width, bottom - top))
                                val barX = if (rtl) size.width - 3.dp.toPx() else 0f
                                drawRect(errorColor, Offset(barX, top), Size(3.dp.toPx(), bottom - top))
                            }
                            val number = measurer.measure((index + 1).toString(), numberStyle)
                            val numberY = top + (result.getLineBottom(first) - result.getLineTop(first) - number.size.height) / 2f
                            val numberX = if (rtl) size.width - gutter + 12.dp.toPx() else gutter - 12.dp.toPx() - number.size.width
                            drawText(number, color = if (line.error) errorColor else numberColor, topLeft = Offset(numberX, numberY))
                            if (line.separator) {
                                val y = (top + bottom) / 2f
                                val textStart = gutter + result.getLineRight(first) - result.getLineLeft(first) + 10.dp.toPx()
                                val end = size.width - EDITOR_END_PADDING.toPx()
                                if (textStart < end) {
                                    val (x0, x1) = if (rtl) (size.width - end) to (size.width - textStart) else textStart to end
                                    drawLine(
                                        dash,
                                        Offset(x0, y),
                                        Offset(x1, y),
                                        1.dp.toPx(),
                                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())),
                                    )
                                }
                            }
                        }
                    }
                    .padding(start = GUTTER, end = EDITOR_END_PADDING, top = EDITOR_VERTICAL_PADDING, bottom = EDITOR_VERTICAL_PADDING),
            ) {
                inner()
            }
        },
    )
}
