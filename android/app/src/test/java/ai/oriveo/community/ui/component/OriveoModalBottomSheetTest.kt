package ai.oriveo.community.ui.component

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import org.junit.Assert.assertEquals
import org.junit.Test

class OriveoModalBottomSheetTest {

    @Test
    fun sheet_container_is_opaque_when_surface_is_translucent() {
        val light = LightOriveoColors
        assertEquals(Color(0xFFFFFFFF), light.surface)
        val resolved = resolveSheetContainerColor(light.surface, light)
        assertEquals(1f, resolved.alpha, 0f)
        assertEquals(Color(0xFFFFFFFF), resolved)
    }

    @Test
    fun opaque_dark_surface_is_unchanged() {
        val dark = DarkOriveoColors
        assertEquals(dark.surface, resolveSheetContainerColor(dark.surface, dark))
    }

    @Test
    fun explicit_non_surface_colors_are_kept_as_is() {
        val light = LightOriveoColors
        val tint = Color(0x80123456)
        assertEquals(Color.Transparent, resolveSheetContainerColor(Color.Transparent, light))
        assertEquals(tint, resolveSheetContainerColor(tint, light))
        assertEquals(Color.Black, resolveSheetContainerColor(Color.Black, light))
    }
}
