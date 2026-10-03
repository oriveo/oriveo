package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import java.text.BreakIterator
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

// State machine for the connection probe.
//
// Validate the address → connect once without credentials → (success / not MCP / unreachable / sign-in required). When
// sign-in is required the flow branches on `authKind`: `token` retries with the token, `auto` runs authorization
// discovery (CIMD / DCR / neither supported).
//
// **A server record is saved only after the tool list has been read; no failure leaves half a server behind.** "Leaves
// nothing behind" covers the database tables **and the credential store**. The authorizer supports `persist =
// false`: tokens obtained through the browser sign-in stay in memory and are written to the credential store only after
// the record is stored, so a process killed between a successful sign-in and the insert leaves no unclaimed token
// either. Credentials are still cleared by `serverId` before any failure terminal state (defensive: the caller may have
// passed an authorizer in persisting mode).
//
// The production entry point is [McpAddCoordinator.add] (probe + persist + exactly one terminal state). [McpAddProbe]
// only probes and never persists.

/**
 * Why an address failed validation. Both lead to the same invalid-address screen; only the explanatory text differs.
 */
enum class McpInvalidUrlReason {
    /** Incomplete, not `https://`, or too long. */
    Malformed,

    /** The address carries a username or password: the explanation tells the user to use an access token instead. */
    HasUserinfo,
}

/** Result of [McpEndpoint.check]. */
sealed class McpEndpointCheck {
    data class Valid(val url: String) : McpEndpointCheck()
    data class Invalid(val reason: McpInvalidUrlReason) : McpEndpointCheck()
}

/**
 * Address validation, the first step of the add flow. Accepts only `https://` with a host name, at most 2048 bytes, and
 * no userinfo component.
 */
object McpEndpoint {
    fun validate(raw: String): String? = (check(raw) as? McpEndpointCheck.Valid)?.url

    fun check(raw: String): McpEndpointCheck {
        val trimmed = raw.trim()
        if (trimmed.isEmpty() || trimmed.toByteArray(Charsets.UTF_8).size > McpServerRecord.MAX_URL_LENGTH) {
            return McpEndpointCheck.Invalid(McpInvalidUrlReason.Malformed)
        }
        val uri = McpOrigin.parse(trimmed) ?: return McpEndpointCheck.Invalid(McpInvalidUrlReason.Malformed)
        val scheme = uri.scheme
        if (scheme?.lowercase(Locale.ROOT) != "https" || uri.host.isNullOrEmpty()) {
            return McpEndpointCheck.Invalid(McpInvalidUrlReason.Malformed)
        }
        // Addresses with a userinfo component (`user:pass@`) are always rejected, with a hint to use an access token
        // instead. The browser fetch specification forbids credentials in URLs, so the web client could never connect
        // anyway; all clients agree at this step.
        if (uri.rawUserInfo != null) return McpEndpointCheck.Invalid(McpInvalidUrlReason.HasUserinfo)
        // Stored addresses always use a lowercase scheme, whatever case the user typed.
        return McpEndpointCheck.Valid("https" + trimmed.substring(scheme.length))
    }
}

/**
 * Where requests for a saved server should go. **Every request path takes its address from here** and never uses
 * `record.url` directly: for a `localOnly` record `url` is only the display address, and the full address lives in the
 * credential store.
 */
sealed class McpServerEndpointResolution {
    data class Ready(val url: String) : McpServerEndpointResolution() {
        /** The full address may carry a secret, so it is kept out of the string description. */
        override fun toString(): String = "Ready(url=<redacted>)"
    }

    /**
     * The full address is not on this device (restored from a backup onto a new device, or the credential file was
     * cleared): the server needs its address entered again, and no request is sent.
     */
    data object NeedsAddress : McpServerEndpointResolution()

    val urlOrNull: String? get() = (this as? Ready)?.url
}

object McpServerEndpoint {
    fun resolve(record: McpServerRecord, uid: String, credentialStore: McpCredentialStore): McpServerEndpointResolution {
        val raw = if (record.localOnly) credentialStore.loadEndpoint(record.id, uid) else record.url
        val url = raw?.let(McpEndpoint::validate) ?: return McpServerEndpointResolution.NeedsAddress
        return McpServerEndpointResolution.Ready(url)
    }
}

