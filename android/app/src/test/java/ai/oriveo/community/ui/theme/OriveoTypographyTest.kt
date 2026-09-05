package ai.oriveo.community.ui.theme

import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class OriveoTypographyTest {

    @Test
    fun `hero and title1 keep using the brand font family`() {
        assertNotNull(OriveoTypography.hero.fontFamily)
        assertEquals(OriveoTypography.hero.fontFamily, OriveoTypography.title1.fontFamily)
        assertEquals(FontWeight.Bold, OriveoTypography.hero.fontWeight)
        assertEquals(FontWeight.Bold, OriveoTypography.title1.fontWeight)
    }
}
