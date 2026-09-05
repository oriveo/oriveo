package ai.oriveo.community.feature.chat.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Shown when the conversation is still not readable after the load timeout, with a retry action.
 */
@Composable
internal fun ConversationStalledState(
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            imageVector = Icons.Outlined.WarningAmber,
            contentDescription = null,
            tint = colors.textTertiary,
            modifier = Modifier.size(32.dp),
        )

        Text(
            text = stringResource(R.string.chat_load_stalled_title),
            style = OriveoTheme.typography.title3,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )

        Text(
            text = stringResource(R.string.chat_load_stalled_message),
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )

        OriveoPrimaryButton(
            text = stringResource(R.string.retry),
            onClick = onRetry,
        )
    }
}

/**
 * The loading skeleton for a conversation whose messages have not arrived yet.
 *
 * @param showLabel whether to show the progress label above the placeholder bubbles.
 */
@Composable
internal fun ConversationBootstrapState(
    modifier: Modifier = Modifier,
    showLabel: Boolean = true,
) {
    val bubbleSpecs = remember {
        listOf(
            BootstrapBubbleSpec(Alignment.Start, 0.44f, 58.dp),
            BootstrapBubbleSpec(Alignment.End, 0.58f, 72.dp),
            BootstrapBubbleSpec(Alignment.Start, 0.36f, 48.dp),
            BootstrapBubbleSpec(Alignment.End, 0.52f, 64.dp),
        )
    }

    Box(
        modifier = modifier
            .verticalScroll(rememberScrollState()),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 420.dp)
                .padding(top = OriveoTheme.spacing.xl, bottom = OriveoTheme.spacing.xl),
            verticalArrangement = Arrangement.spacedBy(18.dp, Alignment.Bottom),
        ) {
            if (showLabel) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = OriveoTheme.colors.textTertiary,
                    )
                    Text(
                        text = stringResource(R.string.chat_bootstrap_in_progress),
                        style = OriveoTheme.typography.caption,
                        color = OriveoTheme.colors.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(start = OriveoTheme.spacing.sm),
                    )
                }
            }
            bubbleSpecs.forEach { spec ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = if (spec.alignment == Alignment.End) {
                        Arrangement.End
                    } else {
                        Arrangement.Start
                    },
                ) {
                    BootstrapBubble(
                        spec = spec,
                        modifier = Modifier
                            .fillMaxWidth(spec.widthFraction)
                            .widthIn(max = 560.dp * spec.widthFraction),
                    )
                }
            }
        }
    }
}

@Composable
private fun BootstrapBubble(
    spec: BootstrapBubbleSpec,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(22.dp)
    val fillColor = if (spec.alignment == Alignment.End) {
        colors.primary.copy(alpha = 0.08f)
    } else {
        colors.surfaceElevated
    }
    val shadowColor = colors.shadow.copy(alpha = colors.shadow.alpha * 0.5f)

    Column(
        modifier = modifier
            .heightIn(min = spec.minHeight)
            .shadow(
                elevation = if (isDark) 16.dp else 8.dp,
                shape = shape,
                ambientColor = shadowColor,
                spotColor = shadowColor,
            )
            .background(fillColor, shape)
            .border(OriveoBorderWidth.standard, colors.hairline, shape)
            .padding(horizontal = OriveoTheme.spacing.lg)
            .padding(vertical = OriveoTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        BootstrapLine(widthFraction = 0.68f)
        BootstrapLine(widthFraction = 0.92f)
        BootstrapLine(widthFraction = 0.54f)
    }
}

private data class BootstrapBubbleSpec(
    val alignment: Alignment.Horizontal,
    val widthFraction: Float,
    val minHeight: Dp,
)

@Composable
private fun BootstrapLine(widthFraction: Float) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth(widthFraction)
            .height(10.dp)
            .clip(RoundedCornerShape(percent = 100))
            .background(colors.textTertiary.copy(alpha = 0.12f)),
    )
}

/** Icon for the nth starter prompt: globe, envelope, code, sparkles. */
internal fun promptIcon(index: Int): ImageVector {
    val icons = listOf(
        Icons.Outlined.Language,   // globe
        Icons.Outlined.Email,      // envelope
        Icons.Outlined.Code,       // curlybraces
        Icons.Outlined.AutoAwesome, // sparkles
    )
    return icons[index % icons.size]
}
