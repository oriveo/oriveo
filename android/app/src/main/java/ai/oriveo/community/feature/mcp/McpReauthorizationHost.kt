package ai.oriveo.community.feature.mcp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpReauthPhase
import ai.oriveo.community.core.mcp.McpReauthSession
import ai.oriveo.community.core.mcp.McpReauthorizationCoordinator
import ai.oriveo.community.feature.chat.mcp.McpBottomSheet
import ai.oriveo.community.feature.chat.mcp.McpQuietButton
import ai.oriveo.community.feature.chat.mcp.McpServerIcon
import ai.oriveo.community.feature.chat.mcp.McpSheetHeader
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.compose.koinInject

/**
 * The re-authorization sheet, mounted at the navigation root: the chat tool panel, the step block and the management detail screen can all start a
 * re-authorization, and this presents it whoever did (pre-sign-in notice → browser → result; or pasting a new access token). Draws nothing when none is in progress.
 */
@Composable
fun McpReauthorizationHost(coordinator: McpReauthorizationCoordinator = koinInject()) {
    val session by coordinator.session.collectAsStateWithLifecycle()
    val current = session ?: return
    // Cannot be swiped away while checking, signing in through the browser or submitting a token: that step either asks again or ends by itself.
    val interruptible = when (val phase = current.phase) {
        is McpReauthPhase.Prompt, is McpReauthPhase.Failed -> true
        is McpReauthPhase.Token -> !phase.busy
        McpReauthPhase.Checking, McpReauthPhase.Browser -> false
    }
    McpBottomSheet(onDismiss = coordinator::cancel, dismissible = interruptible) {
        McpReauthorizationContent(
            session = current,
            onContinue = coordinator::approve,
            onSubmitToken = coordinator::submitToken,
            onRetry = coordinator::retry,
            onCancel = coordinator::cancel,
        )
    }
}

@Composable
internal fun ColumnScope.McpReauthorizationContent(
    session: McpReauthSession,
    onContinue: () -> Unit,
    onSubmitToken: (String) -> Unit,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
) {
    when (val phase = session.phase) {
        McpReauthPhase.Checking -> Waiting(session, stringResource(R.string.mcp_reauth_checking))
        McpReauthPhase.Browser -> Waiting(session, stringResource(R.string.mcp_add_browser))
        is McpReauthPhase.Prompt -> McpAuthPromptContent(
            name = session.serverName,
            nameKnown = true,
            iconUrl = session.iconUrl,
            authorizationHost = phase.authorizationHost,
            serverHost = phase.serverHost,
            onContinue = onContinue,
            onCancel = onCancel,
        )
        is McpReauthPhase.Token -> {
            var token by remember(session.serverId) { mutableStateOf("") }
            // Editing the token clears the previous error.
            var edited by remember(phase.rejected, phase.busy) { mutableStateOf(false) }
            McpSheetHeader(
                title = stringResource(R.string.mcp_reauth_token_title),
                subtitle = stringResource(R.string.mcp_add_needs_token_body),
            )
            TokenField(
                token = token,
                rejected = phase.rejected && !edited,
                onTokenChange = {
                    token = it
                    edited = true
                },
            )
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                OriveoPrimaryButton(
                    text = stringResource(R.string.save),
                    onClick = { onSubmitToken(token) },
                    enabled = token.isNotBlank() && !(phase.rejected && !edited),
                    loading = phase.busy,
                )
                McpQuietButton(text = stringResource(R.string.cancel), onClick = onCancel)
            }
        }
        is McpReauthPhase.Failed -> {
            McpNoticeBlock(
                title = stringResource(if (phase.unreachable) R.string.mcp_add_unreachable_title else R.string.mcp_reauth_failed_title),
                body = stringResource(if (phase.unreachable) R.string.mcp_reauth_unreachable_body else R.string.mcp_reauth_failed_body),
                tone = if (phase.unreachable) McpPillTone.Danger else McpPillTone.Warning,
            )
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                OriveoPrimaryButton(
                    text = stringResource(if (phase.unreachable) R.string.mcp_try_again else R.string.mcp_add_sign_in_again),
                    onClick = onRetry,
                )
                McpQuietButton(text = stringResource(R.string.cancel), onClick = onCancel)
            }
        }
    }
}

@Composable
private fun Waiting(session: McpReauthSession, text: String) {
    val serverName = session.serverName
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        McpServerIcon(name = serverName, iconUrl = session.iconUrl, size = 44.dp, serverUrl = session.serverUrl)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(text = serverName, style = OriveoTheme.typography.title3, color = colors.textPrimary, maxLines = 1)
            Text(text = text, style = OriveoTheme.typography.caption, color = colors.textSecondary)
        }
        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.primary, trackColor = colors.border)
    }
}
