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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * The app-wide close button: a bare ×, no fill, border or shadow, same spec as [OriveoBackButton].
 *
 * Matches the iOS `OriveoCloseButton`: 24-grid path `M7 7l10 10M17 7L7 17` with a 2 stroke,
 * 48dp touch target, textPrimary by default, 50% icon opacity while pressed, unbounded ripple only.
 * Panels with their own palette pass [tint]. To line the icon up with the trailing margin,
 * use `Modifier.offset(x = OriveoBackButtonDefaults.EdgeInset)`.
 */
@Composable
fun OriveoCloseButton(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    tint: Color = OriveoTheme.colors.textPrimary,
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
            painter = painterResource(R.drawable.ic_oriveo_close),
            contentDescription = contentDescription,
            tint = tint,
            modifier = Modifier
                .size(OriveoBackButtonDefaults.IconSize)
                .alpha(if (isPressed) 0.5f else 1f),
        )
    }
}
