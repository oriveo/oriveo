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
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** System recognizer kind: on-device (API 31+) or the system default recognition service. */
enum class SystemSTTRecognizer { ON_DEVICE, DEFAULT }

/** Recording mode and recognizer chosen for system dictation. */
sealed interface SystemSTTRoute {
    /**
     * The app records audio itself and feeds it to the recognizer through the pipe (33+ EXTRA_AUDIO_SOURCE); [languageTag] is the entry that matched in the recognizer's support list.
     * [languagePackOffer]: the on-device recognizer can download this language but it is not installed, so this time the route uses DEFAULT (language-pack guidance; no automatic download).
     */
    data class Pipe(
        val recognizer: SystemSTTRecognizer,
        val languageTag: String,
        val languagePackOffer: Boolean = false,
    ) : SystemSTTRoute

    /**
     * The recognizer records audio with its own microphone; [languageTag] is the requested recognition language.
     * [languagePackOffer]: no candidate supports this language, but the on-device recognizer can download it (language-pack guidance; downloaded only after the user agrees).
     */
    data class SelfRecord(
        val recognizer: SystemSTTRecognizer,
        val languageTag: String,
        val languagePackOffer: Boolean = false,
    ) : SystemSTTRoute

    /** No speech recognition service on the device. */
    data object Unavailable : SystemSTTRoute
}

/**
 * Language support reported by the recognizer (a subset of RecognitionSupport).
 * [cannotCheck]: the recognition service reports ERROR_CANNOT_CHECK_SUPPORT (support cannot be checked, e.g. Samsung's default service); support is unknown and is treated as supported.
 */
data class SystemSTTSupport(
    val installedOnDevice: List<String> = emptyList(),
    val online: List<String> = emptyList(),
    val downloadableOnDevice: List<String> = emptyList(),
    val cannotCheck: Boolean = false,
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

    /** Called only on sdk 33+; a failed query returns null (treated as unsupported), and a query that cannot be checked (ERROR_CANNOT_CHECK_SUPPORT) returns cannotCheck. */
    suspend fun checkSupport(recognizer: SystemSTTRecognizer, languageTag: String): SystemSTTSupport?

    /** Only called on SDK 33+. */
    fun triggerModelDownload(recognizer: SystemSTTRecognizer, languageTag: String)

    fun uiLocale(): Locale
}

/**
 * Routes by SDK and recognizer support:
 * - 33+: candidates [on-device (when available), default]; the first that supports the language (installed on-device or online, or support cannot be checked) routes through the pipe;
 *   if none supports it, this time it records itself without an automatic download; if the on-device recognizer can download the language, the route carries language-pack guidance (download is triggered only by [downloadLanguagePack] after user consent).
 *   If the support query does not return within [checkSupportTimeoutMs], it is treated as unsupported and the next candidate is tried (later callbacks are discarded).
 * - Below 33: support is not queried; record directly.
 * - No recognition service at all (including when every recognition service package is disabled): unavailable.
 *
 * Successful support results (including cannot-check) are cached per (language, recognizer) in this instance for [supportCacheTtlMs] (failures and timeouts are not cached);
 * the matching entry is invalidated when the model download for that language is triggered (the support list changes once it is installed).
 */
