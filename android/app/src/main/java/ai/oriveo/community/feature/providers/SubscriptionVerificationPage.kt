package ai.oriveo.community.feature.providers

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent
import ai.oriveo.community.R
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely

/**
 * Opens the provider's device-code approval page.
 *
 * A full browser is tried first so the user lands in a window where they can already be signed in to
 * the provider; a Custom Tab is the fallback for a device with no browser that answers ACTION_VIEW.
 * If neither is available the user is told, rather than left staring at a code that goes nowhere.
 */
internal fun openSubscriptionVerificationPage(context: Context, url: String) {
    val uri = Uri.parse(url)
    val browserIntent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    if (launchExternalActivitySafely { context.startActivity(browserIntent) } ==
        ExternalActivityLaunchOutcome.LAUNCHED
    ) return
    val customTab = launchExternalActivitySafely {
        CustomTabsIntent.Builder().build().launchUrl(context, uri)
    }
    if (customTab == ExternalActivityLaunchOutcome.UNAVAILABLE) {
        Toast.makeText(context, R.string.link_open_failed_message, Toast.LENGTH_LONG).show()
    }
}
