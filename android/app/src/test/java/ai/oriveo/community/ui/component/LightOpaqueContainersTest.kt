package ai.oriveo.community.ui.component

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import ai.oriveo.community.feature.chat.composer.composerShellFillColor
import ai.oriveo.community.feature.mcp.mcpPermissionMenuContainerColor
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import org.junit.Assert.assertEquals
import org.junit.Test

class LightOpaqueContainersTest {

    private val light = LightOriveoColors
    private val dark = DarkOriveoColors

    private fun assertOpaqueComposite(original: Color, resolved: Color) {
        assertEquals(1f, resolved.alpha, 0f)
        assertEquals(original.compositeOver(light.backgroundBase), resolved)
    }

    @Test
    fun composer_shell_fill_is_opaque_in_light_and_unchanged_in_dark() {
        val cases = listOf(
            Triple(true, false, Color(0xFFFFFFFF).copy(alpha = 0.26f)),
            Triple(false, true, Color(0xFFFBF9FF).copy(alpha = 0.19f)),
            Triple(false, false, Color(0xFFFFFFFF).copy(alpha = 0.11f)),
        )
        cases.forEach { (focused, draft, original) ->
            assertOpaqueComposite(original, composerShellFillColor(false, focused, draft, light))
        }
        assertEquals(Color(0xFF101113).copy(alpha = 0.46f), composerShellFillColor(true, true, false, dark))
        assertEquals(Color(0xFF0B0C0E).copy(alpha = 0.42f), composerShellFillColor(true, false, true, dark))
        assertEquals(Color(0xFF07080A).copy(alpha = 0.38f), composerShellFillColor(true, false, false, dark))
    }

    @Test
    fun tab_bar_fallback_fill_is_opaque_in_light_and_unchanged_in_dark() {
        assertOpaqueComposite(Color(0xF7FDFBFF), liquidGlassFallbackFill(isDark = false, colors = light))
        assertEquals(dark.surface.copy(alpha = 0.95f), liquidGlassFallbackFill(isDark = true, colors = dark))
    }

    @Test
    fun mcp_permission_menu_is_opaque_in_light_and_unchanged_in_dark() {
        assertOpaqueComposite(light.surface, mcpPermissionMenuContainerColor(isDark = false, colors = light))
        assertEquals(dark.surface, mcpPermissionMenuContainerColor(isDark = true, colors = dark))
    }
}
