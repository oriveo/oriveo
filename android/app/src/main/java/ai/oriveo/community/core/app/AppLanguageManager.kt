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

    /**
     * uiLanguage from attachment extraction spec section 1: zh-Hans / zh-Hant / ja / ko / ru, everything else is en.
     * Only used as the tie-breaker in plain-text encoding detection (section 4). When Chinese has no script, decide by region: Taiwan, Hong Kong and Macau are Traditional.
     */
    fun extractionUiLanguage(locale: Locale = Locale.getDefault()): String = when (locale.language) {
        "zh" -> when {
            locale.script == "Hant" -> "zh-Hant"
            locale.script.isEmpty() && locale.country in TRADITIONAL_CHINESE_REGIONS -> "zh-Hant"
            else -> "zh-Hans"
        }
        "ja", "ko", "ru" -> locale.language
        else -> "en"
    }

    private val TRADITIONAL_CHINESE_REGIONS = setOf("TW", "HK", "MO")
}
