package ai.oriveo.community.ui.component

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.statusBars
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalBottomSheetProperties
import androidx.compose.material3.SheetState
import androidx.compose.material3.contentColorFor
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.app.GlobalSnackbarManager
import kotlin.math.roundToInt

/**
 * The single entry point for every bottom sheet in the app. Parameters map one to one to Material3
 * [ModalBottomSheet]; in addition it hosts a [GlobalToastHost] inside the sheet window.
 *
 * A ModalBottomSheet renders in its own window and completely covers the main window's toast host,
 * so feedback raised inside a sheet ("Saved", "Couldn't open link") would never be seen. This adds the
 * host in one place; a new sheet that uses this gets it automatically.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OriveoModalBottomSheet(
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    sheetState: SheetState = rememberModalBottomSheetState(),
    sheetMaxWidth: Dp = BottomSheetDefaults.SheetMaxWidth,
    sheetGesturesEnabled: Boolean = true,
    shape: Shape = BottomSheetDefaults.ExpandedShape,
    containerColor: Color = BottomSheetDefaults.ContainerColor,
    contentColor: Color = contentColorFor(containerColor),
    tonalElevation: Dp = 0.dp,
    scrimColor: Color = BottomSheetDefaults.ScrimColor,
    dragHandle: @Composable (() -> Unit)? = { BottomSheetDefaults.DragHandle() },
    contentWindowInsets: @Composable () -> WindowInsets = { BottomSheetDefaults.windowInsets },
    properties: ModalBottomSheetProperties = ModalBottomSheetProperties(),
    content: @Composable ColumnScope.() -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        modifier = modifier,
        sheetState = sheetState,
        sheetMaxWidth = sheetMaxWidth,
        sheetGesturesEnabled = sheetGesturesEnabled,
        shape = shape,
        containerColor = containerColor,
        contentColor = contentColor,
        tonalElevation = tonalElevation,
        scrimColor = scrimColor,
        dragHandle = dragHandle,
        contentWindowInsets = contentWindowInsets,
        properties = properties,
    ) {
        SheetToastLayer { content() }
    }
}

/**
 * Sheet content plus a toast host layered on top of it.
 *
 * The content still sits in a fillMaxWidth Column, the same shape as Material3's own content column
 * (weight / align work as usual). The host sits at the top of the sheet panel; when the panel is dragged
 * close to the top of the screen it only adds the part that overlaps the status bar, rather than an
 * unconditional statusBarsPadding like the main window (a half-height sheet is far from the status bar).
 */
@Composable
fun SheetToastLayer(
    manager: GlobalSnackbarManager? = rememberGlobalSnackbarManager(),
    content: @Composable ColumnScope.() -> Unit,
) {
    val statusBarTop = WindowInsets.statusBars.getTop(LocalDensity.current)
    var layerTopInWindow by remember { mutableIntStateOf(Int.MAX_VALUE) }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .onGloballyPositioned { layerTopInWindow = it.positionInWindow().y.roundToInt() },
    ) {
        Column(modifier = Modifier.fillMaxWidth(), content = content)
        GlobalToastHost(
            manager = manager,
            modifier = Modifier
                .align(Alignment.TopCenter)
                // Read the position in the placement phase so dragging the sheet does not recompose
                .offset { IntOffset(0, (statusBarTop - layerTopInWindow).coerceAtLeast(0)) },
        )
    }
}
