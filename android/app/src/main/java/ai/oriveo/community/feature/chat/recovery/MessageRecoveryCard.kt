package ai.oriveo.community.feature.chat.recovery

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.OriveoTextButton
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Maps the English error key that was persisted with the message to a localized title.
 *
 * This delegates to [ErrorMapper.localizeProviderErrorTitle] rather than keeping a second lookup
 * table here. A local copy has to be kept in step with the mapper by hand, and it also misses the
 * titles that interpolate a status code, such as `Relay Error (502)`: an exact-match table cannot
 * express those, so relay failures showed up untranslated inside the recovery card.
 */
@Composable
internal fun localizedErrorTitle(key: String?): String {
    val context = LocalContext.current
    return key?.let { ErrorMapper.localizeProviderErrorTitle(it, context) }
        ?: stringResource(R.string.message_failed)
}

@Composable
internal fun MessageRecoveryCard(
    title: String,
    message: String,
    tone: StatusTone,
    technicalDetail: String?,
    primaryTitle: String,
    secondaryTitle: String?,
    tertiaryTitle: String?,
    onPrimary: () -> Unit,
    onSecondary: (() -> Unit)?,
    onTertiary: (() -> Unit)?,
    actionsEnabled: Boolean,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    var showTechnicalDetail by remember { mutableStateOf(false) }
    val toneForeground = tone.foreground()
    val toneBackground = tone.background()
    val icon = if (tone == StatusTone.Danger) Icons.Filled.Error else Icons.Filled.Info

    OriveoCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .padding(top = OriveoTheme.spacing.sm),
        fillColor = toneBackground,
        borderColor = toneForeground.copy(alpha = 0.24f),
        shadowStyle = OriveoSurfaceStyle.Soft,
    ) {
        Box {
            Column(
                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                        tint = toneForeground,
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = title,
                            style = OriveoTheme.typography.title3,
                            color = colors.textPrimary,
                            // Leave room for the dismiss button pinned to the top-right corner.
                            modifier = Modifier.padding(end = 28.dp),
                        )
                        Text(
                            text = message,
                            style = OriveoTheme.typography.body,
                            color = colors.textSecondary,
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                ) {
                    OriveoPrimaryButton(
                        text = primaryTitle,
                        onClick = onPrimary,
                        modifier = Modifier.weight(1f),
                        enabled = actionsEnabled,
                    )
                    if (!secondaryTitle.isNullOrBlank() && onSecondary != null) {
                        OriveoSecondaryButton(
                            text = secondaryTitle,
                            onClick = onSecondary,
                            modifier = Modifier.weight(1f),
                            enabled = actionsEnabled,
                        )
                    }
                }

                if (!tertiaryTitle.isNullOrBlank() && onTertiary != null) {
                    OriveoTextButton(
                        text = tertiaryTitle,
                        onClick = onTertiary,
                        enabled = actionsEnabled,
                    )
                }

                if (!technicalDetail.isNullOrBlank()) {
                    Row(
                        modifier = Modifier.clickable { showTechnicalDetail = !showTechnicalDetail },
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        OriveoTextButton(
                            text = stringResource(R.string.technical_details),
                            onClick = { showTechnicalDetail = !showTechnicalDetail },
                        )
                        Icon(
                            imageVector = if (showTechnicalDetail) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                            tint = colors.textSecondary,
                        )
                    }

                    AnimatedVisibility(visible = showTechnicalDetail) {
                        Text(
                            text = technicalDetail,
                            style = OriveoTheme.typography.code,
                            color = colors.textSecondary,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(OriveoTheme.spacing.sm))
                                .background(colors.surfaceInset)
                                .border(OriveoBorderWidth.standard, colors.border, RoundedCornerShape(OriveoTheme.spacing.sm))
                                .padding(OriveoTheme.spacing.md),
                        )
                    }
                }
            }

            // The dismiss button lives inside the card rather than floating above it, so it cannot
            // overlap whatever the message list draws next.
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(32.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                    tint = colors.textTertiary,
                )
            }
        }
    }
}

// -- Previews --
//
// Layout check for the worst case a translation can produce: a four-line body, an expanded
// technical detail block and all three actions, at a 360dp width. The card must grow to fit,
// without clipping and without overlapping what follows it.
//
// Nothing inside the card constrains height (no height(), heightIn() or maxLines), and the host
// draws it as an ordinary sibling in the same Column, so LazyColumn measures the real height
// instead of working from a cached estimate.

@Preview(showBackground = true, widthDp = 360)
@Composable
private fun MessageRecoveryCardLongBodyPreview() {
    OriveoTheme {
        Column {
            MessageRecoveryCard(
                title = "The provider rejected this request",
                message = "This model is rate limited on your key right now. Wait a moment and try " +
                    "again, or switch to another model to keep going without waiting for the " +
                    "limit window to reset.",
                tone = StatusTone.Danger,
                technicalDetail = "HTTP 429 / rate_limit_exceeded / retry-after: 5400",
                primaryTitle = "Try again",
                secondaryTitle = "Edit message",
                tertiaryTitle = "Switch model",
                onPrimary = {},
                onSecondary = {},
                onTertiary = {},
                actionsEnabled = true,
                onDismiss = {},
            )
            MessageRecoveryCard(
                title = "Generation stopped",
                message = "The reply was interrupted before the model finished writing it. Continue " +
                    "from where it stopped, or regenerate the whole answer from the original " +
                    "prompt.",
                tone = StatusTone.Warning,
                technicalDetail = null,
                primaryTitle = "Continue",
                secondaryTitle = null,
                tertiaryTitle = null,
                onPrimary = {},
                onSecondary = null,
                onTertiary = null,
                actionsEnabled = true,
                onDismiss = {},
            )
        }
    }
}
