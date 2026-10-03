package ai.oriveo.community.core.mcp

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

// Pausing and resuming when authorization expires mid-run: when a step in the loop hits "sign-in required again" it is
// not failed outright. The loop stops at that step and waits for the user's decision: re-authorize and continue from
// this step, or skip the step and let the answer go on.

/** The user's decision for one pause. */
enum class McpAuthPauseDecision {
    /** Re-authorized: continue from this step; earlier results are kept. */
    Resume,

    /** Skip this step: it is recorded as skipped (`auth_skipped`) and the answer continues. */
    Skip,
}

data class McpAuthPauseRequest(
    val conversationId: String,
    val serverId: String,
    val serverName: String,
    /** The step it stopped at (the step id in the message's `toolSteps`). */
    val stepId: String,
)

/**
 * Pause gate: a suspension point in the loop; time spent waiting does not count toward the call timeout. When the user
 * taps stop, the coroutine that started it is cancelled, and implementations let the cancellation propagate unchanged.
 */
fun interface McpAuthPauseGate {
    suspend fun awaitDecision(request: McpAuthPauseRequest): McpAuthPauseDecision
}

data class PendingMcpAuthPause(val id: String, val request: McpAuthPauseRequest)

/**
 * UI side of the pause gate: the step block reads [pending] to render "Re-authorize / Skip this step", and the user's
 * decision travels back to the loop through [resolve].
 */
class McpAuthPauseCoordinator : McpAuthPauseGate {
    private val lock = Any()
    private val waiters = LinkedHashMap<String, CompletableDeferred<McpAuthPauseDecision>>()
    private val _pending = MutableStateFlow<List<PendingMcpAuthPause>>(emptyList())
    val pending: StateFlow<List<PendingMcpAuthPause>> = _pending.asStateFlow()

    override suspend fun awaitDecision(request: McpAuthPauseRequest): McpAuthPauseDecision {
        val pause = PendingMcpAuthPause(UUID.randomUUID().toString(), request)
        val waiter = CompletableDeferred<McpAuthPauseDecision>()
        synchronized(lock) {
            waiters[pause.id] = waiter
            _pending.update { it + pause }
        }
        try {
            return waiter.await()
        } finally {
            remove(pause.id)
        }
    }

    fun resolve(id: String, decision: McpAuthPauseDecision) {
        remove(id)?.complete(decision)
    }

    /** The answer in this conversation was stopped: steps still paused end as cancelled (recorded as interrupted). */
    fun cancelConversation(conversationId: String) {
        _pending.value
            .filter { it.request.conversationId.equals(conversationId, ignoreCase = true) }
            .forEach { remove(it.id)?.cancel() }
    }

    private fun remove(id: String): CompletableDeferred<McpAuthPauseDecision>? = synchronized(lock) {
        val waiter = waiters.remove(id)
        _pending.update { list -> list.filterNot { it.id == id } }
        waiter
    }
}

/**
 * Re-authorizes one server (browser sign-in, or pasting a new access token). Returns true on success: the credentials
 * are updated and the connection state is restored.
 *
 * This is a UI flow (it shows the pre-sign-in prompt and opens the system browser); the server-management UI provides
 * the implementation and wires it into [McpChatToolRunner.reauthorizer]. The chat side only calls it and never opens a
 * browser itself.
 */
fun interface McpReauthorizer {
    suspend fun reauthorize(serverId: String): Boolean
}

/**
 * Placeholder for when no re-authorization entry point is available yet: does nothing, the pause stays, and the user
 * can still skip the step.
 */
object McpUnavailableReauthorizer : McpReauthorizer {
    override suspend fun reauthorize(serverId: String): Boolean = false
}
