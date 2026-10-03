package ai.oriveo.community.feature.chat.mcp

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpErrorCode
import ai.oriveo.community.core.mcp.McpToolStep
import ai.oriveo.community.core.mcp.McpToolStepUpdate
import ai.oriveo.community.core.mcp.McpToolStepsPresentation
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * The link between the step block and the chat screen. Message cells sit deep in the list; threading five callbacks through would lengthen the signatures of
 * `ChatMessagesList` → `MessageItemWithActions` → `MessageBubble`. Only the step block uses them, so a CompositionLocal delivers them.
 * When not provided (previews, other screens reusing the message bubble) the step block still renders, it just is not tappable.
 */
internal class McpToolStepsHost(
    /** Ids of the steps in the current conversation parked waiting for re-authorization; reads Compose state, so only the step block recomposes. */
    val pausedStepIds: () -> Set<String>,
    /** Whether this message's tool loop hit the step limit (known only within this session, not persisted). */
    val limitReached: (messageId: String) -> Boolean,
    val onSelectStep: (messageId: String, step: McpToolStep) -> Unit,
    val onReauthorize: (step: McpToolStep) -> Unit,
    val onSkipStep: (step: McpToolStep) -> Unit,
)

internal val LocalMcpToolStepsHost = staticCompositionLocalOf<McpToolStepsHost?> { null }

/**
 * The remote MCP step block.
 *
 * A header row + expandable step rows: card radius 16, header height 46, minimum row height 44. What to show is decided by the pure function [McpToolStepsPresentation.make]; this only draws.
 *
 * Expanded while running, collapsed automatically when the answer completes; once the user expanded it manually it no longer auto-collapses.
 */
@Composable
internal fun McpToolStepsBlock(
    steps: List<McpToolStep>,
    isGenerating: Boolean,
    modifier: Modifier = Modifier,
    limitReached: Boolean = false,
    pausedStepId: String? = null,
    onSelectStep: ((McpToolStep) -> Unit)? = null,
    onReauthorize: (McpToolStep) -> Unit = {},
    onSkipStep: (McpToolStep) -> Unit = {},
) {
    if (steps.isEmpty()) return
    val colors = OriveoTheme.colors
    val presentation = remember(steps, isGenerating, limitReached, pausedStepId) {
        McpToolStepsPresentation.make(steps, isGenerating, limitReached, pausedStepId)
    }
    var expanded by rememberSaveable { mutableStateOf(presentation.isActive) }
    var userToggled by rememberSaveable { mutableStateOf(false) }
    var showsEarlier by rememberSaveable { mutableStateOf(false) }
    var wasActive by remember { mutableStateOf(presentation.isActive) }
    LaunchedEffect(presentation.isActive) {
        if (presentation.isActive && !wasActive) expanded = true
        if (!presentation.isActive && wasActive && !userToggled) expanded = false
        wasActive = presentation.isActive
    }
    // While waiting for re-authorization the action buttons live inside the block: collapsed, the user could not see what to do next.
    val isOpen = expanded || presentation.pausedForSignIn != null

    val shape = RoundedCornerShape(16.dp)
    val expansionState = stringResource(if (isOpen) R.string.mcp_steps_expanded else R.string.mcp_steps_collapsed)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .animateContentSize()
            .clip(shape)
            .background(colors.surface, shape)
            .border(1.dp, colors.border, shape),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 46.dp)
                .clickable(role = Role.Button) {
                    expanded = !isOpen
                    userToggled = true
                }
                .semantics { stateDescription = expansionState }
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Build,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = colors.primaryTextSafe,
            )
            Text(
                text = headerText(presentation.header),
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            trailingText(presentation.trailing)?.let { trailing ->
                Text(
                    text = trailing,
                    style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp),
                    color = colors.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
            }
            Icon(
                imageVector = if (isOpen) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = colors.textTertiary,
            )
        }

        if (isOpen) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(colors.border))
            Column(modifier = Modifier.padding(top = 4.dp, bottom = 6.dp)) {
                val hidden = if (showsEarlier) 0 else presentation.hiddenEarlierCount
                if (hidden > 0) {
                    Box(
                        modifier = Modifier
                            .heightIn(min = 44.dp)
                            .clickable(role = Role.Button) { showsEarlier = true }
                            .padding(horizontal = 14.dp),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        Text(
                            text = pluralStringResource(R.plurals.mcp_steps_show_earlier, hidden, hidden),
                            style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold),
                            color = colors.primaryTextSafe,
                        )
                    }
                }
                presentation.rows.drop(hidden).forEach { row ->
                    StepRow(row = row, onSelect = onSelectStep?.takeIf { row.opensDetail })
                }
                presentation.pausedForSignIn?.let { paused ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 6.dp, bottom = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        PauseButton(
                            text = stringResource(R.string.mcp_sign_in_again),
                            tinted = true,
                            onClick = { onReauthorize(paused) },
                            modifier = Modifier.weight(1f),
                        )
                        PauseButton(
                            text = stringResource(R.string.mcp_step_skip),
                            tinted = false,
                            onClick = { onSkipStep(paused) },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                if (presentation.limitReached) {
                    Box(Modifier.padding(start = 14.dp, end = 14.dp, top = 4.dp).fillMaxWidth().height(1.dp).background(colors.border))
                    Text(
                        text = stringResource(R.string.mcp_steps_limit_reached),
                        style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp, lineHeight = 19.sp),
                        color = colors.textTertiary,
                        modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 6.dp),
                    )
                }
            }
        }
    }
    if (presentation.pausedForSignIn != null) {
        Text(
            text = stringResource(R.string.mcp_step_resume_note),
            style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp),
            color = colors.textSecondary,
        )
    }
}

