package ai.oriveo.community.core.mcp

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchCustomTab
import ai.oriveo.community.core.util.launchExternalActivitySafely
import java.lang.ref.WeakReference
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The sign-in page could not be opened (no browser / disabled by policy), or no redirect arrived before the timeout. The
 * authorizer treats it as "sign-in not completed".
 */
class McpBrowserSessionException(reason: String) : Exception(reason)

/**
 * Android implementation of the browser session: Custom Tabs opens the authorization page, [McpOAuthRedirectActivity]
 * receives the redirect and hands it to [McpOAuthCallbackRouter], and this class waits for it by `state`.
 *
 * Coming back to the app never ends the sign-in: when the server already granted consent and 302s without a user
 * tap, Custom Tabs keeps the https App Link and the app resumes first, and the web page's `oriveo://` fallback only
 * arrives afterwards; switching to a mail or authenticator app looks the same. The wait ends on the callback, the
 * user's cancel (the caller's coroutine is cancelled), or [timeoutMillis], which matches Web's overall limit.
 *
 * `state`, `iss` and the redirect URI itself are not validated here: the URL is handed back unchanged to
 * [McpAuthorizer.completeAuthorization].
 */
class McpAppBrowserSession(
    private val router: McpOAuthCallbackRouter,
    /** Opens the authorization page; returns false if it cannot be opened. */
    private val openPage: (url: String) -> Boolean,
    private val timeoutMillis: Long = AUTHORIZATION_TIMEOUT_MILLIS,
) : McpBrowserSession {

    override suspend fun authorize(url: String, redirectUri: String): String {
        // The authorization URL is built by the authorizer and always carries a state; without one the browser is not
        // opened (the redirect could not be claimed anyway).
        val state = McpCallbackValidator.parameters(url)["state"]?.takeIf { it.isNotEmpty() }
            ?: throw McpBrowserSessionException("missing state")
        val waiter = router.register(state)
        try {
            if (!openPage(url)) throw McpBrowserSessionException("no browser")
            return withTimeoutOrNull(timeoutMillis) { waiter.await() }
                ?: throw McpBrowserSessionException("timeout")
        } finally {
            router.cancel(state)
        }
    }

    companion object {
        const val AUTHORIZATION_TIMEOUT_MILLIS: Long = 10 * 60_000
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
            launchCustomTab(context, uri, CustomTabsIntent.Builder().setShowTitle(true).build())
        }
        if (viaCustomTabs == ExternalActivityLaunchOutcome.LAUNCHED) return true
        val viaBrowser = launchExternalActivitySafely {
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        return viaBrowser == ExternalActivityLaunchOutcome.LAUNCHED
    }
}
