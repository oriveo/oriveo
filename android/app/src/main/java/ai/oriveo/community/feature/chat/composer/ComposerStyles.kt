package ai.oriveo.community.feature.chat.composer

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.ui.theme.OriveoTheme

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
    iconStart = composerDynamicColor(light = 0xA5B4FC, dark = 0x818CF8),
    iconEnd = composerDynamicColor(light = 0x6366F1, dark = 0x6366F1),
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

@Composable
internal fun composerModelBehaviorAccent(): ComposerCapabilityAccent = ComposerCapabilityAccent(
    tint = composerDynamicColor(light = 0x5B4AB8, dark = 0xC4B5FD),
    iconStart = composerDynamicColor(light = 0xA78BFA, dark = 0xC4B5FD),
    iconEnd = composerDynamicColor(light = 0x6D5BD0, dark = 0x8B5CF6),
    softFill = composerDynamicColor(light = 0xF5F3FF, dark = 0x211B36, darkAlpha = 0.94f),
    softBorder = composerDynamicColor(light = 0xC4B5FD, dark = 0xA78BFA, lightAlpha = 0.70f, darkAlpha = 0.30f),
    shadow = composerDynamicColor(light = 0x6D5BD0, dark = 0x000000, lightAlpha = 0.15f, darkAlpha = 0.22f),
)

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
