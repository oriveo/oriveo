package ai.oriveo.community.feature.chat.voice

import androidx.annotation.VisibleForTesting
import androidx.compose.ui.text.TextLayoutResult
import android.icu.text.LocaleDisplayNames
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
import androidx.compose.runtime.DisposableEffect
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
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.recognitionLanguageRows
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.Locale
import kotlin.math.roundToInt
import org.koin.mp.KoinPlatform

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
 *
 * The recognition language sheet closes (unchanged, capture resumes) when the conversation ends or the switcher
 * leaves the composition. [languageSettings] overrides the
 * settings the chip and the sheet read (null = the Koin instance).
 */
@Composable
fun VoiceConversationSwitcher(
    handle: VoiceConversationHandle,
    modifier: Modifier = Modifier,
    barModifier: Modifier = Modifier,
    languageSettings: VoiceEngineSettings? = null,
    /** Test hook: layout of the stage's status line (see [VoiceConversationBar]). */
    @VisibleForTesting onStatusLayout: ((TextLayoutResult) -> Unit)? = null,
    /** Centered above the stage's orb (the home page's model pill, PM0 card A3); null = none. */
    stageHeader: (@Composable () -> Unit)? = null,
    normal: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }
    // E-690: switching engines ends the old session before the new one opens; the stage stays meanwhile.
    val switching = handle.switchingTo
    val inConversation = handle.status != null || switching != null
    // E-690: tell the host the notice reached the stage; it keeps the name until then.
    LaunchedEffect(switching) { if (switching != null) handle.switchNoticeShown(switching) }
    val progress = remember { Animatable(if (inConversation) 1f else 0f) }
    LaunchedEffect(inConversation) {
        if (!inConversation) handle.closeLanguagePicker(changed = false)
        progress.animateTo(if (inConversation) 1f else 0f, VoiceConversationTransition.spec(reduceMotion))
    }
    DisposableEffect(handle) {
        onDispose { handle.closeLanguagePicker(changed = false) }
    }
    val settings = languageSettings ?: remember { KoinPlatform.getKoinOrNull()?.getOrNull<VoiceEngineSettings>() }
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
        // The stage is taller than the input area: both sit on the bottom edge while they swap.
        contentAlignment = Alignment.BottomCenter,
    ) {
        if (showNormal) {
            Box(
                Modifier.graphicsLayer {
                    alpha = VoiceConversationTransition.frame(progress.value, reduceMotion, Offset.Zero).normalAlpha
                },
            ) {
                // PM1 card A4: a failure ends on the idle stage; the page's RealtimeVoiceDock shows its card.
                val idleFailure = handle.failure?.let { RealtimeIdleFailure(it, handle::perform) }
                CompositionLocalProvider(
                    LocalVoiceEntryAnchor provides anchor,
                    LocalRealtimeIdleFailure provides idleFailure,
                ) { normal() }
            }
        }
        if (showBar) {
            val status = handle.status ?: lastStatus[0] ?: ConversationStatusKey.LISTENING
            VoiceConversationBar(
                status = status,
                level = handle.level,
                caption = handle.caption,
                realtimeCaption = handle.realtimeCaption,
                page = handle.page,
                onEnd = handle.onEnd,
                onTapOrb = handle::tapOrb,
                onToggleMute = handle.onToggleMute,
                modifier = barModifier,
                motion = motion,
                userSpeaking = handle.userSpeaking,
                nudges = handle.nudges,
                languageName = if (status == ConversationStatusKey.CHECK_LANGUAGE) {
                    recognitionLanguageName(settings, refresh = handle.languagePickerOpen)
                } else {
                    null
                },
                onOpenLanguage = handle::openLanguagePicker,
                failure = handle.failure,
                onFailureAction = handle::perform,
                switchingTo = handle.switchingTo,
                onStatusLayout = onStatusLayout,
                header = stageHeader,
            )
        }
        if (handle.languagePickerOpen) {
            if (settings == null) {
                RecognitionLanguageSheet(onDismiss = handle::closeLanguagePicker)
            } else {
                RecognitionLanguageSheet(onDismiss = handle::closeLanguagePicker, settings = settings)
            }
        }
        if (showNormal && showBar && !reduceMotion) {
            // The ≋ glyph leaving its button and fading into the orb.
            val density = LocalDensity.current
            val half = with(density) { (GhostSize / 2).toPx() }
            Icon(
                imageVector = Icons.Rounded.GraphicEq,
                contentDescription = null,
                tint = ghostGlyphTint(OriveoTheme.colors, OriveoTheme.isDark),
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

/**
 * Saved recognition language under the same name as its row in the language sheet ([recognitionLanguageRows]); a
 * saved tag no row carries keeps its locale display name. null = no settings (e.g. previews), shown as automatic.
 * Re-read when [refresh] flips, i.e. after the sheet closes.
 */
@Composable
private fun recognitionLanguageName(settings: VoiceEngineSettings?, refresh: Boolean): String? {
    val context = LocalContext.current
    return remember(settings, refresh, context) {
        settings ?: return@remember null
        val tag = settings.recognitionLanguage()
        val row = recognitionLanguageRows(tag).firstOrNull { it.selected }
        when {
            row != null -> row.label.resolve(context)
            tag != null -> recognitionLanguageDisplayName(tag, context.resources.configuration.locales[0])
            else -> null
        }
    }
}

/**
 * A recognition language tag (BCP 47) no sheet row carries, named in [uiLocale] by ICU's CLDR display-name pattern
 * (as on iOS), first letter capitalized. A tag whose language the system cannot name stays
 * the raw tag (iOS systemLanguageName), never "Xx (United States)".
 */
internal fun recognitionLanguageDisplayName(tag: String, uiLocale: Locale): String {
    val locale = Locale.forLanguageTag(tag)
    val language = locale.language
    val names = LocaleDisplayNames.getInstance(uiLocale)
    val languageName = names.languageDisplayName(language).orEmpty()
    if (language.isEmpty() || languageName.isEmpty() || languageName.equals(language, ignoreCase = true)) return tag
    val name = names.localeDisplayName(locale).orEmpty().ifEmpty { return tag }
    return name.replaceFirstChar { it.titlecase(uiLocale) }
}

/** The flying ≋ crosses the page background, not the purple button: light-brand text-safe in light, the palette accent in dark. */
private fun ghostGlyphTint(colors: OriveoColors, isDark: Boolean): Color = if (isDark) colors.accent else colors.primaryTextSafe
