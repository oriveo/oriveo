package ai.oriveo.community.core.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.content.ContextCompat
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** System recognizer kind: on-device (API 31+) or the system default recognition service. */
enum class SystemSTTRecognizer { ON_DEVICE, DEFAULT }

/** Recording mode and recognizer chosen for system dictation. */
sealed interface SystemSTTRoute {
    /** The app records audio itself and feeds it to the recognizer through a pipe (API 33+ EXTRA_AUDIO_SOURCE); [languageTag] is the entry matched in the recognizer's supported list. */
    data class Pipe(val recognizer: SystemSTTRecognizer, val languageTag: String) : SystemSTTRoute

    /** The recognizer opens the microphone itself; [languageTag] is the requested recognition language. */
    data class SelfRecord(val recognizer: SystemSTTRecognizer, val languageTag: String) : SystemSTTRoute

    /** No speech recognition service on the device. */
    data object Unavailable : SystemSTTRoute
}

/** Language support reported by a recognizer (a subset of RecognitionSupport). */
data class SystemSTTSupport(
    val installedOnDevice: List<String> = emptyList(),
    val online: List<String> = emptyList(),
    val downloadableOnDevice: List<String> = emptyList(),
)

/** Platform capabilities used for routing; production uses [AndroidSystemSTTBackend], tests use a fake backend. */
interface SystemSTTBackend {
    fun isRecognitionAvailable(): Boolean

    /** Only called on SDK 31+. */
    fun isOnDeviceRecognitionAvailable(): Boolean

    /**
     * Whether at least one enabled RecognitionService exists on the device. isOnDeviceRecognitionAvailable only
     * looks at framework configuration and still returns true when the user disabled the service package, so this
     * re-checks against the services that can actually be bound.
     */
    fun hasEnabledRecognitionService(): Boolean

    /** Only called on SDK 33+; returns null when the query fails (treated as unsupported). */
    suspend fun checkSupport(recognizer: SystemSTTRecognizer, languageTag: String): SystemSTTSupport?

    /** Only called on SDK 33+. */
    fun triggerModelDownload(recognizer: SystemSTTRecognizer, languageTag: String)

    fun uiLocale(): Locale
}

/**
 * Chooses a route from the SDK level and recognizer support:
 * - 33+: candidates are [on-device (when available), default]; the first one that supports the language
 *   (installed on-device or online) uses the pipe. If none does and a candidate can download an on-device
 *   model, a download is triggered once and this run self-records.
 *   A support query that does not call back within [checkSupportTimeoutMs] counts as unsupported and the next
 *   candidate is tried (late callbacks are discarded).
 * - Below 33: support is not queried, self-record directly.
 * - No recognition service at all (including all service packages disabled): unavailable.
 */
class SystemSTTRouter(
    private val backend: SystemSTTBackend,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
    private val checkSupportTimeoutMs: Long = CHECK_SUPPORT_TIMEOUT_MS,
) {
    suspend fun route(language: String?): SystemSTTRoute {
        val tag = language?.takeIf { it.isNotBlank() } ?: uiLanguageTag()
        val defaultAvailable = backend.isRecognitionAvailable()
        val onDeviceAvailable = sdkInt >= Build.VERSION_CODES.S && backend.isOnDeviceRecognitionAvailable()
        if (!defaultAvailable && !onDeviceAvailable) return SystemSTTRoute.Unavailable
        // Framework configuration still reports available when all service packages are disabled: with no enabled service, treat as unavailable.
        if (!backend.hasEnabledRecognitionService()) return SystemSTTRoute.Unavailable
        val selfRecorder = if (defaultAvailable) SystemSTTRecognizer.DEFAULT else SystemSTTRecognizer.ON_DEVICE
        if (sdkInt < Build.VERSION_CODES.TIRAMISU) return SystemSTTRoute.SelfRecord(selfRecorder, tag)

        val candidates = buildList {
            if (onDeviceAvailable) add(SystemSTTRecognizer.ON_DEVICE)
            if (defaultAvailable) add(SystemSTTRecognizer.DEFAULT)
        }
        val supports = mutableListOf<Pair<SystemSTTRecognizer, SystemSTTSupport>>()
        for (candidate in candidates) {
            // Cancel the query on timeout: the backend suspension point is cancelled and late callbacks are dropped because the continuation is no longer active.
            val support = withTimeoutOrNull(checkSupportTimeoutMs) { backend.checkSupport(candidate, tag) } ?: continue
            val matched = matchLanguage(tag, support.installedOnDevice + support.online)
            if (matched != null) return SystemSTTRoute.Pipe(candidate, matched)
            supports += candidate to support
        }
        supports.firstOrNull { (_, support) -> matchLanguage(tag, support.downloadableOnDevice) != null }
            ?.let { (candidate, support) ->
                backend.triggerModelDownload(candidate, matchLanguage(tag, support.downloadableOnDevice)!!)
            }
        return SystemSTTRoute.SelfRecord(selfRecorder, tag)
    }

    /** When no recognition language is given, use the app UI language; if the UI language is not among the app's 16 languages, the UI actually shows English. */
    private fun uiLanguageTag(): String {
        val ui = backend.uiLocale()
        val tag = ui.toLanguageTag()
        return if (appLocaleFor(tag) != null) tag else "en"
    }

    internal companion object {
        /** Upper bound for waiting on a recognizer's support query. */
        const val CHECK_SUPPORT_TIMEOUT_MS = 2_000L

        /**
         * Looks for a case-insensitively equal tag first, then a normalized-equal one, otherwise the first entry whose primary subtag matches and whose script is compatible; returns null if none.
         * Normalization: cmn is treated as zh; a Chinese tag without a script infers it from the region (CN / SG -> Hans, TW / HK / MO -> Hant); when both sides have a script they must be equal.
         */
        fun matchLanguage(tag: String, supported: List<String>): String? {
            val wanted = tag.replace('_', '-')
            supported.firstOrNull { it.replace('_', '-').equals(wanted, ignoreCase = true) }?.let { return it }
            val want = LanguageTag.parse(wanted)
            val parsed = supported.map { it to LanguageTag.parse(it.replace('_', '-')) }
            parsed.firstOrNull { (_, have) -> have == want }?.let { return it.first }
            return parsed.firstOrNull { (_, have) ->
                have.language == want.language &&
                    (have.script == null || want.script == null || have.script == want.script)
            }?.first
        }

        private val HANS_REGIONS = setOf("CN", "SG")
        private val HANT_REGIONS = setOf("TW", "HK", "MO")

        /** The parts of a language tag that matter for routing: primary language (lowercase), script (capitalized), region (uppercase). */
        private data class LanguageTag(val language: String, val script: String?, val region: String?) {
            companion object {
                fun parse(tag: String): LanguageTag {
                    val parts = tag.split('-').filter { it.isNotEmpty() }
                    val language = parts.firstOrNull()?.lowercase()?.let { if (it == "cmn") "zh" else it }.orEmpty()
                    var script: String? = null
                    var region: String? = null
                    for (part in parts.drop(1)) {
                        when {
                            script == null && region == null && part.length == 4 && part.all { it.isLetter() } ->
                                script = part.lowercase().replaceFirstChar { it.uppercaseChar() }
                            region == null && (
                                (part.length == 2 && part.all { it.isLetter() }) ||
                                    (part.length == 3 && part.all { it.isDigit() })
                                ) -> region = part.uppercase()
                        }
                    }
                    if (language == "zh" && script == null) {
                        script = when (region) {
                            in HANS_REGIONS -> "Hans"
                            in HANT_REGIONS -> "Hant"
                            else -> null
                        }
                    }
                    return LanguageTag(language, script, region)
                }
            }
        }
    }
}

