package ai.oriveo.community.feature.mcp

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpInvalidUrlReason
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.mcp.McpToolSnapshot
import ai.oriveo.community.feature.chat.mcp.McpBottomSheet
import ai.oriveo.community.feature.chat.mcp.McpCard
import ai.oriveo.community.feature.chat.mcp.McpFootnote
import ai.oriveo.community.feature.chat.mcp.McpHairline
import ai.oriveo.community.feature.chat.mcp.McpQuietButton
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

/** User actions on the add screen. The UI only draws and forwards; all state lives in [McpAddServerFlow]. */
internal class McpAddActions(
    val onBack: () -> Unit,
    val onUrlChange: (String) -> Unit = {},
    val onNameChange: (String) -> Unit = {},
    val onTokenChange: (String) -> Unit = {},
    val onConnect: () -> Unit = {},
    val onCancel: () -> Unit = {},
    val onApproveSignIn: () -> Unit = {},
    val onRetry: () -> Unit = {},
    val onEditAddress: () -> Unit = {},
    val onConnectWithToken: () -> Unit = {},
    val onReadOnlyPermission: (McpToolPermission) -> Unit = {},
    val onChangesPermission: (McpToolPermission) -> Unit = {},
    val onFinish: () -> Unit = {},
    val onLeave: () -> Unit = {},
)

/**
 * Add a server. [onDone] is called with the new server's id after the user taps "Done"; [onBack] means leaving without adding one.
 */
@Composable
fun McpAddServerScreen(
    onBack: () -> Unit,
    onDone: (serverId: String) -> Unit,
    viewModel: McpAddServerViewModel = koinViewModel(),
) {
    val flow = viewModel.flow
    val state by flow.state.collectAsStateWithLifecycle()

    LaunchedEffect(state.completedServerId) {
        state.completedServerId?.let(onDone)
    }

    val leave = {
        flow.close()
        onBack()
    }
    // System back: "connecting" = cancel; "confirm permissions" = abandon the add (nothing saved); failure page = back to the form.
    val back: () -> Unit = {
        when (state.screen) {
            is McpAddScreen.Progress -> flow.cancel()
            is McpAddScreen.Failure -> flow.editAddress()
            McpAddScreen.Form, is McpAddScreen.Review -> leave()
        }
    }
    BackHandler(onBack = back)

    McpAddServerContent(
        state = state,
        actions = McpAddActions(
            onBack = back,
            onUrlChange = flow::updateUrl,
            onNameChange = flow::updateName,
            onTokenChange = flow::updateToken,
            onConnect = flow::connect,
            onCancel = flow::cancel,
            onApproveSignIn = flow::approveSignIn,
            onRetry = flow::retry,
            onEditAddress = flow::editAddress,
            onConnectWithToken = flow::connectWithToken,
            onReadOnlyPermission = flow::setReadOnlyPermission,
            onChangesPermission = flow::setChangesPermission,
            onFinish = flow::finish,
            onLeave = leave,
        ),
    )

    val screen = state.screen
    if (screen is McpAddScreen.Progress && screen.stage == McpAddStage.AuthPrompt) {
        McpAuthPromptSheet(
            name = state.displayName,
            nameKnown = state.name.isNotBlank(),
            authorizationHost = screen.authorizationHost.orEmpty(),
            serverHost = state.host,
            onContinue = flow::approveSignIn,
            onCancel = flow::cancel,
        )
    }
}

@Composable
internal fun McpAddServerContent(state: McpAddUiState, actions: McpAddActions) {
    when (val screen = state.screen) {
        McpAddScreen.Form -> FormPage(state, actions)
        is McpAddScreen.Progress -> ProgressPage(state, screen, actions)
        is McpAddScreen.Review -> ReviewPage(state, screen, actions)
        is McpAddScreen.Failure -> FailurePage(state, screen, actions)
    }
}

// ── Address form (including the bad-address state) ─────────

