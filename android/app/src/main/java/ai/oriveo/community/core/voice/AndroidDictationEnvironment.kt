package ai.oriveo.community.core.voice

import android.content.Context
import androidx.appcompat.app.AppCompatDelegate
import java.util.Locale

/** Production [DictationEnvironment]: stops read-aloud before dictation; recognition language comes from voice settings first, then the app UI language. */
class AndroidDictationEnvironment(
    context: Context,
    private val readAloud: ReadAloudController,
    private val settings: VoiceEngineSettings? = null,
) : DictationEnvironment {
    private val appContext = context.applicationContext

    override fun stopReadAloud() {
        readAloud.stop(ReadAloudEndReason.USER_STOPPED)
    }

    /** Returns the BCP-47 tag saved on the voice settings page as-is; unset = automatic, returns null. */
    override fun recognitionLanguage(): String? = settings?.recognitionLanguage()

    /** App UI language (derived the same way as [AndroidReadAloudEnvironment.uiLocale]). */
    override fun uiLanguageTag(): String = uiLocale().toLanguageTag()

    private fun uiLocale(): Locale = appUiLocale(appContext.resources.configuration.locales[0])
}

/** App UI language: the in-app language setting first, then [configLocale] (host configuration), and finally the system default. */
fun appUiLocale(configLocale: Locale? = null): Locale =
    AppCompatDelegate.getApplicationLocales()[0]
        ?: configLocale
        ?: Locale.getDefault()

/** Host recognition language (BCP-47 as-is): the recognition language in voice settings; when unset (automatic) it follows the App UI language. Dictation and realtime use the same fallback. */
fun hostRecognitionLanguage(settings: VoiceEngineSettings?): String =
    settings?.recognitionLanguage() ?: appUiLocale().toLanguageTag()
