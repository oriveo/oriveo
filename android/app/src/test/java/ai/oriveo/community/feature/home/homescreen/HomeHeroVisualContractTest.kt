package ai.oriveo.community.feature.home.homescreen

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp
import ai.oriveo.community.feature.home.AuroraHeroCardAppearance
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.auroraCssShadowRadius
import ai.oriveo.community.feature.home.auroraHeroRimBrush
import ai.oriveo.community.feature.home.homeHeroPillModelName
import ai.oriveo.community.feature.notes.homeNotesAccessibilityText
import ai.oriveo.community.feature.notes.homeNotesPreviewLine
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contracts for the home hero, greeting and Notes entry.
 * Pure functions are asserted on their values; only structural rules ("must not regress to the old style")
 * read the source.
 */
class HomeHeroVisualContractTest {

    @Test
    fun `hero idle is flat and only focus lights the aurora ring`() {
        val darkIdle = AuroraHeroCardAppearance.resolve(isDark = true, focused = false)
        val darkFocused = AuroraHeroCardAppearance.resolve(isDark = true, focused = true)
        val lightIdle = AuroraHeroCardAppearance.resolve(isDark = false, focused = false)
        val lightFocused = AuroraHeroCardAppearance.resolve(isDark = false, focused = true)

        // Idle: 1dp stroke, no aurora ring; focused: aurora ring, stroke hidden
        listOf(darkIdle, lightIdle).forEach {
            assertFalse(it.showsGlowBorder)
            assertTrue(it.showsHairlineBorder)
        }
        listOf(darkFocused, lightFocused).forEach {
            assertTrue(it.showsGlowBorder)
            assertFalse(it.showsHairlineBorder)
        }

        // Dark: 0 12 28 -6 rgba(0,0,0,.36), unchanged on focus
        assertNull(darkIdle.contactShadow)
        assertEquals(
            AuroraHeroCardAppearance.CardShadow(Color.Black.copy(alpha = 0.36f), 28.dp, 12.dp, spread = (-6).dp),
            darkIdle.ambientShadow,
        )
        assertEquals(darkIdle.ambientShadow, darkFocused.ambientShadow)
        // Light idle: 0 1 2 rgba(15,23,42,.04) + 0 10 28 rgba(139,92,246,.08); light focused: 0 14 40 rgba(139,92,246,.16)
        assertEquals(AuroraHeroCardAppearance.CardShadow(Color(0xFF0F172A).copy(alpha = 0.04f), 2.dp, 1.dp), lightIdle.contactShadow)
        assertEquals(AuroraHeroCardAppearance.CardShadow(Color(0xFF8B5CF6).copy(alpha = 0.08f), 28.dp, 10.dp), lightIdle.ambientShadow)
        assertNull(lightFocused.contactShadow)
        assertEquals(AuroraHeroCardAppearance.CardShadow(Color(0xFF8B5CF6).copy(alpha = 0.16f), 40.dp, 14.dp), lightFocused.ambientShadow)
    }

    @Test
    fun `dark hero keeps the card flat and puts the aurora on its top edge`() {
        // The dark card looked muddy when it carried a glow blob in one corner, too much saturation in the dark
        // areas and grey text of a different hue than the face. The fix keeps the face a uniform base, brighter at
        // the top, and moves the aurora to the top edge and outside the card.
        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()

        // Face: a two-stop vertical gradient with no directional glow blobs; only the afterglow below the top edge remains inside
        assertTrue(
            themeSource.contains("colors = listOf(AuroraTheme.Colors.heroSurfaceDarkTop, AuroraTheme.Colors.heroSurfaceDarkBottom)"),
        )

        // The pill is opaque: a translucent white over the face fades into a grey patch
        assertEquals(1f, AuroraTheme.Colors.pillFillDark.alpha)
        // Grey text inside the hero shares the face's hue and is not the global t3 (a warm grey-purple)
        assertNotEquals(AuroraTheme.Colors.textTertiaryDark, AuroraTheme.Colors.heroTextTertiaryDark)
        val barSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()
        assertFalse("Tertiary grey inside the hero card always goes through heroTextTertiary()", barSource.contains("AuroraTheme.textTertiary()"))

        // Light is unaffected: still a white card + two glows + a uniform cardBorder stroke
        assertEquals(Color(0xFFEC8FEA).copy(alpha = 0.08f), AuroraTheme.Colors.heroGlowBLight)
        assertEquals(SolidColor(AuroraTheme.Colors.cardBorderLight), auroraHeroRimBrush(isDark = false, height = 100f))
    }