@Composable
private fun FormPage(state: McpAddUiState, actions: McpAddActions) {
    val colors = OriveoTheme.colors
    McpPageScaffold(
        title = stringResource(R.string.mcp_add_server),
        onBack = actions.onBack,
        bottomBar = {
            OriveoPrimaryButton(
                text = stringResource(R.string.mcp_add_connect),
                onClick = actions.onConnect,
                enabled = state.canConnect,
            )
        },
    ) {
        Column(modifier = Modifier.padding(horizontal = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = stringResource(R.string.mcp_add_server),
                style = OriveoTheme.typography.hero.copy(fontSize = 26.sp, lineHeight = 32.sp, fontWeight = FontWeight.ExtraBold),
                color = colors.textPrimary,
                modifier = Modifier.semantics { heading() },
            )
            Text(text = stringResource(R.string.mcp_add_subtitle), style = OriveoTheme.typography.body, color = colors.textSecondary)
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            McpFieldLabel(stringResource(R.string.mcp_add_address))
            McpTextField(
                value = state.url,
                onValueChange = actions.onUrlChange,
                label = stringResource(R.string.mcp_add_address),
                placeholder = stringResource(R.string.mcp_add_address_placeholder),
                errorText = state.urlError?.let { mcpInvalidUrlText(it) },
                monospace = true,
                keyboardType = KeyboardType.Uri,
            )
            if (state.urlError == null) McpFootnote(stringResource(R.string.mcp_add_address_hint))
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            McpFieldLabel(stringResource(R.string.mcp_add_name))
            McpTextField(
                value = state.name,
                onValueChange = actions.onNameChange,
                label = stringResource(R.string.mcp_add_name),
                placeholder = stringResource(R.string.mcp_add_name_placeholder),
            )
        }

        // The form has only address and name: the sign-in method is decided by probing rather than picked up front, and the access
        // token field appears only at the "access token required" step.
        McpFootnote(stringResource(R.string.mcp_add_sign_in_note))
    }
}

@Composable
internal fun mcpInvalidUrlText(reason: McpInvalidUrlReason): String = stringResource(
    when (reason) {
        McpInvalidUrlReason.Malformed -> R.string.mcp_add_error_url
        McpInvalidUrlReason.HasUserinfo -> R.string.mcp_add_error_url_userinfo
    },
)

/** Token field (shared by "access token required" and re-authorization). Uses the form's error style when the server rejects the token. */
@Composable
internal fun TokenField(token: String, rejected: Boolean, onTokenChange: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        McpTextField(
            value = token,
            onValueChange = onTokenChange,
            label = stringResource(R.string.mcp_access_token),
            placeholder = stringResource(R.string.mcp_add_token_placeholder),
            errorText = if (rejected) stringResource(R.string.mcp_add_token_rejected) else null,
            secure = true,
            keyboardType = KeyboardType.Password,
        )
        if (!rejected) McpFootnote(stringResource(R.string.mcp_add_token_note))
    }
}

// ── Progress pages ──────────────────────────────────────────

@Composable
private fun ProgressPage(state: McpAddUiState, screen: McpAddScreen.Progress, actions: McpAddActions) {
    val name = state.displayName
    val caption = stringResource(
        when (screen.stage) {
            McpAddStage.Connecting -> R.string.mcp_add_connecting
            McpAddStage.AuthPrompt -> R.string.mcp_add_needs_sign_in
            McpAddStage.Browser -> R.string.mcp_add_browser
            McpAddStage.Finishing -> R.string.mcp_add_finishing
        },
    )
    val signInRow = when (screen.stage) {
        McpAddStage.Connecting -> McpChecklistRow(stringResource(R.string.mcp_add_step_checking), McpChecklistState.Active)
        McpAddStage.AuthPrompt -> McpChecklistRow(
            stringResource(R.string.mcp_add_step_checking),
            McpChecklistState.Done,
            detail = stringResource(R.string.mcp_add_step_sign_in_needed, name),
        )
        McpAddStage.Browser -> McpChecklistRow(stringResource(R.string.mcp_add_step_sign_in_needed, name), McpChecklistState.Active)
        McpAddStage.Finishing -> McpChecklistRow(
            if (screen.signedIn) stringResource(R.string.mcp_add_step_signed_in, name) else stringResource(R.string.mcp_add_step_checking),
            McpChecklistState.Done,
        )
    }
    McpPageScaffold(
        title = stringResource(R.string.mcp_add_server),
        onBack = actions.onBack,
        bottomBar = {
            McpQuietButton(text = stringResource(R.string.cancel), onClick = actions.onCancel)
        },
    ) {
        McpHeroCard(name = name, serverUrl = state.url, nameKnown = state.name.isNotBlank(), caption = caption)
        McpChecklistCard(
            rows = listOf(
                McpChecklistRow(stringResource(R.string.mcp_add_step_found), McpChecklistState.Done),
                signInRow,
                McpChecklistRow(
                    stringResource(R.string.mcp_add_step_reading_tools),
                    if (screen.stage == McpAddStage.Finishing) McpChecklistState.Active else McpChecklistState.Waiting,
                ),
            ),
        )
    }
}

