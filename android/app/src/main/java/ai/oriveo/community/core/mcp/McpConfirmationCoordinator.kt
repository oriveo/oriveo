package ai.oriveo.community.core.mcp

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** A confirmation waiting for the user's decision. */
data class PendingMcpConfirmation(val id: String, val request: McpConfirmationRequest)

/**
 * The UI side of the confirmation gate: the loop's `execute` suspends here, and the confirmation dialog reads the head of
 * the queue and sends the user's choice back.
 *
 * - One at a time: the queue follows proposal order and the dialog only ever presents its head.
 * - No timeout: waiting does not count towards the call timeout and the dialog stays while the app is in the background;
 *   if the process is killed, that step is shown as interrupted next time.
 * - When the user taps stop (the send coroutine is cancelled) the wait is cancelled with it, the entry leaves the queue
 *   and the whole loop winds down.
 * - The dialog host is attached to the navigation root, so it is visible on any screen and in any conversation; while the
 *   host is absent (the UI is not up yet) entries stay queued. Waiting is preferred over approving or denying on the
 *   user's behalf.
 */
class McpConfirmationCoordinator : McpConfirmationGate {
    private val lock = Any()
    private val waiters = LinkedHashMap<String, CompletableDeferred<McpConfirmationChoice>>()
    private val _pending = MutableStateFlow<List<PendingMcpConfirmation>>(emptyList())
    val pending: StateFlow<List<PendingMcpConfirmation>> = _pending.asStateFlow()

    override suspend fun requestConfirmation(request: McpConfirmationRequest): McpConfirmationChoice {
        val confirmation = PendingMcpConfirmation(UUID.randomUUID().toString(), request)
        val waiter = CompletableDeferred<McpConfirmationChoice>()
        synchronized(lock) {
            waiters[confirmation.id] = waiter
            _pending.update { it + confirmation }
        }
        try {
            return waiter.await()
        } finally {
            remove(confirmation.id)
        }
    }

    /** The user made a choice in the dialog. */
    fun resolve(id: String, choice: McpConfirmationChoice) {
        remove(id)?.complete(choice)
    }

    /** This conversation's answer was stopped or finished: confirmations still waiting are all wound down as cancelled. */
    fun cancelConversation(conversationId: String) {
        _pending.value
            .filter { it.request.conversationId.equals(conversationId, ignoreCase = true) }
            .forEach { remove(it.id)?.cancel() }
    }

    fun cancelAll() {
        _pending.value.forEach { remove(it.id)?.cancel() }
    }

    private fun remove(id: String): CompletableDeferred<McpConfirmationChoice>? = synchronized(lock) {
        val waiter = waiters.remove(id)
        _pending.update { list -> list.filterNot { it.id == id } }
        waiter
    }
}
