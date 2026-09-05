package ai.oriveo.community.core.app

import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import ai.oriveo.community.core.model.LanguageOption

object AppLanguageManager {

    fun apply(option: LanguageOption) {
        val targetLocales = option.localeTag?.let(LocaleListCompat::forLanguageTags)
            ?: LocaleListCompat.getEmptyLocaleList()
        val currentLocales = AppCompatDelegate.getApplicationLocales()

        if (currentLocales.toLanguageTags() == targetLocales.toLanguageTags()) return

        AppCompatDelegate.setApplicationLocales(targetLocales)
    }
}
