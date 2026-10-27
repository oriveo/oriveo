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
 * Summary of the theme cell on the Settings home: the default palette shows only the appearance name (Light / Dark / Follow System);
 * any other palette shows "<appearance> · <palette name>". The palette always comes from resolve(darkPalette) (custom -> [ThemeSwatchSelection.Custom]).
 */
internal fun themeSummaryLabel(
    theme: ThemeOption,
    darkPalette: String?,
    appearanceLabel: (ThemeOption) -> String,
    paletteLabel: (ThemeSwatchSelection) -> String,
    appearanceWithPalette: (ThemeOption, String) -> String,
): String = when (val selection = ThemePageRules.selection(darkPalette)) {
    ThemeSwatchSelection.Palette(DarkPaletteId.Default) -> appearanceLabel(theme)
    else -> appearanceWithPalette(theme, paletteLabel(selection))
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