/** Result of successfully reading the tool list (the data the default-permissions review needs). */
data class McpAddReview(
    val serverId: String,
    val session: McpSession,
    /**
     * Freshly fetched tool snapshots; new or changed tools have `pendingReview = true` and are withheld from outgoing
     * requests until the user confirms.
     */
    val tools: List<McpToolSnapshot>,
    /** Default permissions: `auto` for tools declared read-only, `ask` for the rest. */
    val defaultPermissions: Map<String, McpToolPermission>,
    /**
     * Tokens obtained through the browser sign-in that are **not yet written to the credential store** (`persist =
     * false`). [McpAddCoordinator] persists them once the record is stored. In the terminal state handed to the UI this
     * is already cleared (see [McpAddCoordinator.add]).
     */
    val pendingCredentials: McpCredentials? = null,
)

/**
 * States of the probe state machine. The progress, review and common failure states each map to one screen of the add
 * flow; the remaining terminal states have no screen of their own and leave their presentation to the UI layer.
 */
sealed class McpAddState {
    /** Connecting. */
    data object Connecting : McpAddState()

    /**
     * Pre-sign-in prompt. Carries the host name of the authorization endpoint; the state machine waits here for the
     * user's consent, and until then no client is registered and no browser is opened.
     */
    data class AuthPrompt(val authorizationHost: String) : McpAddState()

    /** System browser. */
    data object Browser : McpAddState()

    /** Reading the tool list. */
    data object Finishing : McpAddState()

    /** Default-permissions review (the success terminal state). */
    data class Review(val review: McpAddReview) : McpAddState()

    /**
     * The address is malformed (including addresses that are not `https://` and addresses with a userinfo component).
     */
    data class InvalidUrl(val reason: McpInvalidUrlReason) : McpAddState()

    /** Unreachable. */
    data object Unreachable : McpAddState()

    /** Not an MCP server. */
    data object NotMcp : McpAddState()

    /** An access token is required. */
    data object NeedsToken : McpAddState()

    /**
     * Sign-in was not completed (the user cancelled, the provider refused, or the server still rejects us after
     * sign-in).
     */
    data object AuthCancelled : McpAddState()

    /** Token field error: with `authKind = token` the retry with the token still got a 401. */
    data object TokenRejected : McpAddState()

    /**
     * The server limit has been reached (carries the limit). Checked before probing starts so the user is not turned
     * away after completing a sign-in.
     */
    data class LimitReached(val max: Int) : McpAddState()

    /**
     * The addition was cancelled (the coroutine that started it was cancelled). No record or credentials are left
     * behind.
     */
    data object Cancelled : McpAddState()

    /**
     * The server connected and the tools were read, but writing to local storage failed (or `serverId` collided with an
     * existing server). No record or credentials are left behind.
     */
    data object SaveFailed : McpAddState()

    /** Connecting through reading the tool list are in-progress states; everything else is terminal. */
    val isTerminal: Boolean
        get() = when (this) {
            Connecting, is AuthPrompt, Browser, Finishing -> false
            else -> true
        }
}

/**
 * What the pre-sign-in prompt shows: the host name of the authorization endpoint. The system browser opens only after
 * the user confirms.
 */
data class McpAuthPrompt(val authorizationHost: String)

/** Progress-state callback. */
typealias McpAddProgress = suspend (McpAddState) -> Unit

/**
 * Pre-sign-in gate: shows the prompt and waits for the user's decision. Only `true` lets the flow continue (register
 * the client, open the browser).
 */
typealias McpAuthorizationGate = suspend (McpAuthPrompt) -> Boolean

/**
 * Connection probe state machine. Does not write to the server store; progress states are reported to the UI through
 * the `progress` callback.
 */
