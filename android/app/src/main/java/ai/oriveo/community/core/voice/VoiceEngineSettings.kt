package ai.oriveo.community.core.voice

import android.content.SharedPreferences
import ai.oriveo.community.core.model.ProviderKind

/** Where an engine fallback was discovered: the engine row in settings, or the point of use for dictation / read-aloud. */
enum class VoiceNoticeSite(val rawValue: String) {
    Settings("settings"),
    Use("use"),
}

/**
 * Stores the engine selection and recognition language for dictation (stt) / read-aloud (tts) / conversation (realtime) on this device; keys are `oriveo.voice.<direction>.*`.
 *
 * Stored on this device only and not synced across devices; included in system backup. A missing or unreadable stored value means system.
 * Recognition language null = auto. The read-aloud rate defaults to 1.0; writes are clamped to 0.5...2.0 in steps of 0.1.
 *
 * SharedPreferences is wrapped lazily via [prefsProvider], the same way as LastAuthMethodStore.
 */
class VoiceEngineSettings(
    prefsProvider: () -> SharedPreferences,
) {
    private val prefs: SharedPreferences by lazy(LazyThreadSafetyMode.PUBLICATION) {
        prefsProvider()
    }

    /** Consent record for the cloud voice disclosure, sharing the same prefs file as the selection. */
    val disclosure: VoiceDisclosureStore by lazy(LazyThreadSafetyMode.PUBLICATION) {
        VoiceDisclosureStore { prefs }
    }

    fun prewarm() {
        prefs.contains("")
    }

    fun selection(direction: VoiceDirection): VoiceEngineSelection {
        val engine = prefs.getString(key(direction, FIELD_ENGINE), null)
        if (engine != ENGINE_CLOUD) return VoiceEngineSelection.System
        val providerKind = prefs.getString(key(direction, FIELD_PROVIDER), null)
            ?.let(ProviderKind::fromRawValue)
            ?: return VoiceEngineSelection.System
        val connectionId = prefs.getString(key(direction, FIELD_CONNECTION), null)
            ?: return VoiceEngineSelection.System
        val model = prefs.getString(key(direction, FIELD_MODEL), null)
            ?: return VoiceEngineSelection.System
        return VoiceEngineSelection.Cloud(
            providerKind = providerKind,
            connectionId = connectionId,
            model = model,
            voice = prefs.getString(key(direction, FIELD_VOICE), null),
        )
    }

    /** Writes a selection made through the engine picker (including re-selecting system): also clears the pending notices of both sites for that direction. */
    fun setSelection(direction: VoiceDirection, selection: VoiceEngineSelection) {
        val editor = prefs.edit()
        writeSelection(editor, direction, selection)
        VoiceNoticeSite.entries.forEach { editor.remove(pendingKey(direction, it)) }
        editor.apply()
    }

    private fun writeSelection(
        editor: SharedPreferences.Editor,
        direction: VoiceDirection,
        selection: VoiceEngineSelection,
    ) {
        when (selection) {
            VoiceEngineSelection.System -> {
                editor.putString(key(direction, FIELD_ENGINE), ENGINE_SYSTEM)
                CLOUD_FIELDS.forEach { editor.remove(key(direction, it)) }
            }
            is VoiceEngineSelection.Cloud -> {
                editor.putString(key(direction, FIELD_ENGINE), ENGINE_CLOUD)
                editor.putString(key(direction, FIELD_PROVIDER), selection.providerKind.rawValue)
                editor.putString(key(direction, FIELD_CONNECTION), selection.connectionId)
                editor.putString(key(direction, FIELD_MODEL), selection.model)
                val voice = selection.voice
                if (voice == null) {
                    editor.remove(key(direction, FIELD_VOICE))
                } else {
                    editor.putString(key(direction, FIELD_VOICE), voice)
                }
            }
        }
    }

    /**
     * Applies one resolution result at [site] and returns the fallback reason to show right now (null = no notice).
     *
     * - Resolution asks to revert to system: rewrite the selection; when it carries a notice, show it now and leave one pending notice for the other site.
     * - At the point of use with a currently usable (cloud) selection: take this site's pending notice but do not show it.
     * - At the point of use with the current selection already system: take this site's pending notice and show it now (a fallback found first at the other site).
     * - [resolution] null = catalog unavailable: do not resolve, rewrite, or leave a pending notice; existing ones can still be taken via [takePendingNotice].
     */
    fun applyResolution(
        direction: VoiceDirection,
        resolution: VoiceEngineResolution?,
        site: VoiceNoticeSite,
    ): VoiceFallbackReason? {
        if (resolution == null) return null
        val reason = resolution.reason
        if (resolution.persist == VoiceSelectionPersist.System) {
            val editor = prefs.edit()
            writeSelection(editor, direction, VoiceEngineSelection.System)
            editor.remove(pendingKey(direction, site))
            if (resolution.notice && reason != null) {
                VoiceNoticeSite.entries.filter { it != site }
                    .forEach { editor.putString(pendingKey(direction, it), reason.rawValue) }
            }
            editor.apply()
            return if (resolution.notice) reason else null
        }
        if (site != VoiceNoticeSite.Use) return null
        val pending = takePendingNotice(direction, site)
        return if (resolution.engine is VoiceEngine.Cloud) null else pending
    }

    /** Takes and clears the pending notice at [site]; null if none. */
    fun takePendingNotice(direction: VoiceDirection, site: VoiceNoticeSite): VoiceFallbackReason? {
        val key = pendingKey(direction, site)
        val raw = prefs.getString(key, null) ?: return null
        prefs.edit().remove(key).apply()
        return VoiceFallbackReason.entries.firstOrNull { it.rawValue == raw }
    }

    /** null = auto. */
    fun recognitionLanguage(): String? = prefs.getString(KEY_RECOGNITION_LANGUAGE, null)

    fun setRecognitionLanguage(language: String?) {
        val editor = prefs.edit()
        if (language == null) {
            editor.remove(KEY_RECOGNITION_LANGUAGE)
        } else {
            editor.putString(KEY_RECOGNITION_LANGUAGE, language)
        }
        editor.apply()
    }

    /** Read-aloud rate; 1.0 when never stored. */
    fun speechRate(): Double {
        if (!prefs.contains(KEY_SPEECH_RATE)) return DEFAULT_SPEECH_RATE
        return normalizeSpeechRate(prefs.getFloat(KEY_SPEECH_RATE, DEFAULT_SPEECH_RATE.toFloat()).toDouble())
    }

    fun setSpeechRate(rate: Double) {
        prefs.edit().putFloat(KEY_SPEECH_RATE, normalizeSpeechRate(rate).toFloat()).apply()
    }

    /** Whether the system microphone permission request has been issued on this device (distinguishes the first request from a permanent denial where the system no longer prompts). */
    fun microphoneRequested(): Boolean = prefs.getBoolean(KEY_MIC_REQUESTED, false)

    fun markMicrophoneRequested() {
        prefs.edit().putBoolean(KEY_MIC_REQUESTED, true).apply()
    }

    private fun key(direction: VoiceDirection, field: String) =
        "oriveo.voice.${direction.rawValue}.$field"

    private fun pendingKey(direction: VoiceDirection, site: VoiceNoticeSite) =
        key(direction, "$FIELD_PENDING_NOTICE.${site.rawValue}")

    companion object {
        const val PREFS_NAME = "oriveo_voice_settings"
        const val KEY_RECOGNITION_LANGUAGE = "oriveo.voice.stt.language"
        const val KEY_MIC_REQUESTED = "oriveo.voice.mic.requested"
        const val KEY_SPEECH_RATE = "oriveo.voice.tts.speechRate"
        const val DEFAULT_SPEECH_RATE = 1.0
        const val MIN_SPEECH_RATE = 0.5
        const val MAX_SPEECH_RATE = 2.0

        /** Clamp to 0.5...2.0 in steps of 0.1; NaN falls back to the default. */
        fun normalizeSpeechRate(rate: Double): Double {
            if (rate.isNaN()) return DEFAULT_SPEECH_RATE
            val clamped = rate.coerceIn(MIN_SPEECH_RATE, MAX_SPEECH_RATE)
            return Math.round(clamped * 10).toDouble() / 10
        }

        private const val ENGINE_SYSTEM = "system"
        private const val ENGINE_CLOUD = "cloud"
        private const val FIELD_ENGINE = "engine"
        private const val FIELD_PROVIDER = "providerKind"
        private const val FIELD_CONNECTION = "connectionId"
        private const val FIELD_MODEL = "model"
        private const val FIELD_VOICE = "voice"
        private const val FIELD_PENDING_NOTICE = "pendingNotice"
        private val CLOUD_FIELDS = listOf(FIELD_PROVIDER, FIELD_CONNECTION, FIELD_MODEL, FIELD_VOICE)
    }
}
