package ai.oriveo.community.ui.component

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

/** Sizes for [OriveoBackButton] (shared with [OriveoCloseButton]). */
object OriveoBackButtonDefaults {
    /** Touch target (Material minimum). */
    val HitSize = 48.dp

    /** Icon box. */
    val IconSize = 22.dp

    /** How far the touch target extends past the icon box on each side; offset by it to line the icon up with the page margin. */
    val EdgeInset = (HitSize - IconSize) / 2
}

/**
 * The app-wide page back button: a bare chevron with no fill, border or shadow.
 *
 * Matches the iOS `OriveoBackButton`: 22dp icon, 24-grid path with a 2.2 stroke and round caps,
 * 48dp touch target, textPrimary, 50% icon opacity while pressed, unbounded ripple only.
 * The glyph is `R.drawable.ic_oriveo_back` (same path as iOS and web, auto-mirrored for RTL).
 *
 * It only owns the look; the caller passes the action (a plain pop, or a confirm-before-leave flow).
 *
 * Usage: `OriveoBackButton(onClick = onBack)`
 */
@Composable
fun OriveoBackButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    Box(
        modifier = modifier
            .size(OriveoBackButtonDefaults.HitSize)
            .clickable(
                interactionSource = interactionSource,
                indication = ripple(bounded = false, radius = OriveoBackButtonDefaults.HitSize / 2),
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painter = painterResource(R.drawable.ic_oriveo_back),
            contentDescription = stringResource(R.string.back),
            tint = OriveoTheme.colors.textPrimary,
            modifier = Modifier
                .size(OriveoBackButtonDefaults.IconSize)
                .alpha(if (isPressed) 0.5f else 1f),
        )
    }
}
