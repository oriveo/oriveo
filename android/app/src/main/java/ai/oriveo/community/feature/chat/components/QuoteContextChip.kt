package ai.oriveo.community.feature.chat.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

internal enum class QuoteContextChipPresentation { Composer, SentMessage }

/** Pending/sent quote treatment. Composer has lift; sent snapshots deliberately have none. */
@Composable
internal fun QuoteContextChip(
    quote: QuoteContext,
    presentation: QuoteContextChipPresentation,
    onRemove: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    if (!quote.isValid) return
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(14.dp)
    val fill = when (presentation) {
        QuoteContextChipPresentation.Composer -> colors.primarySoft
            .opacity(if (isDark) 0.66f else 0.54f)
            .compositeOver(colors.surfaceElevated.opacity(if (isDark) 0.78f else 0.92f))
        QuoteContextChipPresentation.SentMessage -> Color.White.opacity(if (isDark) 0.14f else 0.12f)
    }
    var expanded by remember(quote) { mutableStateOf(false) }
    val selectedDescription = stringResource(R.string.chat_quote_selected_content, quote.summaryText)
    val removeDescription = stringResource(R.string.chat_quote_remove)
    val fullContextDescription = stringResource(
        R.string.chat_quote_full_context_accessibility,
        quote.selectedText,
        quote.fullContextText,
    )

    Box(modifier = modifier) {
        Row(
            modifier = Modifier
                .then(if (presentation == QuoteContextChipPresentation.Composer) Modifier.shadow(4.dp, shape) else Modifier)
                .background(fill, shape)
                .heightIn(min = 48.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clickable { expanded = true }
                    .heightIn(min = 48.dp)
                    .padding(start = 12.dp, end = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Outlined.FormatQuote,
                    contentDescription = null,
                    tint = if (presentation == QuoteContextChipPresentation.Composer) colors.primary else Color.White,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = quote.summaryText,
                    style = OriveoTheme.typography.footnote,
                    color = if (presentation == QuoteContextChipPresentation.Composer) colors.textPrimary else Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { contentDescription = selectedDescription },
                )
            }
            onRemove?.let { remove ->
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clickable(onClick = remove)
                        .semantics { contentDescription = removeDescription },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(12.dp),
                    )
                }
            }
        }

        // DropdownMenu is rendered in a Popup root. Never let a parent SelectionContainer register
        // these labels against the parent's unrelated layout hierarchy.
        DisableSelection {
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
                modifier = Modifier.background(colors.surfaceElevated),
            ) {
                val leading = if (quote.contextTruncated) "…${quote.leadingText}" else quote.leadingText
                val trailing = if (quote.contextTruncated) "${quote.trailingText}…" else quote.trailingText
                val preview = buildAnnotatedString {
                    append(leading)
                    val selectedStart = length
                    append(quote.selectedText)
                    addStyle(
                        SpanStyle(background = if (isDark) Color(0x807A5A00) else Color(0xFFFFE58F)),
                        selectedStart,
                        length,
                    )
                    append(trailing)
                }
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = (LocalConfiguration.current.screenHeightDp * 0.6f).dp)
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp),
                ) {
                    Text(
                        text = stringResource(R.string.chat_quote_full_context),
                        style = OriveoTheme.typography.caption,
                        color = colors.textSecondary,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                    Text(
                        text = preview,
                        style = OriveoTheme.typography.body,
                        color = colors.textPrimary,
                        modifier = Modifier.semantics {
                            contentDescription = fullContextDescription
                        },
                    )
                }
            }
        }
    }
}
