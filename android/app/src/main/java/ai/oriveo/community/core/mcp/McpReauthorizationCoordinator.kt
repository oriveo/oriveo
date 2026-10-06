package ai.oriveo.community.core.mcp

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

// Re-authorization of an already saved server: the production implementation of `McpReauthorizer`. The chat
// screen's tool panel and step blocks and the management screen's detail page all call it. It draws no UI itself;
// it only publishes "what the user must be asked now" on [session], and a dialog hosted at the navigation root
// presents it.

/** How far the re-authorization has progressed. */
sealed interface McpReauthPhase {
    /** Reading metadata only to work out how to sign in (no client registration, no browser). */
    data object Checking : McpReauthPhase

    /** Pre-sign-in notice: shows the sign-in page's host; the client is registered and the browser opened only after the user taps Continue. */
    data class Prompt(val authorizationHost: String, val serverHost: String) : McpReauthPhase

    /** Signing in inside the system browser. */
    data object Browser : McpReauthPhase

    /** This server uses an access token (or does not support automatic sign-in): ask the user to paste a new one. */
    data class Token(val rejected: Boolean = false, val busy: Boolean = false) : McpReauthPhase

    /** Did not succeed. [unreachable]: the server could not be reached, as opposed to the sign-in being refused. Can be retried. */
    data class Failed(val unreachable: Boolean) : McpReauthPhase
}

data class McpReauthSession(
    val serverId: String,
    val serverName: String,
    val phase: McpReauthPhase,
    /** The server's own icon, already vetted by [McpServerIconPolicy]. */
    val iconUrl: String? = null,
    val serverUrl: String? = null,
)

class McpReauthorizationCoordinator(
    private val actions: McpServerActions,
    private val store: McpServerStore,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : McpReauthorizer {
    private val _session = MutableStateFlow<McpReauthSession?>(null)

    /** The re-authorization in progress; null when there is none. */
    val session: StateFlow<McpReauthSession?> = _session.asStateFlow()

    private sealed interface Decision {
        data object Approve : Decision
        data object Retry : Decision
        data object Cancel : Decision
        data class SubmitToken(val token: String) : Decision
    }

    /** Only one runs at a time: when two places trigger re-authorization at once, the later one waits for the earlier one to finish. */
    private val mutex = Mutex()

    @Volatile private var decisions: Channel<Decision> = Channel(Channel.CONFLATED)

    /**
     * Re-authorizes one server. Returns true on success: credentials are updated, the connection state is back to
     * connected, and the tool catalog has been refreshed along the way.
     * Returns false when the user cancels, gives up after a failure, or the server has been removed. If the calling
     * coroutine is cancelled, the dialog is dismissed with it.
     */
    override suspend fun reauthorize(serverId: String): Boolean = mutex.withLock {
        withContext(dispatcher) {
            try {
                run(serverId)
            } finally {
                _session.value = null
            }
        }
    }

    private suspend fun run(serverId: String): Boolean {
        val record = store.fetchServer(serverId) ?: return false
        val iconUrl = McpServerIconPolicy.loadable(record.iconURL, record.url)
        fun show(phase: McpReauthPhase) {
            _session.value = McpReauthSession(serverId, record.name, phase, iconUrl, record.url)
        }
        // A step that needs the user's answer: swap in a fresh reply channel before publishing the page, so a tap
        // is not lost just because this coroutine has not reached the receive yet.
        suspend fun ask(phase: McpReauthPhase): Decision {
            decisions = Channel(Channel.CONFLATED)
            show(phase)
            return decisions.receive()
        }
        while (true) {
            show(McpReauthPhase.Checking)
            when (val preparation = actions.prepareReauthorization(serverId)) {
                McpReauthPreparation.Connected -> return true
                McpReauthPreparation.Gone, McpReauthPreparation.NeedsAddress -> return false
                McpReauthPreparation.Unreachable -> {
                    if (ask(McpReauthPhase.Failed(unreachable = true)) != Decision.Retry) return false
                }
                McpReauthPreparation.NeedsToken -> {
                    var rejected = false
                    while (true) {
                        val decision = ask(McpReauthPhase.Token(rejected = rejected))
                        if (decision !is Decision.SubmitToken) return false
                        show(McpReauthPhase.Token(busy = true))
                        when (actions.submitAccessToken(serverId, decision.token)) {
                            McpTokenSubmission.Connected -> return true
                            McpTokenSubmission.Gone -> return false
                            McpTokenSubmission.Rejected -> rejected = true
                            McpTokenSubmission.Unreachable -> {
                                if (ask(McpReauthPhase.Failed(unreachable = true)) != Decision.Retry) return false
                                rejected = false
                            }
                        }
                    }
                }
                is McpReauthPreparation.Ready -> {
                    val decision = ask(McpReauthPhase.Prompt(preparation.authorizationHost, preparation.serverHost))
                    if (decision != Decision.Approve) return false
                    show(McpReauthPhase.Browser)
                    when (actions.completeReauthorization(serverId, preparation.plan)) {
                        McpReauthOutcome.Connected -> return true
                        McpReauthOutcome.Gone -> return false
                        McpReauthOutcome.Cancelled, McpReauthOutcome.Failed ->
                            if (ask(McpReauthPhase.Failed(unreachable = false)) != Decision.Retry) return false
                        McpReauthOutcome.Unreachable ->
                            if (ask(McpReauthPhase.Failed(unreachable = true)) != Decision.Retry) return false
                    }
                }
            }
        }
    }

    // ── UI side ───────────────────────────────────────────

    /** Continue on the pre-sign-in notice. */
    fun approve() {
        if (_session.value?.phase is McpReauthPhase.Prompt) decisions.trySend(Decision.Approve)
    }

    /** Retry on the failure page. */
    fun retry() {
        if (_session.value?.phase is McpReauthPhase.Failed) decisions.trySend(Decision.Retry)
    }

    fun submitToken(token: String) {
        val phase = _session.value?.phase as? McpReauthPhase.Token ?: return
        if (!phase.busy) decisions.trySend(Decision.SubmitToken(token))
    }

    /** Cancel / dismiss the dialog. Does not interrupt while checking, signing in inside the browser or submitting a token (that step asks again or ends on its own when it finishes). */
    fun cancel() {
        when (val phase = _session.value?.phase) {
            is McpReauthPhase.Prompt, is McpReauthPhase.Failed -> decisions.trySend(Decision.Cancel)
            is McpReauthPhase.Token -> if (!phase.busy) decisions.trySend(Decision.Cancel)
            McpReauthPhase.Checking, McpReauthPhase.Browser, null -> Unit
        }
    }
}