@Composable
private fun StepRow(row: McpToolStepsPresentation.Row, onSelect: ((McpToolStep) -> Unit)?) {
    val colors = OriveoTheme.colors
    val detail = mcpStepDetailText(row.detail)
    val detailColor = when (row.status) {
        McpToolStepUpdate.Status.Failed -> colors.danger
        McpToolStepUpdate.Status.NeedsAuth -> colors.warningText
        else -> colors.textTertiary
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .then(
                if (onSelect != null) {
                    Modifier.clickable(role = Role.Button) { onSelect(row.step) }
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.Extension,
            contentDescription = null,
            modifier = Modifier.padding(top = 1.dp).size(18.dp),
            tint = colors.textSecondary,
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            // Server name and tool title are third-party text and are not translated.
            Text(
                text = if (row.step.serverName.isEmpty()) row.step.displayTitle else "${row.step.serverName} · ${row.step.displayTitle}",
                style = OriveoTheme.typography.caption,
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (detail.isNotEmpty()) {
                Text(
                    text = detail,
                    style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp, lineHeight = 18.sp),
                    color = detailColor,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row(
            modifier = Modifier.padding(top = 1.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            StatusIcon(row.status)
            if (onSelect != null) {
                Icon(
                    imageVector = Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.textTertiary,
                )
            }
        }
    }
}

/** Status icon: distinguished by shape as well as colour, and carries a text label (accessibility). */
@Composable
private fun StatusIcon(status: McpToolStepUpdate.Status) {
    val colors = OriveoTheme.colors
    val label = mcpStepStatusText(status)
    when (status) {
        McpToolStepUpdate.Status.Running -> CircularProgressIndicator(
            modifier = Modifier.size(16.dp).semantics { stateDescription = label },
            strokeWidth = 2.dp,
            color = colors.primary,
            trackColor = colors.border,
        )
        McpToolStepUpdate.Status.Done -> Icon(Icons.Filled.CheckCircle, label, Modifier.size(18.dp), colors.success)
        McpToolStepUpdate.Status.Failed -> Icon(Icons.Filled.Error, label, Modifier.size(18.dp), colors.danger)
        McpToolStepUpdate.Status.NeedsAuth -> Icon(Icons.Filled.Error, label, Modifier.size(18.dp), colors.warning)
        McpToolStepUpdate.Status.Denied,
        McpToolStepUpdate.Status.Interrupted,
        -> Icon(Icons.Outlined.Block, label, Modifier.size(18.dp), colors.textTertiary)
    }
}

@Composable
private fun PauseButton(text: String, tinted: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = modifier
            .height(48.dp)
            .clip(shape)
            .background(if (tinted) colors.primarySoft else colors.surface)
            .border(1.dp, if (tinted) colors.primary.copy(alpha = 0.3f) else colors.borderStrong, shape)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
            color = if (tinted) colors.primaryTextSafe else colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun headerText(header: McpToolStepsPresentation.Header): String = when (header) {
    McpToolStepsPresentation.Header.Running -> stringResource(R.string.mcp_steps_running)
    McpToolStepsPresentation.Header.WaitingForSignIn -> stringResource(R.string.mcp_steps_waiting_sign_in)
    is McpToolStepsPresentation.Header.Finished -> pluralStringResource(R.plurals.mcp_steps_used, header.usedCount, header.usedCount)
}

@Composable
private fun trailingText(trailing: McpToolStepsPresentation.Trailing): String? = when (trailing) {
    is McpToolStepsPresentation.Trailing.Step -> trailing.number.takeIf { it > 0 }?.let { stringResource(R.string.mcp_steps_step, it) }
    // The separator between server names would normally follow each language's list convention; a middle dot reads fine in every language.
    is McpToolStepsPresentation.Trailing.Servers -> trailing.names.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    is McpToolStepsPresentation.Trailing.Declined -> stringResource(R.string.mcp_steps_declined, trailing.count)
    is McpToolStepsPresentation.Trailing.Failed -> stringResource(R.string.mcp_steps_failed, trailing.count)
}

@Composable
internal fun mcpStepStatusText(status: McpToolStepUpdate.Status): String = stringResource(
    when (status) {
        McpToolStepUpdate.Status.Running -> R.string.mcp_status_running
        McpToolStepUpdate.Status.Done -> R.string.mcp_status_done
        McpToolStepUpdate.Status.Failed -> R.string.mcp_status_failed
        McpToolStepUpdate.Status.Denied -> R.string.mcp_status_declined
        McpToolStepUpdate.Status.NeedsAuth -> R.string.mcp_status_needs_sign_in
        McpToolStepUpdate.Status.Interrupted -> R.string.mcp_step_interrupted
    },
)

/** Failure text is looked up by the closed-set error code: no status codes, protocol names or raw server text. */
@Composable
internal fun mcpStepFailureText(code: String?): String = stringResource(
    when (code?.let(McpErrorCode::fromWireValue)) {
        McpErrorCode.Timeout -> R.string.mcp_failure_timeout
        McpErrorCode.Unreachable -> R.string.mcp_failure_unreachable
        McpErrorCode.ServerError -> R.string.mcp_failure_server_error
        McpErrorCode.ToolError -> R.string.mcp_failure_tool_error
        McpErrorCode.NeedsInputUnsupported -> R.string.mcp_failure_needs_input
        McpErrorCode.ToolUnavailable -> R.string.mcp_failure_unavailable
        McpErrorCode.AuthSkipped -> R.string.mcp_failure_skipped
        else -> R.string.mcp_status_failed
    },
)

@Composable
internal fun mcpStepDetailText(detail: McpToolStepsPresentation.RowDetail): String = when (detail) {
    is McpToolStepsPresentation.RowDetail.ArgsSummary -> detail.text
    McpToolStepsPresentation.RowDetail.Declined -> stringResource(R.string.mcp_step_declined)
    McpToolStepsPresentation.RowDetail.Interrupted -> stringResource(R.string.mcp_step_interrupted)
    is McpToolStepsPresentation.RowDetail.SignInExpired -> stringResource(R.string.mcp_step_sign_in_expired, detail.serverName)
    is McpToolStepsPresentation.RowDetail.Failure -> mcpStepFailureText(detail.code)
}
