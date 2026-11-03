package ai.oriveo.community.ui.util

import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.LayoutDirection
import ai.oriveo.community.core.skills.SkillValidation
import org.junit.Assert.assertEquals
import org.junit.Test

class ContentDirectionTest {

    @Test
    fun content_direction_style_uses_textdirection_content() {
        assertEquals(TextDirection.Content, userContentTextStyle.textDirection)
    }

    @Test
    fun slash_fragment_is_isolated_ltr() {
        val label = SkillValidation.slashLabel("weekly report")
        val isolated = isolateSlashFragment(label)
        assertEquals("⁦$label⁩", isolated)
        assertEquals('⁦', isolated.first())
        assertEquals('⁩', isolated.last())
    }

    @Test
    fun content_layout_direction_follows_first_strong_char() {
        assertEquals(LayoutDirection.Ltr, contentLayoutDirection("Fixed sign-in", LayoutDirection.Rtl))
        assertEquals(
            LayoutDirection.Rtl,
            contentLayoutDirection("\u0645\u0631\u062d\u0628\u0627", LayoutDirection.Ltr),
        )
        assertEquals(LayoutDirection.Ltr, contentLayoutDirection("1. Fixed", LayoutDirection.Rtl))
        assertEquals(LayoutDirection.Rtl, contentLayoutDirection("123", LayoutDirection.Rtl))
        assertEquals(LayoutDirection.Ltr, contentLayoutDirection("123", LayoutDirection.Ltr))
        assertEquals(LayoutDirection.Rtl, contentLayoutDirection("", LayoutDirection.Rtl))
    }

    @Test
    fun counter_text_is_ltr_isolated() {
        val isolated = isolateLtr("13 / 40")
        assertEquals("\u206613 / 40\u2069", isolated)
        assertEquals(isolateSlashFragment("/x"), isolateLtr("/x"))
    }
}
