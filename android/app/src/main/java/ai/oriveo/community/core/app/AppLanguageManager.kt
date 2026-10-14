package ai.oriveo.community.core.app

import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import ai.oriveo.community.core.model.LanguageOption
import java.util.Locale

object AppLanguageManager {

    fun apply(option: LanguageOption) {
        val targetLocales = applicationLocaleTag(option)?.let(LocaleListCompat::forLanguageTags)
            ?: LocaleListCompat.getEmptyLocaleList()
        val currentLocales = AppCompatDelegate.getApplicationLocales()

        if (currentLocales.toLanguageTags() == targetLocales.toLanguageTags()) return

        AppCompatDelegate.setApplicationLocales(targetLocales)
    }

    /**
     * The tag applied to Configuration: an explicit ar gets nu=latn appended. On API <= 35 ICU renders Arabic
     * digits by default, but counted copy needs Latin digits; the Unicode extension does not take part in resource
     * matching. "Follow system" does not go through here and is unchanged.
     */
    internal fun applicationLocaleTag(option: LanguageOption): String? {
        val tag = option.localeTag ?: return null
        return if (Locale.forLanguageTag(tag).language == "ar") "$tag-u-nu-latn" else tag
    }

    /** The language identifier sent outbound, with Unicode extensions removed (ar-u-nu-latn -> ar); servers and analytics only read language and region. */
    fun outboundLanguageTag(locale: Locale = Locale.getDefault()): String =
        Locale.Builder().setLocale(locale).clearExtensions().build().toLanguageTag()
}