/** Production [SystemSTTBackend]: SpeechRecognizer is created and called only on the main thread and destroyed after use. */
class AndroidSystemSTTBackend(context: Context) : SystemSTTBackend {
    private val appContext = context.applicationContext

    override fun isRecognitionAvailable(): Boolean = SpeechRecognizer.isRecognitionAvailable(appContext)

    @RequiresApi(Build.VERSION_CODES.S)
    override fun isOnDeviceRecognitionAvailable(): Boolean =
        SpeechRecognizer.isOnDeviceRecognitionAvailable(appContext)

    /** Counts enabled components only (flags 0 excludes disabled packages); the manifest <queries> already declares RecognitionService. */
    override fun hasEnabledRecognitionService(): Boolean =
        appContext.packageManager.queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0).isNotEmpty()

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    override suspend fun checkSupport(recognizer: SystemSTTRecognizer, languageTag: String): SystemSTTSupport? =
        withContext(Dispatchers.Main.immediate) {
            val speech = createRecognizer(recognizer)
            try {
                suspendCancellableCoroutine { cont ->
                    speech.checkRecognitionSupport(
                        recognizerIntent(languageTag),
                        ContextCompat.getMainExecutor(appContext),
                        object : RecognitionSupportCallback {
                            override fun onSupportResult(support: RecognitionSupport) {
                                if (cont.isActive) {
                                    cont.resume(
                                        SystemSTTSupport(
                                            installedOnDevice = support.installedOnDeviceLanguages,
                                            online = support.onlineLanguages,
                                            downloadableOnDevice = support.supportedOnDeviceLanguages,
                                        ),
                                    )
                                }
                            }

                            override fun onError(error: Int) {
                                if (cont.isActive) cont.resume(null)
                            }
                        },
                    )
                }
            } finally {
                speech.destroy()
            }
        }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    override fun triggerModelDownload(recognizer: SystemSTTRecognizer, languageTag: String) {
        ContextCompat.getMainExecutor(appContext).execute {
            val speech = createRecognizer(recognizer)
            runCatching { speech.triggerModelDownload(recognizerIntent(languageTag)) }
            speech.destroy()
        }
    }

    override fun uiLocale(): Locale =
        AppCompatDelegate.getApplicationLocales()[0]
            ?: appContext.resources.configuration.locales[0]
            ?: Locale.getDefault()

    /** Creates the recognizer for the routing result; must be called on the main thread. */
    fun createRecognizer(recognizer: SystemSTTRecognizer): SpeechRecognizer =
        if (recognizer == SystemSTTRecognizer.ON_DEVICE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
        } else {
            SpeechRecognizer.createSpeechRecognizer(appContext)
        }

    private fun recognizerIntent(languageTag: String): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
}