/**
 * Pre-sign-in notice. **Must show the host name of the sign-in page**; the client is registered and the browser opened only after "Continue".
 * Shared by the add flow and re-authorization of saved servers.
 */
@Composable
internal fun McpAuthPromptSheet(
    name: String,
    nameKnown: Boolean,
    authorizationHost: String,
    serverHost: String,
    onContinue: () -> Unit,
    onCancel: () -> Unit,
    busy: Boolean = false,
) {
    McpBottomSheet(onDismiss = onCancel) {
        McpAuthPromptContent(name, nameKnown, authorizationHost, serverHost, onContinue, onCancel, busy)
    }
}

@Composable
internal fun ColumnScope.McpAuthPromptContent(
    name: String,
    nameKnown: Boolean,
    authorizationHost: String,
    serverHost: String,
    onContinue: () -> Unit,
    onCancel: () -> Unit,
    busy: Boolean = false,
    iconUrl: String? = null,
) {
    val colors = OriveoTheme.colors
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(horizontal = 4.dp)) {
        McpHeroIcon(name = name, nameKnown = nameKnown, size = 44.dp, iconUrl = iconUrl, serverUrl = "https://" + serverHost)
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                text = stringResource(R.string.mcp_auth_prompt_title, name),
                style = OriveoTheme.typography.title1.copy(fontSize = 20.sp, lineHeight = 26.sp),
                color = colors.textPrimary,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = stringResource(R.string.mcp_auth_prompt_body, name),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
        }
    }
    McpCard(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
        HostRow(label = stringResource(R.string.mcp_auth_prompt_sign_in_page), host = authorizationHost, secure = true)
        McpHairline()
        HostRow(label = stringResource(R.string.mcp_auth_prompt_connects_to), host = serverHost, secure = false)
    }
    McpFootnote(stringResource(R.string.mcp_auth_prompt_hint))
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        OriveoPrimaryButton(
            text = stringResource(R.string.mcp_continue),
            onClick = onContinue,
            loading = busy,
        )
        McpQuietButton(text = stringResource(R.string.cancel), onClick = onCancel)
    }
}

@Composable
private fun HostRow(label: String, host: String, secure: Boolean) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(vertical = 10.dp).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.caption,
            color = colors.textTertiary,
            modifier = Modifier.heightIn().padding(end = 4.dp),
        )
        if (secure) Icon(Icons.Outlined.Lock, contentDescription = null, modifier = Modifier.size(14.dp), tint = colors.success)
        Text(
            text = host,
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.MiddleEllipsis,
        )
    }
}

// ── Confirm default permissions ─────────────────────────────

