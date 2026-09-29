package ai.oriveo.community.ui.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.materialIcon
import androidx.compose.material.icons.materialPath
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.PriorityHigh
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.delay
import org.koin.mp.KoinPlatform

private const val TOAST_DURATION_MS = 3000L

/** Capsule shape, same spec on every platform (iOS `Capsule` / Web `rounded-full`): corner radius is half the height. */
internal val GlobalToastShape = RoundedCornerShape(percent = 50)

/**
 * Global top toast overlay, mirroring iOS `ToastOverlay` / `ToastManager`.
 *
 * A centered capsule at the top: a 24dp colored round icon on the left, the text, and an optional
 * action; dismissed after 3s by default. Every platform uses the same spec (iOS `ToastOverlay` /
 * Web `components/Toast.tsx`), so change the look on all of them together.
 *
 * Every window (the main window / a ModalBottomSheet / a full-screen Dialog) hosts its own copy, and
 * [GlobalSnackbarManager] lets only the topmost one render. When an upper window closes, the remaining
 * time hands back to the next one down, which keeps showing the toast. Sheets always go through
 * [OriveoModalBottomSheet], which already hosts one, so don't add another by hand.
 *
 * It does not add a status bar inset itself: the host decides based on whether it consumes systemBars.
 *
 * @param isRoot pass true for the main window's host, which always stays at the bottom of the stack.
 */
@Composable
fun GlobalToastHost(
    modifier: Modifier = Modifier,
    isRoot: Boolean = false,
    manager: GlobalSnackbarManager? = rememberGlobalSnackbarManager(),
) {
    manager ?: return
    val token = remember { Any() }
    DisposableEffect(manager, token, isRoot) {
        manager.attachHost(token, isRoot)
        onDispose { manager.detachHost(token) }
    }
    val topHost by manager.topHost.collectAsState()
    val active by manager.active.collectAsState()
    val current = active?.takeIf { topHost === token }
    var rendered by remember { mutableStateOf<GlobalSnackbarMessage?>(null) }

    LaunchedEffect(current) {
        val shown = current ?: return@LaunchedEffect
        rendered = shown.message
        delay(manager.remainingMillis(shown, TOAST_DURATION_MS))
        manager.dismiss(shown)
    }

    AnimatedVisibility(
        visible = current != null,
        modifier = modifier,
        // Slide in with a spring to match iOS spring(response 0.34, damping 0.82); fades stay short tweens
        enter = fadeIn(animationSpec = tween(220)) +
            slideInVertically(
                animationSpec = spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMediumLow),
                initialOffsetY = { -it },
            ),
        exit = fadeOut(animationSpec = tween(180)) + slideOutVertically(targetOffsetY = { -it }),
    ) {
        rendered?.let { msg ->
            ToastCapsule(
                message = msg,
                onActionClick = {
                    msg.action?.onClick?.invoke()
                    current?.let(manager::dismiss)
                },
            )
        }
    }
}

/**
 * Looks up the global toast manager during composition. It is null when Koin has not started (UI tests
 * without Koin, previews): no host is attached and toasts are dropped silently. Otherwise every
 * component test that contains a sheet or a link would have to start Koin first.
 */
@Composable
fun rememberGlobalSnackbarManager(): GlobalSnackbarManager? =
    remember { KoinPlatform.getKoinOrNull()?.getOrNull<GlobalSnackbarManager>() }

@Composable
private fun ToastCapsule(
    message: GlobalSnackbarMessage,
    onActionClick: () -> Unit = {},
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val accent = message.style.toastAccent(colors)
    val hasAction = message.action != null

    Row(
        modifier = Modifier
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm)
            .widthIn(max = 480.dp)
            .shadow(elevation = 10.dp, shape = GlobalToastShape, ambientColor = colors.shadow, spotColor = colors.shadow)
            // Android has no equivalent of the iOS regularMaterial blur, so a nearly opaque surface keeps it readable over any content
            .background(colors.surfaceElevated.copy(alpha = 0.96f), GlobalToastShape)
            .border(1.dp, colors.border, GlobalToastShape)
            // TalkBack announces system Toasts automatically; a custom capsule needs liveRegion to keep that
            .semantics { liveRegion = LiveRegionMode.Polite }
            .padding(start = 8.dp, end = if (hasAction) 14.dp else 16.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .background(accent.copy(alpha = 0.16f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = message.style.toastGlyph(),
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(13.dp),
            )
        }
        Text(
            text = message.message.resolve(context),
            style = OriveoTheme.typography.caption.copy(fontSize = 14.sp, fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = if (hasAction) Modifier.weight(1f, fill = false) else Modifier,
        )
        message.action?.let { action ->
            Box(
                modifier = Modifier
                    .width(1.dp)
                    .height(16.dp)
                    .background(colors.border),
            )
            Text(
                text = action.label.resolve(context),
                style = OriveoTheme.typography.caption.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = colors.primary,
                maxLines = 1,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { onActionClick() }
                    .padding(horizontal = 2.dp, vertical = 2.dp),
            )
        }
    }
}

/** Accent color of the round icon; one table on every platform (iOS `ToastCapsule.accent`). */
internal fun GlobalToastStyle.toastAccent(colors: OriveoColors): Color = when (this) {
    GlobalToastStyle.Success -> colors.success
    GlobalToastStyle.Error -> colors.danger
    GlobalToastStyle.Warning -> colors.warning
    GlobalToastStyle.Info -> colors.info
    GlobalToastStyle.Removed, GlobalToastStyle.Neutral -> colors.textSecondary
}

/** Glyph inside the circle, matching the iOS SF Symbols checkmark / xmark / exclamationmark / info / minus / bell.fill. */
internal fun GlobalToastStyle.toastGlyph(): ImageVector = when (this) {
    GlobalToastStyle.Success -> Icons.Rounded.Check
    GlobalToastStyle.Error -> Icons.Rounded.Close
    GlobalToastStyle.Warning -> Icons.Rounded.PriorityHigh
    GlobalToastStyle.Info -> ToastInfoGlyph
    GlobalToastStyle.Removed -> Icons.Rounded.Remove
    GlobalToastStyle.Neutral -> Icons.Rounded.Notifications
}

/**
 * A bare "i" glyph. Material's Info icon has its own ring, which inside a 24dp circle becomes a
 * ring in a ring and blurs at 13dp. The SF `info` symbol iOS uses is an i without a ring, so this
 * draws one in the same proportions (a dot on top plus a round-capped bar).
 */
private val ToastInfoGlyph: ImageVector by lazy {
    materialIcon(name = "Oriveo.ToastInfo") {
        materialPath {
            moveTo(12f, 4.25f)
            arcToRelative(2f, 2f, 0f, true, true, 0f, 4f)
            arcToRelative(2f, 2f, 0f, true, true, 0f, -4f)
            close()
            moveTo(10.25f, 11.75f)
            arcToRelative(1.75f, 1.75f, 0f, false, true, 3.5f, 0f)
            verticalLineToRelative(6.5f)
            arcToRelative(1.75f, 1.75f, 0f, false, true, -3.5f, 0f)
            close()
        }
    }
}
