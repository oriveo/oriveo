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

    /**
     * Returns the BCP-47 tag saved on the voice settings page as-is; when unset (automatic), uses the app UI language
     * (resolved the same way as [AndroidReadAloudEnvironment.uiLocale]).
     */
    override fun recognitionLanguage(): String? =
        settings?.recognitionLanguage() ?: uiLocale().toLanguageTag()

    private fun uiLocale(): Locale =
        AppCompatDelegate.getApplicationLocales()[0]
            ?: appContext.resources.configuration.locales[0]
            ?: Locale.getDefault()
}
