package ai.oriveo.community.feature.chat.voice

import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.TweenSpec
import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.math.PI
import kotlin.math.pow
import java.util.Locale

/** The transition on the production frame / spec functions. */
// Robolectric: language names come from android.icu (CLDR display names); plain JVM only has stubs.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class VoiceConversationTransitionTest {
    private val travel = Offset(120f, 8f)

    @Test
    fun `a saved tag whose language the system cannot name stays the raw tag, a known one gets the system name`() {
        // Same as iOS systemLanguageName: when the system does not recognize the language part, fall back to the raw code instead of building "Xx (United States)"
        assertEquals("xx-YY", recognitionLanguageDisplayName("xx-YY", Locale.ENGLISH))
        assertEquals("English (United States)", recognitionLanguageDisplayName("en-US", Locale.ENGLISH))
        assertEquals("Japanese", recognitionLanguageDisplayName("ja", Locale.ENGLISH))
    }

    @Test
    fun `the system name follows the CLDR display pattern like iOS`() {
        // Same as iOS: the zh UI wraps the region in full-width parentheses, while the en UI uses "English (United States)"
        assertEquals("\u82F1\u8BED\uFF08\u7F8E\u56FD\uFF09", recognitionLanguageDisplayName("en-US", Locale.forLanguageTag("zh-Hans")))
        assertEquals("English (United States)", recognitionLanguageDisplayName("en-US", Locale.forLanguageTag("en")))
        assertEquals("xx-YY", recognitionLanguageDisplayName("xx-YY", Locale.forLanguageTag("zh-Hans")))
    }

    @Test
    fun `spring follows response 0_35 and damping 0_85, reduced motion is a 200 ms fade`() {
        val spring = VoiceConversationTransition.spec(reduceMotion = false) as SpringSpec<Float>
        assertEquals(0.85f, spring.dampingRatio, 1e-6f)
        assertEquals((2 * PI / 0.35).pow(2).toFloat(), spring.stiffness, 0.5f)
        val fade = VoiceConversationTransition.spec(reduceMotion = true) as TweenSpec<Float>
        assertEquals(200, fade.durationMillis)
    }

    @Test
    fun `entering moves the voice glyph to the orb, fades the input area and scales the side buttons in`() {
        val start = VoiceConversationTransition.frame(0f, reduceMotion = false, travel = travel)
        assertEquals(1f, start.normalAlpha)
        assertEquals(0f, start.barAlpha)
        assertEquals(0.6f, start.sideScale)
        assertEquals("orb starts at the ≋ button", travel, start.orbOffset)
        assertEquals(1f, start.ghostAlpha)
        // -0.0 and 0.0 differ for Offset equality: compare numerically.
        assertEquals(0f, start.ghostOffset.x, 1e-6f)
        assertEquals(0f, start.ghostOffset.y, 1e-6f)

        val mid = VoiceConversationTransition.frame(0.5f, reduceMotion = false, travel = travel)
        assertEquals("glyph and orb share the path", mid.orbOffset, travel + mid.ghostOffset)
        assertTrue(mid.sideScale in 0.6f..1f)

        val end = VoiceConversationTransition.frame(1f, reduceMotion = false, travel = travel)
        assertEquals(0f, end.normalAlpha)
        assertEquals(1f, end.barAlpha)
        assertEquals(1f, end.sideScale)
        assertEquals(Offset.Zero, end.orbOffset)
        assertEquals(0f, end.ghostAlpha)
        // Leaving runs the same frames backwards (progress 1 → 0).
    }

    @Test
    fun `reduced motion only cross-fades`() {
        for (p in listOf(0f, 0.3f, 0.7f, 1f)) {
            val f = VoiceConversationTransition.frame(p, reduceMotion = true, travel = travel)
            assertEquals(1f - p, f.normalAlpha, 1e-6f)
            assertEquals(p, f.barAlpha, 1e-6f)
            assertEquals(1f, f.sideScale)
            assertEquals(Offset.Zero, f.orbOffset)
            assertEquals(0f, f.ghostAlpha)
        }
    }

    @Test
    fun `spring overshoot never pushes the fades out of range`() {
        val f = VoiceConversationTransition.frame(1.04f, reduceMotion = false, travel = travel)
        assertEquals(1f, f.barAlpha)
        assertEquals(0f, f.normalAlpha)
    }
}
