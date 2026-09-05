@file:Suppress("DEPRECATION")

package ai.oriveo.community.ui.component.markdown

import android.content.ClipData
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.NoteAdd
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.OpenInFull
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext


private const val PREVIEW_LINE_LIMIT = 18
private const val CHARACTER_LIMIT = 1400
private val PREVIEW_HEIGHT = 392.dp // 18 × 20 + 32
private val CARD_CORNER = 16.dp


private val HEADER_HEIGHT = 44.dp
private val CODE_PAD = 12.dp        // iOS codeTextView.textContainerInset = 12
private val BOTTOM_FADE_HEIGHT = 44.dp
private val TOP_FADE_HEIGHT = 28.dp


private const val PREWARM_MAX_CHARS = 20_000
private const val PREWARM_DELAY_MS = 500L


@Composable
fun CodeBlockCard(
    code: String,
    language: String,
    mdColors: MarkdownColors,
    modifier: Modifier = Modifier,
    
    onSaveAsNote: ((String) -> Unit)? = null,
) {
    val codeText = remember(code) { code.replace("\t", "    ") }
    
    val lineCount = remember(codeText) { (codeText.count { it == '\n' } + 1).coerceAtLeast(1) }
    val isTruncated = remember(lineCount, codeText) {
        lineCount > PREVIEW_LINE_LIMIT || codeText.length > CHARACTER_LIMIT
    }
    val previewText = remember(codeText, isTruncated) {
        if (isTruncated) codeText.lines().take(PREVIEW_LINE_LIMIT).joinToString("\n") else codeText
    }
    val isMarkdownLanguage = remember(language) {
        language.lowercase().let { it == "markdown" || it == "md" }
    }

    var showViewer by remember { mutableStateOf(false) }

    
    if (isTruncated && !isMarkdownLanguage && codeText.length <= PREWARM_MAX_CHARS) {
        LaunchedEffect(codeText, language, mdColors) {
            delay(PREWARM_DELAY_MS)
            if (MarkdownRenderCache.cachedHighlightedCode(codeText, language, mdColors) == null) {
                withContext(Dispatchers.Default) {
                    MarkdownRenderCache.highlightCode(codeText, language, mdColors)
                }
            }
        }
    }

    val shape = RoundedCornerShape(CARD_CORNER)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(elevation = 6.dp, shape = shape, ambientColor = Color.Black.copy(alpha = 0.18f))
            .clip(shape)
            .background(mdColors.codeBlockBg)
            .border(OriveoBorderWidth.standard, mdColors.codeBlockBorder, shape),
    ) {
        
        
        val saveFencedAsNote: ((String) -> Unit)? = onSaveAsNote?.let { cb ->
            { _: String ->
                val fence = if (language.isBlank()) "```" else "```$language"
                cb("$fence\n$code\n```")
            }
        }
        CodeBlockHeader(
            language = language,
            lineCount = lineCount,
            isTruncated = isTruncated,
            mdColors = mdColors,
            code = codeText,
            onExpand = { showViewer = true },
            onSaveAsNote = saveFencedAsNote,
        )

        if (isMarkdownLanguage) {
            MarkdownCodePreview(
                code = previewText,
                mdColors = mdColors,
                isTruncated = isTruncated,
            )
        } else {
            SyntaxCodePreview(
                code = previewText,
                language = language,
                mdColors = mdColors,
                isTruncated = isTruncated,
            )
        }
    }

    if (showViewer) {
        CodeBlockViewerSheet(
            language = language,
            code = codeText,
            mdColors = mdColors,
            onDismiss = { showViewer = false },
        )
    }
}