class McpAddProbe(
    private val authorizer: McpAuthorizer,
    /**
     * Must be the same store [authorizer] uses: on a failed probe, any token this sign-in stored has to be deleted from
     * it.
     */
    private val credentialStore: McpCredentialStore,
    private val makeClient: (String) -> McpClient,
    private val runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /**
     * Runs one probe and also sends the terminal state through `progress`. Probes only, never persists; production code
     * goes through [McpAddCoordinator.add].
     */
    suspend fun probe(
        urlString: String,
        authKind: McpAuthKind,
        uid: String,
        token: String? = null,
        serverId: String = UUID.randomUUID().toString(),
        confirmAuthorization: McpAuthorizationGate? = null,
        progress: McpAddProgress? = null,
    ): McpAddState {
        val state = run(urlString, authKind, uid, token, serverId, confirmAuthorization, progress)
        withContext(NonCancellable) { progress?.invoke(state) }
        return state
    }

    /**
     * Runs one probe and returns the terminal state. Progress states are delivered through `progress` in order, but
     * **the terminal state is not**: the caller emits it once after persisting, so the UI never receives "success"
     * followed by "failure".
     *
     * - [token]: the access token the user entered when `authKind = Token`.
     * - [serverId] must identify a server that does not exist yet: on failure the credentials stored under this id are
     *   deleted.
     * - [confirmAuthorization]: the pre-sign-in gate. Omitting it is the same as the user declining: no client is
     *   registered and no browser is opened.
     *
     * If the coroutine that started it is cancelled this returns [McpAddState.Cancelled] (it does not throw). By the
     * time any failure terminal state is returned, the credentials of this sign-in have been deleted.
     */
    suspend fun run(
        urlString: String,
        authKind: McpAuthKind,
        uid: String,
        token: String? = null,
        serverId: String = UUID.randomUUID().toString(),
        confirmAuthorization: McpAuthorizationGate? = null,
        progress: McpAddProgress? = null,
    ): McpAddState {
        val endpoint = when (val checked = McpEndpoint.check(urlString)) {
            is McpEndpointCheck.Valid -> checked.url
            is McpEndpointCheck.Invalid -> return McpAddState.InvalidUrl(checked.reason)
        }
        val state = try {
            explore(endpoint, authKind, uid, token, serverId, confirmAuthorization, progress)
        } catch (error: CancellationException) {
            McpAddState.Cancelled
        }
        if (state !is McpAddState.Review) discardCredentials(serverId, uid)
        return state
    }

    /**
     * Deletes the credentials this addition stored (a no-op if there are none). A failed delete must not mask the
     * failure reason, so this never throws.
     */
    private fun discardCredentials(serverId: String, uid: String) {
        runCatching { credentialStore.delete(serverId, uid) }
    }

    private suspend fun explore(
        endpoint: String,
        authKind: McpAuthKind,
        uid: String,
        token: String?,
        serverId: String,
        confirmAuthorization: McpAuthorizationGate?,
        progress: McpAddProgress?,
    ): McpAddState {
        if (cancelled()) return McpAddState.Cancelled
        progress?.invoke(McpAddState.Connecting)

        val client = makeClient(endpoint)
        // Step one: connect once without credentials.
        when (val outcome = client.connect()) {
            is McpConnectOutcome.Connected -> return finish(client, outcome.session, serverId, authKind, null, progress)
            McpConnectOutcome.NotMcp -> return McpAddState.NotMcp
            is McpConnectOutcome.Failed -> return failureState(outcome.error)
            McpConnectOutcome.Unreachable -> return if (cancelled()) McpAddState.Cancelled else McpAddState.Unreachable
            McpConnectOutcome.NeedsAuth -> Unit
        }

        return when (authKind) {
            McpAuthKind.Token -> {
                if (token.isNullOrEmpty()) return McpAddState.TokenRejected
                retryWithToken(client, token, serverId, authKind, null, progress)
            }
            McpAuthKind.Auto -> runDiscovery(client, endpoint, serverId, uid, confirmAuthorization, progress)
        }
    }

    // ── Branches ───────────────────────────────────────────

    /**
     * Discovery for `authKind = auto`: if the client can register automatically → prompt (wait for consent) → browser →
     * sign-in → read tools → review; otherwise → access token required.
     */
    private suspend fun runDiscovery(
        client: McpClient,
        endpoint: String,
        serverId: String,
        uid: String,
        confirmAuthorization: McpAuthorizationGate?,
        progress: McpAddProgress?,
    ): McpAddState {
        val plan = when (val discovered = authorizer.discover(client.authChallenge, endpoint)) {
            is McpAuthDiscoveryOutcome.Ready -> discovered.plan
            McpAuthDiscoveryOutcome.NeedsToken -> return if (cancelled()) McpAddState.Cancelled else McpAddState.NeedsToken
            // The metadata could not be fetched this time (network / timeout / 5xx): that means unreachable, not a
            // conclusion that an access token is required.
            McpAuthDiscoveryOutcome.TemporarilyUnavailable ->
                return if (cancelled()) McpAddState.Cancelled else McpAddState.Unreachable
        }
        if (cancelled()) return McpAddState.Cancelled

        // Pre-sign-in gate: only GETs have been sent so far. A DCR registration leaves a client on the authorization
        // server, and opening the browser takes the user to a third-party page; both must happen only after the user
        // consents.
        val prompt = McpAuthPrompt(plan.authorizationHost ?: plan.issuer)
        progress?.invoke(McpAddState.AuthPrompt(prompt.authorizationHost))
        val approved = confirmAuthorization?.invoke(prompt) ?: false
        if (cancelled()) return McpAddState.Cancelled
        if (!approved) return McpAddState.AuthCancelled

        progress?.invoke(McpAddState.Browser)
        val credentials = try {
            // The discovery result is passed to authorization as is, without discovering again; client registration
            // happens inside this step. Tokens are not persisted yet (see the file header).
            authorizer.authorize(plan, serverId, uid, persist = false)
        } catch (error: CancellationException) {
            throw error
        } catch (error: McpAuthorizerException) {
            if (cancelled()) return McpAddState.Cancelled
            return if (error.isTransient) McpAddState.Unreachable else McpAddState.AuthCancelled
        } catch (error: Exception) {
            // User cancelled / provider refused / redirect rejected → sign-in not completed.
            return if (cancelled()) McpAddState.Cancelled else McpAddState.AuthCancelled
        }
        if (cancelled()) return McpAddState.Cancelled

        val token = credentials.accessToken ?: credentials.pastedToken ?: return McpAddState.AuthCancelled
        return retryWithToken(client, token, serverId, McpAuthKind.Auto, credentials, progress)
    }

    /**
     * Reconnects with a token. If sign-in is still required, the outcome depends on the sign-in method: pasted token →
     * token field error; browser sign-in → sign-in not completed.
     */
    private suspend fun retryWithToken(
        client: McpClient,
        token: String,
        serverId: String,
        authKind: McpAuthKind,
        pendingCredentials: McpCredentials?,
        progress: McpAddProgress?,
    ): McpAddState = when (val outcome = client.connect(bearerToken = token)) {
        is McpConnectOutcome.Connected -> finish(client, outcome.session, serverId, authKind, pendingCredentials, progress)
        McpConnectOutcome.NeedsAuth -> rejectedState(authKind)
        McpConnectOutcome.NotMcp -> McpAddState.NotMcp
        is McpConnectOutcome.Failed -> failureState(outcome.error)
        McpConnectOutcome.Unreachable -> if (cancelled()) McpAddState.Cancelled else McpAddState.Unreachable
    }

    /** Reads the tool list, then moves to the default-permissions review. */
    private suspend fun finish(
        client: McpClient,
        session: McpSession,
        serverId: String,
        authKind: McpAuthKind,
        pendingCredentials: McpCredentials?,
        progress: McpAddProgress?,
    ): McpAddState {
        if (cancelled()) return McpAddState.Cancelled
        progress?.invoke(McpAddState.Finishing)
        val definitions = try {
            client.listTools()
        } catch (error: CancellationException) {
            throw error
        } catch (error: McpClientException) {
            if (error.code == McpErrorCode.NeedsAuth) return rejectedState(authKind)
            return failureState(error)
        } catch (error: Exception) {
            return if (cancelled()) McpAddState.Cancelled else McpAddState.Unreachable
        }
        if (cancelled()) return McpAddState.Cancelled
        val snapshots = McpToolCatalog.snapshots(serverId, definitions, runtimeConfig, now = now())
        return McpAddState.Review(
            McpAddReview(
                serverId = serverId,
                session = session,
                tools = snapshots,
                defaultPermissions = McpToolCatalog.defaultPermissions(snapshots),
                pendingCredentials = pendingCredentials,
            ),
        )
    }

    private fun rejectedState(authKind: McpAuthKind): McpAddState =
        if (authKind == McpAuthKind.Token) McpAddState.TokenRejected else McpAddState.AuthCancelled

    /**
     * Cancellation has its own terminal state and is not folded into "unreachable"; timeouts and server errors remain
     * "unreachable".
     */
    private suspend fun failureState(error: McpClientException): McpAddState =
        if (error.code == McpErrorCode.Cancelled || cancelled()) McpAddState.Cancelled else McpAddState.Unreachable

    private suspend fun cancelled(): Boolean = !currentCoroutineContext().isActive
}

