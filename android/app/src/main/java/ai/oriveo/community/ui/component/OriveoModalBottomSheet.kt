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
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
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
    val colors = OriveoTheme.colors
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        modifier = modifier,
        sheetState = sheetState,
        sheetMaxWidth = sheetMaxWidth,
        sheetGesturesEnabled = sheetGesturesEnabled,
        shape = shape,
        containerColor = resolveSheetContainerColor(containerColor, colors),
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
 * The light palette's `surface` is translucent (94% alpha), so a sheet painted with it lets the
 * text underneath show through. When the caller passes exactly `colors.surface`, flatten it onto
 * `backgroundBase` to get an opaque panel; any other explicit color (Transparent, paywall tints,
 * black backdrops) is kept as-is. The dark `surface` is already opaque, so it is unchanged.
 */
internal fun resolveSheetContainerColor(containerColor: Color, colors: OriveoColors): Color =
    if (containerColor == colors.surface) {
        colors.surface.compositeOver(colors.backgroundBase)
    } else {
        containerColor
    }

/**
 * Light-mode containers that float over scrolling content (composer shell, tab bar fallback,
 * popups, dropdown menus) must not let the text underneath show through. Flatten the original
 * color onto `backgroundBase`: same hue over empty space, but fully opaque. Dark mode keeps the
 * original color untouched.
 */
internal fun lightOpaqueContainerColor(color: Color, isDark: Boolean, colors: OriveoColors): Color =
    if (isDark) color else color.compositeOver(colors.backgroundBase)

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
