package ai.oriveo.community.feature.chat.voice

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlin.math.roundToInt

/**
 * Window position of the page's ≋ button (its center), written by the button on layout and read by the
 * transition as the orb's start / end point. A plain field, not state: writing it never recomposes anything.
 */
class VoiceEntryAnchor {
    var center: Offset? = null
}

/** Provided by [VoiceConversationSwitcher] around the page's normal input area; null elsewhere. */
val LocalVoiceEntryAnchor = staticCompositionLocalOf<VoiceEntryAnchor?> { null }

/** Where the bar's orb sits (window center), reported by the bar on layout; plain field like [VoiceEntryAnchor]. */
class VoiceBarMotion internal constructor(
    internal val progress: () -> Float,
    internal val reduceMotion: Boolean,
    internal val travel: () -> Offset,
) {
    internal var orbCenter: Offset? = null

    internal fun frame(): VoiceTransitionFrame = VoiceConversationTransition.frame(progress(), reduceMotion, travel())
}

/** One frame of the transition at progress [p] (0 = normal input area, 1 = voice bar). */
data class VoiceTransitionFrame(
    val normalAlpha: Float,
    val barAlpha: Float,
    val sideScale: Float,
    val orbOffset: Offset,
    val ghostAlpha: Float,
    val ghostOffset: Offset,
)

object VoiceConversationTransition {
    /**
     * spring: response 0.35 s, damping 0.85 (SwiftUI `.spring(response:dampingFraction:)`).
     * Compose `spring(stiffness, dampingRatio)` with unit mass: stiffness = (2π / response)² = (2π / 0.35)² ≈ 322.3,
     * dampingRatio = dampingFraction = 0.85.
     */
    const val SPRING_STIFFNESS = 322.3f
    const val SPRING_DAMPING_RATIO = 0.85f

    /** System animations off: a plain 200 ms cross-fade. */
    const val REDUCED_FADE_MS = 200

    /** Finite specs only: the transition never registers an infinite animation. */
    fun spec(reduceMotion: Boolean): AnimationSpec<Float> = if (reduceMotion) {
        tween(REDUCED_FADE_MS, easing = LinearEasing)
    } else {
        spring(dampingRatio = SPRING_DAMPING_RATIO, stiffness = SPRING_STIFFNESS)
    }

    /**
     * Entering (p 0 → 1): ≋ travels from its button to the orb's place and fades into the orb ([ghostOffset] /
     * [orbOffset] cover the same path), the input area with its chip row fades out, ✕ and mute scale + fade in.
     * Leaving runs the same frames backwards. With reduced motion only the two layers cross-fade.
     * [travel] = ≋ center − orb center (px).
     */
    fun frame(p: Float, reduceMotion: Boolean, travel: Offset): VoiceTransitionFrame {
        val fade = p.coerceIn(0f, 1f)
        if (reduceMotion) {
            return VoiceTransitionFrame(
                normalAlpha = 1f - fade,
                barAlpha = fade,
                sideScale = 1f,
                orbOffset = Offset.Zero,
                ghostAlpha = 0f,
                ghostOffset = Offset.Zero,
            )
        }
        return VoiceTransitionFrame(
            normalAlpha = 1f - fade,
            barAlpha = fade,
            // The spring may overshoot a little: ✕ and mute settle with it.
            sideScale = 0.6f + 0.4f * p,
            orbOffset = travel * (1f - p),
            ghostAlpha = 1f - fade,
            ghostOffset = -travel * p,
        )
    }
}

/**
 * Swaps the page's input area and the voice bar with one choreographed transition (see
 * [VoiceConversationTransition.frame]); the reverse on leaving. Both layers are composed only while the transition
 * runs; every per-frame value is read in the draw phase.
 */
@Composable
fun VoiceConversationSwitcher(
    handle: VoiceConversationHandle,
    modifier: Modifier = Modifier,
    barModifier: Modifier = Modifier,
    normal: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    val inConversation = handle.status != null
    val progress = remember { Animatable(if (inConversation) 1f else 0f) }
    LaunchedEffect(inConversation) {
        progress.animateTo(if (inConversation) 1f else 0f, VoiceConversationTransition.spec(reduceMotion))
    }
    // The bar keeps the last status while it leaves.
    val lastStatus = remember { arrayOfNulls<ConversationStatusKey>(1) }
    handle.status?.let { lastStatus[0] = it }

    val anchor = remember { VoiceEntryAnchor() }
    val origin = remember { arrayOf(Offset.Zero) }
    val motion = remember(reduceMotion) {
        lateinit var self: VoiceBarMotion
        self = VoiceBarMotion(
            progress = { progress.value },
            reduceMotion = reduceMotion,
            travel = {
                val from = anchor.center
                val to = self.orbCenter
                if (from == null || to == null) Offset.Zero else from - to
            },
        )
        self
    }
    val showNormal by remember { derivedStateOf { progress.value < 1f || progress.targetValue < 1f } }
    val showBar by remember { derivedStateOf { progress.value > 0f || progress.targetValue > 0f } }

    Box(
        modifier = modifier.onGloballyPositioned { origin[0] = it.positionInWindow() },
        contentAlignment = Alignment.Center,
    ) {
        if (showNormal) {
            Box(
                Modifier.graphicsLayer {
                    alpha = VoiceConversationTransition.frame(progress.value, reduceMotion, Offset.Zero).normalAlpha
                },
            ) {
                CompositionLocalProvider(LocalVoiceEntryAnchor provides anchor) { normal() }
            }
        }
        if (showBar) {
            VoiceConversationBar(
                status = handle.status ?: lastStatus[0] ?: ConversationStatusKey.LISTENING,
                level = handle.level,
                page = handle.page,
                onEnd = handle.onEnd,
                onTapOrb = handle.onTapOrb,
                onToggleMute = handle.onToggleMute,
                modifier = barModifier,
                motion = motion,
            )
        }
        if (showNormal && showBar && !reduceMotion) {
            // The ≋ glyph leaving its button and fading into the orb.
            val density = LocalDensity.current
            val half = with(density) { (GhostSize / 2).toPx() }
            Icon(
                imageVector = Icons.Rounded.GraphicEq,
                contentDescription = null,
                tint = ghostGlyphTint(OriveoTheme.isDark),
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .offset {
                        val start = anchor.center ?: return@offset IntOffset(-10_000, -10_000)
                        val frame = VoiceConversationTransition.frame(progress.value, false, motion.travel())
                        val at = start + frame.ghostOffset - origin[0]
                        IntOffset((at.x - half).roundToInt(), (at.y - half).roundToInt())
                    }
                    .size(GhostSize)
                    .graphicsLayer {
                        alpha = VoiceConversationTransition.frame(progress.value, false, Offset.Zero).ghostAlpha
                    },
            )
        }
    }
}

/** Reports the ≋ button's window center to the enclosing [VoiceConversationSwitcher] (no-op outside one). */
@Composable
fun Modifier.voiceEntryAnchor(): Modifier {
    val anchor = LocalVoiceEntryAnchor.current ?: return this
    return onGloballyPositioned { anchor.center = it.boundsInWindow().center }
}

private val GhostSize = 18.dp

/** The flying ≋ crosses the page background, not the purple button: deep purple in light, light purple in dark. */
private fun ghostGlyphTint(isDark: Boolean): Color = if (isDark) Color(0xFFC4B5FD) else Color(0xFF6D28D9)
