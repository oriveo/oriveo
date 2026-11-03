package ai.oriveo.community.feature.chat.voice

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import org.junit.Assert.assertEquals
import org.junit.Test

/** Realtime failure card secondary button fill and text use the same values as the dictation failure card. */
class RealtimeFailureSecondaryColorsTest {
    @Test
    fun secondary_fill_matches_dictation_card() {
        assertEquals(Color(0xFFF2F2F5), RealtimeFailureSecondaryColors.fill(isDark = false))
        assertEquals(Color.White.copy(alpha = 0.10f), RealtimeFailureSecondaryColors.fill(isDark = true))
    }

    @Test
    fun secondary_text_matches_dictation_card() {
        assertEquals(Color(0xFF3F3F46), RealtimeFailureSecondaryColors.text(isDark = false))
        assertEquals(Color(0xFFEDEDEF), RealtimeFailureSecondaryColors.text(isDark = true))
    }

    @Test
    fun card_border_is_visible_on_white_card() {
        assertEquals(Color(0x14000000), RealtimeFailureSecondaryColors.cardBorder(LightOriveoColors))
        assertEquals(Color(0x1AFFFFFF), RealtimeFailureSecondaryColors.cardBorder(DarkOriveoColors))
    }
}
