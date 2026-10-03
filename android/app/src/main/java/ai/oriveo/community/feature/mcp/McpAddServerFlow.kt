package ai.oriveo.community.feature.mcp

import ai.oriveo.community.core.mcp.McpAddCoordinator
import ai.oriveo.community.core.mcp.McpAddState
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpEndpoint
import ai.oriveo.community.core.mcp.McpEndpointCheck
import ai.oriveo.community.core.mcp.McpInvalidUrlReason
import ai.oriveo.community.core.mcp.McpOrigin
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.mcp.McpToolSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// UI state of the add-server flow, turning the `McpAddCoordinator` state machine into "which page to draw now".
//
// Probing, sign-in and persistence all live in `McpAddCoordinator`; this does three things only: collect the form, map progress / terminal
// states to pages, and release the tools or abandon the add at the "confirm default permissions" step. No failed terminal state leaves a record behind (guaranteed by the coordinator).

/** Which step the progress page is on. */
enum class McpAddStage { Connecting, AuthPrompt, Browser, Finishing }

/** Kinds of failure page (including "limit reached" and "could not save"). */
enum class McpAddFailure { Unreachable, NotMcp, NeedsToken, AuthCancelled, LimitReached, SaveFailed }

sealed interface McpAddScreen {
    /** Address form (a bad address or a token error also stays on this page). */
    data object Form : McpAddScreen

    data class Progress(
        val stage: McpAddStage,
        /** Host name of the sign-in page (the pre-sign-in notice must show it). */
        val authorizationHost: String? = null,
        /** Already signed in through the browser (the second checklist row reads "Signed in"). */
        val signedIn: Boolean = false,
    ) : McpAddScreen

    /**
     * Connected; confirm default permissions. The record is already persisted, but flagged "pending confirmation" with all tools
     * quarantined: only "Done" releases them.
     */
    data class Review(
        val serverId: String,
        val tools: List<McpToolSnapshot>,
        val readOnlyPermission: McpToolPermission = McpToolPermission.Auto,
        val changesPermission: McpToolPermission = McpToolPermission.Ask,
        val saving: Boolean = false,
    ) : McpAddScreen {
        val readOnlyTools: List<McpToolSnapshot> get() = tools.filter { it.readOnly }
        val changingTools: List<McpToolSnapshot> get() = tools.filterNot { it.readOnly }
    }

    data class Failure(
        val kind: McpAddFailure,
        /** The limit from [McpAddFailure.LimitReached]. */
        val max: Int = 0,
        /** [McpAddFailure.NeedsToken]: the server rejected the token just pasted. */
        val tokenRejected: Boolean = false,
    ) : McpAddScreen
}

data class McpAddUiState(
    val url: String = "",
    val name: String = "",
    /** Decided by probing, not chosen by the user: `Token` only after a token was pasted on the "access token required" page. */
    val authKind: McpAuthKind = McpAuthKind.Auto,
    val token: String = "",
    val urlError: McpInvalidUrlReason? = null,
    val screen: McpAddScreen = McpAddScreen.Form,
    /** The name the server reports (known only once connected). */
    val serverName: String? = null,
    /** The icon the server reports (known only once connected; already through the icon policy). */
    val serverIconUrl: String? = null,
    /** Server id after "Done": the UI leaves the add screen on it. */
    val completedServerId: String? = null,
) {
    /** Name on the hero card and the pre-sign-in notice: user-entered → server-reported → host name (the host name stands in while the name is unknown). */
    val displayName: String
        get() = name.trim().ifEmpty { serverName?.trim().orEmpty() }.ifEmpty { host }

    val host: String get() = McpOrigin.parse(url.trim())?.host.orEmpty().ifEmpty { url.trim() }

    val canConnect: Boolean
        get() = url.isNotBlank() && urlError == null
}

