package ai.oriveo.community.feature.chat.composer

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.ui.theme.DefaultLightBrandTuned
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.primarySubtle

internal data class ComposerCapabilityAccent(
    val tint: Color,
    val iconStart: Color,
    val iconEnd: Color,
    val softFill: Color,
    val softBorder: Color,
    val shadow: Color,
)

internal enum class ComposerControlChipAccessory {
    None,
    Chevron,
}

@Composable
internal fun composerAttachmentAccent(): ComposerCapabilityAccent = ComposerCapabilityAccent(
    tint = composerDynamicColor(light = 0x52607A, dark = 0xCBD5E1),
    // The dark start follows the palette primary; light keeps its original value
    iconStart = if (OriveoTheme.isDark) OriveoTheme.colors.primary else composerLightColor(0xA5B4FC),
    // Both dark ends follow the palette (primary -> primaryActive), so the badge foreground can uniformly use onPrimary
    iconEnd = if (OriveoTheme.isDark) OriveoTheme.colors.primaryActive else composerLightColor(0x6366F1),
    softFill = composerDynamicColor(light = 0xF8FAFC, dark = 0x172136, darkAlpha = 0.94f),
    softBorder = composerDynamicColor(light = 0xD5DBE7, dark = 0x94A3B8, darkAlpha = 0.26f),
    shadow = OriveoTheme.colors.shadow,
)

@Composable
internal fun composerLibraryAccent(): ComposerCapabilityAccent = ComposerCapabilityAccent(
    tint = composerDynamicColor(light = 0x166534, dark = 0x86EFAC),
    iconStart = composerDynamicColor(light = 0x4ADE80, dark = 0x86EFAC),
    iconEnd = composerDynamicColor(light = 0x15803D, dark = 0x22C55E),
    softFill = composerDynamicColor(light = 0xECFDF3, dark = 0x10281A, darkAlpha = 0.92f),
    softBorder = composerDynamicColor(light = 0x86D7A4, dark = 0x4ADE80, lightAlpha = 0.62f, darkAlpha = 0.28f),
    shadow = composerDynamicColor(light = 0x166534, dark = 0x000000, lightAlpha = 0.14f, darkAlpha = 0.22f),
)

/** The model-behavior chip is a brand-purple accent: dark uses the current palette tokens (accent -> primary), light follows the light brand colors (the default palette keeps its original values). */
@Composable
internal fun composerModelBehaviorAccent(): ComposerCapabilityAccent {
    val colors = OriveoTheme.colors
    if (OriveoTheme.isDark) {
        return ComposerCapabilityAccent(
            tint = colors.accent,
            iconStart = colors.accent,
            iconEnd = colors.primary,
            softFill = colors.primarySubtle,
            softBorder = colors.primary.copy(alpha = 0.30f),
            shadow = Color.Black.copy(alpha = 0.22f),
        )
    }
    // Light follows the light brand colors: text / dark end / shadow -> textSafe, light end -> ink, fill -> soft, border -> ink; the default palette keeps its original values
    val brand = OriveoTheme.lightBrand
    return ComposerCapabilityAccent(
        tint = brand.tuned(composerLightColor(0x5B4AB8), brand.textSafe),
        iconStart = brand.tuned(DefaultLightBrandTuned.ringLavender, brand.ink),
        iconEnd = brand.tuned(composerLightColor(0x6D5BD0), brand.textSafe),
        softFill = brand.tuned(composerLightColor(0xF5F3FF), brand.soft),
        softBorder = brand.tuned(DefaultLightBrandTuned.lavender.copy(alpha = 0.70f), brand.ink.copy(alpha = 0.30f)),
        shadow = brand.tuned(composerLightColor(0x6D5BD0, alpha = 0.15f), brand.textSafe.copy(alpha = 0.15f)),
    )
}

/** For the light branch only: the same algorithm as the light side of [composerDynamicColor], so light values stay bit-for-bit unchanged. */
private fun composerLightColor(hex: Long, alpha: Float = 1f): Color = Color(0xFF000000L or hex).copy(alpha = alpha)

@Composable
internal fun composerAccent(capability: ModelCapability): ComposerCapabilityAccent = when (capability) {
    ModelCapability.Reasoning -> ComposerCapabilityAccent(
        tint = composerDynamicColor(light = 0xC66312, dark = 0xF6C24B),
        iconStart = composerDynamicColor(light = 0xF0A11F, dark = 0xF6C24B),
        iconEnd = composerDynamicColor(light = 0xC66312, dark = 0xD97706),
        softFill = composerDynamicColor(light = 0xFFF3DE, dark = 0x3A2610, darkAlpha = 0.92f),
        softBorder = composerDynamicColor(light = 0xE4B05D, dark = 0xF6C24B, lightAlpha = 0.65f, darkAlpha = 0.34f),
        shadow = composerDynamicColor(light = 0xC66312, dark = 0x000000, lightAlpha = 0.18f, darkAlpha = 0.22f),
    )
    ModelCapability.Web -> ComposerCapabilityAccent(
        tint = composerDynamicColor(light = 0x0F766E, dark = 0x2DD4BF),
        iconStart = composerDynamicColor(light = 0x2DC7B4, dark = 0x2DD4BF),
        iconEnd = composerDynamicColor(light = 0x0891B2, dark = 0x0F766E),
        softFill = composerDynamicColor(light = 0xE9FBF7, dark = 0x102A28, darkAlpha = 0.92f),
        softBorder = composerDynamicColor(light = 0x7ADBCF, dark = 0x5EEAD4, lightAlpha = 0.62f, darkAlpha = 0.28f),
        shadow = composerDynamicColor(light = 0x0F766E, dark = 0x000000, lightAlpha = 0.14f, darkAlpha = 0.22f),
    )
    else -> composerAttachmentAccent()
}

@Composable
internal fun composerDynamicColor(
    light: Long,
    dark: Long,
    lightAlpha: Float = 1f,
    darkAlpha: Float = 1f,
): Color {
    val isDark = OriveoTheme.isDark
    val base = if (isDark) dark else light
    val alpha = if (isDark) darkAlpha else lightAlpha
    return Color(0xFF000000L or base).copy(alpha = alpha)
}

internal fun composerResolvedColor(
    isDark: Boolean,
    light: Long,
    dark: Long,
    lightAlpha: Float = 1f,
    darkAlpha: Float = 1f,
): Color {
    val base = if (isDark) dark else light
    val alpha = if (isDark) darkAlpha else lightAlpha
    return Color(0xFF000000L or base).copy(alpha = alpha)
}

internal fun composerFileExtensionLabel(fileName: String): String? {
    val extension = fileName.substringAfterLast('.', "").uppercase()
    return extension.takeIf { it.isNotEmpty() }?.take(4)
}

internal fun composerDisplayFileName(fileName: String): String {
    val rawName = fileName.substringAfterLast('/')
    val lastDot = rawName.lastIndexOf('.')
    val baseName = if (lastDot > 0) rawName.substring(0, lastDot) else rawName
    return if (baseName.isBlank()) rawName else baseName
}
