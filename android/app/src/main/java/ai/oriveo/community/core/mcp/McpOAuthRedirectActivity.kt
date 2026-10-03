package ai.oriveo.community.core.mcp

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import ai.oriveo.community.MainActivity
import org.koin.android.ext.android.inject

/**
 * Trampoline for the OAuth redirect: takes the callback URL, hands it to [McpOAuthCallbackRouter], brings the main UI
 * back to the foreground only when someone claims it, and finishes immediately. It shows no UI and makes no security
 * decision; `state` / `iss` / redirect URI validation happens in [McpAuthorizer.completeAuthorization].
 *
 * The URL is handed over first and the main UI is brought back second: the browser session decides that the user closed
 * the sign-in page themselves from "the main UI returned to the foreground before the callback arrived", so the reverse
 * order would turn a successful sign-in into a cancellation.
 *
 * When nobody claims it (`state` does not match, the authorization was not started from this app, the callback arrived
 * twice) the main UI is **not** brought to the foreground: that link is not one this app is waiting for, and pulling
 * the app up would only interrupt whatever the user is doing.
 */
class McpOAuthRedirectActivity : Activity() {
    private val router: McpOAuthCallbackRouter by inject()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val delivered = McpOAuthCallbackIntents.callbackUrl(intent)?.let(router::deliver) == true
        if (delivered) {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
        finish()
    }
}

object McpOAuthCallbackIntents {
    /**
     * Whether this intent carries the registered redirect URI; returns the full URL if so. Matches the intent filter in
     * the manifest literally (scheme + host + path must all match; no prefix matching).
     */
    fun callbackUrl(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val url = intent.dataString ?: return null
        return url.takeIf(McpOAuthCallbackRouter::isCallbackUrl)
    }
}
