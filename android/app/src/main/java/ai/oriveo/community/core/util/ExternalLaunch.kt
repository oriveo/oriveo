package ai.oriveo.community.core.util

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent
import ai.oriveo.community.R

enum class ExternalActivityLaunchOutcome {
    LAUNCHED,
    UNAVAILABLE,
}

fun launchExternalActivitySafely(launch: () -> Unit): ExternalActivityLaunchOutcome =
    try {
        launch()
        ExternalActivityLaunchOutcome.LAUNCHED
    } catch (_: ActivityNotFoundException) {
        ExternalActivityLaunchOutcome.UNAVAILABLE
    } catch (_: SecurityException) {
        ExternalActivityLaunchOutcome.UNAVAILABLE
    }

fun launchExternalActivityOrNotify(context: Context, launch: () -> Unit) {
    if (launchExternalActivitySafely(launch) == ExternalActivityLaunchOutcome.UNAVAILABLE) {
        Toast.makeText(context, R.string.external_app_unavailable, Toast.LENGTH_LONG).show()
    }
}

fun openExternalUrl(context: Context, url: String): Boolean {
    val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
    val viaCustomTabs = launchExternalActivitySafely {
        CustomTabsIntent.Builder().build().launchUrl(context, uri)
    }
    if (viaCustomTabs == ExternalActivityLaunchOutcome.LAUNCHED) return true
    val viaBrowser = launchExternalActivitySafely {
        context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    return viaBrowser == ExternalActivityLaunchOutcome.LAUNCHED
}
