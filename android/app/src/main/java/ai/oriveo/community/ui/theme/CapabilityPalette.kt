package ai.oriveo.community.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * Capability palette: five fixed colors, dark theme uses the Tailwind 400 shade and light theme the 600 shade, with the same values as the iOS `CapabilityPalette`.
 * Capability icons and capability cards take colors only from here; `capability-matrix-gate.mjs --lint` G6 blocks hand-writing these ten color values outside the token file.
 */
object CapabilityPalette {
    val webSearch: Color @Composable get() = pick(light = Color(0xFF2563EB), dark = Color(0xFF60A5FA))
    val reasoning: Color @Composable get() = pick(light = Color(0xFF7C3AED), dark = Color(0xFFA78BFA))
    val attachment: Color @Composable get() = pick(light = Color(0xFFD97706), dark = Color(0xFFFBBF24))
    val vision: Color @Composable get() = pick(light = Color(0xFF059669), dark = Color(0xFF34D399))
    val tools: Color @Composable get() = pick(light = Color(0xFFDB2777), dark = Color(0xFFF472B6))

    @Composable
    private fun pick(light: Color, dark: Color): Color = if (OriveoTheme.isDark) dark else light
}

/**
 * The five non-capability colors of the connection detail page (relay / local) row icons: chosen the same way as [CapabilityPalette] (600 shade in light, 400 shade in dark).
 * The web-search / thinking rows reuse the capability colors and are not repeated here; the color values appear only in this file.
 */
object DetailRowPalette {
    val teal: Color @Composable get() = pick(light = Color(0xFF0D9488), dark = Color(0xFF2DD4BF))
    val cyan: Color @Composable get() = pick(light = Color(0xFF0891B2), dark = Color(0xFF22D3EE))
    val indigo: Color @Composable get() = pick(light = Color(0xFF4F46E5), dark = Color(0xFF818CF8))
    val orange: Color @Composable get() = pick(light = Color(0xFFEA580C), dark = Color(0xFFFB923C))
    val rose: Color @Composable get() = pick(light = Color(0xFFE11D48), dark = Color(0xFFFB7185))

    @Composable
    private fun pick(light: Color, dark: Color): Color = if (OriveoTheme.isDark) dark else light
}
