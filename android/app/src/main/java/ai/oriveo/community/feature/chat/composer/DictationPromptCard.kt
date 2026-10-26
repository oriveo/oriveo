package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.theme.OriveoTheme

internal const val DICTATION_CARD_TAG = "dictation_card"
internal const val DICTATION_CARD_SECONDARY_TAG = "dictation_card_secondary"
internal const val DICTATION_CARD_PRIMARY_TAG = "dictation_card_primary"
internal const val DICTATION_CARD_ICON_ERROR_TAG = "dictation_card_icon_error"
internal const val DICTATION_CARD_ICON_WAVEFORM_TAG = "dictation_card_icon_waveform"

/** Minimum touch target for the card buttons. */
private val CardButtonMinHeight = 44.dp

/**
 * Stateless dictation status card, iOS parity: leading status icon with
 * title and subtitle beside it, then trailing-aligned buttons — secondary as a gray text button,
 * primary as a brand capsule. Takes the card model from [dictationCard]; the host executes the
 * button actions (rule 5) and gives the horizontal inset, so the card matches the input width.
 */
@Composable
internal fun DictationPromptCard(
    card: DictationCard,
    onSecondary: () -> Unit,
    onPrimary: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    OriveoCard(
        modifier = modifier
            .fillMaxWidth()
            .testTag(DICTATION_CARD_TAG)
            .padding(vertical = spacing.sm),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
            Row(horizontalArrangement = Arrangement.spacedBy(spacing.md)) {
                card.icon?.let { DictationCardStatusIcon(it) }
                Column(verticalArrangement = Arrangement.spacedBy(spacing.xs)) {
                    Text(
                        text = stringResource(card.title),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )
                    Text(
                        text = card.subtitle.resolve(),
                        style = OriveoTheme.typography.caption,
                        color = colors.textSecondary,
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(spacing.sm, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CardButton(
                    text = stringResource(card.secondary.label),
                    onClick = onSecondary,
                    textColor = colors.textSecondary,
                    fill = null,
                    modifier = Modifier.testTag(DICTATION_CARD_SECONDARY_TAG),
                )
                CardButton(
                    text = stringResource(card.primary.label),
                    onClick = onPrimary,
                    textColor = colors.textInverse,
                    fill = colors.primaryTextSafe,
                    modifier = Modifier.testTag(DICTATION_CARD_PRIMARY_TAG),
                )
            }
        }
    }
}

@Composable
private fun DictationCardStatusIcon(icon: DictationCardIcon) {
    val colors = OriveoTheme.colors
    val (vector, tint, tag) =
        when (icon) {
            DictationCardIcon.Error -> Triple(Icons.Rounded.Error, colors.error, DICTATION_CARD_ICON_ERROR_TAG)
            DictationCardIcon.Waveform ->
                Triple(Icons.Rounded.GraphicEq, colors.primary, DICTATION_CARD_ICON_WAVEFORM_TAG)
        }
    // The title already says what happened; the icon is decorative.
    Icon(
        imageVector = vector,
        contentDescription = null,
        tint = tint,
        modifier = Modifier.size(22.dp).testTag(tag),
    )
}

/** Hugs its label; [fill] null = plain text button, otherwise a filled capsule. */
@Composable
private fun CardButton(
    text: String,
    onClick: () -> Unit,
    textColor: Color,
    fill: Color?,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .heightIn(min = CardButtonMinHeight)
            .clip(CircleShape)
            .then(if (fill != null) Modifier.background(fill) else Modifier)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.lg),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = OriveoTheme.typography.body,
            fontWeight = FontWeight.SemiBold,
            color = textColor,
        )
    }
}

@Composable
private fun DictationText.resolve(): String =
    if (args.isEmpty()) stringResource(res) else stringResource(res, *args.toTypedArray())
