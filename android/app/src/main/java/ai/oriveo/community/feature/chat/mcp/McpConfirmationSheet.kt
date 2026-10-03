package ai.oriveo.community.feature.chat.mcp

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpConfirmationChoice
import ai.oriveo.community.core.mcp.McpConfirmationContent
import ai.oriveo.community.core.mcp.McpConfirmationParameter
import ai.oriveo.community.core.mcp.McpConfirmationRequest
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Content of the pre-write confirmation. Hosted by [McpConfirmationHost] at the navigation root.
 * "View full text" is a second level inside the same sheet, leaving only "Allow once" and "Deny".
 *
 * **Default focus is on "Deny"**: the sheet is triggered by the model's action and may appear just as the user presses Enter; with
 * a hardware keyboard attached, Enter / Space must not approve directly. Touch has no focus, so nothing changes visually there.
 */
@Composable
internal fun ColumnScope.McpConfirmationContentView(
    request: McpConfirmationRequest,
    confirmationId: String,
    onChoose: (McpConfirmationChoice) -> Unit,
    serverIconUrl: String? = null,
) {
    // A new confirmation returns to the first level: the previous one's full text must not carry over.
    var showingFullText by remember(confirmationId) { mutableStateOf(false) }
    val declineFocus = remember { FocusRequester() }
    // Focus goes back to "Deny" for every confirmation and every level change. The request is ignored in touch mode.
    LaunchedEffect(confirmationId, showingFullText) { runCatching { declineFocus.requestFocus() } }
    if (showingFullText) {
        FullTextPage(request = request, declineFocus = declineFocus, onBack = { showingFullText = false }, onChoose = onChoose)
    } else {
        SummaryPage(
            request = request, serverIconUrl = serverIconUrl, declineFocus = declineFocus,
            onViewAll = { showingFullText = true }, onChoose = onChoose,
        )
    }
}

@Composable
private fun ColumnScope.SummaryPage(
    request: McpConfirmationRequest,
    serverIconUrl: String?,
    declineFocus: FocusRequester,
    onViewAll: () -> Unit,
    onChoose: (McpConfirmationChoice) -> Unit,
) {
    val colors = OriveoTheme.colors
    val title = request.toolTitle.ifEmpty { request.toolName }
    val parameters = remember(request.arguments) { McpConfirmationContent.parameters(request.arguments) }
    val hasMore = remember(request.arguments) { McpConfirmationContent.hasMoreParameters(request.arguments) }

    Row(
        modifier = Modifier.padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        McpServerIcon(name = request.serverName, iconUrl = serverIconUrl, size = 44.dp)
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                text = stringResource(R.string.mcp_confirm_title, request.serverName, title),
                style = OriveoTheme.typography.title1.copy(fontSize = 20.sp, lineHeight = 26.sp),
                color = colors.textPrimary,
            )
            Text(
                text = stringResource(R.string.mcp_confirm_subtitle, request.serverName),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
        }
    }

    // At most 4 argument rows, each value clipped to two lines; on narrow screens / large fonts this block scrolls internally and the buttons stay pinned to the bottom.
    McpCard(
        modifier = Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
    ) {
        InfoRow(label = stringResource(R.string.mcp_confirm_server)) {
            Text(
                text = buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.Medium)) { append(request.serverName) }
                    if (request.serverHost.isNotEmpty()) {
                        withStyle(SpanStyle(color = colors.textTertiary)) { append(" · ${request.serverHost}") }
                    }
                },
                style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp),
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
        parameters.forEach { parameter ->
            McpHairline()
            InfoRow(label = parameter.key) {
                when (val display = parameter.display) {
                    is McpConfirmationParameter.Display.Inline -> Text(
                        text = display.text,
                        style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    is McpConfirmationParameter.Display.Long -> {
                        Text(
                            text = stringResource(R.string.mcp_confirm_about_characters, display.characterCount),
                            style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Medium),
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        McpInlineAction(
                            text = stringResource(R.string.mcp_confirm_view_all),
                            onClick = onViewAll,
                        )
                    }
                }
            }
        }
        // With more than 4 top-level arguments the rest is only visible in the full text: offer a way in, so the user never decides on a partial view.
        if (hasMore && parameters.none { it.display is McpConfirmationParameter.Display.Long }) {
            McpHairline()
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                McpInlineAction(
                    text = stringResource(R.string.mcp_confirm_view_all),
                    onClick = onViewAll,
                )
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        OriveoPrimaryButton(
            text = stringResource(R.string.mcp_confirm_allow_once),
            onClick = { onChoose(McpConfirmationChoice.Once) },
        )
        McpSecondaryButton(
            text = stringResource(R.string.mcp_confirm_allow_conversation),
            onClick = { onChoose(McpConfirmationChoice.Conversation) },
        )
        McpQuietButton(
            text = stringResource(R.string.mcp_confirm_decline),
            onClick = { onChoose(McpConfirmationChoice.Deny) },
            modifier = Modifier.focusRequester(declineFocus),
        )
    }
}

@Composable
private fun ColumnScope.FullTextPage(
    request: McpConfirmationRequest,
    declineFocus: FocusRequester,
    onBack: () -> Unit,
    onChoose: (McpConfirmationChoice) -> Unit,
) {
    val colors = OriveoTheme.colors
    val fullText = remember(request.arguments) { McpConfirmationContent.allParametersText(request.arguments) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .clickable(role = Role.Button, onClickLabel = stringResource(R.string.back), onClick = onBack),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                contentDescription = stringResource(R.string.back),
                modifier = Modifier.size(20.dp),
                tint = colors.textPrimary,
            )
        }
        Text(
            text = stringResource(R.string.mcp_confirm_full_title),
            style = OriveoTheme.typography.title1.copy(fontSize = 18.sp, lineHeight = 24.sp),
            color = colors.textPrimary,
        )
    }
    McpCodeBlock(
        text = fullText,
        modifier = Modifier.weight(1f, fill = false),
        maxHeight = 392.dp,
        monospace = false,
    )
    McpFootnote(text = stringResource(R.string.mcp_confirm_full_note, request.serverName))
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        OriveoPrimaryButton(
            text = stringResource(R.string.mcp_confirm_allow_once),
            onClick = { onChoose(McpConfirmationChoice.Once) },
        )
        McpQuietButton(
            text = stringResource(R.string.mcp_confirm_decline),
            onClick = { onChoose(McpConfirmationChoice.Deny) },
            modifier = Modifier.focusRequester(declineFocus),
        )
    }
}

/** Key-value row: the key is the server-defined argument name verbatim, in a fixed-width column; the value takes the remaining width. */
@Composable
private fun InfoRow(label: String, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp),
            color = OriveoTheme.colors.textTertiary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.width(McpKeyColumnWidth),
        )
        content()
    }
}
