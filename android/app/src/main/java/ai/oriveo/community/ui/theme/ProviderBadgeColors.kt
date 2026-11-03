package ai.oriveo.community.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import ai.oriveo.community.core.model.ProviderKind

/**
 * Background and border colours the provider badge paints behind a vendor logo, so that marks with
 * transparent backgrounds sit on a plate tuned to their own brand hue instead of on raw surface.
 */
data class ProviderBrandColors(
    val background: Color,
    val border: Color,
)

object ProviderBadgeColors {

    @Composable
    fun forProvider(kind: ProviderKind): ProviderBrandColors {
        val colors = OriveoTheme.colors
        val isDark = OriveoTheme.isDark
        return when (kind) {
            ProviderKind.OpenAI -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF1E2433),
                    border = Color(0xFF333D50),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFFFFF),
                    border = Color(0xFFE5E7EB),
                )
            }

            ProviderKind.Anthropic -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF2A2520),
                    border = Color(0xFF4A3F33),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFF4EFE6),
                    border = Color(0xFFE7DDCD),
                )
            }

            ProviderKind.Gemini -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF1E2433),
                    border = Color(0xFF333D50),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFFFFF),
                    border = Color(0xFFE5E7EB),
                )
            }

            ProviderKind.DeepSeek -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF15243B),
                    border = Color(0xFF2C4B73),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFEEF4FF),
                    border = Color(0xFFC8D8F7),
                )
            }

            ProviderKind.Grok -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF1A1B1E),
                    border = Color(0xFF2E3033),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFF2F3F5),
                    border = Color(0xFFD5D8DC),
                )
            }

            ProviderKind.OpenRouter -> if (isDark) {
                ProviderBrandColors(
                    background = Color.Transparent,
                    border = Color(0xFF3D3D60),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFEEEFFF),
                    border = Color(0xFFD4D5FE),
                )
            }

            ProviderKind.Groq -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF2D1B18),
                    border = Color(0xFF4A2E28),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFF1EE),
                    border = Color(0xFFFBCFC6),
                )
            }

            ProviderKind.Together -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF152238),
                    border = Color(0xFF2A3D5C),
                    // The Together mark is a three-colour figure (orange / magenta / lilac), not a
                    // monochrome glyph, so it is deliberately left un-tinted in dark mode: applying
                    // the usual white tint would flatten the whole brand palette into one white block.
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFEDF5FF),
                    border = Color(0xFFC4DAFE),
                )
            }

            ProviderKind.Fireworks -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF2D1F18),
                    border = Color(0xFF4A3228),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFF4EE),
                    border = Color(0xFFFBD3C1),
                )
            }

            ProviderKind.MiniMax -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF2D1820),
                    border = Color(0xFF4A2833),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFF0F3),
                    border = Color(0xFFFBC8D4),
                )
            }

            ProviderKind.Zhipu -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF1A1B20),
                    border = Color(0xFF353740),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFF0F0F2),
                    border = Color(0xFFD5D6DB),
                )
            }

            ProviderKind.Qwen -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF1C1A38),
                    border = Color(0xFF33306A),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFEEEDFC),
                    border = Color(0xFFC5C3F5),
                )
            }

            ProviderKind.Moonshot -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF141821),
                    border = Color(0xFF2F3849),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFFFFF),
                    border = Color(0xFFE3E7EF),
                )
            }

            // Mistral brand orange is #FA500F; the plate pair follows the Fireworks orange recipe,
            // pulled slightly further towards red.
            ProviderKind.Mistral -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF2D1B12),
                    border = Color(0xFF4A2C1C),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFF2EA),
                    border = Color(0xFFFBCDB4),
                )
            }

            ProviderKind.SiliconFlow -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF1E1245),
                    border = Color(0xFF3B2A80),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFF3ECFF),
                    border = Color(0xFFD4C4F6),
                )
            }

            ProviderKind.Relay -> if (isDark) {
                ProviderBrandColors(
                    background = Color(0xFF1E2433),
                    border = Color(0xFF333D50),
                )
            } else {
                ProviderBrandColors(
                    background = Color(0xFFFFFFFF),
                    border = Color(0xFFE5E7EB),
                )
            }
        }
    }

    @Composable
    fun usageBreakdown(kind: ProviderKind): Color {
        val pair = ProviderUsageBreakdownPalette.argb.getValue(kind)
        return Color(if (OriveoTheme.isDark) pair.dark else pair.light)
    }
}

/** Raw light / dark ARGB pair for one provider's usage breakdown accent. */
data class ProviderUsageArgb(val light: Long, val dark: Long)

/**
 * Single source of the usage breakdown accent per provider (non-Composable so tests can read it).
 * [ProviderBadgeColors.usageBreakdown] picks light / dark from this table.
 */
