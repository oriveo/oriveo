package ai.oriveo.community.core.voice

import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import ai.oriveo.community.testing.TestSharedPreferences
import java.util.Locale
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Host recognition language fallback: the voice setting's recognition language wins; unset (auto) follows the app UI language; otherwise the system default. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class AndroidDictationEnvironmentTest {

    private val settings = VoiceEngineSettings { TestSharedPreferences() }
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
    fun host_language_prefers_setting_then_ui_locale() {
        Locale.setDefault(Locale.forLanguageTag("de-DE"))
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags("fr-FR"))

        // Recognition language set: BCP-47 returned as is, unaffected by the UI language
        settings.setRecognitionLanguage("ja-JP")
        assertEquals("ja-JP", hostRecognitionLanguage(settings))

        // Unset (auto): follows the app UI language
        settings.setRecognitionLanguage(null)
        assertEquals("fr-FR", hostRecognitionLanguage(settings))
        assertEquals("fr-FR", hostRecognitionLanguage(null))

        // App UI language unset: falls back to the system default
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList())
        assertEquals("de-DE", hostRecognitionLanguage(settings))
    }
}