    @Test
    fun `the aurora crown lights hero and notes alike and fades out on focus`() {
        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()

        // The hero has the near-white hot core + the outer halo; Notes is the same light one step weaker, without core or halo
        assertTrue(themeSource.contains("drawAuroraCrown(hairlinePath, hairlineWidth, scale = 1f, hotCore = true, alpha = 1f - p)"))
        assertTrue(
            themeSource.contains("drawAuroraCrown(borderPath, hairlineWidth, scale = AURORA_CROWN_NOTES_SCALE, hotCore = false, alpha = 1f)"),
        )
        // On focus the crown and the outer halo fade out together in favor of the ring: both glows at once look smeared
        assertTrue(themeSource.contains("if (p < 1f) halo.forEach { with(it) { draw(size, alpha = 1f - p) } }"))
    }

    @Test
    fun `home header clears the top fade band at rest`() {
        // The band [status bar, status bar + fade length] at the top of the list washes content out; a header placed right under the status bar looks as if its capsule were covered
        val screenSource = File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
        assertTrue(screenSource.contains("contentPadding = PaddingValues(top = statusBarInset + OriveoSystemBarFadeLength)"))
    }

    @Test
    fun `css blur converts to the compose shadow radius`() {
        // CSS blur B → sigma B/2; BlurMaskFilter sigma = 0.57735 r → r ≈ 0.866 B
        assertEquals(25.98f, auroraCssShadowRadius(30.dp).value, 0.01f)
        assertEquals(1.732f, auroraCssShadowRadius(2.dp).value, 0.001f)
    }

    @Test
    fun `model pill drops vendor prefix and free suffix`() {
        assertEquals("DeepSeek V4 Flash", homeHeroPillModelName("DeepSeek: DeepSeek V4 Flash"))
        assertEquals("LFM2.5-1.2B-Instruct", homeHeroPillModelName("LiquidAI: LFM2.5-1.2B-Instruct (free)"))
        assertEquals("GPT-5", homeHeroPillModelName("  GPT-5  "))
    }

    @Test
    fun `notes entry shows the latest title or the invitation copy`() {
        assertEquals("Invite", homeNotesPreviewLine(count = 0, latestTitle = "Old", untitled = "Untitled", invitation = "Invite"))
        assertEquals("Metal shaders", homeNotesPreviewLine(count = 3, latestTitle = "  Metal shaders ", untitled = "Untitled", invitation = "Invite"))
        // Notes exist but the latest has no title: "Untitled", not the empty-state invitation (matches iOS NoteText.displayTitle)
        assertEquals("Untitled", homeNotesPreviewLine(count = 3, latestTitle = "   ", untitled = "Untitled", invitation = "Invite"))
        assertEquals("Untitled", homeNotesPreviewLine(count = 3, latestTitle = null, untitled = "Untitled", invitation = "Invite"))

        assertEquals("Notes, 3 notes, Metal shaders", homeNotesAccessibilityText("Notes", "3 notes", "Metal shaders"))
        assertEquals("Notes. Invite", homeNotesAccessibilityText("Notes", null, "Invite"))
    }

    @Test
    fun `hero card keeps the flat design structure`() {
        val barSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()

        assertTrue(
            "Hero uses the shared aurora glass card with the 26dp radius and border-box padding 19/19/15.",
            barSource.contains(".auroraGlassCard(isDark = isDark, cornerRadius = HOME_HERO_CORNER_RADIUS, focused = isFocused)") &&
                barSource.contains(".padding(start = 19.dp, end = 19.dp, top = 19.dp, bottom = 15.dp)"),
        )
        assertFalse(
            "The idle hero has no hairline divider between the input and the controls any more.",
            barSource.contains("Brush.horizontalGradient") || barSource.contains("AuroraTheme.hairline()"),
        )
        assertFalse(
            "The send button is a flat solid purple circle: no gradient, no shadow, no sheen.",
            barSource.contains("OriveoGradients.primary") ||
                barSource.contains("Color.White.copy(alpha = 0.28f)") ||
                barSource.contains(".shadow("),
        )
        assertTrue(
            "The send button announces Send, not New Chat.",
            barSource.contains("contentDescription = stringResource(R.string.send)"),
        )
        assertTrue(
            "The model pill stays a picker with provider logo, cleaned model name and provider subtitle.",
            barSource.contains("ProviderBadgeIcon(") &&
                barSource.contains("active.provider.displayName") &&
                barSource.contains("homeHeroPillModelName(") &&
                barSource.contains("stringResource(R.string.select_model)") &&
                barSource.contains("stringResource(R.string.add_provider)"),
        )
    }
}
