package ai.oriveo.community.feature.storage

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.storage.StorageManager
import android.provider.Settings
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely
import ai.oriveo.community.ui.component.OriveoWebDestination
import ai.oriveo.community.ui.component.openOriveoWebPage

object StorageSettingsLauncher {

    /** The failure toast is shown by the blocked screen's own toast host (NavHost is short-circuited then). */
    fun openStorageSettings(context: Context, snackbar: GlobalSnackbarManager) {
        val candidates = listOf(
            Intent(StorageManager.ACTION_MANAGE_STORAGE),
            Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", context.packageName, null)),
        )
        for (intent in candidates) {
            val launched = launchExternalActivitySafely {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            if (launched == ExternalActivityLaunchOutcome.LAUNCHED) return
        }
        snackbar.show(
            GlobalSnackbarMessage(UiText.Resource(R.string.external_app_unavailable), style = GlobalToastStyle.Error),
        )
    }

    /** Support happens in the open, on the repository's issue tracker. */
    fun openSupport(context: Context) {
        context.openOriveoWebPage(OriveoWebDestination.Issues)
    }
}
