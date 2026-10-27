package ai.oriveo.community.feature.chat.composer

import androidx.annotation.StringRes
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material3.Icon
import ai.oriveo.community.feature.chat.voice.voiceEntryAnchor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Send / stop button, equivalent to iOS `ChatComposerBar.composerActionCluster` (a single 40dp circle).
 *
 * States:
 * - Empty input: flat lavender circle with a textTertiary up arrow (no white fill, gray border or shadow; scale 0.96).
 * - Has content: lit up as a primaryGradient purple circle with a white arrow and primaryGlow shadow (the only
 *   highlighted primary action; scale 1).
 * - Generating: danger circle with a white Stop.
 * - Empty draft and the model can produce text ([voiceAvailable]): the same solid purple key as the content state,
 *   with the icon swapped for a white waveform; tapping calls [onStartVoice]. After the stop square turns back into
 *   the waveform, taps are ignored for [ComposerVoiceEntry.REARM_MILLIS].
 *   The waveform / arrow / stop square only morph the icon ([MainButtonGlyph]); the key is never rebuilt.
 */
@Composable
internal fun ComposerActionCluster(
    isGenerating: Boolean,
    isPrimed: Boolean,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    voiceAvailable: Boolean = false,
    onStartVoice: () -> Unit = {},
    clock: () -> Long = { android.os.SystemClock.uptimeMillis() },
    onClick: () -> Unit,
) {
    val mode = ComposerVoiceEntry.mode(isGenerating = isGenerating, hasContent = isPrimed, voiceAvailable = voiceAvailable)
    val isVoice = mode == ComposerActionMode.Voice
    // The waveform key and the up arrow are both the solid purple primary action
    val isLit = isPrimed || isVoice
    val rearmGuard = remember { VoiceEntryRearmGuard(clock) }
    rearmGuard.observe(isGenerating)
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()

    // Matches iOS: scaleEffect(0.96) when empty; scales up to 1 with content or while generating (a press shrinks it slightly to 0.97).
    val baseScale by animateFloatAsState(if (isLit || isGenerating) 1f else 0.96f, label = "sendBaseScale")
    val pressScale by animateFloatAsState(if (pressed) 0.97f else 1f, label = "sendPressScale")

    // Uniform flat lavender base (same as the top bar / attachment button): light brand purple@12% / dark white@10%.
    val flatFill = composerFlatFill(isDark, OriveoTheme.colors.primary)
    val background: Brush = when {
        isGenerating -> SolidColor(colors.danger)
        isLit -> OriveoGradients.primary
        else -> SolidColor(flatFill)
    }
    // While generating, the solid danger fill keeps white; the lit state sits on the brand gradient and uses onPrimary in dark
    val iconTint = when {
        isGenerating -> Color.White
        isLit -> OriveoGradients.onPrimary
        else -> colors.textTertiary
    }
    val borderColor = if (isLit || isGenerating) colors.hairline else Color.Transparent
    val glowColor = when {
        isGenerating -> colors.danger.copy(alpha = 0.22f)
        isLit -> colors.primaryGlow
        else -> Color.Transparent
    }
    val elevation = if (isLit || isGenerating) 10.dp else 0.dp

    Box(
        modifier = modifier
            // The voice transition starts and ends at this button.
            .voiceEntryAnchor()
            .size(40.dp)
            .graphicsLayer {
                val s = baseScale * pressScale
                scaleX = s
                scaleY = s
            }
            .shadow(elevation = elevation, shape = CircleShape, ambientColor = glowColor, spotColor = glowColor)
            .clip(CircleShape)
            .background(background, CircleShape)
            .then(
                if (borderColor != Color.Transparent) {
                    Modifier.border(OriveoBorderWidth.standard, borderColor, CircleShape)
                } else {
                    Modifier
                },
            )
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = {
                    if (!isVoice) onClick() else if (rearmGuard.accepts()) onStartVoice()
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        // The waveform / arrow / stop icons are stacked and each reads its enter / exit progress only inside graphicsLayer: during the morph only layer properties change per frame, with no recomposition.
        // The previous AnimatedContent recomposed AnimatedContentImpl / AnimatedEnterExitImpl on every frame of the morph: pasting
        // an over-limit long text into an empty draft raised Compose recompositions 9 to 13 and applyChanges 7 to 11, pasteOverLimit60k P90 +6 to 11%.
        MainButtonGlyph(ComposerActionMode.Send, Icons.Filled.ArrowUpward, R.string.send, 16, mode, iconTint)
        MainButtonGlyph(ComposerActionMode.Voice, Icons.Rounded.GraphicEq, R.string.voice_conversation_start_a11y, 18, mode, iconTint)
        MainButtonGlyph(ComposerActionMode.Stop, Icons.Filled.Stop, R.string.stop, 15, mode, iconTint)
    }
}

/**
 * One icon on the main key. The morph spec matches the original AnimatedContent: the new icon scales up from 0.6 and fades in over 180ms, the old icon shrinks to 0.6 and fades out over 120ms,
 * and it switches instantly when system animations are off (animator scale). [ComposerActionMode.Idle] and Send are both the up arrow.
 * Only the current icon carries a contentDescription; the two stacked below are invisible to accessibility.
 */
@Composable
private fun MainButtonGlyph(
    glyph: ComposerActionMode,
    icon: ImageVector,
    @StringRes descriptionRes: Int,
    sizeDp: Int,
    mode: ComposerActionMode,
    tint: Color,
) {
    val active = glyph == if (mode == ComposerActionMode.Idle) ComposerActionMode.Send else mode
    val progress = animateFloatAsState(
        targetValue = if (active) 1f else 0f,
        animationSpec = tween(if (active) GLYPH_ENTER_MILLIS else GLYPH_EXIT_MILLIS),
        label = "mainButtonGlyph",
    )
    Icon(
        imageVector = icon,
        contentDescription = if (active) stringResource(descriptionRes) else null,
        modifier = Modifier
            .size(sizeDp.dp)
            .graphicsLayer {
                val p = progress.value
                alpha = p
                val scale = GLYPH_MIN_SCALE + (1f - GLYPH_MIN_SCALE) * p
                scaleX = scale
                scaleY = scale
            },
        tint = tint,
    )
}

private const val GLYPH_ENTER_MILLIS = 180
private const val GLYPH_EXIT_MILLIS = 120
private const val GLYPH_MIN_SCALE = 0.6f

/** Flat lavender base of the idle main button: light = the palette's light-brand ink ([lightPrimary]) @ 12%, dark white @ 10%. */
internal fun composerFlatFill(isDark: Boolean, lightPrimary: Color = LightOriveoColors.primary): Color =
    if (isDark) Color.White.copy(alpha = 0.10f) else lightPrimary.copy(alpha = 0.12f)
