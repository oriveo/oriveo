package ai.oriveo.community.feature.chat

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.error.isTransientNetworkOrCancellation
import ai.oriveo.community.core.model.ProviderServiceError

/** Turns a failure to pick a provider for the next message into one snackbar the user can act on. */
class ChatProviderResolutionErrorReporter(
    private val context: Context,
    private val globalSnackbarManager: GlobalSnackbarManager,
) {
    fun show(error: Throwable) {
        val providerError = error as? ProviderServiceError
        val message = when {
            providerError != null -> ErrorMapper.localizeProviderErrorMessage(providerError, context)
            error.isTransientNetworkOrCancellation() -> context.getString(R.string.error_network_message)
            else -> context.getString(R.string.error_generic_message)
        }
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Dynamic(message),
                style = GlobalToastStyle.Error,
            ),
        )
    }
}