object ProviderUsageBreakdownPalette {
    val argb: Map<ProviderKind, ProviderUsageArgb> = mapOf(
        ProviderKind.OpenAI to ProviderUsageArgb(light = 0xFF10A37F, dark = 0xFF22C18D),
        ProviderKind.Anthropic to ProviderUsageArgb(light = 0xFFC7956D, dark = 0xFFE0B58E),
        ProviderKind.Gemini to ProviderUsageArgb(light = 0xFF4285F4, dark = 0xFF7AB2FF),
        ProviderKind.DeepSeek to ProviderUsageArgb(light = 0xFF4F7BFF, dark = 0xFF7EA2FF),
        ProviderKind.Grok to ProviderUsageArgb(light = 0xFF0F0F10, dark = 0xFFF2F3F5),
        ProviderKind.OpenRouter to ProviderUsageArgb(light = 0xFF6D63FF, dark = 0xFF9B93FF),
        ProviderKind.Groq to ProviderUsageArgb(light = 0xFFF55036, dark = 0xFFFF8A74),
        ProviderKind.Together to ProviderUsageArgb(light = 0xFF0EA5E9, dark = 0xFF38BDF8),
        ProviderKind.Fireworks to ProviderUsageArgb(light = 0xFFFF6B35, dark = 0xFFFF9B6B),
        ProviderKind.MiniMax to ProviderUsageArgb(light = 0xFFE8457C, dark = 0xFFFF6B8A),
        ProviderKind.Zhipu to ProviderUsageArgb(light = 0xFF333333, dark = 0xFFA0A0A8),
        ProviderKind.Qwen to ProviderUsageArgb(light = 0xFF615CED, dark = 0xFF8B88F5),
        ProviderKind.Moonshot to ProviderUsageArgb(light = 0xFF111827, dark = 0xFFE5E7EB),
        // Mistral orange: brand #FA500F in light, one step brighter in dark for contrast.
        ProviderKind.Mistral to ProviderUsageArgb(light = 0xFFFA500F, dark = 0xFFFF8205),
        ProviderKind.SiliconFlow to ProviderUsageArgb(light = 0xFF7C3AED, dark = 0xFFA78BFA),
        // Neutral slate; the provider hero for Relay uses theme primary instead.
        ProviderKind.Relay to ProviderUsageArgb(light = 0xFF64748B, dark = 0xFF94A3B8),
    )
}

/**
 * Flat brand tint used for decorative accents (note diamonds, source dots) rather than for the
 * badge plate.
 *
 * These are the vendors' own published brand colours and are deliberately hard-coded instead of
 * being drawn from the theme tokens: brand recognition is the point, so they must not shift with
 * the palette.
 *
 * [fallbackId] disambiguates providers that share one kind. Relay endpoints are all "relay", so
 * hashing the instance id spreads them across a palette; without it every Relay a user configures
 * would render in the same colour.
 */
internal fun providerTintFor(providerKind: String, fallbackId: String = ""): Color {
    val raw = providerKind.trim().lowercase()
    return when (raw) {
        "openai" -> Color(0xFF10A37F)
        "anthropic" -> Color(0xFFC7956D)
        "gemini" -> Color(0xFF4285F4)
        "deepseek" -> Color(0xFF4D6BFE)
        "grok", "xai" -> Color(0xFF0F0F10)
        "openrouter" -> Color(0xFF6D63FF)
        "groq" -> Color(0xFFF55036)
        "together", "togetherai" -> Color(0xFF0EA5E9)
        "fireworks", "fireworksai" -> Color(0xFFFF6B35)
        "minimax" -> Color(0xFFE8457C)
        "zhipu" -> Color(0xFF1F63EC)
        "qwen" -> Color(0xFF615CED)
        "moonshot", "kimi" -> Color(0xFF5B3AFF)
        "mistral" -> Color(0xFFFA500F)
        "siliconflow" -> Color(0xFF7C3AED)
        else -> {
            // Relay endpoints and any kind this table does not know share one raw value, so they are
            // spread deterministically across a palette by hashing their id.
            val palette = if (raw == "relay") RELAY_PALETTE else FALLBACK_PALETTE
            val seed = if (fallbackId.isNotEmpty()) fallbackId else raw
            palette[djb2HashIndex(seed, palette.size)]
        }
    }
}

private val FALLBACK_PALETTE = listOf(
    Color(0xFF6366F1),  // indigo
    Color(0xFF22C55E),  // green
    Color(0xFFF59E0B),  // amber
    Color(0xFFEF4444),  // red
    Color(0xFF06B6D4),  // cyan
)

/**
 * Palette for Relay instances. The hues deliberately avoid the clusters the vendor brand colours
 * already occupy (OpenAI green, Anthropic tan, the blue-violet family), so a user running several
 * Relay endpoints can still tell their accents apart at a glance.
 */
private val RELAY_PALETTE = listOf(
    Color(0xFF14B8A6),  // teal 500
    Color(0xFFF59E0B),  // amber 500
    Color(0xFFD946EF),  // fuchsia 500
    Color(0xFF84CC16),  // lime 500
    Color(0xFFEC4899),  // pink 500
    Color(0xFFEAB308),  // yellow 500
    Color(0xFFFB923C),  // orange 400
    Color(0xFF0891B2),  // cyan 600
)

/** DJB2 is used here because it is stable across processes: the same id always picks the same swatch. */
private fun djb2HashIndex(id: String, count: Int): Int {
    if (id.isEmpty()) return 0
    var h = 5381L
    for (byte in id.toByteArray(Charsets.UTF_8)) {
        h = h * 33 + (byte.toInt() and 0xFF)
    }
    val absH = if (h < 0) -h else h
    return (absH % count).toInt()
}