@Composable
fun StreamingCodeBlockCard(
    code: String,
    language: String,
    mdColors: MarkdownColors,
    modifier: Modifier = Modifier,
) {
    val normalized = remember(code) { code.replace("\t", "    ").ifEmpty { " " } }
    val lines = remember(normalized) { normalized.lines() }
    val lineCount = lines.size.coerceAtLeast(1)
    val exceedsLine = lineCount > PREVIEW_LINE_LIMIT
    val exceedsChar = normalized.length > CHARACTER_LIMIT
    val isTruncated = exceedsLine || exceedsChar
    val previewText = remember(normalized, isTruncated) {
        if (!isTruncated) {
            normalized
        } else {
            val tailed = if (exceedsLine) {
                lines.takeLast(PREVIEW_LINE_LIMIT).joinToString("\n")
            } else {
                normalized
            }
            if (tailed.length > CHARACTER_LIMIT) tailed.takeLast(CHARACTER_LIMIT) else tailed
        }
    }

    val shape = RoundedCornerShape(CARD_CORNER)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(elevation = 6.dp, shape = shape, ambientColor = Color.Black.copy(alpha = 0.18f))
            .clip(shape)
            .background(mdColors.codeBlockBg)
            .border(OriveoBorderWidth.standard, mdColors.codeBlockBorder, shape),
    ) {
        
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(HEADER_HEIGHT)
                .background(mdColors.codeBlockSurface)
                .padding(horizontal = OriveoTheme.spacing.md),
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LanguageCapsule(language = language, mdColors = mdColors)
            Spacer(modifier = Modifier.weight(1f))
            if (isTruncated) {
                Text(
                    text = stringResource(R.string.code_block_lines, lineCount),
                    style = OriveoTheme.typography.footnote,
                    color = mdColors.codeBlockSecondary,
                )
            }
        }

        
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .let { if (isTruncated) it.height(PREVIEW_HEIGHT) else it },
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(CODE_PAD),
                verticalAlignment = Alignment.Bottom,
            ) {
                
                
                
                
                
                val highlighted = remember(previewText, language, mdColors) {
                    highlightStreamingCode(previewText, language, mdColors)
                }
                Text(
                    text = highlighted,
                    style = OriveoTheme.typography.code.copy(color = mdColors.codeBlockFg),
                )
                Spacer(modifier = Modifier.width(2.dp))
                StreamingCodeCursor(color = mdColors.codeBlockFg)
            }

            if (isTruncated) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(TOP_FADE_HEIGHT)
                        .background(
                            brush = Brush.verticalGradient(
                                colors = listOf(
                                    mdColors.codeBlockBg.copy(alpha = 0.92f),
                                    Color.Transparent,
                                ),
                            ),
                        )
                        .align(Alignment.TopCenter),
                )
            }
        }
    }
}

@Composable
private fun CodeBlockHeader(
    language: String,
    lineCount: Int,
    isTruncated: Boolean,
    mdColors: MarkdownColors,
    code: String,
    onExpand: () -> Unit,
    onSaveAsNote: ((String) -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(HEADER_HEIGHT)
            .background(mdColors.codeBlockSurface)
            .padding(horizontal = OriveoTheme.spacing.md),
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LanguageCapsule(language = language, mdColors = mdColors)

        Spacer(modifier = Modifier.weight(1f))

        if (isTruncated) {
            Text(
                text = stringResource(R.string.code_block_lines, lineCount),
                style = OriveoTheme.typography.footnote,
                color = mdColors.codeBlockSecondary,
            )
        }

        CopyPillButton(code = code, mdColors = mdColors)

        if (onSaveAsNote != null) {
            HeaderPillButton(
                icon = { Icon(Icons.AutoMirrored.Outlined.NoteAdd, contentDescription = null, modifier = Modifier.size(11.dp), tint = mdColors.codeBlockFg) },
                label = stringResource(R.string.notes_chat_save_as_note),
                mdColors = mdColors,
                onClick = { onSaveAsNote(code) },
            )
        }

        if (isTruncated) {
            HeaderPillButton(
                icon = { Icon(Icons.Outlined.OpenInFull, contentDescription = null, modifier = Modifier.size(11.dp), tint = mdColors.codeBlockFg) },
                label = stringResource(R.string.code_block_expand),
                mdColors = mdColors,
                onClick = onExpand,
            )
        }
    }
}

@Composable
private fun LanguageCapsule(language: String, mdColors: MarkdownColors) {
    val display = remember(language) {
        if (language.isNotEmpty()) language.uppercase() else ""
    }
    val defaultLabel = stringResource(R.string.code_block_default_language)
    val finalText = if (display.isEmpty()) defaultLabel.uppercase() else display

    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(mdColors.codeBlockSurface)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Outlined.Code,
            contentDescription = null,
            modifier = Modifier.size(11.dp),
            tint = mdColors.codeBlockSecondary,
        )
        Text(
            text = finalText,
            style = OriveoTheme.typography.footnote,
            color = mdColors.codeBlockFg,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun CopyPillButton(code: String, mdColors: MarkdownColors) {
    val clipboard = LocalClipboard.current
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }

    HeaderPillButton(
        icon = {
            Icon(
                imageVector = if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
                contentDescription = null,
                modifier = Modifier.size(11.dp),
                tint = mdColors.codeBlockFg,
            )
        },
        label = stringResource(if (copied) R.string.copied else R.string.copy),
        mdColors = mdColors,
        onClick = {
            scope.launch {
                clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("code", code)))
            }
            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            copied = true
        },
    )
}

