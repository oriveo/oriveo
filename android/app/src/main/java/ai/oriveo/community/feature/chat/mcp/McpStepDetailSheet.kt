package ai.oriveo.community.feature.chat.mcp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpConfirmationContent
import ai.oriveo.community.core.mcp.McpStepPayload
import ai.oriveo.community.core.mcp.McpToolStep
import ai.oriveo.community.core.mcp.McpToolStepUpdate
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.Locale
import kotlinx.coroutines.delay

/** Everything the step detail shows: the summary on the message + the local payload ([payload] null = no detail is stored for the step). */
data class McpStepDetailState(
    val messageId: String,
    val step: McpToolStep,
    val payload: McpStepPayload?,
    /** The payload is still being read from local storage. Until then the "no details" note stays hidden to avoid a flash. */
    val loading: Boolean,
)

/** Step detail. Arguments and result come from the local per-step payload; without one, a one-line note is shown instead. */
@Composable
internal fun McpStepDetailSheet(detail: McpStepDetailState, onDismiss: () -> Unit, serverIconUrl: String? = null, serverUrl: String? = null) {
    McpBottomSheet(onDismiss = onDismiss) {
        McpStepDetailContent(detail, serverIconUrl, serverUrl)
    }
}

@Composable
internal fun ColumnScope.McpStepDetailContent(detail: McpStepDetailState, serverIconUrl: String? = null, serverUrl: String? = null) {
    val colors = OriveoTheme.colors
    val step = detail.step
    val status = step.statusValue ?: McpToolStepUpdate.Status.Interrupted
    val statusText = mcpStepStatusText(status)
    val subtitle = step.durationMs?.let { durationMs ->
        stringResource(
            R.string.mcp_detail_subtitle,
            step.serverName,
            stringResource(R.string.mcp_detail_seconds, String.format(Locale.getDefault(), "%.1f", durationMs / 1000.0)),
            statusText,
        )
    } ?: stringResource(R.string.mcp_detail_subtitle_no_duration, step.serverName, statusText)

    Row(
        modifier = Modifier.padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        McpServerIcon(name = step.serverName, iconUrl = serverIconUrl, size = 44.dp, serverUrl = serverUrl)
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                text = step.displayTitle,
                style = OriveoTheme.typography.title1.copy(fontSize = 20.sp, lineHeight = 26.sp),
                color = colors.textPrimary,
            )
            Text(text = subtitle, style = OriveoTheme.typography.caption, color = colors.textSecondary)
        }
    }

    val payload = detail.payload
    val arguments = payload?.arguments?.takeIf { it.isNotEmpty() }
    val result = payload?.resultPrefix?.takeIf { it.isNotEmpty() }
    when {
        detail.loading -> Unit
        arguments == null && result == null -> Text(
            text = stringResource(R.string.mcp_detail_not_on_device),
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
        )
        else -> {
            if (arguments != null) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionTitle(stringResource(R.string.mcp_detail_sent))
                    McpCodeBlock(
                        text = remember(arguments) { McpConfirmationContent.allParametersText(arguments) },
                        maxHeight = 140.dp,
                    )
                }
            }
            if (result != null) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        SectionTitle(stringResource(R.string.mcp_detail_returned))
                        CopyAction(result)
                    }
                    McpCodeBlock(text = result, maxHeight = 180.dp)
                }
                McpFootnote(text = stringResource(R.string.mcp_detail_third_party_note), modifier = Modifier.padding(horizontal = 0.dp))
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text = text,
        style = OriveoTheme.typography.footnote.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
        color = OriveoTheme.colors.textSecondary,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}

/** "Copy" copies what is displayed (the storage layer already truncated it to 2 KB). */
@Composable
private fun CopyAction(text: String) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1600)
            copied = false
        }
    }
    McpInlineAction(
        text = stringResource(if (copied) R.string.copied else R.string.copy),
        onClick = {
            clipboard.setText(AnnotatedString(text))
            copied = true
        },
    )
}