class SystemSTTRouter(
    private val backend: SystemSTTBackend,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
    private val checkSupportTimeoutMs: Long = CHECK_SUPPORT_TIMEOUT_MS,
    private val supportCacheTtlMs: Long = SUPPORT_CACHE_TTL_MS,
    /** Monotonic clock in milliseconds. */
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private class CachedSupport(val support: SystemSTTSupport, val atMs: Long)

    private val supportCache = mutableMapOf<Pair<String, SystemSTTRecognizer>, CachedSupport>()

    suspend fun route(language: String?): SystemSTTRoute {
        val tag = resolveTag(language)
        val availability = availability()
        basicRoute(tag, availability)?.let { return it }
        val supports = mutableListOf<Pair<SystemSTTRecognizer, SystemSTTSupport>>()
        for (candidate in availability.candidates) {
            val support = support(candidate, tag) ?: continue
            pipeRoute(candidate, tag, support, supports)?.let { return it }
            supports += candidate to support
        }
        return selfRecordRoute(tag, availability, supports)
    }

    /**
     * A route that can be decided without querying the recognition service (not suspended): unavailable, record itself below 33, or the same as [route] when every candidate's support query hits the cache;
     * returns null when some candidate misses the cache.
     */
    fun cachedRoute(language: String?): SystemSTTRoute? {
        val tag = resolveTag(language)
        val availability = availability()
        basicRoute(tag, availability)?.let { return it }
        val supports = mutableListOf<Pair<SystemSTTRecognizer, SystemSTTSupport>>()
        for (candidate in availability.candidates) {
            val support = cachedSupport(candidate, tag) ?: return null
            pipeRoute(candidate, tag, support, supports)?.let { return it }
            supports += candidate to support
        }
        return selfRecordRoute(tag, availability, supports)
    }

    /** No candidate supports [tag]: record itself; if the on-device recognizer can download the language, carry language-pack guidance without triggering a download. */
    private fun selfRecordRoute(
        tag: String,
        availability: Availability,
        supports: List<Pair<SystemSTTRecognizer, SystemSTTSupport>>,
    ): SystemSTTRoute.SelfRecord {
        val offer = supports.any { (candidate, support) ->
            candidate == SystemSTTRecognizer.ON_DEVICE && matchLanguage(tag, support.downloadableOnDevice) != null
        }
        return SystemSTTRoute.SelfRecord(availability.selfRecorder, tag, languagePackOffer = offer)
    }

    /** Whether each of the two recognizer kinds is available; [candidates] is the order of candidates whose support is queried on 33+. */
    private class Availability(val default: Boolean, val onDevice: Boolean) {
        val selfRecorder: SystemSTTRecognizer
            get() = if (default) SystemSTTRecognizer.DEFAULT else SystemSTTRecognizer.ON_DEVICE

        val candidates: List<SystemSTTRecognizer>
            get() = buildList {
                if (onDevice) add(SystemSTTRecognizer.ON_DEVICE)
                if (default) add(SystemSTTRecognizer.DEFAULT)
            }
    }

    private fun availability(): Availability {
        val defaultAvailable = backend.isRecognitionAvailable()
        val onDeviceAvailable = sdkInt >= Build.VERSION_CODES.S && backend.isOnDeviceRecognitionAvailable()
        return Availability(defaultAvailable, onDeviceAvailable)
    }

    /** A route that can be decided without a support query: unavailable, or record itself below 33; otherwise null. */
    private fun basicRoute(tag: String, availability: Availability): SystemSTTRoute? {
        if (!availability.default && !availability.onDevice) return SystemSTTRoute.Unavailable
        // Framework configuration may still report availability when every recognition service package is disabled; with no enabled service at all, treat it as unavailable.
        if (!backend.hasEnabledRecognitionService()) return SystemSTTRoute.Unavailable
        if (sdkInt < Build.VERSION_CODES.TIRAMISU) return SystemSTTRoute.SelfRecord(availability.selfRecorder, tag)
        return null
    }

    /** [candidate] supports [tag] (or its support cannot be checked, in which case the requested tag is used): route through the pipe; [earlier] is a candidate ranked before it that does not support the language. */
    private fun pipeRoute(
        candidate: SystemSTTRecognizer,
        tag: String,
        support: SystemSTTSupport,
        earlier: List<Pair<SystemSTTRecognizer, SystemSTTSupport>>,
    ): SystemSTTRoute.Pipe? {
        val matched = if (support.cannotCheck) tag else matchLanguage(tag, support.installedOnDevice + support.online) ?: return null
        // The on-device recognizer is not installed but can download this language: on DEFAULT, prompt the user that a language pack can be installed.
        val offer = candidate == SystemSTTRecognizer.DEFAULT && earlier.any { (other, otherSupport) ->
            other == SystemSTTRecognizer.ON_DEVICE && matchLanguage(tag, otherSupport.downloadableOnDevice) != null
        }
        return SystemSTTRoute.Pipe(candidate, matched, languagePackOffer = offer)
    }

    /**
     * The user accepts language-pack guidance: when the on-device recognizer can download [language] (default: the same as [route]), trigger the download and return true;
     * below sdk 33, or when the on-device recognizer is unavailable or cannot download, return false.
     */
    suspend fun downloadLanguagePack(language: String?): Boolean {
        if (sdkInt < Build.VERSION_CODES.TIRAMISU || !backend.isOnDeviceRecognitionAvailable()) return false
        val tag = resolveTag(language)
        val support = support(SystemSTTRecognizer.ON_DEVICE, tag) ?: return false
        val target = matchLanguage(tag, support.downloadableOnDevice) ?: return false
        download(SystemSTTRecognizer.ON_DEVICE, tag, target)
        return true
    }

    private fun download(recognizer: SystemSTTRecognizer, tag: String, target: String) {
        synchronized(supportCache) { supportCache.remove(tag to recognizer) }
        backend.triggerModelDownload(recognizer, target)
    }

    /** Query [recognizer]'s support for [tag]: first check an unexpired cache; a query that times out is cancelled (a late callback is discarded because its continuation is no longer active). */
    private suspend fun support(recognizer: SystemSTTRecognizer, tag: String): SystemSTTSupport? {
        val key = tag to recognizer
        cachedSupport(recognizer, tag)?.let { return it }
        val support = withTimeoutOrNull(checkSupportTimeoutMs) { backend.checkSupport(recognizer, tag) } ?: return null
        synchronized(supportCache) { supportCache[key] = CachedSupport(support, nowMs()) }
        return support
    }

    /** Unexpired support-query cache; an expired entry is removed, and none returns null. */
    private fun cachedSupport(recognizer: SystemSTTRecognizer, tag: String): SystemSTTSupport? {
        val key = tag to recognizer
        synchronized(supportCache) {
            val cached = supportCache[key]
            if (cached != null && nowMs() - cached.atMs < supportCacheTtlMs) return cached.support
            supportCache.remove(key)
            return null
        }
    }

    private fun resolveTag(language: String?): String = language?.takeIf { it.isNotBlank() } ?: uiLanguageTag()

    /** When no recognition language is given, use the app's UI language; when the UI language is not among the app's 16 languages, the UI actually shows English. */
    private fun uiLanguageTag(): String {
        val ui = backend.uiLocale()
        val tag = ui.toLanguageTag()
        return if (appLocaleFor(tag) != null) tag else "en"
    }

    internal companion object {
        /** Upper bound for waiting on a recognizer's support query. */
        const val CHECK_SUPPORT_TIMEOUT_MS = 2_000L

        /** Lifetime of a support-query cache entry. */
        const val SUPPORT_CACHE_TTL_MS = 600_000L

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

/**
 * Serial gate for recognizer instances: a new recognizer waits until the previous instance's destroy() has finished on the main thread before it is created, with no timeout (destroy is always posted to the main thread, so it always completes),
 * so the recognition service does not drop the session that connected first while old and new instances coexist; a realtime session holds the number for its whole run, and support queries and downloads during that time queue behind it.
 */
class SystemSTTRecognizerGate {
    /**
     * The position of one recognizer instance: [awaitTurn] waits for the predecessor to finish; this number is complete once it has [release]d itself and the predecessor is complete (transitively),
     * so a middle number that releases first (for example when it is cancelled while waiting) also cannot let later ones overtake an earlier instance that is still alive.
     */
    class Ticket internal constructor(
        private val previous: CompletableDeferred<Unit>?,
        private val done: CompletableDeferred<Unit>,
    ) {
        private val released = CompletableDeferred<Unit>()

        init {
            released.invokeOnCompletion {
                if (previous == null) {
                    done.complete(Unit)
                } else {
                    previous.invokeOnCompletion { done.complete(Unit) }
                }
            }
        }

        /** Suspends until all predecessor instances are destroyed; cancellable (after cancelling, [release] must still be called). */
        suspend fun awaitTurn() {
            previous?.await()
        }

        /** This number's instance is destroyed (or never built); safe to call repeatedly. */
        fun release() {
            released.complete(Unit)
        }
    }

    private var last: CompletableDeferred<Unit>? = null

    /** Synchronously take a number before a recognizer is created (queued after the instances that took numbers earlier). */
    @Synchronized
    fun enqueue(): Ticket {
        val mine = CompletableDeferred<Unit>()
        val previous = last
        last = mine
        return Ticket(previous, mine)
    }

    companion object {
        /** One gate shared within the process: recognizers created by the route's backend instance and by the session's backend instance also wait for each other. */
        val shared = SystemSTTRecognizerGate()
    }
}

/** Production [SystemSTTBackend]: SpeechRecognizer is created and called only on the main thread and destroyed right after use; every creation goes through [gate]. */
class AndroidSystemSTTBackend(
    context: Context,
    internal val gate: SystemSTTRecognizerGate = SystemSTTRecognizerGate.shared,
    /** Test double: replaces the real SpeechRecognizer creation (counts that the first one is destroyed before the second is created). */
    private val recognizerFactory: ((SystemSTTRecognizer) -> SpeechRecognizer)? = null,
) : SystemSTTBackend {
    private val appContext = context.applicationContext
    private val downloadScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

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
            val ticket = gate.enqueue()
            val speech = try {
                ticket.awaitTurn()
                createRecognizer(recognizer)
            } catch (error: Throwable) {
                ticket.release()
                throw error
            }
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
                                if (!cont.isActive) return
                                // Support cannot be checked (e.g. Samsung's default service) is not the same as unsupported: hand it to routing, which treats it as supported.
                                cont.resume(
                                    if (error == SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT) {
                                        SystemSTTSupport(cannotCheck = true)
                                    } else {
                                        null
                                    },
                                )
                            }
                        },
                    )
                }
            } finally {
                runCatching { speech.destroy() }
                ticket.release()
            }
        }

    /** While a session holds the number, wait until the session ends (instance destroyed) before creating the recognizer to run; requests are not dropped. */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    override fun triggerModelDownload(recognizer: SystemSTTRecognizer, languageTag: String) {
        // Take the number synchronously: a session recognizer opened later is queued behind the instance used for this download, which is destroyed first.
        val ticket = gate.enqueue()
        downloadScope.launch {
            try {
                ticket.awaitTurn()
                val speech = createRecognizer(recognizer)
                runCatching { speech.triggerModelDownload(recognizerIntent(languageTag)) }
                runCatching { speech.destroy() }
            } finally {
                ticket.release()
            }
        }
    }

    override fun uiLocale(): Locale =
        AppCompatDelegate.getApplicationLocales()[0]
            ?: appContext.resources.configuration.locales[0]
            ?: Locale.getDefault()

    /** Creates the recognizer for the routing result; must be called on the main thread, and first takes a number from [gate] and waits for it. */
    fun createRecognizer(recognizer: SystemSTTRecognizer): SpeechRecognizer =
        recognizerFactory?.invoke(recognizer) ?: if (recognizer == SystemSTTRecognizer.ON_DEVICE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
        } else {
            SpeechRecognizer.createSpeechRecognizer(appContext)
        }

    private fun recognizerIntent(languageTag: String): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
}
