package ai.oriveo.community.core.mcp

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * In-process handoff of the OAuth redirect: the browser session waits here, and the Activity that receives the callback
 * intent hands the URL in.
 *
 * The callback arrives on the custom scheme (`oriveo://mcp/oauth/callback`) and is claimed by `state` only: a given
 * `state` is claimed once, and one that does not match is not claimed (the caller treats it as an authorization that was
 * not started from this app). Validating `state`, `iss` and the redirect URI itself remains the job of
 * [McpAuthorizer.completeAuthorization]; this class only delivers the URL to the authorization that started it and makes
 * no security decision.
 */
class McpOAuthCallbackRouter {
    private val pending = ConcurrentHashMap<String, CompletableDeferred<String>>()

    private val _hostResumed = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /**
     * The main UI returned to the foreground. Custom Tabs gives no callback when it is closed, so the browser session uses
     * this to detect "the user came back without a callback" (= the user closed the sign-in page themselves). No replay:
     * only an occurrence after subscribing counts.
     */
    val hostResumed: SharedFlow<Unit> = _hostResumed.asSharedFlow()

    /** Called from the main Activity's `onResume`. */
    fun notifyHostResumed() {
        _hostResumed.tryEmit(Unit)
    }

    /** Registers before the browser is opened and returns the handle that waits for the callback. */
    fun register(state: String): CompletableDeferred<String> =
        CompletableDeferred<String>().also { pending[state] = it }

    /** Removes the registration when the user cancels or the browser session ends. */
    fun cancel(state: String) {
        pending.remove(state)?.cancel()
    }

    /**
     * Hands the callback URL to the waiting authorization. Returns false when it is not the registered redirect URI,
     * has no `state`, or nobody is waiting for that `state`.
     */
    fun deliver(callbackUrl: String): Boolean {
        if (!isCallbackUrl(callbackUrl)) return false
        val state = McpCallbackValidator.parameters(callbackUrl)["state"] ?: return false
        val waiter = pending.remove(state) ?: return false
        return waiter.complete(callbackUrl)
    }

    companion object {
        /** Whether this is a registered redirect URI. */
        fun isCallbackUrl(url: String): Boolean = McpClientMetadata.REDIRECT_URIS.any { McpRedirectUri.matches(url, it) }
    }
}
