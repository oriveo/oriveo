package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes

internal data class SettingsRowContent(
    val subtitle: String? = null,
    val value: String? = null,
)

internal fun themeSummaryLabel(
    theme: ThemeOption,
    systemLabel: String,
    lightLabel: String,
    darkLabel: String,
): String = when (theme) {
    ThemeOption.System -> systemLabel
    ThemeOption.Light -> lightLabel
    ThemeOption.Dark -> darkLabel
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

internal fun memoryRowContent(
    memoryText: String,
    notSetLabel: String,
    maxPreviewGraphemes: Int = 30,
): SettingsRowContent {
    val normalized = memoryText.trim()
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
