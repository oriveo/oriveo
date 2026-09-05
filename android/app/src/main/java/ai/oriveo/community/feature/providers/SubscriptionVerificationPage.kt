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
 *
 *
 *
 */
internal fun openSubscriptionVerificationPage(context: Context, url: String) {
    val uri = Uri.parse(url)
    val browserIntent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    if (launchExternalActivitySafely { context.startActivity(browserIntent) } ==
        ExternalActivityLaunchOutcome.LAUNCHED
    ) return
    // Provider subscription authorization note.
    val customTab = launchExternalActivitySafely {
        CustomTabsIntent.Builder().build().launchUrl(context, uri)
    }
    if (customTab == ExternalActivityLaunchOutcome.UNAVAILABLE) {
        Toast.makeText(context, R.string.link_open_failed_message, Toast.LENGTH_LONG).show()
    }
}
