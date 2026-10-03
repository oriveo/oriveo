package ai.oriveo.community.feature.chat.mcp

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.core.mcp.McpConfirmationCoordinator
import ai.oriveo.community.core.mcp.McpServerIconPolicy
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.PendingMcpConfirmation
import org.koin.compose.koinInject

/**
 * Host of the pre-write confirmation, mounted at the navigation root next to `McpReauthorizationHost`: **the sheet follows the user**.
 *
 * While an answer keeps running in the background the user may move to another screen or conversation; the confirmation shows up
 * wherever the user is, one at a time in proposal order, not only in "the conversation that happens to be open". Leaving the screen that started the answer is not a denial: without the user's choice the step simply keeps waiting.
 */
@Composable
fun McpConfirmationHost(
    coordinator: McpConfirmationCoordinator = koinInject(),
    store: McpServerStore = koinInject(),
) {
    val current = currentMcpConfirmation(coordinator) ?: return
    val haptics = LocalHapticFeedback.current
    // A light haptic each time a confirmation appears.
    LaunchedEffect(current.id) { haptics.performHapticFeedback(HapticFeedbackType.LongPress) }
    // Cannot be swiped away: without the user's choice the step does not run, and it must not hang unanswered either.
    McpBottomSheet(onDismiss = {}, dismissible = false) {
        McpConfirmationHostContent(current, coordinator, store)
    }
}

/** The head of the queue (in proposal order), whichever conversation it belongs to. */
@Composable
internal fun currentMcpConfirmation(coordinator: McpConfirmationCoordinator): PendingMcpConfirmation? {
    val pending by coordinator.pending.collectAsStateWithLifecycle()
    return pending.firstOrNull()
}

/** Sheet content: the user's choice goes straight back to the gate. A separate function so UI tests can render it without the sheet window. */
@Composable
internal fun ColumnScope.McpConfirmationHostContent(
    current: PendingMcpConfirmation,
    coordinator: McpConfirmationCoordinator,
    store: McpServerStore?,
) {
    // The server's own icon, subject to the icon policy; the initial tile when it cannot be loaded.
    val iconUrl by produceState<String?>(initialValue = null, current.request.serverId, store) {
        value = runCatching {
            store?.fetchServer(current.request.serverId)?.let { McpServerIconPolicy.loadable(it.iconURL, it.url) }
        }.getOrNull()
    }
    McpConfirmationContentView(
        request = current.request,
        confirmationId = current.id,
        onChoose = { choice -> coordinator.resolve(current.id, choice) },
        serverIconUrl = iconUrl,
    )
}