/**
 * Production entry point of the add flow: probe → persist → emit **one** terminal state.
 *
 * A server record is written only once the tool list has been read; after any failure terminal state neither the
 * database nor the credential store hold a trace of this addition.
 */
class McpAddCoordinator(
    private val probe: McpAddProbe,
    private val store: McpServerStore,
    /** Must be the same store the probe and the authorizer use. */
    private val credentialStore: McpCredentialStore,
    private val runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback,
) {
    private val uid: String get() = LOCAL_PARTITION_ID

    /**
     * Runs the probe and persists on success. Returns the terminal state; [progress] receives the progress states in
     * order and then the terminal state exactly once (the return value). In the returned [McpAddState.Review],
     * `pendingCredentials` is already cleared: tokens belong in the credential store only.
     *
     * If the coroutine that started it is cancelled, cleanup finishes before [McpAddState.Cancelled] is returned, and
     * the terminal state is still delivered to [progress].
     */
    suspend fun add(
        urlString: String,
        authKind: McpAuthKind,
        name: String = "",
        token: String? = null,
        serverId: String = UUID.randomUUID().toString(),
        confirmAuthorization: McpAuthorizationGate? = null,
        progress: McpAddProgress? = null,
    ): McpAddState {
        val state = try {
            perform(urlString, name, authKind, token, serverId, confirmAuthorization, progress)
        } catch (error: CancellationException) {
            withContext(NonCancellable) { rollBack(serverId, removeRecord = false) }
            McpAddState.Cancelled
        }
        val published = if (state is McpAddState.Review) {
            McpAddState.Review(state.review.copy(pendingCredentials = null))
        } else {
            state
        }
        withContext(NonCancellable) { progress?.invoke(published) }
        return published
    }

    private suspend fun perform(
        urlString: String,
        name: String,
        authKind: McpAuthKind,
        token: String?,
        serverId: String,
        confirmAuthorization: McpAuthorizationGate?,
        progress: McpAddProgress?,
    ): McpAddState {
        val endpoint = when (val checked = McpEndpoint.check(urlString)) {
            is McpEndpointCheck.Valid -> checked.url
            is McpEndpointCheck.Invalid -> return McpAddState.InvalidUrl(checked.reason)
        }

        // At the limit, or this id already is a server: refuse before sending any request. The former spares the user
        // from finishing a browser sign-in only to be told nothing can be added; the latter matters because the failure
        // cleanup below deletes the credentials stored under this id, and it must never touch the tokens of an existing
        // server.
        try {
            if (store.serverExists(serverId)) return McpAddState.SaveFailed
            if (store.serverCount() >= runtimeConfig.maxServers) return McpAddState.LimitReached(runtimeConfig.maxServers)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            return McpAddState.SaveFailed
        }

        val state = probe.run(urlString, authKind, uid, token, serverId, confirmAuthorization, progress)
        // The probe's own failure terminal states: the probe already cleared the credentials.
        if (state !is McpAddState.Review) return state
        val review = state.review

        // Last cancellation check before persisting: the user has left the add screen, so no server may silently
        // appear.
        if (!currentCoroutineContext().isActive) {
            rollBack(serverId, removeRecord = false)
            return McpAddState.Cancelled
        }

        val now = System.currentTimeMillis()
        // An address that looks like it carries a secret has its full form stored as a credential, and only the
        // display address is written to the database (`McpServerStore` enforces that on write).
        val localOnly = McpLocalOnly.isLocalOnly(endpoint)
        // Persisting the record and the credentials is non-cancellable as a whole: if the write transaction commits and
        // the coroutine is then cancelled at the resume point, a record would be left behind with nobody aware of it.
        // Cancellation is checked after this block, when everything that needs undoing can be undone cleanly.
        val failure: McpAddState? = withContext(NonCancellable) {
            try {
                // One write transaction covers everything; a failure rolls it all back, and a primary-key collision
                // leaves the existing server untouched. What is stored is a pending-confirmation record: it is not
                // listed until the user taps "Done" on the default-permissions review.
                store.addServer(
                    McpServerAddition(
                        id = serverId,
                        name = resolveName(name, review.session, endpoint),
                        url = endpoint,
                        authKind = authKind,
                        localOnly = localOnly,
                        iconURL = review.session.serverIconUrl,
                        createdAt = now,
                        snapshots = review.tools,
                        permissions = review.defaultPermissions,
                        connectionState = McpConnectionState(
                            serverId = serverId,
                            status = McpConnectionStatus.Connected,
                            lastSuccessAt = now,
                            negotiatedVersion = review.session.protocolVersion,
                            generation = review.session.generation,
                            sessionId = review.session.sessionId,
                        ),
                        pendingAdd = true,
                    ),
                    maxServers = runtimeConfig.maxServers,
                )
            } catch (error: McpStoreError.LimitReached) {
                // Another addition filled the remaining slots during the probe.
                rollBack(serverId, removeRecord = false)
                return@withContext McpAddState.LimitReached(error.max)
            } catch (error: Exception) {
                rollBack(serverId, removeRecord = false)
                return@withContext McpAddState.SaveFailed
            }

            // The full address is stored after the insert for the same reason: a localOnly server without its full
            // address cannot send any request, so failing to store it counts as a failed addition. Tokens are stored
            // after the insert too: storing the token first and being killed before the insert would leave a token
            // without a server that nothing ever cleans up; the other order leaves a pending-confirmation record that
            // the next launch sweeps. If storing fails, the addition fails and the just-inserted record is removed
            // (`addServer` succeeding proves it did not exist before, so the row deleted is always the one inserted
            // here).
            try {
                if (localOnly) credentialStore.saveEndpoint(endpoint, serverId, uid)
                persistAfterInsert(review, authKind, token, serverId)
            } catch (error: Exception) {
                rollBack(serverId, removeRecord = true)
                return@withContext McpAddState.SaveFailed
            }
            null
        }
        if (failure != null) return failure
        // The user left the add screen while persisting: undo the record and credentials just written.
        if (!currentCoroutineContext().isActive) {
            withContext(NonCancellable) { rollBack(serverId, removeRecord = true) }
            return McpAddState.Cancelled
        }
        return state
    }

    private fun persistAfterInsert(review: McpAddReview, authKind: McpAuthKind, token: String?, serverId: String) {
        var credentials = review.pendingCredentials
        // The pasted access token has only lived in memory so far (the probe connected with it once); unless it is
        // stored, the next call has no token to send.
        if (authKind == McpAuthKind.Token && !token.isNullOrEmpty()) {
            credentials = (credentials ?: McpCredentials()).copy(pastedToken = token)
        }
        if (credentials != null) credentialStore.save(credentials, serverId, uid)
    }

    /**
     * Undoes this addition: optionally deletes the just-inserted record and clears the credentials stored under this
     * id. Never throws.
     */
    private suspend fun rollBack(serverId: String, removeRecord: Boolean) {
        if (removeRecord) runCatching { store.deleteServer(serverId) }
        runCatching { credentialStore.delete(serverId, uid) }
    }

    companion object {
        /** Fallback when the name is left empty: the server's self-reported name → the host name. */
        internal fun resolveName(name: String, session: McpSession, endpoint: String): String {
            val trimmed = name.trim()
            if (trimmed.isNotEmpty()) return capped(trimmed)
            val serverName = session.serverName?.trim()
            if (!serverName.isNullOrEmpty()) return capped(serverName)
            return capped(McpOrigin.parse(endpoint)?.host ?: FALLBACK_NAME)
        }

        private const val FALLBACK_NAME = "MCP Server"

        /**
         * Truncates to at most 64 UTF-16 code units without splitting a grapheme cluster. Code units are the measure
         * because that is what [McpServerRecord.MAX_NAME_LENGTH] counts; a name truncated by grapheme count could
         * exceed 64 code units.
         */
        internal fun capped(name: String): String {
            val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
            iterator.setText(name)
            var end = 0
            var next = iterator.next()
            while (next != BreakIterator.DONE && next <= McpServerRecord.MAX_NAME_LENGTH) {
                end = next
                next = iterator.next()
            }
            return if (end == 0) FALLBACK_NAME else name.substring(0, end)
        }
    }
}