class McpAddServerFlow(
    private val scope: CoroutineScope,
    private val coordinator: McpAddCoordinator,
    private val store: McpServerStore,
    /** Cleanup for an abandoned add runs here: the page is already gone, so it must not be cancelled along with the page's scope. */
    private val cleanupScope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val _state = MutableStateFlow(McpAddUiState())
    val state: StateFlow<McpAddUiState> = _state.asStateFlow()

    private var job: Job? = null

    /** Connection attempt counter. After a cancel or restart, callbacks still in flight from the previous attempt no longer change the page. */
    private val runId = java.util.concurrent.atomic.AtomicInteger(0)

    /**
     * The answer to this attempt's pre-sign-in notice. A fresh one per attempt, existing before the page switches to the notice, so a tap
     * is never lost because the state machine has not reached the awaiting line yet.
     */
    @Volatile private var approval = CompletableDeferred<Boolean>()

    // ── Form ───────────────────────────────────────────────

    fun updateUrl(value: String) = _state.update { it.copy(url = value, urlError = null) }

    fun updateName(value: String) = _state.update { it.copy(name = value) }

    fun updateToken(value: String) = _state.update { current ->
        val screen = current.screen
        current.copy(
            token = value,
            screen = if (screen is McpAddScreen.Failure) screen.copy(tokenRejected = false) else screen,
        )
    }

    // ── Connect ────────────────────────────────────────────

    /** "Connect" on the form: probes from scratch without credentials; the sign-in method is decided by the probe. */
    fun connect() {
        _state.update { it.copy(authKind = McpAuthKind.Auto) }
        start()
    }

    /** "Retry" / "Sign in again": runs again with the same input. */
    fun retry() = start()

    /** "Connect" after pasting a token on the "access token required" page. */
    fun connectWithToken() {
        _state.update { it.copy(authKind = McpAuthKind.Token) }
        start()
    }

    /** "Edit address": back to the form with everything entered kept. */
    fun editAddress() = _state.update { it.copy(screen = McpAddScreen.Form) }

    private fun start() {
        if (job?.isActive == true) return
        val input = _state.value
        // Bad address: stay on the form with an error under the field, sending no request.
        val checked = McpEndpoint.check(input.url)
        if (checked is McpEndpointCheck.Invalid) {
            _state.update { it.copy(urlError = checked.reason, screen = McpAddScreen.Form) }
            return
        }
        val url = (checked as McpEndpointCheck.Valid).url
        _state.update { it.copy(screen = McpAddScreen.Progress(McpAddStage.Connecting), serverName = null) }
        val run = runId.incrementAndGet()
        approval = CompletableDeferred()
        job = scope.launch(dispatcher) {
            var usedBrowser = false
            fun show(screen: McpAddScreen) {
                if (runId.get() == run) _state.update { it.copy(screen = screen) }
            }
            val terminal = coordinator.add(
                urlString = url,
                authKind = input.authKind,
                name = input.name,
                token = input.token.trim().takeIf { input.authKind == McpAuthKind.Token && it.isNotEmpty() },
                confirmAuthorization = { awaitApproval() },
                progress = { progress ->
                    when (progress) {
                        McpAddState.Connecting -> show(McpAddScreen.Progress(McpAddStage.Connecting))
                        is McpAddState.AuthPrompt ->
                            show(McpAddScreen.Progress(McpAddStage.AuthPrompt, authorizationHost = progress.authorizationHost))
                        McpAddState.Browser -> {
                            usedBrowser = true
                            show(McpAddScreen.Progress(McpAddStage.Browser))
                        }
                        McpAddState.Finishing -> show(McpAddScreen.Progress(McpAddStage.Finishing, signedIn = usedBrowser))
                        else -> Unit
                    }
                },
            )
            if (!isActive || runId.get() != run) {
                // The page is already gone: even a successful add must not quietly leave a server behind.
                if (terminal is McpAddState.Review) withContext(NonCancellable) { remove(terminal.review.serverId) }
                return@launch
            }
            finishWith(terminal)
        }
    }

    private fun finishWith(terminal: McpAddState) {
        _state.update { current ->
            when (terminal) {
                is McpAddState.Review -> current.copy(
                    serverName = terminal.review.session.serverName,
                    serverIconUrl = terminal.review.session.serverIconUrl,
                    screen = McpAddScreen.Review(
                        serverId = terminal.review.serverId,
                        tools = terminal.review.tools,
                    ),
                )
                is McpAddState.InvalidUrl -> current.copy(urlError = terminal.reason, screen = McpAddScreen.Form)
                // The token is only entered on the "access token required" page: when the server rejects it, stay there with an error under the field.
                McpAddState.TokenRejected -> current.copy(screen = McpAddScreen.Failure(McpAddFailure.NeedsToken, tokenRejected = true))
                McpAddState.Unreachable -> current.copy(screen = McpAddScreen.Failure(McpAddFailure.Unreachable))
                McpAddState.NotMcp -> current.copy(screen = McpAddScreen.Failure(McpAddFailure.NotMcp))
                McpAddState.NeedsToken -> current.copy(screen = McpAddScreen.Failure(McpAddFailure.NeedsToken))
                McpAddState.AuthCancelled -> current.copy(screen = McpAddScreen.Failure(McpAddFailure.AuthCancelled))
                is McpAddState.LimitReached -> current.copy(screen = McpAddScreen.Failure(McpAddFailure.LimitReached, max = terminal.max))
                McpAddState.SaveFailed -> current.copy(screen = McpAddScreen.Failure(McpAddFailure.SaveFailed))
                // User cancelled: back to the form with the input kept.
                McpAddState.Cancelled -> current.copy(screen = McpAddScreen.Form)
                McpAddState.Connecting, is McpAddState.AuthPrompt, McpAddState.Browser, McpAddState.Finishing -> current
            }
        }
    }

    // ── Pre-sign-in notice ─────────────────────────────────

    /** The state machine waits here for the user's decision; no client registration and no browser before consent. */
    private suspend fun awaitApproval(): Boolean = approval.await()

    /** "Continue": registers the client and opens the system browser. */
    fun approveSignIn() {
        val screen = _state.value.screen
        if (screen is McpAddScreen.Progress && screen.stage == McpAddStage.AuthPrompt) approval.complete(true)
    }

    /**
     * Cancels an add in progress ("Cancel" on the progress page or the pre-sign-in notice, system back). Returns to the form once the
     * coordinator has cleaned up; no record or credential is left behind.
     */
    fun cancel() {
        runId.incrementAndGet()
        job?.cancel()
        approval.cancel()
        _state.update { if (it.screen is McpAddScreen.Progress) it.copy(screen = McpAddScreen.Form) else it }
    }

    // ── Confirm default permissions ────────────────────────

    fun setReadOnlyPermission(permission: McpToolPermission) = updateReview { it.copy(readOnlyPermission = permission) }

    fun setChangesPermission(permission: McpToolPermission) = updateReview { it.copy(changesPermission = permission) }

    private fun updateReview(change: (McpAddScreen.Review) -> McpAddScreen.Review) = _state.update { current ->
        val review = current.screen as? McpAddScreen.Review ?: return@update current
        current.copy(screen = change(review))
    }

    /**
     * "Done": the user has seen the tool groups and default permissions, so the tools are released from quarantine, the permissions are
     * written and the server now counts as added: the "pending confirmation" flag is cleared. The probe just read this very
     * snapshot, so the server is not asked a second time. If the permissions fail to save the tools stay quarantined: the server is not lost, and the detail screen later shows "Tools updated" for another confirmation.
     *
     * The write runs on [cleanupScope]: if the user leaves right after "Done" the page's scope is cancelled, and this confirmation must not be lost with it
     * (otherwise the record would be cleaned up as half-finished on the next launch).
     */
    fun finish() {
        val review = _state.value.screen as? McpAddScreen.Review ?: return
        if (review.saving) return
        updateReview { it.copy(saving = true) }
        cleanupScope.launch(dispatcher) {
            val permissions = review.tools.associate { tool ->
                tool.toolName to if (tool.readOnly) review.readOnlyPermission else review.changesPermission
            }
            try {
                store.confirmAddition(review.serverId, review.tools.map { it.copy(pendingReview = false) }, permissions)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // Permissions failed to save: at least record the server as added (see above).
                runCatching { store.markAdditionConfirmed(review.serverId) }
            }
            _state.update { it.copy(completedServerId = review.serverId) }
        }
    }

    /**
     * Leaving the add screen (system back, top-bar back, page destroyed). Parked on "confirm default permissions" without tapping Done = abandon the add,
     * removing the freshly persisted record and credentials; in progress = cancel. Nothing happens once Done was tapped.
     */
    fun close() {
        val current = _state.value
        cancel()
        val review = current.screen as? McpAddScreen.Review ?: return
        if (current.completedServerId != null || review.saving) return
        _state.update { it.copy(screen = McpAddScreen.Form) }
        cleanupScope.launch(dispatcher) { remove(review.serverId) }
    }

    /** Removes the freshly persisted record, tool snapshot and credentials. */
    private suspend fun remove(serverId: String) {
        runCatching { store.deleteServer(serverId) }
    }
}
