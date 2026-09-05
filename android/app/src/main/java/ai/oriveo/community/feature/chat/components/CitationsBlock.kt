package ai.oriveo.community.feature.chat.components

import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.security.isSafeExternalUrl
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Renders the web-search citations attached to a message.
 *
 * Takes a [Citation] list, collapsed by default to the first 3 entries with a
 * "View all N sources" toggle to expand the rest. Each entry shows a favicon, title,
 * and domain, and opens externally in the browser when tapped.
 *
 * Uses Material3 colors for both light and dark themes via [OriveoTheme], matching
 * MessageBubble's color and spacing choices.
 */
@Composable
fun CitationsBlock(
    citations: List<Citation>,
    modifier: Modifier = Modifier,
) {
    if (citations.isEmpty()) return

    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val context = LocalContext.current

    val collapsedLimit = 3
    var expanded by remember { mutableStateOf(false) }
    val visibleItems = if (expanded || citations.size <= collapsedLimit) {
        citations
    } else {
        citations.take(collapsedLimit)
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .border(
                width = OriveoBorderWidth.standard,
                color = colors.hairline,
                shape = RoundedCornerShape(12.dp),
            )
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(spacing.xs),
    ) {
        // Title row
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Public,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = colors.textSecondary,
            )
            Text(
                text = stringResource(R.string.citations_section_title),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }

        visibleItems.forEachIndexed { idx, citation ->
            CitationRow(
                citation = citation,
                index = citation.index ?: idx + 1,
                onClick = { url ->
                    if (!isOpenableCitationUrl(url)) return@CitationRow
                    if (!openExternalUrl(context, url)) {
                        Toast.makeText(context, R.string.link_open_failed_message, Toast.LENGTH_LONG).show()
                    }
                },
            )
        }

        // Expand/collapse button
        if (citations.size > collapsedLimit) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded }
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    imageVector = if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.textTertiary,
                )
                Text(
                    text = if (expanded) {
                        stringResource(R.string.citations_collapse)
                    } else {
                        stringResource(R.string.citations_view_all, citations.size)
                    },
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun CitationRow(
    citation: Citation,
    index: Int,
    onClick: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    val host = remember(citation.url) { extractHost(citation.url) }
    val isOpenable = remember(citation.url) { isOpenableCitationUrl(citation.url) }
    val title = citation.title?.takeIf { it.isNotBlank() } ?: host ?: citation.url

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = isOpenable) { onClick(citation.url) }
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val sourceIcon = when (citation.source) {
            "notion" -> Icons.AutoMirrored.Outlined.MenuBook
            "google" -> Icons.Outlined.Description
            else -> Icons.Outlined.Public
        }
        Box(
            modifier = Modifier
                .size(16.dp)
                .background(colors.backgroundSecondary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = sourceIcon,
                contentDescription = null,
                modifier = Modifier.size(12.dp),
                tint = colors.textTertiary,
            )
        }

        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = "[$index] $title",
                style = OriveoTheme.typography.footnote,
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            val sourceDetail = listOfNotNull(
                citation.source?.replaceFirstChar { it.uppercase() },
                citation.lastEdited?.let(::formatCitationDate),
                host,
            ).distinct().joinToString(" · ")
            if (sourceDetail.isNotBlank()) {
                Text(
                    text = sourceDetail,
                    style = OriveoTheme.typography.caption,
                    color = colors.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

private fun extractHost(url: String): String? {
    return runCatching {
        val uri = Uri.parse(url)
        uri.host?.takeIf { it.isNotBlank() }?.removePrefix("www.")
    }.getOrNull()
}

internal fun isOpenableCitationUrl(raw: String): Boolean = isSafeExternalUrl(raw)

private fun formatCitationDate(raw: String): String = runCatching {
    java.time.Instant.parse(raw)
        .atZone(java.time.ZoneId.systemDefault())
        .toLocalDate()
        .format(java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.MEDIUM))
}.getOrDefault(raw)
