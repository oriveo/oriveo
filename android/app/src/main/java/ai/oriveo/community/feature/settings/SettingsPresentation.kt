package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import ai.oriveo.community.ui.theme.DarkPaletteId

internal data class SettingsRowContent(
    val subtitle: String? = null,
    val value: String? = null,
)

/**
 * Summary on the right of the Theme row in Settings: light -> "Light"; dark -> the palette name (the default palette shows "Dark");
 * follow system -> "Follow System · <palette name>". The palette name always comes from resolve(darkPalette).
 */
internal fun themeSummaryLabel(
    theme: ThemeOption,
    darkPalette: String?,
    lightLabel: String,
    paletteLabel: (DarkPaletteId) -> String,
    followSystemLabel: (String) -> String,
): String {
    val palette = paletteLabel(DarkPaletteId.fromId(darkPalette))
    return when (theme) {
        ThemeOption.System -> followSystemLabel(palette)
        ThemeOption.Light -> lightLabel
        ThemeOption.Dark -> palette
    }
}

internal fun languageSummaryLabel(
    language: LanguageOption,
    systemLabel: String,
): String = if (language == LanguageOption.System) {
    systemLabel
} else {
    language.displayName
}

internal fun formatAppVersion(versionName: String, versionCode: Int): String =
    "V$versionName ($versionCode)"

private val MEMORY_LIST_MARKER = Regex("^\\s*[-*•]\\s+")

internal fun memoryRowContent(
    memoryText: String,
    notSetLabel: String,
    maxPreviewGraphemes: Int = 30,
): SettingsRowContent {
    // Memory is often stored as a Markdown list: the preview strips leading list markers and joins lines, so "- " never shows
    val normalized = memoryText.lines()
        .map { it.replace(MEMORY_LIST_MARKER, "").trim() }
        .filter { it.isNotEmpty() }
        .joinToString(" ")
    val hasMemory = normalized.isNotBlank()
    val preview = if (hasMemory) {
        buildString {
            append(normalized.takeGraphemes(maxPreviewGraphemes))
            if (normalized.graphemeCount() > maxPreviewGraphemes) {
                append("...")
            }
        }
    } else {
        notSetLabel
    }
    return SettingsRowContent(
        subtitle = null,
        value = preview,
    )
}
