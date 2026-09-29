package ai.oriveo.community.ui.component

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.oriveo.community.core.app.GlobalSnackbarManager

/**
 * The single entry point for every full-screen Dialog in the app (`usePlatformDefaultWidth = false`);
 * in addition it hosts a [GlobalToastHost] inside the Dialog window.
 *
 * A full-screen Dialog is its own window and completely covers the main window's toast host, so
 * feedback such as a link that could not be opened would never be seen. As with
 * [OriveoModalBottomSheet], a new full-screen Dialog that goes through here gets it automatically.
 */
@Composable
fun OriveoFullScreenDialog(
    onDismissRequest: () -> Unit,
    properties: DialogProperties = DialogProperties(
        usePlatformDefaultWidth = false,
        decorFitsSystemWindows = false,
    ),
    content: @Composable BoxScope.() -> Unit,
) {
    Dialog(onDismissRequest = onDismissRequest, properties = properties) {
        DialogToastLayer { content() }
    }
}

/** Full-screen content plus a toast host on top; the Dialog window extends behind the status bar, so the host clears it itself. */
@Composable
fun DialogToastLayer(
    manager: GlobalSnackbarManager? = rememberGlobalSnackbarManager(),
    content: @Composable BoxScope.() -> Unit,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        content()
        GlobalToastHost(
            manager = manager,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .statusBarsPadding(),
        )
    }
}
