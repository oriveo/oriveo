package ai.oriveo.community.feature.chat.mcp

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import ai.oriveo.community.feature.chat.ChatMcpCoordinator

/**
 * The two remote MCP bottom sheets on the chat screen: tool panel and step detail. The pre-write confirmation is not here; it is
 * hosted at the navigation root ([McpConfirmationHost]) and follows the user.
 *
 * A separate composable so that reads of [ChatMcpCoordinator] state stay inside this one recomposition scope: reading it in the
 * root body of `ChatScreenContent` would recompose the whole message list on every panel refresh.
 */
@Composable
internal fun ChatMcpSheets(
    coordinator: ChatMcpCoordinator,
    onSwitchModel: () -> Unit,
    onNavigateToMcpServers: () -> Unit,
    onNavigateToMcpAddServer: () -> Unit,
) {
    if (coordinator.showToolPanel) {
        McpToolPanelSheet(
            state = coordinator.panelState,
            onDismiss = coordinator::dismissToolPanel,
            onToggle = coordinator::setServerEnabled,
            onReauthorize = coordinator::reauthorize,
            onManageServers = {
                coordinator.dismissToolPanel()
                onNavigateToMcpServers()
            },
            onAddServer = {
                coordinator.dismissToolPanel()
                onNavigateToMcpAddServer()
            },
            onSwitchModel = {
                coordinator.dismissToolPanel()
                onSwitchModel()
            },
        )
    }

    coordinator.stepDetail?.let { detail ->
        McpStepDetailSheet(
            detail = detail,
            onDismiss = coordinator::dismissStepDetail,
            serverIconUrl = coordinator.serverIconUrl(detail.step.serverId),
            serverUrl = coordinator.serverUrl(detail.step.serverId),
        )
    }
}

/** Callbacks and transient state the step block needs, taken from [ChatMcpCoordinator]. */
@Composable
internal fun rememberMcpToolStepsHost(coordinator: ChatMcpCoordinator): McpToolStepsHost = remember(coordinator) {
    McpToolStepsHost(
        pausedStepIds = coordinator::pausedStepIds,
        limitReached = coordinator::isStepLimitReached,
        onSelectStep = coordinator::openStepDetail,
        onReauthorize = { step -> coordinator.reauthorize(step.serverId) },
        onSkipStep = { step -> coordinator.skipStep(step.id) },
    )
}