@Composable
private fun ReviewPage(state: McpAddUiState, screen: McpAddScreen.Review, actions: McpAddActions) {
    McpPageScaffold(
        title = stringResource(R.string.mcp_add_server),
        onBack = actions.onBack,
        bottomBar = {
            OriveoPrimaryButton(
                text = stringResource(R.string.done),
                onClick = actions.onFinish,
                loading = screen.saving,
            )
        },
    ) {
        McpHeroCard(
            name = state.displayName,
            iconUrl = state.serverIconUrl,
            serverUrl = state.url,
            status = { McpStatusPill(stringResource(R.string.mcp_status_connected), McpPillTone.Success) },
            caption = pluralStringResource(R.plurals.mcp_panel_tool_count, screen.tools.size, screen.tools.size),
        )
        if (screen.tools.isEmpty()) {
            // The server offers no tools: the permission card becomes a one-line note, and the primary button is still "Done".
            McpFootnote(stringResource(R.string.mcp_no_tools), color = OriveoTheme.colors.textSecondary)
        } else {
            McpSectionTitle(stringResource(R.string.mcp_add_default_permissions))
            McpCard(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
                val groups = buildList {
                    if (screen.readOnlyTools.isNotEmpty()) {
                        add(Triple(R.string.mcp_group_read_only, screen.readOnlyTools, true))
                    }
                    if (screen.changingTools.isNotEmpty()) {
                        add(Triple(R.string.mcp_group_changes_data, screen.changingTools, false))
                    }
                }
                groups.forEachIndexed { index, (title, tools, readOnly) ->
                    if (index > 0) McpHairline()
                    PermissionGroupRow(
                        title = stringResource(title),
                        tools = tools,
                        permission = if (readOnly) screen.readOnlyPermission else screen.changesPermission,
                        onSelect = if (readOnly) actions.onReadOnlyPermission else actions.onChangesPermission,
                    )
                }
            }
            McpFootnote(stringResource(R.string.mcp_add_review_note))
        }
    }
}

@Composable
internal fun mcpPermissionText(permission: McpToolPermission): String = stringResource(
    when (permission) {
        McpToolPermission.Auto -> R.string.mcp_permission_auto
        McpToolPermission.Ask -> R.string.mcp_permission_ask
        McpToolPermission.Off -> R.string.mcp_permission_off
    },
)

/** Default permission for a group of tools: group name and the first 3 tool titles (verbatim from the server) on the left, a three-option menu on the right. */
@Composable
private fun PermissionGroupRow(
    title: String,
    tools: List<McpToolSnapshot>,
    permission: McpToolPermission,
    onSelect: (McpToolPermission) -> Unit,
) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 62.dp).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(text = title, style = OriveoTheme.typography.body, color = colors.textPrimary)
            Text(
                text = stringResource(R.string.mcp_add_group_summary, tools.take(3).joinToString(" · ") { it.title }, tools.size),
                style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp),
                color = colors.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box {
            Row(
                modifier = Modifier
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .clickable(role = Role.DropdownList) { expanded = true }
                    .padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(text = mcpPermissionText(permission), style = OriveoTheme.typography.body.copy(fontSize = 15.sp), color = colors.textSecondary)
                Icon(Icons.Outlined.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp), tint = colors.textTertiary)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, containerColor = colors.surface) {
                McpToolPermission.entries.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(mcpPermissionText(option), style = OriveoTheme.typography.body, color = colors.textPrimary) },
                        onClick = {
                            expanded = false
                            onSelect(option)
                        },
                    )
                }
            }
        }
    }
}

// ── Failure pages, plus "limit reached" and "could not save" ─

