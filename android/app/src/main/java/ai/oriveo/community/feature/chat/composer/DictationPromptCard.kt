package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import ai.oriveo.community.feature.chat.voice.VoiceGlyphs
import ai.oriveo.community.ui.theme.OriveoTheme

internal const val DICTATION_CARD_TAG = "dictation_card"
internal const val DICTATION_CARD_SECONDARY_TAG = "dictation_card_secondary"
internal const val DICTATION_CARD_PRIMARY_TAG = "dictation_card_primary"
internal const val DICTATION_CARD_ICON_ERROR_TAG = "dictation_card_icon_error"
internal const val DICTATION_CARD_ICON_WAVEFORM_TAG = "dictation_card_icon_waveform"

/** v3 floating card geometry (S4 dictation contract rule 5). */
internal val DictationCardPadding = 18.dp
internal val DictationCardButtonHeight = 40.dp
private val DictationCardShape = RoundedCornerShape(24.dp)
private val DictationCardButtonShape = RoundedCornerShape(20.dp)
private val DictationCardIconSize = 40.dp

/**
 * Stateless dictation status card, v3 floating card: leading status badge with
 * title and subtitle beside it, then trailing-aligned capsule buttons — secondary on a neutral fill,
 * primary on the brand gradient. Takes the card model from [dictationCard]; the host executes the
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
    val isDark = OriveoTheme.isDark
    val spacing = OriveoTheme.spacing
    val shadow = if (isDark) {
        Modifier
    } else {
        Modifier.dropShadow(
            shape = DictationCardShape,
            shadow = Shadow(radius = 34.dp, color = Color(0xFF0F172A).copy(alpha = 0.10f), offset = DpOffset(0.dp, 14.dp)),
        )
    }
    val hairline = if (isDark) Color.White.copy(alpha = 0.10f) else Color(0xFF0F172A).copy(alpha = 0.08f)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .testTag(DICTATION_CARD_TAG)
            .padding(vertical = spacing.sm)
            .then(shadow)
            .clip(DictationCardShape)
            .background(colors.surfaceElevated, DictationCardShape)
            .border(0.5.dp, hairline, DictationCardShape)
            .padding(DictationCardPadding),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                card.icon?.let { DictationCardStatusIcon(it) }
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = card.title.resolve(),
                        style = TextStyle(
                            fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = (-0.3).sp,
                            color = colors.textPrimary,
                        ),
                    )
                    card.subtitle?.let { subtitle ->
                        Text(
                            text = subtitle.resolve(),
                            style = TextStyle(
                                fontSize = 14.5.sp,
                                lineHeight = 1.5.em,
                                color = if (isDark) Color(0xFFB3B3BA) else Color(0xFF52525B),
                            ),
                        )
                    }
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CardButton(
                    text = stringResource(card.secondary.label),
                    onClick = onSecondary,
                    textColor = if (isDark) Color(0xFFEDEDEF) else Color(0xFF3F3F46),
                    fill = SolidColor(if (isDark) Color.White.copy(alpha = 0.10f) else Color(0xFFF2F2F5)),
                    modifier = Modifier
                        .testTag(DICTATION_CARD_SECONDARY_TAG),
                )
                CardButton(
                    text = stringResource(card.primary.label),
                    onClick = onPrimary,
                    textColor = Color.White,
                    fill = DictationBrandGradient,
                    shadow = Shadow(radius = 14.dp, color = Color(0xFF7C3AED).copy(alpha = 0.28f), offset = DpOffset(0.dp, 6.dp)), // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour
                    modifier = Modifier
                        .testTag(DICTATION_CARD_PRIMARY_TAG),
                )
            }
        }
    }
}

/** 40 round amber badge with the graphic-eq glyph; the tag keeps the error / waveform distinction. */
@Composable
private fun DictationCardStatusIcon(icon: DictationCardIcon) {
    val isDark = OriveoTheme.isDark
    val tag = when (icon) {
        DictationCardIcon.Error -> DICTATION_CARD_ICON_ERROR_TAG
        DictationCardIcon.Waveform -> DICTATION_CARD_ICON_WAVEFORM_TAG
    }
    val badge = if (isDark) {
        Modifier.background(Color(0xFFF59E0B).copy(alpha = 0.18f), CircleShape)
    } else {
        Modifier
            .background(Brush.verticalGradient(listOf(Color(0xFFFFF4E5), Color(0xFFFFE7C7))), CircleShape)
            .border(0.5.dp, Color(0xFFB45309).copy(alpha = 0.18f), CircleShape)
    }
    Box(
        modifier = Modifier.size(DictationCardIconSize).clip(CircleShape).then(badge),
        contentAlignment = Alignment.Center,
    ) {
        // The title already says what happened; the icon is decorative.
        Icon(
            painter = painterResource(VoiceGlyphs.graphicEq),
            contentDescription = null,
            tint = if (isDark) Color(0xFFFCD34D) else Color(0xFFC2410C),
            modifier = Modifier.size(19.dp).testTag(tag),
        )
    }
}

/** Hugs its label: capsule at least 40 high on [fill] (8 above and below the label), optionally lifted by [shadow]. */
@Composable
private fun CardButton(
    text: String,
    onClick: () -> Unit,
    textColor: Color,
    fill: Brush,
    modifier: Modifier = Modifier,
    shadow: Shadow? = null,
) {
    Box(
        modifier = modifier
            .heightIn(min = DictationCardButtonHeight)
            .then(if (shadow != null) Modifier.dropShadow(shape = DictationCardButtonShape, shadow = shadow) else Modifier)
            .clip(DictationCardButtonShape)
            .background(fill, DictationCardButtonShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = textColor),
            maxLines = 1,
        )
    }
}

@Composable
private fun DictationText.resolve(): String =
    if (args.isEmpty()) stringResource(res) else stringResource(res, *args.toTypedArray())
