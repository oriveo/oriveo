package ai.oriveo.community.core.voice

import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.model.LanguageOption

/** One row of the recognition-language panel; a null [tag] means automatic. */
data class RecognitionLanguageRow(
    val tag: String?,
    val label: UiText,
    val selected: Boolean,
)

/** Rows of the recognition-language panel: automatic plus UI languages with a localeTag; the [current] entry is checked. Shared by the settings page and the in-conversation form. */
internal fun recognitionLanguageRows(current: String?): List<RecognitionLanguageRow> {
    val automatic = RecognitionLanguageRow(
        tag = null,
        label = UiText.Resource(R.string.voice_language_automatic),
        selected = current == null,
    )
    return listOf(automatic) + LanguageOption.entries.mapNotNull { option ->
        val tag = option.localeTag ?: return@mapNotNull null
        RecognitionLanguageRow(tag = tag, label = UiText.Dynamic(option.displayName), selected = tag == current)
    }
}