@Composable
private fun FailurePage(state: McpAddUiState, screen: McpAddScreen.Failure, actions: McpAddActions) {
    val name = state.displayName
    val nameKnown = state.name.isNotBlank()
    McpPageScaffold(
        title = stringResource(R.string.mcp_add_server),
        onBack = actions.onBack,
        bottomBar = { FailureActions(state, screen, actions) },
    ) {
        when (screen.kind) {
            McpAddFailure.Unreachable -> {
                McpHeroCard(name, serverUrl = state.url, nameKnown = nameKnown, status = { McpStatusPill(stringResource(R.string.mcp_panel_cant_connect), McpPillTone.Danger) })
                McpNoticeBlock(
                    title = stringResource(R.string.mcp_add_unreachable_title),
                    body = stringResource(R.string.mcp_add_unreachable_body),
                    tone = McpPillTone.Danger,
                )
            }
            McpAddFailure.NotMcp -> {
                McpHeroCard(name, serverUrl = state.url, nameKnown = nameKnown, status = { McpStatusPill(stringResource(R.string.mcp_add_not_mcp_status), McpPillTone.Warning) })
                McpNoticeBlock(
                    title = stringResource(R.string.mcp_add_not_mcp_title),
                    body = stringResource(R.string.mcp_add_not_mcp_body),
                    tone = McpPillTone.Warning,
                )
            }
            McpAddFailure.NeedsToken -> {
                McpHeroCard(name, serverUrl = state.url, nameKnown = nameKnown, status = { McpStatusPill(stringResource(R.string.mcp_add_needs_token_status), McpPillTone.Warning) })
                McpNoticeBlock(
                    title = stringResource(R.string.mcp_add_needs_token_title),
                    body = stringResource(R.string.mcp_add_needs_token_body),
                    tone = McpPillTone.Warning,
                )
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    McpFieldLabel(stringResource(R.string.mcp_access_token))
                    TokenField(token = state.token, rejected = screen.tokenRejected, onTokenChange = actions.onTokenChange)
                }
            }
            McpAddFailure.AuthCancelled -> {
                McpHeroCard(name, serverUrl = state.url, nameKnown = nameKnown, status = { McpStatusPill(stringResource(R.string.mcp_add_auth_cancelled_status), McpPillTone.Warning) })
                McpNoticeBlock(
                    title = stringResource(R.string.mcp_add_auth_cancelled_title),
                    body = stringResource(R.string.mcp_add_auth_cancelled_body),
                    tone = McpPillTone.Warning,
                )
            }
            McpAddFailure.LimitReached -> {
                McpHeroCard(name, serverUrl = state.url, nameKnown = nameKnown, status = { McpStatusPill(stringResource(R.string.mcp_add_limit_status), McpPillTone.Warning) })
                McpNoticeBlock(
                    title = stringResource(R.string.mcp_add_limit_title),
                    body = pluralStringResource(R.plurals.mcp_add_limit_body, screen.max, screen.max),
                    tone = McpPillTone.Warning,
                )
            }
            McpAddFailure.SaveFailed -> {
                McpHeroCard(name, serverUrl = state.url, nameKnown = nameKnown, status = { McpStatusPill(stringResource(R.string.mcp_add_save_failed_status), McpPillTone.Danger) })
                McpNoticeBlock(
                    title = stringResource(R.string.mcp_add_save_failed_title),
                    body = stringResource(R.string.mcp_add_save_failed_body),
                    tone = McpPillTone.Danger,
                )
            }
        }
    }
}

@Composable
private fun ColumnScope.FailureActions(state: McpAddUiState, screen: McpAddScreen.Failure, actions: McpAddActions) {
    when (screen.kind) {
        McpAddFailure.Unreachable, McpAddFailure.SaveFailed -> {
            OriveoPrimaryButton(
                text = stringResource(R.string.mcp_try_again),
                onClick = actions.onRetry,
            )
            McpQuietButton(stringResource(R.string.mcp_add_edit_address), actions.onEditAddress)
        }
        McpAddFailure.NotMcp ->
            OriveoPrimaryButton(
                text = stringResource(R.string.mcp_add_edit_address),
                onClick = actions.onEditAddress,
            )
        McpAddFailure.NeedsToken ->
            OriveoPrimaryButton(
                text = stringResource(R.string.mcp_add_connect),
                onClick = actions.onConnectWithToken,
                enabled = state.token.isNotBlank() && !screen.tokenRejected,
            )
        McpAddFailure.AuthCancelled -> {
            OriveoPrimaryButton(
                text = stringResource(R.string.mcp_add_sign_in_again),
                onClick = actions.onRetry,
            )
            McpQuietButton(stringResource(R.string.cancel), actions.onLeave)
        }
        McpAddFailure.LimitReached ->
            McpQuietButton(stringResource(R.string.close), actions.onLeave)
    }
}
