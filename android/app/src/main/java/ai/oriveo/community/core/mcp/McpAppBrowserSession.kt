package ai.oriveo.community.core.mcp

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely
import java.lang.ref.WeakReference
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The sign-in page could not be opened (no browser / disabled by policy), or the user came back without a redirect. The
 * authorizer treats it as "sign-in not completed".
 */
class McpBrowserSessionException(reason: String) : Exception(reason)

/**
 * Android implementation of the browser session: Custom Tabs opens the authorization page, [McpOAuthRedirectActivity]
 * receives the redirect and hands it to [McpOAuthCallbackRouter], and this class waits for it by `state`.
 *
 * The system gives no callback when the user closes Custom Tabs, so that can only be inferred from "the main UI is back
 * in the foreground but no redirect arrived". The redirect path is "the trampoline Activity delivers the URL first,
 * then brings the main UI to the foreground", so on a normal completion the URL always arrives before
 * [McpOAuthCallbackRouter.hostResumed]; [dismissGraceMillis] only leaves room for scheduling between those two steps.
 *
 * `state`, `iss` and the redirect URI itself are not validated here: the URL is handed back unchanged to
 * [McpAuthorizer.completeAuthorization].
 */
class McpAppBrowserSession(
    private val router: McpOAuthCallbackRouter,
    /** Opens the authorization page; returns false if it cannot be opened. */
    private val openPage: (url: String) -> Boolean,
    private val dismissGraceMillis: Long = 600,
) : McpBrowserSession {

    override suspend fun authorize(url: String, redirectUri: String): String {
        // The authorization URL is built by the authorizer and always carries a state; without one the browser is not
        // opened (the redirect could not be claimed anyway).
        val state = McpCallbackValidator.parameters(url)["state"]?.takeIf { it.isNotEmpty() }
            ?: throw McpBrowserSessionException("missing state")
        val waiter = router.register(state)
        try {
            return coroutineScope {
                // Subscribe before opening the browser: UNDISPATCHED guarantees we are already listening for "back in
                // the foreground" when it opens.
                val watchdog = launch(start = CoroutineStart.UNDISPATCHED) {
                    router.hostResumed.collect {
                        delay(dismissGraceMillis)
                        waiter.completeExceptionally(McpBrowserSessionException("dismissed"))
                    }
                }
                try {
                    if (!openPage(url)) throw McpBrowserSessionException("no browser")
                    waiter.await()
                } finally {
                    watchdog.cancel()
                }
            }
        } finally {
            router.cancel(state)
        }
    }
}

/**
 * Opens the authorization page with Custom Tabs. When there is a foreground Activity its context is used (the sign-in
 * page lands in this app's task and is dismissed together with it after the redirect); otherwise it falls back to the
 * application context, which requires `NEW_TASK`.
 */
class McpAuthorizationPageLauncher(private val appContext: Context) {
    @Volatile private var host: WeakReference<Activity>? = null

    fun attach(activity: Activity) {
        host = WeakReference(activity)
    }

    fun detach(activity: Activity) {
        if (host?.get() === activity) host = null
    }

    fun open(url: String): Boolean {
        val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        val activity = host?.get()?.takeUnless { it.isFinishing || it.isDestroyed }
        val context: Context = activity ?: appContext
        val viaCustomTabs = launchExternalActivitySafely {
            val tabs = CustomTabsIntent.Builder().setShowTitle(true).build()
            if (activity == null) tabs.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            tabs.launchUrl(context, uri)
        }
        if (viaCustomTabs == ExternalActivityLaunchOutcome.LAUNCHED) return true
        val viaBrowser = launchExternalActivitySafely {
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        return viaBrowser == ExternalActivityLaunchOutcome.LAUNCHED
    }
}