@Composable
private fun HeaderPillButton(
    icon: @Composable () -> Unit,
    label: String,
    mdColors: MarkdownColors,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon()
        Text(
            text = label,
            style = OriveoTheme.typography.footnote,
            color = mdColors.codeBlockFg,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SyntaxCodePreview(
    code: String,
    language: String,
    mdColors: MarkdownColors,
    isTruncated: Boolean,
) {
    
    
    
    val highlighted = remember(code, language, mdColors) {
        MarkdownRenderCache.highlightCode(code, language, mdColors)
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (isTruncated) it.height(PREVIEW_HEIGHT) else it },
    ) {
        Text(
            text = highlighted,
            style = OriveoTheme.typography.code.copy(color = mdColors.codeBlockFg),
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(CODE_PAD),
        )

        if (isTruncated) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(BOTTOM_FADE_HEIGHT)
                    .background(
                        brush = Brush.verticalGradient(
                            colors = listOf(
                                Color.Transparent,
                                mdColors.codeBlockBg.copy(alpha = 0.92f),
                            ),
                        ),
                    )
                    .align(Alignment.BottomCenter),
            )
        }
    }
}


@Composable
private fun MarkdownCodePreview(
    code: String,
    mdColors: MarkdownColors,
    isTruncated: Boolean,
) {
    val previewColors = remember(mdColors) {
        mdColors.copy(
            text = mdColors.codeBlockFg,
            textSecondary = mdColors.codeBlockSecondary,
            inlineCodeBg = mdColors.codeBlockSurface,
            inlineCodeText = mdColors.codeBlockFg,
            quoteBorder = mdColors.codeBlockSecondary,
            quoteText = mdColors.codeBlockSecondary,
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (isTruncated) it.height(PREVIEW_HEIGHT) else it },
    ) {
        
        
        val contentModifier = if (isTruncated) {
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(CODE_PAD)
        } else {
            Modifier
                .fillMaxWidth()
                .padding(CODE_PAD)
        }
        Box(modifier = contentModifier) {
            StaticMarkdownContent(
                text = code,
                mdColors = previewColors,
                isUserMessage = false,
            )
        }

        if (isTruncated) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(BOTTOM_FADE_HEIGHT)
                    .background(
                        brush = Brush.verticalGradient(
                            colors = listOf(
                                Color.Transparent,
                                mdColors.codeBlockBg.copy(alpha = 0.92f),
                            ),
                        ),
                    )
                    .align(Alignment.BottomCenter),
            )
        }
    }
}

/**
 *  —  iOS CodeBlockViewerSheet (sheet + NavigationStack + Done )
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CodeBlockViewerSheet(
    language: String,
    code: String,
    mdColors: MarkdownColors,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val displayLang = remember(language) {
        if (language.isNotEmpty()) language.uppercase() else ""
    }
    val defaultLabel = stringResource(R.string.code_block_default_language).uppercase()
    val title = displayLang.ifEmpty { defaultLabel }

    val highlighted = remember(code, language, mdColors) {
        MarkdownRenderCache.highlightCode(code, language, mdColors)
    }

    // The viewer sheet has its own layout root. Drop the message-level registrar, then create a
    // root-local SelectionContainer only around code so full-screen selection/copy remains intact.
    DisableSelection {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = sheetState,
            containerColor = mdColors.codeBlockBg,
            dragHandle = null,
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = OriveoTheme.spacing.md, vertical = OriveoTheme.spacing.sm),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = title,
                        style = OriveoTheme.typography.title3,
                        color = mdColors.codeBlockSecondary,
                    )
                    TextButton(onClick = onDismiss) {
                        Text(
                            text = stringResource(R.string.done),
                            color = mdColors.codeBlockFg,
                        )
                    }
                }

                
                SelectionContainer(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState()),
                ) {
                    Text(
                        text = highlighted,
                        style = OriveoTheme.typography.code.copy(color = mdColors.codeBlockFg),
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(OriveoTheme.spacing.xl),
                    )
                }
            }
        }
    }
}


internal fun highlightStreamingCode(
    code: String,
    language: String,
    colors: MarkdownColors,
): AnnotatedString {
    val lastNewline = code.lastIndexOf('\n')
    if (lastNewline < 0) return AnnotatedString(code)
    return buildAnnotatedString {
        append(SyntaxHighlighter.highlight(code.substring(0, lastNewline), language, colors))
        append(code.substring(lastNewline))
    }
}

@Composable
private fun StreamingCodeCursor(color: Color) {
    val infinite = rememberInfiniteTransition(label = "code-cursor-blink")
    val alpha by infinite.animateFloat(
        initialValue = 1f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 550, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "code-cursor-alpha",
    )

    Box(
        modifier = Modifier
            .size(width = 2.dp, height = 16.dp)
            
            
            .drawBehind { drawRect(color = color.copy(alpha = alpha)) },
    )
}
