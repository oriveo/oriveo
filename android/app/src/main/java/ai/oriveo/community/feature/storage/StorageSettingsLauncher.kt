package ai.oriveo.community.feature.storage

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.storage.StorageManager
import android.provider.Settings
import android.widget.Toast
import ai.oriveo.community.R
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely
import ai.oriveo.community.ui.component.OriveoWebDestination
import ai.oriveo.community.ui.component.openOriveoWebPage

object StorageSettingsLauncher {

    fun openStorageSettings(context: Context) {
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
        Toast.makeText(context, R.string.external_app_unavailable, Toast.LENGTH_LONG).show()
    }

    /** Support happens in the open, on the repository's issue tracker. */
    fun openSupport(context: Context) {
        context.openOriveoWebPage(OriveoWebDestination.Issues)
    }
}
