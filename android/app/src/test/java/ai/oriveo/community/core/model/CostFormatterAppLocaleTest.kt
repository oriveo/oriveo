package ai.oriveo.community.core.model

import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import ai.oriveo.community.feature.managedwallet.formatManagedBalanceMicrousd
import java.util.Locale
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * USD amounts default to the App UI language, not the JVM default locale: on API 24-32 the
 * per-app language only reaches Locale.getDefault() after an AppCompatActivity applies it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class CostFormatterAppLocaleTest {

    private lateinit var savedDefault: Locale

    @Before
    fun setUp() {
        savedDefault = Locale.getDefault()
    }

    @After
    fun tearDown() {
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList())
        Locale.setDefault(savedDefault)
    }

    @Test
    fun usd_amounts_follow_app_language_over_system_locale() {
        Locale.setDefault(Locale.forLanguageTag("en-US"))
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags("de"))

        assertEquals("1,20 $", normalize(CostFormatter.usd(1.2, 2, 2)))
        assertEquals("1,20 $", normalize(formatManagedBalanceMicrousd(1_200_000)))
    }

    @Test
    fun usd_amounts_follow_system_locale_when_app_language_unset() {
        Locale.setDefault(Locale.forLanguageTag("en-US"))
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList())

        assertEquals("$1.20", normalize(CostFormatter.usd(1.2, 2, 2)))
        assertEquals("$1.20", normalize(formatManagedBalanceMicrousd(1_200_000)))
    }

    private fun normalize(text: String): String =
        text.replace(Regex("[‎‏؜]"), "").replace(' ', ' ').replace(' ', ' ')
}
