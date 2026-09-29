package ai.oriveo.community.core.util

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText

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

/**
 * Safe entry point for Activity Result requests (system gallery / camera / document picker /
 * document creation): when nothing can handle it, say so with a top toast instead of letting
 * `launcher.launch(...)` throw [ActivityNotFoundException] on the main thread and crash the process.
 *
 * These entry points usually sit behind buttons people tap again when nothing happens, and a silent
 * failure is harder to diagnose than a crash, so give feedback rather than silence.
 */
fun launchExternalActivityOrNotify(snackbar: GlobalSnackbarManager?, launch: () -> Unit) {
    if (launchExternalActivitySafely(launch) == ExternalActivityLaunchOutcome.UNAVAILABLE) {
        snackbar?.show(
            GlobalSnackbarMessage(
                UiText.Resource(R.string.external_app_unavailable),
                style = GlobalToastStyle.Error,
            ),
        )
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
