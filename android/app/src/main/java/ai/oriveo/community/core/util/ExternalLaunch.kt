package ai.oriveo.community.core.util

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText

/**
 * The single safe entry point for handing something to another app on the system.
 *
 * Why: `startActivity` / `CustomTabsIntent.launchUrl` / the Activity Result `launch()` all end up on the same
 * system Activity resolution path, which **throws** [ActivityNotFoundException] when no component can handle the
 * request. A device may well lack the target component (browser disabled, work profile restrictions, slimmed-down
 * ROMs, app cloning or virtual containers, enterprise policy). That is not an app bug, but it would still crash
 * the whole process (for example an OAuth page opened with ACTION_VIEW on a device with no browser).
 *
 * `Intent.resolveActivity` is deliberately not used as a pre-check: the manifest declares no `<queries>`, so with
 * package visibility on API 30+ it returns null for every http(s) URL (a false negative). Catching the exception
 * that is actually thrown is the reliable test.
 */
enum class ExternalActivityLaunchOutcome {
    LAUNCHED,
    UNAVAILABLE,
}

/**
 * Only degrades "the external Activity is unavailable" into a state the UI can report; other exceptions keep
 * propagating so programming errors are not swallowed.
 *
 * [SecurityException]: the target component exists but refuses to be started by this app (not exported, missing
 * permission, crossing a work-profile boundary). For the user that is the same as "there is no such app", so it is
 * also reported as [ExternalActivityLaunchOutcome.UNAVAILABLE].
 */
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

/**
 * Opens [url] in an external browser and returns whether it was really opened; callers **must** handle false
 * (give the user an understandable message) and must not treat this as fire-and-forget.
 *
 * Order: Custom Tabs, then plain `ACTION_VIEW`. When no browser supports Custom Tabs it falls back to a plain
 * `ACTION_VIEW`, which can throw in the same way, so each step is guarded on its own and the second step is not
 * skipped because the first one threw (the two resolve slightly different component sets).
 *
 * Task ownership: the ACTION_VIEW fallback always carries [Intent.FLAG_ACTIVITY_NEW_TASK] (a browser belongs in its
 * own task). Custom Tabs go through [launchCustomTab], which adds NEW_TASK only when no Activity is available:
 * Custom Tabs do **not** handle task ownership for the caller, and a bare `launchUrl` from the application context
 * throws AndroidRuntimeException.
 */
fun openExternalUrl(context: Context, url: String): Boolean {
    val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
    val viaCustomTabs = launchExternalActivitySafely {
        launchCustomTab(context, uri)
    }
    if (viaCustomTabs == ExternalActivityLaunchOutcome.LAUNCHED) return true
    val viaBrowser = launchExternalActivitySafely {
        context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    return viaBrowser == ExternalActivityLaunchOutcome.LAUNCHED
}

/**
 * Walks the [ContextWrapper.getBaseContext] chain to find the host Activity; Compose's `LocalContext` is often a wrapper around it.
 */
internal fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current != null) {
        if (current is Activity) return current
        current = (current as? ContextWrapper)?.baseContext
    }
    return null
}

/**
 * The single entry point for opening [uri] with Custom Tabs.
 *
 * When an Activity can be found it launches from it without NEW_TASK: the Custom Tab stays in this app's task and
 * closing it returns to the original page. When none is found (application / service context),
 * [Intent.FLAG_ACTIVITY_NEW_TASK] is added to [CustomTabsIntent.intent]; otherwise the system throws
 * AndroidRuntimeException and the process crashes.
 * When no component can handle it, [ActivityNotFoundException] is thrown as usual for the caller to guard.
 */
fun launchCustomTab(
    context: Context,
    uri: Uri,
    tabs: CustomTabsIntent = CustomTabsIntent.Builder().build(),
) {
    val activity = context.findActivity()
    if (activity == null) tabs.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    tabs.launchUrl(activity ?: context, uri)
}
